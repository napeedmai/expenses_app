--------------------------------------------------------------------------------
-- 57_email_wire_workflow.sql
--
-- Run as the application schema, AFTER 56_email_notifications.sql. Idempotent.
--
-- 56 created send_expense_mail. Nothing calls it until this script runs.
--
-- This replaces the six inline APEX_MAIL.SEND blocks with four calls to that
-- one procedure, in:
--
--   * process_expense_action        -- accept / revise / reject
--   * the POST /expenses/{id}/submit ORDS handler
--
-- Both bodies below are copied BYTE FOR BYTE from PROD_3_business_logic.sql
-- and PROD_4_endpoints.sql, which now carry the same change -- so a fresh
-- MASTER_DEPLOY.sql install and an existing environment end up identical.
--
-- This matters for the handler especially: ORDS.DEFINE_HANDLER replaces the
-- ENTIRE body, so anything missing from the replacement is silently deleted
-- from the live endpoint. Do not retype it from memory.
--
--
-- WHAT CHANGES IN BEHAVIOUR
-- -------------------------
--   BEFORE                                  AFTER
--   submit    -> employee + manager         -> TO manager, CC employee
--   mgr accept-> (no email at all)          -> TO finance, CC manager+employee
--   fin accept-> employee + manager         -> TO employee, CC manager
--   revised   -> manager + finance          -> TO employee, CC manager if
--                (NOT the employee)            Finance asked for it
--   rejected  -> manager + finance          -> TO employee, CC manager if
--                (NOT the employee)            Finance rejected it
--
-- The two REVISED/REJECTED rows are the important ones. The person who had to
-- fix or was denied the claim was never told.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON


--------------------------------------------------------------------------------
-- 0. Prerequisites. Stops with a clear message rather than compiling something
--    that references a procedure which does not exist.
--------------------------------------------------------------------------------
DECLARE
  l_n       NUMBER;
  l_missing VARCHAR2(400);
  l_schema  VARCHAR2(128) := SYS_CONTEXT('USERENV','CURRENT_SCHEMA');
BEGIN
  DBMS_OUTPUT.PUT_LINE('Connected as: ' || l_schema);
  DBMS_OUTPUT.PUT_LINE('This must be the schema the APP uses -- the one in');
  DBMS_OUTPUT.PUT_LINE('src/config.js API_BASE_URL. Wrong schema is the most common');
  DBMS_OUTPUT.PUT_LINE('cause of confusing errors from these scripts.');
  DBMS_OUTPUT.PUT_LINE(' ');

  -- process_expense_action calls send_expense_mail AND send_push_notification.
  -- PL/SQL will not compile a procedure that references an INVALID object: it
  -- fails with PLS-00905, once per call site, which reads as several unrelated
  -- errors rather than one missing dependency.
  FOR d IN (SELECT column_value AS name FROM TABLE(sys.odcivarchar2list(
              'SEND_EXPENSE_MAIL', 'SEND_PUSH_NOTIFICATION', 'JSON_ESCAPE_STR',
              'GET_REVIEWER_ROLE', 'GET_FINANCE_MANAGER_EMPID', 'IS_FINANCE_MANAGER')))
  LOOP
    SELECT COUNT(*) INTO l_n FROM user_objects
    WHERE  object_name = d.name AND status = 'VALID';

    IF l_n = 0 THEN
      l_missing := l_missing || d.name || ' ';
      DBMS_OUTPUT.PUT_LINE('  MISSING or INVALID: ' || d.name);
    ELSE
      DBMS_OUTPUT.PUT_LINE('  ok: ' || d.name);
    END IF;
  END LOOP;

  IF l_missing IS NOT NULL THEN
    DBMS_OUTPUT.PUT_LINE(' ');
    RAISE_APPLICATION_ERROR(-20001,
      'Cannot proceed on ' || l_schema || '. Missing or INVALID: ' || l_missing
      || '-- process_expense_action cannot compile while any dependency is invalid. '
      || 'If SEND_PUSH_NOTIFICATION or JSON_ESCAPE_STR is the problem, this schema '
      || 'never received the push feature: run MASTER_DEPLOY.sql here first, or '
      || 'connect to the schema the app actually uses. '
      || 'If SEND_EXPENSE_MAIL is the problem, run 56_email_notifications.sql first.');
  END IF;

  SELECT COUNT(*) INTO l_n FROM app_secrets WHERE secret_name = 'MAIL_WORKSPACE';
  IF l_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE('WARNING: APP_SECRETS.MAIL_WORKSPACE is not set.');
    DBMS_OUTPUT.PUT_LINE('APEX_MAIL.SEND needs a workspace and will fail without it.');
    DBMS_OUTPUT.PUT_LINE('See 56_email_notifications.sql section 2.');
  END IF;

  DBMS_OUTPUT.PUT_LINE(' ');
  DBMS_OUTPUT.PUT_LINE('Prerequisites OK on ' || l_schema || '.');
END;
/


--------------------------------------------------------------------------------
-- 1. process_expense_action -- accept / revise / reject.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE process_expense_action(
  p_expense_id  IN  NUMBER,
  p_emp_id      IN  NUMBER,
  p_action      IN  VARCHAR2,   -- 'ACCEPTED' | 'REVISED' | 'REJECTED'
  p_comment     IN  VARCHAR2,
  p_result_code OUT NUMBER,
  p_result_msg  OUT VARCHAR2
) IS
  l_status         VARCHAR2(30);
  l_role           VARCHAR2(30);
  l_emp_owner      NUMBER;
  l_manager_empid  NUMBER;
  l_finance_empid  NUMBER;
  l_emp_email      VARCHAR2(255);
  l_mgr_email      VARCHAR2(255);
  l_fin_email      VARCHAR2(255);
BEGIN
  BEGIN
    SELECT status, emp_id, manager_empid, finance_manager_empid
    INTO   l_status, l_emp_owner, l_manager_empid, l_finance_empid
    FROM   expenses
    WHERE  id = p_expense_id
    FOR UPDATE;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      p_result_code := 404;
      p_result_msg  := 'Expense ' || p_expense_id || ' not found';
      RETURN;
  END;

  IF l_status != 'SUBMITTED' THEN
    p_result_code := 409;
    p_result_msg  := 'Expense ' || p_expense_id || ' is not awaiting review (current status: ' || l_status || ')';
    RETURN;
  END IF;

  l_role := get_reviewer_role(p_expense_id, p_emp_id);
  IF l_role IS NULL THEN
    p_result_code := 403;
    p_result_msg  := 'You are not the assigned reviewer for expense ' || p_expense_id || ' at its current stage';
    RETURN;
  END IF;

  INSERT INTO expense_approvals (expense_id, approver_id, role, action, comments)
  VALUES (p_expense_id, p_emp_id, l_role, p_action, p_comment);

  IF p_action = 'ACCEPTED' THEN
    IF l_role = 'PROJECT_MANAGER' THEN
      UPDATE expenses SET current_stage = 'FINANCE' WHERE id = p_expense_id;

      -- Previously this transition sent NO email at all -- the finance
      -- manager was told by push only, so with push unavailable nobody
      -- knew a claim was waiting for them.
      send_expense_mail(p_expense_id, 'MANAGER_ACCEPTED', p_emp_id, p_comment);

      send_push_notification(l_emp_owner, 'Approved by Manager',
        'Your expense #' || p_expense_id || ' was approved by your project manager — now with Finance.', p_expense_id);
      IF l_finance_empid IS NOT NULL THEN
        send_push_notification(l_finance_empid, 'Approval Needed',
          'An expense approved by its project manager is waiting for your review.', p_expense_id);
      END IF;

    ELSE -- FINANCE_MANAGER accepting = final approval
      UPDATE expenses SET status = 'APPROVED', current_stage = NULL WHERE id = p_expense_id;

      send_expense_mail(p_expense_id, 'FINANCE_ACCEPTED', p_emp_id, p_comment);

      send_push_notification(l_emp_owner, 'Expense Approved',
        'Your expense #' || p_expense_id || ' was fully approved.', p_expense_id);
    END IF;

  ELSIF p_action = 'REVISED' THEN
    UPDATE expenses SET status = 'REVISION_REQUESTED' WHERE id = p_expense_id;

    -- Was mailed to the manager and Finance, and NOT to the employee -- the
    -- one person who has to act on it.
    send_expense_mail(p_expense_id, 'REVISED', p_emp_id, p_comment);

    send_push_notification(l_emp_owner, 'Revision Needed',
      'Your expense #' || p_expense_id || ' needs changes before it can be approved.' ||
      CASE WHEN p_comment IS NOT NULL THEN ' Comment: ' || p_comment ELSE '' END,
      p_expense_id);

  ELSIF p_action = 'REJECTED' THEN
    UPDATE expenses SET status = 'REJECTED', current_stage = NULL WHERE id = p_expense_id;

    -- Same fix: the employee was never told their claim was rejected.
    send_expense_mail(p_expense_id, 'REJECTED', p_emp_id, p_comment);

    send_push_notification(l_emp_owner, 'Expense Rejected',
      'Your expense #' || p_expense_id || ' was rejected.' ||
      CASE WHEN p_comment IS NOT NULL THEN ' Comment: ' || p_comment ELSE '' END,
      p_expense_id);
  END IF;

  p_result_code := 200;
  p_result_msg  := 'OK';
EXCEPTION
  WHEN OTHERS THEN
    p_result_code := 400;
    p_result_msg  := SQLERRM;
END process_expense_action;
/


--------------------------------------------------------------------------------
-- 2. POST /expenses/{id}/submit
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => ':id/submit',
    p_method      => 'POST',
    p_source_type => ords.source_type_plsql,
    p_source      => q'[
      DECLARE
        l_emp_id        NUMBER := TO_NUMBER(:emp_id_hdr);
        l_owner_id      NUMBER;
        l_status        VARCHAR2(30);
        l_current_stage VARCHAR2(20);
        l_project_id    NUMBER;
        l_manager_id    NUMBER;
        l_finance_id    NUMBER;
        l_emp_email     VARCHAR2(255);
        l_mgr_email     VARCHAR2(255);
      BEGIN
        IF is_valid_session_token(l_emp_id, :session_token_hdr) != 'Y' THEN
          :status := 401;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'Session expired or invalid. Please log in again.'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        SELECT emp_id, status, current_stage, project_id, manager_empid, finance_manager_empid
        INTO   l_owner_id, l_status, l_current_stage, l_project_id, l_manager_id, l_finance_id
        FROM   expenses WHERE id = :id FOR UPDATE;

        IF l_owner_id != l_emp_id THEN
          :status := 403;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'Not your expense'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        IF l_status = 'DRAFT' THEN
          l_manager_id := get_project_manager_empid(l_project_id);
          l_finance_id := get_finance_manager_empid();

          UPDATE expenses
          SET status = 'SUBMITTED',
              current_stage = 'MANAGER',
              manager_empid = l_manager_id,
              finance_manager_empid = l_finance_id,
              submitted_by = l_emp_id,
              submitted_at = SYSTIMESTAMP
          WHERE id = :id;

          -- TO the project manager, CC the employee. See send_expense_mail.
          send_expense_mail(:id, 'SUBMITTED', l_emp_id);

          send_push_notification(l_emp_id, 'Expense Submitted',
            'Your expense #' || :id || ' was submitted for approval.', :id);
          IF l_manager_id IS NOT NULL THEN
            send_push_notification(l_manager_id, 'Approval Needed',
              'An expense from your project is waiting for your approval.', :id);
          END IF;

        ELSIF l_status = 'REVISION_REQUESTED' THEN
          UPDATE expenses SET status = 'SUBMITTED' WHERE id = :id;

          send_push_notification(l_emp_id, 'Expense Resubmitted',
            'Your expense #' || :id || ' was resubmitted for approval.', :id);

          IF l_current_stage = 'MANAGER' AND l_manager_id IS NOT NULL THEN
            send_push_notification(l_manager_id, 'Approval Needed',
              'A revised expense is waiting for your approval.', :id);
          ELSIF l_current_stage = 'FINANCE' AND l_finance_id IS NOT NULL THEN
            send_push_notification(l_finance_id, 'Approval Needed',
              'A revised expense is waiting for your approval.', :id);
          END IF;

        ELSE
          :status := 409;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Cannot submit an expense in status ' || l_status);
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        :status := 200;
        APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('id', :id); APEX_JSON.WRITE('status', 'SUBMITTED'); APEX_JSON.CLOSE_OBJECT;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          :status := 404;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'Expense not found'); APEX_JSON.CLOSE_OBJECT;
      END;
    ]'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/submit', p_method => 'POST',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/submit', p_method => 'POST',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/submit', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT'
  );
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 3. Verify.
--------------------------------------------------------------------------------
SELECT object_name, object_type, status
FROM   user_objects
WHERE  object_name IN ('PROCESS_EXPENSE_ACTION','SEND_EXPENSE_MAIL')
ORDER  BY object_name;

-- The live handler should now call send_expense_mail and contain no APEX_MAIL.
SELECT CASE WHEN INSTR(h.source, 'send_expense_mail') > 0 THEN 'Y' ELSE 'N' END AS uses_new_mail,
       CASE WHEN INSTR(h.source, 'APEX_MAIL') > 0 THEN 'Y' ELSE 'N' END        AS still_inline
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND    t.uri_template = ':id/submit'
AND    h.method = 'POST';


--------------------------------------------------------------------------------
-- 4. Test it for real.
--
-- Submit an expense from the app, then read the log. This is the part that was
-- previously invisible -- every attempt is recorded, including the failures.
--
--   SELECT created_at, event, status, mail_to, mail_cc, error_text
--   FROM   expense_mail_log
--   ORDER  BY id DESC FETCH FIRST 20 ROWS ONLY;
--
-- status QUEUED  -> accepted by APEX but PUSH_QUEUE did not confirm
-- status PUSHED  -> handed to the mail server
-- status FAILED  -> error_text has the full stack
-- status SKIPPED -> nobody to send to; usually a missing COMPANY_EMAIL
--
-- If rows say PUSHED and no mail arrives, the problem is past the database:
-- the SMTP server, its network ACL, or spam filtering of the MAIL_FROM address.
--------------------------------------------------------------------------------
