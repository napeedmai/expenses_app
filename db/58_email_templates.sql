--------------------------------------------------------------------------------
-- 58_email_templates.sql
--
-- Run as the application schema, after 56 and 57. Idempotent.
-- Replaces send_expense_mail with the full Expense Claim layout.
--
-- Sends both a plain-text and an HTML body. Outlook shows the HTML table;
-- anything that cannot renders the text version. The old version sent text
-- only, with no table and no names or ecodes.
--
--
-- WHAT EACH EVENT NOW SENDS
-- -------------------------
--
--   SUBMITTED          TO project manager   CC employee
--     Dear <PM>, action performed by <submitter>
--     Project Name / Claim Date / Claim For / bill no / Currency / Claim Amount
--
--   MANAGER_ACCEPTED   TO finance manager   CC project manager + employee
--     Dear <FM>, action performed by <PM> (PM)
--     full claim block + Manager Remarks
--
--   FINANCE_ACCEPTED   TO employee          CC project manager
--     Dear <submitter>, action performed by <FM> (FM)
--     full claim block + Manager Remarks + Fin.Manager Remarks + Approved Amount
--
--   REVISED / REJECTED TO employee          CC project manager
--     Dear <submitter>, action performed by <actor> (PM or FM)
--     full claim block + "<Manager|Fin.Manager> Remarks: <reason>"
--
--
-- TWO THINGS TO CHECK, BOTH DELIBERATE
-- ------------------------------------
-- 1. SUBMITTED goes TO the project manager, CC the employee. The spec said
--    "to: employee and cc : PM" but the greeting was "Dear PM", and the
--    original requirement was "a mail to the project manager and cc the
--    submitted person". Greeting and original requirement agree, so that is
--    what is implemented. Swap l_to and l_cc in the SUBMITTED branch if the
--    other reading was intended.
--
-- 2. CC on REVISED/REJECTED is now UNCONDITIONAL, matching the latest
--    instruction ("to employee and cc to manger"). It was previously
--    conditional on Finance being the actor. The manager is therefore copied
--    on his own decision when he is the one revising or rejecting.
--
--
-- "Approved Amount" uses the claim amount. There is no separate approved-amount
-- column in EXPENSES -- partial approval is not a feature. If it is ever
-- needed, add the column first; do not quietly reinterpret this field.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON


CREATE OR REPLACE PROCEDURE send_expense_mail(
  p_expense_id  IN NUMBER,
  p_event       IN VARCHAR2,
  p_actor_empid IN NUMBER DEFAULT NULL,
  p_comment     IN VARCHAR2 DEFAULT NULL
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
    l_body := l_body || RPAD(p_label, 22) || NVL(p_value, '-') || CHR(10);
    l_rows := l_rows
      || '<tr><td style="padding:4px 10px;border:1px solid #ddd;background:#f8fafc;'
      || 'white-space:nowrap"><b>' || p_label || '</b></td>'
      || '<td style="padding:4px 10px;border:1px solid #ddd">'
      || NVL(DBMS_XMLGEN.CONVERT(p_value), '-') || '</td></tr>';
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
         e.project_id, e.amount, e.currency, e.amount_usd, e.type, e.bill_no, e.submitted_at
  INTO   l_emp_id, l_mgr_id, l_fin_id,
         l_project_id, l_amount, l_currency, l_amount_usd, l_type, l_bill_no, l_submitted_at
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
    IF r.empid = l_emp_id THEN
      l_emp_name  := r.full_name;
      l_emp_email := r.company_email;
      l_emp_label := r.full_name || '(' || r.ecode || ')';
    END IF;
    IF r.empid = l_mgr_id THEN
      l_mgr_name  := r.full_name;
      l_mgr_email := r.company_email;
      l_mgr_label := r.full_name || '(' || r.ecode || ')';
    END IF;
    IF r.empid = l_fin_id THEN
      l_fin_name  := r.full_name;
      l_fin_email := r.company_email;
      l_fin_label := r.full_name || '(' || r.ecode || ')';
    END IF;
  END LOOP;

  -- Actor. is_finance_manager decides the role rather than comparing against
  -- manager_empid, because the same person can be both on different claims.
  IF p_actor_empid IS NOT NULL THEN
    l_actor_role := CASE WHEN is_finance_manager(p_actor_empid) = 'Y' AND p_event IN
                              ('FINANCE_ACCEPTED','REVISED','REJECTED')
                         THEN 'FM' ELSE 'PM' END;
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
    l_to        := l_mgr_email;
    l_cc        := cc_list(l_emp_email);
    l_greeting  := 'Dear ' || NVL(l_mgr_name, 'Project Manager');
    l_actor_label := l_emp_name;
    l_subject   := 'Expense #' || p_expense_id || ' awaiting your approval';

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
  ELSE
    add_row('Employee(Ecode):', l_emp_label);
    add_row('Manager (Ecode):', l_mgr_label);
    add_row('Fin.Mgr(Ecode):', l_fin_label);
    add_row('Claim For:', l_type);
    add_row('bill no:', l_bill_no);
    add_row('Currency:', l_currency);
    add_row('bill Amount:', TO_CHAR(l_amount) || ' ' || l_currency);

    IF p_event = 'FINANCE_ACCEPTED' THEN
      add_row('Manager Remarks:', l_mgr_remarks);
      add_row('Fin.Manager Remarks:', l_fin_remarks);
      add_row('Approved Amount:', TO_CHAR(l_amount) || ' ' || l_currency);
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
-- Verify, then preview each template without sending.
--------------------------------------------------------------------------------
SELECT object_name, status FROM user_objects
WHERE  object_name = 'SEND_EXPENSE_MAIL';

-- Fire all four against a real expense id and read the log. Recipients come
-- from the row, so use one that has a project, a manager and an amount.
--
--   SET SERVEROUTPUT ON
--   BEGIN
--     send_expense_mail(1, 'SUBMITTED',        NULL);
--     send_expense_mail(1, 'MANAGER_ACCEPTED', <pm empid>,  'Looks fine to me');
--     send_expense_mail(1, 'FINANCE_ACCEPTED', 3725,        'Approved');
--     send_expense_mail(1, 'REVISED',          3725,        'Please attach the invoice');
--   END;
--   /
--
--   SELECT created_at, event, status, mail_to, mail_cc, subject, error_text
--   FROM   expense_mail_log ORDER BY id DESC FETCH FIRST 10 ROWS ONLY;
--
-- To see the rendered body before anyone receives it:
--
--   SELECT mail_to, mail_cc, mail_subj, mail_body
--   FROM   apex_mail_queue ORDER BY mail_message_created DESC;


--------------------------------------------------------------------------------
-- IF MAIL_CC COMES BACK EMPTY
--
-- It is probably correct. cc_list drops anyone who is already the TO
-- recipient, and on a claim where the submitter is also the project manager
-- both addresses are the same person -- so CC is deliberately empty rather
-- than sending them a copy of their own mail. Test with a claim whose employee
-- and manager are different people before concluding CC is broken.
--------------------------------------------------------------------------------
