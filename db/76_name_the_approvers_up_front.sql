--------------------------------------------------------------------------------
-- 76_name_the_approvers_up_front.sql
--
-- Run as the APPLICATION SCHEMA, in SQL SCRIPTS. Idempotent.
-- Run AFTER 73 (which restored these two handlers).
--
--   dev  = karyasiddhitest.trinamix.com, schema HRMS
--   prod = karyasiddhi.trinamix.com,     schema REPO
--
--
-- WHY
-- ---
-- Opening a new expense showed:
--
--     Reporting Manager     Set when you submit
--     Manager (Finance)     Set when you submit
--
-- Two problems in three words.
--
-- 1. "Set when you submit" was true only because nothing told the screen any
--    earlier. Both approvers are knowable the moment a project is chosen: the
--    project manager comes from the project, and the finance manager is a
--    constant. Making someone submit to find out who is about to receive their
--    claim is a bad trade for no reason.
--
-- 2. "Reporting Manager" is the wrong name. The field is resolved by
--    get_project_manager_empid(project_id), which reads the PROJECT_MANAGER
--    table -- it is the manager OF THE PROJECT, not the employee's HR reporting
--    line. Those are often different people. The label came from the field list
--    I was given and I used it verbatim without noticing it described something
--    else. The app-side rename is a separate change; this script supplies the
--    data.
--
--
-- WHAT CHANGES
-- ------------
--   GET /expenses/my-projects   + manager_empid, manager_name
--   GET /expenses/whoami        + finance_manager_empid, finance_manager_name
--
-- No new templates and no privilege changes -- both handlers already exist, so
-- there is nothing here that can empty the module.
--
-- Both derive their answer by CALLING the same functions the submit handler
-- calls, rather than by joining to the tables themselves. One definition of
-- "who approves this", so the name shown to the user cannot disagree with the
-- person the claim is actually routed to.
--
-- is_reporting_manager stays in the whoami payload under its old name. It is an
-- internal role flag that LoginScreen reads, and renaming a field in the same
-- change as adding two others is how a working screen goes blank.
--
--
-- A NULL manager_name IS INFORMATION, NOT A GAP
-- ---------------------------------------------
-- A project with no PROJECT_MANAGER row cannot be approved at the first stage.
-- Today that surfaces at submit, in an email. Returning it here lets the screen
-- say so while the person is still choosing the project. Dev's project 7288 is
-- exactly this case, which is why the approval flow could not be tested there.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF


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
--------------------------------------------------------------------------------
-- 3. Verify.
--------------------------------------------------------------------------------

-- a) Both handlers carry the new fields, and still have their 2 header params.
SELECT t.uri_template, h.method,
       (SELECT COUNT(*) FROM user_ords_parameters pa WHERE pa.handler_id = h.id) AS params,
       CASE WHEN INSTR(h.source, 'manager_name') > 0 THEN 'Y' ELSE 'N' END AS has_manager_name,
       CASE WHEN INSTR(h.source, 'is_reporting_manager') > 0 THEN 'Y' ELSE '-' END AS kept_role_flag
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND    t.uri_template IN ('whoami','my-projects')
ORDER  BY t.uri_template;
-- Expect: my-projects 2 params, has_manager_name Y
--         whoami      2 params, has_manager_name Y, kept_role_flag Y


-- b) What the two endpoints will now return for you.
--    CHANGE 3680 BELOW to whichever empid you are logged in as. A literal
--    rather than a DEFINE, because SET DEFINE OFF is on at the top of this file
--    (the handler bodies need it) and substitution variables are unreliable
--    under it in APEX SQL Scripts.

SELECT e.empid,
       e.first_name || ' ' || e.last_name AS display_name,
       is_finance_manager(e.empid)        AS is_finance_manager,
       get_finance_manager_empid()        AS finance_manager_empid,
       (SELECT f.first_name || ' ' || f.last_name FROM employeedetails f
        WHERE  f.empid = get_finance_manager_empid()) AS finance_manager_name
FROM   employeedetails e
WHERE  e.empid = 3680;

SELECT DISTINCT pa.project_id, pm.project_name,
       get_project_manager_empid(pa.project_id) AS manager_empid,
       (SELECT m.first_name || ' ' || m.last_name FROM employeedetails m
        WHERE  m.empid = get_project_manager_empid(pa.project_id)) AS manager_name
FROM   project_allocation_wb pa
JOIN   projectmaster pm ON pm.project_id = pa.project_id
WHERE  pa.emp_id = 3680
AND   (pa.res_end_date IS NULL OR pa.res_end_date >= TRUNC(SYSDATE))
AND    pm.status = 'ACTIVE'
ORDER  BY pm.project_name;
-- On dev this should be one row: 7288 "test", manager_empid NULL. That NULL is
-- the reason the approval flow cannot be tested there -- see 73 section 5.


-- c) Nothing in the module references a dropped column. Run this after ANY
--    ORDS script. MUST RETURN NO ROWS.
SELECT t.uri_template, h.method
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND   (INSTR(LOWER(h.source), 'e.bill_no')    > 0
    OR INSTR(LOWER(h.source), 'e.bill_date')  > 0
    OR INSTR(LOWER(h.source), 'e.type')       > 0
    OR INSTR(LOWER(h.source), 'e.description') > 0
    OR INSTR(LOWER(h.source), 'e.attachment') > 0)
ORDER  BY t.uri_template, h.method;


-- d) And no template without a handler. MUST RETURN NO ROWS.
SELECT t.uri_template, COUNT(h.id) AS handlers
FROM   user_ords_templates t
JOIN   user_ords_modules m ON m.id = t.module_id
LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
WHERE  m.name = 'expenses.employee'
GROUP  BY t.uri_template HAVING COUNT(h.id) = 0;


--------------------------------------------------------------------------------
-- 4. The app side of this change
--
-- src/screens/AddEditExpenseScreen.js
--   * label "Reporting Manager" -> "Project Manager"
--   * populate both names from the selected project and from whoami, instead of
--     only from a saved claim
--   * when manager_name is NULL, say the project has no manager rather than
--     leaving the row blank -- a blank reads as "not loaded yet"
--
-- The emails already say "project manager" in their body text, so nothing there
-- needs changing. get_reviewer_role still returns PROJECT_MANAGER /
-- FINANCE_MANAGER, which was right all along; only the app label was wrong.
--------------------------------------------------------------------------------
