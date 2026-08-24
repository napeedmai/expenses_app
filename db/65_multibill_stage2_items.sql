--------------------------------------------------------------------------------
-- 65_multibill_stage2_items.sql
--
-- MULTIPLE BILLS PER CLAIM -- STAGE 2a: the bill endpoints.
--
-- Run as the APPLICATION SCHEMA (REPO), after 64. Idempotent.
--
--
-- ADDITIVE. NOTHING BREAKS.
-- -------------------------
-- Everything here is new: three URI templates, six handlers, three helper
-- functions and three privilege patterns. No existing handler is touched, so
-- the app keeps working exactly as it does now while this goes in.
--
-- That is possible because the legacy per-bill columns on EXPENSES survived
-- stage 1 -- section 3 of script 64 did not execute. Which turns out to be
-- lucky: the old handlers still read those columns, so the API stayed up. Do
-- NOT drop them until stage 3 ships and the app no longer reads them.
--
--
-- WHAT THIS ADDS
--   GET    :id/items                      list the bills on a claim
--   POST   :id/items                      add a bill
--   PUT    :id/items/:item_id             edit a bill
--   DELETE :id/items/:item_id             remove a bill, renumber the rest
--   POST   :id/items/:item_id/attachment  upload that bill's receipt
--   GET    :id/items/:item_id/attachment  download it
--
-- STILL TO COME, in 66:
--   POST draft            create a claim header without bill fields
--   POST :id/submit       require at least one bill, a receipt on each, claim_for
--   GET :id               return claim_for and a bill count
--
--
-- DESIGN NOTES
-- ------------
-- CONVERSION RATE IS NEVER ACCEPTED FROM THE CLIENT. price_expense_item
-- computes it from the currency and the bill's own from_date. A client-supplied
-- rate is a client-supplied reimbursement figure.
--
-- ITEM_NO is assigned server-side and renumbered on delete, so it is always
-- 1..n with no gaps. Without renumbering, deleting bill 3 of 20 would leave
-- MAX(item_no) = 20 and block adding another, because the check constraint caps
-- item_no at 20 -- a cap on the NUMBER of bills would have silently become a
-- cap on the highest number ever used.
--
-- EDITS ARE BLOCKED once a claim leaves DRAFT or REVISION_REQUESTED. Otherwise
-- an employee could alter the amounts under a reviewer who is mid-decision, or
-- after approval.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF


--------------------------------------------------------------------------------
-- 0. Right schema, and stage 1 actually ran?
--------------------------------------------------------------------------------
DECLARE
  l_schema VARCHAR2(128) := SYS_CONTEXT('USERENV','CURRENT_SCHEMA');
  l_n      NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Connected as: ' || l_schema);

  SELECT COUNT(*) INTO l_n FROM user_tables WHERE table_name = 'EXPENSE_ITEMS';
  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'EXPENSE_ITEMS not found on ' || l_schema
      || '. Run 64_multibill_stage1_clean.sql first. Nothing changed.');
  END IF;

  SELECT COUNT(*) INTO l_n FROM user_objects
  WHERE  object_name = 'RECALC_CLAIM_TOTALS' AND status = 'VALID';
  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'RECALC_CLAIM_TOTALS missing or INVALID. Re-run 64. Nothing changed.');
  END IF;

  DBMS_OUTPUT.PUT_LINE('Stage 1 present. Proceeding.');
END;
/


--------------------------------------------------------------------------------
-- 1. Helpers.
--
-- One place each for "may this person look at this claim", "may they change
-- it", and "what is this bill worth in USD". Six handlers need all three, and
-- three copies of a permission check is how one of them ends up subtly
-- different -- exactly how the finance-manager bug happened.
--------------------------------------------------------------------------------

-- Owner, or the reviewer whose turn it is. get_reviewer_role already answers
-- the second question correctly, including the case where one person is both
-- project manager and finance manager.
CREATE OR REPLACE FUNCTION can_view_claim(
  p_expense_id IN NUMBER,
  p_emp_id     IN NUMBER
) RETURN VARCHAR2 IS
  l_owner NUMBER;
BEGIN
  SELECT emp_id INTO l_owner FROM expenses WHERE id = p_expense_id;
  IF l_owner = p_emp_id THEN
    RETURN 'Y';
  END IF;
  RETURN CASE WHEN get_reviewer_role(p_expense_id, p_emp_id) IS NOT NULL
              THEN 'Y' ELSE 'N' END;
EXCEPTION
  WHEN NO_DATA_FOUND THEN RETURN 'N';
END can_view_claim;
/

-- Only the owner, and only while the claim is theirs to change. A reviewer
-- never edits bills -- they accept, revise or reject the claim as a whole.
CREATE OR REPLACE FUNCTION can_edit_claim(
  p_expense_id IN NUMBER,
  p_emp_id     IN NUMBER
) RETURN VARCHAR2 IS
  l_owner  NUMBER;
  l_status VARCHAR2(30);
BEGIN
  SELECT emp_id, status INTO l_owner, l_status
  FROM   expenses WHERE id = p_expense_id;

  IF l_owner != p_emp_id THEN
    RETURN 'N';
  END IF;
  RETURN CASE WHEN l_status IN ('DRAFT', 'REVISION_REQUESTED')
              THEN 'Y' ELSE 'N' END;
EXCEPTION
  WHEN NO_DATA_FOUND THEN RETURN 'N';
END can_edit_claim;
/

-- Price a bill. OUT params rather than two function calls so the rate and the
-- amount can never come from different lookups.
--
-- Raises if no rate covers that currency and month: EXCHANGE_RATE and
-- AMOUNT_USD are NOT NULL on EXPENSE_ITEMS, and an unpriced bill would drop
-- out of the claim total without anyone noticing.
CREATE OR REPLACE PROCEDURE price_expense_item(
  p_amount    IN  NUMBER,
  p_currency  IN  VARCHAR2,
  p_from_date IN  DATE,
  p_rate      OUT NUMBER,
  p_usd       OUT NUMBER
) IS
BEGIN
  p_rate := get_exchange_rate(p_currency, p_from_date);
  p_usd  := convert_to_usd(p_amount, p_currency, p_from_date);

  IF p_rate IS NULL OR p_usd IS NULL THEN
    RAISE_APPLICATION_ERROR(-20030,
      'No exchange rate for ' || p_currency || ' in '
      || TO_CHAR(p_from_date, 'Mon YYYY')
      || '. Load a CURRENCY_CONVERSION row for that currency, or pick another.');
  END IF;
END price_expense_item;
/


--------------------------------------------------------------------------------
-- 2. URI templates.
--
-- Three, not six: a template is a URL shape, and GET/POST or PUT/DELETE on the
-- same shape share one. DEFINE_TEMPLATE is safe to re-run.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => ':id/items');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => ':id/items/:item_id');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => ':id/items/:item_id/attachment');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Templates defined.');
END;
/


--------------------------------------------------------------------------------
-- 3. GET :id/items -- list the bills.
--
--    Visible to the owner and to whichever reviewer's turn it is; a reviewer
--    approving a multi-bill claim has to see all of it.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => ':id/items',
    p_method      => 'GET',
    p_source_type => ords.source_type_collection_feed,
    p_source      => q'[
      SELECT i.id, i.item_no, i.bill_no,
             TO_CHAR(i.bill_date, 'MM/DD/YYYY') AS bill_date,
             TO_CHAR(i.from_date, 'MM/DD/YYYY') AS from_date,
             TO_CHAR(i.to_date,   'MM/DD/YYYY') AS to_date,
             i.type, i.description,
             i.currency, i.amount, i.exchange_rate, i.amount_usd,
             i.attachment_filename, i.attachment_mime_type,
             CASE WHEN i.attachment_blob IS NULL THEN 'N' ELSE 'Y' END AS has_receipt,
             DBMS_LOB.GETLENGTH(i.attachment_blob) AS receipt_bytes
      FROM   expense_items i
      WHERE  i.expense_id = :id
      AND    is_valid_session_token(TO_NUMBER(:emp_id_hdr), :session_token_hdr) = 'Y'
      AND    can_view_claim(:id, TO_NUMBER(:emp_id_hdr)) = 'Y'
      ORDER  BY i.item_no
    ]'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/items', p_method => 'GET',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/items', p_method => 'GET',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 4. POST :id/items -- add a bill.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name   => 'expenses.employee',
    p_pattern       => ':id/items',
    p_method        => 'POST',
    p_source_type   => ords.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source        => q'[
      DECLARE
        c_max_items CONSTANT NUMBER := 20;
        l_body      CLOB   := :body_text;
        l_emp_id    NUMBER := TO_NUMBER(:emp_id_hdr);
        l_count     NUMBER;
        l_item_no   NUMBER;
        l_new_id    NUMBER;
        l_bill_no   VARCHAR2(100)  := JSON_VALUE(l_body, '$.bill_no');
        l_bill_date DATE           := TO_DATE(JSON_VALUE(l_body, '$.bill_date'), 'YYYY-MM-DD');
        l_type      VARCHAR2(100)  := JSON_VALUE(l_body, '$.type');
        l_descr     VARCHAR2(4000) := JSON_VALUE(l_body, '$.description');
        l_from      DATE           := TO_DATE(JSON_VALUE(l_body, '$.from_date'), 'YYYY-MM-DD');
        l_to        DATE           := TO_DATE(JSON_VALUE(l_body, '$.to_date'), 'YYYY-MM-DD');
        l_currency  VARCHAR2(3)    := UPPER(JSON_VALUE(l_body, '$.currency'));
        l_amount    NUMBER         := TO_NUMBER(JSON_VALUE(l_body, '$.amount'));
        l_rate      NUMBER;
        l_usd       NUMBER;
      BEGIN
        IF l_emp_id IS NULL THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error','Missing or invalid X-Emp-Id header'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;
        IF is_valid_session_token(l_emp_id, :session_token_hdr) != 'Y' THEN
          :status := 401;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error','Session expired or invalid. Please log in again.'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;
        IF can_edit_claim(:id, l_emp_id) != 'Y' THEN
          :status := 403;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error','This claim is not yours to change, or it has already been submitted.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        -- Everything except bill_no is required. Reported in one message so the
        -- app does not have to round-trip once per missing field.
        DECLARE
          l_missing VARCHAR2(400);
        BEGIN
          IF l_bill_date IS NULL THEN l_missing := l_missing || 'bill_date '; END IF;
          IF l_type      IS NULL THEN l_missing := l_missing || 'type ';      END IF;
          IF l_descr     IS NULL THEN l_missing := l_missing || 'description '; END IF;
          IF l_from      IS NULL THEN l_missing := l_missing || 'from_date '; END IF;
          IF l_to        IS NULL THEN l_missing := l_missing || 'to_date ';   END IF;
          IF l_currency  IS NULL THEN l_missing := l_missing || 'currency ';  END IF;
          IF l_amount    IS NULL THEN l_missing := l_missing || 'amount ';    END IF;
          IF l_missing IS NOT NULL THEN
            :status := 400;
            APEX_JSON.OPEN_OBJECT;
            APEX_JSON.WRITE('error','Missing required field(s): ' || TRIM(l_missing));
            APEX_JSON.CLOSE_OBJECT;
            RETURN;
          END IF;
        END;

        IF l_amount <= 0 THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error','Amount must be greater than zero.'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;
        IF l_to < l_from THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error','To Date cannot be before From Date.'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        SELECT COUNT(*) INTO l_count FROM expense_items WHERE expense_id = :id;
        IF l_count >= c_max_items THEN
          :status := 409;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error','A claim can hold at most ' || c_max_items
            || ' bills. Submit this one and start another.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        -- Rate and USD are computed here, never taken from the request.
        price_expense_item(l_amount, l_currency, l_from, l_rate, l_usd);

        SELECT NVL(MAX(item_no), 0) + 1 INTO l_item_no
        FROM   expense_items WHERE expense_id = :id;

        INSERT INTO expense_items (
          expense_id, item_no, bill_no, bill_date, type, description,
          from_date, to_date, currency, amount, exchange_rate, amount_usd,
          created_by, last_updated_by)
        VALUES (:id, l_item_no, l_bill_no, l_bill_date, l_type, l_descr,
          l_from, l_to, l_currency, l_amount, l_rate, l_usd,
          l_emp_id, l_emp_id)
        RETURNING id INTO l_new_id;

        recalc_claim_totals(:id);

        :status := 201;
        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.WRITE('id', l_new_id);
        APEX_JSON.WRITE('item_no', l_item_no);
        APEX_JSON.WRITE('exchange_rate', l_rate);
        APEX_JSON.WRITE('amount_usd', l_usd);
        APEX_JSON.WRITE('bills_on_claim', l_count + 1);
        APEX_JSON.CLOSE_OBJECT;
      EXCEPTION
        WHEN OTHERS THEN
          -- -20030 is price_expense_item's "no rate" -- the user can act on
          -- that one, so give them the message rather than a generic 500.
          IF SQLCODE = -20030 THEN
            :status := 400;
            APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', SQLERRM); APEX_JSON.CLOSE_OBJECT;
          ELSE
            :status := 400;
            APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', SQLERRM); APEX_JSON.CLOSE_OBJECT;
          END IF;
      END;
    ]'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/items', p_method => 'POST',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/items', p_method => 'POST',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/items', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT');
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 5. PUT :id/items/:item_id -- edit a bill.
--
--    Recomputes the rate every time, because changing the currency, the amount
--    or from_date all change what the bill is worth. Recomputing from the
--    STORED row afterwards, not from the request, is what keeps a client from
--    supplying its own rate.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name   => 'expenses.employee',
    p_pattern       => ':id/items/:item_id',
    p_method        => 'PUT',
    p_source_type   => ords.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source        => q'[
      DECLARE
        l_body     CLOB   := :body_text;
        l_emp_id   NUMBER := TO_NUMBER(:emp_id_hdr);
        l_n        NUMBER;
        l_currency VARCHAR2(3);
        l_amount   NUMBER;
        l_from     DATE;
        l_rate     NUMBER;
        l_usd      NUMBER;
      BEGIN
        IF is_valid_session_token(l_emp_id, :session_token_hdr) != 'Y' THEN
          :status := 401;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error','Session expired or invalid. Please log in again.'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;
        IF can_edit_claim(:id, l_emp_id) != 'Y' THEN
          :status := 403;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error','This claim is not yours to change, or it has already been submitted.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        SELECT COUNT(*) INTO l_n FROM expense_items
        WHERE  id = :item_id AND expense_id = :id;
        IF l_n = 0 THEN
          :status := 404;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error','No such bill on this claim.'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        -- NVL against the current value: an omitted field means "leave it",
        -- so the app can send only what changed.
        UPDATE expense_items
        SET    bill_no     = NVL(JSON_VALUE(l_body,'$.bill_no'), bill_no),
               bill_date   = NVL(TO_DATE(JSON_VALUE(l_body,'$.bill_date'),'YYYY-MM-DD'), bill_date),
               type        = NVL(JSON_VALUE(l_body,'$.type'), type),
               description = NVL(JSON_VALUE(l_body,'$.description'), description),
               from_date   = NVL(TO_DATE(JSON_VALUE(l_body,'$.from_date'),'YYYY-MM-DD'), from_date),
               to_date     = NVL(TO_DATE(JSON_VALUE(l_body,'$.to_date'),'YYYY-MM-DD'), to_date),
               currency    = NVL(UPPER(JSON_VALUE(l_body,'$.currency')), currency),
               amount      = NVL(TO_NUMBER(JSON_VALUE(l_body,'$.amount')), amount),
               last_update_date = SYSDATE,
               last_updated_by  = l_emp_id
        WHERE  id = :item_id AND expense_id = :id;

        -- Re-price from what is now STORED, not from the request body.
        SELECT currency, amount, from_date INTO l_currency, l_amount, l_from
        FROM   expense_items WHERE id = :item_id;

        price_expense_item(l_amount, l_currency, l_from, l_rate, l_usd);

        UPDATE expense_items
        SET    exchange_rate = l_rate, amount_usd = l_usd
        WHERE  id = :item_id;

        recalc_claim_totals(:id);

        :status := 200;
        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.WRITE('id', :item_id);
        APEX_JSON.WRITE('exchange_rate', l_rate);
        APEX_JSON.WRITE('amount_usd', l_usd);
        APEX_JSON.CLOSE_OBJECT;
      EXCEPTION
        WHEN OTHERS THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', SQLERRM); APEX_JSON.CLOSE_OBJECT;
      END;
    ]'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/items/:item_id', p_method => 'PUT',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/items/:item_id', p_method => 'PUT',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/items/:item_id', p_method => 'PUT',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT');
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 6. DELETE :id/items/:item_id -- remove a bill and close the gap.
--
-- The renumbering matters. item_no is capped at 20 by a check constraint, and
-- new bills take MAX(item_no)+1. Delete bill 3 of 20 without renumbering and
-- MAX stays 20, so the next insert asks for 21 and is rejected -- the cap on
-- HOW MANY bills would have quietly become a cap on how many were ever added.
--
-- Renumbering runs in descending order. Ascending would try to set an item_no
-- that a later row still holds, and expense_items_no_uq would reject it.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => ':id/items/:item_id',
    p_method      => 'DELETE',
    p_source_type => ords.source_type_plsql,
    p_source      => q'[
      DECLARE
        l_emp_id  NUMBER := TO_NUMBER(:emp_id_hdr);
        l_item_no NUMBER;
        l_left    NUMBER;
      BEGIN
        IF is_valid_session_token(l_emp_id, :session_token_hdr) != 'Y' THEN
          :status := 401;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error','Session expired or invalid. Please log in again.'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;
        IF can_edit_claim(:id, l_emp_id) != 'Y' THEN
          :status := 403;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error','This claim is not yours to change, or it has already been submitted.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        BEGIN
          SELECT item_no INTO l_item_no FROM expense_items
          WHERE  id = :item_id AND expense_id = :id;
        EXCEPTION
          WHEN NO_DATA_FOUND THEN
            :status := 404;
            APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error','No such bill on this claim.'); APEX_JSON.CLOSE_OBJECT;
            RETURN;
        END;

        DELETE FROM expense_items WHERE id = :item_id;

        FOR r IN (SELECT id, item_no FROM expense_items
                  WHERE  expense_id = :id AND item_no > l_item_no
                  ORDER  BY item_no ASC)
        LOOP
          UPDATE expense_items SET item_no = r.item_no - 1 WHERE id = r.id;
        END LOOP;

        recalc_claim_totals(:id);

        SELECT COUNT(*) INTO l_left FROM expense_items WHERE expense_id = :id;

        :status := 200;
        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.WRITE('deleted', :item_id);
        APEX_JSON.WRITE('bills_on_claim', l_left);
        APEX_JSON.CLOSE_OBJECT;
      EXCEPTION
        WHEN OTHERS THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', SQLERRM); APEX_JSON.CLOSE_OBJECT;
      END;
    ]'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/items/:item_id', p_method => 'DELETE',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/items/:item_id', p_method => 'DELETE',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/items/:item_id', p_method => 'DELETE',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT');
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 7. POST :id/items/:item_id/attachment -- upload the receipt.
--
--    Mirrors the existing claim-level upload: same 1 MB cap, same MIME
--    whitelist via is_allowed_attachment.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => ':id/items/:item_id/attachment',
    p_method      => 'POST',
    p_source_type => ords.source_type_plsql,
    p_source      => q'[
      DECLARE
        c_max_bytes CONSTANT NUMBER := 1048576;
        l_emp_id    NUMBER := TO_NUMBER(:emp_id_hdr);
        l_blob      BLOB   := :body;
        l_name      VARCHAR2(300) := :file_name_hdr;
        l_mime      VARCHAR2(150) := :content_type_hdr;
        l_n         NUMBER;
      BEGIN
        IF is_valid_session_token(l_emp_id, :session_token_hdr) != 'Y' THEN
          :status := 401;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error','Session expired or invalid. Please log in again.'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;
        IF can_edit_claim(:id, l_emp_id) != 'Y' THEN
          :status := 403;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error','This claim is not yours to change, or it has already been submitted.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        SELECT COUNT(*) INTO l_n FROM expense_items
        WHERE  id = :item_id AND expense_id = :id;
        IF l_n = 0 THEN
          :status := 404;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error','No such bill on this claim.'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        IF l_blob IS NULL OR DBMS_LOB.GETLENGTH(l_blob) = 0 THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error','No file received.'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;
        IF DBMS_LOB.GETLENGTH(l_blob) > c_max_bytes THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error','Receipt is larger than 1 MB.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;
        IF is_allowed_attachment(l_mime) = 'N' THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error','File type not allowed. Use pdf, jpg, png, xlsx, xls, csv or rar.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        UPDATE expense_items
        SET    attachment_blob      = l_blob,
               attachment_filename  = l_name,
               attachment_mime_type = l_mime,
               last_update_date     = SYSDATE,
               last_updated_by      = l_emp_id
        WHERE  id = :item_id AND expense_id = :id;

        :status := 200;
        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.WRITE('id', :item_id);
        APEX_JSON.WRITE('filename', l_name);
        APEX_JSON.WRITE('bytes', DBMS_LOB.GETLENGTH(l_blob));
        APEX_JSON.CLOSE_OBJECT;
      EXCEPTION
        WHEN OTHERS THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', SQLERRM); APEX_JSON.CLOSE_OBJECT;
      END;
    ]'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/items/:item_id/attachment', p_method => 'POST',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/items/:item_id/attachment', p_method => 'POST',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/items/:item_id/attachment', p_method => 'POST',
    p_name => 'X-File-Name', p_bind_variable_name => 'file_name_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/items/:item_id/attachment', p_method => 'POST',
    p_name => 'Content-Type', p_bind_variable_name => 'content_type_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/items/:item_id/attachment', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT');
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 8. GET :id/items/:item_id/attachment -- download the receipt.
--
--    Readable by the owner and the reviewer whose turn it is, via
--    can_view_claim. The Content-Type comes from the stored MIME type so the
--    phone knows what it is -- the app then decides whether to show it inline
--    or hand it to another app (src/utils/openAttachment.js).
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => ':id/items/:item_id/attachment',
    p_method      => 'GET',
    p_source_type => ords.source_type_media,
    p_source      => q'[
      SELECT i.attachment_mime_type, i.attachment_blob
      FROM   expense_items i
      WHERE  i.id = :item_id
      AND    i.expense_id = :id
      AND    i.attachment_blob IS NOT NULL
      AND    is_valid_session_token(TO_NUMBER(:emp_id_hdr), :session_token_hdr) = 'Y'
      AND    can_view_claim(:id, TO_NUMBER(:emp_id_hdr)) = 'Y'
    ]'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/items/:item_id/attachment', p_method => 'GET',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/items/:item_id/attachment', p_method => 'GET',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 9. Privileges.
--
-- THREE NEW PATTERNS MUST BE PROTECTED. A URI that no privilege matches is
-- reachable by anyone -- see DEPLOYMENT.md 13.2. This rebuilds
-- expenses.authenticated by reading the patterns it already has and adding the
-- new ones, so nothing existing is lost and re-running is harmless.
--
-- ORDS has no "add one pattern" call: DEFINE_PRIVILEGE replaces the whole set,
-- so the existing set has to be read back first.
--------------------------------------------------------------------------------
DECLARE
  l_roles    owa.vc_arr;
  l_patterns owa.vc_arr;
  r          PLS_INTEGER := 0;
  p          PLS_INTEGER := 0;

  FUNCTION has_pattern(p_pat IN VARCHAR2) RETURN BOOLEAN IS
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n
    FROM   user_ords_privilege_mappings pm
    JOIN   user_ords_privileges pr ON pr.id = pm.privilege_id
    WHERE  pr.name = 'expenses.authenticated' AND pm.pattern = p_pat;
    RETURN l_n > 0;
  END;
BEGIN
  -- Existing roles, read rather than hardcoded: role names differ between
  -- environments and a wrong one locks out every protected endpoint.
  FOR x IN (SELECT DISTINCT role_name FROM user_ords_privilege_roles pr
            JOIN user_ords_privileges p ON p.id = pr.privilege_id
            WHERE p.name = 'expenses.authenticated' ORDER BY role_name)
  LOOP
    r := r + 1; l_roles(r) := x.role_name;
  END LOOP;

  IF r = 0 THEN
    RAISE_APPLICATION_ERROR(-20002,
      'Privilege expenses.authenticated has no roles -- refusing to rebuild it '
      || 'and lock everyone out. Check PROD_2_ords_and_security_setup.sql.');
  END IF;

  FOR x IN (SELECT pm.pattern FROM user_ords_privilege_mappings pm
            JOIN user_ords_privileges pr ON pr.id = pm.privilege_id
            WHERE pr.name = 'expenses.authenticated' ORDER BY pm.pattern)
  LOOP
    p := p + 1; l_patterns(p) := x.pattern;
  END LOOP;

  FOR np IN (SELECT column_value AS pat FROM TABLE(sys.odcivarchar2list(
               '/expenses/:id/items',
               '/expenses/:id/items/:item_id',
               '/expenses/:id/items/:item_id/attachment')))
  LOOP
    IF NOT has_pattern(np.pat) THEN
      p := p + 1; l_patterns(p) := np.pat;
      DBMS_OUTPUT.PUT_LINE('  adding pattern ' || np.pat);
    END IF;
  END LOOP;

  ORDS.DELETE_PRIVILEGE(p_name => 'expenses.authenticated');
  ORDS.DEFINE_PRIVILEGE(
    p_privilege_name => 'expenses.authenticated',
    p_roles          => l_roles,
    p_patterns       => l_patterns,
    p_label          => 'Expense App - Authenticated Access',
    p_description    => 'Any signed-in employee or reviewer may call these. '
      || 'Row-level ownership and stage checks happen in the handlers. '
      || 'auth/login is deliberately excluded -- a pattern covering it makes '
      || 'login impossible.');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Privilege rebuilt: ' || p || ' pattern(s), ' || r || ' role(s).');
END;
/


--------------------------------------------------------------------------------
-- 10. Verify.
--------------------------------------------------------------------------------
SELECT object_name, object_type, status
FROM   user_objects
WHERE  object_name IN ('CAN_VIEW_CLAIM','CAN_EDIT_CLAIM','PRICE_EXPENSE_ITEM',
                       'RECALC_CLAIM_TOTALS')
ORDER  BY object_name;

-- Six new handlers, on three templates.
SELECT t.uri_template, h.method, h.source_type
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND    t.uri_template LIKE ':id/items%'
ORDER  BY t.uri_template, h.method;

-- No template without a handler -- a registered URL that answers but runs
-- nothing.
SELECT t.uri_template, COUNT(h.id) AS handlers
FROM   user_ords_templates t
JOIN   user_ords_modules m ON m.id = t.module_id
LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
WHERE  m.name = 'expenses.employee'
GROUP  BY t.uri_template
ORDER  BY handlers, t.uri_template;

-- All three new patterns must be protected.
SELECT pm.pattern, pr.name AS privilege
FROM   user_ords_privilege_mappings pm
JOIN   user_ords_privileges pr ON pr.id = pm.privilege_id
WHERE  pm.pattern LIKE '/expenses/:id/items%'
ORDER  BY pm.pattern;

-- Must return NO rows: a wildcard would also match auth/login.
SELECT pm.pattern FROM user_ords_privilege_mappings pm
WHERE  pm.pattern LIKE '/expenses/%*%' OR pm.pattern = '/expenses/*';


--------------------------------------------------------------------------------
-- NEXT: 66 finishes stage 2 --
--   POST draft       create a claim header with no bill fields
--   PUT :id          accept claim_for
--   GET :id          return claim_for and a bill count
--   POST :id/submit  at least one bill, a receipt on every bill, claim_for set
--
-- Nothing here changes existing behaviour, so the app keeps working until then.
--
-- MANUAL TEST, once 66 is in. Against a DRAFT claim you own:
--   POST   /expenses/{id}/items      {"bill_date":"2026-08-01","type":"Taxi",
--                                     "description":"Airport","from_date":"2026-08-01",
--                                     "to_date":"2026-08-01","currency":"INR","amount":450}
--     -> 201 with exchange_rate and amount_usd filled in by the server
--   GET    /expenses/{id}/items      -> the bill, has_receipt N
--   POST   .../items/{itemId}/attachment  -> 200, has_receipt becomes Y
--   DELETE .../items/{itemId}        -> 200, and the claim total returns to null
--
-- Then check the rollup:
--   SELECT id, amount, amount_usd, from_date, to_date FROM expenses WHERE id = ...;
--------------------------------------------------------------------------------
