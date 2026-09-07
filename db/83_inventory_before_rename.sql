--------------------------------------------------------------------------------
-- 83_inventory_before_rename.sql
--
-- READ-ONLY. Changes nothing, creates nothing, drops nothing.
-- Safe on dev AND on production. Run it on both.
--
--   dev  = karyasiddhitest.trinamix.com, schema HRMS
--   prod = karyasiddhi.trinamix.com,     schema REPO
--
--
-- WHY THIS EXISTS BEFORE THE RENAME
-- ---------------------------------
-- HRMS is a SHARED schema. It holds this expense app, an unrelated resource
-- management application (the one whose "Resource End Date Change Notification"
-- mail turned up in APEX_MAIL_QUEUE), the company HR tables, and roughly 190
-- pre-existing INVALID objects that belong to none of it.
--
-- So "rename everything in dev" cannot be taken literally. Renaming an object
-- that belongs to someone else's system breaks that system silently, and there
-- is no undo once the dependent PL/SQL has been recompiled around the new name.
-- The rename has to work from an EXPLICIT list, and this script is how that
-- list gets built from the database rather than from my reading of the repo.
--
-- The repo has been wrong about the schema three times on this project --
-- CK_APPROVALS_ROLE most recently, where the correct definition sat in
-- PROD_1_schema.sql having never been applied. Treat sections 1-3 as the truth
-- and my candidate list as a guess to be checked against them.
--
--
-- WHAT WE ARE ABOUT TO DO, SO YOU CAN JUDGE WHAT MATTERS
-- ------------------------------------------------------
--   * every expense-app object gets an XXKS_EXP_ prefix
--   * procedures and functions stay standalone (not packaged)
--   * unwanted objects get dropped, but only from a list you have approved
--   * every table carries CREATED_BY, CREATION_DATE, LAST_UPDATED_BY,
--     LAST_UPDATE_DATE
--
-- Section 6 is the one to read most carefully: it finds anything OUTSIDE the
-- app that depends on the app's objects. Each row there is something that
-- breaks the moment we rename, and it is much cheaper to know now.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET PAGESIZE 200


--------------------------------------------------------------------------------
-- 0. Where am I.
--------------------------------------------------------------------------------
SELECT SYS_CONTEXT('USERENV','CURRENT_SCHEMA') AS schema_name,
       CASE SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
            WHEN 'HRMS' THEN 'dev' WHEN 'REPO' THEN '** PRODUCTION **'
            ELSE 'unrecognised' END AS environment,
       (SELECT COUNT(*) FROM user_objects)                        AS objects_in_schema,
       (SELECT COUNT(*) FROM user_objects WHERE status != 'VALID') AS invalid_in_schema
FROM   dual;
-- invalid_in_schema will be a large number. Most of it is not ours and never
-- was. Section 5 narrows it to objects we are responsible for.


--------------------------------------------------------------------------------
-- 1. Everything that LOOKS like ours.
--
-- Deliberately wider than my candidate list: any name containing EXPENSE, plus
-- the specific odd ones. If this returns an object I have not accounted for in
-- the rename map, that object was written by someone else at some point and
-- needs a decision before we touch anything.
--
-- KNOWN NOT OURS, and excluded on purpose -- renaming any of these would break
-- the company's HR systems:
--   EMPLOYEEDETAILS  PROJECTMASTER  PROJECT_ALLOCATION_WB  CURRENCY_CONVERSION
--------------------------------------------------------------------------------
SELECT object_name, object_type, status,
       TO_CHAR(created, 'DD-Mon-YYYY') AS created,
       TO_CHAR(last_ddl_time, 'DD-Mon-YYYY') AS last_ddl
FROM   user_objects
WHERE  object_type IN ('TABLE','VIEW','SEQUENCE','TRIGGER','PROCEDURE','FUNCTION',
                       'PACKAGE','PACKAGE BODY','TYPE','TYPE BODY','INDEX',
                       'MATERIALIZED VIEW','SYNONYM')
AND   (object_name LIKE '%EXPENSE%'
    OR object_name LIKE 'XXKS%'
    OR object_name IN ('APP_SECRETS','EMP_PUSH_TOKENS',
                       'SEND_PUSH_NOTIFICATION','TEST_PUSH_NOTIFICATION',
                       'GET_OAUTH_ACCESS_TOKEN','GENERATE_SESSION_TOKEN',
                       'IS_VALID_SESSION_TOKEN','HMAC_SHA','JSON_ESCAPE_STR',
                       'IS_ALLOWED_ATTACHMENT','CONVERT_TO_USD',
                       'GET_EXCHANGE_RATE','GET_RATE_EFFECTIVE_DATE',
                       'GET_FINANCE_MANAGER_EMPID','GET_PROJECT_MANAGER_EMPID',
                       'GET_REVIEWER_ROLE','IS_FINANCE_MANAGER',
                       'CAN_VIEW_CLAIM','CAN_EDIT_CLAIM',
                       'PRICE_EXPENSE_ITEM','RECALC_CLAIM_TOTALS',
                       'SCAN_RECEIPT','TRG_COPY_PM_TO_EXPENSE'))
ORDER  BY object_type, object_name;


--------------------------------------------------------------------------------
-- 2. Table detail: rows, and whether the who columns are already there.
--
-- who_cols counts how many of the four are present. 4 = nothing to add.
-- A table with 0 rows is not automatically dead -- EXPENSE_SCAN_LOG is empty
-- because the OpenAI account has no credit, not because nobody wants it.
--------------------------------------------------------------------------------
DECLARE
  l_rows NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE(RPAD('TABLE', 30) || RPAD('ROWS', 10)
                       || RPAD('WHO_COLS', 10) || 'MISSING');
  DBMS_OUTPUT.PUT_LINE(RPAD('-', 90, '-'));

  FOR t IN (SELECT table_name FROM user_tables
            WHERE  table_name LIKE '%EXPENSE%'
            OR     table_name IN ('APP_SECRETS','EMP_PUSH_TOKENS')
            ORDER  BY table_name)
  LOOP
    -- Dynamic because the table list is not known until run time. COUNT(*) is
    -- exact; NUM_ROWS from user_tables is whatever the last stats gather said
    -- and can be years old or absent, which is not good enough for a decision
    -- about dropping something.
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM "' || t.table_name || '"' INTO l_rows;

    DECLARE
      l_have NUMBER;
      l_miss VARCHAR2(200);
    BEGIN
      SELECT COUNT(*) INTO l_have FROM user_tab_columns
      WHERE  table_name = t.table_name
      AND    column_name IN ('CREATED_BY','CREATION_DATE',
                             'LAST_UPDATED_BY','LAST_UPDATE_DATE');

      SELECT LISTAGG(c, ',') WITHIN GROUP (ORDER BY c) INTO l_miss
      FROM  (SELECT 'CREATED_BY' c FROM dual UNION ALL
             SELECT 'CREATION_DATE'    FROM dual UNION ALL
             SELECT 'LAST_UPDATED_BY'  FROM dual UNION ALL
             SELECT 'LAST_UPDATE_DATE' FROM dual)
      WHERE c NOT IN (SELECT column_name FROM user_tab_columns
                      WHERE table_name = t.table_name);

      DBMS_OUTPUT.PUT_LINE(RPAD(t.table_name, 30) || RPAD(l_rows, 10)
                           || RPAD(l_have || '/4', 10) || NVL(l_miss, '-'));
    END;
  END LOOP;
END;
/


--------------------------------------------------------------------------------
-- 3. Indexes, constraints and triggers hanging off those tables.
--
-- These need renaming too, and they are the ones that get forgotten: a table
-- called XXKS_EXP_EXPENSES with a constraint still called CK_APPROVALS_ROLE is
-- half a job, and the half that is left is the half nobody can find later.
--------------------------------------------------------------------------------
SELECT table_name, index_name, uniqueness,
       (SELECT LISTAGG(column_name, ',') WITHIN GROUP (ORDER BY column_position)
        FROM   user_ind_columns c WHERE c.index_name = i.index_name) AS cols
FROM   user_indexes i
WHERE  table_name LIKE '%EXPENSE%' OR table_name IN ('APP_SECRETS','EMP_PUSH_TOKENS')
ORDER  BY table_name, index_name;

SELECT table_name, constraint_name, constraint_type, status,
       search_condition_vc
FROM   user_constraints
WHERE  table_name LIKE '%EXPENSE%' OR table_name IN ('APP_SECRETS','EMP_PUSH_TOKENS')
ORDER  BY table_name,
          CASE constraint_type WHEN 'P' THEN 1 WHEN 'U' THEN 2
                               WHEN 'R' THEN 3 ELSE 4 END,
          constraint_name;
-- System-generated names (SYS_C00...) are NOT NULL checks. They cannot be
-- renamed usefully and do not need to be.

SELECT trigger_name, table_name, trigger_type, triggering_event, status
FROM   user_triggers
WHERE  table_name LIKE '%EXPENSE%' OR table_name IN ('APP_SECRETS','EMP_PUSH_TOKENS')
ORDER  BY table_name, trigger_name;
-- TRG_COPY_PM_TO_EXPENSE is expected here and has never been explained. It is
-- not in the repo. Read its body before the rename -- if it writes
-- MANAGER_EMPID, it is competing with the submit handler, which also writes it.


--------------------------------------------------------------------------------
-- 4. Which of our subprograms does any ORDS handler actually call?
--
-- This is the strongest evidence for keep-vs-drop. A function no handler calls
-- and no other PL/SQL calls is dead code -- and dead code in a shared schema is
-- worse than dead code in a repo, because the next person cannot tell whose it
-- is.
--
-- Counted against the handler SOURCE (a CLOB), so DBMS_LOB.INSTR rather than
-- INSTR. A plain INSTR on a CLOB silently searches only the first chunk, which
-- is how VERIFY_MODULE quietly returned nothing three times.
--------------------------------------------------------------------------------
DECLARE
  TYPE t_names IS TABLE OF VARCHAR2(128);
  l_names t_names := t_names(
    'PROCESS_EXPENSE_ACTION','SEND_EXPENSE_MAIL','RECALC_CLAIM_TOTALS',
    'PRICE_EXPENSE_ITEM','SCAN_RECEIPT','EXPENSE_LOGIN_RECORD',
    'GET_OAUTH_ACCESS_TOKEN','SEND_PUSH_NOTIFICATION','TEST_PUSH_NOTIFICATION',
    'EXPENSE_LOGIN_RETRY_AFTER','GENERATE_SESSION_TOKEN','IS_VALID_SESSION_TOKEN',
    'HMAC_SHA','JSON_ESCAPE_STR','IS_ALLOWED_ATTACHMENT','CONVERT_TO_USD',
    'GET_EXCHANGE_RATE','GET_RATE_EFFECTIVE_DATE','GET_FINANCE_MANAGER_EMPID',
    'GET_PROJECT_MANAGER_EMPID','GET_REVIEWER_ROLE','IS_FINANCE_MANAGER',
    'CAN_VIEW_CLAIM','CAN_EDIT_CLAIM');
  l_h NUMBER;
  l_p NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE(RPAD('SUBPROGRAM', 32) || RPAD('IN_HANDLERS', 14)
                       || RPAD('CALLED_BY_PLSQL', 18) || 'VERDICT');
  DBMS_OUTPUT.PUT_LINE(RPAD('-', 90, '-'));

  FOR i IN 1 .. l_names.COUNT LOOP
    SELECT COUNT(*) INTO l_h FROM user_ords_handlers
    WHERE  DBMS_LOB.INSTR(LOWER(source), LOWER(l_names(i))) > 0;

    -- Dependencies exclude self-reference, which every subprogram has.
    SELECT COUNT(*) INTO l_p FROM user_dependencies
    WHERE  referenced_name = l_names(i)
    AND    name != l_names(i);

    DBMS_OUTPUT.PUT_LINE(
      RPAD(l_names(i), 32) || RPAD(l_h, 14) || RPAD(l_p, 18)
      || CASE WHEN l_h = 0 AND l_p = 0 THEN '** nothing calls it **'
              ELSE 'in use' END);
  END LOOP;
END;
/


--------------------------------------------------------------------------------
-- 5. Our objects only -- which are INVALID right now.
--
-- The schema-wide count from section 0 is noise. This is the number that has to
-- be zero before AND after the rename, so record it now: if something is
-- already broken, the rename did not break it and we should not spend an
-- afternoon proving otherwise.
--------------------------------------------------------------------------------
SELECT object_name, object_type, status
FROM   user_objects
WHERE  status != 'VALID'
AND   (object_name LIKE '%EXPENSE%' OR object_name LIKE 'XXKS%'
    OR object_name IN ('APP_SECRETS','EMP_PUSH_TOKENS','SCAN_RECEIPT',
                       'HMAC_SHA','JSON_ESCAPE_STR','CONVERT_TO_USD',
                       'GET_EXCHANGE_RATE','GET_RATE_EFFECTIVE_DATE',
                       'GENERATE_SESSION_TOKEN','IS_VALID_SESSION_TOKEN',
                       'GET_OAUTH_ACCESS_TOKEN','IS_ALLOWED_ATTACHMENT',
                       'GET_FINANCE_MANAGER_EMPID','GET_PROJECT_MANAGER_EMPID',
                       'GET_REVIEWER_ROLE','IS_FINANCE_MANAGER',
                       'CAN_VIEW_CLAIM','CAN_EDIT_CLAIM','PRICE_EXPENSE_ITEM',
                       'RECALC_CLAIM_TOTALS','SEND_PUSH_NOTIFICATION',
                       'TEST_PUSH_NOTIFICATION'))
ORDER  BY object_type, object_name;


--------------------------------------------------------------------------------
-- 6. ** READ THIS ONE CAREFULLY **
--
-- Anything OUTSIDE the expense app that depends on an expense-app object.
--
-- Every row is something that breaks when we rename, owned by someone who does
-- not know this is happening. A shared schema means another team may well have
-- written a report or a view over EXPENSES without telling anyone -- that is
-- not misuse, it is what a shared schema is for.
--
-- Zero rows means the rename is ours alone to do. Rows mean a conversation
-- before any DDL, and possibly a synonym left behind under the old name.
--------------------------------------------------------------------------------
SELECT d.name AS dependent_object, d.type AS dependent_type,
       d.referenced_name AS depends_on_ours, d.referenced_type
FROM   user_dependencies d
WHERE  d.referenced_name IN (
         SELECT object_name FROM user_objects
         WHERE  object_name LIKE '%EXPENSE%'
         OR     object_name IN ('APP_SECRETS','EMP_PUSH_TOKENS'))
AND    d.name NOT LIKE '%EXPENSE%'
AND    d.name NOT IN ('APP_SECRETS','EMP_PUSH_TOKENS','SCAN_RECEIPT',
                      'PRICE_EXPENSE_ITEM','RECALC_CLAIM_TOTALS',
                      'CAN_VIEW_CLAIM','CAN_EDIT_CLAIM','GET_REVIEWER_ROLE',
                      'IS_FINANCE_MANAGER','GET_FINANCE_MANAGER_EMPID',
                      'GET_PROJECT_MANAGER_EMPID','CONVERT_TO_USD',
                      'GET_EXCHANGE_RATE','GET_RATE_EFFECTIVE_DATE',
                      'IS_VALID_SESSION_TOKEN','GENERATE_SESSION_TOKEN',
                      'HMAC_SHA','JSON_ESCAPE_STR','IS_ALLOWED_ATTACHMENT',
                      'GET_OAUTH_ACCESS_TOKEN','SEND_PUSH_NOTIFICATION',
                      'TEST_PUSH_NOTIFICATION')
ORDER  BY d.name;

-- Same question for APEX. An APEX page or process in ANOTHER application that
-- reads EXPENSES would not appear above.
SELECT application_id, application_name, page_id, page_name, component_type,
       component_name
FROM   apex_application_page_regions
WHERE  UPPER(region_source) LIKE '%EXPENSE%'
UNION  ALL
SELECT application_id, application_name, page_id, page_name, 'PROCESS',
       process_name
FROM   apex_application_page_proc
WHERE  UPPER(process_source) LIKE '%EXPENSE%';
-- May raise ORA-00942 if the reporting views are not granted to this user.
-- That is not a failure of this script -- skip it and ask a DBA instead.


--------------------------------------------------------------------------------
-- 7. ORDS modules, so we know exactly how many handlers must be rewritten.
--
-- The rename does NOT change any endpoint URI and does NOT change any JSON
-- field name. That is a firm constraint, not a preference: the app calls these
-- paths and reads these fields, and a schema tidy-up that forces a mobile
-- release is not a tidy-up.
--------------------------------------------------------------------------------
SELECT m.name AS module_name, m.uri_prefix, COUNT(h.id) AS handlers
FROM   user_ords_modules m
LEFT   JOIN user_ords_templates t ON t.module_id = m.id
LEFT   JOIN user_ords_handlers  h ON h.template_id = t.id
GROUP  BY m.name, m.uri_prefix
ORDER  BY m.name;

SELECT t.uri_pattern, h.method, h.source_type
FROM   user_ords_templates t
JOIN   user_ords_modules   m ON m.id = t.module_id
LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
WHERE  m.name LIKE 'expenses%'
ORDER  BY t.uri_pattern, h.method;
-- A template with a NULL method is a URL that answers and runs nothing. There
-- should be none: that was the 555 in script 72.


--------------------------------------------------------------------------------
-- WHAT TO SEND BACK
--
-- All of it, but sections 4 and 6 are the ones that decide anything:
--
--   4 tells us what is genuinely dead and can be dropped rather than renamed
--   6 tells us whether the rename is safe to do at all
--
-- Nothing has changed. The next script does not get written until these are
-- read.
--------------------------------------------------------------------------------
