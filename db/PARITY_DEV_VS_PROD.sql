--------------------------------------------------------------------------------
-- PARITY_DEV_VS_PROD.sql
--
-- READ-ONLY. Run on DEV and on PROD, put the outputs side by side.
--
-- Answers one question: is prod now the same application as dev? Object counts
-- and endpoint lists are checkable facts; "I think we ran everything" is not.
--
--
-- DIFFERENCES THAT ARE CORRECT AND EXPECTED
-- -----------------------------------------
--   DELETE /expenses/:id     dev only. Script 78 restored it for testing and
--                            deliberately never went to prod.
--   APEX_WORKSPACE           different VALUE on each (that is the point of it
--                            being configuration). Both must have the row.
--   LOGIN_APEX_LOCK_AT       dev only, from script 88. Prod's handler NVLs to
--                            4, which is the observed threshold, so the
--                            countdown works either way -- but see section 5.
--   AI_SERVICE_STATIC_ID     both have the row; prod's VALUE is almost
--                            certainly still script 79's placeholder.
--
-- Anything else that differs is worth explaining before launch.
--------------------------------------------------------------------------------

SET LINESIZE 200
SET PAGESIZE 200

SELECT SYS_CONTEXT('USERENV','CURRENT_SCHEMA') AS schema_name,
       CASE SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
            WHEN 'HRMS' THEN 'dev' WHEN 'REPO' THEN 'PROD' ELSE '?' END AS env
FROM   dual;


--------------------------------------------------------------------------------
-- 1. Object counts. Expect identical numbers on both.
--------------------------------------------------------------------------------
SELECT object_type, COUNT(*) AS n
FROM   user_objects
WHERE  object_name LIKE 'XXKS\_EXP\_%' ESCAPE '\'
GROUP  BY object_type ORDER BY object_type;

-- And the names, so a mismatch says WHICH object rather than just a number.
SELECT object_name, object_type FROM user_objects
WHERE  object_name LIKE 'XXKS\_EXP\_%' ESCAPE '\'
ORDER  BY object_type, object_name;


--------------------------------------------------------------------------------
-- 2. Nothing left under an old name, nothing broken.
--    Both queries: zero rows on both environments.
--------------------------------------------------------------------------------
SELECT object_name, object_type FROM user_objects
WHERE  object_name IN ('EXPENSES','EXPENSE_ITEMS','EXPENSE_APPROVALS','APP_SECRETS',
                       'EXPENSE_MAIL_LOG','EXPENSE_SCAN_LOG','EXPENSE_LOGIN_ATTEMPTS',
                       'SCAN_RECEIPT','EXPENSE_LOGIN_RECORD','EXPENSE_LOGIN_RETRY_AFTER',
                       'SEND_PUSH_NOTIFICATION','TEST_PUSH_NOTIFICATION','EMP_PUSH_TOKENS',
                       'PROCESS_EXPENSE_ACTION','SEND_EXPENSE_MAIL','CAN_VIEW_CLAIM',
                       'CAN_EDIT_CLAIM','IS_FINANCE_MANAGER','IS_VALID_SESSION_TOKEN');

SELECT object_name, object_type, status FROM user_objects
WHERE  object_name LIKE 'XXKS\_EXP\_%' ESCAPE '\' AND status != 'VALID';


--------------------------------------------------------------------------------
-- 3. Endpoints. The list must match except for DELETE :id, which is dev only.
--------------------------------------------------------------------------------
SELECT t.uri_template, NVL(h.method,'** NO HANDLER **') AS method
FROM   user_ords_templates t
JOIN   user_ords_modules   m ON m.id = t.module_id
LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
WHERE  m.name LIKE 'expenses%'
ORDER  BY t.uri_template, h.method;

-- Feature flags, read from the deployed handlers rather than from the repo.
-- Expect 1 / 1 / 1 / 0 / 0 on both.
SELECT
  (SELECT COUNT(*) FROM user_ords_handlers h
   JOIN user_ords_templates t ON t.id=h.template_id
   JOIN user_ords_modules m ON m.id=t.module_id
   WHERE m.name LIKE 'expenses%' AND t.uri_template='mine'
   AND   DBMS_LOB.INSTR(h.source,'type_totals')>0)              AS mine_type_totals,
  (SELECT COUNT(*) FROM user_ords_handlers h
   JOIN user_ords_templates t ON t.id=h.template_id
   JOIN user_ords_modules m ON m.id=t.module_id
   WHERE m.name LIKE 'expenses%' AND t.uri_template=':id/submit'
   AND   DBMS_LOB.INSTR(h.source,'l_manager_id, l_finance_id, SYSTIMESTAMP')>0)
                                                                AS submit_has_62_fix,
  (SELECT COUNT(*) FROM user_ords_handlers h
   JOIN user_ords_templates t ON t.id=h.template_id
   JOIN user_ords_modules m ON m.id=t.module_id
   WHERE m.name LIKE 'expenses%' AND t.uri_template='auth/login'
   AND   DBMS_LOB.INSTR(h.source,'account_locked')>0)           AS login_says_locked,
  (SELECT COUNT(*) FROM user_ords_handlers
   WHERE DBMS_LOB.INSTR(LOWER(source),'send_push_notification')>0) AS still_pushes,
  (SELECT COUNT(*) FROM user_ords_handlers
   WHERE DBMS_LOB.INSTR(LOWER(source),'login_retry_after')>0)   AS still_throttles
FROM dual;


--------------------------------------------------------------------------------
-- 4. Schema shape: who columns, and no legacy columns.
--    Expect 4 for every table on both, and legacy_cols 0.
--------------------------------------------------------------------------------
SELECT t.table_name,
       (SELECT COUNT(*) FROM user_tab_columns c
        WHERE  c.table_name = t.table_name
        AND    c.column_name IN ('CREATED_BY','CREATION_DATE',
                                 'LAST_UPDATED_BY','LAST_UPDATE_DATE')) AS who_cols,
       (SELECT COUNT(*) FROM user_triggers g WHERE g.table_name = t.table_name) AS trgs
FROM   user_tables t
WHERE  t.table_name LIKE 'XXKS\_EXP\_%' ESCAPE '\'
ORDER  BY t.table_name;

SELECT COUNT(*) AS legacy_cols FROM user_tab_columns
WHERE  table_name = 'XXKS_EXP_CLAIMS'
AND    column_name IN ('BILL_NO','BILL_DATE','TYPE','DESCRIPTION','ATTACHMENT_BLOB',
                       'ATTACHMENT_FILENAME','ATTACHMENT_MIME_TYPE','ATTACHMENT_PATH');


--------------------------------------------------------------------------------
-- 5. Configuration. NAMES only -- no values.
--
-- Both must have APEX_WORKSPACE (different values). If prod lacks
-- LOGIN_APEX_LOCK_AT the handler defaults to 4, which matches the observed
-- threshold, so the countdown is right -- add it only if prod's APEX workspace
-- is configured differently.
--------------------------------------------------------------------------------
SELECT secret_name,
       CASE WHEN secret_value IS NULL THEN 'NULL'
            ELSE 'set (' || LENGTH(secret_value) || ' chars)' END AS value_state
FROM   xxks_exp_secrets ORDER BY secret_name;


--------------------------------------------------------------------------------
-- 6. Privileges. Expect 18 authenticated patterns and 4 review on both, and
--    auth/login covered by NEITHER.
--------------------------------------------------------------------------------
SELECT p.name, COUNT(*) AS patterns
FROM   user_ords_privilege_mappings m
JOIN   user_ords_privileges p ON p.id = m.privilege_id
WHERE  p.name LIKE 'expenses%'
GROUP  BY p.name ORDER BY p.name;

SELECT p.name, m.pattern
FROM   user_ords_privilege_mappings m
JOIN   user_ords_privileges p ON p.id = m.privilege_id
WHERE  p.name LIKE 'expenses%'
ORDER  BY p.name, m.pattern;
-- auth/login must not appear. If it does, nobody can sign in.


--------------------------------------------------------------------------------
-- 7. What the two databases hold. Not a parity check -- just so the numbers
--    are on the record before launch.
--------------------------------------------------------------------------------
SELECT (SELECT COUNT(*) FROM xxks_exp_claims)     AS claims,
       (SELECT COUNT(*) FROM xxks_exp_items)      AS bills,
       (SELECT COUNT(*) FROM xxks_exp_approvals)  AS approvals,
       (SELECT COUNT(*) FROM xxks_exp_mail_log)   AS mails,
       (SELECT COUNT(*) FROM xxks_exp_scan_log)   AS scans
FROM   dual;
