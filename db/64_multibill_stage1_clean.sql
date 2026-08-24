--------------------------------------------------------------------------------
-- 64_multibill_stage1_clean.sql
--
-- MULTIPLE BILLS PER CLAIM -- STAGE 1, clean-slate version.
--
-- SUPERSEDES 63_multibill_stage1_schema.sql and makes
-- 67_multibill_stage5_cleanup.sql unnecessary. Both of those existed to
-- preserve ~100 test claims; the decision to delete them instead removes the
-- migration, the doubled attachment storage, the legacy columns and the whole
-- of stage 5.
--
-- Run as the APPLICATION SCHEMA (REPO -- not dev). Read MULTI_BILL_PLAN.md.
--
--
--   *** THIS DELETES EVERY EXPENSE CLAIM AND ITS APPROVAL HISTORY. ***
--
-- Authorised August 2026 on the grounds that all existing rows are test data.
-- Section 1 copies both tables to _pre_multibill backups first, so it is
-- recoverable for as long as you keep those.
--
--
--   *** THE API GOES DOWN UNTIL STAGE 2 IS DEPLOYED. ***
--
-- Section 3 drops columns that live ORDS handlers select -- GET :id, mine and
-- pending all read e.bill_no, e.type, e.description and e.attachment_filename.
-- The moment those columns disappear, those handlers fail. Not gracefully: a
-- bare 403 or 555 with no body, which reads as a permissions problem and is
-- not one.
--
-- So DO NOT RUN THIS UNTIL STAGE 2 IS READY TO RUN IMMEDIATELY AFTER. The gap
-- between them is downtime, not a soft rollout. There is no partial state worth
-- sitting in.
--
--
-- WHAT IT DOES
--   1. Back up EXPENSES and EXPENSE_APPROVALS
--   2. Delete all claims, approvals and any bills from a previous attempt
--   3. Drop the eight legacy per-bill columns from EXPENSES
--   4. Relax AMOUNT, FROM_DATE, TO_DATE -- these are totals now, not inputs
--   5. Add CLAIM_FOR
--   6. Create EXPENSE_ITEMS, properly strict -- no legacy rows to accommodate
--   7. recalc_claim_totals
--   8. Verify
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF


--------------------------------------------------------------------------------
-- 0. Right schema? Four earlier scripts went to dev by accident.
--------------------------------------------------------------------------------
DECLARE
  l_schema VARCHAR2(128) := SYS_CONTEXT('USERENV','CURRENT_SCHEMA');
  l_n      NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Connected as: ' || l_schema);

  SELECT COUNT(*) INTO l_n FROM user_tables WHERE table_name = 'EXPENSES';
  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'No EXPENSES table on ' || l_schema || '. Wrong schema -- connect to the '
      || 'one in src/config.js API_BASE_URL. Nothing changed.');
  END IF;

  SELECT COUNT(*) INTO l_n FROM user_objects
  WHERE  object_name IN ('GET_EXCHANGE_RATE','CONVERT_TO_USD') AND status = 'VALID';
  IF l_n < 2 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'Currency functions missing or INVALID on ' || l_schema
      || '. Run MASTER_DEPLOY.sql here first. Nothing changed.');
  END IF;

  DBMS_OUTPUT.PUT_LINE('Prerequisites OK.');
END;
/


--------------------------------------------------------------------------------
-- 1. Backups. Cheap, and the only thing standing between a decision and a
--    regret. Drop them once the new flow has been exercised.
--------------------------------------------------------------------------------
DECLARE
  PROCEDURE snapshot(p_src IN VARCHAR2) IS
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n FROM user_tables WHERE table_name = UPPER(p_src);
    IF l_n = 0 THEN
      DBMS_OUTPUT.PUT_LINE('  ' || UPPER(p_src) || ' does not exist -- skipped.');
      RETURN;
    END IF;

    SELECT COUNT(*) INTO l_n FROM user_tables
    WHERE  table_name = UPPER(p_src) || '_PRE_MULTIBILL';
    IF l_n > 0 THEN
      DBMS_OUTPUT.PUT_LINE('  ' || UPPER(p_src) || '_PRE_MULTIBILL already exists '
        || '-- kept, NOT overwritten.');
      RETURN;
    END IF;

    EXECUTE IMMEDIATE 'CREATE TABLE ' || p_src || '_pre_multibill AS SELECT * FROM ' || p_src;
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || p_src || '_pre_multibill' INTO l_n;
    DBMS_OUTPUT.PUT_LINE('  ' || UPPER(p_src) || '_PRE_MULTIBILL created, ' || l_n || ' row(s).');
  END;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Backups:');
  snapshot('expenses');
  snapshot('expense_approvals');
END;
/


--------------------------------------------------------------------------------
-- 2. Delete the test data.
--
--    Children first: EXPENSE_APPROVALS and EXPENSE_ITEMS both have foreign keys
--    to EXPENSES, so deleting parents first fails with ORA-02292.
--
--    DELETE rather than TRUNCATE: TRUNCATE cannot run while a foreign key
--    points at the table, and DELETE is transactional -- if something looks
--    wrong you can still ROLLBACK before the COMMIT below.
--------------------------------------------------------------------------------
DECLARE
  l_items    NUMBER := 0;
  l_appr     NUMBER := 0;
  l_claims   NUMBER := 0;
  l_n        NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_n FROM user_tables WHERE table_name = 'EXPENSE_ITEMS';
  IF l_n > 0 THEN
    EXECUTE IMMEDIATE 'DELETE FROM expense_items';
    l_items := SQL%ROWCOUNT;
  END IF;

  DELETE FROM expense_approvals;  l_appr   := SQL%ROWCOUNT;
  DELETE FROM expenses;           l_claims := SQL%ROWCOUNT;

  DBMS_OUTPUT.PUT_LINE('Deleted ' || l_items  || ' bill(s), '
                                  || l_appr   || ' approval(s), '
                                  || l_claims || ' claim(s).');
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 3. Drop the legacy per-bill columns.
--
-- These described ONE bill on the claim row. Bills now live in EXPENSE_ITEMS,
-- so keeping them would mean two places to write the same fact -- exactly the
-- pattern that caused the finance-manager bug, where one id lived in three
-- places and only one got changed.
--
-- ATTACHMENT_PATH goes too. It has never held anything meaningful: the receipt
-- has always been the BLOB. Written and read by the handlers, but dead since
-- before this project started.
--
-- Safe to drop the BLOB because section 2 just deleted every row. On a schema
-- with real data this would be the irreversible step.
--------------------------------------------------------------------------------
DECLARE
  PROCEDURE drop_col(p_col IN VARCHAR2) IS
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n FROM user_tab_columns
    WHERE  table_name = 'EXPENSES' AND column_name = UPPER(p_col);

    IF l_n = 0 THEN
      DBMS_OUTPUT.PUT_LINE('  ' || UPPER(p_col) || ' already gone.');
      RETURN;
    END IF;

    EXECUTE IMMEDIATE 'ALTER TABLE expenses DROP COLUMN ' || p_col;
    DBMS_OUTPUT.PUT_LINE('  dropped ' || UPPER(p_col));
  END;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Dropping legacy per-bill columns:');
  drop_col('bill_no');
  drop_col('bill_date');
  drop_col('type');
  drop_col('description');
  drop_col('attachment_blob');
  drop_col('attachment_filename');
  drop_col('attachment_mime_type');
  drop_col('attachment_path');
END;
/

-- Reclaim the space the BLOB column occupied. Dropping a column alone frees
-- nothing on disk. Harmless on an empty table; it matters once there is data.
BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE expenses MOVE ONLINE';
  DBMS_OUTPUT.PUT_LINE('EXPENSES reorganised.');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('MOVE ONLINE skipped: ' || SQLERRM);
    DBMS_OUTPUT.PUT_LINE('(Not fatal -- needs an index rebuild or a licence '
      || 'this edition may not have. Space is reclaimed, indexes may need '
      || 'ALTER INDEX ... REBUILD.)');
END;
/


--------------------------------------------------------------------------------
-- 4. AMOUNT, FROM_DATE and TO_DATE become nullable.
--
-- They are TOTALS now, derived from the bills, not things the claim header
-- supplies. A claim exists for a moment before its first bill, and all three
-- are NOT NULL today -- so POST /expenses/draft would fail on the insert.
--
-- The CHECK constraints need no change: an Oracle check is violated only when
-- it evaluates to FALSE, and both `amount > 0` and `to_date >= from_date`
-- evaluate to NULL -- not FALSE -- when the column is null. They keep rejecting
-- a zero amount and a reversed period while permitting "not yet known".
--------------------------------------------------------------------------------
DECLARE
  PROCEDURE make_nullable(p_col IN VARCHAR2) IS
    l_nullable VARCHAR2(1);
  BEGIN
    SELECT nullable INTO l_nullable FROM user_tab_columns
    WHERE  table_name = 'EXPENSES' AND column_name = UPPER(p_col);

    IF l_nullable = 'N' THEN
      EXECUTE IMMEDIATE 'ALTER TABLE expenses MODIFY (' || p_col || ' NULL)';
      DBMS_OUTPUT.PUT_LINE('  ' || UPPER(p_col) || ' is now nullable.');
    ELSE
      DBMS_OUTPUT.PUT_LINE('  ' || UPPER(p_col) || ' already nullable.');
    END IF;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      DBMS_OUTPUT.PUT_LINE('  ' || UPPER(p_col) || ' not found.');
  END;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Relaxing claim-level totals:');
  make_nullable('amount');
  make_nullable('from_date');
  make_nullable('to_date');
END;
/


--------------------------------------------------------------------------------
-- 5. CLAIM_FOR -- free text, the purpose of the whole claim.
--
-- Nullable in the database even though the spec calls it mandatory, and
-- deliberately so: a draft claim is created before the user has finished
-- typing. Requiring it here would break draft creation for exactly the reason
-- section 4 exists. Enforced where the rule belongs -- at submit, in the
-- handler, alongside "at least one bill" and "every bill has a receipt".
--------------------------------------------------------------------------------
DECLARE
  l_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_n FROM user_tab_columns
  WHERE  table_name = 'EXPENSES' AND column_name = 'CLAIM_FOR';

  IF l_n = 0 THEN
    EXECUTE IMMEDIATE 'ALTER TABLE expenses ADD (claim_for VARCHAR2(400))';
    DBMS_OUTPUT.PUT_LINE('CLAIM_FOR added.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('CLAIM_FOR already present.');
  END IF;
END;
/


--------------------------------------------------------------------------------
-- 6. EXPENSE_ITEMS -- the bills.
--
-- Recreated from scratch if a previous attempt left one. Safe: section 2
-- emptied it, and no code reads it yet.
--
-- EXCHANGE_RATE and AMOUNT_USD are NOT NULL here, unlike the earlier draft of
-- this script. That version had to allow nulls because legacy rows might have
-- had no rate to migrate. With no legacy rows, the stricter declaration is
-- correct: every bill is priced at save time by the server, and a bill with no
-- USD value would silently drop out of the dashboard total.
--------------------------------------------------------------------------------
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE expense_items CASCADE CONSTRAINTS';
  DBMS_OUTPUT.PUT_LINE('Old EXPENSE_ITEMS dropped.');
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -942 THEN RAISE; END IF;   -- -942 = table does not exist
END;
/

CREATE TABLE expense_items (
  id                    NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  expense_id            NUMBER         NOT NULL,
  item_no               NUMBER         NOT NULL,
  bill_no               VARCHAR2(100),                  -- the only optional input
  bill_date             DATE           NOT NULL,
  type                  VARCHAR2(100)  NOT NULL,
  description           VARCHAR2(4000) NOT NULL,
  from_date             DATE           NOT NULL,
  to_date               DATE           NOT NULL,
  currency              VARCHAR2(3)    NOT NULL,
  amount                NUMBER(12,2)   NOT NULL,
  exchange_rate         NUMBER         NOT NULL,        -- server-set
  amount_usd            NUMBER         NOT NULL,        -- server-set
  attachment_blob       BLOB,                           -- required to SUBMIT
  attachment_filename   VARCHAR2(300),
  attachment_mime_type  VARCHAR2(150),
  creation_date         DATE DEFAULT SYSDATE NOT NULL,
  created_by            VARCHAR2(150),
  last_update_date      DATE DEFAULT SYSDATE NOT NULL,
  last_updated_by       VARCHAR2(150),
  CONSTRAINT ck_items_amount CHECK (amount > 0),
  CONSTRAINT ck_items_dates  CHECK (to_date >= from_date),
  CONSTRAINT ck_items_itemno CHECK (item_no BETWEEN 1 AND 20),
  CONSTRAINT expense_items_no_uq UNIQUE (expense_id, item_no),
  CONSTRAINT fk_items_expense FOREIGN KEY (expense_id)
    REFERENCES expenses(id) ON DELETE CASCADE
);

-- NO SEPARATE INDEX ON (expense_id, item_no).
--
-- expense_items_no_uq already creates one -- a unique constraint is implemented
-- as a unique index -- and Oracle refuses a second index on the same column
-- list with ORA-01408: "such column list already indexed". An earlier draft of
-- this script tried, and the exception handler only tolerated ORA-955 (already
-- exists), so it failed the run.
--
-- Nothing is lost. That index leads on EXPENSE_ID, so it serves every lookup
-- this table gets: "the bills on claim X", in item_no order.

COMMENT ON TABLE expense_items IS
  'One row per bill on an expense claim. EXPENSES is the claim; this holds bill '
  || 'details and the receipt. Max 20 per claim. See MULTI_BILL_PLAN.md.';

-- The 20 cap lives in two places on purpose: this CHECK is the backstop no code
-- path can bypass, and stage 2's POST handler returns a readable 409 before it
-- is ever reached. The constraint alone would show the user ORA-02290.


--------------------------------------------------------------------------------
-- 7. recalc_claim_totals -- roll the bills up into the claim.
--
-- Called after every bill insert, update and delete. Deliberately NOT a
-- trigger: a row trigger fires once per bill, so saving five bills would
-- recompute five times, and reading EXPENSE_ITEMS from a trigger on
-- EXPENSE_ITEMS hits mutating-table restrictions.
--
-- WARNING ON `amount`: summing mixed currencies gives a number that means
-- nothing -- 99 INR plus 50 EUR is not 149 of anything. It is maintained only
-- so screens written against the old shape return something. AMOUNT_USD is the
-- only total to trust, and everything new should use it.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE recalc_claim_totals(p_expense_id IN NUMBER) IS
  l_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_count FROM expense_items WHERE expense_id = p_expense_id;

  -- No bills -- either just created, or the last bill was deleted. Clear the
  -- totals rather than leaving figures on a claim with nothing behind them: a
  -- stale total is worse than an empty one, because it looks real.
  IF l_count = 0 THEN
    UPDATE expenses
    SET    amount = NULL, amount_usd = NULL, from_date = NULL, to_date = NULL
    WHERE  id = p_expense_id;
    RETURN;
  END IF;

  UPDATE expenses e
  SET    (amount, amount_usd, from_date, to_date, currency, exchange_rate) =
         (SELECT SUM(i.amount),
                 SUM(i.amount_usd),
                 MIN(i.from_date),
                 MAX(i.to_date),
                 MIN(i.currency)      KEEP (DENSE_RANK FIRST ORDER BY i.item_no),
                 MIN(i.exchange_rate) KEEP (DENSE_RANK FIRST ORDER BY i.item_no)
          FROM   expense_items i
          WHERE  i.expense_id = e.id)
  WHERE  e.id = p_expense_id;
END recalc_claim_totals;
/


--------------------------------------------------------------------------------
-- 8. Verify.
--------------------------------------------------------------------------------
SELECT (SELECT COUNT(*) FROM expenses)             AS claims,
       (SELECT COUNT(*) FROM expense_items)        AS bills,
       (SELECT COUNT(*) FROM expense_approvals)    AS approvals,
       (SELECT COUNT(*) FROM expenses_pre_multibill) AS backed_up_claims
FROM   dual;

-- EXPENSES should now show CLAIM_FOR present; AMOUNT, FROM_DATE, TO_DATE
-- nullable; and none of the eight dropped columns.
SELECT column_name, nullable, data_type
FROM   user_tab_columns
WHERE  table_name = 'EXPENSES'
ORDER  BY column_id;

SELECT object_name, object_type, status
FROM   user_objects
WHERE  object_name IN ('EXPENSE_ITEMS','RECALC_CLAIM_TOTALS')
ORDER  BY object_name;

-- These handlers are now INVALID and will stay that way until stage 2 replaces
-- them. Expected -- see the warning at the top of this file.
SELECT t.uri_template, h.method
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND    (INSTR(h.source, 'bill_no') > 0 OR INSTR(h.source, 'attachment_blob') > 0
     OR INSTR(h.source, 'e.type')  > 0 OR INSTR(h.source, 'e.description')   > 0)
ORDER  BY t.uri_template, h.method;


--------------------------------------------------------------------------------
-- NEXT: STAGE 2, immediately. Until it runs, the app cannot read or write
-- expenses at all -- the handlers above reference columns that no longer exist.
--
-- Stage 2 delivers:
--   * GET/POST :id/items, PUT/DELETE :id/items/:itemId
--   * POST/GET :id/items/:itemId/attachment
--   * privilege patterns for each (a path no privilege matches is public)
--   * GET :id / mine / pending rewritten against the new shape
--   * POST draft creating a claim header only
--   * submit rules: at least one bill, a receipt on every bill, claim_for set
--
-- ROLLBACK, if it comes to that: the data is in EXPENSES_PRE_MULTIBILL and
-- EXPENSE_APPROVALS_PRE_MULTIBILL, but the dropped columns are gone from the
-- live table -- so restoring means recreating them first. Going forward is
-- easier than going back.
--------------------------------------------------------------------------------
