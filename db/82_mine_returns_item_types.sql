--------------------------------------------------------------------------------
-- 82_mine_returns_item_types.sql
--
-- Run as the APPLICATION SCHEMA, in SQL SCRIPTS. Idempotent.
-- Run AFTER 71_handlers_drop_legacy_columns.sql.
--
--   dev  = karyasiddhitest.trinamix.com, schema HRMS
--   prod = karyasiddhi.trinamix.com,     schema REPO
--
--
-- "WHERE IT'S GOING" HAS BEEN SHOWING NOTHING BUT "OTHER"
-- -------------------------------------------------------
-- HomeScreen.js builds the category breakdown from `e.type`:
--
--   const key = e.type || 'Other';
--
-- Script 64 dropped TYPE from EXPENSES -- it moved to EXPENSE_ITEMS, because
-- since multi-bill a claim has one type PER BILL rather than one overall. So
-- `mine` stopped returning it, `e.type` became undefined, and every claim fell
-- through to the fallback. The chart has been drawing a single bar labelled
-- "Other" ever since, which reads as "we have no data" rather than as a bug,
-- which is why it went unnoticed.
--
-- This is the same class of fault as 70 and 71: a column moved and the things
-- that read it were never followed up. The difference is that those failed
-- loudly with a 403 and this one failed quietly with a plausible-looking chart.
--
--
-- WHY A STRING RATHER THAN ONE "top_type" COLUMN
-- ----------------------------------------------
-- The obvious cheap fix is to return the type of the biggest bill and file the
-- whole claim under it. That is wrong in the ordinary case: a trip with a $600
-- air fare and a $500 hotel would report $1,100 of Air Fare and no hotel spend
-- at all. A breakdown that is confidently wrong is worse than one that says
-- "Other", because nobody checks it.
--
-- So `mine` now returns the claim's per-type totals, already grouped:
--
--   type_totals = "Air Fare=600|Hotel=500"
--
-- The client splits on | and = and sums across claims. Exact, one extra scalar
-- subquery, no new endpoint and no extra round trip -- the alternative was a
-- separate items call per claim, which is N requests to draw three bars.
--
-- Length is not a concern. The subquery groups BY TYPE, so its row count is the
-- number of DISTINCT types on one claim -- at most a handful, and hard-capped
-- because a claim holds at most 20 bills (ck_items_itemno). ON OVERFLOW
-- TRUNCATE is there so that an implausible claim degrades to a short breakdown
-- instead of raising ORA-01489 and taking the whole expense list down with it.
--
-- AMOUNT_USD is read from the ITEM, not apportioned from the claim. It is
-- NOT NULL on EXPENSE_ITEMS and set by price_expense_item at write time, so it
-- is the authoritative per-bill figure. SUM(items.amount_usd) should equal
-- e.amount_usd -- recalc_claim_totals maintains exactly that -- and section 3
-- checks it rather than assuming it.
--
--
-- THE CLIENT KEEPS ITS FALLBACK
-- -----------------------------
-- HomeScreen falls back to `e.type || 'Other'` when type_totals is absent, so
-- the app works against an environment where this script has not been run yet.
-- Prod is that environment until someone runs it there.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF


--------------------------------------------------------------------------------
-- 1. Confirm the premise before changing anything.
--
-- Read-only. If ref_type is 1 the handler already returns a type and this
-- script is solving a problem that does not exist here.
--------------------------------------------------------------------------------
SELECT SYS_CONTEXT('USERENV','CURRENT_SCHEMA') AS schema_name,
       CASE SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
            WHEN 'HRMS' THEN 'dev' WHEN 'REPO' THEN '** PRODUCTION **'
            ELSE 'unrecognised' END AS environment
FROM   dual;

SELECT COUNT(*) AS mine_handlers,
       MAX(CASE WHEN DBMS_LOB.INSTR(source, 'type_totals') > 0
                THEN 'YES' ELSE 'no' END) AS already_returns_types
FROM   user_ords_handlers
WHERE  module_name = 'expenses.employee'
AND    uri_pattern = 'mine'
AND    method      = 'GET';
-- Expect 1 handler, already_returns_types = no.


--------------------------------------------------------------------------------
-- 2. Redefine GET /expenses/mine.
--
-- Everything else is copied verbatim from 71. DEFINE_HANDLER replaces the whole
-- handler -- there is no "add one column" call -- so the entire query has to be
-- restated, and the two header PARAMETERS with it: they hang off the handler
-- and are dropped with it. 71 re-declares them for the same reason. Forgetting
-- them would leave :emp_id_hdr unbound and every request would 500.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'mine',
    p_method      => 'GET',
    p_source_type => ords.source_type_collection_feed,
    p_source      => q'[
      SELECT 'expenses/' || e.id "$.id",
             e.id,
             TO_CHAR(e.from_date, 'MM/DD/YYYY') from_date,
             TO_CHAR(e.to_date, 'MM/DD/YYYY') to_date,
             e.project_id,
             e.claim_for, e.amount, e.currency, e.amount_usd,
             (SELECT COUNT(*) FROM expense_items i WHERE i.expense_id = e.id) AS item_count,
             (SELECT LISTAGG(t.type || '=' || TO_CHAR(t.usd), '|'
                             ON OVERFLOW TRUNCATE WITHOUT COUNT)
                       WITHIN GROUP (ORDER BY t.usd DESC)
                FROM  (SELECT i.type, SUM(i.amount_usd) AS usd
                       FROM   expense_items i
                       WHERE  i.expense_id = e.id
                       GROUP  BY i.type) t) AS type_totals,
             e.status, e.current_stage, e.submitted_at
      FROM   expenses e
      WHERE  e.emp_id = TO_NUMBER(:emp_id_hdr)
      AND    is_valid_session_token(TO_NUMBER(:emp_id_hdr), :session_token_hdr) = 'Y'
      ORDER BY e.creation_date DESC
    ]'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'mine', p_method => 'GET',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'mine', p_method => 'GET',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('mine now returns type_totals.');
END;
/


--------------------------------------------------------------------------------
-- 3. Verify -- by running the query, not by reading the handler.
--
-- Reading back the handler source only proves the text was stored. It does not
-- prove the SQL parses, and a handler that does not parse is exactly the bare
-- 403-with-no-body that cost this project two days. So run the real expression
-- against real rows.
--------------------------------------------------------------------------------

-- a) The handler holds the new column.
SELECT method, source_type,
       CASE WHEN DBMS_LOB.INSTR(source, 'type_totals') > 0
            THEN 'present' ELSE '** MISSING **' END AS type_totals
FROM   user_ords_handlers
WHERE  module_name = 'expenses.employee' AND uri_pattern = 'mine' AND method = 'GET';

-- b) Both header parameters survived. Expect 2 rows.
SELECT name, bind_variable_name, source_type
FROM   user_ords_parameters
WHERE  module_name = 'expenses.employee' AND uri_pattern = 'mine' AND method = 'GET'
ORDER  BY name;

-- c) The expression itself, on the ten most recent claims. Any claim with
--    bills should show something like "Air Fare=600|Hotel=500". A submitted
--    claim showing NULL means it has no items, which is its own problem.
SELECT e.id, e.status,
       (SELECT COUNT(*) FROM expense_items i WHERE i.expense_id = e.id) AS items,
       (SELECT LISTAGG(t.type || '=' || TO_CHAR(t.usd), '|'
                       ON OVERFLOW TRUNCATE WITHOUT COUNT)
                 WITHIN GROUP (ORDER BY t.usd DESC)
          FROM  (SELECT i.type, SUM(i.amount_usd) AS usd
                 FROM   expense_items i
                 WHERE  i.expense_id = e.id
                 GROUP  BY i.type) t) AS type_totals
FROM   expenses e
ORDER  BY e.id DESC
FETCH  FIRST 10 ROWS ONLY;

-- d) The item totals must agree with the claim total, or the chart will not add
--    up to the month's bar and someone will reasonably conclude one of them is
--    lying. Zero rows is the pass condition. A cent of rounding is tolerated.
SELECT e.id, e.amount_usd AS claim_usd, SUM(i.amount_usd) AS items_usd,
       ROUND(e.amount_usd - SUM(i.amount_usd), 2) AS diff
FROM   expenses e
JOIN   expense_items i ON i.expense_id = e.id
GROUP  BY e.id, e.amount_usd
HAVING ABS(e.amount_usd - SUM(i.amount_usd)) > 0.01
ORDER  BY ABS(e.amount_usd - SUM(i.amount_usd)) DESC;
--
-- Rows here are NOT caused by this script. They mean recalc_claim_totals did
-- not run for those claims -- most likely rows written before script 66. Note
-- them and decide separately; the breakdown will still be right per type.


--------------------------------------------------------------------------------
-- 4. Then look at the app.
--
-- Home > "Where it's going", with a month that has approved claims selected.
-- Expect up to three real category names. If it still says "Other", the bundle
-- is stale before the API is wrong -- that has now happened twice on this
-- project. Check the Network tab for type_totals in the /expenses/mine
-- response BEFORE changing any code.
--
-- On prod: run this whenever convenient. It only adds a column, so nothing
-- breaks if the app there is older than the change.
--------------------------------------------------------------------------------
