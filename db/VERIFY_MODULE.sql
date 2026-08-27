--------------------------------------------------------------------------------
-- VERIFY_MODULE.sql
--
-- READ-ONLY. Changes nothing. Run as the APPLICATION SCHEMA, in SQL Scripts.
--
-- THE post-change check for the ORDS layer. Run this after ANY script that
-- touches handlers, templates or privileges -- 71 through 77 all should have
-- ended with it.
--
--
-- WHY THIS FILE EXISTS
-- --------------------
-- Every fault in the August 2026 sequence was in the ORDS metadata, and every
-- one of them arrived disguised as something else:
--
--   403 on Home and Approvals    handlers selecting dropped columns   (71)
--   555 on the conversion rate   the template did not exist           (72)
--   empty project dropdown       the template had no handler          (73)
--   ORA-01843 to the user        one-format date parsing              (75)
--   "Set when you submit"        the data was never sent              (76)
--   0 handlers on :id/attachment ORDS.DELETE_TEMPLATE does not exist  (77)
--
-- None of them were privilege problems, which is what they all looked like.
--
-- I got the check itself wrong three times before this version:
--
--   * flagged a comment inside a handler body as a fault
--   * wrote 'attachment_blob' unqualified, so every legitimate reference to
--     EXPENSE_ITEMS.ATTACHMENT_BLOB came back as broken
--   * tried to slice each CLOB into readable lines, and the query returned
--     nothing at all -- which looks exactly like a pass
--
-- The last one is the worst failure mode, so section 2 is now the dullest thing
-- that works: DBMS_LOB.INSTR against fully-qualified column names.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF
SET LINESIZE 200


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
