--------------------------------------------------------------------------------
-- 53_finance_manager_single_source.sql
--
-- Run as the application schema. Idempotent.
--
-- SYMPTOM
-- -------
-- is_finance_manager was changed to return 'Y' for 3725, but expenses in the
-- app still show the previous finance manager's name.
--
-- CAUSE
-- -----
-- The employee id 3680 was written in THREE places, and the function is only
-- one of them:
--
--   1. is_finance_manager()                       -- who MAY act as finance
--   2. EXPENSES.FINANCE_MANAGER_EMPID column DEFAULT 3680
--   3. the :id/submit handler, literally:  finance_manager_empid = 3680
--
-- (1) decides whether someone is ALLOWED to approve. (2) and (3) decide who the
-- expense is ROUTED to and whose name the app displays. Changing only (1) makes
-- 3725 able to approve while every expense still points at 3680 -- which is
-- exactly the reported symptom, and why approving still worked.
--
-- This script makes (1) the only place the id appears, so the next change is
-- one line in one object.
--
-- BEFORE RUNNING: set c_finance_manager in section 1 to the correct EMPID for
-- THIS environment. Dev and prod may legitimately differ.
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- 1. One function, one place, both questions answered.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_finance_manager_empid RETURN NUMBER IS
  -- >>> THE ONLY PLACE THIS ID SHOULD EVER APPEAR <<<
  c_finance_manager CONSTANT NUMBER := 3725;
BEGIN
  RETURN c_finance_manager;
END get_finance_manager_empid;
/

CREATE OR REPLACE FUNCTION is_finance_manager(p_emp_id IN NUMBER) RETURN VARCHAR2 IS
BEGIN
  RETURN CASE WHEN p_emp_id = get_finance_manager_empid() THEN 'Y' ELSE 'N' END;
END is_finance_manager;
/


--------------------------------------------------------------------------------
-- 2. Column default.
--
--    A DEFAULT cannot call a function, so it has to be a literal -- but it only
--    applies to rows inserted without an explicit value, and the submit handler
--    below always sets one. Cleared rather than left pointing at a stale id, so
--    a row can never quietly acquire the wrong finance manager.
--------------------------------------------------------------------------------
DECLARE
  l_default LONG;
BEGIN
  SELECT data_default INTO l_default
  FROM   user_tab_columns
  WHERE  table_name = 'EXPENSES' AND column_name = 'FINANCE_MANAGER_EMPID';

  DBMS_OUTPUT.PUT_LINE('Old column default: ' || NVL(TRIM(l_default), '(none)'));

  EXECUTE IMMEDIATE 'ALTER TABLE expenses MODIFY (finance_manager_empid DEFAULT NULL)';
  DBMS_OUTPUT.PUT_LINE('Column default cleared -- the submit handler now sets it.');
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    DBMS_OUTPUT.PUT_LINE('EXPENSES.FINANCE_MANAGER_EMPID not found -- wrong schema?');
END;
/


--------------------------------------------------------------------------------
-- 3. The submit handler.
--
--    Only the one line changes: the literal becomes the function call. The rest
--    of the handler is reproduced verbatim from PROD_4_endpoints.sql, because
--    ORDS.DEFINE_HANDLER replaces the whole body -- there is no way to patch a
--    single line of a stored handler.
--
--    If PROD_4's submit handler has been edited since, re-copy it here first,
--    or that edit is silently reverted.
--------------------------------------------------------------------------------
DECLARE
  l_src CLOB;
BEGIN
  SELECT h.source INTO l_src
  FROM   user_ords_handlers h
  JOIN   user_ords_templates t ON t.id = h.template_id
  JOIN   user_ords_modules m   ON m.id = t.module_id
  WHERE  m.name = 'expenses.employee'
  AND    t.uri_template = ':id/submit'
  AND    h.method = 'POST';

  IF INSTR(l_src, 'finance_manager_empid = 3680') > 0 THEN
    DBMS_OUTPUT.PUT_LINE('Submit handler hardcodes 3680 -- being replaced below.');
  ELSIF INSTR(l_src, 'get_finance_manager_empid') > 0 THEN
    DBMS_OUTPUT.PUT_LINE('Submit handler already uses the function. Re-applying is harmless.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('WARNING: submit handler matches neither pattern -- it may have been');
    DBMS_OUTPUT.PUT_LINE('edited since PROD_4. Compare it before letting this replace it.');
  END IF;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    DBMS_OUTPUT.PUT_LINE('No :id/submit POST handler found.');
END;
/

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

          BEGIN
            SELECT company_email INTO l_emp_email FROM employeedetails WHERE empid = l_emp_id;
            IF l_manager_id IS NOT NULL THEN
              SELECT company_email INTO l_mgr_email FROM employeedetails WHERE empid = l_manager_id;
            END IF;

            IF l_emp_email IS NOT NULL THEN
              APEX_MAIL.SEND(p_to => l_emp_email, p_from => l_emp_email,
                p_subj => 'Expense #' || :id || ' submitted',
                p_body => 'Your expense has been submitted for approval.');
            END IF;
            IF l_mgr_email IS NOT NULL THEN
              APEX_MAIL.SEND(p_to => l_mgr_email, p_from => l_emp_email,
                p_subj => 'Expense #' || :id || ' awaiting your approval',
                p_body => 'An expense has been submitted and needs your review.');
            END IF;
          EXCEPTION
            WHEN OTHERS THEN NULL;
          END;

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
-- 4. Existing rows.
--
--    Only rows still IN FLIGHT are repointed. APPROVED and REJECTED expenses
--    are history: rewriting who approved them would falsify the audit trail,
--    and EXPENSE_APPROVALS already records who actually acted.
--
--    Review the SELECT before running the UPDATE.
--------------------------------------------------------------------------------
SELECT status,
       current_stage,
       finance_manager_empid,
       COUNT(*) AS rows_affected
FROM   expenses
WHERE  status IN ('DRAFT', 'SUBMITTED', 'REVISION_REQUESTED')
AND    NVL(finance_manager_empid, -1) != get_finance_manager_empid()
GROUP  BY status, current_stage, finance_manager_empid
ORDER  BY status;

UPDATE expenses
SET    finance_manager_empid = get_finance_manager_empid()
WHERE  status IN ('DRAFT', 'SUBMITTED', 'REVISION_REQUESTED')
AND    NVL(finance_manager_empid, -1) != get_finance_manager_empid();

COMMIT;


--------------------------------------------------------------------------------
-- 5. After: nothing in flight should point anywhere else.
--------------------------------------------------------------------------------
SELECT get_finance_manager_empid() AS configured,
       (SELECT first_name || ' ' || last_name FROM employeedetails
        WHERE empid = get_finance_manager_empid()) AS name,
       (SELECT COUNT(*) FROM expenses
        WHERE status IN ('DRAFT','SUBMITTED','REVISION_REQUESTED')
        AND   NVL(finance_manager_empid, -1) != get_finance_manager_empid()) AS still_wrong
FROM   dual;

SELECT object_name, status FROM user_objects
WHERE  object_name IN ('GET_FINANCE_MANAGER_EMPID','IS_FINANCE_MANAGER','PROCESS_EXPENSE_ACTION')
ORDER  BY object_name;


--------------------------------------------------------------------------------
-- NOTE ON SECTION 3
--
-- The handler body there is copied byte-for-byte from PROD_4_endpoints.sql with
-- exactly two lines changed: l_finance_id is assigned from the function, and the
-- UPDATE uses it instead of the literal. Everything else -- the
-- REVISION_REQUESTED branch, both APEX_MAIL sends, all four push
-- notifications -- is untouched.
--
-- This matters because ORDS.DEFINE_HANDLER replaces the entire body. There is no
-- way to patch one line of a stored handler, so anything missing from the
-- replacement is silently deleted from the live endpoint. If PROD_4's submit
-- handler has been edited since this script was written, re-copy it here first.
--------------------------------------------------------------------------------
