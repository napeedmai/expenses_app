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
-- Stage 5 no longer exists: 64 drops the legacy columns up front, so there is
-- nothing left to clean up later.
--
-- Kept only as a record of the migration path, in case a future environment
-- ever has real data to preserve.
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- 67_multibill_stage5_cleanup.sql
--
-- MULTIPLE BILLS PER CLAIM -- STAGE 5: drop the legacy per-bill columns.
--
--
--   *** DO NOT RUN THIS YET. EVERY DROP IS COMMENTED OUT ON PURPOSE. ***
--
--
-- This is the last stage and the only irreversible one. It exists now so the
-- cleanup is written down rather than left for someone to work out later.
--
--
-- WHEN IS IT SAFE?
-- ----------------
-- Not "when the new app is released". The real condition is:
--
--     no client is still reading the old per-bill columns
--
-- Those are different dates. Store rollouts take days, and a sideloaded APK
-- never auto-updates -- someone can be on the old build for months. While they
-- are, they read bill details from the CLAIM row and fetch receipts from
-- /expenses/{id}/attachment, both of which this script destroys.
--
-- Section 1 checks readiness. Wait for at least one full release cycle after
-- the new app is live, and confirm the legacy attachment endpoint has gone
-- quiet, before uncommenting anything.
--
-- The cost of waiting is disk: attachments exist twice, once on the claim and
-- once on its first bill. That is the whole downside. The cost of rushing is
-- every receipt on every migrated claim, permanently.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED


--------------------------------------------------------------------------------
-- 1. Readiness. Run this whenever you think it might be time.
--------------------------------------------------------------------------------
DECLARE
  l_claims      NUMBER;
  l_no_items    NUMBER;
  l_orphan_blob NUMBER;
  l_mismatch    NUMBER;
  l_ready       BOOLEAN := TRUE;
BEGIN
  SELECT COUNT(*) INTO l_claims FROM expenses;

  -- a) Every claim must have at least one bill. A claim without one would lose
  --    its bill details entirely.
  SELECT COUNT(*) INTO l_no_items
  FROM   expenses e
  WHERE  NOT EXISTS (SELECT 1 FROM expense_items i WHERE i.expense_id = e.id);

  -- b) No receipt may exist ONLY on the claim row. If the claim has a blob and
  --    its first bill does not, dropping the column deletes the only copy.
  SELECT COUNT(*) INTO l_orphan_blob
  FROM   expenses e
  WHERE  e.attachment_blob IS NOT NULL
  AND    NOT EXISTS (SELECT 1 FROM expense_items i
                     WHERE  i.expense_id = e.id
                     AND    i.attachment_blob IS NOT NULL);

  -- c) Totals must agree with the bills, or the rollup has drifted and the
  --    claim columns are still carrying something the bills do not.
  SELECT COUNT(*) INTO l_mismatch
  FROM   expenses e
  WHERE  ABS(NVL(e.amount_usd,0)
             - NVL((SELECT SUM(i.amount_usd) FROM expense_items i
                    WHERE i.expense_id = e.id), 0)) > 0.01;

  DBMS_OUTPUT.PUT_LINE('Claims                          : ' || l_claims);
  DBMS_OUTPUT.PUT_LINE('Claims with no bills            : ' || l_no_items);
  DBMS_OUTPUT.PUT_LINE('Receipts only on the claim row  : ' || l_orphan_blob);
  DBMS_OUTPUT.PUT_LINE('Total mismatches                : ' || l_mismatch);
  DBMS_OUTPUT.PUT_LINE(' ');

  IF l_no_items > 0 THEN
    l_ready := FALSE;
    DBMS_OUTPUT.PUT_LINE('BLOCKED: some claims have no bills. Re-run stage 1''s migration.');
  END IF;
  IF l_orphan_blob > 0 THEN
    l_ready := FALSE;
    DBMS_OUTPUT.PUT_LINE('BLOCKED: ' || l_orphan_blob || ' receipt(s) exist only on the claim.');
    DBMS_OUTPUT.PUT_LINE('         Dropping ATTACHMENT_BLOB would delete the only copy.');
    DBMS_OUTPUT.PUT_LINE('         Section 2 copies them across first.');
  END IF;
  IF l_mismatch > 0 THEN
    l_ready := FALSE;
    DBMS_OUTPUT.PUT_LINE('BLOCKED: totals disagree with bills on ' || l_mismatch || ' claim(s).');
  END IF;

  IF l_ready THEN
    DBMS_OUTPUT.PUT_LINE('Data checks pass.');
    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE('STILL TO CONFIRM BY HAND -- no query can tell you these:');
    DBMS_OUTPUT.PUT_LINE('  * the new app has been live for a full release cycle');
    DBMS_OUTPUT.PUT_LINE('  * nobody is still running an old APK');
    DBMS_OUTPUT.PUT_LINE('  * /expenses/{id}/attachment has gone quiet (see section 4)');
  END IF;
END;
/


--------------------------------------------------------------------------------
-- 2. Rescue any receipt that lives only on the claim row.
--
--    Should find nothing if stage 1 ran cleanly. Present for claims created
--    between stage 1 and stage 3 by an old app build, which would have attached
--    to the claim rather than to a bill.
--------------------------------------------------------------------------------
/*
UPDATE expense_items i
SET   (attachment_blob, attachment_filename, attachment_mime_type) =
      (SELECT e.attachment_blob, e.attachment_filename, e.attachment_mime_type
       FROM   expenses e WHERE e.id = i.expense_id)
WHERE i.item_no = 1
AND   i.attachment_blob IS NULL
AND   EXISTS (SELECT 1 FROM expenses e
              WHERE e.id = i.expense_id AND e.attachment_blob IS NOT NULL);
COMMIT;
*/


--------------------------------------------------------------------------------
-- 3. The endpoints must stop reading these columns FIRST.
--
-- Dropping a column that a stored ORDS handler selects makes the handler fail
-- at request time -- as a bare 403 or 555 with no body, which reads as a
-- permissions problem and is not one. See DEPLOYMENT.md section 12.
--
-- These references exist in PROD_4_endpoints.sql today:
--
--     e.type                    x3   GET :id, mine, pending
--     e.description             x3
--     e.bill_no                 x3
--     e.bill_date               x3
--     e.attachment_filename     x3
--     e.attachment_path         x1
--     e.attachment_mime_type    x1
--
-- Stage 2 replaces those reads with the bill list. Confirm none remain before
-- dropping anything:
--------------------------------------------------------------------------------
SELECT t.uri_template, h.method
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND    (INSTR(h.source, 'e.bill_no')             > 0
     OR INSTR(h.source, 'e.bill_date')           > 0
     OR INSTR(h.source, 'e.attachment_blob')     > 0
     OR INSTR(h.source, 'e.attachment_filename') > 0
     OR INSTR(h.source, 'e.attachment_path')     > 0)
ORDER  BY t.uri_template, h.method;

-- Rows here mean NOT READY. Each one breaks the moment a column disappears.


--------------------------------------------------------------------------------
-- 4. Is anything still using the legacy attachment endpoint?
--
--    The single best signal that old app builds are gone. ORDS does not log
--    this by default, so either enable ORDS request logging for a week, or
--    watch EXPENSE_ITEMS: once every recent claim has its receipts on bills
--    rather than on the claim row, the old path is unused.
--------------------------------------------------------------------------------
SELECT TRUNC(e.creation_date)                                  AS day,
       COUNT(*)                                                AS claims,
       SUM(CASE WHEN e.attachment_blob IS NOT NULL THEN 1 END) AS attached_to_claim,
       SUM(CASE WHEN EXISTS (SELECT 1 FROM expense_items i
                             WHERE i.expense_id = e.id
                             AND   i.attachment_blob IS NOT NULL)
                THEN 1 END)                                    AS attached_to_bills
FROM   expenses e
WHERE  e.creation_date > SYSDATE - 30
GROUP  BY TRUNC(e.creation_date)
ORDER  BY day DESC;

-- ATTACHED_TO_CLAIM should be zero for every recent day. A non-zero value is an
-- old build still writing to the legacy path.


--------------------------------------------------------------------------------
-- 5. THE DROPS. Uncomment only after 1, 3 and 4 are all clear.
--
-- Take a backup of EXPENSES first -- these columns hold the only remaining
-- copy of every receipt on the claim side:
--
--     CREATE TABLE expenses_pre_cleanup AS SELECT * FROM expenses;
--
-- Keep that table until you are certain. It is the difference between a mistake
-- and a disaster.
--------------------------------------------------------------------------------
/*
-- Per-bill details, now held on EXPENSE_ITEMS:
ALTER TABLE expenses DROP COLUMN bill_no;
ALTER TABLE expenses DROP COLUMN bill_date;
ALTER TABLE expenses DROP COLUMN type;
ALTER TABLE expenses DROP COLUMN description;

-- The receipt. IRREVERSIBLE -- every migrated attachment then exists only on
-- its bill. Do this one last, and only with the backup table in place.
ALTER TABLE expenses DROP COLUMN attachment_blob;
ALTER TABLE expenses DROP COLUMN attachment_filename;
ALTER TABLE expenses DROP COLUMN attachment_mime_type;

-- ATTACHMENT_PATH was never used. The receipt has always been the BLOB; this
-- column is written and read by the handlers but has never held anything
-- meaningful. Dead before this project started.
ALTER TABLE expenses DROP COLUMN attachment_path;

-- Reclaim the space the BLOBs occupied. Without this, dropping the column frees
-- nothing on disk.
ALTER TABLE expenses MOVE ONLINE;
*/


--------------------------------------------------------------------------------
-- 6. NEVER DROP THESE.
--
-- They look like the same kind of leftover and are not -- they are the claim's
-- ROLLED-UP TOTALS, written by recalc_claim_totals:
--
--   AMOUNT_USD      the total. HomeScreen sums it for every dashboard figure,
--                   and `pending` and `mine` return it. Dropping it blanks the
--                   dashboard.
--   AMOUNT          the total in mixed currencies. Not a meaningful number,
--                   but read by existing screens.
--   CURRENCY        first bill's, for display
--   EXCHANGE_RATE   first bill's, for display
--   FROM_DATE       MIN across bills -- the dashboard groups by its month
--   TO_DATE         MAX across bills
--
-- Anything new should read AMOUNT_USD, not AMOUNT.
--------------------------------------------------------------------------------
SELECT column_name, nullable, data_type
FROM   user_tab_columns
WHERE  table_name = 'EXPENSES'
ORDER  BY column_id;
