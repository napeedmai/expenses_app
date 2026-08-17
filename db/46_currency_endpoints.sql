--------------------------------------------------------------------------------
-- 46_currency_endpoints.sql
--
-- ORDS side of multi-currency expenses. Run AFTER 45_currency_conversion.sql,
-- as the app schema (HRMS for dev, REPO for prod). Idempotent.
--
-- ADDS
--   GET  /expenses/currencies      - dropdown values
--   GET  /expenses/exchange-rate   - rate for a currency on a date
--
-- CHANGES
--   POST /expenses/draft           - accepts currency, stamps rate + USD
--   PUT  /expenses/{id}            - recomputes rate + USD after edits
--   GET  /expenses/mine            - returns currency, exchange_rate, amount_usd
--   GET  /expenses/{id}            - same
--
-- BACKWARD COMPATIBILITY
-- ----------------------
-- A client that sends no "currency" gets c_default_currency (INR), matching
-- how existing rows were backfilled in 45_currency_conversion.sql. This
-- keeps already-installed app builds working while the new build rolls out.
-- Change the default in BOTH files if INR is wrong for your data.
--
-- PRIVILEGES
-- ----------
-- The two new endpoints are added to the expenses.authenticated privilege.
-- This matters: ORDS leaves any path no privilege pattern matches WIDE OPEN,
-- so a new endpoint is public until it is listed. Section 3 rebuilds the
-- privilege from its CURRENT roles and patterns rather than a hardcoded
-- list, because role names differ between environments (dev uses
-- REPORTING_MANAGER_ROLE where prod uses PROJECT_MANAGER_ROLE) and
-- hardcoding them would lock out every protected endpoint.
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- 1. GET /expenses/currencies
--
--    Only currencies that actually resolve to a rate today are returned, so
--    the dropdown cannot offer something that fails on save.
--    inverse_rate is included for display ("1 USD = 88.65 INR"); it must
--    never be used to multiply - see the header of 45_currency_conversion.sql.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_TEMPLATE(
    p_module_name => 'expenses.employee',
    p_pattern     => 'currencies');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'currencies',
    p_method      => 'GET',
    p_source_type => ords.source_type_collection_feed,
    p_source      => q'[
      SELECT c.from_curr                                  AS currency,
             get_exchange_rate(c.from_curr, SYSDATE)      AS exchange_rate,
             ROUND(1 / get_exchange_rate(c.from_curr, SYSDATE), 6) AS inverse_rate
      FROM   (SELECT DISTINCT from_curr
              FROM   currency_conversion
              WHERE  UPPER(to_curr) = 'USD') c
      WHERE  is_valid_session_token(TO_NUMBER(:emp_id_hdr), :session_token_hdr) = 'Y'
      AND    get_exchange_rate(c.from_curr, SYSDATE) IS NOT NULL
      ORDER  BY c.from_curr
    ]'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'currencies', p_method => 'GET',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'currencies', p_method => 'GET',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 2. GET /expenses/exchange-rate?currency=INR&on_date=04/15/2026
--
--    on_date should be the expense's FROM_DATE, since the applicable rate is
--    the one for the month the expense PERIOD starts in - not the bill month.
--    Omitting on_date gives today's rate.
--
--    Lets the Add Expense screen show the rate and converted amount before
--    saving, using exactly the same function the save path uses, so the
--    preview can never disagree with what gets stored.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_TEMPLATE(
    p_module_name => 'expenses.employee',
    p_pattern     => 'exchange-rate');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'exchange-rate',
    p_method      => 'GET',
    p_source_type => ords.source_type_plsql,
    p_source      => q'[
      DECLARE
        l_emp_id   NUMBER := TO_NUMBER(:emp_id_hdr);
        l_currency VARCHAR2(3)  := UPPER(:currency);
        l_on_date  DATE;
        l_rate     NUMBER;
        l_amount   NUMBER := TO_NUMBER(:amount DEFAULT NULL ON CONVERSION ERROR);
      BEGIN
        IF is_valid_session_token(l_emp_id, :session_token_hdr) != 'Y' THEN
          :status := 401;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Session expired or invalid. Please log in again.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        IF l_currency IS NULL THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Missing "currency" query parameter.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        l_on_date := CASE
                       WHEN :on_date IS NULL THEN SYSDATE
                       ELSE TO_DATE(:on_date, 'MM/DD/YYYY')
                     END;

        l_rate := get_exchange_rate(l_currency, l_on_date);

        IF l_rate IS NULL THEN
          :status := 404;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'No exchange rate on file for ' || l_currency || '.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        :status := 200;
        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.WRITE('currency',      l_currency);
        APEX_JSON.WRITE('on_date',       TO_CHAR(l_on_date, 'MM/DD/YYYY'));
        APEX_JSON.WRITE('rate_month',    TO_CHAR(TRUNC(l_on_date, 'MM'), 'MON-YYYY'));
        APEX_JSON.WRITE('exchange_rate', l_rate);
        APEX_JSON.WRITE('inverse_rate',  ROUND(1 / l_rate, 6));
        IF l_amount IS NOT NULL THEN
          APEX_JSON.WRITE('amount',     l_amount);
          APEX_JSON.WRITE('amount_usd', ROUND(l_amount * l_rate, 2));
        END IF;
        APEX_JSON.CLOSE_OBJECT;
      EXCEPTION
        WHEN OTHERS THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', SQLERRM);
          APEX_JSON.CLOSE_OBJECT;
      END;
    ]'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'exchange-rate', p_method => 'GET',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'exchange-rate', p_method => 'GET',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'exchange-rate', p_method => 'GET',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT');

  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 3. Protect the two new endpoints.
--
--    Reads the privilege's CURRENT roles and patterns and adds the new ones,
--    so this works unchanged on dev and prod despite their different role
--    names. Never introduces a wildcard - a pattern like /expenses/* would
--    also match /expenses/auth/login and make logging in impossible.
--------------------------------------------------------------------------------
DECLARE
  l_roles    owa.vc_arr;
  l_patterns owa.vc_arr;
  r          PLS_INTEGER := 0;
  p          PLS_INTEGER := 0;

  FUNCTION has_pattern(p_pattern IN VARCHAR2) RETURN BOOLEAN IS
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n
    FROM   user_ords_privilege_mappings pm
    JOIN   user_ords_privileges pr ON pr.id = pm.privilege_id
    WHERE  pr.name = 'expenses.authenticated'
      AND  pm.pattern = p_pattern;
    RETURN l_n > 0;
  END;
BEGIN
  IF has_pattern('/expenses/currencies') AND has_pattern('/expenses/exchange-rate') THEN
    DBMS_OUTPUT.PUT_LINE('Privilege already covers both new endpoints - nothing to do.');
    RETURN;
  END IF;

  FOR x IN (SELECT role_name
            FROM   user_ords_privilege_roles
            WHERE  privilege_name = 'expenses.authenticated'
            ORDER  BY role_name)
  LOOP
    r := r + 1;
    l_roles(r) := x.role_name;
  END LOOP;

  IF r = 0 THEN
    RAISE_APPLICATION_ERROR(-20080,
      'expenses.authenticated has no roles - aborting rather than recreating '||
      'it with none, which would block every protected endpoint.');
  END IF;

  FOR x IN (SELECT pm.pattern
            FROM   user_ords_privilege_mappings pm
            JOIN   user_ords_privileges pr ON pr.id = pm.privilege_id
            WHERE  pr.name = 'expenses.authenticated'
            ORDER  BY pm.pattern)
  LOOP
    p := p + 1;
    l_patterns(p) := x.pattern;
  END LOOP;

  IF NOT has_pattern('/expenses/currencies') THEN
    p := p + 1; l_patterns(p) := '/expenses/currencies';
  END IF;

  IF NOT has_pattern('/expenses/exchange-rate') THEN
    p := p + 1; l_patterns(p) := '/expenses/exchange-rate';
  END IF;

  ORDS.DELETE_PRIVILEGE(p_name => 'expenses.authenticated');

  ORDS.DEFINE_PRIVILEGE(
    p_privilege_name => 'expenses.authenticated',
    p_roles          => l_roles,
    p_patterns       => l_patterns,
    p_label          => 'Expense App - Authenticated Access',
    p_description    => 'Any signed-in employee or reviewer may call expense endpoints. Row-level checks happen in the handlers. auth/login is intentionally excluded - a wildcard here makes login impossible.');

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Privilege rebuilt with ' || p || ' patterns and ' || r || ' roles.');
END;
/


--------------------------------------------------------------------------------
-- 4. POST /expenses/draft - now stamps currency, rate and USD amount.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'draft',
    p_method      => 'POST',
    p_source_type => ords.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source      => q'[
      DECLARE
        c_default_currency CONSTANT VARCHAR2(3) := 'INR';

        l_body        CLOB    := :body_text;
        l_emp_id      NUMBER  := TO_NUMBER(:emp_id_hdr);
        l_mime        VARCHAR2(150) := JSON_VALUE(l_body, '$.attachment_mime_type');
        l_client_req  VARCHAR2(64)  := JSON_VALUE(l_body, '$.client_request_id');
        l_id          NUMBER;
        l_existing_status VARCHAR2(30);
        l_currency    VARCHAR2(3);
        l_from_date   DATE;
        l_amount      NUMBER;
        l_rate        NUMBER;
      BEGIN
        IF l_emp_id IS NULL THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'Missing or invalid X-Emp-Id header'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        IF is_valid_session_token(l_emp_id, :session_token_hdr) != 'Y' THEN
          :status := 401;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'Session expired or invalid. Please log in again.'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        IF l_client_req IS NOT NULL THEN
          BEGIN
            SELECT id, status INTO l_id, l_existing_status
            FROM   expenses
            WHERE  emp_id = l_emp_id AND client_request_id = l_client_req;

            :status := 200;
            APEX_JSON.OPEN_OBJECT;
            APEX_JSON.WRITE('id', l_id);
            APEX_JSON.WRITE('status', l_existing_status);
            APEX_JSON.WRITE('deduplicated', 'Y');
            APEX_JSON.CLOSE_OBJECT;
            RETURN;
          EXCEPTION
            WHEN NO_DATA_FOUND THEN NULL;
          END;
        END IF;

        IF is_allowed_attachment(l_mime) = 'N' THEN
          :status := 422;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Attachment type not allowed: ' || l_mime);
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        IF JSON_VALUE(l_body, '$.from_date') IS NULL THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Missing or unreadable "from_date" (expected format: MM/DD/YYYY).');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        IF JSON_VALUE(l_body, '$.to_date') IS NULL THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Missing or unreadable "to_date" (expected format: MM/DD/YYYY).');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        IF JSON_VALUE(l_body, '$.amount' RETURNING NUMBER) IS NULL THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Missing or unreadable "amount" (must be a plain number, not a quoted string).');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        l_from_date := TO_DATE(JSON_VALUE(l_body, '$.from_date'), 'MM/DD/YYYY');
        l_amount    := JSON_VALUE(l_body, '$.amount' RETURNING NUMBER);

        -- Older app builds send no currency at all; default rather than
        -- reject, so a phone that has not updated yet keeps working.
        l_currency  := UPPER(NVL(JSON_VALUE(l_body, '$.currency'), c_default_currency));

        -- The rate is chosen by the month FROM_DATE falls in, not the bill
        -- date: a May bill for April travel uses April's rate.
        l_rate := get_exchange_rate(l_currency, l_from_date);

        IF l_rate IS NULL THEN
          :status := 422;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'No exchange rate on file for currency ' || l_currency || '.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        INSERT INTO expenses (
          emp_id, bill_no, bill_date, from_date, to_date, project_id, type, amount,
          description, attachment_path, attachment_filename, attachment_mime_type, status,
          client_request_id, currency, exchange_rate, amount_usd
        ) VALUES (
          l_emp_id,
          JSON_VALUE(l_body, '$.bill_no'),
          CASE WHEN JSON_VALUE(l_body, '$.bill_date') IS NOT NULL
               THEN TO_DATE(JSON_VALUE(l_body, '$.bill_date'), 'MM/DD/YYYY') END,
          l_from_date,
          TO_DATE(JSON_VALUE(l_body, '$.to_date'), 'MM/DD/YYYY'),
          JSON_VALUE(l_body, '$.project_id' RETURNING NUMBER),
          JSON_VALUE(l_body, '$.type'),
          l_amount,
          JSON_VALUE(l_body, '$.description'),
          JSON_VALUE(l_body, '$.attachment_path'),
          JSON_VALUE(l_body, '$.attachment_filename'),
          l_mime,
          'DRAFT',
          l_client_req,
          l_currency,
          l_rate,
          ROUND(l_amount * l_rate, 2)
        )
        RETURNING id INTO l_id;

        :status := 201;
        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.WRITE('id', l_id);
        APEX_JSON.WRITE('status', 'DRAFT');
        APEX_JSON.WRITE('currency', l_currency);
        APEX_JSON.WRITE('exchange_rate', l_rate);
        APEX_JSON.WRITE('amount_usd', ROUND(l_amount * l_rate, 2));
        APEX_JSON.CLOSE_OBJECT;
      EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
          BEGIN
            SELECT id, status INTO l_id, l_existing_status
            FROM   expenses
            WHERE  emp_id = l_emp_id AND client_request_id = l_client_req;
            :status := 200;
            APEX_JSON.OPEN_OBJECT;
            APEX_JSON.WRITE('id', l_id);
            APEX_JSON.WRITE('status', l_existing_status);
            APEX_JSON.WRITE('deduplicated', 'Y');
            APEX_JSON.CLOSE_OBJECT;
          EXCEPTION
            WHEN OTHERS THEN
              :status := 400;
              APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', SQLERRM); APEX_JSON.CLOSE_OBJECT;
          END;
        WHEN OTHERS THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', SQLERRM);
          APEX_JSON.CLOSE_OBJECT;
      END;
    ]'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'draft', p_method => 'POST',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'draft', p_method => 'POST',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'draft', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT');

  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 5. PUT /expenses/{id} - recompute conversion after any edit.
--
--    The recompute is a second UPDATE reading the row's own stored values,
--    rather than the incoming JSON. That way it stays correct no matter
--    which subset of fields the client sent: change only the amount and the
--    USD figure still follows; change only from_date and the rate moves to
--    the new month.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => ':id',
    p_method      => 'PUT',
    p_source_type => ords.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source      => q'[
      DECLARE
        l_body     CLOB   := :body_text;
        l_emp_id   NUMBER := TO_NUMBER(:emp_id_hdr);
        l_owner_id NUMBER;
        l_status   VARCHAR2(30);
        l_mime     VARCHAR2(150) := JSON_VALUE(l_body, '$.attachment_mime_type');
        l_currency VARCHAR2(3)   := UPPER(JSON_VALUE(l_body, '$.currency'));
        l_rate     NUMBER;
        l_usd      NUMBER;
        l_curr_now VARCHAR2(3);
      BEGIN
        IF is_valid_session_token(l_emp_id, :session_token_hdr) != 'Y' THEN
          :status := 401;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'Session expired or invalid. Please log in again.'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        SELECT emp_id, status INTO l_owner_id, l_status
        FROM   expenses WHERE id = :id FOR UPDATE;

        IF l_owner_id != l_emp_id THEN
          :status := 403;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'Not your expense'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        IF l_status NOT IN ('DRAFT', 'REVISION_REQUESTED') THEN
          :status := 409;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Cannot edit an expense in status ' || l_status);
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        IF is_allowed_attachment(l_mime) = 'N' THEN
          :status := 422;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'Attachment type not allowed: ' || l_mime); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        -- Reject an unknown currency before writing anything.
        IF l_currency IS NOT NULL AND get_exchange_rate(l_currency, SYSDATE) IS NULL THEN
          :status := 422;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'No exchange rate on file for currency ' || l_currency || '.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        UPDATE expenses SET
          bill_no              = NVL(JSON_VALUE(l_body, '$.bill_no'), bill_no),
          bill_date            = CASE WHEN JSON_VALUE(l_body, '$.bill_date') IS NOT NULL
                                       THEN TO_DATE(JSON_VALUE(l_body, '$.bill_date'), 'MM/DD/YYYY') ELSE bill_date END,
          from_date            = NVL(TO_DATE(JSON_VALUE(l_body, '$.from_date'), 'MM/DD/YYYY'), from_date),
          to_date              = NVL(TO_DATE(JSON_VALUE(l_body, '$.to_date'), 'MM/DD/YYYY'), to_date),
          project_id           = NVL(JSON_VALUE(l_body, '$.project_id' RETURNING NUMBER), project_id),
          type                 = NVL(JSON_VALUE(l_body, '$.type'), type),
          amount               = NVL(JSON_VALUE(l_body, '$.amount' RETURNING NUMBER), amount),
          description          = NVL(JSON_VALUE(l_body, '$.description'), description),
          attachment_path      = NVL(JSON_VALUE(l_body, '$.attachment_path'), attachment_path),
          attachment_filename  = NVL(JSON_VALUE(l_body, '$.attachment_filename'), attachment_filename),
          attachment_mime_type = NVL(l_mime, attachment_mime_type),
          currency             = NVL(l_currency, currency)
        WHERE id = :id;

        -- Recompute from what is now stored, not from the request body.
        UPDATE expenses
        SET    exchange_rate = get_exchange_rate(currency, from_date),
               amount_usd    = ROUND(amount * get_exchange_rate(currency, from_date), 2)
        WHERE  id = :id
        RETURNING currency, exchange_rate, amount_usd INTO l_curr_now, l_rate, l_usd;

        :status := 200;
        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.WRITE('id', :id);
        APEX_JSON.WRITE('status', 'UPDATED');
        APEX_JSON.WRITE('currency', l_curr_now);
        APEX_JSON.WRITE('exchange_rate', l_rate);
        APEX_JSON.WRITE('amount_usd', l_usd);
        APEX_JSON.CLOSE_OBJECT;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          :status := 404;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'Expense not found'); APEX_JSON.CLOSE_OBJECT;
        WHEN OTHERS THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', SQLERRM); APEX_JSON.CLOSE_OBJECT;
      END;
    ]'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id', p_method => 'PUT',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id', p_method => 'PUT',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id', p_method => 'PUT',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT');

  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 6. GET /expenses/mine - include the currency columns.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'mine',
    p_method      => 'GET',
    p_source_type => ords.source_type_collection_feed,
    p_source      => q'[
      SELECT 'expenses/' || e.id "$.id",
             e.id, e.bill_no,
             TO_CHAR(e.bill_date, 'MM/DD/YYYY') bill_date,
             TO_CHAR(e.from_date, 'MM/DD/YYYY') from_date,
             TO_CHAR(e.to_date, 'MM/DD/YYYY') to_date,
             e.project_id,
             e.type, e.amount, e.description, e.attachment_filename,
             e.status, e.current_stage, e.submitted_at,
             e.currency, e.exchange_rate, e.amount_usd
      FROM   expenses e
      WHERE  e.emp_id = TO_NUMBER(:emp_id_hdr)
      AND    is_valid_session_token(TO_NUMBER(:emp_id_hdr), :session_token_hdr) = 'Y'
      ORDER BY e.creation_date DESC
    ]'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'mine', p_method => 'GET',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'mine', p_method => 'GET',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 6b. GET /expenses/{id} - include the currency columns.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => ':id',
    p_method      => 'GET',
    p_source_type => ords.source_type_collection_item,
    p_source      => q'[
      SELECT e.id, e.emp_id, e.bill_no,
             TO_CHAR(e.bill_date, 'MM/DD/YYYY') bill_date,
             TO_CHAR(e.from_date, 'MM/DD/YYYY') from_date,
             TO_CHAR(e.to_date, 'MM/DD/YYYY') to_date,
             e.project_id, pm.project_name,
             e.type, e.amount, e.description,
             e.currency, e.exchange_rate, e.amount_usd,
             e.attachment_path, e.attachment_filename, e.attachment_mime_type,
             e.status, e.current_stage,
             e.manager_empid, mgr.first_name || ' ' || mgr.last_name AS manager_name,
             e.finance_manager_empid, fin.first_name || ' ' || fin.last_name AS finance_manager_name,
             e.submitted_at, e.creation_date, e.last_update_date
      FROM   expenses e
      LEFT   JOIN projectmaster pm ON pm.project_id = e.project_id
      LEFT   JOIN employeedetails mgr ON mgr.empid = e.manager_empid
      LEFT   JOIN employeedetails fin ON fin.empid = e.finance_manager_empid
      WHERE  e.id = :id
      AND    e.emp_id = TO_NUMBER(:emp_id_hdr)
      AND    is_valid_session_token(TO_NUMBER(:emp_id_hdr), :session_token_hdr) = 'Y'
    ]'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id', p_method => 'GET',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id', p_method => 'GET',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 6c. GET /expenses/pending - reviewers need the currency too.
--
--     Without this a reviewer sees a bare number with no unit: "1000" could
--     be 1,000 rupees (about $11) or 1,000 dinar (about $3,272). The amount
--     alone is not enough information to approve on.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'pending',
    p_method      => 'GET',
    p_source_type => ords.source_type_collection_feed,
    p_source      => q'[
      SELECT 'expenses/' || e.id "$.id",
             e.id, e.emp_id,
             emp.first_name || ' ' || emp.last_name AS emp_name,
             e.bill_no,
             TO_CHAR(e.bill_date, 'MM/DD/YYYY') bill_date,
             TO_CHAR(e.from_date, 'MM/DD/YYYY') from_date,
             TO_CHAR(e.to_date, 'MM/DD/YYYY') to_date,
             e.project_id, pm.project_name,
             e.type, e.amount, e.description, e.current_stage,
             e.currency, e.exchange_rate, e.amount_usd,
             e.submitted_at, e.attachment_filename
      FROM   expenses e
      JOIN   employeedetails emp ON emp.empid = e.emp_id
      LEFT   JOIN projectmaster pm ON pm.project_id = e.project_id
      WHERE  e.status = 'SUBMITTED'
      AND    is_valid_session_token(TO_NUMBER(:emp_id_hdr), :session_token_hdr) = 'Y'
      AND (
            (e.current_stage = 'MANAGER' AND e.manager_empid = TO_NUMBER(:emp_id_hdr))
         OR (e.current_stage = 'FINANCE' AND is_finance_manager(TO_NUMBER(:emp_id_hdr)) = 'Y')
      )
      ORDER BY e.creation_date ASC
    ]'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'pending', p_method => 'GET',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'pending', p_method => 'GET',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 7. Verification.
--------------------------------------------------------------------------------
-- New templates present?
SELECT t.uri_template, h.method
FROM   user_ords_templates t
JOIN   user_ords_modules m ON m.id = t.module_id
LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
WHERE  m.name = 'expenses.employee'
  AND  t.uri_template IN ('currencies', 'exchange-rate')
ORDER  BY t.uri_template;

-- Both new endpoints protected, and still no wildcard?
SELECT pm.pattern, p.name
FROM   user_ords_privilege_mappings pm
JOIN   user_ords_privileges p ON p.id = pm.privilege_id
ORDER  BY p.name, pm.pattern;

-- Must return zero rows.
SELECT pm.pattern FROM user_ords_privilege_mappings pm
WHERE  pm.pattern LIKE '/expenses/%*%' OR pm.pattern = '/expenses/*';


--------------------------------------------------------------------------------
-- 8. Then test with a real Bearer token and session token:
--
--   GET /expenses/currencies
--       -> list of currencies, each with exchange_rate and inverse_rate
--
--   GET /expenses/exchange-rate?currency=INR&on_date=04/15/2026&amount=1000
--       -> exchange_rate ~0.0113, amount_usd ~11.28, rate_month APR-2026
--
--   POST /expenses/draft  with  "currency": "EUR", "amount": 100
--       -> amount_usd ~117.26
--
--   PUT /expenses/{id}    with  "amount": 200   (no currency sent)
--       -> amount_usd doubles, currency unchanged
--
-- The check that matters: 1000 INR must come back as roughly 11 USD, not
-- 88,648. If you see the latter, the rate direction has been inverted
-- somewhere - see the header of 45_currency_conversion.sql.
--------------------------------------------------------------------------------
