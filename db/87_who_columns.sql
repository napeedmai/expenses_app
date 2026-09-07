--------------------------------------------------------------------------------
-- 87_who_columns.sql
--
-- Run as the APPLICATION SCHEMA, in SQL SCRIPTS. Idempotent.
-- Run AFTER 86_rename_handlers.sql, and after the app has been tested.
--
--   dev  = karyasiddhitest.trinamix.com, schema HRMS
--   prod = karyasiddhi.trinamix.com,     schema REPO
--
--
-- WHAT THIS DOES
-- --------------
-- Puts CREATED_BY, CREATION_DATE, LAST_UPDATED_BY and LAST_UPDATE_DATE on every
-- table this application owns, and makes them get POPULATED rather than merely
-- exist. Four of the tables have none of them:
--
--   XXKS_EXP_SECRETS          10 rows, 0/4
--   XXKS_EXP_MAIL_LOG         15 rows, 0/4   (has CREATED_AT)
--   XXKS_EXP_SCAN_LOG         27 rows, 0/4   (has CREATED_AT)
--   XXKS_EXP_LOGIN_ATTEMPTS    3 rows, 0/4   (has ATTEMPTED_AT)
--
-- XXKS_EXP_CLAIMS, _ITEMS, _APPROVALS and the two _BKP tables already have all
-- four and a trigger that fills them. Nothing here touches those.
--
--
-- CREATED_AT IS RENAMED, NOT DUPLICATED
-- -------------------------------------
-- MAIL_LOG and SCAN_LOG already record when a row was created; the column is
-- just called CREATED_AT. Adding CREATION_DATE beside it would leave two
-- columns meaning the same thing, drifting apart the first time someone writes
-- to one and not the other -- so it is RENAMED.
--
-- That is safe here, and it was checked rather than assumed:
--
--   * no PL/SQL names CREATED_AT in an INSERT column list -- both tables rely
--     on the column DEFAULT, so the writers do not care what it is called
--   * the indexes on (EXPENSE_ID, CREATED_AT) and (EMP_ID, CREATED_AT) follow a
--     column rename automatically; they are defined on the column, not its name
--   * section 1 REFUSES TO RUN if it finds an ORDS handler naming CREATED_AT
--
-- ATTEMPTED_AT on LOGIN_ATTEMPTS is NOT renamed. It is a business fact -- when
-- the sign-in was tried -- that the rate limiter reads directly, not an audit
-- stamp that happens to coincide. It keeps its name and gets the four who
-- columns alongside.
--
-- The renamed columns keep TIMESTAMP rather than becoming DATE. The existing
-- CREATION_DATE columns are DATE, so this is inconsistent, and converting would
-- mean add-copy-drop on live tables to remove sub-second precision that is
-- actually useful for scan timings. Not worth it. Noted so it is a decision
-- rather than an oversight.
--
--
-- WHICH COLUMNS ARE NOT NULL
-- --------------------------
-- CREATION_DATE and LAST_UPDATE_DATE are NOT NULL; CREATED_BY and
-- LAST_UPDATED_BY are nullable. That is not a preference, it is what
-- XXKS_EXP_CLAIMS and XXKS_EXP_APPROVALS already do (their SYS_C constraints,
-- visible in script 83's output). Matching an existing convention beats
-- introducing a better one on four tables out of nine.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF
SET LINESIZE 200


--------------------------------------------------------------------------------
-- 1. Pre-flight. The rename must be done, and nothing may depend on CREATED_AT
--    by name.
--------------------------------------------------------------------------------
DECLARE
  l_n NUMBER;
  l_h NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_n FROM user_tables WHERE table_name = 'XXKS_EXP_CLAIMS';
  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001, 'Run 85, 85b and 86 first.');
  END IF;

  SELECT COUNT(*) INTO l_h FROM user_ords_handlers
  WHERE  REGEXP_LIKE(source, '[^A-Za-z0-9_]created_at[^A-Za-z0-9_]', 'i');
  IF l_h > 0 THEN
    RAISE_APPLICATION_ERROR(-20002,
      l_h || ' ORDS handler(s) name CREATED_AT. Renaming the column would break '
      || 'them. Send me the list before running this.');
  END IF;

  SELECT COUNT(*) INTO l_n FROM user_source
  WHERE  name LIKE 'XXKS\_EXP\_%' ESCAPE '\'
  AND    REGEXP_LIKE(text, '[^A-Za-z0-9_]created_at[^A-Za-z0-9_]', 'i');
  DBMS_OUTPUT.PUT_LINE('PL/SQL lines naming created_at: ' || l_n
                       || '  (comments and ad-hoc SELECTs are fine)');
END;
/


--------------------------------------------------------------------------------
-- 2. Rename CREATED_AT -> CREATION_DATE where it exists.
--------------------------------------------------------------------------------
DECLARE
  l_n NUMBER;
  PROCEDURE rename_it(p_tab VARCHAR2) IS
    l_old NUMBER; l_new NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_old FROM user_tab_columns
    WHERE  table_name = p_tab AND column_name = 'CREATED_AT';
    SELECT COUNT(*) INTO l_new FROM user_tab_columns
    WHERE  table_name = p_tab AND column_name = 'CREATION_DATE';

    IF l_old = 1 AND l_new = 0 THEN
      EXECUTE IMMEDIATE 'ALTER TABLE "' || p_tab
                     || '" RENAME COLUMN created_at TO creation_date';
      DBMS_OUTPUT.PUT_LINE(RPAD(p_tab, 26) || ' created_at -> creation_date');
    ELSIF l_new = 1 THEN
      DBMS_OUTPUT.PUT_LINE(RPAD(p_tab, 26) || ' already has creation_date');
    ELSE
      DBMS_OUTPUT.PUT_LINE(RPAD(p_tab, 26) || ' has neither -- will be added');
    END IF;
  END;
BEGIN
  rename_it('XXKS_EXP_MAIL_LOG');
  rename_it('XXKS_EXP_SCAN_LOG');
END;
/


--------------------------------------------------------------------------------
-- 3. Add whatever is still missing, then backfill, then enforce NOT NULL.
--
-- Three steps rather than one ALTER with DEFAULT ... NOT NULL, because the
-- existing rows need a sensible value and there is a better one available than
-- SYSDATE for three of the four tables:
--
--   MAIL_LOG, SCAN_LOG        creation_date already carries the real time
--   LOGIN_ATTEMPTS            attempted_at is the real time
--   SECRETS                   nothing recorded; SYSDATE is the honest answer
--                             and CREATED_BY says so
--
-- Backfilling CREATED_BY with SYSDATE-era guesswork would be worse than
-- admitting the information was never captured, so it is set to a marker.
--------------------------------------------------------------------------------
DECLARE
  TYPE t_tabs IS TABLE OF VARCHAR2(128);
  l_tabs t_tabs := t_tabs('XXKS_EXP_SECRETS', 'XXKS_EXP_MAIL_LOG',
                          'XXKS_EXP_SCAN_LOG', 'XXKS_EXP_LOGIN_ATTEMPTS');
  l_n    NUMBER;

  FUNCTION has_col(p_tab VARCHAR2, p_col VARCHAR2) RETURN BOOLEAN IS
    l_c NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_c FROM user_tab_columns
    WHERE  table_name = p_tab AND column_name = p_col;
    RETURN l_c > 0;
  END;

  PROCEDURE add_col(p_tab VARCHAR2, p_col VARCHAR2, p_type VARCHAR2) IS
  BEGIN
    IF NOT has_col(p_tab, p_col) THEN
      EXECUTE IMMEDIATE 'ALTER TABLE "' || p_tab || '" ADD (' || p_col || ' ' || p_type || ')';
      DBMS_OUTPUT.PUT_LINE('   added ' || p_col);
    END IF;
  END;
BEGIN
  FOR i IN 1 .. l_tabs.COUNT LOOP
    -- SKIP WHAT IS NOT THERE.
    --
    -- On prod, XXKS_EXP_SCAN_LOG and XXKS_EXP_LOGIN_ATTEMPTS do not exist when
    -- this runs -- the AI scan and login work arrive after the rename, in the
    -- feature phase. ALTER TABLE on a missing table raises ORA-00942 and would
    -- take the rest of the loop with it, leaving the tables that DO exist
    -- half-done. The feature scripts create those two with the who columns
    -- already on them.
    DECLARE
      l_exists NUMBER;
    BEGIN
      SELECT COUNT(*) INTO l_exists FROM user_tables WHERE table_name = l_tabs(i);
      IF l_exists = 0 THEN
        DBMS_OUTPUT.PUT_LINE(l_tabs(i) || ' -- not present here, skipped');
        CONTINUE;
      END IF;
    END;

    DBMS_OUTPUT.PUT_LINE(l_tabs(i));

    add_col(l_tabs(i), 'CREATION_DATE',    'DATE');
    add_col(l_tabs(i), 'CREATED_BY',       'VARCHAR2(150)');
    add_col(l_tabs(i), 'LAST_UPDATE_DATE', 'DATE');
    add_col(l_tabs(i), 'LAST_UPDATED_BY',  'VARCHAR2(150)');

    -- Backfill. Each statement is written so a re-run changes nothing.
    IF l_tabs(i) = 'XXKS_EXP_LOGIN_ATTEMPTS' THEN
      EXECUTE IMMEDIATE 'UPDATE "' || l_tabs(i) || '"
        SET creation_date = NVL(creation_date, CAST(attempted_at AS DATE))
        WHERE creation_date IS NULL';
    ELSE
      EXECUTE IMMEDIATE 'UPDATE "' || l_tabs(i) || '"
        SET creation_date = NVL(creation_date, SYSDATE)
        WHERE creation_date IS NULL';
    END IF;

    EXECUTE IMMEDIATE 'UPDATE "' || l_tabs(i) || '"
      SET last_update_date = NVL(last_update_date, creation_date),
          created_by       = NVL(created_by,      ''PRE_WHO_COLUMNS''),
          last_updated_by  = NVL(last_updated_by, ''PRE_WHO_COLUMNS'')
      WHERE last_update_date IS NULL OR created_by IS NULL
         OR last_updated_by IS NULL';
    DBMS_OUTPUT.PUT_LINE('   backfilled ' || SQL%ROWCOUNT || ' row(s)');
    COMMIT;

    -- NOT NULL only after every row has a value, or the ALTER fails.
    FOR c IN (SELECT column_name FROM user_tab_columns
              WHERE  table_name = l_tabs(i)
              AND    column_name IN ('CREATION_DATE','LAST_UPDATE_DATE')
              AND    nullable = 'Y')
    LOOP
      EXECUTE IMMEDIATE 'ALTER TABLE "' || l_tabs(i) || '" MODIFY ('
                     || c.column_name || ' NOT NULL)';
      DBMS_OUTPUT.PUT_LINE('   ' || c.column_name || ' is now NOT NULL');
    END LOOP;
  END LOOP;
END;
/


--------------------------------------------------------------------------------
-- 4. Triggers, so the columns stay true.
--
-- Columns that exist but are never written are worse than no columns: they look
-- like an audit trail and are not one. These mirror XXKS_EXP_CLAIMS_T1 exactly,
-- including NVL(apex_application.g_user, USER) -- which is also what the other
-- XXKS_ systems in this schema do, so a DBA reading any of them sees one
-- convention.
--
-- Through ORDS, APEX_APPLICATION.G_USER is normally null and this records the
-- schema name. That is honest: the app authenticates its own users and passes
-- the employee id in a header, so the database genuinely does not know who the
-- person was. Where it matters, the row already carries EMP_ID.
--------------------------------------------------------------------------------
DECLARE
  TYPE t_tabs IS TABLE OF VARCHAR2(128);
  l_tabs t_tabs := t_tabs('XXKS_EXP_SECRETS', 'XXKS_EXP_MAIL_LOG',
                          'XXKS_EXP_SCAN_LOG', 'XXKS_EXP_LOGIN_ATTEMPTS');
  l_trg VARCHAR2(128);
BEGIN
  FOR i IN 1 .. l_tabs.COUNT LOOP
    DECLARE
      l_exists NUMBER;
    BEGIN
      SELECT COUNT(*) INTO l_exists FROM user_tables WHERE table_name = l_tabs(i);
      IF l_exists = 0 THEN
        DBMS_OUTPUT.PUT_LINE(l_tabs(i) || ' -- not present here, no trigger');
        CONTINUE;
      END IF;
    END;

    -- XXKS_EXP_SECRETS -> XXKS_EXP_SECRETS_T1, and so on: the same _T<n>
    -- pattern section 4 of script 85 used for the two existing triggers.
    l_trg := l_tabs(i) || '_T1';

    EXECUTE IMMEDIATE '
      CREATE OR REPLACE TRIGGER "' || l_trg || '"
      BEFORE INSERT OR UPDATE ON "' || l_tabs(i) || '"
      FOR EACH ROW
      BEGIN
        IF INSERTING THEN
          :new.creation_date := NVL(:new.creation_date, SYSDATE);
          :new.created_by    := NVL(:new.created_by,
                                    NVL(apex_application.g_user, USER));
        END IF;
        :new.last_update_date := SYSDATE;
        :new.last_updated_by  := NVL(apex_application.g_user, USER);
      END;';
    DBMS_OUTPUT.PUT_LINE('trigger ' || l_trg || ' on ' || l_tabs(i));
  END LOOP;
END;
/
-- NVL on the INSERT branch rather than a bare assignment: a caller that sets
-- creation_date deliberately -- a backfill, a data fix -- should not have it
-- silently overwritten with SYSDATE. The two existing triggers do overwrite;
-- they are left alone, because changing a working audit trigger to make four
-- new ones consistent is the wrong trade.


--------------------------------------------------------------------------------
-- 5. Fix the stale reference in the OAuth error message.
--
-- XXKS_EXP_GET_OAUTH_ACCESS_TOKEN tells whoever hits the error to check
-- APP_SECRETS. That table is now XXKS_EXP_SECRETS. The rename scripts correctly
-- did NOT touch it -- it is English prose inside a string literal, and 85b went
-- to some trouble to protect exactly that -- but prose that names a table can
-- still go out of date.
--------------------------------------------------------------------------------
DECLARE
  l_src  CLOB;
  l_line VARCHAR2(32767);
  l_n    NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_n FROM user_source
  WHERE  name = 'XXKS_EXP_GET_OAUTH_ACCESS_TOKEN'
  AND    INSTR(text, 'APP_SECRETS') > 0;

  IF l_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('OAuth message already updated -- nothing to do.');
    RETURN;
  END IF;

  DBMS_LOB.CREATETEMPORARY(l_src, TRUE);
  DBMS_LOB.WRITEAPPEND(l_src, 1, CHR(10));
  FOR r IN (SELECT text FROM user_source
            WHERE  name = 'XXKS_EXP_GET_OAUTH_ACCESS_TOKEN' AND type = 'PROCEDURE'
            ORDER  BY line)
  LOOP
    -- Only inside that one message. A blanket REPLACE would be the very
    -- mistake this script's section 2 comment warns about.
    l_line := REPLACE(r.text, 'in APP_SECRETS', 'in XXKS_EXP_SECRETS');
    IF l_line IS NOT NULL AND LENGTH(l_line) > 0 THEN
      DBMS_LOB.WRITEAPPEND(l_src, LENGTH(l_line), l_line);
    END IF;
  END LOOP;
  DBMS_LOB.WRITEAPPEND(l_src, 1, CHR(10));

  EXECUTE IMMEDIATE 'CREATE OR REPLACE ' || l_src;
  DBMS_LOB.FREETEMPORARY(l_src);
  DBMS_OUTPUT.PUT_LINE('OAuth error message now names XXKS_EXP_SECRETS.');
END;
/


--------------------------------------------------------------------------------
-- 5b. Recompile.
--
-- Sections 2 and 3 rename a column and add four more. ANY DDL on a table
-- invalidates every PL/SQL object that depends on it, whether or not the change
-- affects it -- so XXKS_EXP_SEND_MAIL (writes the mail log),
-- XXKS_EXP_LOGIN_RECORD and XXKS_EXP_LOGIN_RETRY_AFTER (read the attempts
-- table) all go INVALID, and XXKS_EXP_PROCESS_ACTION follows because it calls
-- SEND_MAIL.
--
-- Oracle would revalidate them on first use, but "first use" here means a real
-- user submitting a claim, and if one of them does NOT recompile they find out
-- instead of us. This section was missing from the first version of this
-- script and the run left four objects INVALID -- harmless, but it looked like
-- damage, which is its own cost.
--
-- Two passes: one is not enough when A is compiled before B, which it calls,
-- is itself valid.
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
      EXCEPTION WHEN OTHERS THEN NULL;   -- section 6(d) reports what is left
      END;
    END LOOP;
  END LOOP;
END;
/


--------------------------------------------------------------------------------
-- 6. Verify.
--------------------------------------------------------------------------------

-- a) Every table has all four. Expect 4 for each of the nine, and no table
--    listed with fewer.
SELECT t.table_name,
       (SELECT COUNT(*) FROM user_tab_columns c
        WHERE  c.table_name = t.table_name
        AND    c.column_name IN ('CREATED_BY','CREATION_DATE',
                                 'LAST_UPDATED_BY','LAST_UPDATE_DATE')) AS who_cols
FROM   user_tables t
WHERE  t.table_name LIKE 'XXKS\_EXP\_%' ESCAPE '\'
ORDER  BY who_cols, t.table_name;

-- b) No NULLs left anywhere. Expect zero rows.
SELECT 'XXKS_EXP_SECRETS' t, COUNT(*) nulls FROM xxks_exp_secrets
  WHERE creation_date IS NULL OR last_update_date IS NULL
     OR created_by IS NULL OR last_updated_by IS NULL
HAVING COUNT(*) > 0
UNION ALL
SELECT 'XXKS_EXP_MAIL_LOG', COUNT(*) FROM xxks_exp_mail_log
  WHERE creation_date IS NULL OR last_update_date IS NULL
     OR created_by IS NULL OR last_updated_by IS NULL
HAVING COUNT(*) > 0
UNION ALL
SELECT 'XXKS_EXP_SCAN_LOG', COUNT(*) FROM xxks_exp_scan_log
  WHERE creation_date IS NULL OR last_update_date IS NULL
     OR created_by IS NULL OR last_updated_by IS NULL
HAVING COUNT(*) > 0
UNION ALL
SELECT 'XXKS_EXP_LOGIN_ATTEMPTS', COUNT(*) FROM xxks_exp_login_attempts
  WHERE creation_date IS NULL OR last_update_date IS NULL
     OR created_by IS NULL OR last_updated_by IS NULL
HAVING COUNT(*) > 0;

-- c) A trigger on every table. Expect six: the four new ones plus
--    XXKS_EXP_CLAIMS_T1 and XXKS_EXP_APPROVALS_T1.
--
--    XXKS_EXP_ITEMS and the two _BKP tables have none. ITEMS is worth knowing
--    about: it has the four columns and NOT NULL on two of them, so its writers
--    must be setting them explicitly. That has always been true and is not this
--    script's business -- but it is the one table where the audit trail depends
--    on the code remembering.
SELECT table_name, trigger_name, status
FROM   user_triggers
WHERE  table_name LIKE 'XXKS\_EXP\_%' ESCAPE '\'
ORDER  BY table_name;

-- d) Nothing broken. Expect zero rows.
SELECT object_name, object_type, status FROM user_objects
WHERE  object_name LIKE 'XXKS\_EXP\_%' ESCAPE '\' AND status != 'VALID';


--------------------------------------------------------------------------------
-- 7. Then prove the triggers fire, because (c) only proves they exist.
--
--   INSERT INTO xxks_exp_secrets (secret_name, secret_value)
--   VALUES ('WHO_COLUMN_TEST', 'delete me');
--
--   SELECT secret_name, created_by, creation_date, last_updated_by,
--          last_update_date
--   FROM   xxks_exp_secrets WHERE secret_name = 'WHO_COLUMN_TEST';
--   -- all four populated
--
--   UPDATE xxks_exp_secrets SET secret_value = 'still here'
--   WHERE  secret_name = 'WHO_COLUMN_TEST';
--   -- last_update_date moves, creation_date does not
--
--   DELETE FROM xxks_exp_secrets WHERE secret_name = 'WHO_COLUMN_TEST';
--   COMMIT;
--
-- Then send a claim through the app end to end once more. Section 2 renamed a
-- column on the mail log, and the thing that writes to it is the procedure
-- every notification goes through.
--------------------------------------------------------------------------------
