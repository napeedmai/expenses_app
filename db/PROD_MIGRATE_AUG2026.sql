--==============================================================================
--
--  PROD_MIGRATE_AUG2026.sql
--
--  ONE FILE. Run it in APEX -> SQL Workshop -> SQL SCRIPTS.
--  *** NOT SQL Commands. *** SQL Commands silently skipped a whole section of
--  script 64 and is the reason prod and dev diverged in the first place.
--
--    prod = karyasiddhi.trinamix.com      /ords/repo   schema REPO
--    dev  = karyasiddhitest.trinamix.com  /ords/repo   schema HRMS
--
--  Verified working on HRMS (dev) before being assembled for REPO.
--
--
--  WHAT THIS IS
--  ------------
--  Scripts 70, 71, 72, 73, 75, 76, 77 and 69 concatenated in dependency order,
--  with their individual verification sections removed and replaced by ONE
--  verification at the end. Each part keeps its own guards and its own header
--  explaining what it fixes and why.
--
--  Nothing here was retyped. Every handler body and every procedure was lifted
--  programmatically from the file that owns it.
--
--
--  SECTION MAP
--  -----------
--    1   70   send_expense_mail reads the BILLS; adds the bill table to both
--             email bodies. Prod has been mailing reviewers a blank bill number
--             and no bill list since multi-bill shipped.
--    2   71   five handlers stop naming the eight columns db/64 dropped
--    3   72   currencies + exchange-rate templates, created only if absent
--    4   73   nine handlers reinstalled: whoami, my-projects, push-token,
--             :id/accept|revise|reject, bulk-accept|revise|reject
--    5   75   exchange-rate accepts ISO as well as MM/DD/YYYY
--    6   76   my-projects and whoami name both approvers up front
--    7   77   :id/attachment answers 410 Gone instead of nothing
--    8   69   expenses.authenticated rebuilt from an explicit pattern list
--    9        VERIFY -- must end PASS
--
--
--  THE ORDER IS NOT ARBITRARY
--  --------------------------
--    * 71 before 73. Section 4 refuses to run if GET mine still references
--      e.bill_no, because that means PROD_4_endpoints.sql has been run and has
--      undone the multi-bill work. On prod that IS the state until section 2
--      fixes it -- so running 73 first would abort, correctly.
--    * 72 before 75. 75 patches the exchange-rate handler; 72 is what makes
--      sure there is a template to patch.
--    * 73 before 76. 73 installs whoami and my-projects from PROD_4; 76 then
--      adds the approver fields. Reversed, 73 silently reverts 76.
--    * 70 before everything. It recompiles process_expense_action, and doing
--      that mid-way through handler changes makes a failure hard to attribute.
--
--
--  SAFE TO RE-RUN. Every section is idempotent. Templates are created only when
--  absent; handlers are replaced wholesale, which is how ORDS works anyway.
--
--  NOTHING HERE DELETES DATA. No DROP, no DELETE, no TRUNCATE, no ALTER TABLE.
--  Take the snapshot in step 1 of PROD_MIGRATION.md anyway.
--
--  NOTHING HERE CALLS ORDS.DEFINE_MODULE. That is the one genuinely destructive
--  call in this codebase -- it deletes every template in the module -- and it is
--  what emptied dev. It appears nowhere below.
--
--
--  IF A SECTION FAILS
--  ------------------
--  APEX runs the remaining sections regardless. That is survivable because each
--  one guards its own prerequisites and raises -20001 with a SENTENCE rather
--  than changing anything: a single failure tends to produce more guard messages
--  downstream, not damage.
--
--  So: read the output top to bottom and find the FIRST -20001. Fix that, then
--  re-run the whole file. Do not pick out one section to re-run.
--
--
--  THIS IS A BREAKING API CHANGE
--  ----------------------------
--  After section 2, GET /expenses/mine, /pending and /:id stop returning
--  bill_no, bill_date, type, description and attachment_filename. ANY APP BUILD
--  OLDER THAN THE MULTI-BILL REWRITE WILL BREAK. Confirm nobody is on an old
--  build before running this.
--
--  And one visible regression ships with it: HomeScreen groups spending by a
--  claim-level `type` that no longer exists, so every claim will file under
--  "Other" until that screen gets a bill-level aggregate.
--
--
--  AFTERWARDS
--  ----------
--    * src/config.js must point at karyasiddhi.trinamix.com before any build.
--      API_BASE_URL is compiled into the bundle.
--    * Test a claim with TWO BILLS IN DIFFERENT CURRENCIES and read the email.
--      That is the case the old send_expense_mail got wrong in every possible
--      way, and the only one that proves section 1 worked.
--    * 67_multibill_stage5_cleanup.sql drops the eight legacy columns. Safe
--      after this, needed by nothing. Leave it a while.
--==============================================================================


SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF
SET LINESIZE 200


--==============================================================================
-- SECTION 0   --   Where am I, and is this the right database?
--==============================================================================
DECLARE
  l_schema VARCHAR2(128) := SYS_CONTEXT('USERENV','CURRENT_SCHEMA');
  l_n      NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('==================================================');
  DBMS_OUTPUT.PUT_LINE('Connected as: ' || l_schema);
  DBMS_OUTPUT.PUT_LINE(CASE l_schema
    WHEN 'REPO' THEN '  ** PRODUCTION ** (karyasiddhi.trinamix.com)'
    WHEN 'HRMS' THEN '  dev (karyasiddhitest.trinamix.com)'
    ELSE '  UNRECOGNISED SCHEMA -- stop and find out where you are' END);
  DBMS_OUTPUT.PUT_LINE('==================================================');

  SELECT COUNT(*) INTO l_n FROM user_tables WHERE table_name = 'EXPENSE_ITEMS';
  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'No EXPENSE_ITEMS table on ' || l_schema || '. The multi-bill schema '
      || '(64/65/66) is not installed here, so there is nothing for this '
      || 'migration to fix. WRONG SCHEMA, or wrong database. Nothing changed.');
  END IF;

  -- Not a failure either way -- just say which shape we are on, because it
  -- decides whether the faults below were visible or silent.
  SELECT COUNT(*) INTO l_n FROM user_tab_columns
  WHERE  table_name = 'EXPENSES'
  AND    column_name IN ('BILL_NO','BILL_DATE','TYPE','DESCRIPTION',
                         'ATTACHMENT_BLOB','ATTACHMENT_FILENAME',
                         'ATTACHMENT_MIME_TYPE','ATTACHMENT_PATH');

  IF l_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('Legacy columns gone -- section 3 of script 64 ran here.');
    DBMS_OUTPUT.PUT_LINE('The faults below were VISIBLE on this schema (403s, 555s).');
  ELSE
    DBMS_OUTPUT.PUT_LINE(l_n || ' legacy column(s) still on EXPENSES -- section 3 of '
      || 'script 64 did NOT run here.');
    DBMS_OUTPUT.PUT_LINE('The faults below were SILENT on this schema: handlers '
      || 'compiled, emails sent, and the bill details were simply blank.');
  END IF;

  SELECT COUNT(h.id) INTO l_n
  FROM   user_ords_modules m
  LEFT   JOIN user_ords_templates t ON t.module_id = m.id
  LEFT   JOIN user_ords_handlers  h ON h.template_id = t.id
  WHERE  m.name = 'expenses.employee';
  DBMS_OUTPUT.PUT_LINE('Module has ' || l_n || ' handler(s) before this run. '
    || '(A healthy schema ends with 26.)');
END;
/


--==============================================================================
-- SECTION 1   --   from 70_email_multibill.sql
-- send_expense_mail reads the BILLS
--==============================================================================

--------------------------------------------------------------------------------
-- 0. Right schema, and the prerequisites the new body needs.
--------------------------------------------------------------------------------
DECLARE
  l_schema VARCHAR2(128) := SYS_CONTEXT('USERENV','CURRENT_SCHEMA');
  l_n      NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Connected as: ' || l_schema);
  DBMS_OUTPUT.PUT_LINE('  HRMS = dev (karyasiddhitest), REPO = PRODUCTION (karyasiddhi).');

  SELECT COUNT(*) INTO l_n FROM user_tables WHERE table_name = 'EXPENSE_ITEMS';
  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'No EXPENSE_ITEMS table on ' || l_schema || '. Run 64_multibill_stage1_clean.sql '
      || 'here first -- this email body reads it. Nothing changed.');
  END IF;

  SELECT COUNT(*) INTO l_n FROM user_tab_columns
  WHERE  table_name = 'EXPENSES' AND column_name = 'CLAIM_FOR';
  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'EXPENSES.CLAIM_FOR does not exist on ' || l_schema || '. Script 64 has not '
      || 'run here. Nothing changed.');
  END IF;

  SELECT COUNT(*) INTO l_n FROM user_tables WHERE table_name = 'EXPENSE_MAIL_LOG';
  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'No EXPENSE_MAIL_LOG on ' || l_schema || '. Run EMAIL_DEPLOY.sql here first. '
      || 'Nothing changed.');
  END IF;

  SELECT COUNT(*) INTO l_n FROM user_objects
  WHERE  object_name = 'PROCESS_EXPENSE_ACTION' AND object_type = 'PROCEDURE';
  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'PROCESS_EXPENSE_ACTION not found on ' || l_schema || '. Run EMAIL_DEPLOY.sql '
      || 'then 62 here first. Nothing changed.');
  END IF;

  DBMS_OUTPUT.PUT_LINE('Prerequisites OK.');
END;
/


--------------------------------------------------------------------------------
-- 1. send_expense_mail -- multi-bill aware. FIRST, because 2 depends on it.
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
  p_actor_role  IN VARCHAR2 DEFAULT NULL,
  -- Values the CALLER has just written but NOT yet committed.
  --
  -- This procedure is AUTONOMOUS, so it runs in its own transaction and cannot
  -- see the caller's uncommitted work. On submit that is fatal: the handler
  -- sets manager_empid and submitted_at, then calls this -- which re-reads the
  -- row and still sees an unsubmitted draft with no manager. The result was an
  -- email to the employee saying "no project manager is assigned", about a
  -- claim that had one.
  --
  -- Autonomy is still wanted: the mail log must survive a rolled-back
  -- approval, and APEX_MAIL.PUSH_QUEUE commits, which must not commit the
  -- caller's half-finished transaction. So instead of reading these three,
  -- the caller passes them. NULL means "not known, read from the row", which
  -- is correct for a manual call after the fact.
  p_manager_empid IN NUMBER    DEFAULT NULL,
  p_finance_empid IN NUMBER    DEFAULT NULL,
  p_submitted_at  IN TIMESTAMP DEFAULT NULL
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
  -- Was l_type / l_bill_no, read from EXPENSES. Those columns are gone: a
  -- claim no longer HAS one type or one bill number, its bills do. See
  -- MULTI_BILL_PLAN.md.
  l_claim_for    VARCHAR2(400);
  l_item_count   NUMBER := 0;
  l_ccy_count    NUMBER := 0;
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
  l_bill_text    CLOB;   -- the bill list, plain
  l_bill_html    CLOB;   -- the bill list, HTML
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

  -- The claim total, in USD, as stamped on the row by recalc_claim_totals --
  -- not a fresh conversion. Restating an approved claim at today's rate would
  -- make the email disagree with the record.
  --
  -- USD ONLY, deliberately. EXPENSES.AMOUNT is now SUM(items.amount) across
  -- bills that may be in different currencies, so 4500 with a currency label
  -- of INR would be a fabrication when one bill was in EUR. The USD column is
  -- the only claim-level figure that means anything. Per-bill amounts appear
  -- in their own currency in the bill table below.
  FUNCTION total_usd_row RETURN VARCHAR2 IS
  BEGIN
    IF l_amount_usd IS NULL THEN
      RETURN NULL;   -- renders as '-'
    END IF;
    RETURN TO_CHAR(l_amount_usd) || ' USD'
           || CASE WHEN l_item_count > 0
                   THEN '   (' || l_item_count || ' bill'
                        || CASE WHEN l_item_count = 1 THEN '' ELSE 's' END || ')'
              END;
  END;

  -- The bill list. This is the substance of the email now -- the reviewer is
  -- being asked to approve a set of bills, and without this they see only a
  -- total and have to open the app to find out what it is made of.
  --
  -- Reads EXPENSE_ITEMS. Safe from an autonomous transaction because bills are
  -- saved and committed one request at a time, long before submit runs. The
  -- header columns are the ones that are uncommitted at that moment, which is
  -- why those arrive as parameters instead.
  PROCEDURE bill_table IS
  BEGIN
    IF l_item_count = 0 THEN
      l_bill_text := CHR(10) || 'This claim has no bills on it.' || CHR(10);
      l_bill_html := '<p style="padding:8px 10px;border:1px solid #f59e0b;'
        || 'background:#fef3c7;color:#92400e">This claim has no bills on it.</p>';
      RETURN;
    END IF;

    l_bill_text := CHR(10) || 'Bills (' || l_item_count || ')' || CHR(10)
                || RPAD('-', 60, '-') || CHR(10);
    l_bill_html := '<p style="font-weight:700;margin:14px 0 6px">Bills ('
                || l_item_count || ')</p>'
                || '<table style="border-collapse:collapse;border:1px solid #ddd;'
                || 'font-size:13px">'
                || '<tr style="background:#f1f5f9">'
                || '<th style="padding:4px 8px;border:1px solid #ddd">#</th>'
                || '<th style="padding:4px 8px;border:1px solid #ddd">Type</th>'
                || '<th style="padding:4px 8px;border:1px solid #ddd">Description</th>'
                || '<th style="padding:4px 8px;border:1px solid #ddd">Bill No</th>'
                || '<th style="padding:4px 8px;border:1px solid #ddd">Bill Date</th>'
                || '<th style="padding:4px 8px;border:1px solid #ddd">Period</th>'
                || '<th style="padding:4px 8px;border:1px solid #ddd">Amount</th>'
                || '<th style="padding:4px 8px;border:1px solid #ddd">USD</th></tr>';

    FOR b IN (SELECT item_no, bill_no, bill_date, type, description,
                     from_date, to_date, currency, amount, exchange_rate,
                     amount_usd, attachment_filename
              FROM   expense_items
              WHERE  expense_id = p_expense_id
              ORDER  BY item_no)
    LOOP
      l_bill_text := l_bill_text
        || b.item_no || '. ' || NVL(b.type, '-')
        || ' -- ' || NVL(b.description, '-') || CHR(10)
        || '     bill no ' || NVL(b.bill_no, '-')
        || ',  dated ' || NVL(TO_CHAR(b.bill_date, 'DD-Mon-YYYY'), '-') || CHR(10)
        || '     ' || NVL(TO_CHAR(b.from_date, 'DD-Mon-YYYY'), '-')
        || ' to '  || NVL(TO_CHAR(b.to_date,   'DD-Mon-YYYY'), '-') || CHR(10)
        || '     ' || TO_CHAR(b.amount) || ' ' || b.currency
        || '  =  ' || NVL(TO_CHAR(b.amount_usd), '-') || ' USD'
        || CASE WHEN b.exchange_rate IS NOT NULL AND b.currency != 'USD'
                THEN '   (1 ' || b.currency || ' = ' || TO_CHAR(b.exchange_rate) || ' USD)'
           END || CHR(10)
        || '     receipt: ' || NVL(b.attachment_filename, 'NONE') || CHR(10) || CHR(10);

      l_bill_html := l_bill_html
        || '<tr>'
        || '<td style="padding:4px 8px;border:1px solid #ddd">' || b.item_no || '</td>'
        || '<td style="padding:4px 8px;border:1px solid #ddd">'
        || NVL(DBMS_XMLGEN.CONVERT(b.type), '-') || '</td>'
        || '<td style="padding:4px 8px;border:1px solid #ddd">'
        || NVL(DBMS_XMLGEN.CONVERT(b.description), '-') || '</td>'
        || '<td style="padding:4px 8px;border:1px solid #ddd">'
        || NVL(DBMS_XMLGEN.CONVERT(b.bill_no), '-') || '</td>'
        || '<td style="padding:4px 8px;border:1px solid #ddd;white-space:nowrap">'
        || NVL(TO_CHAR(b.bill_date, 'DD-Mon-YYYY'), '-') || '</td>'
        || '<td style="padding:4px 8px;border:1px solid #ddd;white-space:nowrap">'
        || NVL(TO_CHAR(b.from_date, 'DD-Mon-YYYY'), '-') || ' to '
        || NVL(TO_CHAR(b.to_date,   'DD-Mon-YYYY'), '-') || '</td>'
        || '<td style="padding:4px 8px;border:1px solid #ddd;text-align:right;'
        || 'white-space:nowrap">' || TO_CHAR(b.amount) || ' ' || b.currency || '</td>'
        || '<td style="padding:4px 8px;border:1px solid #ddd;text-align:right;'
        || 'white-space:nowrap">' || NVL(TO_CHAR(b.amount_usd), '-') || '</td>'
        || '</tr>';
    END LOOP;

    l_bill_html := l_bill_html
      || '<tr style="background:#f8fafc">'
      || '<td colspan="7" style="padding:4px 8px;border:1px solid #ddd;'
      || 'text-align:right"><b>Total</b></td>'
      || '<td style="padding:4px 8px;border:1px solid #ddd;text-align:right;'
      || 'white-space:nowrap"><b>' || NVL(TO_CHAR(l_amount_usd), '-')
      || ' USD</b></td></tr></table>';

    l_bill_text := l_bill_text
      || RPAD('-', 60, '-') || CHR(10)
      || RPAD('Total (USD):', 22) || NVL(TO_CHAR(l_amount_usd), '-') || CHR(10);

    -- Worth saying out loud. A reviewer who sees three amounts and a USD total
    -- that is not their sum should be told why, not left to suspect an error.
    IF l_ccy_count > 1 THEN
      l_bill_text := l_bill_text || CHR(10)
        || 'Bills are in ' || l_ccy_count || ' different currencies, so the'  || CHR(10)
        || 'total is given in USD only -- each bill was converted at the'     || CHR(10)
        || 'rate for its own From Date.' || CHR(10);
      l_bill_html := l_bill_html
        || '<p style="color:#64748b;font-size:12px">Bills are in '
        || l_ccy_count || ' different currencies, so the total is given in USD '
        || 'only. Each bill was converted at the rate for its own From Date.</p>';
    END IF;
  END bill_table;

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
         e.claim_for, e.submitted_at
  INTO   l_emp_id, l_mgr_id, l_fin_id,
         l_project_id, l_amount, l_currency, l_amount_usd, l_exchange_rate,
         l_claim_for, l_submitted_at
  FROM   expenses e
  WHERE  e.id = p_expense_id;

  -- Caller's values win. Without this the three lines below read stale data
  -- on the submit path and the whole email is about the wrong situation.
  l_mgr_id       := NVL(p_manager_empid, l_mgr_id);
  l_fin_id       := NVL(p_finance_empid, l_fin_id);
  l_submitted_at := NVL(p_submitted_at,  l_submitted_at);

  SELECT COUNT(*), COUNT(DISTINCT currency)
  INTO   l_item_count, l_ccy_count
  FROM   expense_items
  WHERE  expense_id = p_expense_id;

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
    add_row('Claim For:', l_claim_for);
    add_row('Claim Total (USD):', total_usd_row);
  ELSE
    add_row('Employee(Ecode):', l_emp_label);
    add_row('Manager (Ecode):', l_mgr_label);
    add_row('Fin.Mgr(Ecode):', l_fin_label);
    add_row('Claim For:', l_claim_for);
    add_row('Claim Total (USD):', total_usd_row);

    IF p_event = 'FINANCE_ACCEPTED' THEN
      add_row('Manager Remarks:', l_mgr_remarks);
      add_row('Fin.Manager Remarks:', l_fin_remarks);
      add_row('Approved Amount:', total_usd_row);
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

  bill_table;
  l_body := l_body || l_bill_text;

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
         || l_bill_html
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
-- 2. Recompile everything that went stale.
--
-- process_expense_action needs no source change -- it was only ever INVALID
-- because it calls send_expense_mail. recalc_claim_totals and the two triggers
-- on EXPENSES were invalidated by script 64's ALTER TABLE, which is normal and
-- clears on recompile; they are listed here so the run ends with nothing
-- INVALID rather than leaving ORDS to trip over one of them later.
--
-- ONLY the app's own objects. HRMS is a shared schema with roughly 190
-- pre-existing INVALID objects belonging to other systems. DBMS_UTILITY.
-- COMPILE_SCHEMA would touch all of them and is not ours to run.
--------------------------------------------------------------------------------
ALTER PROCEDURE process_expense_action COMPILE;
ALTER PROCEDURE recalc_claim_totals    COMPILE;


--==============================================================================
-- SECTION 2   --   from 71_handlers_drop_legacy_columns.sql
-- five handlers stop naming dropped columns
--==============================================================================

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


--==============================================================================
-- SECTION 3   --   from 72_restore_currency_endpoints.sql
-- currencies + exchange-rate templates
--==============================================================================

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


--==============================================================================
-- SECTION 4   --   from 73_restore_missing_handlers.sql
-- nine handlers reinstalled
--==============================================================================

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


--==============================================================================
-- SECTION 5   --   from 75_exchange_rate_date_parse_fix.sql
-- exchange-rate accepts ISO
--==============================================================================

--------------------------------------------------------------------------------
-- 0. Prove the point before changing anything.
--
-- This is the whole bug in four rows. Run it and read it -- it is worth seeing
-- once, because the wrong form gives no error at all.
--------------------------------------------------------------------------------
SELECT 'wrong: clause on the FORMAT'  AS variant,
       TO_DATE('2026-08-25', 'YYYY-MM-DD' DEFAULT NULL ON CONVERSION ERROR) AS result
FROM   dual
UNION ALL
SELECT 'right: clause on the VALUE',
       TO_DATE('2026-08-25' DEFAULT NULL ON CONVERSION ERROR, 'YYYY-MM-DD')
FROM   dual
UNION ALL
SELECT 'right, and genuinely bad input',
       TO_DATE('21-08-2026' DEFAULT NULL ON CONVERSION ERROR, 'YYYY-MM-DD')
FROM   dual
UNION ALL
SELECT 'plain TO_DATE, valid ISO',
       TO_DATE('2026-08-25', 'YYYY-MM-DD')
FROM   dual;
-- Row 1 NULL is the bug. Rows 2 and 4 must show 25-AUG-26. Row 3 NULL is
-- correct behaviour.


--------------------------------------------------------------------------------
-- 1. Prerequisites.
--------------------------------------------------------------------------------
DECLARE
  l_n NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Connected as: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
  DBMS_OUTPUT.PUT_LINE('  HRMS = dev, REPO = PRODUCTION.');

  SELECT COUNT(*) INTO l_n
  FROM   user_ords_templates t
  JOIN   user_ords_modules m ON m.id = t.module_id
  WHERE  m.name = 'expenses.employee' AND t.uri_template = 'exchange-rate';

  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'No exchange-rate template here. Run 72_restore_currency_endpoints.sql '
      || 'first. Nothing changed.');
  END IF;

  SELECT COUNT(*) INTO l_n FROM user_objects
  WHERE  object_name IN ('GET_EXCHANGE_RATE','GET_RATE_EFFECTIVE_DATE')
  AND    object_type = 'FUNCTION' AND status = 'VALID';

  IF l_n < 2 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'get_exchange_rate / get_rate_effective_date are not both VALID here. '
      || 'Nothing changed.');
  END IF;

  DBMS_OUTPUT.PUT_LINE('Prerequisites OK.');
END;
/


--------------------------------------------------------------------------------
-- 2. GET /expenses/exchange-rate  --  date parsing that actually works.
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

        -- ACCEPT BOTH DATE FORMATS.
        --
        -- This endpoint was written before multi-bill and only ever parsed
        -- MM/DD/YYYY. Every endpoint added since speaks ISO, and BillSheet.js
        -- calls it through isoFromMDY() -- so it was sending '2026-08-21',
        -- Oracle read '2026' as a month, and the screen showed the user
        -- "ORA-01843: not a valid month". A client/server format mismatch
        -- reported as a database error, which is the least useful form it
        -- could possibly take.
        --
        -- This is FORMAT-ONLY detection, not guesswork: '2026-08-21' cannot be
        -- MM/DD/YYYY and '08/21/2026' cannot be ISO, so there is no ambiguous
        -- case to get wrong. Both are accepted rather than picking one, because
        -- the app is not the only possible caller and a date parameter that
        -- rejects the format half the codebase uses is a trap.
        IF :on_date IS NULL THEN
          l_on_date := SYSDATE;
        ELSE
          -- Try ISO, then MM/DD/YYYY, using nested exception blocks.
          --
          -- Script 74 tried to do this by hanging a DEFAULT-ON-CONVERSION-ERROR
          -- clause off TO_DATE's FORMAT argument, which is wrong -- the clause
          -- belongs to TO_DATE's FIRST
          -- argument, not to the format model. Written that way it still
          -- compiles and it returns NULL for EVERY input, so a perfectly good
          -- '2026-08-25' came back as "could not read on_date". The idiom was
          -- copied from the TO_NUMBER(:amount DEFAULT ...) line above, where
          -- the position happens to be right.
          --
          -- Doing it with exception blocks instead of fixing the placement:
          -- it needs no particular Oracle version, it cannot be got subtly
          -- wrong in the same way, and it also catches a well-formed date that
          -- is not a real one -- '2026-13-45' matches the ISO shape and is
          -- still not a date.
          --
          -- SUBSTR so an ISO value carrying a time component still parses.
          BEGIN
            l_on_date := TO_DATE(SUBSTR(:on_date, 1, 10), 'YYYY-MM-DD');
          EXCEPTION
            WHEN OTHERS THEN
              BEGIN
                l_on_date := TO_DATE(:on_date, 'MM/DD/YYYY');
              EXCEPTION
                WHEN OTHERS THEN
                  l_on_date := NULL;
              END;
          END;

          IF l_on_date IS NULL THEN
            :status := 400;
            APEX_JSON.OPEN_OBJECT;
            APEX_JSON.WRITE('error',
              'Could not read on_date "' || :on_date
              || '". Use YYYY-MM-DD or MM/DD/YYYY.');
            APEX_JSON.CLOSE_OBJECT;
            RETURN;
          END IF;
        END IF;

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
          -- Name the parameters. A bare SQLERRM sent an Oracle date-format
          -- error to a person filling in a bill, with nothing to connect it to
          -- the field that caused it.
          :status := 400;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error',
            'Could not price ' || NVL(:currency, '(no currency)')
            || ' on ' || NVL(:on_date, 'today') || ': ' || SQLERRM);
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


--==============================================================================
-- SECTION 6   --   from 76_name_the_approvers_up_front.sql
-- my-projects and whoami name the approvers
--==============================================================================

--------------------------------------------------------------------------------
-- 0. Prerequisites: both handlers must already be there, and the two functions
--    they now call must be VALID.
--------------------------------------------------------------------------------
DECLARE
  l_n NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Connected as: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
  DBMS_OUTPUT.PUT_LINE('  HRMS = dev, REPO = PRODUCTION.');

  FOR p IN (SELECT column_value AS pat
            FROM   TABLE(sys.odcivarchar2list('whoami','my-projects')))
  LOOP
    SELECT COUNT(h.id) INTO l_n
    FROM   user_ords_templates t
    JOIN   user_ords_modules m ON m.id = t.module_id
    LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
    WHERE  m.name = 'expenses.employee' AND t.uri_template = p.pat;

    IF l_n = 0 THEN
      RAISE_APPLICATION_ERROR(-20001,
        p.pat || ' has no handler on ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
        || '. Run 73_restore_missing_handlers.sql first. Nothing changed.');
    END IF;
  END LOOP;

  SELECT COUNT(*) INTO l_n FROM user_objects
  WHERE  object_name IN ('GET_PROJECT_MANAGER_EMPID','GET_FINANCE_MANAGER_EMPID')
  AND    object_type = 'FUNCTION' AND status = 'VALID';

  IF l_n < 2 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'get_project_manager_empid / get_finance_manager_empid are not both VALID '
      || 'here. Run PROD_3_business_logic.sql. Nothing changed.');
  END IF;

  DBMS_OUTPUT.PUT_LINE('Prerequisites OK.');
END;
/


--------------------------------------------------------------------------------
-- 1. GET /expenses/whoami   -- now names the finance approver.
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
             is_finance_manager(e.empid) AS is_finance_manager,
             -- Who the finance approver IS, not just whether you are them.
             -- The claim header needs to show this the moment a new expense is
             -- opened; before, the screen said "Set when you submit" because
             -- nothing told it any earlier. The id is a constant --
             -- get_finance_manager_empid is the single place it lives -- so it
             -- belongs on whoami rather than on every claim.
             get_finance_manager_empid() AS finance_manager_empid,
             (SELECT f.first_name || ' ' || f.last_name
              FROM   employeedetails f
              WHERE  f.empid = get_finance_manager_empid()) AS finance_manager_name
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

--------------------------------------------------------------------------------
-- 2. GET /expenses/my-projects   -- now names the project's manager.
--------------------------------------------------------------------------------

BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'my-projects',
    p_method      => 'GET',
    p_source_type => ords.source_type_collection_feed,
    p_source      => q'{
      SELECT DISTINCT pa.project_id,
             pm.project_name,
             -- The project's manager, so the claim header can name them as soon
             -- as a project is picked instead of waiting for submit.
             --
             -- get_project_manager_empid reads the PROJECT_MANAGER table and
             -- takes the earliest row by creation_date, sr_no. Calling it here
             -- rather than joining keeps ONE definition of "who approves this
             -- project" -- the submit handler calls the same function, so the
             -- name shown cannot disagree with the person the claim goes to.
             --
             -- NULL manager_name is real and worth showing: a project with no
             -- PROJECT_MANAGER row cannot be approved at the first stage. Better
             -- to say so while the person is still choosing than to fail at
             -- submit. Dev's project 7288 is exactly this case.
             get_project_manager_empid(pa.project_id) AS manager_empid,
             (SELECT m.first_name || ' ' || m.last_name
              FROM   employeedetails m
              WHERE  m.empid = get_project_manager_empid(pa.project_id)) AS manager_name
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


--==============================================================================
-- SECTION 7   --   from 77_retire_claim_attachment.sql
-- :id/attachment answers 410 Gone
--==============================================================================

--------------------------------------------------------------------------------
-- 0. Confirm the diagnosis rather than trusting the header above.
--
-- If ORDS.DELETE_TEMPLATE turns out to exist in this ORDS version, that is
-- worth knowing -- but this script does not need it either way.
--------------------------------------------------------------------------------
DECLARE
  l_n NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Connected as: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
  DBMS_OUTPUT.PUT_LINE('  HRMS = dev, REPO = PRODUCTION.');

  SELECT COUNT(*) INTO l_n
  FROM   all_procedures
  WHERE  owner = 'ORDS_METADATA' AND object_name = 'ORDS'
  AND    procedure_name = 'DELETE_TEMPLATE';

  IF l_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('ORDS.DELETE_TEMPLATE does not exist here -- as expected. '
      || 'Retiring the endpoint with a 410 handler instead.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('*** ORDS.DELETE_TEMPLATE DOES exist in this version. '
      || 'The 410 handler below is still the better option -- an old client gets '
      || 'told why -- but deleting the template is available if you prefer. ***');
  END IF;

  SELECT COUNT(*) INTO l_n
  FROM   user_ords_templates t
  JOIN   user_ords_modules m ON m.id = t.module_id
  WHERE  m.name = 'expenses.employee' AND t.uri_template = ':id/attachment';

  -- In the combined migration this is a SKIP, not a failure: a prod schema
  -- that never had the endpoint is already in the desired state.
  IF l_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('No :id/attachment template here -- nothing to retire. '
      || 'Skipping section 7.');
  END IF;
END;
/


--------------------------------------------------------------------------------
-- 1. POST and GET both answer 410 Gone, naming the endpoint that replaced them.
--
-- source_type_plsql for GET as well as POST: the original GET was
-- source_type_media, which streams a BLOB and has no way to write a JSON body
-- or set a status.
--------------------------------------------------------------------------------
DECLARE
  l_exists NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_exists
  FROM   user_ords_templates t
  JOIN   user_ords_modules m ON m.id = t.module_id
  WHERE  m.name = 'expenses.employee' AND t.uri_template = ':id/attachment';

  IF l_exists = 0 THEN
    DBMS_OUTPUT.PUT_LINE('  no :id/attachment template -- nothing to retire.');
    RETURN;
  END IF;

  FOR m IN (SELECT column_value AS meth
            FROM   TABLE(sys.odcivarchar2list('POST','GET')))
  LOOP
    ORDS.DEFINE_HANDLER(
      p_module_name => 'expenses.employee',
      p_pattern     => ':id/attachment',
      p_method      => m.meth,
      p_source_type => ords.source_type_plsql,
      p_source      => q'[
        BEGIN
          :status := 410;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error',
            'Receipts belong to a bill, not to a claim. This endpoint was '
            || 'retired when one claim became many bills.');
          APEX_JSON.WRITE('use_instead',
            '/expenses/' || :id || '/items/{item_id}/attachment');
          APEX_JSON.WRITE('note',
            'The replacement takes the raw file as the request body with '
            || 'Content-Type set to the file''s own MIME type. It is not '
            || 'multipart/form-data.');
          APEX_JSON.CLOSE_OBJECT;
        END;
      ]'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'expenses.employee', p_pattern => ':id/attachment',
      p_method => m.meth,
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
      p_source_type => 'HEADER', p_access_method => 'OUT');

    DBMS_OUTPUT.PUT_LINE('  ' || m.meth || ' :id/attachment -> 410 Gone');
  END LOOP;
  COMMIT;
END;
/


--==============================================================================
-- SECTION 8   --   from 69_restore_privileges.sql
-- expenses.authenticated from an explicit list
--==============================================================================

--------------------------------------------------------------------------------
-- 0. Is the login handler back? If not, stop -- 50 has not been run.
--------------------------------------------------------------------------------
DECLARE
  l_n NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Connected as: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));

  SELECT COUNT(*) INTO l_n
  FROM   user_ords_handlers h
  JOIN   user_ords_templates t ON t.id = h.template_id
  JOIN   user_ords_modules m   ON m.id = t.module_id
  WHERE  m.name = 'expenses.employee'
  AND    t.uri_template = 'auth/login' AND h.method = 'POST';

  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'auth/login POST has no handler. Run 50_fix_login_null_bypass.sql first '
      || '-- login is down until you do. Nothing changed here.');
  END IF;

  DBMS_OUTPUT.PUT_LINE('auth/login handler present. Proceeding.');
END;
/


--------------------------------------------------------------------------------
-- 1. Rebuild expenses.authenticated from an EXPLICIT list.
--
-- Every everyday endpoint. Reviewer-only paths (pending, bulk-*) belong to
-- expenses.review and must NOT appear here: ORDS refuses the same pattern in
-- two privileges with "ORA-20039: Pattern already mapped".
--
-- auth/login is deliberately absent. A pattern covering it makes login
-- impossible by construction -- you would need a Bearer token to obtain a
-- Bearer token. See DEPLOYMENT.md 13.2.
--------------------------------------------------------------------------------
DECLARE
  l_roles    owa.vc_arr;
  l_patterns owa.vc_arr;
  r          PLS_INTEGER := 0;
  p          PLS_INTEGER := 0;
  l_added    VARCHAR2(4000);

  FUNCTION mapped_elsewhere(p_pat IN VARCHAR2) RETURN VARCHAR2 IS
    l_priv VARCHAR2(200);
  BEGIN
    SELECT MAX(pr.name) INTO l_priv
    FROM   user_ords_privilege_mappings pm
    JOIN   user_ords_privileges pr ON pr.id = pm.privilege_id
    WHERE  pm.pattern = p_pat AND pr.name != 'expenses.authenticated';
    RETURN l_priv;
  END;
BEGIN
  -- Roles read, not hardcoded: they differ between environments and a wrong
  -- name locks out every protected endpoint.
  FOR x IN (SELECT DISTINCT pr.role_name
            FROM   user_ords_privilege_roles pr
            JOIN   user_ords_privileges p ON p.id = pr.privilege_id
            WHERE  p.name = 'expenses.authenticated'
            ORDER  BY pr.role_name)
  LOOP
    r := r + 1; l_roles(r) := x.role_name;
  END LOOP;

  IF r = 0 THEN
    RAISE_APPLICATION_ERROR(-20002,
      'expenses.authenticated has no roles. Refusing to rebuild it and lock '
      || 'everyone out. Check PROD_2_ords_and_security_setup.sql.');
  END IF;

  FOR np IN (SELECT column_value AS pat FROM TABLE(sys.odcivarchar2list(
               '/expenses/whoami',
               '/expenses/my-projects',
               '/expenses/currencies',                      -- was missing
               '/expenses/exchange-rate',                   -- was missing
               '/expenses/draft',
               '/expenses/mine',
               '/expenses/:id',
               '/expenses/:id/submit',
               '/expenses/:id/attachment',
               '/expenses/:id/accept',
               '/expenses/:id/revise',
               '/expenses/:id/reject',
               '/expenses/push-token',
               '/expenses/:id/items',
               '/expenses/:id/items/:item_id',
               '/expenses/:id/items/:item_id/attachment')))
  LOOP
    IF mapped_elsewhere(np.pat) IS NOT NULL THEN
      DBMS_OUTPUT.PUT_LINE('  SKIP ' || np.pat || ' -- already in '
        || mapped_elsewhere(np.pat));
    ELSE
      p := p + 1; l_patterns(p) := np.pat;
    END IF;
  END LOOP;

  -- What is being added that was not there before?
  FOR np IN (SELECT column_value AS pat FROM TABLE(sys.odcivarchar2list(
               '/expenses/currencies', '/expenses/exchange-rate')))
  LOOP
    DECLARE l_n NUMBER;
    BEGIN
      SELECT COUNT(*) INTO l_n FROM user_ords_privilege_mappings
      WHERE  pattern = np.pat;
      IF l_n = 0 THEN l_added := l_added || np.pat || ' '; END IF;
    END;
  END LOOP;

  ORDS.DELETE_PRIVILEGE(p_name => 'expenses.authenticated');
  ORDS.DEFINE_PRIVILEGE(
    p_privilege_name => 'expenses.authenticated',
    p_roles          => l_roles,
    p_patterns       => l_patterns,
    p_label          => 'Expense App - Authenticated Access',
    p_description    => 'Any signed-in employee or reviewer may call these. '
      || 'Row-level ownership and stage checks happen in the handlers. '
      || 'auth/login is deliberately excluded -- a pattern covering it makes '
      || 'login impossible.');
  COMMIT;

  DBMS_OUTPUT.PUT_LINE('Rebuilt with ' || p || ' pattern(s), ' || r || ' role(s).');
  IF l_added IS NOT NULL THEN
    DBMS_OUTPUT.PUT_LINE('Newly protected (were public): ' || l_added);
  ELSE
    DBMS_OUTPUT.PUT_LINE('Nothing was newly protected -- all were already mapped.');
  END IF;
END;
/


--==============================================================================
-- SECTION 9   --   VERIFY. This replaces the eight individual
--                   verification sections. It must end PASS.
--
-- The per-script checks were removed deliberately: three of them were
-- wrong -- one flagged a comment, one flagged every legitimate reference to
-- EXPENSE_ITEMS.ATTACHMENT_BLOB, and one silently returned nothing at all,
-- which reads exactly like a pass. One check, written four times until it
-- was right, beats eight written once.
--==============================================================================

PROMPT ================ 0. WHERE AM I ================

SELECT SYS_CONTEXT('USERENV','CURRENT_SCHEMA') AS schema_name,
       CASE SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
            WHEN 'HRMS' THEN 'DEV  (karyasiddhitest)'
            WHEN 'REPO' THEN 'PRODUCTION  (karyasiddhi)'
            ELSE 'unrecognised -- find out before changing anything'
       END AS environment,
       (SELECT COUNT(*) FROM user_ords_templates t
        JOIN   user_ords_modules m ON m.id = t.module_id
        WHERE  m.name = 'expenses.employee') AS templates,
       (SELECT COUNT(h.id) FROM user_ords_handlers h
        JOIN   user_ords_templates t ON t.id = h.template_id
        JOIN   user_ords_modules m   ON m.id = t.module_id
        WHERE  m.name = 'expenses.employee') AS handlers
FROM   dual;


PROMPT ================ 1. TEMPLATES WITH NO HANDLER ================
PROMPT (a URL that answers and runs nothing -- MUST BE EMPTY)

SELECT t.uri_template, COUNT(h.id) AS handlers
FROM   user_ords_templates t
JOIN   user_ords_modules m ON m.id = t.module_id
LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
WHERE  m.name = 'expenses.employee'
GROUP  BY t.uri_template
HAVING COUNT(h.id) = 0
ORDER  BY 1;


PROMPT ================ 2. REFERENCES TO THE COLUMNS db/64 DROPPED ================
PROMPT (MUST BE EMPTY)

-- No line splitting. The first version of this check tried to slice each CLOB
-- into lines so a human could read them; it produced no output at all on HRMS,
-- which is worse than a false positive -- a check that silently returns nothing
-- reads exactly like a pass.
--
-- So: match the QUALIFIED name only. Every SELECT in this module aliases
-- EXPENSES as e, so 'e.bill_no' is unambiguous, while a bare 'attachment_blob'
-- is usually EXPENSE_ITEMS doing something legitimate. That distinction is the
-- whole bug in my earlier query.
SELECT t.uri_template, h.method, c.col AS dropped_column_referenced
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
CROSS  JOIN (SELECT column_value AS col FROM TABLE(sys.odcivarchar2list(
         'e.bill_no','e.bill_date','e.type','e.description',
         'e.attachment_blob','e.attachment_filename',
         'e.attachment_mime_type','e.attachment_path'))) c
WHERE  m.name = 'expenses.employee'
AND    DBMS_LOB.INSTR(h.source, c.col) > 0
ORDER  BY t.uri_template, h.method, c.col;

-- The writes have no table alias, so they need naming individually. These are
-- the two handlers 71 fixed: INSERT INTO expenses (... description ...) and
-- UPDATE expenses SET description = ... MUST ALSO BE EMPTY.
SELECT t.uri_template, h.method, 'writes EXPENSES.DESCRIPTION' AS problem
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND  ((t.uri_template = 'draft' AND h.method = 'POST')
   OR (t.uri_template = ':id'   AND h.method = 'PUT'))
AND    DBMS_LOB.INSTR(h.source, 'description') > 0;


PROMPT ================ 3. EVERY ENDPOINT THE APP CALLS ================

SELECT x.pat AS endpoint,
       NVL((SELECT LISTAGG(h.method, ' ') WITHIN GROUP (ORDER BY h.method)
            FROM   user_ords_templates t
            JOIN   user_ords_modules m ON m.id = t.module_id
            JOIN   user_ords_handlers h ON h.template_id = t.id
            WHERE  m.name = 'expenses.employee' AND t.uri_template = x.pat),
           '** MISSING OR EMPTY **') AS methods
FROM   (SELECT column_value AS pat FROM TABLE(sys.odcivarchar2list(
          'auth/login','whoami','my-projects','currencies','exchange-rate',
          'draft','mine','pending',':id',':id/submit',
          ':id/accept',':id/revise',':id/reject','push-token',
          ':id/items',':id/items/:item_id',':id/items/:item_id/attachment',
          'bulk-accept','bulk-revise','bulk-reject',
          ':id/attachment'))) x
ORDER  BY 2, 1;
-- :id/attachment should read 'GET POST' and answer 410 -- retired, not missing.
-- See 77_retire_claim_attachment.sql.


PROMPT ================ 4. PRIVILEGE COVERAGE ================
PROMPT (UNPROTECTED = reachable with no token. auth/login MUST be unprotected.)

SELECT x.pat AS pattern,
       NVL((SELECT MAX(pr.name) FROM user_ords_privilege_mappings pm
            JOIN   user_ords_privileges pr ON pr.id = pm.privilege_id
            WHERE  pm.pattern = '/expenses/' || x.pat),
           '** UNPROTECTED **') AS privilege
FROM   (SELECT column_value AS pat FROM TABLE(sys.odcivarchar2list(
          'whoami','my-projects','currencies','exchange-rate',
          'draft','mine','pending',':id',':id/submit',
          ':id/accept',':id/revise',':id/reject','push-token',
          ':id/items',':id/items/:item_id',':id/items/:item_id/attachment',
          'bulk-accept','bulk-revise','bulk-reject'))) x
ORDER  BY 2, 1;
-- Anything UNPROTECTED -> 69_restore_privileges.sql, which rebuilds from an
-- explicit list rather than reading back the live set. ORDS has no "add one
-- pattern" call; DEFINE_PRIVILEGE replaces the whole set, which is how patterns
-- have gone missing twice.

-- auth/login must be covered by NO privilege. MUST BE EMPTY -- a pattern here
-- makes login impossible by construction: you would need a token to get a token.
SELECT pm.pattern, pr.name AS privilege
FROM   user_ords_privilege_mappings pm
JOIN   user_ords_privileges pr ON pr.id = pm.privilege_id
WHERE  pm.pattern LIKE '/expenses/auth%';

-- No wildcards. MUST BE EMPTY.
SELECT pattern FROM user_ords_privilege_mappings
WHERE  pattern LIKE '/expenses/%*%' OR pattern = '/expenses/*';


PROMPT ================ 5. THE APP'S PL/SQL ================
PROMPT (named explicitly -- HRMS is shared and carries ~190 other INVALID
PROMPT  objects belonging to other systems. Never COMPILE_SCHEMA here.)

SELECT o.object_name, o.object_type, o.status
FROM   user_objects o
WHERE  o.object_name IN ('SEND_EXPENSE_MAIL','PROCESS_EXPENSE_ACTION',
                         'RECALC_CLAIM_TOTALS','SEND_PUSH_NOTIFICATION',
                         'TEST_PUSH_NOTIFICATION','GET_REVIEWER_ROLE',
                         'IS_FINANCE_MANAGER','GET_FINANCE_MANAGER_EMPID',
                         'GET_PROJECT_MANAGER_EMPID','GET_EXCHANGE_RATE',
                         'GET_RATE_EFFECTIVE_DATE','CONVERT_TO_USD',
                         'IS_VALID_SESSION_TOKEN','CAN_VIEW_CLAIM',
                         'CAN_EDIT_CLAIM','PRICE_EXPENSE_ITEM',
                         'IS_ALLOWED_ATTACHMENT','JSON_ESCAPE_STR',
                         'TRG_EXPENSES_AUDIT','TRG_COPY_PM_TO_EXPENSE')
AND    o.status != 'VALID'
ORDER  BY o.object_name;
-- MUST BE EMPTY. Anything here -> ALTER ... COMPILE that one object, then read
-- user_errors. An INVALID object makes every handler that touches it 403.

SELECT name, type, line, position, text
FROM   user_errors
WHERE  name IN ('SEND_EXPENSE_MAIL','PROCESS_EXPENSE_ACTION','RECALC_CLAIM_TOTALS',
                'GET_EXCHANGE_RATE','GET_RATE_EFFECTIVE_DATE',
                'TRG_EXPENSES_AUDIT','TRG_COPY_PM_TO_EXPENSE')
ORDER  BY name, line, position;


PROMPT ================ 6. THE ONE-LINE ANSWER ================

SELECT CASE WHEN empty_templates = 0 AND broken_refs = 0
                 AND missing_endpoints = 0 AND invalid_objects = 0
            THEN 'PASS'
            ELSE 'FAIL -- see the sections above'
       END AS result,
       empty_templates, broken_refs, missing_endpoints, invalid_objects
FROM (
  SELECT
    (SELECT COUNT(*) FROM (
       SELECT t.id FROM user_ords_templates t
       JOIN   user_ords_modules m ON m.id = t.module_id
       LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
       WHERE  m.name = 'expenses.employee'
       GROUP  BY t.id HAVING COUNT(h.id) = 0)) AS empty_templates,

    -- Same qualified-name logic as section 2.
    (SELECT COUNT(*)
     FROM   user_ords_handlers h
     JOIN   user_ords_templates t ON t.id = h.template_id
     JOIN   user_ords_modules m   ON m.id = t.module_id
     CROSS  JOIN (SELECT column_value AS col FROM TABLE(sys.odcivarchar2list(
              'e.bill_no','e.bill_date','e.type','e.description',
              'e.attachment_blob','e.attachment_filename',
              'e.attachment_mime_type','e.attachment_path'))) c
     WHERE  m.name = 'expenses.employee'
     AND    DBMS_LOB.INSTR(h.source, c.col) > 0) AS broken_refs,

    (SELECT COUNT(*) FROM (SELECT column_value AS pat FROM TABLE(sys.odcivarchar2list(
        'auth/login','whoami','my-projects','currencies','exchange-rate',
        'draft','mine','pending',':id',':id/submit',':id/accept',':id/revise',
        ':id/reject','push-token',':id/items',':id/items/:item_id',
        ':id/items/:item_id/attachment','bulk-accept','bulk-revise',
        'bulk-reject'))) x
     WHERE NOT EXISTS (
       SELECT 1 FROM user_ords_templates t
       JOIN   user_ords_modules m ON m.id = t.module_id
       JOIN   user_ords_handlers h ON h.template_id = t.id
       WHERE  m.name = 'expenses.employee' AND t.uri_template = x.pat)) AS missing_endpoints,

    (SELECT COUNT(*) FROM user_objects
     WHERE  object_name IN ('SEND_EXPENSE_MAIL','PROCESS_EXPENSE_ACTION',
                            'RECALC_CLAIM_TOTALS','GET_REVIEWER_ROLE',
                            'IS_FINANCE_MANAGER','GET_FINANCE_MANAGER_EMPID',
                            'GET_PROJECT_MANAGER_EMPID','GET_EXCHANGE_RATE',
                            'GET_RATE_EFFECTIVE_DATE','CONVERT_TO_USD',
                            'IS_VALID_SESSION_TOKEN','CAN_VIEW_CLAIM',
                            'CAN_EDIT_CLAIM','PRICE_EXPENSE_ITEM',
                            'IS_ALLOWED_ATTACHMENT')
     AND    status != 'VALID') AS invalid_objects
);
--
-- PASS here does not mean the app works -- it means ORDS can route and run
-- every endpoint, and nothing references a column that is gone. The remaining
-- reasons a screen can still be wrong are data, not metadata:
--
--   * no PROJECT_MANAGER row for the project     -> cannot approve stage 1
--   * no allocation in PROJECT_ALLOCATION_WB      -> empty project dropdown
--   * CURRENCY_CONVERSION rates end Sep-2025      -> is_fallback always 'Y'
--
-- All three are true on dev today. See 73 section 5.
--------------------------------------------------------------------------------
