--------------------------------------------------------------------------------
-- 56_email_notifications.sql
--
-- Run as the application schema, with SET SERVEROUTPUT ON. Idempotent.
--
-- Rebuilds expense email notifications: one procedure, one place, an explicit
-- TO/CC matrix, and a log table so a failure is never invisible again.
--
--
-- WHY NO MAIL WAS ARRIVING -- three causes, all present at once
-- ------------------------------------------------------------
--
-- 1. APEX_MAIL.PUSH_QUEUE was never called, anywhere.
--    APEX_MAIL.SEND does not send. It writes a row to APEX_MAIL_QUEUE. The
--    queue is flushed either by APEX's own background job or by an explicit
--    PUSH_QUEUE call. If that job is not running on this instance, mail sits
--    in the queue forever, looking sent from the application's point of view.
--
-- 2. No APEX session context.
--    APEX_MAIL.SEND requires a workspace (security group) to be established.
--    Called from an ORDS handler or a plain stored procedure there is none, so
--    it raises an error immediately. Only the LOGIN handler ever called
--    APEX_UTIL.SET_WORKSPACE; nothing in the approval path did.
--
-- 3. Every call was wrapped in "EXCEPTION WHEN OTHERS THEN NULL".
--    So causes 1 and 2 produced no error, no log entry, and no mail. The
--    intent was right -- a mail failure must never roll back an approval --
--    but discarding the reason made it undiagnosable.
--
--
-- THE OLD MATRIX WAS ALSO WRONG
-- -----------------------------
-- On REVISED and REJECTED the old code mailed the project manager and the
-- finance manager -- and not the employee. The one person who has to act on a
-- revision, or who most needs to know about a rejection, was never told.
--
--
-- THE NEW MATRIX  (as specified, August 2026)
-- -------------------------------------------
--
--   EVENT             TO                  CC
--   ---------------------------------------------------------------------
--   SUBMITTED         project manager     employee
--   MANAGER_ACCEPTED  finance manager     project manager + employee
--   FINANCE_ACCEPTED  employee            project manager
--   REVISED           employee            project manager, only if Finance
--                                         asked for the revision
--   REJECTED          employee            project manager, only if Finance
--                                         rejected it
--
-- The conditional CC exists because the project manager only needs to hear
-- about a rejection on a claim he already approved. If HE is the one rejecting
-- it, copying him on his own decision is noise.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED


--------------------------------------------------------------------------------
-- 1. Mail log -- so a failure is visible.
--------------------------------------------------------------------------------
BEGIN
  EXECUTE IMMEDIATE '
    CREATE TABLE expense_mail_log (
      id          NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      expense_id  NUMBER,
      event       VARCHAR2(30),
      mail_to     VARCHAR2(4000),
      mail_cc     VARCHAR2(4000),
      subject     VARCHAR2(400),
      status      VARCHAR2(20),        -- QUEUED | PUSHED | FAILED | SKIPPED
      error_text  VARCHAR2(4000),
      created_at  TIMESTAMP DEFAULT SYSTIMESTAMP
    )';
EXCEPTION
  WHEN OTHERS THEN IF SQLCODE != -955 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'CREATE INDEX ix_mail_log_expense ON expense_mail_log(expense_id, created_at)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -955 THEN RAISE; END IF;
END;
/


--------------------------------------------------------------------------------
-- 2. Config: sender address and the APEX workspace.
--
--    The workspace is resolved here at DEPLOY time rather than hardcoded --
--    it differs between environments, and a wrong value fails in a way that
--    looks like a mail server problem.
--------------------------------------------------------------------------------
DECLARE
  l_ws VARCHAR2(200);
  l_n  NUMBER;
BEGIN
  SELECT COUNT(DISTINCT workspace_name) INTO l_n
  FROM   apex_workspace_apex_users
  WHERE  workspace_name != 'INTERNAL';

  IF l_n = 1 THEN
    SELECT DISTINCT workspace_name INTO l_ws
    FROM   apex_workspace_apex_users
    WHERE  workspace_name != 'INTERNAL';

    MERGE INTO app_secrets t
    USING (SELECT 'MAIL_WORKSPACE' AS n, l_ws AS v FROM dual) s
    ON (t.secret_name = s.n)
    WHEN MATCHED THEN UPDATE SET t.secret_value = s.v
    WHEN NOT MATCHED THEN INSERT (secret_name, secret_value) VALUES (s.n, s.v);

    DBMS_OUTPUT.PUT_LINE('MAIL_WORKSPACE resolved to: ' || l_ws);
  ELSE
    DBMS_OUTPUT.PUT_LINE('Found ' || l_n || ' candidate workspaces -- cannot choose.');
    DBMS_OUTPUT.PUT_LINE('Set it by hand:');
    DBMS_OUTPUT.PUT_LINE('  UPDATE app_secrets SET secret_value = ''<WORKSPACE>''');
    DBMS_OUTPUT.PUT_LINE('  WHERE secret_name = ''MAIL_WORKSPACE'';');
  END IF;
END;
/

-- Sender address. EDIT THIS if IT specifies something different. It must be an
-- address the mail server will accept as a sender, or everything is rejected
-- or filed as spam -- which is why the old behaviour of sending AS the acting
-- employee was a liability rather than a convenience.
MERGE INTO app_secrets t
USING (SELECT 'MAIL_FROM' AS n, 'noreply@trinamix.com' AS v FROM dual) s
ON (t.secret_name = s.n)
WHEN MATCHED THEN UPDATE SET t.secret_value = s.v
WHEN NOT MATCHED THEN INSERT (secret_name, secret_value) VALUES (s.n, s.v);

COMMIT;


--------------------------------------------------------------------------------
-- 3. The one mail procedure.
--
--    Every notification goes through here. Callers say WHAT happened and WHO
--    did it; this decides who hears about it. That way the matrix lives in one
--    readable place instead of being scattered across six call sites, which is
--    how it drifted out of step with the intended behaviour in the first place.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE send_expense_mail(
  p_expense_id  IN NUMBER,
  p_event       IN VARCHAR2,           -- see the matrix in the header
  p_actor_empid IN NUMBER DEFAULT NULL,-- who performed the action
  p_comment     IN VARCHAR2 DEFAULT NULL
) IS
  PRAGMA AUTONOMOUS_TRANSACTION;

  l_emp_id      NUMBER;
  l_mgr_id      NUMBER;
  l_fin_id      NUMBER;
  l_amount      NUMBER;
  l_currency    VARCHAR2(3);
  l_amount_usd  NUMBER;
  l_type        VARCHAR2(100);
  l_from_date   DATE;
  l_to_date     DATE;

  l_emp_email   VARCHAR2(255);
  l_emp_name    VARCHAR2(255);
  l_mgr_email   VARCHAR2(255);
  l_fin_email   VARCHAR2(255);

  l_to          VARCHAR2(4000);
  l_cc          VARCHAR2(4000);
  l_subject     VARCHAR2(400);
  l_body        VARCHAR2(4000);
  l_headline    VARCHAR2(400);

  l_from        VARCHAR2(255);
  l_workspace   VARCHAR2(200);
  l_actor_is_finance BOOLEAN := FALSE;

  FUNCTION secret(p_name IN VARCHAR2) RETURN VARCHAR2 IS
    l_v VARCHAR2(200);
  BEGIN
    SELECT secret_value INTO l_v FROM app_secrets WHERE secret_name = p_name;
    RETURN l_v;
  EXCEPTION WHEN NO_DATA_FOUND THEN RETURN NULL;
  END;

  FUNCTION email_of(p_id IN NUMBER) RETURN VARCHAR2 IS
    l_v VARCHAR2(255);
  BEGIN
    IF p_id IS NULL THEN RETURN NULL; END IF;
    SELECT company_email INTO l_v FROM employeedetails WHERE empid = p_id;
    RETURN l_v;
  EXCEPTION WHEN NO_DATA_FOUND THEN RETURN NULL;
  END;

  -- Builds a CC list from parts, dropping NULLs, duplicates, and anyone who is
  -- already the TO recipient. Without this an employee who is also the project
  -- manager on their own claim receives the same mail twice.
  FUNCTION cc_list(p_a IN VARCHAR2, p_b IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
    l_out VARCHAR2(4000);
    PROCEDURE add(p_e IN VARCHAR2) IS
    BEGIN
      IF p_e IS NULL THEN RETURN; END IF;
      IF UPPER(p_e) = UPPER(NVL(l_to, '~')) THEN RETURN; END IF;
      IF INSTR(UPPER(NVL(l_out, '')), UPPER(p_e)) > 0 THEN RETURN; END IF;
      l_out := CASE WHEN l_out IS NULL THEN p_e ELSE l_out || ',' || p_e END;
    END;
  BEGIN
    add(p_a);
    add(p_b);
    RETURN l_out;
  END;

  PROCEDURE log_it(p_status IN VARCHAR2, p_err IN VARCHAR2 DEFAULT NULL) IS
  BEGIN
    INSERT INTO expense_mail_log (expense_id, event, mail_to, mail_cc, subject, status, error_text)
    VALUES (p_expense_id, p_event, l_to, l_cc, l_subject, p_status, p_err);
  END;

BEGIN
  SELECT emp_id, manager_empid, finance_manager_empid, amount, currency,
         amount_usd, type, from_date, to_date
  INTO   l_emp_id, l_mgr_id, l_fin_id, l_amount, l_currency,
         l_amount_usd, l_type, l_from_date, l_to_date
  FROM   expenses
  WHERE  id = p_expense_id;

  l_emp_email := email_of(l_emp_id);
  l_mgr_email := email_of(l_mgr_id);
  l_fin_email := email_of(NVL(l_fin_id, get_finance_manager_empid()));

  BEGIN
    SELECT first_name || ' ' || last_name INTO l_emp_name
    FROM   employeedetails WHERE empid = l_emp_id;
  EXCEPTION WHEN OTHERS THEN l_emp_name := 'Employee #' || l_emp_id;
  END;

  l_actor_is_finance := (p_actor_empid IS NOT NULL
                         AND is_finance_manager(p_actor_empid) = 'Y');

  ------------------------------------------------------------------------------
  -- The matrix.
  ------------------------------------------------------------------------------
  IF p_event = 'SUBMITTED' THEN
    l_to       := l_mgr_email;
    l_cc       := cc_list(l_emp_email);
    l_headline := 'An expense needs your approval';
    l_subject  := 'Expense #' || p_expense_id || ' awaiting your approval';

  ELSIF p_event = 'MANAGER_ACCEPTED' THEN
    l_to       := l_fin_email;
    l_cc       := cc_list(l_mgr_email, l_emp_email);
    l_headline := 'An expense approved by the project manager needs your review';
    l_subject  := 'Expense #' || p_expense_id || ' awaiting Finance approval';

  ELSIF p_event = 'FINANCE_ACCEPTED' THEN
    l_to       := l_emp_email;
    l_cc       := cc_list(l_mgr_email);
    l_headline := 'Your expense has been fully approved';
    l_subject  := 'Expense #' || p_expense_id || ' approved';

  ELSIF p_event = 'REVISED' THEN
    l_to       := l_emp_email;
    -- Only copy the project manager if FINANCE asked for the revision: he
    -- already approved this claim, so he needs to know it came back.
    l_cc       := CASE WHEN l_actor_is_finance THEN cc_list(l_mgr_email) END;
    l_headline := 'Your expense needs changes before it can be approved';
    l_subject  := 'Expense #' || p_expense_id || ' sent back for revision';

  ELSIF p_event = 'REJECTED' THEN
    l_to       := l_emp_email;
    l_cc       := CASE WHEN l_actor_is_finance THEN cc_list(l_mgr_email) END;
    l_headline := 'Your expense has been rejected';
    l_subject  := 'Expense #' || p_expense_id || ' rejected';

  ELSE
    l_subject := 'Unknown event ' || p_event;
    log_it('SKIPPED', 'Unrecognised event');
    COMMIT;
    RETURN;
  END IF;

  IF l_to IS NULL THEN
    log_it('SKIPPED', 'No TO address -- the relevant employee has no COMPANY_EMAIL');
    COMMIT;
    RETURN;
  END IF;

  ------------------------------------------------------------------------------
  -- Body.
  ------------------------------------------------------------------------------
  l_body :=
    l_headline || CHR(10) || CHR(10) ||
    'Expense  : #' || p_expense_id || CHR(10) ||
    'Employee : ' || l_emp_name || CHR(10) ||
    'Type     : ' || NVL(l_type, '-') || CHR(10) ||
    'Amount   : ' || l_amount || ' ' || NVL(l_currency, '') ||
      CASE WHEN l_amount_usd IS NOT NULL AND NVL(l_currency,'X') != 'USD'
           THEN '  (USD ' || l_amount_usd || ')' END || CHR(10) ||
    'Period   : ' || TO_CHAR(l_from_date, 'DD-Mon-YYYY') ||
                ' to ' || TO_CHAR(l_to_date, 'DD-Mon-YYYY') || CHR(10) ||
    CASE WHEN p_comment IS NOT NULL
         THEN CHR(10) || 'Comment  : ' || p_comment || CHR(10) END ||
    CHR(10) || 'Open the Expenses app to view or act on this claim.' || CHR(10);

  ------------------------------------------------------------------------------
  -- Send.
  ------------------------------------------------------------------------------
  l_from      := NVL(secret('MAIL_FROM'), 'noreply@trinamix.com');
  l_workspace := secret('MAIL_WORKSPACE');

  BEGIN
    -- Without a workspace APEX_MAIL.SEND raises immediately: it needs a
    -- security group id, and outside an APEX session there is none.
    IF l_workspace IS NOT NULL THEN
      APEX_UTIL.SET_WORKSPACE(p_workspace => l_workspace);
    END IF;

    APEX_MAIL.SEND(
      p_to   => l_to,
      p_cc   => l_cc,
      p_from => l_from,
      p_subj => l_subject,
      p_body => l_body
    );

    log_it('QUEUED');

    -- SEND only queues. This is what actually hands it to the mail server.
    -- Missing this was the single biggest reason no mail arrived.
    APEX_MAIL.PUSH_QUEUE;

    UPDATE expense_mail_log SET status = 'PUSHED'
    WHERE  id = (SELECT MAX(id) FROM expense_mail_log
                 WHERE expense_id = p_expense_id AND event = p_event);

    COMMIT;

  EXCEPTION
    WHEN OTHERS THEN
      -- Recorded, not raised. A mail failure must never roll back the approval
      -- that triggered it -- but it must not vanish either.
      log_it('FAILED', SUBSTR(DBMS_UTILITY.FORMAT_ERROR_STACK, 1, 4000));
      COMMIT;
  END;

EXCEPTION
  WHEN NO_DATA_FOUND THEN
    l_subject := 'Expense ' || p_expense_id || ' not found';
    log_it('SKIPPED', 'No such expense');
    COMMIT;
  WHEN OTHERS THEN
    log_it('FAILED', SUBSTR(DBMS_UTILITY.FORMAT_ERROR_STACK, 1, 4000));
    COMMIT;
END send_expense_mail;
/


--------------------------------------------------------------------------------
-- 4. Diagnostic: is mail configured on this instance at all?
--------------------------------------------------------------------------------
DECLARE
  l_host  VARCHAR2(200);
  l_port  VARCHAR2(20);
  l_from  VARCHAR2(200);
  l_queue NUMBER;
BEGIN
  BEGIN
    l_host := APEX_INSTANCE_ADMIN.GET_PARAMETER('SMTP_HOST_ADDRESS');
    l_port := APEX_INSTANCE_ADMIN.GET_PARAMETER('SMTP_HOST_PORT');
    l_from := APEX_INSTANCE_ADMIN.GET_PARAMETER('SMTP_FROM');
    DBMS_OUTPUT.PUT_LINE('SMTP host : ' || NVL(l_host, '(NOT SET -- no mail can ever be sent)'));
    DBMS_OUTPUT.PUT_LINE('SMTP port : ' || NVL(l_port, '(not set)'));
    DBMS_OUTPUT.PUT_LINE('SMTP from : ' || NVL(l_from, '(not set)'));
    IF l_host IS NULL THEN
      DBMS_OUTPUT.PUT_LINE(' ');
      DBMS_OUTPUT.PUT_LINE('>> A DBA or APEX administrator must set the SMTP host. Until then');
      DBMS_OUTPUT.PUT_LINE('>> nothing in this script can deliver mail:');
      DBMS_OUTPUT.PUT_LINE('>>   APEX_INSTANCE_ADMIN.SET_PARAMETER(''SMTP_HOST_ADDRESS'', ''smtp.trinamix.com'');');
      DBMS_OUTPUT.PUT_LINE('>>   APEX_INSTANCE_ADMIN.SET_PARAMETER(''SMTP_HOST_PORT'', ''25'');');
      DBMS_OUTPUT.PUT_LINE('>> Note the mail server also needs a network ACL, same as exp.host did.');
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('Cannot read instance parameters from this schema.');
      DBMS_OUTPUT.PUT_LINE('Ask an APEX administrator for SMTP_HOST_ADDRESS.');
  END;

  BEGIN
    SELECT COUNT(*) INTO l_queue FROM apex_mail_queue;
    DBMS_OUTPUT.PUT_LINE('Mail sitting in APEX_MAIL_QUEUE: ' || l_queue);
    IF l_queue > 0 THEN
      DBMS_OUTPUT.PUT_LINE('>> Unsent mail is queued. That is the PUSH_QUEUE problem this');
      DBMS_OUTPUT.PUT_LINE('>> script fixes. Flush it now with: BEGIN APEX_MAIL.PUSH_QUEUE; END;');
    END IF;
  EXCEPTION
    WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('APEX_MAIL_QUEUE not readable from this schema.');
  END;
END;
/


--------------------------------------------------------------------------------
-- 5. Test one event without touching a real expense's status.
--
--    Substitute a real expense id you own. Safe: send_expense_mail only reads.
--------------------------------------------------------------------------------
-- BEGIN send_expense_mail(p_expense_id => 123, p_event => 'SUBMITTED'); END;
-- /
--
-- Then read the outcome -- this is the part that used to be invisible:
--
-- SELECT created_at, event, status, mail_to, mail_cc, subject, error_text
-- FROM   expense_mail_log ORDER BY id DESC FETCH FIRST 10 ROWS ONLY;


--------------------------------------------------------------------------------
-- 6. Confirm it compiled.
--------------------------------------------------------------------------------
SELECT object_name, object_type, status
FROM   user_objects
WHERE  object_name IN ('SEND_EXPENSE_MAIL', 'EXPENSE_MAIL_LOG')
ORDER  BY object_name;

SELECT secret_name, secret_value
FROM   app_secrets
WHERE  secret_name IN ('MAIL_FROM', 'MAIL_WORKSPACE')
ORDER  BY secret_name;


--------------------------------------------------------------------------------
-- NEXT: 57_email_wire_workflow.sql replaces the inline APEX_MAIL.SEND calls in
-- process_expense_action and the :id/submit handler with calls to this
-- procedure. Until that runs, this procedure exists but nothing calls it.
--------------------------------------------------------------------------------
