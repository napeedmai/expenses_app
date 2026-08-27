--------------------------------------------------------------------------------
-- 72_restore_currency_endpoints.sql
--
-- Run as the APPLICATION SCHEMA, in SQL SCRIPTS. Idempotent.
--
--   dev  = karyasiddhitest.trinamix.com, schema HRMS
--   prod = karyasiddhi.trinamix.com,     schema REPO
--
--
-- WHAT THE DIAGNOSTIC FOUND
-- -------------------------
-- Not what any of us expected. On HRMS:
--
--   GET_EXCHANGE_RATE          VALID
--   GET_RATE_EFFECTIVE_DATE    VALID      <- so 48 and 49 DID run here
--   CONVERT_TO_USD             VALID
--   user_errors                no rows
--
--   CURRENCY_CONVERSION        12 currencies, 70 monthly rows each
--   the handler's own query    13 rows, including USD = 1
--
--   my-projects' exact SQL     returns project 7288 "test"
--
-- So the functions are fine, the rate data is complete, and the SQL behind both
-- endpoints returns rows. Nothing is wrong below the ORDS layer.
--
-- The last query is the one that mattered:
--
--   SELECT ... FROM user_ords_handlers h JOIN user_ords_templates t ...
--   WHERE  m.name = 'expenses.employee'
--   AND    t.uri_template IN ('exchange-rate','currencies');
--     -> no data found
--
-- THE TEMPLATES DO NOT EXIST. Both endpoints were removed from the module at
-- some point -- most likely by a re-run of ORDS.DEFINE_MODULE, which wipes
-- every template it owns. The 555 is ORDS having no resource to route to, and
-- "only INR" is the app's own fallback when GET /currencies fails.
--
-- Third round, third time the fault was one layer above where the symptom
-- pointed, and third time reading the live ORDS metadata settled it in one
-- query. That check is now first in DEPLOYMENT.md 12.
--
--
-- WHY NOT SIMPLY RE-RUN 46_currency_endpoints.sql
-- -----------------------------------------------
-- Because section 4 of that script calls DELETE_PRIVILEGE then DEFINE_PRIVILEGE
-- on expenses.authenticated, from a pattern list written before multi-bill
-- existed. Running it would silently drop:
--
--   /expenses/:id/items          /expenses/:id/items/:item_id
--   /expenses/:id/items/:item_id/attachment
--
-- ORDS leaves a URI that no privilege matches reachable by ANYONE, so all six
-- bill endpoints would become public. That is exactly how currencies and
-- exchange-rate lost their protection before, and why 69_restore_privileges.sql
-- had to be written.
--
-- So this script defines the two templates and their handlers and TOUCHES NO
-- PRIVILEGES. It only reports on them.
--
-- The handler bodies are the final versions, lifted from the scripts that own
-- them rather than retyped:
--   currencies     <- 49_usd_identity.sql             (USD identity, 1 USD = 1)
--   exchange-rate  <- 48_rate_month_truthfulness.sql  (rate_month, is_fallback)
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF


--------------------------------------------------------------------------------
-- 0. Where am I, what exists now, and are the functions actually there?
--------------------------------------------------------------------------------
DECLARE
  l_n NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Connected as: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
  DBMS_OUTPUT.PUT_LINE('  HRMS = dev, REPO = PRODUCTION.');

  SELECT COUNT(*) INTO l_n FROM user_objects
  WHERE  object_name IN ('GET_EXCHANGE_RATE','GET_RATE_EFFECTIVE_DATE','CONVERT_TO_USD')
  AND    object_type = 'FUNCTION' AND status = 'VALID';

  IF l_n < 3 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'Only ' || l_n || ' of 3 currency functions are VALID here. Run 45, then 48, '
      || 'then 49 first -- but NOT 46, see the header. Nothing changed.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('All three currency functions VALID.');

  FOR p IN (SELECT column_value AS pat
            FROM   TABLE(sys.odcivarchar2list('currencies','exchange-rate')))
  LOOP
    SELECT COUNT(*) INTO l_n
    FROM   user_ords_templates t
    JOIN   user_ords_modules m ON m.id = t.module_id
    WHERE  m.name = 'expenses.employee' AND t.uri_template = p.pat;
    DBMS_OUTPUT.PUT_LINE('  template ' || RPAD(p.pat, 15)
      || CASE WHEN l_n = 0 THEN '** MISSING -- will be created **' ELSE 'present' END);
  END LOOP;
END;
/


--------------------------------------------------------------------------------
-- 1. The two templates. Created only if absent, so a re-run is harmless.
--
-- Guarded rather than delete-and-recreate: this script must never be the thing
-- that removes a handler. Enough of those have gone missing already.
--------------------------------------------------------------------------------
DECLARE
  l_n NUMBER;
BEGIN
  FOR p IN (SELECT column_value AS pat
            FROM   TABLE(sys.odcivarchar2list('currencies','exchange-rate')))
  LOOP
    SELECT COUNT(*) INTO l_n
    FROM   user_ords_templates t
    JOIN   user_ords_modules m ON m.id = t.module_id
    WHERE  m.name = 'expenses.employee' AND t.uri_template = p.pat;

    IF l_n = 0 THEN
      ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => p.pat);
      DBMS_OUTPUT.PUT_LINE('  created template ' || p.pat);
    ELSE
      DBMS_OUTPUT.PUT_LINE('  template ' || p.pat || ' already there -- left alone');
    END IF;
  END LOOP;
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 2. GET /expenses/currencies   -- from 49_usd_identity.sql
--
-- Every currency with a resolvable rate, plus USD at 1. The dropdown therefore
-- cannot offer something that fails on save.
--------------------------------------------------------------------------------

BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'currencies',
    p_method      => 'GET',
    p_source_type => ords.source_type_collection_feed,
    p_source      => q'[
      SELECT c.currency,
             get_exchange_rate(c.currency, SYSDATE)                      AS exchange_rate,
             ROUND(1 / get_exchange_rate(c.currency, SYSDATE), 6)        AS inverse_rate
      FROM   (SELECT DISTINCT from_curr AS currency
              FROM   currency_conversion
              WHERE  UPPER(to_curr) = 'USD'
                AND  UPPER(from_curr) != 'USD'
              UNION
              SELECT 'USD' FROM dual) c
      WHERE  is_valid_session_token(TO_NUMBER(:emp_id_hdr), :session_token_hdr) = 'Y'
      AND    get_exchange_rate(c.currency, SYSDATE) IS NOT NULL
      ORDER  BY c.currency
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
-- 3. GET /expenses/exchange-rate   -- from 48_rate_month_truthfulness.sql
--
-- Returns rate_month and is_fallback alongside the rate, so the app can say
-- WHICH month's rate it used rather than implying the figure is current.
--------------------------------------------------------------------------------

BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'exchange-rate',
    p_method      => 'GET',
    p_source_type => ords.source_type_plsql,
    p_source      => q'[
      DECLARE
        l_emp_id   NUMBER := TO_NUMBER(:emp_id_hdr);
        l_currency VARCHAR2(3) := UPPER(:currency);
        l_on_date  DATE;
        l_rate     NUMBER;
        l_eff      DATE;
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
        l_eff  := get_rate_effective_date(l_currency, l_on_date);

        IF l_rate IS NULL THEN
          :status := 404;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'No exchange rate on file for ' || l_currency || '.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        :status := 200;
        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.WRITE('currency',        l_currency);
        APEX_JSON.WRITE('on_date',         TO_CHAR(l_on_date, 'MM/DD/YYYY'));
        APEX_JSON.WRITE('requested_month', TO_CHAR(TRUNC(l_on_date, 'MM'), 'MON-YYYY'));
        APEX_JSON.WRITE('rate_month',      TO_CHAR(l_eff, 'MON-YYYY'));
        APEX_JSON.WRITE('is_fallback',
          CASE WHEN TRUNC(l_eff, 'MM') = TRUNC(l_on_date, 'MM') THEN 'N' ELSE 'Y' END);
        APEX_JSON.WRITE('exchange_rate',   l_rate);
        APEX_JSON.WRITE('inverse_rate',    ROUND(1 / l_rate, 6));
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
-- 4. Verify.
--------------------------------------------------------------------------------

-- a) Both handlers exist, with the right shape.
SELECT t.uri_template, h.method, h.source_type,
       (SELECT COUNT(*) FROM user_ords_parameters pa WHERE pa.handler_id = h.id) AS params,
       CASE WHEN INSTR(h.source, 'get_rate_effective_date') > 0 THEN 'Y' ELSE 'N' END AS uses_48_fn,
       CASE WHEN INSTR(h.source, 'FROM dual') > 0 THEN 'Y' ELSE 'N' END AS usd_identity
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND    t.uri_template IN ('currencies','exchange-rate')
ORDER  BY t.uri_template;
-- Expect two rows.
--   currencies     COLLECTION FEED, 2 params, usd_identity Y
--   exchange-rate  PLSQL,           3 params, uses_48_fn   Y


-- b) THE REAL QUESTION -- what ELSE is missing from the module? This is the
--    query that should have been run three rounds ago. Every '** MISSING **'
--    is an endpoint the app calls that ORDS cannot route, and every
--    'present, 0 handler(s)' is a URL that answers but runs nothing.
SELECT x.pat AS expected_endpoint,
       NVL((SELECT 'present, ' || COUNT(h.id) || ' handler(s)'
            FROM   user_ords_templates t
            JOIN   user_ords_modules m ON m.id = t.module_id
            LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
            WHERE  m.name = 'expenses.employee' AND t.uri_template = x.pat
            GROUP  BY t.id), '** MISSING **') AS state
FROM   (SELECT column_value AS pat FROM TABLE(sys.odcivarchar2list(
          'auth/login','whoami','my-projects','currencies','exchange-rate',
          'draft','mine','pending',':id',':id/submit',':id/attachment',
          ':id/accept',':id/revise',':id/reject','push-token',
          ':id/items',':id/items/:item_id',':id/items/:item_id/attachment',
          'bulk-accept','bulk-revise','bulk-reject'))) x
ORDER  BY 2 DESC, 1;


-- c) Privileges are NOT touched by this script -- only reported. Anything
--    UNPROTECTED is reachable without a token: fix with
--    69_restore_privileges.sql, which rebuilds from an explicit list.
SELECT x.pat AS pattern,
       NVL((SELECT MAX(pr.name) FROM user_ords_privilege_mappings pm
            JOIN   user_ords_privileges pr ON pr.id = pm.privilege_id
            WHERE  pm.pattern = '/expenses/' || x.pat), '** UNPROTECTED **') AS privilege
FROM   (SELECT column_value AS pat FROM TABLE(sys.odcivarchar2list(
          'currencies','exchange-rate','mine','pending',
          ':id/items',':id/items/:item_id',':id/items/:item_id/attachment'))) x
ORDER  BY 2, 1;


--------------------------------------------------------------------------------
-- 5. THEN: three things about dev that no script can fix.
--
--
-- (i) THE ONLY PROJECT YOU CAN PICK HAS NO PROJECT MANAGER.
--
--     Your three allocations, from the diagnostic:
--
--       2386  Trinamix:KaryaSiddhi   PM 5710 Arpana Shukla   allocation ENDED 11-Aug-2026
--       7288  test                   PM none                 usable
--       7328  (no name)              -                       project not ACTIVE
--
--     So the dropdown offering exactly one project is CORRECT, and it is not
--     the endpoint being broken. But a claim on 7288 cannot be approved at the
--     MANAGER stage, because there is nobody to approve it. The submit email
--     will say exactly that -- the no-manager branch working as designed --
--     which means the two-stage workflow cannot be tested as things stand.
--
--     Someone with access to the data has to do ONE of:
--       * add a PROJECT_MANAGER row (P_ID = 7288) for project 7288, or
--       * extend your allocation on 2386 past today -- it expired on 11-Aug,
--         ten days ago -- which also gives you a real manager in Arpana Shukla.
--
--     The second is better: it exercises the path that actually matters, with
--     a manager who has an email address.
--
--
-- (ii) YOU ARE THE FINANCE MANAGER ON DEV.
--      get_finance_manager_empid() returns 3680, which is you. Convenient --
--      you can drive both approval stages single-handed. Just remember it is
--      somebody else on prod, and that a claim you submit yourself will arrive
--      at a finance stage where you are the approver. That is not a bug.
--
--
-- (iii) DEV'S RATES STOP AT 30-SEP-2025, eleven months ago. So every lookup
--       today falls back to the newest month on file, and is_fallback will be
--       'Y' on every response. That is the honest answer rather than a fault:
--       script 48 exists precisely so the app can say WHICH month's rate it
--       used instead of implying the figure is current. Worth knowing before
--       you read 'Y' as something being broken.
--------------------------------------------------------------------------------
