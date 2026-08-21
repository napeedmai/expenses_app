--------------------------------------------------------------------------------
-- EMAIL_DEPLOY.sql   --   Expense App, complete email notifications
--
-- Run ONCE, as the APPLICATION SCHEMA. Idempotent. Supersedes scripts 56-60,
-- which were written one fix at a time; this is all of them, in the only order
-- that compiles.
--
--
-- READ THIS FIRST -- BOTH FAILURES SO FAR WERE MECHANICAL
-- --------------------------------------------------------
--
-- 1. WRONG SCHEMA. Three attempts went to HRMS (dev) instead of the schema the
--    app uses. Dev never received the push feature, so SEND_PUSH_NOTIFICATION
--    is INVALID there, and PROCESS_EXPENSE_ACTION cannot compile against it --
--    which surfaces as five unrelated-looking PLS-00905 errors. STEP 0 stops
--    with one clear message instead.
--
--        SELECT SYS_CONTEXT('USERENV','CURRENT_SCHEMA') FROM dual;
--
-- 2. WRONG ORDER. SEND_EXPENSE_MAIL must be created BEFORE
--    PROCESS_EXPENSE_ACTION. Reversed, the older 4-argument version is still
--    in place when the workflow compiles, and passing the role argument gives
--    PLS-00306, "wrong number or types of arguments". Do not reorder the steps
--    below.
--
-- Run the whole file top to bottom. SET SERVEROUTPUT ON first.
--
--
-- WHAT IT DELIVERS
-- ----------------
--   EVENT              TO                CC
--   SUBMITTED          project manager   employee
--     (no PM assigned  submitter         -- with a warning in the body)
--   MANAGER_ACCEPTED   finance manager   project manager + employee
--   FINANCE_ACCEPTED   employee          project manager
--   REVISED            employee          project manager
--   REJECTED           employee          project manager
--
-- Each mail carries the Expense Claim table: project, employee/manager/finance
-- names with ecodes, type, bill no, currency, amount, the USD equivalent with
-- the rate used, and the relevant remarks. HTML plus a plain-text fallback.
--
-- Every attempt is written to EXPENSE_MAIL_LOG. Failures are logged and
-- swallowed -- a mail failure must never roll back the approval that caused
-- it -- but they are no longer invisible.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF



--------------------------------------------------------------------------------
-- STEP 0 of 6   --   Refuse to run on the wrong schema
-- Everything below depends on objects that only exist where the app lives.
--------------------------------------------------------------------------------


DECLARE
  l_schema  VARCHAR2(128) := SYS_CONTEXT('USERENV','CURRENT_SCHEMA');
  l_n       NUMBER;
  l_missing VARCHAR2(400);
BEGIN
  DBMS_OUTPUT.PUT_LINE('Connected as: ' || l_schema);

  FOR d IN (SELECT column_value AS name FROM TABLE(sys.odcivarchar2list(
              'SEND_PUSH_NOTIFICATION', 'JSON_ESCAPE_STR', 'GET_REVIEWER_ROLE',
              'GET_FINANCE_MANAGER_EMPID', 'IS_FINANCE_MANAGER',
              'GET_PROJECT_MANAGER_EMPID')))
  LOOP
    SELECT COUNT(*) INTO l_n FROM user_objects
    WHERE  object_name = d.name AND status = 'VALID';
    IF l_n = 0 THEN
      l_missing := l_missing || d.name || ' ';
    END IF;
  END LOOP;

  SELECT COUNT(*) INTO l_n FROM user_tables WHERE table_name = 'EXPENSES';
  IF l_n = 0 THEN l_missing := l_missing || 'EXPENSES '; END IF;

  IF l_missing IS NOT NULL THEN
    RAISE_APPLICATION_ERROR(-20001,
      'Wrong schema, or this one is incomplete. Connected as ' || l_schema
      || '. Missing or INVALID: ' || l_missing
      || '-- connect to the schema in src/config.js API_BASE_URL, or run '
      || 'MASTER_DEPLOY.sql here first. Nothing has been changed.');
  END IF;

  DBMS_OUTPUT.PUT_LINE('Prerequisites OK on ' || l_schema || '. Proceeding.');
END;
/



--------------------------------------------------------------------------------
-- STEP 1 of 6   --   EXPENSE_MAIL_LOG
-- So a failed notification is recorded instead of vanishing.
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
      status      VARCHAR2(20),
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
-- STEP 2 of 6   --   Sender address and APEX workspace
-- APEX_MAIL.SEND needs a workspace; an ORDS handler has no APEX session.
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
-- STEP 3 of 6   --   send_expense_mail
-- MUST come before step 4 -- the workflow calls it with five arguments.
--------------------------------------------------------------------------------


CREATE OR REPLACE PROCEDURE send_expense_mail(
  p_expense_id  IN NUMBER,
  p_event       IN VARCHAR2,
  p_actor_empid IN NUMBER   DEFAULT NULL,
  p_comment     IN VARCHAR2 DEFAULT NULL,
  -- 'PROJECT_MANAGER' | 'FINANCE_MANAGER' | NULL.
  --
  -- Passed in because it CANNOT be derived here. is_finance_manager() answers
  -- "is this person the finance manager", not "which role were they acting in
  -- just now" -- and when one person is both the project manager and the
  -- finance manager, those differ. A manager revising at the MANAGER stage was
  -- labelled FM, and his remark filed under Fin.Manager Remarks.
  --
  -- Nor can current_stage be read back: process_expense_action has already
  -- moved it by the time this runs (to FINANCE on manager-accept, to NULL on
  -- final approval). The caller knows; it computed get_reviewer_role before
  -- touching anything.
  p_actor_role  IN VARCHAR2 DEFAULT NULL
) IS
  PRAGMA AUTONOMOUS_TRANSACTION;

  -- expense
  l_emp_id       NUMBER;
  l_mgr_id       NUMBER;
  l_fin_id       NUMBER;
  l_project_id   NUMBER;
  l_project_name VARCHAR2(400);
  l_amount       NUMBER;
  l_currency     VARCHAR2(3);
  l_amount_usd   NUMBER;
  l_exchange_rate NUMBER;
  l_type         VARCHAR2(100);
  l_bill_no      VARCHAR2(100);
  l_submitted_at TIMESTAMP;

  -- people, as "Name(Ecode)"
  l_emp_label    VARCHAR2(400);
  l_mgr_label    VARCHAR2(400);
  l_fin_label    VARCHAR2(400);
  l_emp_name     VARCHAR2(300);
  l_mgr_name     VARCHAR2(300);
  l_fin_name     VARCHAR2(300);
  l_emp_email    VARCHAR2(255);
  l_mgr_email    VARCHAR2(255);
  l_fin_email    VARCHAR2(255);

  -- actor
  l_no_manager   BOOLEAN := FALSE;
  l_mgr_no_email BOOLEAN := FALSE;
  l_actor_name   VARCHAR2(300);
  l_actor_role   VARCHAR2(4);      -- 'PM' | 'FM'
  l_actor_label  VARCHAR2(400);

  -- remarks
  l_mgr_remarks  VARCHAR2(4000);
  l_fin_remarks  VARCHAR2(4000);

  l_to           VARCHAR2(4000);
  l_cc           VARCHAR2(4000);
  l_subject      VARCHAR2(400);
  l_greeting     VARCHAR2(400);
  l_body         CLOB;
  l_html         CLOB;
  l_rows         CLOB;
  l_from         VARCHAR2(255);
  l_workspace    VARCHAR2(200);

  FUNCTION secret(p_name IN VARCHAR2) RETURN VARCHAR2 IS
    l_v VARCHAR2(200);
  BEGIN
    SELECT secret_value INTO l_v FROM app_secrets WHERE secret_name = p_name;
    RETURN l_v;
  EXCEPTION WHEN NO_DATA_FOUND THEN RETURN NULL;
  END;

  -- One row of the claim table, in both formats at once, so the two bodies can
  -- never drift apart.
  PROCEDURE add_row(p_label IN VARCHAR2, p_value IN VARCHAR2) IS
  BEGIN
    l_body := l_body || RPAD(p_label, 22) || NVL(NULLIF(TRIM(p_value), ''), '-') || CHR(10);
    l_rows := l_rows
      || '<tr><td style="padding:4px 10px;border:1px solid #ddd;background:#f8fafc;'
      || 'white-space:nowrap"><b>' || p_label || '</b></td>'
      || '<td style="padding:4px 10px;border:1px solid #ddd">'
      || NVL(DBMS_XMLGEN.CONVERT(NULLIF(TRIM(p_value), '')), '-') || '</td></tr>';
  END;

  -- The USD equivalent stored ON THE ROW at save time, plus the rate used to
  -- get there -- not a fresh conversion. Restating an approved claim at
  -- today's rate would make the email disagree with the record.
  FUNCTION usd_row RETURN VARCHAR2 IS
  BEGIN
    IF l_amount_usd IS NULL THEN
      RETURN NULL;   -- renders as '-'
    END IF;
    RETURN TO_CHAR(l_amount_usd) || ' USD'
           || CASE WHEN l_exchange_rate IS NOT NULL AND NVL(l_currency, 'X') != 'USD'
                   THEN '   (1 ' || l_currency || ' = ' || TO_CHAR(l_exchange_rate) || ' USD)'
              END;
  END;

  PROCEDURE log_it(p_status IN VARCHAR2, p_err IN VARCHAR2 DEFAULT NULL) IS
  BEGIN
    INSERT INTO expense_mail_log (expense_id, event, mail_to, mail_cc, subject, status, error_text)
    VALUES (p_expense_id, p_event, l_to, l_cc, l_subject, p_status, p_err);
  END;

  -- Drops NULLs, duplicates, and anyone already in TO. Without this, someone
  -- who is the project manager on their own claim receives the same mail twice.
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
    add(p_a); add(p_b);
    RETURN l_out;
  END;

BEGIN
  ------------------------------------------------------------------------------
  -- Gather
  ------------------------------------------------------------------------------
  SELECT e.emp_id, e.manager_empid, NVL(e.finance_manager_empid, get_finance_manager_empid()),
         e.project_id, e.amount, e.currency, e.amount_usd, e.exchange_rate,
         e.type, e.bill_no, e.submitted_at
  INTO   l_emp_id, l_mgr_id, l_fin_id,
         l_project_id, l_amount, l_currency, l_amount_usd, l_exchange_rate,
         l_type, l_bill_no, l_submitted_at
  FROM   expenses e
  WHERE  e.id = p_expense_id;

  BEGIN
    SELECT project_name INTO l_project_name
    FROM   projectmaster WHERE project_id = l_project_id;
  EXCEPTION WHEN OTHERS THEN l_project_name := NULL;
  END;

  FOR r IN (SELECT empid,
                   first_name || ' ' || last_name AS full_name,
                   ecode,
                   company_email
            FROM   employeedetails
            WHERE  empid IN (l_emp_id, l_mgr_id, l_fin_id))
  LOOP
    -- TRIM because a name built from two padded CHAR columns is all spaces
    -- when both are empty, and an all-space label renders as a blank table
    -- cell rather than tripping the NVL fallback in add_row.
    IF r.empid = l_emp_id THEN
      l_emp_name  := NULLIF(TRIM(r.full_name), '');
      l_emp_email := r.company_email;
      l_emp_label := TRIM(NVL(l_emp_name, 'Employee #' || r.empid)
                     || CASE WHEN TRIM(r.ecode) IS NOT NULL
                             THEN '(' || TRIM(r.ecode) || ')' END);
    END IF;
    IF r.empid = l_mgr_id THEN
      l_mgr_name  := NULLIF(TRIM(r.full_name), '');
      l_mgr_email := r.company_email;
      l_mgr_label := TRIM(NVL(l_mgr_name, 'Employee #' || r.empid)
                     || CASE WHEN TRIM(r.ecode) IS NOT NULL
                             THEN '(' || TRIM(r.ecode) || ')' END);
    END IF;
    IF r.empid = l_fin_id THEN
      l_fin_name  := NULLIF(TRIM(r.full_name), '');
      l_fin_email := r.company_email;
      l_fin_label := TRIM(NVL(l_fin_name, 'Employee #' || r.empid)
                     || CASE WHEN TRIM(r.ecode) IS NOT NULL
                             THEN '(' || TRIM(r.ecode) || ')' END);
    END IF;
  END LOOP;

  -- If a lookup found nothing at all, say so rather than leaving the row
  -- blank. A blank cell reads as a template bug; "Employee #3725 (not found)"
  -- points at the actual problem, which is the EMPLOYEEDETAILS row.
  l_emp_label := NVL(l_emp_label, 'Employee #' || l_emp_id || ' (not found)');
  l_mgr_label := NVL(l_mgr_label, CASE WHEN l_mgr_id IS NULL THEN 'not assigned'
                                       ELSE 'Employee #' || l_mgr_id || ' (not found)' END);
  l_fin_label := NVL(l_fin_label, CASE WHEN l_fin_id IS NULL THEN 'not assigned'
                                       ELSE 'Employee #' || l_fin_id || ' (not found)' END);

  -- Actor. is_finance_manager decides the role rather than comparing against
  -- manager_empid, because the same person can be both on different claims.
  IF p_actor_empid IS NOT NULL THEN
    l_actor_role :=
      CASE
        WHEN p_actor_role = 'FINANCE_MANAGER' THEN 'FM'
        WHEN p_actor_role = 'PROJECT_MANAGER' THEN 'PM'
        -- No role supplied: fall back to the event, which is unambiguous for
        -- every case except a revise/reject, where the caller must supply it.
        WHEN p_event = 'FINANCE_ACCEPTED'     THEN 'FM'
        WHEN p_event = 'MANAGER_ACCEPTED'     THEN 'PM'
        ELSE 'PM'
      END;
    IF p_actor_empid = l_emp_id THEN
      l_actor_name := l_emp_name;
    ELSIF p_actor_empid = l_mgr_id THEN
      l_actor_name := l_mgr_name;
    ELSIF p_actor_empid = l_fin_id THEN
      l_actor_name := l_fin_name;
    ELSE
      BEGIN
        SELECT first_name || ' ' || last_name INTO l_actor_name
        FROM   employeedetails WHERE empid = p_actor_empid;
      EXCEPTION WHEN OTHERS THEN l_actor_name := 'Employee #' || p_actor_empid;
      END;
    END IF;
  END IF;

  -- Remarks: the most recent comment at each stage, from the audit trail --
  -- so an approval email can quote what the manager said earlier.
  BEGIN
    SELECT MAX(comments) KEEP (DENSE_RANK LAST ORDER BY acted_at)
    INTO   l_mgr_remarks
    FROM   expense_approvals
    WHERE  expense_id = p_expense_id AND role = 'PROJECT_MANAGER';
  EXCEPTION WHEN OTHERS THEN l_mgr_remarks := NULL;
  END;

  BEGIN
    SELECT MAX(comments) KEEP (DENSE_RANK LAST ORDER BY acted_at)
    INTO   l_fin_remarks
    FROM   expense_approvals
    WHERE  expense_id = p_expense_id AND role = 'FINANCE_MANAGER';
  EXCEPTION WHEN OTHERS THEN l_fin_remarks := NULL;
  END;

  -- p_comment is the action just performed; it may not be committed to
  -- EXPENSE_APPROVALS yet from this autonomous transaction's point of view.
  IF p_comment IS NOT NULL THEN
    IF l_actor_role = 'FM' THEN l_fin_remarks := p_comment;
    ELSE                        l_mgr_remarks := p_comment;
    END IF;
  END IF;

  ------------------------------------------------------------------------------
  -- Recipients, greeting, subject
  ------------------------------------------------------------------------------
  IF p_event = 'SUBMITTED' THEN
    IF l_mgr_email IS NOT NULL THEN
      l_to        := l_mgr_email;
      l_cc        := cc_list(l_emp_email);
      l_greeting  := 'Dear ' || NVL(l_mgr_name, 'Project Manager');
      l_subject   := 'Expense #' || p_expense_id || ' awaiting your approval';
    ELSE
      -- No address to send to. TWO VERY DIFFERENT CAUSES, and conflating them
      -- produced a wrong and alarming message: a claim WITH a manager who has
      -- no email was reported as "no project manager assigned, cannot be
      -- approved" -- when in fact it can be approved perfectly well in the
      -- app, the manager just was not emailed.
      --
      --   manager_empid IS NULL  -> genuinely unassigned. Nobody can approve
      --                             it at the first stage. The claim is stuck.
      --   manager_empid set, but
      --   no COMPANY_EMAIL       -> approval works normally; only the
      --                             notification is lost.
      l_to        := l_emp_email;
      l_cc        := NULL;
      l_greeting  := 'Dear ' || NVL(l_emp_name, 'Colleague');
      IF l_mgr_id IS NULL THEN
        l_no_manager := TRUE;
        l_subject := 'Expense #' || p_expense_id
                     || ' submitted -- no project manager assigned';
      ELSE
        l_mgr_no_email := TRUE;
        l_subject := 'Expense #' || p_expense_id || ' submitted';
      END IF;
    END IF;
    l_actor_label := NVL(l_emp_name, 'the submitter');

  ELSIF p_event = 'MANAGER_ACCEPTED' THEN
    l_to        := l_fin_email;
    l_cc        := cc_list(l_mgr_email, l_emp_email);
    l_greeting  := 'Dear ' || NVL(l_fin_name, 'Finance Manager');
    l_actor_label := NVL(l_actor_name, l_mgr_name) || ' (PM)';
    l_subject   := 'Expense #' || p_expense_id || ' awaiting Finance approval';

  ELSIF p_event = 'FINANCE_ACCEPTED' THEN
    l_to        := l_emp_email;
    l_cc        := cc_list(l_mgr_email);
    l_greeting  := 'Dear ' || NVL(l_emp_name, 'Colleague');
    l_actor_label := NVL(l_actor_name, l_fin_name) || ' (FM)';
    l_subject   := 'Expense #' || p_expense_id || ' approved';

  ELSIF p_event IN ('REVISED', 'REJECTED') THEN
    l_to        := l_emp_email;
    l_cc        := cc_list(l_mgr_email);
    l_greeting  := 'Dear ' || NVL(l_emp_name, 'Colleague');
    l_actor_label := NVL(l_actor_name, 'a reviewer') || ' (' || NVL(l_actor_role, 'PM') || ')';
    l_subject   := 'Expense #' || p_expense_id ||
                   CASE WHEN p_event = 'REVISED' THEN ' sent back for revision'
                        ELSE ' rejected' END;
  ELSE
    l_subject := 'Unknown event ' || p_event;
    log_it('SKIPPED', 'Unrecognised event');
    COMMIT; RETURN;
  END IF;

  IF l_to IS NULL THEN
    log_it('SKIPPED', 'No TO address -- the relevant employee has no COMPANY_EMAIL');
    COMMIT; RETURN;
  END IF;

  ------------------------------------------------------------------------------
  -- Claim table
  ------------------------------------------------------------------------------
  l_body := l_greeting || CHR(10) || CHR(10)
         || 'This e-mail generated based on action performed by '
         || l_actor_label || '.' || CHR(10) || CHR(10)
         || 'Expense Claim' || CHR(10)
         || RPAD('-', 60, '-') || CHR(10);
  l_rows := NULL;

  add_row('Project Name:', l_project_name);

  IF p_event = 'SUBMITTED' THEN
    add_row('Claim Date:', TO_CHAR(NVL(CAST(l_submitted_at AS DATE), SYSDATE), 'DD-Mon-YYYY'));
    add_row('Claim For:', l_type);
    add_row('bill no:', l_bill_no);
    add_row('Currency:', l_currency);
    add_row('Claim Amount:', TO_CHAR(l_amount) || ' ' || l_currency);
    add_row('Amount (USD):', usd_row);
  ELSE
    add_row('Employee(Ecode):', l_emp_label);
    add_row('Manager (Ecode):', l_mgr_label);
    add_row('Fin.Mgr(Ecode):', l_fin_label);
    add_row('Claim For:', l_type);
    add_row('bill no:', l_bill_no);
    add_row('Currency:', l_currency);
    add_row('bill Amount:', TO_CHAR(l_amount) || ' ' || l_currency);
    add_row('Amount (USD):', usd_row);

    IF p_event = 'FINANCE_ACCEPTED' THEN
      add_row('Manager Remarks:', l_mgr_remarks);
      add_row('Fin.Manager Remarks:', l_fin_remarks);
      add_row('Approved Amount:', TO_CHAR(l_amount) || ' ' || l_currency
                                  || CASE WHEN l_amount_usd IS NOT NULL
                                          THEN '  (USD ' || TO_CHAR(l_amount_usd) || ')' END);
    ELSIF p_event = 'MANAGER_ACCEPTED' THEN
      add_row('Manager Remarks:', l_mgr_remarks);
    ELSE
      -- REVISED / REJECTED: label the remark with whoever actually acted.
      add_row(CASE WHEN l_actor_role = 'FM' THEN 'Fin.Manager Remarks:'
                   ELSE 'Manager Remarks:' END,
              NVL(p_comment, CASE WHEN l_actor_role = 'FM' THEN l_fin_remarks
                                  ELSE l_mgr_remarks END));
    END IF;
  END IF;

  IF l_no_manager THEN
    l_body := l_body || CHR(10)
      || 'NOTE: this claim has no project manager assigned, so it cannot be'  || CHR(10)
      || 'approved at the first stage. Ask for a project manager to be set on' || CHR(10)
      || 'the project, then resubmit.' || CHR(10);
    l_rows := l_rows
      || '<tr><td colspan="2" style="padding:8px 10px;border:1px solid #f59e0b;'
      || 'background:#fef3c7;color:#92400e"><b>No project manager is assigned '
      || 'to this project</b>, so this claim cannot be approved at the first '
      || 'stage. Ask for one to be set, then resubmit.</td></tr>';

  ELSIF l_mgr_no_email THEN
    -- Deliberately reassuring rather than alarming: the workflow is fine.
    l_body := l_body || CHR(10)
      || 'NOTE: your project manager (' || l_mgr_label || ') has no email'    || CHR(10)
      || 'address on file, so they were not notified automatically. They can'  || CHR(10)
      || 'still approve this claim in the app -- you may want to tell them.'   || CHR(10);
    l_rows := l_rows
      || '<tr><td colspan="2" style="padding:8px 10px;border:1px solid #93c5fd;'
      || 'background:#eff6ff;color:#1e40af">Your project manager <b>'
      || DBMS_XMLGEN.CONVERT(l_mgr_label) || '</b> has no email address on '
      || 'file, so they were not notified. They can still approve this claim '
      || 'in the app.</td></tr>';
  END IF;

  l_body := l_body || CHR(10)
         || 'Open the Expenses app to view or act on this claim.' || CHR(10);

  l_html := '<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#0f172a">'
         || '<p>' || DBMS_XMLGEN.CONVERT(l_greeting) || '</p>'
         || '<p>This e-mail generated based on action performed by <b>'
         || DBMS_XMLGEN.CONVERT(l_actor_label) || '</b>.</p>'
         || '<p style="font-weight:700;margin-bottom:6px">Expense Claim</p>'
         || '<table style="border-collapse:collapse;border:1px solid #ddd">'
         || l_rows
         || '</table>'
         || '<p style="color:#64748b;font-size:12px">Open the Expenses app to '
         || 'view or act on this claim.</p></div>';

  ------------------------------------------------------------------------------
  -- Send
  ------------------------------------------------------------------------------
  l_from      := NVL(secret('MAIL_FROM'), 'noreply@trinamix.com');
  l_workspace := secret('MAIL_WORKSPACE');

  BEGIN
    IF l_workspace IS NOT NULL THEN
      APEX_UTIL.SET_WORKSPACE(p_workspace => l_workspace);
    END IF;

    APEX_MAIL.SEND(
      p_to        => l_to,
      p_cc        => l_cc,
      p_from      => l_from,
      p_subj      => l_subject,
      p_body      => l_body,
      p_body_html => l_html
    );

    log_it('QUEUED');
    APEX_MAIL.PUSH_QUEUE;      -- SEND only queues; this hands it to the server

    UPDATE expense_mail_log SET status = 'PUSHED'
    WHERE  id = (SELECT MAX(id) FROM expense_mail_log
                 WHERE expense_id = p_expense_id AND event = p_event);
    COMMIT;

  EXCEPTION
    WHEN OTHERS THEN
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
-- STEP 4 of 6   --   process_expense_action
-- Passes get_reviewer_role's answer as the actor role.
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
      send_expense_mail(p_expense_id, 'MANAGER_ACCEPTED', p_emp_id, p_comment, l_role);

      send_push_notification(l_emp_owner, 'Approved by Manager',
        'Your expense #' || p_expense_id || ' was approved by your project manager — now with Finance.', p_expense_id);
      IF l_finance_empid IS NOT NULL THEN
        send_push_notification(l_finance_empid, 'Approval Needed',
          'An expense approved by its project manager is waiting for your review.', p_expense_id);
      END IF;

    ELSE -- FINANCE_MANAGER accepting = final approval
      UPDATE expenses SET status = 'APPROVED', current_stage = NULL WHERE id = p_expense_id;

      send_expense_mail(p_expense_id, 'FINANCE_ACCEPTED', p_emp_id, p_comment, l_role);

      send_push_notification(l_emp_owner, 'Expense Approved',
        'Your expense #' || p_expense_id || ' was fully approved.', p_expense_id);
    END IF;

  ELSIF p_action = 'REVISED' THEN
    UPDATE expenses SET status = 'REVISION_REQUESTED' WHERE id = p_expense_id;

    -- Was mailed to the manager and Finance, and NOT to the employee -- the
    -- one person who has to act on it.
    send_expense_mail(p_expense_id, 'REVISED', p_emp_id, p_comment, l_role);

    send_push_notification(l_emp_owner, 'Revision Needed',
      'Your expense #' || p_expense_id || ' needs changes before it can be approved.' ||
      CASE WHEN p_comment IS NOT NULL THEN ' Comment: ' || p_comment ELSE '' END,
      p_expense_id);

  ELSIF p_action = 'REJECTED' THEN
    UPDATE expenses SET status = 'REJECTED', current_stage = NULL WHERE id = p_expense_id;

    -- Same fix: the employee was never told their claim was rejected.
    send_expense_mail(p_expense_id, 'REJECTED', p_emp_id, p_comment, l_role);

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
-- STEP 5 of 6   --   POST /expenses/{{id}}/submit
-- Verbatim from PROD_4. DEFINE_HANDLER replaces the whole body.
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
-- STEP 6 of 6   --   Verify
-- Everything VALID, config present, and which claims cannot be routed.
--------------------------------------------------------------------------------


SELECT object_name, object_type, status
FROM   user_objects
WHERE  object_name IN ('SEND_EXPENSE_MAIL','PROCESS_EXPENSE_ACTION','EXPENSE_MAIL_LOG')
ORDER  BY object_name;

SELECT secret_name, secret_value
FROM   app_secrets
WHERE  secret_name IN ('MAIL_FROM','MAIL_WORKSPACE')
ORDER  BY secret_name;

-- The live handler must call send_expense_mail and hold no inline APEX_MAIL.
SELECT CASE WHEN INSTR(h.source,'send_expense_mail') > 0 THEN 'Y' ELSE 'N' END AS uses_new_mail,
       CASE WHEN INSTR(h.source,'APEX_MAIL')        > 0 THEN 'Y' ELSE 'N' END AS still_inline
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND    t.uri_template = ':id/submit' AND h.method = 'POST';

-- Claims with no project manager: these mail the submitter with a warning,
-- and nobody can approve them. A data problem, not a code one.
SELECT e.id, e.status, e.emp_id, e.project_id, pm.project_name
FROM   expenses e
LEFT   JOIN projectmaster pm ON pm.project_id = e.project_id
WHERE  e.manager_empid IS NULL
AND    e.status IN ('SUBMITTED','REVISION_REQUESTED')
ORDER  BY e.id;


--------------------------------------------------------------------------------
-- THEN TEST, and read the log -- the part that used to be invisible.
--
--   BEGIN send_expense_mail(<expense id>, 'SUBMITTED'); END;
--   /
--
--   SELECT created_at, event, status, mail_to, mail_cc, subject, error_text
--   FROM   expense_mail_log ORDER BY id DESC FETCH FIRST 10 ROWS ONLY;
--
--   PUSHED  -> handed to the mail server. Nothing arriving after that is SMTP
--              or spam filtering of MAIL_FROM, not the database.
--   FAILED  -> error_text holds the full stack.
--   SKIPPED -> nobody to send to; almost always a missing COMPANY_EMAIL.
--
-- Use a claim whose employee and project manager are DIFFERENT people, or CC
-- will be empty -- correctly, since the CC builder drops anyone already in TO.
--------------------------------------------------------------------------------
