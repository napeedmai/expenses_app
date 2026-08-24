--------------------------------------------------------------------------------
--   *** SUPERSEDED -- DO NOT RUN ***
--
-- Replaced by 64_multibill_stage1_clean.sql.
--
-- This version preserved the ~100 existing test claims: it migrated each into a
-- one-bill claim, kept the legacy per-bill columns on EXPENSES for old app
-- builds, and allowed nulls in EXPENSE_ITEMS.EXCHANGE_RATE to accommodate rows
-- created before the currency feature.
--
-- That is all unnecessary now. The decision (August 2026) was that the data is
-- test data and can be deleted, which removes the migration, the doubled
-- attachment storage, the legacy columns and the whole of stage 5.
--
-- Kept only as a record of the migration path, in case a future environment
-- ever has real data to preserve.
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- 63_multibill_stage1_schema.sql
--
-- MULTIPLE BILLS PER CLAIM -- STAGE 1 of 4: schema, migration, totals.
--
-- Run as the APPLICATION SCHEMA (REPO -- not dev). Idempotent. Read
-- MULTI_BILL_PLAN.md first.
--
--
-- SAFE TO RUN NOW, AND REVERSIBLE
-- -------------------------------
-- Nothing reads EXPENSE_ITEMS until stage 2, and no existing endpoint, screen
-- or report changes behaviour. The migration COPIES each existing bill into an
-- item rather than moving it -- the original stays on the EXPENSES row -- so
-- this whole stage can be undone with:
--
--     DROP TABLE expense_items;
--     ALTER TABLE expenses DROP COLUMN claim_for;
--     DROP PROCEDURE recalc_claim_totals;
--     ALTER TABLE expenses MODIFY (amount NOT NULL, from_date NOT NULL, to_date NOT NULL);
--
-- and nothing is lost. That is why it goes first and can sit in production
-- while the rest is built.
--
-- The last line only succeeds while no claim has null values -- true after this
-- script, false once stage 2 starts creating empty draft claims. See 2b.
--
--
-- WHAT IT DOES
-- ------------
--   1.  EXPENSE_ITEMS  -- one row per bill, up to 20 per claim
--   2.  EXPENSES.CLAIM_FOR -- free text, the purpose of the whole claim
--   2b. EXPENSES.AMOUNT / FROM_DATE / TO_DATE become nullable -- these now
--       belong to the bills, so a new claim header cannot supply them
--   3.  recalc_claim_totals -- rolls bills up into the claim's totals and dates
--   4.  Migration -- every existing expense becomes a claim with exactly one bill
--   5.  Verification
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF


--------------------------------------------------------------------------------
-- 0. Right schema? Everything below depends on objects that only exist where
--    the app lives. Four earlier scripts went to dev by accident.
--------------------------------------------------------------------------------
DECLARE
  l_schema  VARCHAR2(128) := SYS_CONTEXT('USERENV','CURRENT_SCHEMA');
  l_n       NUMBER;
  l_missing VARCHAR2(400);
BEGIN
  DBMS_OUTPUT.PUT_LINE('Connected as: ' || l_schema);

  FOR d IN (SELECT column_value AS name FROM TABLE(sys.odcivarchar2list(
              'GET_EXCHANGE_RATE', 'CONVERT_TO_USD')))
  LOOP
    SELECT COUNT(*) INTO l_n FROM user_objects
    WHERE  object_name = d.name AND status = 'VALID';
    IF l_n = 0 THEN l_missing := l_missing || d.name || ' '; END IF;
  END LOOP;

  SELECT COUNT(*) INTO l_n FROM user_tables WHERE table_name = 'EXPENSES';
  IF l_n = 0 THEN l_missing := l_missing || 'EXPENSES '; END IF;

  IF l_missing IS NOT NULL THEN
    RAISE_APPLICATION_ERROR(-20001,
      'Wrong schema, or incomplete. Connected as ' || l_schema
      || '. Missing or INVALID: ' || l_missing
      || '-- connect to the schema in src/config.js API_BASE_URL. Nothing changed.');
  END IF;

  DBMS_OUTPUT.PUT_LINE('Prerequisites OK. Proceeding.');
END;
/


--------------------------------------------------------------------------------
-- 1. EXPENSE_ITEMS -- the bills.
--
-- EXCHANGE_RATE and AMOUNT_USD are NULLABLE, deliberately, even though every
-- new bill always gets both. Legacy rows are the reason: an expense created
-- before the currency feature, or one whose rate lookup found nothing, has no
-- rate to migrate. Declaring the columns NOT NULL would make the migration in
-- section 4 fail on exactly the oldest data, which is the data least worth
-- losing. Stage 2's endpoints always set them, so new bills are never null --
-- see the verification query in section 5 to spot any that are.
--------------------------------------------------------------------------------
BEGIN
  EXECUTE IMMEDIATE '
    CREATE TABLE expense_items (
      id                    NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      expense_id            NUMBER         NOT NULL,
      item_no               NUMBER         NOT NULL,
      bill_no               VARCHAR2(100),
      bill_date             DATE           NOT NULL,
      type                  VARCHAR2(100)  NOT NULL,
      description           VARCHAR2(4000) NOT NULL,
      from_date             DATE           NOT NULL,
      to_date               DATE           NOT NULL,
      currency              VARCHAR2(3)    NOT NULL,
      amount                NUMBER(12,2)   NOT NULL,
      exchange_rate         NUMBER,
      amount_usd            NUMBER,
      attachment_blob       BLOB,
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
    )';
  DBMS_OUTPUT.PUT_LINE('EXPENSE_ITEMS created.');
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -955 THEN RAISE; END IF;
    DBMS_OUTPUT.PUT_LINE('EXPENSE_ITEMS already exists.');
END;
/

-- The cap lives in TWO places on purpose: this CHECK is the backstop that no
-- code path can bypass, and stage 2's POST handler returns a friendly 409
-- before it is ever hit. A constraint alone gives the user ORA-02290.
--
-- NO SEPARATE INDEX on (expense_id, item_no): expense_items_no_uq already
-- creates one, and Oracle refuses a duplicate with ORA-01408. This script
-- originally tried, and failed on that.

COMMENT ON TABLE expense_items IS
  'One row per bill on an expense claim. EXPENSES is the claim; this holds the '
  || 'bill details and receipt. Up to 20 per claim. See MULTI_BILL_PLAN.md.';


--------------------------------------------------------------------------------
-- 2. EXPENSES.CLAIM_FOR -- free text purpose of the whole claim.
--
--    Nullable: the ~100 existing claims have nothing to put in it, and forcing
--    a value would mean inventing one.
--------------------------------------------------------------------------------
DECLARE
  l_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_n FROM user_tab_columns
  WHERE  table_name = 'EXPENSES' AND column_name = 'CLAIM_FOR';

  IF l_n = 0 THEN
    EXECUTE IMMEDIATE 'ALTER TABLE expenses ADD (claim_for VARCHAR2(400))';
    DBMS_OUTPUT.PUT_LINE('EXPENSES.CLAIM_FOR added.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('EXPENSES.CLAIM_FOR already present.');
  END IF;
END;
/


--------------------------------------------------------------------------------
-- 2b. Relax three NOT NULL columns on EXPENSES.
--
-- Easy to miss, and stage 2 cannot work without it.
--
-- Under the new model the claim header collects only Project and Claim For --
-- the dates and the amount belong to the bills. So POST /expenses/draft creates
-- a claim with no from_date, no to_date and no amount, and EXPENSES declares
-- all three NOT NULL. The insert would fail outright.
--
-- These are the ONLY columns affected. EMP_ID stays NOT NULL (always known),
-- STATUS defaults to DRAFT, and the date/amount columns are the only other
-- mandatory ones.
--
-- The CHECK constraints need no change. An Oracle check constraint is violated
-- only when it evaluates to FALSE, and both
--     ck_expenses_amount  CHECK (amount > 0)
--     ck_expenses_dates   CHECK (to_date >= from_date)
-- evaluate to NULL -- not FALSE -- when the column is null. So they keep
-- rejecting a zero or a reversed period, while permitting "not yet known".
--
-- Reversibility: after THIS script no row is null, because every existing claim
-- has values and the migration recalculates all of them. So
--     ALTER TABLE expenses MODIFY (amount NOT NULL, from_date NOT NULL, to_date NOT NULL);
-- still succeeds today. Once stage 2 starts creating empty draft claims that is
-- no longer true, and reverting means deleting or filling those drafts first.
--------------------------------------------------------------------------------
DECLARE
  PROCEDURE make_nullable(p_col IN VARCHAR2) IS
    l_nullable VARCHAR2(1);
  BEGIN
    SELECT nullable INTO l_nullable
    FROM   user_tab_columns
    WHERE  table_name = 'EXPENSES' AND column_name = UPPER(p_col);

    IF l_nullable = 'N' THEN
      EXECUTE IMMEDIATE 'ALTER TABLE expenses MODIFY (' || p_col || ' NULL)';
      DBMS_OUTPUT.PUT_LINE('EXPENSES.' || UPPER(p_col) || ' is now nullable.');
    ELSE
      DBMS_OUTPUT.PUT_LINE('EXPENSES.' || UPPER(p_col) || ' already nullable.');
    END IF;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      DBMS_OUTPUT.PUT_LINE('EXPENSES.' || UPPER(p_col) || ' not found -- check the schema.');
  END;
BEGIN
  make_nullable('amount');
  make_nullable('from_date');
  make_nullable('to_date');
END;
/


--------------------------------------------------------------------------------
-- 3. recalc_claim_totals -- roll the bills up into the claim.
--
-- Called after every bill insert, update or delete. Deliberately NOT a trigger:
-- a row-level trigger fires once per bill, so saving five bills would recompute
-- five times, and reading EXPENSE_ITEMS from a trigger on EXPENSE_ITEMS runs
-- into mutating-table restrictions.
--
-- WHAT IT SETS ON THE CLAIM
--   amount_usd     SUM of bill amount_usd  <- the figure the dashboard uses
--   amount         SUM of bill amount      <- see the warning below
--   from_date      MIN of bill from_date
--   to_date        MAX of bill to_date
--   currency       first bill's, for display
--   exchange_rate  first bill's, for display
--
-- WARNING ON `amount`: summing mixed currencies produces a number that means
-- nothing -- 99 INR plus 50 EUR is not 149 of anything. It is maintained only
-- so screens and reports written against the old single-bill shape keep
-- returning something rather than null. AMOUNT_USD is the only total to trust,
-- and anything new should use it.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE recalc_claim_totals(p_expense_id IN NUMBER) IS
  l_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_count FROM expense_items WHERE expense_id = p_expense_id;

  -- No bills -- either a claim just created, or one whose last bill was
  -- deleted. Clear the totals rather than leaving yesterday's figures on a
  -- claim that no longer has anything behind them: a stale total is worse than
  -- an empty one, because it looks like a real number.
  --
  -- This is only possible because section 2b made these columns nullable.
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
-- 4. Migration -- one bill per existing claim.
--
-- Re-runnable: the NOT EXISTS skips claims that already have bills, so running
-- this twice does not duplicate anything.
--
-- Two values are INVENTED because the columns are NOT NULL and the old data
-- never captured them:
--   bill_date    falls back to the period start
--   description  gets a visible marker rather than being silently blank
--
-- The BLOB is COPIED, not moved. EXPENSES.ATTACHMENT_BLOB keeps its receipt,
-- which is what makes this stage reversible -- and means storage is temporarily
-- doubled for attachments. Reclaim it in a later stage, once the app has been
-- reading items in production for a while.
--------------------------------------------------------------------------------
DECLARE
  l_before NUMBER;
  l_after  NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_before FROM expense_items;

  INSERT INTO expense_items (
    expense_id, item_no, bill_no, bill_date, type, description,
    from_date, to_date, currency, amount, exchange_rate, amount_usd,
    attachment_blob, attachment_filename, attachment_mime_type,
    creation_date, created_by)
  SELECT e.id,
         1,
         e.bill_no,
         NVL(e.bill_date, e.from_date),
         NVL(e.type, 'Other'),
         NVL(e.description, '(migrated from a single-bill claim)'),
         e.from_date,
         e.to_date,
         NVL(e.currency, 'INR'),
         e.amount,
         e.exchange_rate,
         e.amount_usd,
         e.attachment_blob,
         e.attachment_filename,
         e.attachment_mime_type,
         NVL(e.creation_date, SYSDATE),
         e.created_by
  FROM   expenses e
  WHERE  NOT EXISTS (SELECT 1 FROM expense_items i WHERE i.expense_id = e.id);

  l_after := SQL%ROWCOUNT;
  COMMIT;

  DBMS_OUTPUT.PUT_LINE('Migrated ' || l_after || ' claim(s) to one bill each.');
  DBMS_OUTPUT.PUT_LINE('EXPENSE_ITEMS row count: ' || (l_before + l_after));
END;
/

-- Rates were carried across as-is rather than recomputed, so approved claims
-- keep the figure they were approved at. This only fills gaps: a legacy row
-- with no rate gets one now, using the month of its own from_date.
DECLARE
  l_fixed NUMBER := 0;
BEGIN
  FOR r IN (SELECT id, currency, from_date, amount
            FROM   expense_items
            WHERE  exchange_rate IS NULL OR amount_usd IS NULL)
  LOOP
    BEGIN
      UPDATE expense_items
      SET    exchange_rate = get_exchange_rate(r.currency, r.from_date),
             amount_usd    = convert_to_usd(r.amount, r.currency, r.from_date)
      WHERE  id = r.id;
      l_fixed := l_fixed + 1;
    EXCEPTION
      WHEN OTHERS THEN NULL;   -- no rate for that month; section 5 lists these
    END;
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Backfilled rate/USD on ' || l_fixed || ' bill(s).');
END;
/

-- Totals for every claim, so the claim rows agree with their bills from now on.
DECLARE
  l_n NUMBER := 0;
BEGIN
  FOR r IN (SELECT DISTINCT expense_id FROM expense_items) LOOP
    recalc_claim_totals(r.expense_id);
    l_n := l_n + 1;
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Recalculated totals for ' || l_n || ' claim(s).');
END;
/


--------------------------------------------------------------------------------
-- 5. Verification. Every one of these should return NO ROWS.
--------------------------------------------------------------------------------

-- a) Any claim with no bill at all? Should be none after the migration.
SELECT 'claim with no bills' AS problem, e.id, e.status
FROM   expenses e
WHERE  NOT EXISTS (SELECT 1 FROM expense_items i WHERE i.expense_id = e.id);

-- b) Any claim whose USD total disagrees with the sum of its bills?
--    Tolerance of 0.01 for rounding.
SELECT 'total mismatch' AS problem, e.id, e.amount_usd AS claim_total,
       (SELECT SUM(i.amount_usd) FROM expense_items i WHERE i.expense_id = e.id) AS bill_total
FROM   expenses e
WHERE  ABS(NVL(e.amount_usd,0)
           - NVL((SELECT SUM(i.amount_usd) FROM expense_items i
                  WHERE i.expense_id = e.id), 0)) > 0.01;

-- c) Any bill still without a rate? These could not be priced -- no
--    CURRENCY_CONVERSION row covers that currency and month. Expected on very
--    old data; a claim with one shows '-' as its USD amount.
SELECT 'no rate' AS problem, i.id, i.expense_id, i.currency, i.from_date, i.amount
FROM   expense_items i
WHERE  i.exchange_rate IS NULL OR i.amount_usd IS NULL;

-- d) Any claim over the cap? Impossible via the constraint; here as proof.
SELECT 'over 20 bills' AS problem, expense_id, COUNT(*) AS bills
FROM   expense_items GROUP BY expense_id HAVING COUNT(*) > 20;


-- And the shape of things afterwards:
SELECT COUNT(*) AS claims,
       (SELECT COUNT(*) FROM expense_items)                    AS bills,
       (SELECT COUNT(*) FROM expense_items
        WHERE attachment_blob IS NOT NULL)                     AS bills_with_receipt,
       (SELECT ROUND(SUM(amount_usd), 2) FROM expense_items)   AS total_usd
FROM   expenses;

SELECT object_name, object_type, status
FROM   user_objects
WHERE  object_name IN ('EXPENSE_ITEMS','RECALC_CLAIM_TOTALS')
ORDER  BY object_name;

-- The 2b change. AMOUNT, FROM_DATE and TO_DATE must all show NULLABLE = Y, or
-- stage 2 cannot create a claim header.
SELECT column_name, nullable, data_type
FROM   user_tab_columns
WHERE  table_name = 'EXPENSES'
AND    column_name IN ('AMOUNT','FROM_DATE','TO_DATE','CLAIM_FOR','AMOUNT_USD')
ORDER  BY column_name;


--------------------------------------------------------------------------------
-- NEXT: stage 2 adds the endpoints --
--
--   GET/POST         :id/items
--   PUT/DELETE       :id/items/:itemId
--   POST/GET         :id/items/:itemId/attachment
--
-- plus the privilege patterns for each (a path no privilege matches is
-- publicly reachable), items returned by GET :id, and the submit rule: at
-- least one bill, and a receipt on every bill.
--
-- Nothing calls anything created here until then. Deploy stages 1 and 2 to the
-- app schema BEFORE building the app screens, or the app calls endpoints that
-- do not exist.
--------------------------------------------------------------------------------
