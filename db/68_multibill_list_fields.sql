--------------------------------------------------------------------------------
-- 68_multibill_list_fields.sql
--
-- MULTIPLE BILLS PER CLAIM -- STAGE 2c: the two list endpoints.
--
-- Run as the APPLICATION SCHEMA (REPO), after 64-66, in SQL SCRIPTS. Idempotent.
--
--
-- WHY THIS IS NEEDED
-- ------------------
-- GET /expenses/mine and GET /expenses/pending were never updated for the new
-- shape. Neither returns AMOUNT_USD at all -- they predate the currency feature
-- being the source of truth -- so:
--
--   * My Expenses shows the mixed-currency AMOUNT, which since stage 1 is a sum
--     across currencies: 99 INR plus 50 EUR displayed as "149". A number in no
--     currency at all.
--
--   * The review screen renders the claim total from the pending payload. With
--     no amount_usd in it that reads "$undefined" -- a reviewer being asked to
--     approve a figure the screen cannot show.
--
-- Neither returns CLAIM_FOR either, so a reviewer cannot see what the claim was
-- for, and My Expenses falls back to the word "Expense" for every row now that
-- the claim-level TYPE is no longer written.
--
-- Both handlers are copied byte for byte from PROD_4_endpoints.sql with only
-- the select list extended. ORDS.DEFINE_HANDLER replaces the whole handler, so
-- anything missing from the replacement is silently deleted from the live
-- endpoint.
--
-- ADDED TO BOTH: claim_for, currency, amount_usd, item_count
-- ADDED TO pending ALSO: exchange_rate
--
-- item_count is a scalar subquery rather than a join, so a claim with no bills
-- still appears -- with a LEFT JOIN plus GROUP BY it is easy to lose those, and
-- a draft with no bills is exactly what someone needs to find and finish.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF


--------------------------------------------------------------------------------
-- 0. Right schema?
--------------------------------------------------------------------------------
DECLARE
  l_n NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Connected as: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
  SELECT COUNT(*) INTO l_n FROM user_tables WHERE table_name = 'EXPENSE_ITEMS';
  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001, 'EXPENSE_ITEMS missing -- run 64 first. Nothing changed.');
  END IF;
  SELECT COUNT(*) INTO l_n FROM user_tab_columns
  WHERE table_name = 'EXPENSES' AND column_name = 'CLAIM_FOR';
  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001, 'EXPENSES.CLAIM_FOR missing -- run 64 first. Nothing changed.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('OK.');
END;
/


--------------------------------------------------------------------------------
-- 1. GET /expenses/mine
--------------------------------------------------------------------------------

BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'mine',
    p_method      => 'GET',
    p_source_type => ords.source_type_collection_feed,
    p_source      => q'[
      SELECT 'expenses/' || e.id "$.id",
             e.id, e.bill_no,
             TO_CHAR(e.bill_date, 'MM/DD/YYYY') bill_date,
             TO_CHAR(e.from_date, 'MM/DD/YYYY') from_date,
             TO_CHAR(e.to_date, 'MM/DD/YYYY') to_date,
             e.project_id,
             e.type, e.amount, e.description, e.attachment_filename,
             e.claim_for, e.currency, e.amount_usd,
             (SELECT COUNT(*) FROM expense_items i WHERE i.expense_id = e.id) AS item_count,
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
END;
/


--------------------------------------------------------------------------------
-- 2. GET /expenses/pending
--------------------------------------------------------------------------------

BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'pending',
    p_method      => 'GET',
    p_source_type => ords.source_type_collection_feed,
    p_source      => q'[
      SELECT 'expenses/' || e.id "$.id",
             e.id, e.emp_id,
             emp.first_name || ' ' || emp.last_name AS emp_name,
             e.bill_no,
             TO_CHAR(e.bill_date, 'MM/DD/YYYY') bill_date,
             TO_CHAR(e.from_date, 'MM/DD/YYYY') from_date,
             TO_CHAR(e.to_date, 'MM/DD/YYYY') to_date,
             e.project_id, pm.project_name,
             e.type, e.amount, e.description, e.current_stage,
             e.claim_for, e.currency, e.amount_usd, e.exchange_rate,
             (SELECT COUNT(*) FROM expense_items i WHERE i.expense_id = e.id) AS item_count,
             e.submitted_at, e.attachment_filename
      FROM   expenses e
      JOIN   employeedetails emp ON emp.empid = e.emp_id
      LEFT   JOIN projectmaster pm ON pm.project_id = e.project_id
      WHERE  e.status = 'SUBMITTED'
      AND    is_valid_session_token(TO_NUMBER(:emp_id_hdr), :session_token_hdr) = 'Y'
      AND (
            (e.current_stage = 'MANAGER' AND e.manager_empid = TO_NUMBER(:emp_id_hdr))
         OR (e.current_stage = 'FINANCE' AND is_finance_manager(TO_NUMBER(:emp_id_hdr)) = 'Y')
      )
      ORDER BY e.creation_date ASC
    ]'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'pending', p_method => 'GET',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'pending', p_method => 'GET',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 3. Verify.
--------------------------------------------------------------------------------
SELECT t.uri_template, h.method,
       CASE WHEN INSTR(h.source,'claim_for')  > 0 THEN 'Y' ELSE 'N' END AS has_claim_for,
       CASE WHEN INSTR(h.source,'amount_usd') > 0 THEN 'Y' ELSE 'N' END AS has_amount_usd,
       CASE WHEN INSTR(h.source,'item_count') > 0 THEN 'Y' ELSE 'N' END AS has_item_count
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND    t.uri_template IN ('mine','pending',':id')
ORDER  BY t.uri_template, h.method;

-- All three should be Y for mine GET, pending GET and :id GET.

-- No template left without a handler.
SELECT t.uri_template, COUNT(h.id) AS handlers
FROM   user_ords_templates t
JOIN   user_ords_modules m ON m.id = t.module_id
LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
WHERE  m.name = 'expenses.employee'
GROUP  BY t.uri_template HAVING COUNT(h.id) = 0;


--------------------------------------------------------------------------------
-- 4. Check it by hand.
--
--   GET /expenses/mine      -> each row has claim_for, amount_usd, item_count
--   GET /expenses/pending    -> same, as the reviewer
--
-- A claim with two bills in different currencies should show amount_usd as the
-- SUM and item_count 2, while `amount` is the meaningless mixed-currency total
-- that nothing new should read.
--------------------------------------------------------------------------------
