--------------------------------------------------------------------------------
-- 73_restore_missing_handlers.sql
--
-- Run as the APPLICATION SCHEMA, in SQL SCRIPTS. Idempotent.
-- Run AFTER 72_restore_currency_endpoints.sql.
--
--   dev  = karyasiddhitest.trinamix.com, schema HRMS
--   prod = karyasiddhi.trinamix.com,     schema REPO
--
--
-- TEN ENDPOINTS ARE REGISTERED AND EMPTY
-- --------------------------------------
-- Query 4b of script 72 found the real state of dev. Eleven endpoints work.
-- TEN have a template but NO HANDLER -- a URL that answers and runs nothing:
--
--   whoami            my-projects       push-token
--   :id/accept        :id/revise        :id/reject
--   bulk-accept       bulk-revise       bulk-reject
--   :id/attachment
--
-- That is why the project dropdown was empty even though its SQL returns
-- project 7288. Nothing was wrong with the query; there was nothing there to
-- run it.
--
-- The pattern explains itself: something re-ran ORDS.DEFINE_MODULE, which wipes
-- every template in the module. PROD_2_ords_and_security_setup.sql then
-- recreated all 21 TEMPLATES -- but PROD_4_endpoints.sql, which supplies the
-- HANDLERS, was never run here. So the eleven that work are exactly the ones
-- a later script happened to rebuild: 50 (login), 65 (items), 66 (claims),
-- 68/71 (lists), 72 (currency).
--
-- This is the same fault as `51_restore_missing_handlers.sql`, which fixed two
-- of these. It has now happened at scale, and the reason it keeps happening is
-- that DEFINE_MODULE is destructive and nothing warns you. DEPLOYMENT.md 13
-- says never to re-run it; that warning needs to be where people look first.
--
--
-- WHY NOT JUST RUN PROD_4_endpoints.sql
-- -------------------------------------
-- Because it would UNDO scripts 66, 68 and 71. PROD_4 holds the ORIGINAL,
-- pre-multi-bill versions of mine, pending, :id, draft and :id/submit, all of
-- which SELECT and INSERT columns that script 64 dropped. DEFINE_HANDLER
-- replaces the whole handler, so running PROD_4 would put the 403 straight
-- back -- the exact fault 71 has just cleared.
--
-- So this script installs ONLY the nine handlers that are missing AND safe,
-- lifted verbatim from PROD_4 rather than retyped, and each one checked
-- programmatically for references to the eight dropped columns before being
-- included here.
--
--
-- :id/attachment IS DELIBERATELY NOT RESTORED
-- -------------------------------------------
-- It is the CLAIM-level receipt upload, and it reads and writes
-- ATTACHMENT_BLOB, ATTACHMENT_FILENAME, ATTACHMENT_MIME_TYPE and
-- ATTACHMENT_PATH on EXPENSES -- all four dropped by script 64. Under
-- multi-bill a receipt belongs to a BILL, and that endpoint already exists and
-- works: /expenses/:id/items/:item_id/attachment.
--
-- client.js still exports uploadAttachment() and getAttachmentUrl() pointing at
-- the old URL, but nothing in src/screens calls either -- they are dead code
-- from before the rewrite. Section 3 removes the empty template so the module
-- stops advertising an endpoint that cannot work; the two client functions
-- should be deleted separately.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF


--------------------------------------------------------------------------------
-- 0. Right schema, and confirm the handlers really are missing.
--
-- If they are already present this script still runs safely -- DEFINE_HANDLER
-- replaces -- but you should know, because it would mean PROD_4 ran here since
-- 72, and that has consequences for mine/pending/:id/draft/:id/submit.
--------------------------------------------------------------------------------
DECLARE
  l_n       NUMBER;
  l_missing NUMBER := 0;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Connected as: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
  DBMS_OUTPUT.PUT_LINE('  HRMS = dev, REPO = PRODUCTION.');

  FOR p IN (SELECT column_value AS pat FROM TABLE(sys.odcivarchar2list(
              'whoami','my-projects','push-token',':id/accept',':id/revise',
              ':id/reject','bulk-accept','bulk-revise','bulk-reject')))
  LOOP
    SELECT COUNT(h.id) INTO l_n
    FROM   user_ords_templates t
    JOIN   user_ords_modules m ON m.id = t.module_id
    LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
    WHERE  m.name = 'expenses.employee' AND t.uri_template = p.pat;

    IF l_n = 0 THEN l_missing := l_missing + 1; END IF;
    DBMS_OUTPUT.PUT_LINE('  ' || RPAD(p.pat, 16) || l_n || ' handler(s)');
  END LOOP;

  DBMS_OUTPUT.PUT_LINE(l_missing || ' of 9 need restoring.');

  -- The canary. If PROD_4 has been run here, mine is back to its pre-multibill
  -- form and the 403 is back with it. Better to say so now than to have it
  -- rediscovered from the app.
  SELECT COUNT(*) INTO l_n
  FROM   user_ords_handlers h
  JOIN   user_ords_templates t ON t.id = h.template_id
  JOIN   user_ords_modules m   ON m.id = t.module_id
  WHERE  m.name = 'expenses.employee' AND t.uri_template = 'mine'
  AND    INSTR(LOWER(h.source), 'e.bill_no') > 0;

  IF l_n > 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'GET mine references e.bill_no again -- PROD_4_endpoints.sql has been run '
      || 'on this schema and has undone scripts 66/68/71. Re-run 71 (and 66 if '
      || 'draft/submit also broke) BEFORE this script. Nothing changed.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('mine is still the multi-bill version. Good.');
END;
/


--------------------------------------------------------------------------------
-- 1. The nine handlers, verbatim from PROD_4_endpoints.sql.
--
--    whoami        the identity call every screen makes on load
--    my-projects   the project dropdown -- this is the empty LOV
--    push-token    device registration
--    :id/accept | :id/revise | :id/reject          single-claim review
--    bulk-accept | bulk-revise | bulk-reject       multi-select review
--
-- None of these reference a dropped column; that was checked against the list
-- of eight before they were copied, not assumed.
--------------------------------------------------------------------------------

BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'whoami',
    p_method      => 'GET',
    p_source_type => ords.source_type_query_one_row,
    p_source      => q'{
      SELECT e.empid,
             e.first_name || ' ' || e.last_name AS display_name,
             e.ecode,
             CASE WHEN EXISTS (
               SELECT 1 FROM project_manager pm WHERE pm.project_manager_empid = e.empid
             ) THEN 'Y' ELSE 'N' END AS is_reporting_manager,
             is_finance_manager(e.empid) AS is_finance_manager
      FROM   employeedetails e
      WHERE  e.empid = TO_NUMBER(:emp_id_hdr)
      AND    is_valid_session_token(TO_NUMBER(:emp_id_hdr), :session_token_hdr) = 'Y'
    }'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'whoami', p_method => 'GET',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'whoami', p_method => 'GET',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  COMMIT;
END;
/

BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'my-projects',
    p_method      => 'GET',
    p_source_type => ords.source_type_collection_feed,
    p_source      => q'{
      SELECT DISTINCT pa.project_id,
             pm.project_name
      FROM   project_allocation_wb pa
      JOIN   projectmaster pm ON pm.project_id = pa.project_id
      WHERE  pa.emp_id = TO_NUMBER(:emp_id_hdr)
        AND  is_valid_session_token(TO_NUMBER(:emp_id_hdr), :session_token_hdr) = 'Y'
        AND  (pa.res_end_date IS NULL OR pa.res_end_date >= TRUNC(SYSDATE))
        AND  pm.status = 'ACTIVE'
      ORDER BY pm.project_name
    }'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'my-projects', p_method => 'GET',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'my-projects', p_method => 'GET',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  COMMIT;
END;
/

BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'push-token',
    p_method      => 'POST',
    p_source_type => ords.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source      => q'[
      DECLARE
        l_body   CLOB    := :body_text;
        l_emp_id NUMBER  := TO_NUMBER(:emp_id_hdr);
        l_token  VARCHAR2(255) := JSON_VALUE(l_body, '$.push_token');
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

        IF l_token IS NULL THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'Missing "push_token"'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        MERGE INTO emp_push_tokens t
        USING (SELECT l_token AS push_token FROM dual) s
        ON (t.push_token = s.push_token)
        WHEN MATCHED THEN UPDATE SET t.emp_id = l_emp_id, t.updated_at = SYSTIMESTAMP
        WHEN NOT MATCHED THEN INSERT (emp_id, push_token) VALUES (l_emp_id, l_token);

        :status := 200;
        APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('result', 'OK'); APEX_JSON.CLOSE_OBJECT;
      EXCEPTION
        WHEN OTHERS THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', SQLERRM); APEX_JSON.CLOSE_OBJECT;
      END;
    ]'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'push-token', p_method => 'POST',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'push-token', p_method => 'POST',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'push-token', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT'
  );
  COMMIT;
END;
/

BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => ':id/accept',
    p_method      => 'POST',
    p_source_type => ords.source_type_plsql,
    p_source      => q'[
      DECLARE
        l_body    CLOB   := :body_text;
        l_emp_id  NUMBER := TO_NUMBER(:emp_id_hdr);
        l_comment VARCHAR2(4000) := JSON_VALUE(l_body, '$.comment');
        l_code    NUMBER;
        l_msg     VARCHAR2(4000);
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

        process_expense_action(:id, l_emp_id, 'ACCEPTED', l_comment, l_code, l_msg);

        :status := l_code;
        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.WRITE('id', :id);
        APEX_JSON.WRITE('result', l_msg);
        APEX_JSON.CLOSE_OBJECT;
      END;
    ]'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/accept', p_method => 'POST',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/accept', p_method => 'POST',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/accept', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT'
  );
  COMMIT;
END;
/

BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => ':id/revise',
    p_method      => 'POST',
    p_source_type => ords.source_type_plsql,
    p_source      => q'[
      DECLARE
        l_body    CLOB   := :body_text;
        l_emp_id  NUMBER := TO_NUMBER(:emp_id_hdr);
        l_comment VARCHAR2(4000) := JSON_VALUE(l_body, '$.comment');
        l_code    NUMBER;
        l_msg     VARCHAR2(4000);
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

        process_expense_action(:id, l_emp_id, 'REVISED', l_comment, l_code, l_msg);

        :status := l_code;
        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.WRITE('id', :id);
        APEX_JSON.WRITE('result', l_msg);
        APEX_JSON.CLOSE_OBJECT;
      END;
    ]'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/revise', p_method => 'POST',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/revise', p_method => 'POST',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/revise', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT'
  );
  COMMIT;
END;
/

BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => ':id/reject',
    p_method      => 'POST',
    p_source_type => ords.source_type_plsql,
    p_source      => q'[
      DECLARE
        l_body    CLOB   := :body_text;
        l_emp_id  NUMBER := TO_NUMBER(:emp_id_hdr);
        l_comment VARCHAR2(4000) := JSON_VALUE(l_body, '$.comment');
        l_code    NUMBER;
        l_msg     VARCHAR2(4000);
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

        process_expense_action(:id, l_emp_id, 'REJECTED', l_comment, l_code, l_msg);

        :status := l_code;
        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.WRITE('id', :id);
        APEX_JSON.WRITE('result', l_msg);
        APEX_JSON.CLOSE_OBJECT;
      END;
    ]'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/reject', p_method => 'POST',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/reject', p_method => 'POST',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/reject', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT'
  );
  COMMIT;
END;
/

BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'bulk-accept',
    p_method      => 'POST',
    p_source_type => ords.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source      => q'{
      DECLARE
        l_body    CLOB   := :body_text;
        l_emp_id  NUMBER := TO_NUMBER(:emp_id_hdr);
        l_comment VARCHAR2(4000) := JSON_VALUE(l_body, '$.comment');
        l_code    NUMBER;
        l_msg     VARCHAR2(4000);
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

        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.OPEN_ARRAY('results');
        FOR r IN (
          SELECT expense_id
          FROM   JSON_TABLE(l_body, '$.ids[*]' COLUMNS (expense_id NUMBER PATH '$'))
        ) LOOP
          process_expense_action(r.expense_id, l_emp_id, 'ACCEPTED', l_comment, l_code, l_msg);
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('id', r.expense_id);
          APEX_JSON.WRITE('status_code', l_code);
          APEX_JSON.WRITE('message', l_msg);
          APEX_JSON.CLOSE_OBJECT;
        END LOOP;
        APEX_JSON.CLOSE_ARRAY;
        APEX_JSON.CLOSE_OBJECT;
      END;
    }'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'bulk-accept', p_method => 'POST',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'bulk-accept', p_method => 'POST',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  COMMIT;
END;
/

BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'bulk-revise',
    p_method      => 'POST',
    p_source_type => ords.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source      => q'{
      DECLARE
        l_body    CLOB   := :body_text;
        l_emp_id  NUMBER := TO_NUMBER(:emp_id_hdr);
        l_comment VARCHAR2(4000) := JSON_VALUE(l_body, '$.comment');
        l_code    NUMBER;
        l_msg     VARCHAR2(4000);
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

        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.OPEN_ARRAY('results');
        FOR r IN (
          SELECT expense_id
          FROM   JSON_TABLE(l_body, '$.ids[*]' COLUMNS (expense_id NUMBER PATH '$'))
        ) LOOP
          process_expense_action(r.expense_id, l_emp_id, 'REVISED', l_comment, l_code, l_msg);
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('id', r.expense_id);
          APEX_JSON.WRITE('status_code', l_code);
          APEX_JSON.WRITE('message', l_msg);
          APEX_JSON.CLOSE_OBJECT;
        END LOOP;
        APEX_JSON.CLOSE_ARRAY;
        APEX_JSON.CLOSE_OBJECT;
      END;
    }'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'bulk-revise', p_method => 'POST',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'bulk-revise', p_method => 'POST',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  COMMIT;
END;
/

BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'bulk-reject',
    p_method      => 'POST',
    p_source_type => ords.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source      => q'{
      DECLARE
        l_body    CLOB   := :body_text;
        l_emp_id  NUMBER := TO_NUMBER(:emp_id_hdr);
        l_comment VARCHAR2(4000) := JSON_VALUE(l_body, '$.comment');
        l_code    NUMBER;
        l_msg     VARCHAR2(4000);
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

        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.OPEN_ARRAY('results');
        FOR r IN (
          SELECT expense_id
          FROM   JSON_TABLE(l_body, '$.ids[*]' COLUMNS (expense_id NUMBER PATH '$'))
        ) LOOP
          process_expense_action(r.expense_id, l_emp_id, 'REJECTED', l_comment, l_code, l_msg);
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('id', r.expense_id);
          APEX_JSON.WRITE('status_code', l_code);
          APEX_JSON.WRITE('message', l_msg);
          APEX_JSON.CLOSE_OBJECT;
        END LOOP;
        APEX_JSON.CLOSE_ARRAY;
        APEX_JSON.CLOSE_OBJECT;
      END;
    }'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'bulk-reject', p_method => 'POST',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'bulk-reject', p_method => 'POST',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 3. Remove the obsolete claim-level attachment endpoint.
--
-- Its template exists with no handler, and no handler can be written for it:
-- all four columns it needs were dropped by script 64. Leaving an empty
-- template behind is how this whole class of fault hides -- a URL that answers
-- 404 or 555 and looks like a routing problem.
--
-- Receipts live on bills now: /expenses/:id/items/:item_id/attachment.
--------------------------------------------------------------------------------
DECLARE
  l_handlers NUMBER;
  l_exists   NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_exists
  FROM   user_ords_templates t
  JOIN   user_ords_modules m ON m.id = t.module_id
  WHERE  m.name = 'expenses.employee' AND t.uri_template = ':id/attachment';

  IF l_exists = 0 THEN
    DBMS_OUTPUT.PUT_LINE(':id/attachment already gone.');
    RETURN;
  END IF;

  SELECT COUNT(h.id) INTO l_handlers
  FROM   user_ords_templates t
  JOIN   user_ords_modules m ON m.id = t.module_id
  LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
  WHERE  m.name = 'expenses.employee' AND t.uri_template = ':id/attachment';

  -- Refuse if somebody has since attached a working handler. Deleting a live
  -- endpoint because a comment in this file said it was obsolete is exactly
  -- the kind of thing that should need a human to confirm.
  IF l_handlers > 0 THEN
    DBMS_OUTPUT.PUT_LINE('*** :id/attachment HAS ' || l_handlers || ' handler(s). '
      || 'NOT deleted. Someone has restored it -- check whether it still uses '
      || 'the dropped EXPENSES.ATTACHMENT_* columns before removing it. ***');
    RETURN;
  END IF;

  ORDS.DELETE_TEMPLATE(p_module_name => 'expenses.employee',
                       p_pattern     => ':id/attachment');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Removed the empty :id/attachment template.');
END;
/


--------------------------------------------------------------------------------
-- 4. Verify.
--------------------------------------------------------------------------------

-- a) THE WHOLE MODULE. Every endpoint the app calls, and its state.
--    Every row should say 'present, 1 handler(s)' or more.
--    :id/attachment should be gone entirely.
SELECT x.pat AS endpoint,
       NVL((SELECT 'present, ' || COUNT(h.id) || ' handler(s)'
            FROM   user_ords_templates t
            JOIN   user_ords_modules m ON m.id = t.module_id
            LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
            WHERE  m.name = 'expenses.employee' AND t.uri_template = x.pat
            GROUP  BY t.id), '** MISSING **') AS state
FROM   (SELECT column_value AS pat FROM TABLE(sys.odcivarchar2list(
          'auth/login','whoami','my-projects','currencies','exchange-rate',
          'draft','mine','pending',':id',':id/submit',
          ':id/accept',':id/revise',':id/reject','push-token',
          ':id/items',':id/items/:item_id',':id/items/:item_id/attachment',
          'bulk-accept','bulk-revise','bulk-reject'))) x
ORDER  BY 2 DESC, 1;

-- b) Nothing in the module may reference a dropped column. MUST RETURN NO ROWS.
--    This is the check that catches a PROD_4 re-run, and it is worth running
--    after ANY ORDS script from now on.
SELECT t.uri_template, h.method
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND   (INSTR(LOWER(h.source), 'e.bill_no')    > 0
    OR INSTR(LOWER(h.source), 'e.bill_date')  > 0
    OR INSTR(LOWER(h.source), 'e.type')       > 0
    OR INSTR(LOWER(h.source), 'e.description') > 0
    OR INSTR(LOWER(h.source), 'e.attachment') > 0
    OR INSTR(LOWER(h.source), 'attachment_blob') > 0)
ORDER  BY t.uri_template, h.method;

-- c) No template anywhere in the module without a handler. MUST RETURN NO ROWS.
SELECT t.uri_template, COUNT(h.id) AS handlers
FROM   user_ords_templates t
JOIN   user_ords_modules m ON m.id = t.module_id
LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
WHERE  m.name = 'expenses.employee'
GROUP  BY t.uri_template HAVING COUNT(h.id) = 0;

-- d) Header parameters on the restored handlers. Expect 2 or 3 on each.
SELECT t.uri_template, h.method,
       (SELECT COUNT(*) FROM user_ords_parameters pa WHERE pa.handler_id = h.id) AS params
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND    t.uri_template IN ('whoami','my-projects','push-token',':id/accept',
                          ':id/revise',':id/reject','bulk-accept','bulk-revise',
                          'bulk-reject')
ORDER  BY t.uri_template, h.method;

-- e) Privileges. Nothing here changed them, but the newly-live endpoints must
--    be covered or they are open to anyone. Anything UNPROTECTED -> run
--    69_restore_privileges.sql, which rebuilds from an explicit list.
SELECT x.pat AS pattern,
       NVL((SELECT MAX(pr.name) FROM user_ords_privilege_mappings pm
            JOIN   user_ords_privileges pr ON pr.id = pm.privilege_id
            WHERE  pm.pattern = '/expenses/' || x.pat), '** UNPROTECTED **') AS privilege
FROM   (SELECT column_value AS pat FROM TABLE(sys.odcivarchar2list(
          'whoami','my-projects','push-token',':id/accept',':id/revise',
          ':id/reject','bulk-accept','bulk-revise','bulk-reject'))) x
ORDER  BY 2, 1;


--------------------------------------------------------------------------------
-- 5. Then reload the app. In this order, because each proves the next is worth
--    trying:
--
--   1. Log in                      -> auth/login          (already worked)
--   2. Home loads                  -> whoami, mine
--   3. Project dropdown fills      -> my-projects          THE ONE THAT WAS EMPTY
--   4. Currency dropdown fills     -> currencies           12 + USD
--   5. Type an amount              -> exchange-rate        rate and USD appear
--   6. Add a bill, save            -> :id/items
--   7. Attach a receipt            -> :id/items/:item_id/attachment
--   8. Submit                      -> :id/submit
--   9. Approvals tab               -> pending
--  10. Accept                      -> :id/accept
--
-- Step 10 will not complete on project 7288: it has no project manager, so the
-- claim has nobody to approve it at the MANAGER stage. Get your allocation on
-- 2386 extended -- it expired 11-Aug and it has a real manager -- or have a
-- PROJECT_MANAGER row added for 7288. Until then steps 1-8 are testable and
-- 9-10 are not.
--
--
-- AND THE THING TO FIX PROPERLY
--
-- Three rounds of this have all traced back to ORDS.DEFINE_MODULE being
-- destructive and silent. MASTER_DEPLOY.sql calls it. Anyone who runs
-- MASTER_DEPLOY on a schema that already has this app installed will empty the
-- whole module again, and the symptoms will arrive as 403s, 555s and empty
-- dropdowns that all look like something else.
--
-- MASTER_DEPLOY needs a guard at the top: if the module already exists with
-- handlers, refuse to run and say why. That is a small change and it removes an
-- entire category of failure.
--------------------------------------------------------------------------------
