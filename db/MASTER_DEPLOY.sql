--==============================================================================
-- MASTER_DEPLOY.sql   --   Expense App, full database deployment
--
-- Generated 2026-08-17 by concatenating the individual scripts in
-- this folder, in dependency order. Run as the APPLICATION SCHEMA.
--
-- READ DEPLOYMENT.md FIRST -- in particular section 3 (values to collect) and
-- section 5 (the DBA tasks this file cannot perform).
--
-- WHAT THIS FILE DOES NOT DO
-- --------------------------
-- Three things must happen OUTSIDE this script, and login fails without them:
--
--   a) OAuth client + APP_SECRETS seeding   -> PROD_2b_oauth_and_network_acl.sql
--                                              sections 1-2, then MERGE the
--                                              client id/secret/token URL into
--                                              APP_SECRETS.
--   b) Network ACL granted to the APEX ENGINE schema (not just the app
--      schema)                              -> PROD_2b section 3, run by a DBA.
--   c) is_finance_manager still returns 'Y' for a single hardcoded EMPID.
--      Set it for this environment.
--
-- ALSO NOT INCLUDED (remediation for EXISTING environments, not fresh installs):
--   47_align_role_names.sql         role rename, dev only
--   50_fix_login_null_bypass.sql    already folded into PROD_4 below
--   51_restore_missing_handlers.sql handlers already defined in PROD_4 below
--   13_cors_fix_for_web_testing.sql only if serving the app from a browser
--
-- BEFORE RUNNING ON A SCHEMA WITH REAL DATA
-- -----------------------------------------
-- Part 5 (45_currency_conversion.sql) backfills every existing expense with an
-- ASSUMED currency and computes amount_usd from it. This is irreversible. Check
-- c_assumed_currency in that section against your data first.
--
-- Each part is idempotent and safe to re-run. Parts 6-8 deliberately replace
-- objects and handlers created earlier in the file; later definitions win.
--
-- AFTER RUNNING: work through DEPLOYMENT.md section 6. Security tests S2 and S6
-- are not optional -- S2 is what catches an authentication bypass.
--==============================================================================


SET DEFINE OFF
SET SERVEROUTPUT ON


--------------------------------------------------------------------------------
-- PART 0   --   THE GUARD. Do not remove.
--
-- This script is for a FIRST install on an empty schema. Part 3 calls
-- ORDS.DEFINE_MODULE, and re-running that on an existing module DELETES EVERY
-- TEMPLATE IN IT. The later parts then rebuild the handlers they know about --
-- which is not all of them, and not the current versions of the ones that have
-- been patched since.
--
-- On dev in August 2026 this emptied ten endpoints. It surfaced as a 403 on
-- Home, a 555 on the conversion rate, and a project dropdown that stayed blank
-- while its SQL returned a row -- three symptoms, none of which named the
-- cause, and three separate rounds of diagnosis. Scripts 71, 72 and 73 exist
-- to undo it.
--
-- So: if the module is already installed, stop. To upgrade an existing schema,
-- run the individual numbered scripts instead -- they replace one handler at a
-- time and are safe to repeat.
--------------------------------------------------------------------------------
DECLARE
  l_handlers NUMBER;
BEGIN
  SELECT COUNT(h.id) INTO l_handlers
  FROM   user_ords_modules m
  LEFT   JOIN user_ords_templates t ON t.module_id = m.id
  LEFT   JOIN user_ords_handlers  h ON h.template_id = t.id
  WHERE  m.name = 'expenses.employee';

  IF l_handlers > 0 THEN
    RAISE_APPLICATION_ERROR(-20099,
      'REFUSING TO RUN. The expenses.employee module already exists on '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ' with ' || l_handlers
      || ' handler(s). This script calls ORDS.DEFINE_MODULE, which would DELETE '
      || 'every template in it -- including the multi-bill endpoints. Nothing '
      || 'has changed. To upgrade, run the individual numbered scripts. To '
      || 'genuinely start over, drop the module by hand first and know why.');
  END IF;

  DBMS_OUTPUT.PUT_LINE('No existing module on '
    || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || '. Proceeding with a first install.');
END;
/


--------------------------------------------------------------------------------
-- PART 1 of 8   --   PROD_1_schema.sql
-- Tables, indexes, APP_SECRETS, mail log, session signing key
--------------------------------------------------------------------------------


-- Run this FIRST, as the application schema owner, on a schema that has
-- SELECT privileges on EMPLOYEEDETAILS, PROJECT_ALLOCATION_WB,
-- PROJECTMASTER, and PROJECT_MANAGER (the last three already exist as part
-- of your existing system — nothing here creates or alters them).
--
-- Safe to re-run: every CREATE is wrapped to skip cleanly if the object
-- already exists.
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- 1. EXPENSES — one row per expense claim.
--------------------------------------------------------------------------------
BEGIN
  EXECUTE IMMEDIATE '
    CREATE TABLE expenses (
        id                     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        emp_id                 NUMBER          NOT NULL,
        bill_no                VARCHAR2(100),
        bill_date              DATE,
        from_date              DATE            NOT NULL,
        to_date                DATE            NOT NULL,
        project_id             NUMBER,
        type                   VARCHAR2(100),
        amount                 NUMBER(12,2)    NOT NULL,
        description            VARCHAR2(4000),
        attachment_path        VARCHAR2(500),
        attachment_filename    VARCHAR2(300),
        attachment_mime_type   VARCHAR2(150),
        attachment_blob        BLOB,
        status                 VARCHAR2(30)    DEFAULT ''DRAFT'' NOT NULL,
        current_stage          VARCHAR2(20),
        manager_empid          NUMBER,
        -- No DEFAULT. The submit handler sets this from
        -- get_finance_manager_empid(); a literal here would be a second,
        -- silently diverging source of truth.
        finance_manager_empid  NUMBER,
        submitted_by           NUMBER,
        submitted_at           TIMESTAMP,
        client_request_id      VARCHAR2(64),
        creation_date          DATE            DEFAULT SYSDATE NOT NULL,
        created_by             VARCHAR2(150),
        last_update_date       DATE            DEFAULT SYSDATE NOT NULL,
        last_updated_by        VARCHAR2(150),
        CONSTRAINT ck_expenses_status CHECK (
            status IN (''DRAFT'', ''SUBMITTED'', ''REVISION_REQUESTED'', ''APPROVED'', ''REJECTED'')
        ),
        CONSTRAINT ck_expenses_stage CHECK (
            current_stage IN (''MANAGER'', ''FINANCE'') OR current_stage IS NULL
        ),
        CONSTRAINT ck_expenses_dates CHECK (to_date >= from_date),
        CONSTRAINT ck_expenses_amount CHECK (amount > 0),
        CONSTRAINT fk_expenses_emp FOREIGN KEY (emp_id) REFERENCES employeedetails(empid),
        CONSTRAINT fk_expenses_manager FOREIGN KEY (manager_empid) REFERENCES employeedetails(empid),
        CONSTRAINT fk_expenses_submitted_by FOREIGN KEY (submitted_by) REFERENCES employeedetails(empid)
    )';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -955 THEN RAISE; END IF; -- table already exists
END;
/

BEGIN
  EXECUTE IMMEDIATE 'CREATE INDEX ix_expenses_emp ON expenses(emp_id)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -955 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'CREATE INDEX ix_expenses_status_stage ON expenses(status, current_stage)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -955 THEN RAISE; END IF;
END;
/

-- client_request_id must be unique (used to detect/dedupe retried draft
-- creations) — a single-column index, NOT combined with emp_id, so it
-- correctly ignores every existing NULL row (Oracle only excludes a row
-- from a unique index when EVERY key column is null).
BEGIN
  EXECUTE IMMEDIATE 'CREATE UNIQUE INDEX expenses_client_req_uq ON expenses (client_request_id)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -955 THEN RAISE; END IF;
END;
/


--------------------------------------------------------------------------------
-- 2. EXPENSE_APPROVALS — append-only audit trail of every accept/revise/
--    reject action, at either review stage.
--------------------------------------------------------------------------------
BEGIN
  EXECUTE IMMEDIATE '
    CREATE TABLE expense_approvals (
        id                NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        expense_id        NUMBER          NOT NULL,
        approver_id       NUMBER          NOT NULL,
        role              VARCHAR2(30)    NOT NULL,
        action            VARCHAR2(20)    NOT NULL,
        -- COMMENTS, not COMMENT. Two reasons, both of which have already
        -- cost time: COMMENT is an Oracle reserved word and cannot be used
        -- as an unquoted column name, and process_expense_action (PROD_3)
        -- inserts into COMMENTS. When the two disagreed, the table created
        -- fine on a schema where it already existed, then
        -- PROCESS_EXPENSE_ACTION compiled INVALID -- and an ORDS handler
        -- calling an INVALID object returns a bare 403 or 555 with no body,
        -- so every accept/revise/reject failed looking like a permissions
        -- problem. Section 2.1 below repairs schemas built before this fix.
        comments          VARCHAR2(4000),
        acted_at          TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
        creation_date     DATE            DEFAULT SYSDATE NOT NULL,
        created_by        VARCHAR2(150),
        last_update_date  DATE            DEFAULT SYSDATE NOT NULL,
        last_updated_by   VARCHAR2(150),
        CONSTRAINT ck_approvals_role CHECK (role IN (''PROJECT_MANAGER'', ''FINANCE_MANAGER'')),
        CONSTRAINT ck_approvals_action CHECK (action IN (''ACCEPTED'', ''REVISED'', ''REJECTED'')),
        CONSTRAINT fk_approvals_expense FOREIGN KEY (expense_id) REFERENCES expenses(id),
        CONSTRAINT fk_approvals_approver FOREIGN KEY (approver_id) REFERENCES employeedetails(empid)
    )';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -955 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'CREATE INDEX ix_approvals_expense ON expense_approvals(expense_id)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -955 THEN RAISE; END IF;
END;
/

--------------------------------------------------------------------------------
-- 2.1 Repair for schemas created before the COMMENT -> COMMENTS fix above.
--
-- On a schema where EXPENSE_APPROVALS already exists, the CREATE TABLE above
-- is skipped (ORA-955) and the old column name survives. process_expense_action
-- would then stay INVALID forever and every approval action would fail with a
-- bare 403/555. Renames it in place; data is preserved. No-op if the column is
-- already correct.
--------------------------------------------------------------------------------
DECLARE
  l_old NUMBER;
  l_new NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_old FROM user_tab_columns
  WHERE  table_name = 'EXPENSE_APPROVALS' AND column_name = 'COMMENT';

  SELECT COUNT(*) INTO l_new FROM user_tab_columns
  WHERE  table_name = 'EXPENSE_APPROVALS' AND column_name = 'COMMENTS';

  IF l_old = 1 AND l_new = 0 THEN
    -- Quoted because COMMENT is reserved and cannot be referenced unquoted.
    EXECUTE IMMEDIATE 'ALTER TABLE expense_approvals RENAME COLUMN "COMMENT" TO comments';
    DBMS_OUTPUT.PUT_LINE('EXPENSE_APPROVALS.COMMENT renamed to COMMENTS.');
  ELSIF l_old = 1 AND l_new = 1 THEN
    DBMS_OUTPUT.PUT_LINE('WARNING: EXPENSE_APPROVALS has BOTH COMMENT and COMMENTS. '
      || 'Check which one holds the approval comments before dropping either.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('EXPENSE_APPROVALS.COMMENTS already correct.');
  END IF;
END;
/

-- process_expense_action may have been left INVALID by the old name. It is
-- created in PROD_3, so this is deliberately tolerant of it not existing yet.
BEGIN
  EXECUTE IMMEDIATE 'ALTER PROCEDURE process_expense_action COMPILE';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

COMMENT ON TABLE expense_approvals IS 'Append-only audit log — one row per accept/revise/reject action, at either review stage. approver_id references EMPLOYEEDETAILS.EMPID. role is PROJECT_MANAGER or FINANCE_MANAGER (renamed from REPORTING_MANAGER — the first stage now routes via the PROJECT_MANAGER table, not the reporting-manager hierarchy).';


--------------------------------------------------------------------------------
-- 2.2 EXPENSE_MAIL_LOG -- one row per notification email attempt.
--
-- Exists because mail failures used to be swallowed by "EXCEPTION WHEN OTHERS
-- THEN NULL" and were therefore undiagnosable: no mail, no error, no clue.
-- A failed notification must never roll back the approval that triggered it,
-- but it must not vanish either.
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
-- 3. EMP_PUSH_TOKENS — one row per device registered for push notifications.
--------------------------------------------------------------------------------
BEGIN
  EXECUTE IMMEDIATE '
    CREATE TABLE emp_push_tokens (
      id          NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      emp_id      NUMBER NOT NULL,
      push_token  VARCHAR2(255) NOT NULL,
      created_at  TIMESTAMP DEFAULT SYSTIMESTAMP,
      updated_at  TIMESTAMP DEFAULT SYSTIMESTAMP,
      CONSTRAINT emp_push_tokens_token_uq UNIQUE (push_token)
    )';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -955 THEN RAISE; END IF;
END;
/


--------------------------------------------------------------------------------
-- 4. APP_SECRETS — server-only secret used to sign session tokens (see
--    PROD_3_business_logic.sql). Never shipped to the app.
--
-- If this already has a key (re-running this on an instance that's already
-- live), it's left untouched — regenerating it would instantly invalidate
-- every currently logged-in user's session.
--
-- DO NOT use DBMS_CRYPTO.RANDOMBYTES here. An app schema commonly has no
-- execute privilege on SYS.DBMS_CRYPTO, and granting it needs a DBA. When
-- this block failed on the dev schema for that reason, SESSION_TOKEN_KEY
-- was never created, GENERATE_SESSION_TOKEN compiled INVALID, and every
-- login returned a bare "403 Forbidden - Access to the resource is
-- prohibited" from ORDS with no hint that a PL/SQL object was the cause.
-- DBMS_RANDOM and SYS_GUID need no grants and are adequate for a signing
-- secret that never leaves the database.
--------------------------------------------------------------------------------
BEGIN
  EXECUTE IMMEDIATE '
    CREATE TABLE app_secrets (
      secret_name  VARCHAR2(50) PRIMARY KEY,
      secret_value VARCHAR2(200)
    )';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -955 THEN RAISE; END IF;
END;
/

DECLARE
  l_count NUMBER;
  l_key   VARCHAR2(200);
BEGIN
  SELECT COUNT(*) INTO l_count FROM app_secrets WHERE secret_name = 'SESSION_TOKEN_KEY';
  IF l_count = 0 THEN
    SELECT DBMS_RANDOM.STRING('X', 48) || RAWTOHEX(SYS_GUID()) || RAWTOHEX(SYS_GUID())
      INTO l_key FROM dual;

    INSERT INTO app_secrets (secret_name, secret_value)
    VALUES ('SESSION_TOKEN_KEY', l_key);
    COMMIT;
  END IF;
END;
/


--------------------------------------------------------------------------------
-- 5. Audit triggers — bump creation/last-updated columns automatically,
--    matching the convention already used on EMPLOYEEDETAILS and
--    PROJECT_ALLOCATION_WB.
--------------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_expenses_audit
BEFORE INSERT OR UPDATE ON expenses
FOR EACH ROW
BEGIN
  IF INSERTING THEN
    :new.creation_date := SYSDATE;
    :new.created_by    := NVL(apex_application.g_user, USER);
  END IF;
  :new.last_update_date := SYSDATE;
  :new.last_updated_by  := NVL(apex_application.g_user, USER);
END;
/

CREATE OR REPLACE TRIGGER trg_approvals_audit
BEFORE INSERT OR UPDATE ON expense_approvals
FOR EACH ROW
BEGIN
  IF INSERTING THEN
    :new.creation_date := SYSDATE;
    :new.created_by    := NVL(apex_application.g_user, USER);
  END IF;
  :new.last_update_date := SYSDATE;
  :new.last_updated_by  := NVL(apex_application.g_user, USER);
END;
/

COMMIT;


--------------------------------------------------------------------------------
-- PART 2 of 8   --   PROD_2_ords_and_security_setup.sql
-- ORDS roles, module, URI templates, privileges
--------------------------------------------------------------------------------



--------------------------------------------------------------------------------
-- 1. REST-enable this schema.
--------------------------------------------------------------------------------
BEGIN
  ORDS.ENABLE_SCHEMA(p_enabled => TRUE, p_schema => NULL);
  COMMIT;
END;
/

--------------------------------------------------------------------------------
-- 2. Roles.
--------------------------------------------------------------------------------
BEGIN
  ORDS.CREATE_ROLE(p_role_name => 'EMPLOYEE_ROLE');
EXCEPTION WHEN OTHERS THEN NULL; 
END;
/
BEGIN
  ORDS.CREATE_ROLE(p_role_name => 'PROJECT_MANAGER_ROLE');
EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
  ORDS.CREATE_ROLE(p_role_name => 'FINANCE_MANAGER_ROLE');
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

--------------------------------------------------------------------------------
-- 3. Module + every URI template used across the whole app. One
-- DEFINE_MODULE call, ever — re-running DEFINE_MODULE on an existing module
-- would wipe out every template already on it, so this whole file is
-- structured to call it only once at the very top.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_MODULE(
    p_module_name => 'expenses.employee',
    p_base_path   => '/expenses/',
    p_comments    => 'All expense app endpoints — employee-facing and reviewer-facing.'
  );

  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => 'auth/login');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => 'whoami');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => 'my-projects');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => 'draft');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => 'mine');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => ':id');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => ':id/submit');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => ':id/attachment');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => 'pending');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => ':id/accept');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => ':id/revise');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => ':id/reject');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => 'bulk-accept');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => 'bulk-revise');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => 'bulk-reject');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => 'push-token');
  COMMIT;
END;
/

--------------------------------------------------------------------------------
-- 4. Privileges — the coarse gate (authenticated at all vs. reviewer-only).
-- Fine-grained "is this the RIGHT reviewer for THIS expense right now"
-- happens inside the handlers (PROD_4_endpoints.sql), via
-- get_reviewer_role()/is_valid_session_token() — ORDS URL-pattern
-- privileges can't express per-row ownership on their own.
--
-- IMPORTANT: 'auth/login' is deliberately NOT in this list. It's the one
-- endpoint the app can reach with no OAuth Bearer token at all — it's the
-- single door in, and it only opens for a real employee username/password
-- (see PROD_4_endpoints.sql). It then hands back both the OAuth access
-- token AND the session token in one response, so the app never needs to
-- hold the OAuth client secret itself (see PROD_3_business_logic.sql,
-- get_oauth_access_token). Every pattern below still requires a valid
-- Bearer token — and the only way to get one is through that real login.
--
-- NEVER USE A WILDCARD LIKE '/expenses/*' HERE. This is not a style
-- preference. ORDS applies EVERY privilege whose pattern matches a URI, and
-- provides no way to exempt a single path from a wildcard — so '/expenses/*'
-- silently captures '/expenses/auth/login' too and makes login impossible by
-- construction: a Bearer token becomes required to log in, and logging in is
-- the only way to obtain one. A dev environment was set up that way and every
-- login returned a full ORDS "Unauthorized — please sign in" HTML page, with
-- nothing anywhere naming the privilege responsible. Each protected endpoint
-- must be listed explicitly, exactly as below. Add a line here whenever a new
-- endpoint is added to PROD_4_endpoints.sql.
--
-- Use EXACT patterns, not trailing wildcards. '/expenses/pending/*' does NOT
-- match '/expenses/pending', which is the URL the app actually calls — dev
-- shipped that typo and left the reviewer queue endpoints unprotected.
--
-- Verify after any change to this file; the second query must return no rows:
--   SELECT pm.pattern, p.name FROM user_ords_privilege_mappings pm
--     JOIN user_ords_privileges p ON p.id = pm.privilege_id ORDER BY 1;
--   SELECT pm.pattern FROM user_ords_privilege_mappings pm
--     WHERE pm.pattern LIKE '/expenses/%*%' OR pm.pattern = '/expenses/*';
--
-- Role names differ between environments (dev uses REPORTING_MANAGER_ROLE
-- where prod uses PROJECT_MANAGER_ROLE). Confirm against
-- user_ords_privilege_roles before copying this file between instances — the
-- OAuth client is granted the local names, and a mismatch locks out every
-- protected endpoint.
--
-- ALSO IMPORTANT: 'pending', 'bulk-accept', 'bulk-revise', and
-- 'bulk-reject' are deliberately NOT in this list either — ORDS does not
-- allow the same URI pattern to be covered by two different privileges
-- (it errors with "ORA-20039: Pattern already mapped"), and those four
-- patterns belong exclusively to the expenses.review privilege below,
-- since only Project Manager/Finance Manager should reach them at all —
-- not every employee.
--------------------------------------------------------------------------------
DECLARE
  l_roles    owa.vc_arr;
  l_patterns owa.vc_arr;
BEGIN
  l_roles(1) := 'EMPLOYEE_ROLE';
  l_roles(2) := 'PROJECT_MANAGER_ROLE';
  l_roles(3) := 'FINANCE_MANAGER_ROLE';

  l_patterns(1)  := '/expenses/whoami';
  l_patterns(2)  := '/expenses/my-projects';
  l_patterns(3)  := '/expenses/draft';
  l_patterns(4)  := '/expenses/mine';
  l_patterns(5)  := '/expenses/:id';
  l_patterns(6)  := '/expenses/:id/submit';
  l_patterns(7)  := '/expenses/:id/attachment';
  l_patterns(8)  := '/expenses/:id/accept';
  l_patterns(9)  := '/expenses/:id/revise';
  l_patterns(10) := '/expenses/:id/reject';
  l_patterns(11) := '/expenses/push-token';

  ORDS.DEFINE_PRIVILEGE(
    p_privilege_name => 'expenses.authenticated',
    p_roles          => l_roles,
    p_patterns       => l_patterns,
    p_label          => 'Expense App - Authenticated Access',
    p_description    => 'Any signed-in Employee, Project Manager, or Finance Manager may call expense endpoints. Row-level ownership/stage checks happen in the handler. auth/login is intentionally excluded — see note above.'
  );
  COMMIT;
END;
/

DECLARE
  l_roles    owa.vc_arr;
  l_patterns owa.vc_arr;
BEGIN
  l_roles(1) := 'PROJECT_MANAGER_ROLE';
  l_roles(2) := 'FINANCE_MANAGER_ROLE';
  l_patterns(1) := '/expenses/pending';
  l_patterns(2) := '/expenses/bulk-accept';
  l_patterns(3) := '/expenses/bulk-revise';
  l_patterns(4) := '/expenses/bulk-reject';

  ORDS.DEFINE_PRIVILEGE(
    p_privilege_name => 'expenses.review',
    p_roles          => l_roles,
    p_patterns       => l_patterns,
    p_label          => 'Expense App - Reviewer Only',
    p_description    => 'Project Manager / Finance Manager review queues and bulk actions. Employees cannot reach these URLs.'
  );
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- PART 3 of 8   --   PROD_3_business_logic.sql
-- Session tokens, OAuth, approval workflow, email, push
--------------------------------------------------------------------------------



--------------------------------------------------------------------------------
-- Who is the Finance Manager, and is this EMPID them?
--
-- Still a single hardcoded id. Replace get_finance_manager_empid's body with a
-- table or role lookup if a second finance manager is ever needed — everything
-- else calls through it, so nothing else changes.
--------------------------------------------------------------------------------
-- >>> THE ONLY PLACE THE FINANCE MANAGER'S EMPID APPEARS <<<
--
-- It used to appear in three: this function, the EXPENSES.FINANCE_MANAGER_EMPID
-- column default, and a literal in the :id/submit handler. Changing only the
-- function let the new person approve while every expense still displayed and
-- routed to the old one -- the function answers "who MAY approve", the other two
-- answered "who is this expense FOR", and they silently disagreed.
CREATE OR REPLACE FUNCTION get_finance_manager_empid RETURN NUMBER IS
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
-- Which employee is the Project Manager for a given project? Looks up
-- PROJECT_MANAGER (P_ID -> PROJECT_MANAGER_EMPID). If more than one row
-- exists for the same project, picks the earliest-assigned one
-- (CREATION_DATE ascending) as a deterministic tie-break — change the
-- ORDER BY below if a different rule is wanted.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_project_manager_empid(p_project_id IN NUMBER) RETURN NUMBER IS
  l_pm_empid NUMBER;
BEGIN
  IF p_project_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT project_manager_empid INTO l_pm_empid
  FROM (
    SELECT project_manager_empid
    FROM   project_manager
    WHERE  p_id = p_project_id
    ORDER BY creation_date ASC, sr_no ASC
  )
  WHERE ROWNUM = 1;

  RETURN l_pm_empid;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RETURN NULL;
END get_project_manager_empid;
/

--------------------------------------------------------------------------------
-- Allowed attachment types: pdf, jpg, jpeg, png, xlsx, xls, csv, rar.
-- Size limit (1MB) is enforced separately, in the upload handler.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION is_allowed_attachment(p_mime IN VARCHAR2) RETURN VARCHAR2 IS
BEGIN
  IF p_mime IS NULL THEN
    RETURN 'Y'; -- attachment is optional at draft stage
  END IF;
  RETURN CASE
    WHEN p_mime IN (
      'application/pdf',
      'image/jpeg', 'image/jpg', 'image/png',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', -- xlsx
      'application/vnd.ms-excel',                                          -- xls
      'text/csv',
      'application/x-rar-compressed', 'application/vnd.rar', 'application/x-rar'
    ) THEN 'Y'
    ELSE 'N'
  END;
END is_allowed_attachment;
/

--------------------------------------------------------------------------------
-- Given an expense + a caller's EMPID, which reviewer role (if any) can
-- they act as on THIS expense right now? NULL if they're not the assigned
-- reviewer at its current stage.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_reviewer_role(
  p_expense_id IN NUMBER,
  p_emp_id     IN NUMBER
) RETURN VARCHAR2 IS
  l_stage         VARCHAR2(20);
  l_manager_empid NUMBER;
BEGIN
  SELECT current_stage, manager_empid
  INTO   l_stage, l_manager_empid
  FROM   expenses
  WHERE  id = p_expense_id;

  IF l_stage = 'MANAGER' AND l_manager_empid = p_emp_id THEN
    RETURN 'PROJECT_MANAGER';
  ELSIF l_stage = 'FINANCE' AND is_finance_manager(p_emp_id) = 'Y' THEN
    RETURN 'FINANCE_MANAGER';
  ELSE
    RETURN NULL;
  END IF;
EXCEPTION
  WHEN NO_DATA_FOUND THEN RETURN NULL;
END get_reviewer_role;
/

--------------------------------------------------------------------------------
-- HMAC-SHA256, built on STANDARD_HASH.
--
-- DELIBERATELY NOT DBMS_CRYPTO. An app schema often has no execute
-- privilege on SYS.DBMS_CRYPTO and granting it requires a DBA. On the dev
-- schema that grant was absent, so both token functions below compiled
-- INVALID — and an ORDS PL/SQL handler that references an INVALID object is
-- refused before it runs, with ORDS returning a bare "403 Forbidden -
-- Access to the resource is prohibited" and no body. That reads as a
-- permissions problem and is not one; it cost most of a day to trace.
-- STANDARD_HASH is a SQL built-in available to every schema.
--
-- STANDARD_HASH only does plain SHA-256, so HMAC is constructed explicitly
-- per RFC 2104:
--
--     HMAC(K, m) = H( (K XOR opad) || H( (K XOR ipad) || m ) )
--
-- This is NOT the naive hash(secret || payload), which SHA-256's
-- length-extension property makes forgeable: an attacker holding one valid
-- token could produce a signature for a longer payload without the key.
--
-- STANDARD_HASH is a SQL function and cannot be called directly in a PL/SQL
-- expression, hence SELECT ... INTO ... FROM dual.
--
-- Verified against the standard test vector:
--   key='key', msg='The quick brown fox jumps over the lazy dog'
--   => f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hmac_sha256_hex(
  p_message IN VARCHAR2,
  p_key     IN VARCHAR2
) RETURN VARCHAR2 IS
  c_block CONSTANT PLS_INTEGER := 64;   -- SHA-256 block size in bytes
  l_key   RAW(256);
  l_klen  PLS_INTEGER;
  l_ipad  RAW(64);
  l_opad  RAW(64);
  l_inner RAW(32);
  l_outer RAW(32);
BEGIN
  l_key  := UTL_I18N.STRING_TO_RAW(p_key, 'AL32UTF8');
  l_klen := UTL_RAW.LENGTH(l_key);

  IF l_klen > c_block THEN
    SELECT STANDARD_HASH(l_key, 'SHA256') INTO l_key FROM dual;
    l_klen := UTL_RAW.LENGTH(l_key);
  END IF;

  IF l_klen < c_block THEN
    l_key := UTL_RAW.CONCAT(l_key, UTL_RAW.COPIES(HEXTORAW('00'), c_block - l_klen));
  END IF;

  l_ipad := UTL_RAW.BIT_XOR(l_key, UTL_RAW.COPIES(HEXTORAW('36'), c_block));
  l_opad := UTL_RAW.BIT_XOR(l_key, UTL_RAW.COPIES(HEXTORAW('5C'), c_block));

  SELECT STANDARD_HASH(
           UTL_RAW.CONCAT(l_ipad, UTL_I18N.STRING_TO_RAW(p_message, 'AL32UTF8')),
           'SHA256')
    INTO l_inner FROM dual;

  SELECT STANDARD_HASH(UTL_RAW.CONCAT(l_opad, l_inner), 'SHA256')
    INTO l_outer FROM dual;

  RETURN RAWTOHEX(l_outer);
END hmac_sha256_hex;
/

-- Fail the deployment rather than install a broken signer.
DECLARE
  c_expected CONSTANT VARCHAR2(64) :=
    'F7BC83F430538424B13298E6AA6FB143EF4D59A14946175997479DBC2D1A3CD8';
  l_actual VARCHAR2(64);
BEGIN
  l_actual := hmac_sha256_hex('The quick brown fox jumps over the lazy dog', 'key');
  IF UPPER(l_actual) != c_expected THEN
    RAISE_APPLICATION_ERROR(-20099,
      'HMAC-SHA256 self-test FAILED. Expected ' || c_expected ||
      ' but got ' || UPPER(l_actual) || '. Do not use these tokens.');
  END IF;
END;
/


--------------------------------------------------------------------------------
-- Signed session tokens (see PROD_1_schema.sql's APP_SECRETS table).
-- Token shape: "<emp_id>.<expiry_epoch_seconds>.<hmac_signature>".
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION generate_session_token(p_emp_id IN NUMBER) RETURN VARCHAR2 IS
  l_secret  VARCHAR2(200);
  l_expiry  NUMBER;
  l_payload VARCHAR2(100);
BEGIN
  SELECT secret_value INTO l_secret FROM app_secrets WHERE secret_name = 'SESSION_TOKEN_KEY';

  l_expiry  := ROUND((SYSDATE - DATE '1970-01-01') * 86400) + (12 * 3600); -- now + 12h
  l_payload := p_emp_id || '.' || l_expiry;

  RETURN l_payload || '.' || hmac_sha256_hex(l_payload, l_secret);
END generate_session_token;
/

CREATE OR REPLACE FUNCTION is_valid_session_token(
  p_emp_id IN NUMBER,
  p_token  IN VARCHAR2
) RETURN VARCHAR2 IS
  l_secret       VARCHAR2(200);
  l_tok_emp      VARCHAR2(50);
  l_tok_exp      VARCHAR2(50);
  l_tok_sig      VARCHAR2(200);
  l_expected_sig VARCHAR2(200);
  l_now          NUMBER;
  l_dot1         NUMBER;
  l_dot2         NUMBER;
BEGIN
  IF p_token IS NULL OR p_emp_id IS NULL THEN
    RETURN 'N';
  END IF;

  l_dot1 := INSTR(p_token, '.');
  l_dot2 := INSTR(p_token, '.', 1, 2);
  IF l_dot1 = 0 OR l_dot2 = 0 THEN
    RETURN 'N';
  END IF;

  l_tok_emp := SUBSTR(p_token, 1, l_dot1 - 1);
  l_tok_exp := SUBSTR(p_token, l_dot1 + 1, l_dot2 - l_dot1 - 1);
  l_tok_sig := SUBSTR(p_token, l_dot2 + 1);

  IF TO_NUMBER(l_tok_emp) != p_emp_id THEN
    RETURN 'N';
  END IF;

  l_now := ROUND((SYSDATE - DATE '1970-01-01') * 86400);
  IF TO_NUMBER(l_tok_exp) < l_now THEN
    RETURN 'N';
  END IF;

  SELECT secret_value INTO l_secret FROM app_secrets WHERE secret_name = 'SESSION_TOKEN_KEY';
  l_expected_sig := hmac_sha256_hex(l_tok_emp || '.' || l_tok_exp, l_secret);

  IF UPPER(l_expected_sig) = UPPER(l_tok_sig) THEN
    RETURN 'Y';
  ELSE
    RETURN 'N';
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    RETURN 'N';
END is_valid_session_token;
/

--------------------------------------------------------------------------------
-- Fetches an app-level OAuth Bearer token on the app's behalf, using the
-- client id/secret/token-URL stored server-side in APP_SECRETS (seeded in
-- PROD_2_ords_and_security_setup.sql, section 5.1) — never sent to any
-- client. Called only from inside POST /expenses/auth/login
-- (PROD_4_endpoints.sql), right after a real employee username/password
-- has been verified. This is what lets the app stop shipping
-- OAUTH_CLIENT_ID/OAUTH_CLIENT_SECRET entirely: instead of the app
-- fetching its own token with an embedded secret, the server fetches it
-- for the app and hands it back alongside the session token, in one
-- login response.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE get_oauth_access_token(
  p_access_token OUT VARCHAR2,
  p_expires_in   OUT NUMBER
) IS
  l_client_id     VARCHAR2(200);
  l_client_secret VARCHAR2(200);
  l_token_url     VARCHAR2(500);
  l_response      CLOB;
BEGIN
  SELECT secret_value INTO l_client_id     FROM app_secrets WHERE secret_name = 'OAUTH_CLIENT_ID';
  SELECT secret_value INTO l_client_secret FROM app_secrets WHERE secret_name = 'OAUTH_CLIENT_SECRET';
  SELECT secret_value INTO l_token_url     FROM app_secrets WHERE secret_name = 'OAUTH_TOKEN_URL';

  apex_web_service.g_request_headers.DELETE;
  apex_web_service.g_request_headers(1).name  := 'Content-Type';
  apex_web_service.g_request_headers(1).value := 'application/x-www-form-urlencoded';

  BEGIN
    l_response := apex_web_service.make_rest_request(
      p_url         => l_token_url,
      p_http_method => 'POST',
      p_username    => l_client_id,
      p_password    => l_client_secret,
      p_body        => 'grant_type=client_credentials'
    );
  EXCEPTION
    -- ORA-29273 ("HTTP request failed") is just a wrapper — the real
    -- cause (missing ACL grant, SSL/certificate problem, DNS failure,
    -- connection refused, etc.) is in UTL_HTTP's detailed error, which
    -- SQLERRM alone does NOT include. Surface that instead of the vague
    -- wrapper message.
    WHEN OTHERS THEN
      RAISE_APPLICATION_ERROR(-20052,
        'OAuth token request to ' || l_token_url || ' failed. ' ||
        UTL_HTTP.GET_DETAILED_SQLERRM || ' (top-level: ' || SQLERRM || ')');
  END;

  p_access_token := JSON_VALUE(l_response, '$.access_token');
  p_expires_in   := NVL(JSON_VALUE(l_response, '$.expires_in' RETURNING NUMBER), 3600);

  IF p_access_token IS NULL THEN
    RAISE_APPLICATION_ERROR(-20050,
      'OAuth token request did not return an access_token. Check OAUTH_CLIENT_ID/OAUTH_CLIENT_SECRET/OAUTH_TOKEN_URL in APP_SECRETS, and confirm the Network ACL grant for your own domain (PROD_2, section 6) is in place. Raw response: ' ||
      DBMS_LOB.SUBSTR(l_response, 500, 1));
  END IF;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RAISE_APPLICATION_ERROR(-20051,
      'OAuth client credentials are not configured yet — see PROD_2_ords_and_security_setup.sql, section 5.1.');
END get_oauth_access_token;
/

--------------------------------------------------------------------------------
-- Push notifications: escaping helper + the sender itself.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION json_escape_str(p_str IN VARCHAR2) RETURN VARCHAR2 IS
BEGIN
  IF p_str IS NULL THEN RETURN ''; END IF;
  RETURN REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(p_str,
    '\', '\\'), '"', '\"'), CHR(10), '\n'), CHR(13), ''), CHR(9), '\t');
END json_escape_str;
/

CREATE OR REPLACE PROCEDURE send_push_notification(
  p_emp_id      IN NUMBER,
  p_title       IN VARCHAR2,
  p_body        IN VARCHAR2,
  p_expense_id  IN NUMBER DEFAULT NULL
) IS
  PRAGMA AUTONOMOUS_TRANSACTION;
  l_payload  CLOB;
  l_response CLOB;
BEGIN
  FOR t IN (SELECT push_token FROM emp_push_tokens WHERE emp_id = p_emp_id) LOOP
    BEGIN
      -- sound/priority/channelId are what make this appear as a BANNER on
      -- the phone rather than a silent line in the notification drawer.
      --   priority  'high'             -> FCM delivers immediately instead of
      --                                   batching it until the device next
      --                                   wakes, which on a dozing phone can
      --                                   be many minutes.
      --   channelId 'expense-updates'  -> must match the channel created in
      --                                   src/pushNotifications.js. Android 8+
      --                                   takes the importance (and therefore
      --                                   whether a banner appears at all)
      --                                   from the CHANNEL, not the message.
      --                                   A channelId with no matching channel
      --                                   on the device falls back to the
      --                                   default one, silently.
      l_payload := '{"to":"' || json_escape_str(t.push_token) ||
                   '","title":"' || json_escape_str(p_title) ||
                   '","body":"' || json_escape_str(p_body) ||
                   '","sound":"default"' ||
                   ',"priority":"high"' ||
                   ',"channelId":"expense-updates"' ||
                   CASE WHEN p_expense_id IS NOT NULL
                        THEN ',"data":{"expenseId":' || p_expense_id || '}'
                        ELSE '' END ||
                   '}';

      apex_web_service.g_request_headers.DELETE;
      apex_web_service.g_request_headers(1).name  := 'Content-Type';
      apex_web_service.g_request_headers(1).value := 'application/json';
      apex_web_service.g_request_headers(2).name  := 'Accept';
      apex_web_service.g_request_headers(2).value := 'application/json';

      l_response := apex_web_service.make_rest_request(
        p_url         => 'https://exp.host/--/api/v2/push/send',
        p_http_method => 'POST',
        p_body        => l_payload
      );
    EXCEPTION
      WHEN OTHERS THEN NULL;
    END;
  END LOOP;
  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
END send_push_notification;
/

--------------------------------------------------------------------------------
-- Core approval-action logic, shared by the single-item and bulk
-- accept/revise/reject endpoints (PROD_4_endpoints.sql).
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Mail configuration: sender address and APEX workspace.
--
-- The workspace is resolved HERE, at deploy time, rather than hardcoded -- it
-- differs per environment and a wrong value fails in a way that looks like a
-- mail server problem. APEX_MAIL.SEND needs it because it requires a security
-- group id, and an ORDS handler has no APEX session.
--
-- EDIT MAIL_FROM if IT specifies a different sender. It must be an address the
-- mail server will accept, or everything is rejected or filed as spam.
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
-- All expense notification email, in one place.
--
-- Callers say WHAT happened and WHO did it; this decides who hears about it.
-- The matrix used to be scattered across six inline APEX_MAIL.SEND calls and
-- had drifted badly -- on revision and rejection it mailed the managers and
-- not the employee, the one person who had to act.
--
--   EVENT             TO                CC
--   SUBMITTED         project manager   employee
--   MANAGER_ACCEPTED  finance manager   project manager + employee
--   FINANCE_ACCEPTED  employee          project manager
--   REVISED           employee          project manager, if Finance asked
--   REJECTED          employee          project manager, if Finance rejected
--
-- Requires APP_SECRETS rows MAIL_FROM and MAIL_WORKSPACE -- see
-- 56_email_notifications.sql section 2, which seeds them. Without
-- MAIL_WORKSPACE, APEX_MAIL.SEND raises immediately: it needs a security
-- group id and there is no APEX session in an ORDS handler.
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
      -- No project manager to send to. Previously this produced silence: TO
      -- was NULL, the mail was logged SKIPPED, and the person who submitted
      -- the claim had no way to know it had gone nowhere. Tell THEM instead.
      -- The underlying problem is data -- the project has no PROJECT_MANAGER
      -- row, or that manager has no EMPLOYEEDETAILS record -- and it also
      -- means nobody can approve the claim at the first stage.
      l_to        := l_emp_email;
      l_cc        := NULL;
      l_greeting  := 'Dear ' || NVL(l_emp_name, 'Colleague');
      l_subject   := 'Expense #' || p_expense_id
                     || ' submitted -- no project manager assigned';
      l_no_manager := TRUE;
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

COMMIT;


--------------------------------------------------------------------------------
-- PART 4 of 8   --   PROD_4_endpoints.sql
-- Every ORDS handler and parameter (login guard included)
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- POST /expenses/auth/login
--
-- THREE THINGS HERE ARE LOAD-BEARING. Each one, when absent, produced a
-- failure whose error message pointed somewhere else entirely.
--
-- 1. THE HANDLER VALIDATES THE PASSWORD ITSELF.
--    An earlier version read :current_user and assumed ORDS had already
--    checked the Authorization: Basic header against APEX workspace
--    accounts. ORDS does not do that. ORDS privileges authenticate via
--    OAuth2 Bearer tokens and roles — they never validate Basic Auth
--    against an APEX account store, whatever a privilege's description
--    might claim. On an endpoint no privilege covers, :current_user is
--    simply always NULL, so the old handler matched no employee and
--    returned 403 "not linked to an active employee record" for every
--    correct login. The header is decoded here and checked with
--    APEX_UTIL.IS_LOGIN_PASSWORD_VALID.
--
-- 2. THE Authorization PARAMETER BELOW IS MANDATORY.
--    Handlers and their parameters are separate ORDS metadata; defining or
--    redefining a handler does not carry parameters with it. Without that
--    DEFINE_PARAMETER call, :p_authorization is NULL on every request, the
--    handler takes its "missing header" branch, and ORDS replaces the JSON
--    body with a generic "401 - The request is unauthenticated."
--
-- 3. THE APEX WORKSPACE NAME DIFFERS PER ENVIRONMENT.
--    Dev's workspace is HRMS, prod's is REPO. Hardcoding either one breaks
--    the other, and the failure surfaces as "Invalid email or password" —
--    indistinguishable from a genuinely wrong password. It is therefore
--    resolved at deploy time from the database rather than written in.
--
-- Also note this endpoint MUST NOT be matched by any ORDS privilege
-- pattern. See the warning at the top of PROD_2_ords_and_security_setup.sql.
--------------------------------------------------------------------------------
DECLARE
  l_workspace VARCHAR2(128);
  l_source    CLOB;
BEGIN
  -- Resolve the workspace holding the employee accounts. INTERNAL is the
  -- APEX administration workspace and is never the right answer.
  SELECT workspace_name INTO l_workspace
  FROM (
    SELECT workspace_name, COUNT(*) AS c
    FROM   apex_workspace_apex_users
    WHERE  UPPER(workspace_name) != 'INTERNAL'
    GROUP  BY workspace_name
    ORDER  BY c DESC
  )
  WHERE ROWNUM = 1;

  DBMS_OUTPUT.PUT_LINE('Login handler will use APEX workspace: ' || l_workspace);

  l_source := REPLACE(q'[
DECLARE
  l_auth_header    VARCHAR2(4000) := :p_authorization;
  l_decoded        VARCHAR2(4000);
  l_colon_pos      PLS_INTEGER;
  l_username       VARCHAR2(300);
  l_password       VARCHAR2(300);
  l_access_token   VARCHAR2(4000);
  l_expires_in     NUMBER;
  l_valid          BOOLEAN := FALSE;
BEGIN
  IF l_auth_header IS NULL OR SUBSTR(l_auth_header, 1, 6) != 'Basic ' THEN
    :status_code := 401;
    APEX_JSON.OPEN_OBJECT;
    APEX_JSON.WRITE('error', 'Missing or invalid Authorization header.');
    APEX_JSON.CLOSE_OBJECT;
    RETURN;
  END IF;

  l_decoded := UTL_RAW.CAST_TO_VARCHAR2(
                 UTL_ENCODE.BASE64_DECODE(
                   UTL_RAW.CAST_TO_RAW(SUBSTR(l_auth_header, 7))));

  l_colon_pos := INSTR(l_decoded, ':');
  IF l_colon_pos = 0 THEN
    :status_code := 401;
    APEX_JSON.OPEN_OBJECT;
    APEX_JSON.WRITE('error', 'Malformed credentials.');
    APEX_JSON.CLOSE_OBJECT;
    RETURN;
  END IF;

  l_username := SUBSTR(l_decoded, 1, l_colon_pos - 1);
  l_password := SUBSTR(l_decoded, l_colon_pos + 1);

  BEGIN
    APEX_UTIL.SET_WORKSPACE('##WORKSPACE##');
    l_valid := APEX_UTIL.IS_LOGIN_PASSWORD_VALID(p_username => l_username,
                                                 p_password => l_password);
  EXCEPTION
    WHEN OTHERS THEN l_valid := FALSE;
  END;

  -- SECURITY: the NVL is load-bearing. APEX_UTIL.IS_LOGIN_PASSWORD_VALID
  -- returns NULL (not FALSE) for a wrong password, and "IF NOT l_valid"
  -- does NOT fire on NULL -- NOT NULL is NULL, and an IF only branches on
  -- TRUE. That let every wrong password fall straight through to the
  -- success path below and receive a valid session. Initialising
  -- l_valid := FALSE gives no protection, because the assignment
  -- overwrites it.
  --
  -- This shipped as a live authentication bypass: any valid username with
  -- any password returned a session. It was hard to spot because the
  -- obvious diagnostic, CASE WHEN l_valid THEN 'Y' ELSE 'N' END, renders
  -- NULL as 'N' -- the endpoint reported the password as invalid and issued
  -- a token in the same response.
  --
  -- Reject anything that is not explicitly TRUE. Do not "simplify" this
  -- back to IF NOT l_valid.
  IF NVL(l_valid, FALSE) = FALSE THEN
    :status_code := 401;
    APEX_JSON.OPEN_OBJECT;
    APEX_JSON.WRITE('error', 'Invalid email or password.');
    APEX_JSON.CLOSE_OBJECT;
    RETURN;
  END IF;

  :status_code := 200;
  FOR r IN (
    SELECT e.empid,
           e.first_name || ' ' || e.last_name AS display_name,
           e.ecode,
           CASE WHEN EXISTS (
             SELECT 1 FROM project_manager pm WHERE pm.project_manager_empid = e.empid
           ) THEN 'Y' ELSE 'N' END AS is_reporting_manager,
           is_finance_manager(e.empid) AS is_finance_manager
    FROM   apex_workspace_apex_users awau,
           employeedetails           e
    WHERE      UPPER(awau.user_name) = UPPER(e.company_email)
           AND UPPER(awau.user_name) = UPPER(l_username)
           -- Case-insensitive on purpose: different environments' HR data
           -- has used different casing for this column ('Active' vs
           -- 'ACTIVE') — a plain exact-case match silently locked out
           -- otherwise-valid active employees the first time this ran
           -- against a schema that used all-caps status values.
           AND UPPER(e.employeestatus) IN ('ACTIVE', 'RESIGNED')
           AND UPPER(awau.user_name) LIKE '%TRINAMIX.COM'
  ) LOOP
    BEGIN
      get_oauth_access_token(l_access_token, l_expires_in);
    EXCEPTION
      WHEN OTHERS THEN
        :status_code := 500;
        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.WRITE('error', 'Logged in, but could not issue an access token: ' || SQLERRM);
        APEX_JSON.CLOSE_OBJECT;
        RETURN;
    END;

    APEX_JSON.OPEN_OBJECT;
    APEX_JSON.WRITE('empid', r.empid);
    APEX_JSON.WRITE('display_name', r.display_name);
    APEX_JSON.WRITE('ecode', r.ecode);
    APEX_JSON.WRITE('is_reporting_manager', r.is_reporting_manager);
    APEX_JSON.WRITE('is_finance_manager', r.is_finance_manager);
    APEX_JSON.WRITE('session_token', generate_session_token(r.empid));
    APEX_JSON.WRITE('access_token', l_access_token);
    APEX_JSON.WRITE('expires_in', l_expires_in);
    APEX_JSON.CLOSE_OBJECT;
    RETURN;
  END LOOP;

  :status_code := 403;
  APEX_JSON.OPEN_OBJECT;
  APEX_JSON.WRITE('error', 'This account is not linked to an active employee record.');
  APEX_JSON.CLOSE_OBJECT;
END;
]', '##WORKSPACE##', l_workspace);

  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'auth/login',
    p_method      => 'POST',
    p_source_type => ords.source_type_plsql,
    p_source      => l_source
  );

  -- MANDATORY. See note 2 in the header comment: without this the
  -- :p_authorization bind is NULL on every request and login always 401s.
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'auth/login', p_method => 'POST',
    p_name => 'Authorization', p_bind_variable_name => 'p_authorization',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'auth/login', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'OUT'
  );
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- GET /expenses/whoami — role flags for the currently logged-in employee.
-- "is_reporting_manager" means "is a Project Manager on some project" now.
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


--------------------------------------------------------------------------------
-- GET /expenses/my-projects — this employee's active project allocations.
--------------------------------------------------------------------------------
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


--------------------------------------------------------------------------------
-- POST /expenses/draft — create (idempotent via client_request_id).
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

        IF JSON_VALUE(l_body, '$.from_date') IS NULL THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Missing or unreadable "from_date" (expected format: MM/DD/YYYY).');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        IF JSON_VALUE(l_body, '$.to_date') IS NULL THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Missing or unreadable "to_date" (expected format: MM/DD/YYYY).');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        IF JSON_VALUE(l_body, '$.amount' RETURNING NUMBER) IS NULL THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Missing or unreadable "amount" (must be a plain number, not a quoted string).');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        INSERT INTO expenses (
          emp_id, bill_no, bill_date, from_date, to_date, project_id, type, amount,
          description, attachment_path, attachment_filename, attachment_mime_type, status,
          client_request_id
        ) VALUES (
          l_emp_id,
          JSON_VALUE(l_body, '$.bill_no'),
          CASE WHEN JSON_VALUE(l_body, '$.bill_date') IS NOT NULL
               THEN TO_DATE(JSON_VALUE(l_body, '$.bill_date'), 'MM/DD/YYYY') END,
          TO_DATE(JSON_VALUE(l_body, '$.from_date'), 'MM/DD/YYYY'),
          TO_DATE(JSON_VALUE(l_body, '$.to_date'), 'MM/DD/YYYY'),
          JSON_VALUE(l_body, '$.project_id' RETURNING NUMBER),
          JSON_VALUE(l_body, '$.type'),
          JSON_VALUE(l_body, '$.amount' RETURNING NUMBER),
          JSON_VALUE(l_body, '$.description'),
          JSON_VALUE(l_body, '$.attachment_path'),
          JSON_VALUE(l_body, '$.attachment_filename'),
          l_mime,
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
-- GET /expenses/mine — list the caller's own expenses.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'mine',
    p_method      => 'GET',
    p_source_type => ords.source_type_collection_feed,
    p_source      => q'[
      SELECT 'expenses/' || e.id "$.id",
             e.id, e.bill_no,
             TO_CHAR(e.bill_date, 'MM/DD/YYYY') bill_date,
             TO_CHAR(e.from_date, 'MM/DD/YYYY') from_date,
             TO_CHAR(e.to_date, 'MM/DD/YYYY') to_date,
             e.project_id,
             e.type, e.amount, e.description, e.attachment_filename,
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
-- GET /expenses/{id} — view one (own expense only), with project/manager
-- names joined in.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => ':id',
    p_method      => 'GET',
    p_source_type => ords.source_type_collection_item,
    p_source      => q'[
      SELECT e.id, e.emp_id, e.bill_no,
             TO_CHAR(e.bill_date, 'MM/DD/YYYY') bill_date,
             TO_CHAR(e.from_date, 'MM/DD/YYYY') from_date,
             TO_CHAR(e.to_date, 'MM/DD/YYYY') to_date,
             e.project_id, pm.project_name,
             e.type, e.amount, e.description,
             e.attachment_path, e.attachment_filename, e.attachment_mime_type,
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
-- PUT /expenses/{id} — edit (only while DRAFT or REVISION_REQUESTED).
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

        UPDATE expenses SET
          bill_no              = NVL(JSON_VALUE(l_body, '$.bill_no'), bill_no),
          bill_date            = CASE WHEN JSON_VALUE(l_body, '$.bill_date') IS NOT NULL
                                       THEN TO_DATE(JSON_VALUE(l_body, '$.bill_date'), 'MM/DD/YYYY') ELSE bill_date END,
          from_date            = NVL(TO_DATE(JSON_VALUE(l_body, '$.from_date'), 'MM/DD/YYYY'), from_date),
          to_date              = NVL(TO_DATE(JSON_VALUE(l_body, '$.to_date'), 'MM/DD/YYYY'), to_date),
          project_id           = NVL(JSON_VALUE(l_body, '$.project_id' RETURNING NUMBER), project_id),
          type                 = NVL(JSON_VALUE(l_body, '$.type'), type),
          amount               = NVL(JSON_VALUE(l_body, '$.amount' RETURNING NUMBER), amount),
          description          = NVL(JSON_VALUE(l_body, '$.description'), description),
          attachment_path      = NVL(JSON_VALUE(l_body, '$.attachment_path'), attachment_path),
          attachment_filename  = NVL(JSON_VALUE(l_body, '$.attachment_filename'), attachment_filename),
          attachment_mime_type = NVL(l_mime, attachment_mime_type)
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
-- DELETE /expenses/{id} — only while DRAFT.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => ':id',
    p_method      => 'DELETE',
    p_source_type => ords.source_type_plsql,
    p_source      => q'[
      DECLARE
        l_emp_id   NUMBER := TO_NUMBER(:emp_id_hdr);
        l_owner_id NUMBER;
        l_status   VARCHAR2(30);
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

        IF l_status != 'DRAFT' THEN
          :status := 409;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Only DRAFT expenses can be deleted (current status: ' || l_status || ')');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        DELETE FROM expenses WHERE id = :id;
        :status := 204;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          :status := 404;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'Expense not found'); APEX_JSON.CLOSE_OBJECT;
      END;
    ]'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id', p_method => 'DELETE',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id', p_method => 'DELETE',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id', p_method => 'DELETE',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT'
  );
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- POST /expenses/{id}/submit — first submit routes to the expense's
-- Project Manager (via get_project_manager_empid); resubmission after a
-- revision goes back to whichever stage asked for it.
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
-- POST /expenses/{id}/attachment — upload (max 1MB, allowed types only).
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => ':id/attachment',
    p_method      => 'POST',
    p_source_type => ords.source_type_plsql,
    p_mimes_allowed => 'multipart/form-data',
    p_source      => q'{
      DECLARE
        l_body_json    CLOB := :body_json;
        l_emp_id       NUMBER := TO_NUMBER(:emp_id_hdr);
        l_owner_id     NUMBER;
        l_status       VARCHAR2(30);
        l_param_name   VARCHAR2(4000);
        l_file_name    VARCHAR2(4000);
        l_content_type VARCHAR2(200);
        l_file_blob    BLOB;
        c_max_bytes    CONSTANT NUMBER := 1048576;
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
          APEX_JSON.WRITE('error', 'Cannot attach a file to an expense in status ' || l_status);
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        IF ORDS.BODY_FILE_COUNT = 0 THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'No file was included in the request'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        ORDS.GET_BODY_FILE(
          P_FILE_INDEX     => 1,
          P_PARAMETER_NAME => l_param_name,
          P_FILE_NAME      => l_file_name,
          P_CONTENT_TYPE   => l_content_type,
          P_FILE_BLOB      => l_file_blob
        );

        IF is_allowed_attachment(l_content_type) = 'N' THEN
          :status := 422;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Attachment type not allowed: ' || l_content_type ||
            '. Allowed types: PDF, JPG, JPEG, PNG, XLSX, XLS, CSV, RAR.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        IF l_file_blob IS NOT NULL AND DBMS_LOB.GETLENGTH(l_file_blob) > c_max_bytes THEN
          :status := 422;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'File is too large (' ||
            ROUND(DBMS_LOB.GETLENGTH(l_file_blob) / 1024 / 1024, 2) ||
            ' MB). Maximum allowed size is 1 MB.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        UPDATE expenses
        SET attachment_filename  = l_file_name,
            attachment_mime_type = l_content_type,
            attachment_blob      = l_file_blob,
            attachment_path      = NULL
        WHERE id = :id;

        :status := 200;
        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.WRITE('id', :id);
        APEX_JSON.WRITE('attachment_filename', l_file_name);
        APEX_JSON.WRITE('attachment_mime_type', l_content_type);
        APEX_JSON.CLOSE_OBJECT;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          :status := 404;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'Expense not found'); APEX_JSON.CLOSE_OBJECT;
        WHEN OTHERS THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', SQLERRM); APEX_JSON.CLOSE_OBJECT;
      END;
    }'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/attachment', p_method => 'POST',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/attachment', p_method => 'POST',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/attachment', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT'
  );
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- GET /expenses/{id}/attachment — download/view (owner, their project
-- manager, or Finance).
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => ':id/attachment',
    p_method      => 'GET',
    p_source_type => ords.source_type_media,
    p_source      => q'{
      SELECT attachment_mime_type, attachment_blob
      FROM   expenses
      WHERE  id = :id
      AND    attachment_blob IS NOT NULL
      AND    is_valid_session_token(TO_NUMBER(:emp_id_hdr), :session_token_hdr) = 'Y'
      AND (
            emp_id                 = TO_NUMBER(:emp_id_hdr)
         OR manager_empid          = TO_NUMBER(:emp_id_hdr)
         OR is_finance_manager(TO_NUMBER(:emp_id_hdr)) = 'Y'
      )
    }'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/attachment', p_method => 'GET',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/attachment', p_method => 'GET',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- POST /expenses/push-token — register/update this device's Expo push token.
--------------------------------------------------------------------------------
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


--------------------------------------------------------------------------------
-- GET /expenses/pending — role-aware reviewer queue.
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
             e.bill_no,
             TO_CHAR(e.bill_date, 'MM/DD/YYYY') bill_date,
             TO_CHAR(e.from_date, 'MM/DD/YYYY') from_date,
             TO_CHAR(e.to_date, 'MM/DD/YYYY') to_date,
             e.project_id, pm.project_name,
             e.type, e.amount, e.description, e.current_stage,
             e.submitted_at, e.attachment_filename
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
-- POST /expenses/{id}/accept | revise | reject
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


--------------------------------------------------------------------------------
-- POST /expenses/bulk-accept | bulk-revise | bulk-reject
--------------------------------------------------------------------------------
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

COMMIT;


--------------------------------------------------------------------------------
-- PART 5 of 8   --   45_currency_conversion.sql
-- CURRENCY / EXCHANGE_RATE / AMOUNT_USD + backfill
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- 45_currency_conversion.sql
--
-- Multi-currency expenses, converted to USD.
--
-- Run as the app schema (HRMS for dev, REPO for prod). Idempotent.
--
-- WHAT THIS ADDS
--   1. EXPENSES.CURRENCY / EXCHANGE_RATE / AMOUNT_USD
--   2. get_exchange_rate(currency, date)  - month-aware rate lookup
--   3. convert_to_usd(amount, currency, date)
--   4. Backfill for existing rows
--
-- DIRECTION OF CONVERSION - the crux of the whole feature
-- -------------------------------------------------------
-- In CURRENCY_CONVERSION, EXCHANGE_RATE is the USD value of ONE unit of
-- FROM_CURR, and TO_CURR is always 'USD':
--
--     INR  0.011280559  ->  1 INR = $0.0113   (INVERSE_RATE  88.648089)
--     KWD  3.27182306   ->  1 KWD = $3.27     (INVERSE_RATE   0.30564)
--     EUR  1.17258313   ->  1 EUR = $1.17     (INVERSE_RATE   0.852818)
--
-- Therefore:
--     amount_usd = amount * EXCHANGE_RATE
--
-- INVERSE_RATE is units-per-dollar. It is for DISPLAY only ("1 USD =
-- 88.65 INR") and must never be used for the calculation. Getting these
-- backwards turns a 1,000 rupee taxi fare into an $88,648 expense, so the
-- self-test at the bottom of this file asserts the direction explicitly.
--
-- WHICH MONTH'S RATE
-- ------------------
-- The rate is chosen by the month of the expense PERIOD START (FROM_DATE),
-- not the bill date. A bill dated May for travel taken in April uses
-- April's rate. If no row covers that month, we fall back to the current
-- open rate (the one with a NULL EFFECTIVE_END_DATE).
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- 1. Columns on EXPENSES.
--
--    AMOUNT stays exactly as the user typed it; CURRENCY now states what
--    unit it is in, instead of that being an unwritten assumption.
--
--    All three are stored rather than derived on read. A rate row can be
--    corrected later, and if conversion were computed at read time that
--    correction would silently restate expenses that were already approved
--    and paid. Freezing the rate used at save time keeps history honest.
--------------------------------------------------------------------------------
DECLARE
  PROCEDURE add_column(p_ddl IN VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_ddl;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE != -1430 THEN RAISE; END IF;  -- ORA-01430: column already exists
  END;
BEGIN
  add_column('ALTER TABLE expenses ADD (currency VARCHAR2(3))');
  add_column('ALTER TABLE expenses ADD (exchange_rate NUMBER)');
  add_column('ALTER TABLE expenses ADD (amount_usd NUMBER)');
END;
/

COMMENT ON COLUMN expenses.currency      IS 'ISO code the AMOUNT is denominated in, chosen by the user (CURRENCY_CONVERSION.FROM_CURR).';
COMMENT ON COLUMN expenses.exchange_rate IS 'USD value of one unit of CURRENCY, frozen at save time. amount_usd = amount * exchange_rate.';
COMMENT ON COLUMN expenses.amount_usd    IS 'AMOUNT converted to USD using EXCHANGE_RATE. Stored, not derived, so later rate corrections never restate approved expenses.';


--------------------------------------------------------------------------------
-- 2. Rate lookup.
--
--    Returns the USD value of one unit of p_currency for the month
--    containing p_date, falling back to the current open rate.
--    Returns NULL only if the currency is unknown entirely.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_exchange_rate(
  p_currency IN VARCHAR2,
  p_date     IN DATE DEFAULT SYSDATE
) RETURN NUMBER IS
  l_rate       NUMBER;
  l_month_from DATE;
  l_month_to   DATE;
BEGIN
  IF p_currency IS NULL THEN
    RETURN NULL;
  END IF;

  l_month_from := TRUNC(NVL(p_date, SYSDATE), 'MM');
  l_month_to   := LAST_DAY(l_month_from);

  -- (a) A row whose effective window overlaps that month. Newest wins if
  --     several overlap.
  BEGIN
    SELECT exchange_rate INTO l_rate
    FROM (
      SELECT exchange_rate
      FROM   currency_conversion
      WHERE  UPPER(from_curr) = UPPER(p_currency)
        AND  UPPER(to_curr)   = 'USD'
        AND  effective_start_date <= l_month_to
        AND  (effective_end_date IS NULL OR effective_end_date >= l_month_from)
      ORDER  BY effective_start_date DESC, conversion_id DESC
    )
    WHERE ROWNUM = 1;

    RETURN l_rate;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN NULL;  -- fall through to (b)
  END;

  -- (b) Fallback: the current open rate. Reached when the expense predates
  --     the earliest rate row on file.
  BEGIN
    SELECT exchange_rate INTO l_rate
    FROM (
      SELECT exchange_rate
      FROM   currency_conversion
      WHERE  UPPER(from_curr) = UPPER(p_currency)
        AND  UPPER(to_curr)   = 'USD'
        AND  effective_end_date IS NULL
      ORDER  BY effective_start_date DESC, conversion_id DESC
    )
    WHERE ROWNUM = 1;

    RETURN l_rate;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;  -- currency not in the table at all
  END;
END get_exchange_rate;
/


--------------------------------------------------------------------------------
-- 3. Convenience wrapper. Rounds to 2dp for money.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION convert_to_usd(
  p_amount   IN NUMBER,
  p_currency IN VARCHAR2,
  p_date     IN DATE DEFAULT SYSDATE
) RETURN NUMBER IS
  l_rate NUMBER;
BEGIN
  IF p_amount IS NULL OR p_currency IS NULL THEN
    RETURN NULL;
  END IF;

  l_rate := get_exchange_rate(p_currency, p_date);
  IF l_rate IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN ROUND(p_amount * l_rate, 2);
END convert_to_usd;
/


--------------------------------------------------------------------------------
-- 4. Backfill existing rows.
--
--    >>> CHECK THIS BEFORE RUNNING <<<
--    Existing expenses have no currency recorded. This assumes they are all
--    INR. Change c_assumed_currency if that is wrong - there is no way to
--    recover the real value afterwards.
--
--    Each row is converted at the rate for its own FROM_DATE month, so
--    backfilled history matches what the app would have stored at the time.
--------------------------------------------------------------------------------
DECLARE
  c_assumed_currency CONSTANT VARCHAR2(3) := 'INR';   -- <<< CHANGE IF WRONG
  l_updated          NUMBER := 0;
BEGIN
  UPDATE expenses
  SET    currency      = c_assumed_currency,
         exchange_rate = get_exchange_rate(c_assumed_currency, from_date),
         amount_usd    = convert_to_usd(amount, c_assumed_currency, from_date)
  WHERE  currency IS NULL;

  l_updated := SQL%ROWCOUNT;
  COMMIT;

  DBMS_OUTPUT.PUT_LINE('Backfilled ' || l_updated || ' expense rows as ' || c_assumed_currency || '.');
END;
/


--------------------------------------------------------------------------------
-- 5. Self-test. Raises rather than leaving a silently wrong converter in
--    place. Skips cleanly if the reference currencies are absent.
--------------------------------------------------------------------------------
DECLARE
  l_rate NUMBER;
  l_usd  NUMBER;
  l_cnt  NUMBER;
BEGIN
  -- Direction check: 1000 INR must be a small number of dollars, not a
  -- large one. This is the assertion that catches EXCHANGE_RATE and
  -- INVERSE_RATE being swapped.
  SELECT COUNT(*) INTO l_cnt
  FROM   currency_conversion
  WHERE  UPPER(from_curr) = 'INR' AND UPPER(to_curr) = 'USD';

  IF l_cnt > 0 THEN
    l_rate := get_exchange_rate('INR', SYSDATE);
    l_usd  := convert_to_usd(1000, 'INR', SYSDATE);

    IF l_rate IS NULL THEN
      RAISE_APPLICATION_ERROR(-20090, 'get_exchange_rate returned NULL for INR.');
    END IF;

    IF l_usd > 500 THEN
      RAISE_APPLICATION_ERROR(-20091,
        'Conversion direction looks INVERTED: 1000 INR converted to ' || l_usd ||
        ' USD. Expected roughly 11. EXCHANGE_RATE is USD-per-unit; ' ||
        'INVERSE_RATE is units-per-USD and must not be used to multiply.');
    END IF;

    DBMS_OUTPUT.PUT_LINE('OK: 1000 INR = ' || l_usd || ' USD (rate ' || l_rate || ')');
  ELSE
    DBMS_OUTPUT.PUT_LINE('SKIP: no INR row to test against.');
  END IF;

  -- Fallback check: a date far earlier than any rate row must still return
  -- a rate rather than NULL.
  IF l_cnt > 0 THEN
    l_rate := get_exchange_rate('INR', DATE '2000-01-15');
    IF l_rate IS NULL THEN
      RAISE_APPLICATION_ERROR(-20092,
        'Fallback to the current open rate is not working - a date with no ' ||
        'matching month returned NULL.');
    END IF;
    DBMS_OUTPUT.PUT_LINE('OK: fallback rate for Jan 2000 = ' || l_rate);
  END IF;

  -- USD must convert 1:1. It exists as a FROM_CURR row.
  SELECT COUNT(*) INTO l_cnt
  FROM   currency_conversion
  WHERE  UPPER(from_curr) = 'USD' AND UPPER(to_curr) = 'USD';

  IF l_cnt > 0 THEN
    l_usd := convert_to_usd(100, 'USD', SYSDATE);
    IF l_usd != 100 THEN
      RAISE_APPLICATION_ERROR(-20093,
        '100 USD converted to ' || l_usd || ' USD. The USD->USD row should have EXCHANGE_RATE = 1.');
    END IF;
    DBMS_OUTPUT.PUT_LINE('OK: 100 USD = 100 USD');
  ELSE
    DBMS_OUTPUT.PUT_LINE('WARNING: no USD->USD row in CURRENCY_CONVERSION. ' ||
      'Users selecting USD will get a NULL rate. Add a row with EXCHANGE_RATE = 1.');
  END IF;
END;
/


--------------------------------------------------------------------------------
-- 6. Verification.
--------------------------------------------------------------------------------
-- What the dropdown will offer.
SELECT DISTINCT from_curr
FROM   currency_conversion
WHERE  UPPER(to_curr) = 'USD'
ORDER  BY from_curr;

-- Every currency at today's rate, with a worked example.
SELECT from_curr,
       get_exchange_rate(from_curr, SYSDATE)        AS rate_usd_per_unit,
       convert_to_usd(1000, from_curr, SYSDATE)     AS usd_for_1000_units
FROM   (SELECT DISTINCT from_curr FROM currency_conversion WHERE UPPER(to_curr) = 'USD')
ORDER  BY from_curr;

-- Backfill result.
SELECT currency, COUNT(*) AS rows_,
       SUM(CASE WHEN amount_usd IS NULL THEN 1 ELSE 0 END) AS missing_usd
FROM   expenses
GROUP  BY currency
ORDER  BY currency;


--------------------------------------------------------------------------------
-- PART 6 of 8   --   46_currency_endpoints.sql
-- /currencies, /exchange-rate, currency-aware save
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- 46_currency_endpoints.sql
--
-- ORDS side of multi-currency expenses. Run AFTER 45_currency_conversion.sql,
-- as the app schema (HRMS for dev, REPO for prod). Idempotent.
--
-- ADDS
--   GET  /expenses/currencies      - dropdown values
--   GET  /expenses/exchange-rate   - rate for a currency on a date
--
-- CHANGES
--   POST /expenses/draft           - accepts currency, stamps rate + USD
--   PUT  /expenses/{id}            - recomputes rate + USD after edits
--   GET  /expenses/mine            - returns currency, exchange_rate, amount_usd
--   GET  /expenses/{id}            - same
--
-- BACKWARD COMPATIBILITY
-- ----------------------
-- A client that sends no "currency" gets c_default_currency (INR), matching
-- how existing rows were backfilled in 45_currency_conversion.sql. This
-- keeps already-installed app builds working while the new build rolls out.
-- Change the default in BOTH files if INR is wrong for your data.
--
-- PRIVILEGES
-- ----------
-- The two new endpoints are added to the expenses.authenticated privilege.
-- This matters: ORDS leaves any path no privilege pattern matches WIDE OPEN,
-- so a new endpoint is public until it is listed. Section 3 rebuilds the
-- privilege from its CURRENT roles and patterns rather than a hardcoded
-- list, because role names differ between environments (dev uses
-- REPORTING_MANAGER_ROLE where prod uses PROJECT_MANAGER_ROLE) and
-- hardcoding them would lock out every protected endpoint.
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- 1. GET /expenses/currencies
--
--    Only currencies that actually resolve to a rate today are returned, so
--    the dropdown cannot offer something that fails on save.
--    inverse_rate is included for display ("1 USD = 88.65 INR"); it must
--    never be used to multiply - see the header of 45_currency_conversion.sql.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_TEMPLATE(
    p_module_name => 'expenses.employee',
    p_pattern     => 'currencies');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'currencies',
    p_method      => 'GET',
    p_source_type => ords.source_type_collection_feed,
    p_source      => q'[
      SELECT c.from_curr                                  AS currency,
             get_exchange_rate(c.from_curr, SYSDATE)      AS exchange_rate,
             ROUND(1 / get_exchange_rate(c.from_curr, SYSDATE), 6) AS inverse_rate
      FROM   (SELECT DISTINCT from_curr
              FROM   currency_conversion
              WHERE  UPPER(to_curr) = 'USD') c
      WHERE  is_valid_session_token(TO_NUMBER(:emp_id_hdr), :session_token_hdr) = 'Y'
      AND    get_exchange_rate(c.from_curr, SYSDATE) IS NOT NULL
      ORDER  BY c.from_curr
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
-- 2. GET /expenses/exchange-rate?currency=INR&on_date=04/15/2026
--
--    on_date should be the expense's FROM_DATE, since the applicable rate is
--    the one for the month the expense PERIOD starts in - not the bill month.
--    Omitting on_date gives today's rate.
--
--    Lets the Add Expense screen show the rate and converted amount before
--    saving, using exactly the same function the save path uses, so the
--    preview can never disagree with what gets stored.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_TEMPLATE(
    p_module_name => 'expenses.employee',
    p_pattern     => 'exchange-rate');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'exchange-rate',
    p_method      => 'GET',
    p_source_type => ords.source_type_plsql,
    p_source      => q'[
      DECLARE
        l_emp_id   NUMBER := TO_NUMBER(:emp_id_hdr);
        l_currency VARCHAR2(3)  := UPPER(:currency);
        l_on_date  DATE;
        l_rate     NUMBER;
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

        IF l_rate IS NULL THEN
          :status := 404;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'No exchange rate on file for ' || l_currency || '.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        :status := 200;
        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.WRITE('currency',      l_currency);
        APEX_JSON.WRITE('on_date',       TO_CHAR(l_on_date, 'MM/DD/YYYY'));
        APEX_JSON.WRITE('rate_month',    TO_CHAR(TRUNC(l_on_date, 'MM'), 'MON-YYYY'));
        APEX_JSON.WRITE('exchange_rate', l_rate);
        APEX_JSON.WRITE('inverse_rate',  ROUND(1 / l_rate, 6));
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


--------------------------------------------------------------------------------
-- 3. Protect the two new endpoints.
--
--    Reads the privilege's CURRENT roles and patterns and adds the new ones,
--    so this works unchanged on dev and prod despite their different role
--    names. Never introduces a wildcard - a pattern like /expenses/* would
--    also match /expenses/auth/login and make logging in impossible.
--------------------------------------------------------------------------------
DECLARE
  l_roles    owa.vc_arr;
  l_patterns owa.vc_arr;
  r          PLS_INTEGER := 0;
  p          PLS_INTEGER := 0;

  FUNCTION has_pattern(p_pattern IN VARCHAR2) RETURN BOOLEAN IS
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n
    FROM   user_ords_privilege_mappings pm
    JOIN   user_ords_privileges pr ON pr.id = pm.privilege_id
    WHERE  pr.name = 'expenses.authenticated'
      AND  pm.pattern = p_pattern;
    RETURN l_n > 0;
  END;
BEGIN
  IF has_pattern('/expenses/currencies') AND has_pattern('/expenses/exchange-rate') THEN
    DBMS_OUTPUT.PUT_LINE('Privilege already covers both new endpoints - nothing to do.');
    RETURN;
  END IF;

  FOR x IN (SELECT role_name
            FROM   user_ords_privilege_roles
            WHERE  privilege_name = 'expenses.authenticated'
            ORDER  BY role_name)
  LOOP
    r := r + 1;
    l_roles(r) := x.role_name;
  END LOOP;

  IF r = 0 THEN
    RAISE_APPLICATION_ERROR(-20080,
      'expenses.authenticated has no roles - aborting rather than recreating '||
      'it with none, which would block every protected endpoint.');
  END IF;

  FOR x IN (SELECT pm.pattern
            FROM   user_ords_privilege_mappings pm
            JOIN   user_ords_privileges pr ON pr.id = pm.privilege_id
            WHERE  pr.name = 'expenses.authenticated'
            ORDER  BY pm.pattern)
  LOOP
    p := p + 1;
    l_patterns(p) := x.pattern;
  END LOOP;

  IF NOT has_pattern('/expenses/currencies') THEN
    p := p + 1; l_patterns(p) := '/expenses/currencies';
  END IF;

  IF NOT has_pattern('/expenses/exchange-rate') THEN
    p := p + 1; l_patterns(p) := '/expenses/exchange-rate';
  END IF;

  ORDS.DELETE_PRIVILEGE(p_name => 'expenses.authenticated');

  ORDS.DEFINE_PRIVILEGE(
    p_privilege_name => 'expenses.authenticated',
    p_roles          => l_roles,
    p_patterns       => l_patterns,
    p_label          => 'Expense App - Authenticated Access',
    p_description    => 'Any signed-in employee or reviewer may call expense endpoints. Row-level checks happen in the handlers. auth/login is intentionally excluded - a wildcard here makes login impossible.');

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Privilege rebuilt with ' || p || ' patterns and ' || r || ' roles.');
END;
/


--------------------------------------------------------------------------------
-- 4. POST /expenses/draft - now stamps currency, rate and USD amount.
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
        c_default_currency CONSTANT VARCHAR2(3) := 'INR';

        l_body        CLOB    := :body_text;
        l_emp_id      NUMBER  := TO_NUMBER(:emp_id_hdr);
        l_mime        VARCHAR2(150) := JSON_VALUE(l_body, '$.attachment_mime_type');
        l_client_req  VARCHAR2(64)  := JSON_VALUE(l_body, '$.client_request_id');
        l_id          NUMBER;
        l_existing_status VARCHAR2(30);
        l_currency    VARCHAR2(3);
        l_from_date   DATE;
        l_amount      NUMBER;
        l_rate        NUMBER;
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
            WHEN NO_DATA_FOUND THEN NULL;
          END;
        END IF;

        IF is_allowed_attachment(l_mime) = 'N' THEN
          :status := 422;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Attachment type not allowed: ' || l_mime);
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        IF JSON_VALUE(l_body, '$.from_date') IS NULL THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Missing or unreadable "from_date" (expected format: MM/DD/YYYY).');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        IF JSON_VALUE(l_body, '$.to_date') IS NULL THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Missing or unreadable "to_date" (expected format: MM/DD/YYYY).');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        IF JSON_VALUE(l_body, '$.amount' RETURNING NUMBER) IS NULL THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Missing or unreadable "amount" (must be a plain number, not a quoted string).');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        l_from_date := TO_DATE(JSON_VALUE(l_body, '$.from_date'), 'MM/DD/YYYY');
        l_amount    := JSON_VALUE(l_body, '$.amount' RETURNING NUMBER);

        -- Older app builds send no currency at all; default rather than
        -- reject, so a phone that has not updated yet keeps working.
        l_currency  := UPPER(NVL(JSON_VALUE(l_body, '$.currency'), c_default_currency));

        -- The rate is chosen by the month FROM_DATE falls in, not the bill
        -- date: a May bill for April travel uses April's rate.
        l_rate := get_exchange_rate(l_currency, l_from_date);

        IF l_rate IS NULL THEN
          :status := 422;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'No exchange rate on file for currency ' || l_currency || '.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        INSERT INTO expenses (
          emp_id, bill_no, bill_date, from_date, to_date, project_id, type, amount,
          description, attachment_path, attachment_filename, attachment_mime_type, status,
          client_request_id, currency, exchange_rate, amount_usd
        ) VALUES (
          l_emp_id,
          JSON_VALUE(l_body, '$.bill_no'),
          CASE WHEN JSON_VALUE(l_body, '$.bill_date') IS NOT NULL
               THEN TO_DATE(JSON_VALUE(l_body, '$.bill_date'), 'MM/DD/YYYY') END,
          l_from_date,
          TO_DATE(JSON_VALUE(l_body, '$.to_date'), 'MM/DD/YYYY'),
          JSON_VALUE(l_body, '$.project_id' RETURNING NUMBER),
          JSON_VALUE(l_body, '$.type'),
          l_amount,
          JSON_VALUE(l_body, '$.description'),
          JSON_VALUE(l_body, '$.attachment_path'),
          JSON_VALUE(l_body, '$.attachment_filename'),
          l_mime,
          'DRAFT',
          l_client_req,
          l_currency,
          l_rate,
          ROUND(l_amount * l_rate, 2)
        )
        RETURNING id INTO l_id;

        :status := 201;
        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.WRITE('id', l_id);
        APEX_JSON.WRITE('status', 'DRAFT');
        APEX_JSON.WRITE('currency', l_currency);
        APEX_JSON.WRITE('exchange_rate', l_rate);
        APEX_JSON.WRITE('amount_usd', ROUND(l_amount * l_rate, 2));
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
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'draft', p_method => 'POST',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'draft', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT');

  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 5. PUT /expenses/{id} - recompute conversion after any edit.
--
--    The recompute is a second UPDATE reading the row's own stored values,
--    rather than the incoming JSON. That way it stays correct no matter
--    which subset of fields the client sent: change only the amount and the
--    USD figure still follows; change only from_date and the rate moves to
--    the new month.
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
        l_body     CLOB   := :body_text;
        l_emp_id   NUMBER := TO_NUMBER(:emp_id_hdr);
        l_owner_id NUMBER;
        l_status   VARCHAR2(30);
        l_mime     VARCHAR2(150) := JSON_VALUE(l_body, '$.attachment_mime_type');
        l_currency VARCHAR2(3)   := UPPER(JSON_VALUE(l_body, '$.currency'));
        l_rate     NUMBER;
        l_usd      NUMBER;
        l_curr_now VARCHAR2(3);
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

        -- Reject an unknown currency before writing anything.
        IF l_currency IS NOT NULL AND get_exchange_rate(l_currency, SYSDATE) IS NULL THEN
          :status := 422;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'No exchange rate on file for currency ' || l_currency || '.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        UPDATE expenses SET
          bill_no              = NVL(JSON_VALUE(l_body, '$.bill_no'), bill_no),
          bill_date            = CASE WHEN JSON_VALUE(l_body, '$.bill_date') IS NOT NULL
                                       THEN TO_DATE(JSON_VALUE(l_body, '$.bill_date'), 'MM/DD/YYYY') ELSE bill_date END,
          from_date            = NVL(TO_DATE(JSON_VALUE(l_body, '$.from_date'), 'MM/DD/YYYY'), from_date),
          to_date              = NVL(TO_DATE(JSON_VALUE(l_body, '$.to_date'), 'MM/DD/YYYY'), to_date),
          project_id           = NVL(JSON_VALUE(l_body, '$.project_id' RETURNING NUMBER), project_id),
          type                 = NVL(JSON_VALUE(l_body, '$.type'), type),
          amount               = NVL(JSON_VALUE(l_body, '$.amount' RETURNING NUMBER), amount),
          description          = NVL(JSON_VALUE(l_body, '$.description'), description),
          attachment_path      = NVL(JSON_VALUE(l_body, '$.attachment_path'), attachment_path),
          attachment_filename  = NVL(JSON_VALUE(l_body, '$.attachment_filename'), attachment_filename),
          attachment_mime_type = NVL(l_mime, attachment_mime_type),
          currency             = NVL(l_currency, currency)
        WHERE id = :id;

        -- Recompute from what is now stored, not from the request body.
        UPDATE expenses
        SET    exchange_rate = get_exchange_rate(currency, from_date),
               amount_usd    = ROUND(amount * get_exchange_rate(currency, from_date), 2)
        WHERE  id = :id
        RETURNING currency, exchange_rate, amount_usd INTO l_curr_now, l_rate, l_usd;

        :status := 200;
        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.WRITE('id', :id);
        APEX_JSON.WRITE('status', 'UPDATED');
        APEX_JSON.WRITE('currency', l_curr_now);
        APEX_JSON.WRITE('exchange_rate', l_rate);
        APEX_JSON.WRITE('amount_usd', l_usd);
        APEX_JSON.CLOSE_OBJECT;
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
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id', p_method => 'PUT',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id', p_method => 'PUT',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT');

  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 6. GET /expenses/mine - include the currency columns.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'mine',
    p_method      => 'GET',
    p_source_type => ords.source_type_collection_feed,
    p_source      => q'[
      SELECT 'expenses/' || e.id "$.id",
             e.id, e.bill_no,
             TO_CHAR(e.bill_date, 'MM/DD/YYYY') bill_date,
             TO_CHAR(e.from_date, 'MM/DD/YYYY') from_date,
             TO_CHAR(e.to_date, 'MM/DD/YYYY') to_date,
             e.project_id,
             e.type, e.amount, e.description, e.attachment_filename,
             e.status, e.current_stage, e.submitted_at,
             e.currency, e.exchange_rate, e.amount_usd
      FROM   expenses e
      WHERE  e.emp_id = TO_NUMBER(:emp_id_hdr)
      AND    is_valid_session_token(TO_NUMBER(:emp_id_hdr), :session_token_hdr) = 'Y'
      ORDER BY e.creation_date DESC
    ]'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'mine', p_method => 'GET',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'mine', p_method => 'GET',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 6b. GET /expenses/{id} - include the currency columns.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => ':id',
    p_method      => 'GET',
    p_source_type => ords.source_type_collection_item,
    p_source      => q'[
      SELECT e.id, e.emp_id, e.bill_no,
             TO_CHAR(e.bill_date, 'MM/DD/YYYY') bill_date,
             TO_CHAR(e.from_date, 'MM/DD/YYYY') from_date,
             TO_CHAR(e.to_date, 'MM/DD/YYYY') to_date,
             e.project_id, pm.project_name,
             e.type, e.amount, e.description,
             e.currency, e.exchange_rate, e.amount_usd,
             e.attachment_path, e.attachment_filename, e.attachment_mime_type,
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
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id', p_method => 'GET',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 6c. GET /expenses/pending - reviewers need the currency too.
--
--     Without this a reviewer sees a bare number with no unit: "1000" could
--     be 1,000 rupees (about $11) or 1,000 dinar (about $3,272). The amount
--     alone is not enough information to approve on.
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
             e.bill_no,
             TO_CHAR(e.bill_date, 'MM/DD/YYYY') bill_date,
             TO_CHAR(e.from_date, 'MM/DD/YYYY') from_date,
             TO_CHAR(e.to_date, 'MM/DD/YYYY') to_date,
             e.project_id, pm.project_name,
             e.type, e.amount, e.description, e.current_stage,
             e.currency, e.exchange_rate, e.amount_usd,
             e.submitted_at, e.attachment_filename
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
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'pending', p_method => 'GET',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 7. Verification.
--------------------------------------------------------------------------------
-- New templates present?
SELECT t.uri_template, h.method
FROM   user_ords_templates t
JOIN   user_ords_modules m ON m.id = t.module_id
LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
WHERE  m.name = 'expenses.employee'
  AND  t.uri_template IN ('currencies', 'exchange-rate')
ORDER  BY t.uri_template;

-- Both new endpoints protected, and still no wildcard?
SELECT pm.pattern, p.name
FROM   user_ords_privilege_mappings pm
JOIN   user_ords_privileges p ON p.id = pm.privilege_id
ORDER  BY p.name, pm.pattern;

-- Must return zero rows.
SELECT pm.pattern FROM user_ords_privilege_mappings pm
WHERE  pm.pattern LIKE '/expenses/%*%' OR pm.pattern = '/expenses/*';


--------------------------------------------------------------------------------
-- 8. Then test with a real Bearer token and session token:
--
--   GET /expenses/currencies
--       -> list of currencies, each with exchange_rate and inverse_rate
--
--   GET /expenses/exchange-rate?currency=INR&on_date=04/15/2026&amount=1000
--       -> exchange_rate ~0.0113, amount_usd ~11.28, rate_month APR-2026
--
--   POST /expenses/draft  with  "currency": "EUR", "amount": 100
--       -> amount_usd ~117.26
--
--   PUT /expenses/{id}    with  "amount": 200   (no currency sent)
--       -> amount_usd doubles, currency unchanged
--
-- The check that matters: 1000 INR must come back as roughly 11 USD, not
-- 88,648. If you see the latter, the rate direction has been inverted
-- somewhere - see the header of 45_currency_conversion.sql.
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- PART 7 of 8   --   48_rate_month_truthfulness.sql
-- get_rate_effective_date, honest fallback reporting
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- 48_rate_month_truthfulness.sql
--
-- Run as HRMS, then REPO. Requires 45 and 46 already applied.
--
-- THE BUG
-- -------
-- GET /expenses/exchange-rate reported rate_month as the month of the date
-- you asked about, regardless of which rate row was actually used. Ask for
-- June 2026, get no June rate, silently fall back to the October 2025 open
-- rate - and the screen still said "JUN-2026 rate".
--
-- The number was right. The label was a lie. An approver reading
-- "JUN-2026 rate" would reasonably assume a June rate existed.
--
-- THE FIX
-- -------
-- get_rate_effective_date() mirrors get_exchange_rate()'s selection logic
-- exactly and returns the EFFECTIVE_START_DATE of the row that was actually
-- chosen. The endpoint now reports that month, plus a flag saying whether
-- the fallback was used, so the UI can say so out loud.
--
-- The two functions must stay in step. If the lookup rule in
-- get_exchange_rate ever changes, change it here too - section 4 asserts
-- they agree, and fails the deployment if they drift.
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- 1. Which rate row does get_exchange_rate actually pick?
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_rate_effective_date(
  p_currency IN VARCHAR2,
  p_date     IN DATE DEFAULT SYSDATE
) RETURN DATE IS
  l_eff        DATE;
  l_month_from DATE;
  l_month_to   DATE;
BEGIN
  IF p_currency IS NULL THEN
    RETURN NULL;
  END IF;

  l_month_from := TRUNC(NVL(p_date, SYSDATE), 'MM');
  l_month_to   := LAST_DAY(l_month_from);

  -- (a) window overlapping the requested month - same ORDER BY as
  --     get_exchange_rate, so the same row wins.
  BEGIN
    SELECT effective_start_date INTO l_eff
    FROM (
      SELECT effective_start_date
      FROM   currency_conversion
      WHERE  UPPER(from_curr) = UPPER(p_currency)
        AND  UPPER(to_curr)   = 'USD'
        AND  effective_start_date <= l_month_to
        AND  (effective_end_date IS NULL OR effective_end_date >= l_month_from)
      ORDER  BY effective_start_date DESC, conversion_id DESC
    )
    WHERE ROWNUM = 1;

    RETURN l_eff;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN NULL;
  END;

  -- (b) fallback: the current open rate.
  BEGIN
    SELECT effective_start_date INTO l_eff
    FROM (
      SELECT effective_start_date
      FROM   currency_conversion
      WHERE  UPPER(from_curr) = UPPER(p_currency)
        AND  UPPER(to_curr)   = 'USD'
        AND  effective_end_date IS NULL
      ORDER  BY effective_start_date DESC, conversion_id DESC
    )
    WHERE ROWNUM = 1;

    RETURN l_eff;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;
  END;
END get_rate_effective_date;
/


--------------------------------------------------------------------------------
-- 2. GET /expenses/exchange-rate - now tells the truth about the rate month.
--
--    New/changed fields:
--      rate_month     month of the rate ACTUALLY used (was: month requested)
--      requested_month  month asked about, so the UI can compare
--      is_fallback    'Y' when no rate covers the requested month
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


--------------------------------------------------------------------------------
-- 3. Verify against real data.
--
--    For every currency: today should NOT be a fallback (there is an open
--    rate), and a date far in the future SHOULD be, since no row covers it.
--------------------------------------------------------------------------------
SELECT c.from_curr,
       TO_CHAR(TRUNC(SYSDATE,'MM'), 'MON-YYYY')                        AS asked_now,
       TO_CHAR(get_rate_effective_date(c.from_curr, SYSDATE),'MON-YYYY') AS used_now,
       TO_CHAR(get_rate_effective_date(c.from_curr, DATE '2026-06-15'),'MON-YYYY') AS used_for_jun_2026,
       CASE WHEN TRUNC(get_rate_effective_date(c.from_curr, DATE '2026-06-15'),'MM')
                 = DATE '2026-06-01'
            THEN 'N' ELSE 'Y' END                                      AS jun_is_fallback
FROM   (SELECT DISTINCT from_curr
        FROM   currency_conversion
        WHERE  UPPER(to_curr) = 'USD') c
ORDER  BY c.from_curr;


--------------------------------------------------------------------------------
-- 4. Self-test: the two functions must select the SAME row.
--
--    Compares the rate returned by get_exchange_rate against the rate on the
--    row get_rate_effective_date points at, across every currency and a
--    spread of dates. Raises if they ever disagree - that would mean the
--    displayed month belongs to a different row than the number.
--------------------------------------------------------------------------------
DECLARE
  l_rate      NUMBER;
  l_eff       DATE;
  l_rate_at   NUMBER;
  l_checked   PLS_INTEGER := 0;
BEGIN
  FOR c IN (SELECT DISTINCT from_curr
            FROM   currency_conversion
            WHERE  UPPER(to_curr) = 'USD')
  LOOP
    FOR d IN (SELECT DATE '2024-03-15' AS dt FROM dual
              UNION ALL SELECT DATE '2025-10-15' FROM dual
              UNION ALL SELECT SYSDATE FROM dual
              UNION ALL SELECT DATE '2026-06-15' FROM dual
              UNION ALL SELECT DATE '2030-01-15' FROM dual)
    LOOP
      l_rate := get_exchange_rate(c.from_curr, d.dt);
      l_eff  := get_rate_effective_date(c.from_curr, d.dt);

      IF l_rate IS NULL AND l_eff IS NULL THEN
        CONTINUE;  -- currency genuinely absent; both agree
      END IF;

      IF l_rate IS NULL OR l_eff IS NULL THEN
        RAISE_APPLICATION_ERROR(-20095,
          'Disagreement for ' || c.from_curr || ' on ' || TO_CHAR(d.dt,'MM/DD/YYYY') ||
          ': one function returned NULL and the other did not.');
      END IF;

      SELECT MAX(exchange_rate) INTO l_rate_at
      FROM   currency_conversion
      WHERE  UPPER(from_curr) = UPPER(c.from_curr)
        AND  UPPER(to_curr)   = 'USD'
        AND  effective_start_date = l_eff;

      IF l_rate_at IS NULL OR l_rate_at != l_rate THEN
        RAISE_APPLICATION_ERROR(-20096,
          'Row mismatch for ' || c.from_curr || ' on ' || TO_CHAR(d.dt,'MM/DD/YYYY') ||
          ': get_exchange_rate gave ' || l_rate ||
          ' but the row dated ' || TO_CHAR(l_eff,'MM/DD/YYYY') || ' holds ' || l_rate_at ||
          '. The two lookups have drifted apart.');
      END IF;

      l_checked := l_checked + 1;
    END LOOP;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('OK: ' || l_checked || ' currency/date combinations agree.');
END;
/


--------------------------------------------------------------------------------
-- 5. Then test from Postman:
--
--   GET /expenses/exchange-rate?currency=INR&on_date=06/15/2026&amount=1000
--     -> requested_month JUN-2026
--        rate_month      OCT-2025      (the rate actually applied)
--        is_fallback     Y
--
--   GET /expenses/exchange-rate?currency=INR&on_date=10/15/2025&amount=1000
--     -> requested_month OCT-2025
--        rate_month      OCT-2025
--        is_fallback     N
--
-- The point: is_fallback = Y means "no rate on file for that month, this is
-- the current rate instead." The user should be able to see that.
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- PART 8 of 8   --   49_usd_identity.sql
-- USD handled as 1 in code, not as a data row
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- 49_usd_identity.sql
--
-- Run as HRMS and REPO. Requires 45, 46 and 48 already applied.
--
-- PURPOSE
-- -------
-- Treat USD -> USD as an identity in code rather than as a row in
-- CURRENCY_CONVERSION.
--
-- WHY NOT JUST INSERT A ROW
-- -------------------------
-- A USD->USD row is not an exchange rate; it is arithmetic. Storing it
-- invites someone to maintain it like the others - a monthly refresh job
-- writing 0.9998, an end date closing it off, a typo - and every dollar
-- expense in the system silently changes value. Encoding 1 in code makes
-- that impossible.
--
-- WHAT CHANGES
--   get_exchange_rate       returns 1 for USD, before touching the table
--   get_rate_effective_date returns the requested month for USD, so USD is
--                           never reported as a fallback
--   GET /expenses/currencies includes USD even though it has no row
--
-- If a USD row already exists it is now ignored, not deleted - deleting
-- data is not this script's business. Section 5 tells you if one is there.
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- 1. Rate lookup: USD is 1, always.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_exchange_rate(
  p_currency IN VARCHAR2,
  p_date     IN DATE DEFAULT SYSDATE
) RETURN NUMBER IS
  l_rate       NUMBER;
  l_month_from DATE;
  l_month_to   DATE;
BEGIN
  IF p_currency IS NULL THEN
    RETURN NULL;
  END IF;

  -- USD -> USD is arithmetic, not a rate. Short-circuit before the table so
  -- no data can ever make a dollar worth something other than a dollar.
  IF UPPER(p_currency) = 'USD' THEN
    RETURN 1;
  END IF;

  l_month_from := TRUNC(NVL(p_date, SYSDATE), 'MM');
  l_month_to   := LAST_DAY(l_month_from);

  -- (a) a row whose effective window overlaps that month
  BEGIN
    SELECT exchange_rate INTO l_rate
    FROM (
      SELECT exchange_rate
      FROM   currency_conversion
      WHERE  UPPER(from_curr) = UPPER(p_currency)
        AND  UPPER(to_curr)   = 'USD'
        AND  effective_start_date <= l_month_to
        AND  (effective_end_date IS NULL OR effective_end_date >= l_month_from)
      ORDER  BY effective_start_date DESC, conversion_id DESC
    )
    WHERE ROWNUM = 1;

    RETURN l_rate;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN NULL;
  END;

  -- (b) fallback: the current open rate
  BEGIN
    SELECT exchange_rate INTO l_rate
    FROM (
      SELECT exchange_rate
      FROM   currency_conversion
      WHERE  UPPER(from_curr) = UPPER(p_currency)
        AND  UPPER(to_curr)   = 'USD'
        AND  effective_end_date IS NULL
      ORDER  BY effective_start_date DESC, conversion_id DESC
    )
    WHERE ROWNUM = 1;

    RETURN l_rate;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;
  END;
END get_exchange_rate;
/


--------------------------------------------------------------------------------
-- 2. Effective date: USD belongs to whatever month you asked about, so it is
--    never reported as a fallback. Anything else would have the UI warning
--    "no rate loaded for JUN-2026" about dollars, which is nonsense.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_rate_effective_date(
  p_currency IN VARCHAR2,
  p_date     IN DATE DEFAULT SYSDATE
) RETURN DATE IS
  l_eff        DATE;
  l_month_from DATE;
  l_month_to   DATE;
BEGIN
  IF p_currency IS NULL THEN
    RETURN NULL;
  END IF;

  l_month_from := TRUNC(NVL(p_date, SYSDATE), 'MM');
  l_month_to   := LAST_DAY(l_month_from);

  IF UPPER(p_currency) = 'USD' THEN
    RETURN l_month_from;
  END IF;

  BEGIN
    SELECT effective_start_date INTO l_eff
    FROM (
      SELECT effective_start_date
      FROM   currency_conversion
      WHERE  UPPER(from_curr) = UPPER(p_currency)
        AND  UPPER(to_curr)   = 'USD'
        AND  effective_start_date <= l_month_to
        AND  (effective_end_date IS NULL OR effective_end_date >= l_month_from)
      ORDER  BY effective_start_date DESC, conversion_id DESC
    )
    WHERE ROWNUM = 1;

    RETURN l_eff;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN NULL;
  END;

  BEGIN
    SELECT effective_start_date INTO l_eff
    FROM (
      SELECT effective_start_date
      FROM   currency_conversion
      WHERE  UPPER(from_curr) = UPPER(p_currency)
        AND  UPPER(to_curr)   = 'USD'
        AND  effective_end_date IS NULL
      ORDER  BY effective_start_date DESC, conversion_id DESC
    )
    WHERE ROWNUM = 1;

    RETURN l_eff;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;
  END;
END get_rate_effective_date;
/


--------------------------------------------------------------------------------
-- 3. GET /expenses/currencies - USD has no row, so add it explicitly.
--
--    Without this the dropdown cannot offer USD at all, and a user with a
--    dollar receipt has nothing correct to pick.
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
-- 4. Self-test. Raises rather than leaving USD mis-converting.
--------------------------------------------------------------------------------
DECLARE
  l_rate NUMBER;
  l_usd  NUMBER;
  l_eff  DATE;
BEGIN
  -- USD is 1 on every date, including months with no rate data at all.
  FOR d IN (SELECT DATE '2019-01-15' AS dt FROM dual
            UNION ALL SELECT SYSDATE FROM dual
            UNION ALL SELECT DATE '2026-06-15' FROM dual
            UNION ALL SELECT DATE '2031-12-15' FROM dual)
  LOOP
    l_rate := get_exchange_rate('USD', d.dt);
    IF l_rate IS NULL OR l_rate != 1 THEN
      RAISE_APPLICATION_ERROR(-20097,
        'USD rate on ' || TO_CHAR(d.dt,'MM/DD/YYYY') || ' is ' || NVL(TO_CHAR(l_rate),'NULL') ||
        ', expected 1.');
    END IF;

    l_usd := convert_to_usd(100, 'USD', d.dt);
    IF l_usd != 100 THEN
      RAISE_APPLICATION_ERROR(-20098,
        '100 USD converted to ' || l_usd || ' on ' || TO_CHAR(d.dt,'MM/DD/YYYY') || '.');
    END IF;

    -- USD must never look like a fallback.
    l_eff := get_rate_effective_date('USD', d.dt);
    IF TRUNC(l_eff,'MM') != TRUNC(d.dt,'MM') THEN
      RAISE_APPLICATION_ERROR(-20099,
        'USD reported as fallback on ' || TO_CHAR(d.dt,'MM/DD/YYYY') ||
        ' (effective ' || TO_CHAR(l_eff,'MM/DD/YYYY') || ').');
    END IF;
  END LOOP;

  -- Lowercase must behave identically - the app sends whatever the picker holds.
  IF get_exchange_rate('usd', SYSDATE) != 1 THEN
    RAISE_APPLICATION_ERROR(-20096, 'Lowercase "usd" did not resolve to 1.');
  END IF;

  -- A real currency must still work, i.e. the short-circuit did not eat everything.
  IF get_exchange_rate('INR', SYSDATE) IS NULL THEN
    RAISE_APPLICATION_ERROR(-20095, 'INR now returns NULL - the table lookup is broken.');
  END IF;

  DBMS_OUTPUT.PUT_LINE('OK: USD is 1 on all tested dates, never a fallback, INR unaffected.');
END;
/


--------------------------------------------------------------------------------
-- 5. Verify.
--------------------------------------------------------------------------------
-- Is there a leftover USD row? Harmless now - it is ignored - but worth
-- knowing about so nobody maintains a value that has no effect.
SELECT conversion_id, from_curr, to_curr, exchange_rate,
       effective_start_date, effective_end_date
FROM   currency_conversion
WHERE  UPPER(from_curr) = 'USD';

-- Every currency the dropdown will now offer, USD included.
SELECT c.currency,
       get_exchange_rate(c.currency, SYSDATE)    AS rate_usd_per_unit,
       convert_to_usd(1000, c.currency, SYSDATE) AS usd_for_1000
FROM   (SELECT DISTINCT from_curr AS currency
        FROM   currency_conversion
        WHERE  UPPER(to_curr) = 'USD' AND UPPER(from_curr) != 'USD'
        UNION
        SELECT 'USD' FROM dual) c
ORDER  BY c.currency;


--------------------------------------------------------------------------------
-- 6. Then from Postman:
--
--   GET /expenses/currencies
--     -> list includes USD with exchange_rate 1, inverse_rate 1
--
--   GET /expenses/exchange-rate?currency=USD&on_date=06/15/2026&amount=100
--     -> exchange_rate 1, amount_usd 100,
--        rate_month JUN-2026, is_fallback N
--
-- The last one is the point: dollars in a month with no rate data are still
-- dollars, and the UI should not warn about them.
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- END OF DEPLOYMENT -- now verify. Full checks in DEPLOYMENT.md section 6.
--------------------------------------------------------------------------------

-- 1. Nothing INVALID. An ORDS handler that references an INVALID object fails
--    with a bare 403 or 555 and no body -- it reads as a permissions problem.
SELECT object_name, object_type, status
FROM   user_objects
WHERE  status = 'INVALID'
ORDER  BY object_name;

-- 2. Every template must have a handler. handler_count = 0 is a dead URL that
--    answers but runs no code.
SELECT t.uri_template,
       COUNT(h.id) AS handler_count,
       LISTAGG(h.method, ', ') WITHIN GROUP (ORDER BY h.method) AS methods
FROM   user_ords_templates t
JOIN   user_ords_modules m ON m.id = t.module_id
LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
WHERE  m.name = 'expenses.employee'
GROUP  BY t.uri_template
ORDER  BY handler_count, t.uri_template;

-- 3. The login handler needs its Authorization parameter and the NVL guard.
--    Expect auth_param = 1 and has_safe_guard = Y.
SELECT (SELECT COUNT(*) FROM user_ords_parameters pa
        WHERE pa.handler_id = h.id AND UPPER(pa.name) = 'AUTHORIZATION') AS auth_param,
       CASE WHEN INSTR(UPPER(h.source), 'NVL(L_VALID, FALSE) = FALSE') > 0
            THEN 'Y' ELSE 'N' END AS has_safe_guard
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND    t.uri_template = 'auth/login';

-- 4. Must return NO rows. A wildcard also matches /expenses/auth/login and
--    makes logging in impossible: you would need a token to get a token.
SELECT pm.pattern
FROM   user_ords_privilege_mappings pm
WHERE  pm.pattern LIKE '/expenses/%*%'
   OR  pm.pattern = '/expenses/*';

-- 5. The approvals comment column must be COMMENTS (see PROD_1 section 2.1).
SELECT column_name
FROM   user_tab_columns
WHERE  table_name = 'EXPENSE_APPROVALS'
AND    column_name IN ('COMMENT', 'COMMENTS');
