--------------------------------------------------------------------------------
-- 51_restore_missing_handlers.sql
--
-- Run as HRMS. Check section 1 against REPO too - if prod shows the same
-- gaps, run the whole file there as well.
--
-- WHAT IS BROKEN
-- --------------
-- Two templates in expenses.employee have no handler attached:
--
--     whoami       -> the app's identity check
--     :id/accept   -> a reviewer approving an expense
--
-- A template without a handler is a registered URL that does nothing. ORDS
-- answers, but there is no code behind it. Both are silent failures: the
-- path exists, so it does not look like a missing endpoint.
--
-- :id/accept also depends on PROCESS_EXPENSE_ACTION and GET_REVIEWER_ROLE,
-- both of which are INVALID on dev. An ORDS handler that references an
-- INVALID object cannot run, and ORDS reports that as a bare 403 or 555
-- with no body - the failure mode that cost most of a day earlier. Section 4
-- checks them; restoring the handler alone is not enough.
--
-- Handler sources are taken verbatim from PROD_4_endpoints.sql.
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- 1. Before: which templates have no handler? Run on both environments.
--------------------------------------------------------------------------------
SELECT t.uri_template,
       NVL(COUNT(h.id), 0) AS handler_count,
       LISTAGG(h.method, ', ') WITHIN GROUP (ORDER BY h.method) AS methods
FROM   user_ords_templates t
JOIN   user_ords_modules m ON m.id = t.module_id
LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
WHERE  m.name = 'expenses.employee'
GROUP  BY t.uri_template
ORDER  BY handler_count, t.uri_template;


--------------------------------------------------------------------------------
-- 2. GET /expenses/whoami
--
--    Returns the caller's own identity and role flags. The session-token
--    check is in the WHERE clause: a forged X-Emp-Id simply matches no rows
--    rather than returning someone else's identity.
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
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'whoami', p_method => 'GET',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 3. POST /expenses/{id}/accept
--
--    Whether this caller may accept THIS expense at its current stage is
--    decided inside process_expense_action, not here - the ORDS privilege
--    only gates who may reach the URL at all.
--------------------------------------------------------------------------------
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
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/accept', p_method => 'POST',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/accept', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT');

  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 4. The handler is only half the fix - check what it depends on.
--
--    Anything INVALID here means /accept will fail at request time with a
--    bare 403 or 555 and no explanatory body, even though the handler now
--    exists.
--------------------------------------------------------------------------------
SELECT object_name, object_type, status
FROM   user_objects
WHERE  object_name IN ('PROCESS_EXPENSE_ACTION','GET_REVIEWER_ROLE',
                       'IS_VALID_SESSION_TOKEN','IS_FINANCE_MANAGER',
                       'SEND_PUSH_NOTIFICATION')
ORDER  BY object_name;

-- For anything INVALID, this says why. Recompile it first:
--   ALTER FUNCTION  get_reviewer_role      COMPILE;
--   ALTER PROCEDURE process_expense_action COMPILE;
-- then re-run the query above. If still INVALID, the errors below are real
-- and the source needs fixing - PROD_3_business_logic.sql holds both.
SELECT name, type, line, position, text
FROM   user_errors
WHERE  name IN ('PROCESS_EXPENSE_ACTION','GET_REVIEWER_ROLE')
ORDER  BY name, line, position;


--------------------------------------------------------------------------------
-- 5. After: both templates should now show handler_count 1.
--------------------------------------------------------------------------------
SELECT t.uri_template,
       NVL(COUNT(h.id), 0) AS handler_count,
       LISTAGG(h.method, ', ') WITHIN GROUP (ORDER BY h.method) AS methods
FROM   user_ords_templates t
JOIN   user_ords_modules m ON m.id = t.module_id
LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
WHERE  m.name = 'expenses.employee'
  AND  t.uri_template IN ('whoami', ':id/accept')
GROUP  BY t.uri_template
ORDER  BY t.uri_template;


--------------------------------------------------------------------------------
-- 6. Live test, with a real token from a successful login:
--
--   GET  /expenses/whoami
--        Authorization: Bearer <access_token>
--        X-Emp-Id: <empid>
--        X-Session-Token: <session_token>
--        -> 200 with empid, display_name, ecode, role flags
--
--   POST /expenses/<id>/accept        (an expense genuinely awaiting you)
--        same three headers, Content-Type: application/json
--        body: {"comment":"ok"}
--        -> 200 with a result message
--
--   Then the check that matters: repeat /whoami with X-Emp-Id changed to a
--   DIFFERENT employee, keeping your own session token. It must NOT return
--   that employee's identity - the session-token predicate should match no
--   rows, so expect 404 rather than 200.
--------------------------------------------------------------------------------
