--------------------------------------------------------------------------------
-- PROD_STATE_SEP2026.sql
--
-- READ-ONLY. Changes nothing. Creates nothing. Drops nothing.
-- Run on PROD (REPO @ karyasiddhi.trinamix.com), then on DEV, and compare.
--
--
-- WHY THIS COMES BEFORE THE MIGRATION FILE
-- ----------------------------------------
-- Prod last received PROD_MIGRATE_AUG2026.sql, which carried scripts 69 to 77.
-- Everything after that is dev-only:
--
--   79, 79b-79e   AI receipt scanning
--   80, 80b       login rate limiting
--   81            the CK_APPROVALS_ROLE fix
--   82            per-type totals on /expenses/mine
--   84            push removal
--
-- Bundling those into one file and running it on production is the obvious
-- move, and there is one specific reason not to do it blind.
--
--
-- ** THE LOCKOUT HAZARD **
--
-- Script 79 rebuilds the ORDS privilege expenses.authenticated from an
-- EXPLICIT list of URI patterns. ORDS.DEFINE_PRIVILEGE replaces the entire
-- pattern set -- there is no call that adds one pattern to an existing
-- privilege. So if prod protects even one endpoint that dev's list does not
-- name, running 79 there silently removes it from the privilege and that
-- endpoint starts answering 401.
--
-- The symptom would be "some screens stopped working after the release", on
-- production, caused by a script whose actual job was adding receipt scanning.
-- Section 6 exists to make that impossible: it prints prod's current pattern
-- list so the migration can be built from PROD's endpoints, not from dev's.
--
--
-- ALSO WORTH KNOWING BEFORE, NOT AFTER
--
--   * Section 3 of script 64 was never run on prod, so EXPENSES there may still
--     carry BILL_NO, TYPE, DESCRIPTION and the ATTACHMENT_* columns. That does
--     not block anything -- but it means prod and dev are structurally
--     different, and the rename should know that.
--
--   * CK_APPROVALS_ROLE is very likely broken on prod exactly as it was on dev,
--     where it made every project-manager approval fail with ORA-02290 for
--     weeks. Nobody would have reported it as a bug; finance approvals work
--     fine, so it presents as "approvals sometimes fail".
--
--   * Receipt scanning needs an APEX AI service and an OpenAI account with
--     credit. The dev account is currently exhausted. Deploying 79 to prod puts
--     the plumbing in place; it will not scan anything until that is sorted.
--     Better to know that now than to demo it.
--
-- No secret VALUES are selected anywhere in this script. Names only.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET PAGESIZE 200


--------------------------------------------------------------------------------
-- 0. Which database am I on.
--------------------------------------------------------------------------------
SELECT SYS_CONTEXT('USERENV','CURRENT_SCHEMA') AS schema_name,
       CASE SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
            WHEN 'HRMS' THEN 'dev' WHEN 'REPO' THEN '** PRODUCTION **'
            ELSE 'unrecognised' END AS environment,
       SYS_CONTEXT('USERENV','DB_NAME') AS db_name,
       TO_CHAR(SYSDATE, 'DD-Mon-YYYY HH24:MI') AS run_at
FROM   dual;


--------------------------------------------------------------------------------
-- 1. Has the multi-bill cleanup run here?
--
-- legacy_cols 0 = script 64 section 3 ran. 8 = it did not.
--------------------------------------------------------------------------------
SELECT (SELECT COUNT(*) FROM user_tab_columns
        WHERE  table_name = 'EXPENSES'
        AND    column_name IN ('BILL_NO','BILL_DATE','TYPE','DESCRIPTION',
                               'ATTACHMENT_BLOB','ATTACHMENT_FILENAME',
                               'ATTACHMENT_MIME_TYPE','ATTACHMENT_PATH'))
         AS legacy_cols_on_expenses,
       (SELECT COUNT(*) FROM user_tables WHERE table_name = 'EXPENSE_ITEMS')
         AS has_expense_items,
       (SELECT COUNT(*) FROM user_tab_columns
        WHERE  table_name = 'EXPENSES' AND column_name = 'CLAIM_FOR')
         AS has_claim_for
FROM   dual;

SELECT column_name, data_type, nullable
FROM   user_tab_columns
WHERE  table_name = 'EXPENSES'
AND    column_name IN ('BILL_NO','BILL_DATE','TYPE','DESCRIPTION',
                       'ATTACHMENT_BLOB','ATTACHMENT_FILENAME',
                       'ATTACHMENT_MIME_TYPE','ATTACHMENT_PATH')
ORDER  BY column_name;
-- If rows come back, decide separately whether to drop them. Do NOT assume the
-- columns are empty -- check before dropping:
--   SELECT COUNT(*) FROM expenses WHERE bill_no IS NOT NULL OR type IS NOT NULL;


--------------------------------------------------------------------------------
-- 2. ** IS MANAGER APPROVAL BROKEN HERE? **
--
-- If the condition does not name PROJECT_MANAGER, every project-manager
-- approval on production is failing with ORA-02290 right now.
--------------------------------------------------------------------------------
SELECT constraint_name, status, validated, search_condition_vc
FROM   user_constraints
WHERE  table_name = 'EXPENSE_APPROVALS'
ORDER  BY constraint_name;

SELECT role, COUNT(*) AS rows_, MIN(acted_at) AS first_, MAX(acted_at) AS last_
FROM   expense_approvals
GROUP  BY role ORDER BY 2 DESC;
-- Old rows may still say REPORTING_MANAGER. Script 81 renames them, and it
-- refuses to proceed if it finds a value it does not recognise.


--------------------------------------------------------------------------------
-- 3. Which of the dev-only objects already exist here.
--
-- Anything marked "MISSING" is something the migration must create; anything
-- marked "present" it must not create twice.
--------------------------------------------------------------------------------
DECLARE
  TYPE t_names IS TABLE OF VARCHAR2(128);
  l_names t_names := t_names(
    'SCAN_RECEIPT','EXPENSE_SCAN_LOG',                       -- 79 series
    'EXPENSE_LOGIN_ATTEMPTS','EXPENSE_LOGIN_RECORD',
    'EXPENSE_LOGIN_RETRY_AFTER',                             -- 80 / 80b
    'EMP_PUSH_TOKENS','SEND_PUSH_NOTIFICATION',
    'TEST_PUSH_NOTIFICATION',                                -- 84 removes these
    'EXPENSES_PRE_MULTIBILL','EXPENSE_APPROVALS_PRE_MULTIBILL',
    'EMP_EXPENSE_REQUEST',
    'XXKS_EXP_CLAIMS');                                      -- rename done?
  l_n NUMBER;
  l_t VARCHAR2(30);
BEGIN
  DBMS_OUTPUT.PUT_LINE(RPAD('OBJECT', 34) || RPAD('TYPE', 12) || 'STATE');
  DBMS_OUTPUT.PUT_LINE(RPAD('-', 70, '-'));
  FOR i IN 1 .. l_names.COUNT LOOP
    SELECT COUNT(*), MAX(object_type) INTO l_n, l_t
    FROM   user_objects WHERE object_name = l_names(i)
    AND    object_type IN ('TABLE','PROCEDURE','FUNCTION');
    DBMS_OUTPUT.PUT_LINE(RPAD(l_names(i), 34) || RPAD(NVL(l_t,'-'), 12)
                         || CASE WHEN l_n > 0 THEN 'present' ELSE '** MISSING **' END);
  END LOOP;
END;
/


--------------------------------------------------------------------------------
-- 4. Secret NAMES only. Never the values.
--
-- AI_SERVICE_STATIC_ID is what script 79 needs. If it is absent here, receipt
-- scanning will deploy and then fail with a clear message rather than working.
--------------------------------------------------------------------------------
SELECT secret_name,
       CASE WHEN secret_value IS NULL THEN 'NULL'
            ELSE 'set (' || LENGTH(secret_value) || ' chars)' END AS value_state
FROM   app_secrets
ORDER  BY secret_name;


--------------------------------------------------------------------------------
-- 5. ORDS: what is deployed, and what is missing.
--------------------------------------------------------------------------------
SELECT m.name AS module_name, m.uri_prefix, m.status,
       COUNT(DISTINCT t.id) AS templates, COUNT(h.id) AS handlers
FROM   user_ords_modules m
LEFT   JOIN user_ords_templates t ON t.module_id = m.id
LEFT   JOIN user_ords_handlers  h ON h.template_id = t.id
GROUP  BY m.name, m.uri_prefix, m.status
ORDER  BY m.name;

-- Every endpoint, and whether it actually runs anything. A template with no
-- method is a URL that answers and does nothing -- the 555 from script 72.
SELECT t.uri_template, NVL(h.method, '** NO HANDLER **') AS method, h.source_type
FROM   user_ords_templates t
JOIN   user_ords_modules   m ON m.id = t.module_id
LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
WHERE  m.name LIKE 'expenses%'
ORDER  BY t.uri_template, h.method;

-- Feature flags, read from the handlers themselves rather than from the repo.
SELECT
  (SELECT COUNT(*) FROM user_ords_templates t JOIN user_ords_modules m
     ON m.id = t.module_id WHERE m.name LIKE 'expenses%'
     AND t.uri_template = 'scan-receipt')                    AS has_scan_receipt,
  (SELECT COUNT(*) FROM user_ords_templates t JOIN user_ords_modules m
     ON m.id = t.module_id WHERE m.name LIKE 'expenses%'
     AND t.uri_template = 'scan-outcome')                    AS has_scan_outcome,
  (SELECT COUNT(*) FROM user_ords_handlers h
   JOIN user_ords_templates t ON t.id = h.template_id
   JOIN user_ords_modules   m ON m.id = t.module_id
   WHERE m.name LIKE 'expenses%' AND t.uri_template = 'mine'
   AND   DBMS_LOB.INSTR(h.source, 'type_totals') > 0)        AS mine_has_type_totals,
  (SELECT COUNT(*) FROM user_ords_handlers h
   WHERE DBMS_LOB.INSTR(LOWER(h.source), 'expense_login_record') > 0)
                                                             AS login_is_rate_limited,
  (SELECT COUNT(*) FROM user_ords_handlers h
   WHERE DBMS_LOB.INSTR(LOWER(h.source), 'send_push_notification') > 0)
                                                             AS handlers_still_push
FROM dual;


--------------------------------------------------------------------------------
-- 6. ** THE ONE THAT PREVENTS A LOCKOUT **
--
-- Prod's current expenses.authenticated pattern list, and its roles.
--
-- The migration's privilege section will be built from THIS list plus the new
-- scan endpoints -- not from dev's. If prod protects a pattern dev does not,
-- rebuilding from dev's list would 401 it.
--------------------------------------------------------------------------------
SELECT p.name AS privilege_name, p.title,
       (SELECT COUNT(*) FROM user_ords_privilege_roles r
        WHERE  r.privilege_id = p.id) AS roles
FROM   user_ords_privileges p
ORDER  BY p.name;

SELECT p.name AS privilege_name, r.role_name
FROM   user_ords_privilege_roles r
JOIN   user_ords_privileges p ON p.id = r.privilege_id
ORDER  BY p.name, r.role_name;

-- The patterns. THIS is the list I need verbatim.
SELECT p.name AS privilege_name, m.pattern
FROM   user_ords_privilege_mappings m
JOIN   user_ords_privileges p ON p.id = m.privilege_id
ORDER  BY p.name, m.pattern;

SELECT role_name FROM user_ords_roles ORDER BY role_name;


--------------------------------------------------------------------------------
-- 7. Scale, so the migration is not written for dev's four rows.
--------------------------------------------------------------------------------
SELECT (SELECT COUNT(*) FROM expenses)                       AS claims,
       (SELECT COUNT(*) FROM expenses WHERE status = 'DRAFT') AS drafts,
       (SELECT COUNT(*) FROM expenses WHERE status = 'SUBMITTED') AS in_flight,
       (SELECT COUNT(*) FROM expense_approvals)              AS approvals,
       (SELECT COUNT(*) FROM expense_items)                  AS bills
FROM   dual;

-- Claims stuck mid-workflow. These are the ones a bad release hurts, and the
-- reason to run the migration when the number is low.
SELECT status, current_stage, COUNT(*) AS n
FROM   expenses
GROUP  BY status, current_stage
ORDER  BY n DESC;


--------------------------------------------------------------------------------
-- 8. Anything of ours already broken here.
--
-- Record it now. If it is invalid before the migration, the migration did not
-- break it -- and an afternoon does not get spent proving that.
--------------------------------------------------------------------------------
SELECT object_name, object_type, status
FROM   user_objects
WHERE  status != 'VALID'
AND   (object_name LIKE '%EXPENSE%' OR object_name IN
       ('APP_SECRETS','SCAN_RECEIPT','HMAC_SHA','JSON_ESCAPE_STR',
        'CONVERT_TO_USD','GET_EXCHANGE_RATE','GET_RATE_EFFECTIVE_DATE',
        'GENERATE_SESSION_TOKEN','IS_VALID_SESSION_TOKEN',
        'GET_OAUTH_ACCESS_TOKEN','IS_ALLOWED_ATTACHMENT',
        'GET_FINANCE_MANAGER_EMPID','GET_PROJECT_MANAGER_EMPID',
        'GET_REVIEWER_ROLE','IS_FINANCE_MANAGER','CAN_VIEW_CLAIM',
        'CAN_EDIT_CLAIM','PRICE_EXPENSE_ITEM','RECALC_CLAIM_TOTALS'))
ORDER  BY object_name;


--------------------------------------------------------------------------------
-- WHAT TO SEND BACK
--
-- All of it. Sections 6 and 2 are the ones that decide anything:
--
--   6  the privilege patterns the migration must preserve
--   2  whether manager approval is broken on production right now
--
-- Nothing has changed on either database.
--------------------------------------------------------------------------------
