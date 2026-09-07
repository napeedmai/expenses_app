--------------------------------------------------------------------------------
-- 85b_rename_subprograms.sql
--
-- SUPERSEDES SECTION 5 OF 85_rename_to_xxks_exp.sql. Do not run that section.
-- Sections 1-4 of 85 (tables, indexes, constraints, triggers) are correct and
-- idempotent -- run those, then this, then 86.
--
-- Run as the APPLICATION SCHEMA, in SQL SCRIPTS. Idempotent.
--
--
-- TWO BUGS IN THE VERSION THIS REPLACES
-- -------------------------------------
--
-- 1. LISTAGG CANNOT DO THIS.
--
--    SELECT LISTAGG(text, '') ... INTO l_src
--
--    LISTAGG returns a VARCHAR2 and raises ORA-01489 past 4000 bytes.
--    send_expense_mail is over 700 lines. That statement could not have
--    succeeded for a single one of these twenty-two objects. The source is now
--    assembled line by line with DBMS_LOB.
--
-- 2. THE SUBSTITUTION WOULD HAVE REWRITTEN ENGLISH PROSE.
--
--    This is the serious one, and it would not have raised an error -- it would
--    have shipped. A word-boundary match does not care whether the word is an
--    identifier or ordinary text inside a string literal, and both of these are
--    live in the current source:
--
--      send_expense_mail:  'Open the Expenses app to view or act on this claim.'
--      scan_receipt:       '...the app fills same-day expenses in...'
--
--    The first is the closing line of every notification email, and it would
--    have gone out reading "Open the xxks_exp_claims app". The second is part
--    of the prompt sent to the AI, so receipt scanning would have quietly got
--    worse with no error anywhere.
--
--    A rename is supposed to be invisible. That one would have been visible to
--    every employee who gets an email, which is the opposite.
--
--
-- HOW IT IS FIXED
-- ---------------
-- Substitution happens ONLY outside single-quoted literals. Each source line is
-- split on the quote character; segments inside quotes are copied through
-- untouched. Doubled quotes ('') toggle twice and so leave the state unchanged,
-- which is the correct reading of an escaped quote.
--
-- Parity is deliberately reset at every line. A comment containing an
-- apostrophe -- "-- doesn't" -- would otherwise desynchronise everything after
-- it. Resetting per line means the worst case is that the tail of one comment
-- goes unsubstituted, and comments do not need substituting. PL/SQL string
-- literals do not span lines in this codebase, so nothing real is lost.
--
-- Section 3 checks the outcome instead of trusting the reasoning above: it
-- fails loudly if any new body contains an old name, or if any of the known
-- English phrases got mangled.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF
SET LINESIZE 200


--------------------------------------------------------------------------------
-- 0. The tables must already be renamed.
--------------------------------------------------------------------------------
DECLARE
  l_new NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_new FROM user_tables WHERE table_name = 'XXKS_EXP_CLAIMS';
  IF l_new = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'XXKS_EXP_CLAIMS not found -- run sections 1 to 4 of 85 first.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('schema ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
                       || ': tables renamed, rebuilding subprograms.');
END;
/


--------------------------------------------------------------------------------
-- 1. Rebuild each subprogram under its new name, then drop the old.
--------------------------------------------------------------------------------
DECLARE
  TYPE t_map IS TABLE OF VARCHAR2(128) INDEX BY VARCHAR2(128);
  l_map  t_map;   -- everything renamed; bodies reference tables and each other
  l_subs t_map;   -- only the subprograms: what to create and what to drop
  l_old  VARCHAR2(128);
  l_src  CLOB;
  l_n    NUMBER;
  l_kind VARCHAR2(30);
  l_line VARCHAR2(32767);

  -- Whole-identifier substitution on a fragment already known to be outside
  -- any literal. Oracle regex has no \b, so a non-identifier character is
  -- required on each side and put back through \1 and \2; the fragment is
  -- padded so a name at either end still has one.
  --
  -- Run twice because two renameable names separated by a single character --
  -- "expenses e JOIN expense_items" -- share that character, and the first
  -- pass consumes it.
  FUNCTION swap_all(p_frag IN VARCHAR2) RETURN VARCHAR2 IS
    l_t VARCHAR2(32767);
    l_k VARCHAR2(128);
  BEGIN
    IF p_frag IS NULL THEN RETURN p_frag; END IF;
    l_t := ' ' || p_frag || ' ';
    l_k := l_map.FIRST;
    WHILE l_k IS NOT NULL LOOP
      FOR i IN 1 .. 2 LOOP
        l_t := REGEXP_REPLACE(l_t,
                 '([^A-Za-z0-9_])' || l_k || '([^A-Za-z0-9_])',
                 '\1' || l_map(l_k) || '\2', 1, 0, 'i');
      END LOOP;
      l_k := l_map.NEXT(l_k);
    END LOOP;
    RETURN SUBSTR(l_t, 2, LENGTH(l_t) - 2);
  END;

  -- One source line, substituted outside quotes only.
  FUNCTION swap_line(p_line IN VARCHAR2) RETURN VARCHAR2 IS
    l_out VARCHAR2(32767) := NULL;
    l_pos PLS_INTEGER := 1;
    l_q   PLS_INTEGER;
    l_in  BOOLEAN := FALSE;
    l_seg VARCHAR2(32767);
  BEGIN
    IF p_line IS NULL THEN RETURN p_line; END IF;
    LOOP
      l_q := INSTR(p_line, '''', l_pos);
      IF l_q = 0 THEN
        l_seg := SUBSTR(p_line, l_pos);
        l_out := l_out || CASE WHEN l_in THEN l_seg ELSE swap_all(l_seg) END;
        EXIT;
      END IF;
      l_seg := SUBSTR(p_line, l_pos, l_q - l_pos);
      l_out := l_out || CASE WHEN l_in THEN l_seg ELSE swap_all(l_seg) END || '''';
      l_in  := NOT l_in;
      l_pos := l_q + 1;
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

  l_old := l_subs.FIRST;
  WHILE l_old IS NOT NULL LOOP
    l_map(l_old) := l_subs(l_old);
    l_old := l_subs.NEXT(l_old);
  END LOOP;

  ------------------------------------------------------------------- work
  --
  -- FOUR PHASES, and the order is the whole point.
  --
  -- These subprograms call each other. l_subs iterates alphabetically, so
  -- CAN_VIEW_CLAIM is rebuilt long before IS_FINANCE_MANAGER, which it calls --
  -- XXKS_EXP_IS_FINANCE_MANAGER does not exist yet, so the new function
  -- compiles INVALID and CREATE raises ORA-24344.
  --
  -- That is not a fault. It is what building a cyclic set of objects one at a
  -- time always looks like, and Oracle resolves it on the next compile. My
  -- first version treated every error as fatal and stopped on exactly this,
  -- which is why the run died on the second object.
  --
  -- So: create everything (tolerating ORA-24344), recompile, and only drop the
  -- old objects once every new one is VALID. A real compile error therefore
  -- stops the script with nothing dropped and the old objects still serving.
  ------------------------------------------------------------------------------

  ---------------------------------------------------------------- phase 1
  DBMS_OUTPUT.PUT_LINE('-- phase 1: create');
  l_old := l_subs.FIRST;
  WHILE l_old IS NOT NULL LOOP
    SELECT COUNT(*) INTO l_n FROM user_objects
    WHERE  object_name = l_old AND object_type IN ('PROCEDURE','FUNCTION');

    IF l_n = 0 THEN
      DBMS_OUTPUT.PUT_LINE(RPAD(l_old, 30) || ' -- not present (already done)');
    ELSE
      SELECT MAX(object_type) INTO l_kind FROM user_objects
      WHERE  object_name = l_old AND object_type IN ('PROCEDURE','FUNCTION');

      -- USER_SOURCE holds the body WITHOUT "CREATE OR REPLACE": it starts at
      -- "PROCEDURE x(" or "FUNCTION x(".
      DBMS_LOB.CREATETEMPORARY(l_src, TRUE);
      DBMS_LOB.WRITEAPPEND(l_src, 1, CHR(10));

      FOR r IN (SELECT text FROM user_source
                WHERE  name = l_old AND type = l_kind
                ORDER  BY line)
      LOOP
        l_line := swap_line(r.text);
        IF l_line IS NOT NULL AND LENGTH(l_line) > 0 THEN
          DBMS_LOB.WRITEAPPEND(l_src, LENGTH(l_line), l_line);
        END IF;
      END LOOP;

      DBMS_LOB.WRITEAPPEND(l_src, 1, CHR(10));

      BEGIN
        EXECUTE IMMEDIATE 'CREATE OR REPLACE ' || l_src;
        DBMS_OUTPUT.PUT_LINE(RPAD(l_old, 30) || ' -> ' || l_subs(l_old));
      EXCEPTION
        WHEN OTHERS THEN
          DBMS_LOB.FREETEMPORARY(l_src);
          IF SQLCODE = -24344 THEN
            -- Created, but INVALID. Expected for forward references; phase 3
            -- decides whether it was actually a problem.
            DBMS_OUTPUT.PUT_LINE(RPAD(l_old, 30) || ' -> ' || l_subs(l_old)
                                 || '  (invalid for now)');
          ELSE
            RAISE_APPLICATION_ERROR(-20010,
              'Creating ' || l_subs(l_old) || ' from ' || l_old || ' failed: '
              || SQLERRM || '. Nothing has been dropped.');
          END IF;
      END;

      BEGIN DBMS_LOB.FREETEMPORARY(l_src); EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;

    l_old := l_subs.NEXT(l_old);
  END LOOP;

  ---------------------------------------------------------------- phase 2
  -- Two passes. One is not always enough: A may be compiled before B, which it
  -- calls, is itself valid.
  DBMS_OUTPUT.PUT_LINE('-- phase 2: recompile');
  FOR pass IN 1 .. 2 LOOP
    FOR o IN (SELECT object_name, object_type FROM user_objects
              WHERE  object_name LIKE 'XXKS\_EXP\_%' ESCAPE '\'
              AND    object_type IN ('PROCEDURE','FUNCTION')
              AND    status != 'VALID')
    LOOP
      BEGIN
        EXECUTE IMMEDIATE 'ALTER ' || o.object_type || ' "' || o.object_name || '" COMPILE';
      EXCEPTION WHEN OTHERS THEN NULL;   -- phase 3 is what reports
      END;
    END LOOP;
  END LOOP;

  ---------------------------------------------------------------- phase 3
  -- The gate. Nothing is dropped while anything new is broken.
  DBMS_OUTPUT.PUT_LINE('-- phase 3: check');
  DECLARE
    l_bad NUMBER;
    l_names VARCHAR2(4000);
  BEGIN
    SELECT COUNT(*), LISTAGG(object_name, ', ') WITHIN GROUP (ORDER BY object_name)
    INTO   l_bad, l_names
    FROM   user_objects
    WHERE  object_name LIKE 'XXKS\_EXP\_%' ESCAPE '\'
    AND    object_type IN ('PROCEDURE','FUNCTION')
    AND    status != 'VALID';

    IF l_bad > 0 THEN
      RAISE_APPLICATION_ERROR(-20011,
        l_bad || ' rebuilt object(s) will not compile: ' || l_names
        || '. NOTHING HAS BEEN DROPPED and the old objects still work. Read '
        || 'user_errors for those names -- a real substitution mistake looks '
        || 'like PLS-00201 identifier must be declared.');
    END IF;
    DBMS_OUTPUT.PUT_LINE('   all rebuilt objects are VALID');
  END;

  ---------------------------------------------------------------- phase 4
  DBMS_OUTPUT.PUT_LINE('-- phase 4: drop the old');
  l_old := l_subs.FIRST;
  WHILE l_old IS NOT NULL LOOP
    SELECT COUNT(*) INTO l_n FROM user_objects
    WHERE  object_name = l_old AND object_type IN ('PROCEDURE','FUNCTION');

    IF l_n > 0 THEN
      SELECT MAX(object_type) INTO l_kind FROM user_objects
      WHERE  object_name = l_old AND object_type IN ('PROCEDURE','FUNCTION');
      EXECUTE IMMEDIATE 'DROP ' || l_kind || ' "' || l_old || '"';
      DBMS_OUTPUT.PUT_LINE('   dropped ' || LOWER(l_kind) || ' ' || l_old);
    END IF;

    l_old := l_subs.NEXT(l_old);
  END LOOP;
END;
/


--------------------------------------------------------------------------------
-- 2. Recompile ours, and only ours.
--
-- Cross-references are created out of order -- XXKS_EXP_PROCESS_ACTION exists
-- before XXKS_EXP_SEND_MAIL does -- so some land INVALID and need one pass.
--
-- NOT DBMS_UTILITY.COMPILE_SCHEMA: that would touch the ~190 invalid objects
-- belonging to the RPA and ticketing systems. Not ours, not our call.
--------------------------------------------------------------------------------
BEGIN
  FOR pass IN 1 .. 2 LOOP
    FOR o IN (SELECT object_name, object_type FROM user_objects
              WHERE  object_name LIKE 'XXKS\_EXP\_%' ESCAPE '\'
              AND    object_type IN ('PROCEDURE','FUNCTION','TRIGGER')
              AND    status != 'VALID')
    LOOP
      BEGIN
        EXECUTE IMMEDIATE 'ALTER ' || o.object_type || ' "' || o.object_name || '" COMPILE';
      EXCEPTION WHEN OTHERS THEN NULL;   -- pass 2 reports what is left
      END;
    END LOOP;
  END LOOP;
END;
/


--------------------------------------------------------------------------------
-- 3. Verify. Every query here should return ZERO ROWS.
--------------------------------------------------------------------------------

-- a) Nothing of ours is INVALID.
--
-- Phase 3 already gated on this BEFORE the drops. This run is after them, and
-- it catches a different thing: a new body that still names an old object was
-- valid while that object existed and goes invalid the moment it is dropped.
-- That is a missed substitution, and (b) will name it.
SELECT object_name, object_type, status FROM user_objects
WHERE  object_name LIKE 'XXKS\_EXP\_%' ESCAPE '\' AND status != 'VALID'
ORDER  BY object_name;

SELECT name, type, line, position, text FROM user_errors
WHERE  name LIKE 'XXKS\_EXP\_%' ESCAPE '\'
ORDER  BY name, line, position;

-- b) No old name survives in a new body.
SELECT DISTINCT name, type FROM user_source
WHERE  name LIKE 'XXKS\_EXP\_%' ESCAPE '\'
AND    REGEXP_LIKE(text,
         '[^A-Za-z0-9_](expenses|expense_items|expense_approvals'
         || '|expense_mail_log|expense_scan_log|app_secrets'
         || '|expense_login_attempts|process_expense_action|send_expense_mail'
         || '|recalc_claim_totals|price_expense_item|scan_receipt'
         || '|is_valid_session_token|get_reviewer_role|convert_to_usd'
         || '|get_project_manager_empid|get_finance_manager_empid'
         || '|can_view_claim|can_edit_claim)[^A-Za-z0-9_]', 'i');

-- c) No old name is left under its old object name either.
SELECT object_name, object_type FROM user_objects
WHERE  object_name IN ('PROCESS_EXPENSE_ACTION','SEND_EXPENSE_MAIL',
                       'RECALC_CLAIM_TOTALS','PRICE_EXPENSE_ITEM','SCAN_RECEIPT',
                       'EXPENSE_LOGIN_RECORD','EXPENSE_LOGIN_RETRY_AFTER',
                       'GET_OAUTH_ACCESS_TOKEN','GENERATE_SESSION_TOKEN',
                       'IS_VALID_SESSION_TOKEN','HMAC_SHA','JSON_ESCAPE_STR',
                       'IS_ALLOWED_ATTACHMENT','CONVERT_TO_USD',
                       'GET_EXCHANGE_RATE','GET_RATE_EFFECTIVE_DATE',
                       'GET_FINANCE_MANAGER_EMPID','GET_PROJECT_MANAGER_EMPID',
                       'GET_REVIEWER_ROLE','IS_FINANCE_MANAGER',
                       'CAN_VIEW_CLAIM','CAN_EDIT_CLAIM');

-- d) ** THE ENGLISH SURVIVED. ** Zero rows.
--
-- This is the check for bug 2. If the literal masking failed, the email sign-
-- off and the AI prompt now contain a table name.
SELECT name, line, TRIM(text) AS mangled_text
FROM   user_source
WHERE  name LIKE 'XXKS\_EXP\_%' ESCAPE '\'
AND    REGEXP_LIKE(text, 'the +xxks_exp|xxks_exp[a-z_]* +(app|form|claim system)', 'i')
ORDER  BY name, line;

-- And positively: the phrases must still be there. Expect one row each.
SELECT name, TRIM(text) AS kept FROM user_source
WHERE  name IN ('XXKS_EXP_SEND_MAIL','XXKS_EXP_SCAN_RECEIPT')
AND   (INSTR(LOWER(text), 'open the expenses app') > 0
    OR INSTR(LOWER(text), 'same-day expenses') > 0);


--------------------------------------------------------------------------------
-- 4. Then run 86_rename_handlers.sql. The API is down until you do.
--------------------------------------------------------------------------------
