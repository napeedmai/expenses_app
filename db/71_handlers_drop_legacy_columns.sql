--------------------------------------------------------------------------------
-- 71_handlers_drop_legacy_columns.sql
--
-- Run as the APPLICATION SCHEMA, in SQL SCRIPTS. Idempotent.
-- Run AFTER 70_email_multibill.sql.
--
--   dev  = karyasiddhitest.trinamix.com, schema HRMS
--   prod = karyasiddhi.trinamix.com,     schema REPO
--
--
-- THE SAME MISTAKE AS 70, IN FIVE MORE PLACES
-- -------------------------------------------
-- Script 64 dropped eight columns from EXPENSES:
--
--   BILL_NO  BILL_DATE  TYPE  DESCRIPTION
--   ATTACHMENT_BLOB  ATTACHMENT_FILENAME  ATTACHMENT_MIME_TYPE  ATTACHMENT_PATH
--
-- Scripts 66 and 68 were written by copying the old handlers from
-- PROD_4_endpoints.sql and ADDING the new fields. Adding, never removing. So
-- five handlers still select or write columns that no longer exist:
--
--   GET  /expenses/mine      bill_no, bill_date, type, description, attachment_filename
--   GET  /expenses/pending   bill_no, bill_date, type, description, attachment_filename
--   GET  /expenses/:id       bill_no, bill_date, type, description, all three attachment_*
--   POST /expenses/draft     INSERT ... description
--   PUT  /expenses/:id       UPDATE ... description
--
-- Each one is ORA-00904 at runtime, which ORDS reports as a bare 403 with no
-- body. That is the 403 on Home and Approvals. It was never about privileges,
-- and it was never really about the email procedure either -- 70 was a genuine
-- second instance of the same bug, not the cause of this one.
--
-- The header comment in 66 says "copied byte for byte with only the marked
-- parts changed". That was the error: byte-for-byte is the right instinct for
-- preserving logic and the wrong one after a schema change, where the whole
-- point is that some of those bytes are now invalid.
--
--
-- WHY MY DIAGNOSTIC MISSED IT
-- ---------------------------
-- I asked you to run a cut-down version of the mine query -- id, claim_for,
-- currency, amount_usd, item_count -- containing only the columns I had ADDED.
-- It returned no rows, which I read as "the handler SQL is fine". It only ever
-- proved that the new columns exist. Running the handler's actual source is
-- the check that would have found this in one step:
--
--   SELECT source FROM user_ords_handlers h
--   JOIN   user_ords_templates t ON t.id = h.template_id
--   WHERE  t.uri_template = 'mine';
--
--
-- WHAT THE APP LOSES, AND WHY THAT IS CORRECT
-- -------------------------------------------
-- These fields are gone from the claim because they are properties of a BILL
-- now, and a claim has up to twenty of them. There is no single bill_no or type
-- for a claim any more; there was never a coherent value to return.
--
--   * ExpenseListScreen already falls back: `item.claim_for || item.type`.
--   * ReviewExpenseScreen already guards: `expense.description ? ... : null`.
--   * The per-bill values it shows come from GET :id/items, which is unaffected.
--
-- ONE PLACE DOES NOT DEGRADE WELL: HomeScreen groups spending by `e.type` and
-- dates rows by `e.bill_date`. With type gone, every claim files under "Other";
-- with bill_date gone it falls back to from_date, which is fine. The category
-- breakdown needs bill-level data it can no longer get from this endpoint --
-- flagged, not silently patched, because it is a product decision.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF


--------------------------------------------------------------------------------
-- 0. Right schema, and has 64 actually run here?
--
-- This script is safe either way -- the new handlers reference only columns
-- that exist in BOTH shapes -- but it is worth knowing which schema you are on,
-- because prod and dev genuinely differ on this point.
--------------------------------------------------------------------------------
DECLARE
  l_schema VARCHAR2(128) := SYS_CONTEXT('USERENV','CURRENT_SCHEMA');
  l_n      NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Connected as: ' || l_schema);

  SELECT COUNT(*) INTO l_n FROM user_tables WHERE table_name = 'EXPENSE_ITEMS';
  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'No EXPENSE_ITEMS on ' || l_schema || '. Run 64 first. Nothing changed.');
  END IF;

  SELECT COUNT(*) INTO l_n FROM user_tab_columns
  WHERE  table_name = 'EXPENSES'
  AND    column_name IN ('BILL_NO','BILL_DATE','TYPE','DESCRIPTION',
                         'ATTACHMENT_BLOB','ATTACHMENT_FILENAME',
                         'ATTACHMENT_MIME_TYPE','ATTACHMENT_PATH');

  IF l_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('Legacy columns are gone -- section 3 of script 64 ran '
      || 'here. This is the schema where the handlers were failing.');
  ELSE
    DBMS_OUTPUT.PUT_LINE(l_n || ' legacy column(s) still present -- section 3 of '
      || 'script 64 did NOT run here. The handlers still work by accident; this '
      || 'script makes them correct, and 67_multibill_stage5_cleanup.sql can '
      || 'then drop the columns safely.');
  END IF;
END;
/


--------------------------------------------------------------------------------
-- 1. GET /expenses/mine
--
-- Returns: id, from_date, to_date, project_id, claim_for, amount, currency,
--          amount_usd, item_count, status, current_stage, submitted_at.
--
-- `amount` is kept but should not be displayed on its own: since stage 1 it is
-- SUM(items.amount) across bills that may be in different currencies. amount_usd
-- is the figure that means something.
--------------------------------------------------------------------------------

BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'mine',
    p_method      => 'GET',
    p_source_type => ords.source_type_collection_feed,
    p_source      => q'[
      SELECT 'expenses/' || e.id "$.id",
             e.id,
             TO_CHAR(e.from_date, 'MM/DD/YYYY') from_date,
             TO_CHAR(e.to_date, 'MM/DD/YYYY') to_date,
             e.project_id,
             e.claim_for, e.amount, e.currency, e.amount_usd,
             (SELECT COUNT(*) FROM expense_items i WHERE i.expense_id = e.id) AS item_count,
             e.status, e.current_stage, e.submitted_at
      FROM   expenses e
      WHERE  e.emp_id = TO_NUMBER(:emp_id_hdr)
      AND    is_valid_session_token(TO_NUMBER(:emp_id_hdr), :session_token_hdr) = 'Y'
      ORDER BY e.creation_date DESC
    ]'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'mine', p_method => 'GET',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'mine', p_method => 'GET',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  COMMIT;
END;
/

--------------------------------------------------------------------------------
-- 2. GET /expenses/pending
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
             TO_CHAR(e.from_date, 'MM/DD/YYYY') from_date,
             TO_CHAR(e.to_date, 'MM/DD/YYYY') to_date,
             e.project_id, pm.project_name,
             e.current_stage,
             e.claim_for, e.amount, e.currency, e.amount_usd, e.exchange_rate,
             (SELECT COUNT(*) FROM expense_items i WHERE i.expense_id = e.id) AS item_count,
             e.submitted_at
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
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'pending', p_method => 'GET',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  COMMIT;
END;
/

--------------------------------------------------------------------------------
-- 3. GET /expenses/:id -- the claim header.
--
-- bills_without_receipt stays: the app uses it to enable or disable Submit.
--------------------------------------------------------------------------------

BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => ':id',
    p_method      => 'GET',
    p_source_type => ords.source_type_collection_item,
    p_source      => q'[
      SELECT e.id, e.emp_id,
             TO_CHAR(e.from_date, 'MM/DD/YYYY') from_date,
             TO_CHAR(e.to_date, 'MM/DD/YYYY') to_date,
             e.project_id, pm.project_name,
             e.amount, e.amount_usd, e.currency, e.exchange_rate,
             e.claim_for,
             (SELECT COUNT(*) FROM expense_items i WHERE i.expense_id = e.id) AS item_count,
             (SELECT COUNT(*) FROM expense_items i WHERE i.expense_id = e.id
              AND i.attachment_blob IS NULL) AS bills_without_receipt,
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
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id', p_method => 'GET',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  COMMIT;
END;
/

--------------------------------------------------------------------------------
-- 4. POST /expenses/draft
--
-- The claim header is now project_id + claim_for and nothing else. The app's
-- headerPayload() in AddEditExpenseScreen.js sends exactly those two, so the
-- description column was being written from a field that no longer exists in
-- the UI even before it was dropped from the table.
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
        l_body        CLOB    := :body_text;
        l_emp_id      NUMBER  := TO_NUMBER(:emp_id_hdr);
        l_mime        VARCHAR2(150) := JSON_VALUE(l_body, '$.attachment_mime_type');
        l_client_req  VARCHAR2(64)  := JSON_VALUE(l_body, '$.client_request_id');
        l_id          NUMBER;
        l_existing_status VARCHAR2(30);
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
            WHEN NO_DATA_FOUND THEN
              NULL;
          END;
        END IF;

        IF is_allowed_attachment(l_mime) = 'N' THEN
          :status := 422;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Attachment type not allowed: ' || l_mime);
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        -- from_date, to_date and amount are NO LONGER accepted here. They
        -- belong to the bills now, and recalc_claim_totals derives the claim's
        -- values from them. A claim is created empty and gains its dates and
        -- total when its first bill is added.
        --
        -- project_id is required because it decides the reporting manager.
        -- claim_for is required by the spec but checked here rather than by a
        -- NOT NULL column, for the same reason: a draft exists before the user
        -- has finished typing.
        IF JSON_VALUE(l_body, '$.project_id' RETURNING NUMBER) IS NULL THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Missing "project_id". A claim needs a project so its reporting manager can be resolved.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        INSERT INTO expenses (
          emp_id, project_id, claim_for, status, client_request_id
        ) VALUES (
          l_emp_id,
          JSON_VALUE(l_body, '$.project_id' RETURNING NUMBER),
          JSON_VALUE(l_body, '$.claim_for'),
          'DRAFT',
          l_client_req
        )
        RETURNING id INTO l_id;

        :status := 201;
        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.WRITE('id', l_id);
        APEX_JSON.WRITE('status', 'DRAFT');
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
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'draft', p_method => 'POST',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'draft', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT'
  );
  COMMIT;
END;
/

--------------------------------------------------------------------------------
-- 5. PUT /expenses/:id
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
        l_body        CLOB   := :body_text;
        l_emp_id      NUMBER := TO_NUMBER(:emp_id_hdr);
        l_owner_id    NUMBER;
        l_status      VARCHAR2(30);
        l_mime        VARCHAR2(150) := JSON_VALUE(l_body, '$.attachment_mime_type');
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

        -- CLAIM HEADER ONLY. Bill fields are edited through
        -- PUT /expenses/{id}/items/{itemId}; accepting them here would give two
        -- routes to the same fact, which is how the finance-manager id ended up
        -- living in three places and only one of them getting changed.
        --
        -- from_date, to_date and amount are deliberately absent: they are
        -- derived by recalc_claim_totals and would be overwritten anyway.
        UPDATE expenses SET
          project_id  = NVL(JSON_VALUE(l_body, '$.project_id' RETURNING NUMBER), project_id),
          claim_for   = NVL(JSON_VALUE(l_body, '$.claim_for'), claim_for)
        WHERE id = :id;

        :status := 200;
        APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('id', :id); APEX_JSON.WRITE('status', 'UPDATED'); APEX_JSON.CLOSE_OBJECT;
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
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id', p_method => 'PUT',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id', p_method => 'PUT',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT'
  );
  COMMIT;
END;
/

--------------------------------------------------------------------------------
-- 6. Verify -- against the handler SOURCE, which is the check that was missing.
--------------------------------------------------------------------------------

-- a) No handler in the module may still mention a dropped column.
--    MUST RETURN NO ROWS.
SELECT t.uri_template, h.method,
       CASE WHEN INSTR(LOWER(h.source), 'e.bill_no')             > 0 THEN 'bill_no '            END ||
       CASE WHEN INSTR(LOWER(h.source), 'e.bill_date')           > 0 THEN 'bill_date '          END ||
       CASE WHEN INSTR(LOWER(h.source), 'e.type')                > 0 THEN 'type '               END ||
       CASE WHEN INSTR(LOWER(h.source), 'e.description')         > 0 THEN 'description '        END ||
       CASE WHEN INSTR(LOWER(h.source), 'e.attachment_path')     > 0 THEN 'attachment_path '    END ||
       CASE WHEN INSTR(LOWER(h.source), 'e.attachment_filename') > 0 THEN 'attachment_filename 'END ||
       CASE WHEN INSTR(LOWER(h.source), 'e.attachment_mime')     > 0 THEN 'attachment_mime '    END
         AS still_references
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND   (INSTR(LOWER(h.source), 'e.bill_no')   > 0 OR INSTR(LOWER(h.source), 'e.bill_date')   > 0
    OR INSTR(LOWER(h.source), 'e.type')      > 0 OR INSTR(LOWER(h.source), 'e.description') > 0
    OR INSTR(LOWER(h.source), 'e.attachment') > 0)
ORDER  BY t.uri_template, h.method;

-- b) The INSERT and UPDATE must no longer write description.
--    MUST RETURN NO ROWS.
SELECT t.uri_template, h.method
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND    t.uri_template IN ('draft', ':id')
AND    h.method IN ('POST','PUT')
AND    INSTR(LOWER(h.source), 'description') > 0;

-- c) The five handlers are all still there, with their fields.
--    Expect Y in every column.
SELECT t.uri_template, h.method,
       CASE WHEN INSTR(h.source,'claim_for')  > 0 THEN 'Y' ELSE 'N' END AS claim_for,
       CASE WHEN INSTR(h.source,'amount_usd') > 0 THEN 'Y' ELSE 'N' END AS amount_usd,
       CASE WHEN INSTR(h.source,'item_count') > 0 THEN 'Y' ELSE 'N' END AS item_count
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND   ((t.uri_template = 'mine'    AND h.method = 'GET')
    OR (t.uri_template = 'pending' AND h.method = 'GET')
    OR (t.uri_template = ':id'     AND h.method = 'GET'))
ORDER  BY t.uri_template;

-- d) Both header parameters survived on all five. DEFINE_HANDLER replaces the
--    whole handler; parameters are re-declared above, but check rather than
--    assume. Expect 2 per row.
SELECT t.uri_template, h.method,
       (SELECT COUNT(*) FROM user_ords_parameters pa WHERE pa.handler_id = h.id) AS params
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND    t.uri_template IN ('mine','pending',':id','draft')
ORDER  BY t.uri_template, h.method;

-- e) No template left without a handler. MUST RETURN NO ROWS.
SELECT t.uri_template, COUNT(h.id) AS handlers
FROM   user_ords_templates t
JOIN   user_ords_modules m ON m.id = t.module_id
LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
WHERE  m.name = 'expenses.employee'
GROUP  BY t.uri_template HAVING COUNT(h.id) = 0;


--------------------------------------------------------------------------------
-- 7. Then reload the app. Home and Approvals should both load.
--
-- If anything still 403s, get the handler's own source before theorising -- it
-- is the one query that answers this class of fault directly:
--
--   SELECT h.method, h.source
--   FROM   user_ords_handlers h
--   JOIN   user_ords_templates t ON t.id = h.template_id
--   JOIN   user_ords_modules m   ON m.id = t.module_id
--   WHERE  m.name = 'expenses.employee' AND t.uri_template = '<the one failing>';
--
-- Then read its SELECT against user_tab_columns. Do not run a simplified
-- version of it -- that is what hid this fault for two hours.
--
--
-- STILL OUTSTANDING AFTER THIS
--
--   * HomeScreen's category breakdown groups by a claim-level `type` that no
--     longer exists. Every claim now files under "Other". Fixing it properly
--     means a bill-level aggregate -- either a new endpoint or a per-type
--     rollup on the claim. Needs a decision.
--
--   * PROD: run 70 and 71 together before the next release. Neither needs the
--     legacy columns dropped first, and both are silently wrong there today.
--------------------------------------------------------------------------------
