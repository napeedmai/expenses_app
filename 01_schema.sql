--------------------------------------------------------------------------------
-- Mobile Expense Upload App — Phase 1: Database Schema (Oracle) — v2
--
-- Only TWO new tables: EXPENSES and EXPENSE_APPROVALS.
-- Everything else reuses your existing tables — no new users/projects table:
--   EMPLOYEEDETAILS       — employee identity. PK = EMPID. ECODE is the
--                           employee's own code. RMCODE holds the *ECODE*
--                           of the employee's reporting manager (not an
--                           EMPID) — see get_manager_empid() below for the
--                           lookup this implies.
--   PROJECT_ALLOCATION_WB — which projects an employee is actually staffed
--                           on (EMP_ID, PROJECT_ID). Used to source the
--                           "Project" dropdown — informational only, per
--                           the plan, not used for approval routing.
--
-- Finance Manager: only one exists right now — EMPID 3680, hardcoded (see
-- is_finance_manager() below). If a second Finance Manager is ever added,
-- that function is the one place to change (swap the hardcode for a small
-- lookup table at that point).
--
-- Run this as a schema that has SELECT privileges on EMPLOYEEDETAILS and
-- PROJECT_ALLOCATION_WB. If those tables live in a different schema than
-- the one you run this script in, ask whoever owns them to run:
--   GRANT SELECT ON employeedetails TO <this_schema>;
--   GRANT SELECT ON project_allocation_wb TO <this_schema>;
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Helper function 1: resolve an employee's Reporting Manager to an EMPID.
-- RMCODE on EMPLOYEEDETAILS stores the manager's ECODE, not EMPID, so this
-- does the ECODE -> EMPID hop in one place instead of repeating the join in
-- every handler. Returns NULL if the employee has no RMCODE set, or if the
-- RMCODE doesn't match any existing ECODE.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_manager_empid(p_emp_id IN NUMBER) RETURN NUMBER IS
  l_manager_empid NUMBER;
BEGIN
  SELECT e2.empid
  INTO   l_manager_empid
  FROM   employeedetails e1
  JOIN   employeedetails e2 ON e2.ecode = e1.rmcode
  WHERE  e1.empid = p_emp_id;

  RETURN l_manager_empid;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RETURN NULL;
END get_manager_empid;
/

--------------------------------------------------------------------------------
-- Helper function 2: is this EMPID the Finance Manager?
-- Hardcoded to EMPID 3680 for now, per current org setup (single Finance
-- Manager). Centralized here so Phase 2 handlers never hardcode 3680
-- themselves — if a second Finance Manager is added later, this is the only
-- place that needs to change.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION is_finance_manager(p_emp_id IN NUMBER) RETURN VARCHAR2 IS
BEGIN
  RETURN CASE WHEN p_emp_id = 3680 THEN 'Y' ELSE 'N' END;
END is_finance_manager;
/

--------------------------------------------------------------------------------
-- 1. EXPENSES
--
-- emp_id / manager_empid / submitted_by all reference EMPLOYEEDETAILS.EMPID
-- directly.
--
-- manager_empid is a SNAPSHOT, resolved via get_manager_empid() at the
-- moment the expense is submitted — not looked up live on every read. This
-- matters because RMCODE can change later (someone gets a new manager);
-- snapshotting means an expense already awaiting approval doesn't silently
-- reroute mid-flight. finance_manager_empid is snapshotted the same way via
-- is_finance_manager()/hardcoded 3680, for the same reason.
--
-- status: DRAFT -> SUBMITTED -> (REVISION_REQUESTED loops back) -> APPROVED
--         or REJECTED (final, no resubmission) at either review stage.
-- current_stage: MANAGER or FINANCE — whose queue this sits in right now.
-- Both current_stage and the manager/finance snapshot columns are additions
-- beyond what's spelled out in the plan doc itself — flag with the team
-- when reviewing.
--------------------------------------------------------------------------------
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
    status                 VARCHAR2(30)    DEFAULT 'DRAFT' NOT NULL,
    current_stage          VARCHAR2(20),
    manager_empid          NUMBER,
    finance_manager_empid  NUMBER          DEFAULT 3680,
    submitted_by           NUMBER,
    submitted_at           TIMESTAMP,
    creation_date          DATE            DEFAULT SYSDATE NOT NULL,
    created_by             VARCHAR2(150),
    last_update_date       DATE            DEFAULT SYSDATE NOT NULL,
    last_updated_by        VARCHAR2(150),
    CONSTRAINT ck_expenses_status CHECK (
        status IN ('DRAFT', 'SUBMITTED', 'REVISION_REQUESTED', 'APPROVED', 'REJECTED')
    ),
    CONSTRAINT ck_expenses_stage CHECK (
        current_stage IN ('MANAGER', 'FINANCE') OR current_stage IS NULL
    ),
    CONSTRAINT ck_expenses_dates CHECK (to_date >= from_date),
    CONSTRAINT ck_expenses_amount CHECK (amount > 0),
    CONSTRAINT fk_expenses_emp FOREIGN KEY (emp_id) REFERENCES employeedetails(empid),
    CONSTRAINT fk_expenses_manager FOREIGN KEY (manager_empid) REFERENCES employeedetails(empid),
    CONSTRAINT fk_expenses_submitted_by FOREIGN KEY (submitted_by) REFERENCES employeedetails(empid)
);

COMMENT ON TABLE expenses IS 'One row per expense claim. emp_id/manager_empid/submitted_by reference EMPLOYEEDETAILS.EMPID directly — no separate users table.';
COMMENT ON COLUMN expenses.project_id IS 'Informational only (plan Section 5) — should come from PROJECT_ALLOCATION_WB.PROJECT_ID for this emp_id. No hard FK here: PROJECT_ALLOCATION_WB.PROJECT_ID is not unique on its own (an employee/project can have multiple allocation rows), so the handler should validate "does a PROJECT_ALLOCATION_WB row exist for this emp_id + project_id" in Phase 2 rather than relying on a DB constraint.';
COMMENT ON COLUMN expenses.manager_empid IS 'Snapshot of get_manager_empid(emp_id) taken at submit time — see note above on why this is snapshotted, not looked up live.';
COMMENT ON COLUMN expenses.finance_manager_empid IS 'Snapshot of the Finance Manager at submit time. Defaults to 3680 (see is_finance_manager()) — update the DEFAULT here too if that ever changes.';
COMMENT ON COLUMN expenses.attachment_mime_type IS 'Used to enforce allowed file types at the app/API layer: pdf, jpg, jpeg, png, xlsx, xls, csv, rar, zip (Section 5). rar/zip should be virus-scanned server-side before storage.';

CREATE INDEX ix_expenses_emp ON expenses(emp_id);
CREATE INDEX ix_expenses_status_stage ON expenses(status, current_stage);

--------------------------------------------------------------------------------
-- 2. EXPENSE_APPROVALS
-- Audit trail of every accept/revise/reject action taken on an expense.
-- approver_id references EMPLOYEEDETAILS.EMPID directly.
--------------------------------------------------------------------------------
CREATE TABLE expense_approvals (
    id                NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    expense_id        NUMBER          NOT NULL,
    approver_id       NUMBER          NOT NULL,
    role              VARCHAR2(30)    NOT NULL,
    action            VARCHAR2(20)    NOT NULL,
    comment           VARCHAR2(4000),
    acted_at          TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    creation_date     DATE            DEFAULT SYSDATE NOT NULL,
    created_by        VARCHAR2(150),
    last_update_date  DATE            DEFAULT SYSDATE NOT NULL,
    last_updated_by   VARCHAR2(150),
    CONSTRAINT ck_approvals_role CHECK (role IN ('REPORTING_MANAGER', 'FINANCE_MANAGER')),
    CONSTRAINT ck_approvals_action CHECK (action IN ('ACCEPTED', 'REVISED', 'REJECTED')),
    CONSTRAINT fk_approvals_expense FOREIGN KEY (expense_id) REFERENCES expenses(id),
    CONSTRAINT fk_approvals_approver FOREIGN KEY (approver_id) REFERENCES employeedetails(empid)
);

COMMENT ON TABLE expense_approvals IS 'Append-only audit log — one row per accept/revise/reject action, at either review stage. approver_id references EMPLOYEEDETAILS.EMPID.';

CREATE INDEX ix_approvals_expense ON expense_approvals(expense_id);

--------------------------------------------------------------------------------
-- Triggers to bump the audit columns automatically, matching the same
-- created_by/last_updated_by/creation_date/last_update_date convention
-- already used on EMPLOYEEDETAILS and PROJECT_ALLOCATION_WB.
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
