--------------------------------------------------------------------------------
-- 81_fix_approvals_role_constraint.sql
--
-- Run as the APPLICATION SCHEMA, in SQL SCRIPTS. Idempotent.
-- DEV (HRMS) FIRST -- but READ THE PROD NOTE BELOW, because prod is probably
-- broken in exactly the same way and nobody has noticed.
--
--
-- MANAGER APPROVAL HAS NEVER WORKED
-- ---------------------------------
--   process_expense_action(115, 5710, 'ACCEPTED', ...)
--   code = 400
--   msg  = ORA-02290: check constraint (HRMS.CK_APPROVALS_ROLE) violated
--
-- get_reviewer_role returns 'PROJECT_MANAGER' at the MANAGER stage and
-- 'FINANCE_MANAGER' at the FINANCE stage. process_expense_action writes that
-- value into EXPENSE_APPROVALS.ROLE. On this schema the check constraint does
-- not allow 'PROJECT_MANAGER' -- so every manager approval fails and every
-- finance approval succeeds, which is exactly the symptom.
--
-- The constraint is a leftover from before the role was renamed. Dev used
-- REPORTING_MANAGER_ROLE where prod used PROJECT_MANAGER_ROLE;
-- 47_align_role_names.sql renamed the ORDS role and, reasonably enough, said
-- nothing about a table constraint nobody had thought about. The table here
-- predates that.
--
-- PROD_1_schema.sql line 114 has always declared the right thing:
--
--   CONSTRAINT ck_approvals_role CHECK (role IN ('PROJECT_MANAGER','FINANCE_MANAGER'))
--
-- but a CREATE TABLE does not run on a table that already exists, so the
-- correct definition has been sitting in the repo, unapplied, the whole time.
--
--
-- I LOOKED STRAIGHT AT THIS AND MISSED IT
-- ---------------------------------------
-- Earlier in this diagnosis I guessed at a check constraint on ROLE, grepped
-- PROD_1_schema.sql, saw the column list without a constraint and dropped the
-- idea. My grep window stopped at line 111. The constraint is on line 114.
--
-- The general fault is the same one that has cost this project the most time
-- this week: I read the SCRIPT instead of the DATABASE. user_constraints would
-- have answered it in one query, and it is a script's stated intent -- not the
-- schema's actual state -- that keeps being wrong here.
--
--
-- ** PRODUCTION IS PROBABLY BROKEN THE SAME WAY **
-- ------------------------------------------------
-- If REPO's EXPENSE_APPROVALS also predates the current script, manager
-- approval fails there too, and it would look like an intermittent 400 that
-- only some people hit. Section 1 is read-only -- run it on REPO before
-- assuming otherwise.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF
SET LINESIZE 200


--------------------------------------------------------------------------------
-- 1. READ-ONLY. What the constraint actually says, here, right now.
--
-- Safe on any schema including production. Run it on both.
--------------------------------------------------------------------------------
SELECT SYS_CONTEXT('USERENV','CURRENT_SCHEMA') AS schema_name,
       CASE SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
            WHEN 'HRMS' THEN 'dev' WHEN 'REPO' THEN '** PRODUCTION **'
            ELSE 'unrecognised' END AS environment
FROM   dual;

-- search_condition_vc is the readable copy; search_condition is a LONG and
-- awkward to select. 12.2+ has both.
SELECT constraint_name, constraint_type, status, validated, search_condition_vc
FROM   user_constraints
WHERE  table_name = 'EXPENSE_APPROVALS'
ORDER  BY constraint_name;
--
-- If ck_approvals_role does NOT list PROJECT_MANAGER, manager approval is
-- broken on this schema.

-- What is actually in the table. Old rows may carry the old name.
SELECT role, COUNT(*) AS rows_, MIN(acted_at) AS first_, MAX(acted_at) AS last_
FROM   expense_approvals
GROUP  BY role
ORDER  BY 2 DESC;


--------------------------------------------------------------------------------
-- 2. Rename any historical rows that use the old value.
--
-- REPORTING_MANAGER and PROJECT_MANAGER are the same role under two names --
-- 47_align_role_names.sql settled that, and the first approval stage has always
-- routed through the PROJECT_MANAGER table rather than an HR reporting line.
--
-- This has to happen BEFORE the constraint is recreated: a new constraint is
-- validated against existing rows, and one old row would make the whole thing
-- fail.
--
-- It rewrites approval history, which is not nothing. It is a rename of a label
-- and not a change to who approved what, and the alternative -- carrying the
-- constraint NOVALIDATE forever so two names for one role coexist -- is worse.
--------------------------------------------------------------------------------
DECLARE
  l_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_n FROM expense_approvals
  WHERE  role NOT IN ('PROJECT_MANAGER', 'FINANCE_MANAGER');

  IF l_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('All existing rows already use the current names.');
  ELSE
    FOR r IN (SELECT role, COUNT(*) c FROM expense_approvals
              WHERE role NOT IN ('PROJECT_MANAGER','FINANCE_MANAGER')
              GROUP BY role)
    LOOP
      DBMS_OUTPUT.PUT_LINE('  ' || r.c || ' row(s) with role = ' || r.role);
    END LOOP;

    UPDATE expense_approvals
    SET    role = 'PROJECT_MANAGER'
    WHERE  UPPER(role) IN ('REPORTING_MANAGER', 'MANAGER');
    DBMS_OUTPUT.PUT_LINE('  renamed ' || SQL%ROWCOUNT || ' to PROJECT_MANAGER');
    COMMIT;

    SELECT COUNT(*) INTO l_n FROM expense_approvals
    WHERE  role NOT IN ('PROJECT_MANAGER','FINANCE_MANAGER');
    IF l_n > 0 THEN
      RAISE_APPLICATION_ERROR(-20001,
        l_n || ' row(s) still hold a role value this script does not recognise. '
        || 'Look at section 1''s second query and decide what they should be. '
        || 'Refusing to add a constraint that would fail validation.');
    END IF;
  END IF;
END;
/


--------------------------------------------------------------------------------
-- 3. Replace the constraint.
--
-- Dropped and recreated rather than altered: a CHECK condition cannot be
-- modified in place. Named exactly as PROD_1_schema.sql declares it, so a
-- schema built from scratch and a schema repaired by this script end up
-- identical.
--------------------------------------------------------------------------------
DECLARE
  l_n    NUMBER;
  l_cond VARCHAR2(4000);
BEGIN
  SELECT COUNT(*), MAX(search_condition_vc) INTO l_n, l_cond
  FROM   user_constraints
  WHERE  table_name = 'EXPENSE_APPROVALS' AND constraint_name = 'CK_APPROVALS_ROLE';

  IF l_n > 0 THEN
    DBMS_OUTPUT.PUT_LINE('Existing condition: ' || l_cond);

    IF INSTR(UPPER(l_cond), 'PROJECT_MANAGER') > 0
    AND INSTR(UPPER(l_cond), 'FINANCE_MANAGER') > 0 THEN
      DBMS_OUTPUT.PUT_LINE('Already allows both roles -- nothing to do.');
      RETURN;
    END IF;

    EXECUTE IMMEDIATE 'ALTER TABLE expense_approvals DROP CONSTRAINT ck_approvals_role';
    DBMS_OUTPUT.PUT_LINE('Dropped the old constraint.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('No ck_approvals_role here -- adding it.');
  END IF;

  EXECUTE IMMEDIATE q'[
    ALTER TABLE expense_approvals ADD CONSTRAINT ck_approvals_role
    CHECK (role IN ('PROJECT_MANAGER','FINANCE_MANAGER'))]';

  DBMS_OUTPUT.PUT_LINE('ck_approvals_role now allows PROJECT_MANAGER and FINANCE_MANAGER.');
END;
/


--------------------------------------------------------------------------------
-- 4. Verify, then prove it end to end.
--------------------------------------------------------------------------------
SELECT constraint_name, status, validated, search_condition_vc
FROM   user_constraints
WHERE  table_name = 'EXPENSE_APPROVALS' AND constraint_name = 'CK_APPROVALS_ROLE';
-- ENABLED, VALIDATED, and both role names in the condition.

-- The same call that failed. Expect code 200 this time.
--
-- It really approves the claim and really sends the manager-accepted email, so
-- use a claim you are happy to move on. Remove the ROLLBACK to keep it.
SET SERVEROUTPUT ON
DECLARE
  l_id   NUMBER;
  l_code NUMBER;
  l_msg  VARCHAR2(4000);
  l_pm   NUMBER;
BEGIN
  SELECT MAX(id) INTO l_id FROM expenses
  WHERE  status = 'SUBMITTED' AND current_stage = 'MANAGER';

  IF l_id IS NULL THEN
    DBMS_OUTPUT.PUT_LINE('No claim at the MANAGER stage. Submit one and re-run.');
    RETURN;
  END IF;

  SELECT manager_empid INTO l_pm FROM expenses WHERE id = l_id;
  DBMS_OUTPUT.PUT_LINE('claim ' || l_id || ', manager ' || l_pm
    || ', role ' || NVL(get_reviewer_role(l_id, l_pm), '(null)'));

  process_expense_action(l_id, l_pm, 'ACCEPTED', 'constraint fix verification',
                         l_code, l_msg);
  DBMS_OUTPUT.PUT_LINE('code = ' || l_code);
  DBMS_OUTPUT.PUT_LINE('msg  = ' || l_msg);

  ROLLBACK;   -- take this out to actually approve it
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('RAISED: ' || SQLERRM);
    ROLLBACK;
END;
/


--------------------------------------------------------------------------------
-- 5. THEN CHECK PRODUCTION.
--
-- Run section 1 on REPO. If its ck_approvals_role does not list
-- PROJECT_MANAGER, then manager approval has never worked there either -- and
-- because the finance stage works fine, it would present as "approvals
-- sometimes fail" rather than as a broken feature.
--
-- Worth knowing how much of prod's approval history predates the rename:
--
--   SELECT role, COUNT(*), MIN(acted_at), MAX(acted_at)
--   FROM   expense_approvals GROUP BY role;
--
-- If prod needs it, run this whole script there. Sections 2 and 3 are the only
-- ones that change anything, and section 2 refuses to proceed if it finds a
-- role value it does not recognise.
--
--
-- AND ONE THING THIS EXPLAINS
--
-- The approval path has never been exercised on dev, because until yesterday no
-- project you were allocated to had a project manager. The first time anyone
-- could try it was the first time this constraint was hit. A whole stage of the
-- workflow was untestable for weeks for a reason that had nothing to do with
-- the workflow.
--------------------------------------------------------------------------------
