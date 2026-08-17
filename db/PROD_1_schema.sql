
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
        finance_manager_empid  NUMBER          DEFAULT 3680,
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
