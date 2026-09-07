--------------------------------------------------------------------------------
-- 85_rename_to_xxks_exp.sql
--
-- Run as the APPLICATION SCHEMA, in SQL SCRIPTS. Idempotent.
-- Run AFTER 84_drop_push.sql. Run 86_rename_handlers.sql IMMEDIATELY AFTER.
--
--   dev  = karyasiddhitest.trinamix.com, schema HRMS
--   prod = karyasiddhi.trinamix.com,     schema REPO
--
--
-- ** BETWEEN THIS SCRIPT AND 86 THE API IS DOWN **
--
-- Renaming the tables leaves every ORDS handler pointing at objects that no
-- longer exist. An ORDS handler referencing a missing object returns a BARE 403
-- WITH NO BODY -- the failure that cost two days on this project -- and after
-- this script that will be true of roughly thirty endpoints at once. 86 fixes
-- them. Run the two back to back, not on different days.
--
--
-- WHAT GETS RENAMED, AND WHAT EMPHATICALLY DOES NOT
-- -------------------------------------------------
-- Only objects this project created. HRMS is shared: it holds the company HR
-- tables, an RPA system, a ticketing system, and a large existing XXKS_ estate
-- (XXKS_RPA_*, XXKS_TKT_*, XXKS_POC_*, XXKS_PNL, ...). Nothing there is ours.
--
-- Never touched:
--   EMPLOYEEDETAILS  PROJECTMASTER  PROJECT_ALLOCATION_WB  CURRENCY_CONVERSION
--   PROJECT_MANAGER  ENGAGEMENT_MANAGER  INVOICE_APPROVER
--   every existing XXKS_* object
--   TRG_COPY_PM_TO_EXPENSE, TRG_PM_SYNC_TO_EXPENSE, TRG_PROJECTMASTER_EXPENSE
--     -- named "...EXPENSE" but they are the HR system's Travel-project
--     -- automation on PROJECTMASTER and PROJECT_MANAGER. They never read or
--     -- write our EXPENSES table. Confirmed by reading their bodies.
--   EMP_EXPENSE_REQUEST
--     -- matched the %EXPENSE% sweep, 0 rows, created 01-Aug, and appears
--     -- nowhere in this repo. Not demonstrably ours, so left alone.
--
-- XXKS_EXP_ is free: no existing object starts with it. XXKS_EXTRACT_CHILD_LINKS
-- and XXKS_RPA_EXPORT_* are near misses that do not collide.
--
--
-- WHY THE SUBPROGRAMS ARE REBUILT FROM user_source
-- ------------------------------------------------
-- Oracle can RENAME a table, a view, a sequence or a synonym. It CANNOT rename
-- a procedure, function, package or trigger body -- there is no such statement.
-- Those have to be created afresh under the new name and the old ones dropped.
--
-- The new source is generated from USER_SOURCE, not from this repo. That is
-- deliberate. The repo has been wrong about this schema three times -- most
-- recently CK_APPROVALS_ROLE, whose correct definition sat in PROD_1_schema.sql
-- having never been applied, while manager approval failed for weeks. Reading
-- the database means what gets rebuilt is what is actually running, including
-- any change made outside these scripts.
--
--
-- WORD BOUNDARIES MATTER MORE THAN THEY LOOK
-- ------------------------------------------
-- A plain REPLACE of 'EXPENSES' would corrupt EXPENSES_PRE_MULTIBILL,
-- EXPENSE_ITEMS and the column EXPENSE_ID. Every substitution below is bounded
-- by [^A-Za-z0-9_] on each side, so a name only matches as a whole identifier.
-- Underscore is inside the class on purpose: without it, EXPENSE_ITEMS would
-- match the EXPENSE prefix of EXPENSE_APPROVALS.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF
SET LINESIZE 200


--------------------------------------------------------------------------------
-- 0. Refuse to run in the wrong state.
--------------------------------------------------------------------------------
DECLARE
  l_push NUMBER;
  l_new  NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('schema: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));

  SELECT COUNT(*) INTO l_push FROM user_objects
  WHERE  object_name IN ('SEND_PUSH_NOTIFICATION','TEST_PUSH_NOTIFICATION',
                         'EMP_PUSH_TOKENS');
  IF l_push > 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'Push objects still exist -- run 84_drop_push.sql first and check its '
      || 'section 6. Renaming around them would just carry them forward.');
  END IF;

  -- ESCAPE matters: in LIKE, _ is a single-character wildcard, so 'XXKS_EXP%'
  -- would also match XXKSAEXP-anything. Unlikely here, and still wrong.
  SELECT COUNT(*) INTO l_new FROM user_objects
  WHERE  object_name LIKE 'XXKS\_EXP\_%' ESCAPE '\';
  DBMS_OUTPUT.PUT_LINE('objects already named XXKS_EXP_* : ' || l_new
                       || '  (0 on a first run; re-runs are fine)');
END;
/


--------------------------------------------------------------------------------
-- 1. Tables.
--
-- RENAME preserves the data, the indexes, the constraints, the triggers, the
-- grants and the row ids. It does not preserve anything that NAMES the table:
-- PL/SQL and ORDS handlers go invalid, which is what sections 5 and script 86
-- are for.
--
-- EXPENSES becomes XXKS_EXP_CLAIMS rather than XXKS_EXP_EXPENSES: the header
-- and line pair reads as CLAIMS and ITEMS, and every comment and variable in
-- this codebase already calls the header a claim.
--------------------------------------------------------------------------------
DECLARE
  TYPE t_map IS TABLE OF VARCHAR2(128) INDEX BY VARCHAR2(128);
  l_map t_map;
  l_old VARCHAR2(128);
  l_n   NUMBER;
BEGIN
  l_map('EXPENSES')                        := 'XXKS_EXP_CLAIMS';
  l_map('EXPENSE_ITEMS')                   := 'XXKS_EXP_ITEMS';
  l_map('EXPENSE_APPROVALS')               := 'XXKS_EXP_APPROVALS';
  l_map('EXPENSE_MAIL_LOG')                := 'XXKS_EXP_MAIL_LOG';
  l_map('EXPENSE_SCAN_LOG')                := 'XXKS_EXP_SCAN_LOG';
  l_map('EXPENSE_LOGIN_ATTEMPTS')          := 'XXKS_EXP_LOGIN_ATTEMPTS';
  l_map('APP_SECRETS')                     := 'XXKS_EXP_SECRETS';
  -- The two pre-multi-bill backups from script 64. Renamed rather than
  -- dropped -- they are the only copy of the old shape and nobody has said
  -- they are finished with. The _BKP suffix says what they are, so they stop
  -- looking like live tables in a schema listing.
  l_map('EXPENSES_PRE_MULTIBILL')          := 'XXKS_EXP_CLAIMS_BKP';
  l_map('EXPENSE_APPROVALS_PRE_MULTIBILL') := 'XXKS_EXP_APPROVALS_BKP';

  l_old := l_map.FIRST;
  WHILE l_old IS NOT NULL LOOP
    SELECT COUNT(*) INTO l_n FROM user_tables WHERE table_name = l_old;
    IF l_n = 1 THEN
      EXECUTE IMMEDIATE 'ALTER TABLE "' || l_old || '" RENAME TO "' || l_map(l_old) || '"';
      DBMS_OUTPUT.PUT_LINE(RPAD(l_old, 34) || ' -> ' || l_map(l_old));
    ELSE
      SELECT COUNT(*) INTO l_n FROM user_tables WHERE table_name = l_map(l_old);
      DBMS_OUTPUT.PUT_LINE(RPAD(l_old, 34) || ' -- '
        || CASE WHEN l_n = 1 THEN 'already renamed' ELSE '** NOT FOUND **' END);
    END IF;
    l_old := l_map.NEXT(l_old);
  END LOOP;
END;
/


--------------------------------------------------------------------------------
-- 2. Indexes.
--
-- EBS convention: _N<n> non-unique, _U<n> unique, _PK for the primary key's.
-- SYS_C%/SYS_IL% are skipped: the first are the system names behind primary and
-- unique CONSTRAINTS (renamed with the constraint in section 3, which carries
-- its index with it), and SYS_IL% are LOB indexes, which cannot be renamed and
-- do not need to be.
--------------------------------------------------------------------------------
DECLARE
  TYPE t_map IS TABLE OF VARCHAR2(128) INDEX BY VARCHAR2(128);
  l_map t_map;
  l_old VARCHAR2(128);
  l_n   NUMBER;
BEGIN
  l_map('IX_EXPENSES_EMP')           := 'XXKS_EXP_CLAIMS_N1';
  l_map('IX_EXPENSES_STATUS_STAGE')  := 'XXKS_EXP_CLAIMS_N2';
  l_map('EXPENSES_CLIENT_REQ_UQ')    := 'XXKS_EXP_CLAIMS_U1';
  l_map('EXPENSE_ITEMS_NO_UQ')       := 'XXKS_EXP_ITEMS_U1';
  l_map('IX_APPROVALS_EXPENSE')      := 'XXKS_EXP_APPROVALS_N1';
  l_map('IX_MAIL_LOG_EXPENSE')       := 'XXKS_EXP_MAIL_LOG_N1';
  l_map('IX_SCAN_LOG_EMP')           := 'XXKS_EXP_SCAN_LOG_N1';
  l_map('IX_EXPENSE_LOGIN_ATTEMPTS') := 'XXKS_EXP_LOGIN_ATTEMPTS_N1';

  l_old := l_map.FIRST;
  WHILE l_old IS NOT NULL LOOP
    SELECT COUNT(*) INTO l_n FROM user_indexes WHERE index_name = l_old;
    IF l_n = 1 THEN
      EXECUTE IMMEDIATE 'ALTER INDEX "' || l_old || '" RENAME TO "' || l_map(l_old) || '"';
      DBMS_OUTPUT.PUT_LINE(RPAD(l_old, 30) || ' -> ' || l_map(l_old));
    ELSE
      DBMS_OUTPUT.PUT_LINE(RPAD(l_old, 30) || ' -- not present');
    END IF;
    l_old := l_map.NEXT(l_old);
  END LOOP;
END;
/


--------------------------------------------------------------------------------
-- 3. Constraints.
--
-- Named ones only. The SYS_C00... entries are NOT NULL checks -- there are 40+
-- of them, Oracle generated the names, and renaming them buys nothing.
--
-- CK_APPROVALS_ROLE is included and is the one to watch: script 81 had to drop
-- and recreate it because it did not allow PROJECT_MANAGER, and every manager
-- approval failed until it did. A RENAME does not alter the condition, so the
-- fix survives -- section 6 checks that rather than assuming it.
--------------------------------------------------------------------------------
DECLARE
  TYPE t_row IS RECORD (tab VARCHAR2(128), new_name VARCHAR2(128));
  TYPE t_map IS TABLE OF t_row INDEX BY VARCHAR2(128);
  l_map t_map;
  l_old VARCHAR2(128);
  l_n   NUMBER;
  PROCEDURE add(p_old VARCHAR2, p_tab VARCHAR2, p_new VARCHAR2) IS
  BEGIN
    l_map(p_old).tab := p_tab; l_map(p_old).new_name := p_new;
  END;
BEGIN
  add('CK_EXPENSES_AMOUNT',      'XXKS_EXP_CLAIMS',    'XXKS_EXP_CLAIMS_CK_AMOUNT');
  add('CK_EXPENSES_DATES',       'XXKS_EXP_CLAIMS',    'XXKS_EXP_CLAIMS_CK_DATES');
  add('CK_EXPENSES_STAGE',       'XXKS_EXP_CLAIMS',    'XXKS_EXP_CLAIMS_CK_STAGE');
  add('CK_EXPENSES_STATUS',      'XXKS_EXP_CLAIMS',    'XXKS_EXP_CLAIMS_CK_STATUS');
  add('FK_EXPENSES_EMP',         'XXKS_EXP_CLAIMS',    'XXKS_EXP_CLAIMS_FK1');
  add('FK_EXPENSES_MANAGER',     'XXKS_EXP_CLAIMS',    'XXKS_EXP_CLAIMS_FK2');
  add('FK_EXPENSES_SUBMITTED_BY','XXKS_EXP_CLAIMS',    'XXKS_EXP_CLAIMS_FK3');
  add('CK_ITEMS_AMOUNT',         'XXKS_EXP_ITEMS',     'XXKS_EXP_ITEMS_CK_AMOUNT');
  add('CK_ITEMS_DATES',          'XXKS_EXP_ITEMS',     'XXKS_EXP_ITEMS_CK_DATES');
  add('CK_ITEMS_ITEMNO',         'XXKS_EXP_ITEMS',     'XXKS_EXP_ITEMS_CK_ITEMNO');
  add('EXPENSE_ITEMS_NO_UQ',     'XXKS_EXP_ITEMS',     'XXKS_EXP_ITEMS_U1');
  add('FK_ITEMS_EXPENSE',        'XXKS_EXP_ITEMS',     'XXKS_EXP_ITEMS_FK1');
  add('CK_APPROVALS_ACTION',     'XXKS_EXP_APPROVALS', 'XXKS_EXP_APPROVALS_CK_ACTION');
  add('CK_APPROVALS_ROLE',       'XXKS_EXP_APPROVALS', 'XXKS_EXP_APPROVALS_CK_ROLE');
  add('FK_APPROVALS_APPROVER',   'XXKS_EXP_APPROVALS', 'XXKS_EXP_APPROVALS_FK1');
  add('FK_APPROVALS_EXPENSE',    'XXKS_EXP_APPROVALS', 'XXKS_EXP_APPROVALS_FK2');
  add('CK_EXP_LOGIN_OUTCOME',    'XXKS_EXP_LOGIN_ATTEMPTS',
                                 'XXKS_EXP_LOGIN_ATTEMPTS_CK_OUTCOME');

  l_old := l_map.FIRST;
  WHILE l_old IS NOT NULL LOOP
    SELECT COUNT(*) INTO l_n FROM user_constraints WHERE constraint_name = l_old;
    IF l_n = 1 THEN
      EXECUTE IMMEDIATE 'ALTER TABLE "' || l_map(l_old).tab
                     || '" RENAME CONSTRAINT "' || l_old
                     || '" TO "' || l_map(l_old).new_name || '"';
      DBMS_OUTPUT.PUT_LINE(RPAD(l_old, 30) || ' -> ' || l_map(l_old).new_name);
    ELSE
      DBMS_OUTPUT.PUT_LINE(RPAD(l_old, 30) || ' -- not present');
    END IF;
    l_old := l_map.NEXT(l_old);
  END LOOP;
END;
/


--------------------------------------------------------------------------------
-- 4. Triggers.
--
-- ALTER TRIGGER ... RENAME TO works and keeps the body, so unlike procedures
-- these do not need rebuilding. Only the two that sit on OUR tables.
--------------------------------------------------------------------------------
DECLARE
  TYPE t_map IS TABLE OF VARCHAR2(128) INDEX BY VARCHAR2(128);
  l_map t_map;
  l_old VARCHAR2(128);
  l_n   NUMBER;
BEGIN
  l_map('TRG_EXPENSES_AUDIT')  := 'XXKS_EXP_CLAIMS_T1';
  l_map('TRG_APPROVALS_AUDIT') := 'XXKS_EXP_APPROVALS_T1';

  l_old := l_map.FIRST;
  WHILE l_old IS NOT NULL LOOP
    SELECT COUNT(*) INTO l_n FROM user_triggers WHERE trigger_name = l_old;
    IF l_n = 1 THEN
      EXECUTE IMMEDIATE 'ALTER TRIGGER "' || l_old || '" RENAME TO "' || l_map(l_old) || '"';
      DBMS_OUTPUT.PUT_LINE(RPAD(l_old, 26) || ' -> ' || l_map(l_old));
    ELSE
      DBMS_OUTPUT.PUT_LINE(RPAD(l_old, 26) || ' -- not present');
    END IF;
    l_old := l_map.NEXT(l_old);
  END LOOP;
END;
/


--------------------------------------------------------------------------------
-- 5. Procedures and functions -- rebuilt, because they cannot be renamed.
--
-- For each one: read its live source, substitute every renamed identifier
-- (its own name included), CREATE OR REPLACE under the new name, then drop the
-- old.
--
-- The old one is dropped only after the new one exists. If a create fails, the
-- old is left in place and the run stops -- a half-renamed schema with the old
-- copy still working is recoverable; one with neither is not.
--
-- Cross-references resolve themselves. XXKS_EXP_PROCESS_ACTION is created
-- before XXKS_EXP_SEND_MAIL exists, so it compiles INVALID; Oracle revalidates
-- it on first call, and section 7 recompiles everything anyway.
--------------------------------------------------------------------------------
DECLARE
  TYPE t_map IS TABLE OF VARCHAR2(128) INDEX BY VARCHAR2(128);
  l_map  t_map;   -- every rename, tables included: the bodies reference both
  l_subs t_map;   -- just the subprograms, i.e. what to create and drop
  l_old  VARCHAR2(128);
  l_src  CLOB;
  l_n    NUMBER;
  l_kind VARCHAR2(30);

  -- Whole-identifier substitution. Oracle regex has no \b, so the token is
  -- matched with an explicit non-identifier character on each side and those
  -- characters are put back via \1 and \2. The source is padded with newlines
  -- so a name at the very start or end still has a boundary.
  --
  -- Applied twice: two renameable identifiers separated by a single character
  -- (as in "expenses e JOIN expense_items") share that character, and the
  -- first pass consumes it, so the second name is missed on pass one.
  FUNCTION swap(p_src CLOB, p_from VARCHAR2, p_to VARCHAR2) RETURN CLOB IS
    l_out CLOB := p_src;
  BEGIN
    FOR i IN 1 .. 2 LOOP
      l_out := REGEXP_REPLACE(l_out,
                 '([^A-Za-z0-9_])' || p_from || '([^A-Za-z0-9_])',
                 '\1' || p_to || '\2', 1, 0, 'i');
    END LOOP;
    RETURN l_out;
  END;
BEGIN
  ------------------------------------------------------------------ tables
  l_map('EXPENSES')                        := 'XXKS_EXP_CLAIMS';
  l_map('EXPENSE_ITEMS')                   := 'XXKS_EXP_ITEMS';
  l_map('EXPENSE_APPROVALS')               := 'XXKS_EXP_APPROVALS';
  l_map('EXPENSE_MAIL_LOG')                := 'XXKS_EXP_MAIL_LOG';
  l_map('EXPENSE_SCAN_LOG')                := 'XXKS_EXP_SCAN_LOG';
  l_map('EXPENSE_LOGIN_ATTEMPTS')          := 'XXKS_EXP_LOGIN_ATTEMPTS';
  l_map('APP_SECRETS')                     := 'XXKS_EXP_SECRETS';
  l_map('EXPENSES_PRE_MULTIBILL')          := 'XXKS_EXP_CLAIMS_BKP';
  l_map('EXPENSE_APPROVALS_PRE_MULTIBILL') := 'XXKS_EXP_APPROVALS_BKP';

  ------------------------------------------------------------ subprograms
  l_subs('PROCESS_EXPENSE_ACTION')     := 'XXKS_EXP_PROCESS_ACTION';
  l_subs('SEND_EXPENSE_MAIL')          := 'XXKS_EXP_SEND_MAIL';
  l_subs('RECALC_CLAIM_TOTALS')        := 'XXKS_EXP_RECALC_CLAIM_TOTALS';
  l_subs('PRICE_EXPENSE_ITEM')         := 'XXKS_EXP_PRICE_ITEM';
  l_subs('SCAN_RECEIPT')               := 'XXKS_EXP_SCAN_RECEIPT';
  l_subs('EXPENSE_LOGIN_RECORD')       := 'XXKS_EXP_LOGIN_RECORD';
  l_subs('EXPENSE_LOGIN_RETRY_AFTER')  := 'XXKS_EXP_LOGIN_RETRY_AFTER';
  l_subs('GET_OAUTH_ACCESS_TOKEN')     := 'XXKS_EXP_GET_OAUTH_ACCESS_TOKEN';
  l_subs('GENERATE_SESSION_TOKEN')     := 'XXKS_EXP_GENERATE_SESSION_TOKEN';
  l_subs('IS_VALID_SESSION_TOKEN')     := 'XXKS_EXP_IS_VALID_SESSION_TOKEN';
  l_subs('HMAC_SHA')                   := 'XXKS_EXP_HMAC_SHA';
  l_subs('JSON_ESCAPE_STR')            := 'XXKS_EXP_JSON_ESCAPE_STR';
  l_subs('IS_ALLOWED_ATTACHMENT')      := 'XXKS_EXP_IS_ALLOWED_ATTACHMENT';
  l_subs('CONVERT_TO_USD')             := 'XXKS_EXP_CONVERT_TO_USD';
  l_subs('GET_EXCHANGE_RATE')          := 'XXKS_EXP_GET_EXCHANGE_RATE';
  l_subs('GET_RATE_EFFECTIVE_DATE')    := 'XXKS_EXP_GET_RATE_EFFECTIVE_DATE';
  l_subs('GET_FINANCE_MANAGER_EMPID')  := 'XXKS_EXP_GET_FINANCE_MGR_EMPID';
  l_subs('GET_PROJECT_MANAGER_EMPID')  := 'XXKS_EXP_GET_PROJECT_MGR_EMPID';
  l_subs('GET_REVIEWER_ROLE')          := 'XXKS_EXP_GET_REVIEWER_ROLE';
  l_subs('IS_FINANCE_MANAGER')         := 'XXKS_EXP_IS_FINANCE_MANAGER';
  l_subs('CAN_VIEW_CLAIM')             := 'XXKS_EXP_CAN_VIEW_CLAIM';
  l_subs('CAN_EDIT_CLAIM')             := 'XXKS_EXP_CAN_EDIT_CLAIM';

  -- the subprogram names are renamed inside bodies too
  l_old := l_subs.FIRST;
  WHILE l_old IS NOT NULL LOOP
    l_map(l_old) := l_subs(l_old);
    l_old := l_subs.NEXT(l_old);
  END LOOP;

  ------------------------------------------------------------------- work
  l_old := l_subs.FIRST;
  WHILE l_old IS NOT NULL LOOP
    SELECT COUNT(*) INTO l_n FROM user_objects
    WHERE  object_name = l_old AND object_type IN ('PROCEDURE','FUNCTION');

    IF l_n = 0 THEN
      DBMS_OUTPUT.PUT_LINE(RPAD(l_old, 30) || ' -- not present (already done?)');
    ELSE
      SELECT object_type INTO l_kind FROM user_objects
      WHERE  object_name = l_old AND object_type IN ('PROCEDURE','FUNCTION');

      -- USER_SOURCE holds the body WITHOUT "CREATE OR REPLACE", starting at
      -- "PROCEDURE x(" / "FUNCTION x(".
      --
      -- Assembled with DBMS_LOB, NOT with LISTAGG. LISTAGG returns a VARCHAR2
      -- and dies at 4000 bytes with ORA-01489; send_expense_mail alone is over
      -- 700 lines. The first draft of this script used LISTAGG and could not
      -- have worked on a single one of these objects.
      DBMS_LOB.CREATETEMPORARY(l_src, TRUE);
      DBMS_LOB.WRITEAPPEND(l_src, 1, CHR(10));   -- leading boundary for swap()
      FOR r IN (SELECT text FROM user_source
                WHERE  name = l_old AND type = l_kind
                ORDER  BY line)
      LOOP
        -- A blank source line arrives as NULL, and LENGTH(NULL) would make
        -- WRITEAPPEND raise. Skip it; the newline is already in the previous
        -- line's text.
        IF r.text IS NOT NULL AND LENGTH(r.text) > 0 THEN
          DBMS_LOB.WRITEAPPEND(l_src, LENGTH(r.text), r.text);
        END IF;
      END LOOP;
      DBMS_LOB.WRITEAPPEND(l_src, 1, CHR(10));   -- trailing boundary

      DECLARE
        l_key VARCHAR2(128) := l_map.FIRST;
      BEGIN
        WHILE l_key IS NOT NULL LOOP
          l_src := swap(l_src, l_key, l_map(l_key));
          l_key := l_map.NEXT(l_key);
        END LOOP;
      END;

      -- ORA-24344 is "success with compilation error": the object IS created,
      -- just INVALID. Left alone that would drop a working old copy and keep a
      -- broken new one, so it is caught, named, and the run stops with the old
      -- object still in place.
      BEGIN
        EXECUTE IMMEDIATE 'CREATE OR REPLACE ' || l_src;
      EXCEPTION
        WHEN OTHERS THEN
          DBMS_LOB.FREETEMPORARY(l_src);
          RAISE_APPLICATION_ERROR(-20010,
            'Creating ' || l_subs(l_old) || ' from ' || l_old || ' failed: '
            || SQLERRM || ' -- the old object is untouched. Look at '
            || 'user_errors for ' || l_subs(l_old) || ' before re-running.');
      END;

      DBMS_LOB.FREETEMPORARY(l_src);
      EXECUTE IMMEDIATE 'DROP ' || l_kind || ' "' || l_old || '"';
      DBMS_OUTPUT.PUT_LINE(RPAD(l_old, 30) || ' -> ' || l_subs(l_old)
                           || '  (' || LOWER(l_kind) || ')');
    END IF;

    l_old := l_subs.NEXT(l_old);
  END LOOP;
END;
/


--------------------------------------------------------------------------------
-- 6. Verify the structure. The API is still down at this point -- that is
--    expected, and 86 is what fixes it.
--------------------------------------------------------------------------------

-- a) The new estate. Expect 9 tables, 8 indexes, 2 triggers, 22 subprograms.
SELECT object_type, COUNT(*) AS n
FROM   user_objects
WHERE  object_name LIKE 'XXKS\_EXP\_%' ESCAPE '\'
GROUP  BY object_type ORDER BY object_type;

-- b) Nothing under an old name. Expect zero rows.
SELECT object_name, object_type FROM user_objects
WHERE  object_name IN ('EXPENSES','EXPENSE_ITEMS','EXPENSE_APPROVALS',
                       'EXPENSE_MAIL_LOG','EXPENSE_SCAN_LOG','APP_SECRETS',
                       'EXPENSE_LOGIN_ATTEMPTS','EXPENSES_PRE_MULTIBILL',
                       'EXPENSE_APPROVALS_PRE_MULTIBILL',
                       'PROCESS_EXPENSE_ACTION','SEND_EXPENSE_MAIL',
                       'RECALC_CLAIM_TOTALS','PRICE_EXPENSE_ITEM','SCAN_RECEIPT',
                       'EXPENSE_LOGIN_RECORD','EXPENSE_LOGIN_RETRY_AFTER',
                       'GET_OAUTH_ACCESS_TOKEN','GENERATE_SESSION_TOKEN',
                       'IS_VALID_SESSION_TOKEN','HMAC_SHA','JSON_ESCAPE_STR',
                       'IS_ALLOWED_ATTACHMENT','CONVERT_TO_USD',
                       'GET_EXCHANGE_RATE','GET_RATE_EFFECTIVE_DATE',
                       'GET_FINANCE_MANAGER_EMPID','GET_PROJECT_MANAGER_EMPID',
                       'GET_REVIEWER_ROLE','IS_FINANCE_MANAGER',
                       'CAN_VIEW_CLAIM','CAN_EDIT_CLAIM');

-- c) The row counts must be identical to section 2 of script 83. A rename does
--    not move data, so any difference means something other than a rename
--    happened.
SELECT 'XXKS_EXP_CLAIMS' t, COUNT(*) n FROM xxks_exp_claims UNION ALL
SELECT 'XXKS_EXP_ITEMS',       COUNT(*) FROM xxks_exp_items UNION ALL
SELECT 'XXKS_EXP_APPROVALS',   COUNT(*) FROM xxks_exp_approvals UNION ALL
SELECT 'XXKS_EXP_MAIL_LOG',    COUNT(*) FROM xxks_exp_mail_log UNION ALL
SELECT 'XXKS_EXP_SCAN_LOG',    COUNT(*) FROM xxks_exp_scan_log UNION ALL
SELECT 'XXKS_EXP_LOGIN_ATTEMPTS', COUNT(*) FROM xxks_exp_login_attempts UNION ALL
SELECT 'XXKS_EXP_SECRETS',     COUNT(*) FROM xxks_exp_secrets;
-- Expect 4, 6, 9, 15, 27, 3, 10.

-- d) Script 81's fix survived the rename. The condition must still name both
--    roles -- if it does not, manager approval is broken again.
SELECT constraint_name, status, validated, search_condition_vc
FROM   user_constraints
WHERE  constraint_name = 'XXKS_EXP_APPROVALS_CK_ROLE';

-- e) Compile errors from the rebuild. Expect zero rows.
SELECT name, type, line, position, text FROM user_errors
WHERE  name LIKE 'XXKS\_EXP\_%' ESCAPE '\'
ORDER  BY name, line, position;

-- f) No rebuilt body may still mention an old name. Expect zero rows. This is
--    the check that catches a substitution the regex missed.
SELECT DISTINCT name, type FROM user_source
WHERE  name LIKE 'XXKS\_EXP\_%' ESCAPE '\'
AND   (REGEXP_LIKE(text, '[^A-Za-z0-9_](expenses|expense_items|expense_approvals'
                      || '|expense_mail_log|expense_scan_log|app_secrets'
                      || '|expense_login_attempts)[^A-Za-z0-9_]', 'i')
    OR REGEXP_LIKE(text, '[^A-Za-z0-9_](process_expense_action|send_expense_mail'
                      || '|get_reviewer_role|is_valid_session_token'
                      || '|get_project_manager_empid|get_finance_manager_empid'
                      || '|price_expense_item|recalc_claim_totals'
                      || '|convert_to_usd|get_exchange_rate)[^A-Za-z0-9_]', 'i'));


--------------------------------------------------------------------------------
-- 7. Recompile ours, and only ours.
--
-- DBMS_UTILITY.COMPILE_SCHEMA would touch the ~190 invalid objects belonging to
-- the RPA and ticketing systems. Not ours, not our decision.
--------------------------------------------------------------------------------
BEGIN
  FOR o IN (SELECT object_name, object_type FROM user_objects
            WHERE  object_name LIKE 'XXKS\_EXP\_%' ESCAPE '\'
            AND    object_type IN ('PROCEDURE','FUNCTION','TRIGGER')
            AND    status != 'VALID')
  LOOP
    BEGIN
      EXECUTE IMMEDIATE 'ALTER ' || o.object_type || ' "' || o.object_name || '" COMPILE';
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('could not compile ' || o.object_name || ': ' || SQLERRM);
    END;
  END LOOP;
END;
/

SELECT object_name, object_type, status FROM user_objects
WHERE  object_name LIKE 'XXKS\_EXP\_%' ESCAPE '\' AND status != 'VALID'
ORDER  BY object_name;
-- Expect zero rows.


--------------------------------------------------------------------------------
-- 8. NOW RUN 86_rename_handlers.sql.
--
-- Until it runs, every endpoint is broken and the app cannot even log in. Do
-- not stop here to admire section 6.
--------------------------------------------------------------------------------
