--------------------------------------------------------------------------------
-- 84_drop_push.sql
--
-- Run as the APPLICATION SCHEMA, in SQL SCRIPTS. Idempotent.
-- Run BEFORE the rename (85). DEV FIRST.
--
--   dev  = karyasiddhitest.trinamix.com, schema HRMS
--   prod = karyasiddhi.trinamix.com,     schema REPO
--
--
-- THE FOUR "CONFIDENT" DROPS WERE NOT FOUR ISOLATED OBJECTS
-- ---------------------------------------------------------
-- I proposed dropping EMP_PUSH_TOKENS, SEND_PUSH_NOTIFICATION,
-- TEST_PUSH_NOTIFICATION and the client file, and called them confident. The
-- inventory says otherwise:
--
--   SEND_PUSH_NOTIFICATION   IN_HANDLERS 1   CALLED_BY_PLSQL 1   in use
--
-- It is called TEN times in two places that both matter:
--
--   * process_expense_action -- 6 calls, on every accept/revise/reject
--   * the POST /expenses/{id}/submit handler -- 4 calls
--
-- A bare DROP PROCEDURE would have left both INVALID, and an ORDS handler
-- referencing an invalid object returns a bare 403 with no body. That is the
-- exact failure that cost two days on this project, and I would have caused it
-- again by trusting my own summary instead of the dependency count.
--
-- Only TEST_PUSH_NOTIFICATION was genuinely orphaned (0/0, and already
-- INVALID). So the order here is: unwire, then drop.
--
--
-- WHAT THIS CHANGES ABOUT BEHAVIOUR: NOTHING
-- ------------------------------------------
-- EMP_PUSH_TOKENS has 0 rows. Push was removed from the app, so no device has
-- registered a token, so send_push_notification has been looping over an empty
-- cursor on every approval for weeks. Removing it removes work that already
-- did nothing.
--
--
-- ONE THING IT MAKES VISIBLE -- READ THIS
-- ---------------------------------------
-- Resubmitting a claim after REVISION_REQUESTED notified people by PUSH ONLY.
-- There is no send_expense_mail call on that path at all. So today, with zero
-- device tokens, a resubmitted claim silently tells nobody -- the manager is
-- not emailed and never finds out.
--
-- This script does NOT fix that. Adding the mail is a workflow change, not a
-- cleanup, and it needs a decision (a claim resubmitted at the FINANCE stage
-- should go to the finance manager, not back to the project manager, so it is
-- not simply a copy of the SUBMITTED branch). Flagged deliberately rather than
-- smuggled into a drop script. Say the word and it becomes script 88.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF


--------------------------------------------------------------------------------
-- 1. Pre-flight. Read-only, and it refuses to guess.
--
-- Everything below rewrites two objects from source I have in the repo. That is
-- only safe if what is DEPLOYED is the version I think it is -- the repo has
-- been wrong about this schema three times. So: check for landmarks first, and
-- stop if they are missing.
--------------------------------------------------------------------------------
DECLARE
  l_proc_push   NUMBER;
  l_hdl_push    NUMBER;
  l_hdl_ids     NUMBER;
  l_prod4       NUMBER := 0;
  l_tokens      NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_proc_push FROM user_source
  WHERE  name = 'PROCESS_EXPENSE_ACTION'
  AND    INSTR(LOWER(text), 'send_push_notification') > 0;

  SELECT COUNT(*) INTO l_hdl_push FROM user_ords_handlers h
  JOIN   user_ords_templates t ON t.id = h.template_id
  JOIN   user_ords_modules   m ON m.id = t.module_id
  WHERE  m.name = 'expenses.employee' AND t.uri_template = ':id/submit'
  AND    h.method = 'POST'
  AND    DBMS_LOB.INSTR(LOWER(h.source), 'send_push_notification') > 0;

  -- Script 62's fix. If this is absent, the deployed submit handler PREDATES
  -- 62 and replacing it with the text below would silently undo that fix.
  SELECT COUNT(*) INTO l_hdl_ids FROM user_ords_handlers h
  JOIN   user_ords_templates t ON t.id = h.template_id
  JOIN   user_ords_modules   m ON m.id = t.module_id
  WHERE  m.name = 'expenses.employee' AND t.uri_template = ':id/submit'
  AND    h.method = 'POST'
  AND    DBMS_LOB.INSTR(h.source, 'l_manager_id, l_finance_id, SYSTIMESTAMP') > 0;

  SELECT COUNT(*) INTO l_tokens FROM emp_push_tokens;

  DBMS_OUTPUT.PUT_LINE('push calls in process_expense_action : ' || l_proc_push);
  DBMS_OUTPUT.PUT_LINE('submit handler still pushes          : ' || l_hdl_push);
  DBMS_OUTPUT.PUT_LINE('submit handler is the script-62 one  : ' || l_hdl_ids);
  DBMS_OUTPUT.PUT_LINE('rows in EMP_PUSH_TOKENS              : ' || l_tokens);

  IF l_hdl_push > 0 AND l_hdl_ids = 0 THEN
    -- Pushes, and has no sign of script 62. Two very different situations, and
    -- refusing on both was wrong.
    --
    -- On PROD this is expected: PROD_MIGRATE_AUG2026 carried scripts 69-77 and
    -- never included 62, so prod's handler is the PROD_4_endpoints version.
    -- That is a KNOWN OLDER handler, not an unknown one, and section 4 of this
    -- script installs a strictly better replacement -- 62's fix AND no push.
    --
    -- Worth being blunt about what that means: prod currently has script 62's
    -- bug. send_expense_mail is autonomous, so on submit it re-reads a row the
    -- handler has not committed yet, sees a draft with no manager, and emails
    -- the employee to say no project manager is assigned. Nobody has hit it
    -- because prod has one draft claim and no submissions. This script fixes it
    -- on the way past.
    SELECT COUNT(*) INTO l_prod4 FROM user_ords_handlers h
    JOIN   user_ords_templates t ON t.id = h.template_id
    JOIN   user_ords_modules   m ON m.id = t.module_id
    WHERE  m.name LIKE 'expenses%' AND t.uri_template = ':id/submit'
    AND    h.method = 'POST'
    AND    DBMS_LOB.INSTR(h.source, 'Cannot submit an expense in status') > 0
    AND    DBMS_LOB.INSTR(LOWER(h.source), 'get_project_manager_empid') > 0;

    IF l_prod4 = 0 THEN
      RAISE_APPLICATION_ERROR(-20001,
        'The deployed :id/submit handler still pushes, has no sign of script 62, '
        || 'and does not look like the PROD_4_endpoints version either. It is a '
        || 'version I do not have. Send me its source before running this -- '
        || 'replacing it blind would undo whatever it does.');
    END IF;

    DBMS_OUTPUT.PUT_LINE('** submit handler predates script 62 (expected on '
      || 'prod). Section 4 installs 62''s fix as well as removing push. **');
  END IF;

  IF l_tokens > 0 THEN
    DBMS_OUTPUT.PUT_LINE('** ' || l_tokens || ' device token(s) exist. Push is '
      || 'NOT as dead as the plan assumed -- check who is registered before '
      || 'continuing.');
  END IF;
END;
/


--------------------------------------------------------------------------------
-- 2. Remove the push-token endpoint.
--
-- Handler first, then template. ORDS.DELETE_TEMPLATE DOES NOT EXIST -- script
-- 73 raised PLS-00302 assuming it did, and the failure was silent. The real
-- call is ORDS.DELETE_MODULE for a whole module, and for one template the
-- supported route is DEFINE_TEMPLATE's absence... so instead of deleting the
-- template we leave it and give it a handler that answers 410 Gone, exactly as
-- script 77 did for the retired attachment endpoint.
--
-- A 410 is better than a 404 here: it tells an old app build that the endpoint
-- was removed on purpose rather than that it got the URL wrong.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'push-token',
    p_method      => 'POST',
    p_source_type => ords.source_type_plsql,
    p_source      => q'[
      BEGIN
        :status := 410;
        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.WRITE('error',
          'Push notifications were removed from this application. '
          || 'Nothing needs to be registered.');
        APEX_JSON.CLOSE_OBJECT;
      END;
    ]'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'push-token', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT'
  );
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('push-token now answers 410 Gone.');
END;
/


--------------------------------------------------------------------------------
-- 3. process_expense_action, without the six push calls.
--
-- Verbatim from 62_email_autonomous_read_fix.sql apart from those calls. The
-- mail calls, the FOR UPDATE lock, the role check and every status code are
-- unchanged -- this is the procedure the whole approval workflow runs through
-- and it was only just proved working after the CK_APPROVALS_ROLE fix.
--
-- l_emp_owner is kept even though only the push calls read it: it is populated
-- by the SELECT INTO above, and trimming the column list is a change to the
-- locking SELECT for no benefit.
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

      send_expense_mail(p_expense_id, 'MANAGER_ACCEPTED', p_emp_id, p_comment, l_role,
                        l_manager_empid, l_finance_empid);

    ELSE -- FINANCE_MANAGER accepting = final approval
      UPDATE expenses SET status = 'APPROVED', current_stage = NULL WHERE id = p_expense_id;

      send_expense_mail(p_expense_id, 'FINANCE_ACCEPTED', p_emp_id, p_comment, l_role,
                        l_manager_empid, l_finance_empid);
    END IF;

  ELSIF p_action = 'REVISED' THEN
    UPDATE expenses SET status = 'REVISION_REQUESTED' WHERE id = p_expense_id;

    send_expense_mail(p_expense_id, 'REVISED', p_emp_id, p_comment, l_role,
                        l_manager_empid, l_finance_empid);

  ELSIF p_action = 'REJECTED' THEN
    UPDATE expenses SET status = 'REJECTED', current_stage = NULL WHERE id = p_expense_id;

    send_expense_mail(p_expense_id, 'REJECTED', p_emp_id, p_comment, l_role,
                        l_manager_empid, l_finance_empid);
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
-- 4. POST /expenses/{id}/submit, without the four push calls.
--
-- Script 62's fix is preserved exactly: manager_empid, finance_empid and
-- submitted_at are passed to send_expense_mail explicitly, because that
-- procedure is AUTONOMOUS and would otherwise re-read an uncommitted row, see
-- a draft with no manager, and email the employee saying no project manager
-- was assigned.
--
-- The REVISION_REQUESTED branch now contains only its UPDATE. That is the gap
-- described in the header: resubmission notifies nobody. It notified nobody
-- before this script either, because there are no device tokens -- the code
-- just looked like it did something.
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

          -- TO the project manager, CC the employee. The ids are passed
          -- explicitly because send_expense_mail is autonomous and the UPDATE
          -- above is not committed yet. See script 62.
          send_expense_mail(:id, 'SUBMITTED', l_emp_id, NULL, NULL,
                            l_manager_id, l_finance_id, SYSTIMESTAMP);

        ELSIF l_status = 'REVISION_REQUESTED' THEN
          UPDATE expenses SET status = 'SUBMITTED' WHERE id = :id;

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
  DBMS_OUTPUT.PUT_LINE('submit handler rewritten without push.');
END;
/


--------------------------------------------------------------------------------
-- 5. NOW nothing references push. Drop it.
--
-- The check is re-run rather than assumed: sections 3 and 4 could have failed
-- and this script would still reach here, because SQL Scripts does not stop on
-- a compile error.
--------------------------------------------------------------------------------
DECLARE
  l_refs NUMBER;
  PROCEDURE drop_it(p_kind IN VARCHAR2, p_name IN VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE 'DROP ' || p_kind || ' ' || p_name;
    DBMS_OUTPUT.PUT_LINE('dropped ' || LOWER(p_kind) || ' ' || p_name);
  EXCEPTION
    WHEN OTHERS THEN
      -- ORA-04043 / ORA-00942: already gone. Anything else is real.
      IF SQLCODE IN (-4043, -942) THEN
        DBMS_OUTPUT.PUT_LINE(p_name || ' was already gone.');
      ELSE
        RAISE;
      END IF;
  END;
BEGIN
  SELECT (SELECT COUNT(*) FROM user_source
          WHERE name != 'SEND_PUSH_NOTIFICATION'
          AND   INSTR(LOWER(text), 'send_push_notification') > 0)
       + (SELECT COUNT(*) FROM user_ords_handlers
          WHERE DBMS_LOB.INSTR(LOWER(source), 'send_push_notification') > 0)
  INTO   l_refs FROM dual;

  IF l_refs > 0 THEN
    RAISE_APPLICATION_ERROR(-20002,
      l_refs || ' reference(s) to send_push_notification remain. Sections 3 or 4 '
      || 'did not take -- check for compile errors before dropping anything.');
  END IF;

  drop_it('PROCEDURE', 'send_push_notification');
  drop_it('PROCEDURE', 'test_push_notification');
  drop_it('TABLE',     'emp_push_tokens PURGE');
END;
/


--------------------------------------------------------------------------------
-- 6. Verify.
--------------------------------------------------------------------------------

-- a) Gone. Expect zero rows.
SELECT object_name, object_type, status FROM user_objects
WHERE  object_name IN ('SEND_PUSH_NOTIFICATION','TEST_PUSH_NOTIFICATION',
                       'EMP_PUSH_TOKENS');

-- b) Nothing we own is INVALID. Expect zero rows. (Schema-wide invalids belong
--    to the RPA and ticketing systems and are not ours to fix.)
SELECT object_name, object_type, status FROM user_objects
WHERE  status != 'VALID'
AND    object_name IN ('PROCESS_EXPENSE_ACTION','SEND_EXPENSE_MAIL',
                       'RECALC_CLAIM_TOTALS','PRICE_EXPENSE_ITEM','SCAN_RECEIPT');

SELECT name, type, line, position, text FROM user_errors
WHERE  name IN ('PROCESS_EXPENSE_ACTION','SEND_EXPENSE_MAIL')
ORDER  BY name, line;

-- c) No handler still mentions push, and the submit handler kept 62's fix.
SELECT t.uri_template, h.method,
       CASE WHEN DBMS_LOB.INSTR(LOWER(h.source), 'send_push_notification') > 0
            THEN '** STILL PUSHES **' ELSE 'clean' END AS push,
       CASE WHEN DBMS_LOB.INSTR(h.source, 'l_manager_id, l_finance_id, SYSTIMESTAMP') > 0
            THEN 'passes ids' ELSE '-' END AS script62_fix
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules   m ON m.id = t.module_id
WHERE  m.name LIKE 'expenses%'
AND   (t.uri_template IN (':id/submit','push-token')
    OR DBMS_LOB.INSTR(LOWER(h.source), 'push') > 0)
ORDER  BY t.uri_template;


--------------------------------------------------------------------------------
-- 7. Then prove it in the app, because none of the above exercises the code.
--
--   1. Submit a draft claim  -> 200, and the project manager gets the mail
--   2. Approve it as the PM  -> 200, and Finance gets the mail
--   3. Approve it as Finance -> 200, and the employee gets the mail
--
--   SELECT created_at, event, status, mail_to, mail_cc, subject
--   FROM   expense_mail_log ORDER BY id DESC FETCH FIRST 10 ROWS ONLY;
--
-- Step 1 is the one that matters. It is the handler this script rewrote, and a
-- mistake there shows up as a 500 on submit rather than as anything about push.
--------------------------------------------------------------------------------
