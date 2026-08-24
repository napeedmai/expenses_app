--------------------------------------------------------------------------------
-- 66_multibill_stage2_claims.sql
--
-- MULTIPLE BILLS PER CLAIM -- STAGE 2b: the claim endpoints.
--
-- Run as the APPLICATION SCHEMA (REPO), after 64 and 65, in SQL SCRIPTS
-- (SQL Workshop > SQL Scripts) -- NOT SQL Commands. Idempotent.
--
--
-- WHAT CHANGES
-- ------------
--   POST draft       creates a CLAIM HEADER: project + claim_for. No bill
--                    fields. from_date/to_date/amount are no longer accepted
--   PUT  :id         claim header only -- project, claim_for, description
--   GET  :id         adds claim_for, the USD total, a bill count, and a count
--                    of bills with no receipt
--   POST :id/submit  refuses a claim with no bills, or any bill without a
--                    receipt, or no claim_for
--
-- Each body below is copied BYTE FOR BYTE from PROD_4_endpoints.sql with only
-- the marked parts changed. ORDS.DEFINE_HANDLER replaces the WHOLE handler, so
-- anything missing from the replacement is silently deleted from the live
-- endpoint -- retyping one of these from memory once already dropped two
-- emails and a whole branch.
--
--
-- THIS IS THE BREAKING ONE
-- ------------------------
-- Stage 2a was purely additive. This is not: after it, the installed app can
-- no longer create or edit an expense, because it sends bill fields to
-- POST draft and PUT :id and they are no longer read. Reads still work.
--
-- So the app rebuild (stage 3) should follow closely. If you need the current
-- app to keep working for a while longer, run 65 only and hold this back --
-- the item endpoints are usable on their own.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF


--------------------------------------------------------------------------------
-- 0. Right schema, and stage 2a present?
--------------------------------------------------------------------------------
DECLARE
  l_schema VARCHAR2(128) := SYS_CONTEXT('USERENV','CURRENT_SCHEMA');
  l_n      NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Connected as: ' || l_schema);

  SELECT COUNT(*) INTO l_n FROM user_tab_columns
  WHERE  table_name = 'EXPENSES' AND column_name = 'CLAIM_FOR';
  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'EXPENSES.CLAIM_FOR missing. Run 64 first. Nothing changed.');
  END IF;

  SELECT COUNT(*) INTO l_n FROM user_ords_handlers h
  JOIN   user_ords_templates t ON t.id = h.template_id
  JOIN   user_ords_modules m   ON m.id = t.module_id
  WHERE  m.name = 'expenses.employee' AND t.uri_template LIKE ':id/items%';
  IF l_n < 6 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'Only ' || l_n || ' of 6 item handlers exist. Run 65 first. Nothing changed.');
  END IF;

  DBMS_OUTPUT.PUT_LINE('Stages 1 and 2a present. Proceeding.');
END;
/


--------------------------------------------------------------------------------
-- 1. POST /expenses/draft -- create a claim header.
--
--    The idempotency logic (client_request_id) is untouched: a retried save
--    still returns the existing claim rather than creating a second one.
--------------------------------------------------------------------------------

BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'draft',
    p_method      => 'POST',
    p_source_type => ords.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source      => q'[
      DECLARE
        l_body        CLOB    := :body_text;
        l_emp_id      NUMBER  := TO_NUMBER(:emp_id_hdr);
        l_mime        VARCHAR2(150) := JSON_VALUE(l_body, '$.attachment_mime_type');
        l_client_req  VARCHAR2(64)  := JSON_VALUE(l_body, '$.client_request_id');
        l_id          NUMBER;
        l_existing_status VARCHAR2(30);
      BEGIN
        IF l_emp_id IS NULL THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'Missing or invalid X-Emp-Id header'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        IF is_valid_session_token(l_emp_id, :session_token_hdr) != 'Y' THEN
          :status := 401;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'Session expired or invalid. Please log in again.'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        IF l_client_req IS NOT NULL THEN
          BEGIN
            SELECT id, status INTO l_id, l_existing_status
            FROM   expenses
            WHERE  emp_id = l_emp_id AND client_request_id = l_client_req;

            :status := 200;
            APEX_JSON.OPEN_OBJECT;
            APEX_JSON.WRITE('id', l_id);
            APEX_JSON.WRITE('status', l_existing_status);
            APEX_JSON.WRITE('deduplicated', 'Y');
            APEX_JSON.CLOSE_OBJECT;
            RETURN;
          EXCEPTION
            WHEN NO_DATA_FOUND THEN
              NULL;
          END;
        END IF;

        IF is_allowed_attachment(l_mime) = 'N' THEN
          :status := 422;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Attachment type not allowed: ' || l_mime);
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        -- from_date, to_date and amount are NO LONGER accepted here. They
        -- belong to the bills now, and recalc_claim_totals derives the claim's
        -- values from them. A claim is created empty and gains its dates and
        -- total when its first bill is added.
        --
        -- project_id is required because it decides the reporting manager.
        -- claim_for is required by the spec but checked here rather than by a
        -- NOT NULL column, for the same reason: a draft exists before the user
        -- has finished typing.
        IF JSON_VALUE(l_body, '$.project_id' RETURNING NUMBER) IS NULL THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Missing "project_id". A claim needs a project so its reporting manager can be resolved.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        INSERT INTO expenses (
          emp_id, project_id, claim_for, description, status, client_request_id
        ) VALUES (
          l_emp_id,
          JSON_VALUE(l_body, '$.project_id' RETURNING NUMBER),
          JSON_VALUE(l_body, '$.claim_for'),
          JSON_VALUE(l_body, '$.description'),
          'DRAFT',
          l_client_req
        )
        RETURNING id INTO l_id;

        :status := 201;
        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.WRITE('id', l_id);
        APEX_JSON.WRITE('status', 'DRAFT');
        APEX_JSON.CLOSE_OBJECT;
      EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
          BEGIN
            SELECT id, status INTO l_id, l_existing_status
            FROM   expenses
            WHERE  emp_id = l_emp_id AND client_request_id = l_client_req;
            :status := 200;
            APEX_JSON.OPEN_OBJECT;
            APEX_JSON.WRITE('id', l_id);
            APEX_JSON.WRITE('status', l_existing_status);
            APEX_JSON.WRITE('deduplicated', 'Y');
            APEX_JSON.CLOSE_OBJECT;
          EXCEPTION
            WHEN OTHERS THEN
              :status := 400;
              APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', SQLERRM); APEX_JSON.CLOSE_OBJECT;
          END;
        WHEN OTHERS THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', SQLERRM);
          APEX_JSON.CLOSE_OBJECT;
      END;
    ]'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'draft', p_method => 'POST',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'draft', p_method => 'POST',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'draft', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT'
  );
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 2. PUT /expenses/{id} -- edit the claim header.
--------------------------------------------------------------------------------

BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => ':id',
    p_method      => 'PUT',
    p_source_type => ords.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source      => q'[
      DECLARE
        l_body        CLOB   := :body_text;
        l_emp_id      NUMBER := TO_NUMBER(:emp_id_hdr);
        l_owner_id    NUMBER;
        l_status      VARCHAR2(30);
        l_mime        VARCHAR2(150) := JSON_VALUE(l_body, '$.attachment_mime_type');
      BEGIN
        IF is_valid_session_token(l_emp_id, :session_token_hdr) != 'Y' THEN
          :status := 401;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'Session expired or invalid. Please log in again.'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        SELECT emp_id, status INTO l_owner_id, l_status
        FROM   expenses WHERE id = :id FOR UPDATE;

        IF l_owner_id != l_emp_id THEN
          :status := 403;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'Not your expense'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        IF l_status NOT IN ('DRAFT', 'REVISION_REQUESTED') THEN
          :status := 409;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Cannot edit an expense in status ' || l_status);
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        IF is_allowed_attachment(l_mime) = 'N' THEN
          :status := 422;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'Attachment type not allowed: ' || l_mime); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        -- CLAIM HEADER ONLY. Bill fields are edited through
        -- PUT /expenses/{id}/items/{itemId}; accepting them here would give two
        -- routes to the same fact, which is how the finance-manager id ended up
        -- living in three places and only one of them getting changed.
        --
        -- from_date, to_date and amount are deliberately absent: they are
        -- derived by recalc_claim_totals and would be overwritten anyway.
        UPDATE expenses SET
          project_id  = NVL(JSON_VALUE(l_body, '$.project_id' RETURNING NUMBER), project_id),
          claim_for   = NVL(JSON_VALUE(l_body, '$.claim_for'), claim_for),
          description = NVL(JSON_VALUE(l_body, '$.description'), description)
        WHERE id = :id;

        :status := 200;
        APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('id', :id); APEX_JSON.WRITE('status', 'UPDATED'); APEX_JSON.CLOSE_OBJECT;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          :status := 404;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'Expense not found'); APEX_JSON.CLOSE_OBJECT;
        WHEN OTHERS THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', SQLERRM); APEX_JSON.CLOSE_OBJECT;
      END;
    ]'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id', p_method => 'PUT',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id', p_method => 'PUT',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id', p_method => 'PUT',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT'
  );
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 3. GET /expenses/{id} -- claim header, totals and bill counts.
--
--    The BILLS themselves come from GET /expenses/{id}/items. This stays a
--    plain SELECT rather than being rewritten as PL/SQL to nest an array --
--    two simple calls beat one hand-assembled JSON document.
--
--    bills_without_receipt is here so the app can disable Submit and say which
--    bills are short, without fetching the whole list first.
--------------------------------------------------------------------------------

BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => ':id',
    p_method      => 'GET',
    p_source_type => ords.source_type_collection_item,
    p_source      => q'[
      SELECT e.id, e.emp_id, e.bill_no,
             TO_CHAR(e.bill_date, 'MM/DD/YYYY') bill_date,
             TO_CHAR(e.from_date, 'MM/DD/YYYY') from_date,
             TO_CHAR(e.to_date, 'MM/DD/YYYY') to_date,
             e.project_id, pm.project_name,
             e.type, e.amount, e.amount_usd, e.currency, e.exchange_rate,
             e.claim_for, e.description,
             (SELECT COUNT(*) FROM expense_items i WHERE i.expense_id = e.id) AS item_count,
             (SELECT COUNT(*) FROM expense_items i WHERE i.expense_id = e.id
              AND i.attachment_blob IS NULL) AS bills_without_receipt,
             e.attachment_path, e.attachment_filename, e.attachment_mime_type,
             e.status, e.current_stage,
             e.manager_empid, mgr.first_name || ' ' || mgr.last_name AS manager_name,
             e.finance_manager_empid, fin.first_name || ' ' || fin.last_name AS finance_manager_name,
             e.submitted_at, e.creation_date, e.last_update_date
      FROM   expenses e
      LEFT   JOIN projectmaster pm ON pm.project_id = e.project_id
      LEFT   JOIN employeedetails mgr ON mgr.empid = e.manager_empid
      LEFT   JOIN employeedetails fin ON fin.empid = e.finance_manager_empid
      WHERE  e.id = :id
      AND    e.emp_id = TO_NUMBER(:emp_id_hdr)
      AND    is_valid_session_token(TO_NUMBER(:emp_id_hdr), :session_token_hdr) = 'Y'
    ]'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id', p_method => 'GET',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id', p_method => 'GET',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 4. POST /expenses/{id}/submit -- with the new rules.
--------------------------------------------------------------------------------

BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => ':id/submit',
    p_method      => 'POST',
    p_source_type => ords.source_type_plsql,
    p_source      => q'[
      DECLARE
        l_emp_id        NUMBER := TO_NUMBER(:emp_id_hdr);
        l_owner_id      NUMBER;
        l_status        VARCHAR2(30);
        l_current_stage VARCHAR2(20);
        l_project_id    NUMBER;
        l_manager_id    NUMBER;
        l_finance_id    NUMBER;
        l_emp_email     VARCHAR2(255);
        l_mgr_email     VARCHAR2(255);
      BEGIN
        IF is_valid_session_token(l_emp_id, :session_token_hdr) != 'Y' THEN
          :status := 401;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'Session expired or invalid. Please log in again.'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        SELECT emp_id, status, current_stage, project_id, manager_empid, finance_manager_empid
        INTO   l_owner_id, l_status, l_current_stage, l_project_id, l_manager_id, l_finance_id
        FROM   expenses WHERE id = :id FOR UPDATE;

        IF l_owner_id != l_emp_id THEN
          :status := 403;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'Not your expense'); APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        -- SUBMIT RULES. Everything a bill needs was checked when the bill was
        -- saved; these are the things that can only be judged for the claim as
        -- a whole, and they are enforced HERE rather than only in the app --
        -- a client-side check is a courtesy, the handler is the rule.
        DECLARE
          l_bills      NUMBER;
          l_noreceipt  NUMBER;
          l_claim_for  VARCHAR2(400);
          l_missing    VARCHAR2(400);
        BEGIN
          SELECT COUNT(*),
                 COUNT(CASE WHEN attachment_blob IS NULL THEN 1 END)
          INTO   l_bills, l_noreceipt
          FROM   expense_items WHERE expense_id = :id;

          SELECT claim_for INTO l_claim_for FROM expenses WHERE id = :id;

          IF l_bills = 0 THEN
            l_missing := 'This claim has no bills. Add at least one before submitting.';
          ELSIF l_noreceipt > 0 THEN
            -- Named rather than counted: "2 bills" makes someone hunt, the
            -- numbers tell them where to look.
            SELECT 'Receipt missing on bill ' || LISTAGG(item_no, ', ')
                     WITHIN GROUP (ORDER BY item_no)
                   || '. Attach one to every bill before submitting.'
            INTO   l_missing
            FROM   expense_items
            WHERE  expense_id = :id AND attachment_blob IS NULL;
          ELSIF l_claim_for IS NULL THEN
            l_missing := 'Missing "Claim For" -- say what this claim is for.';
          END IF;

          IF l_missing IS NOT NULL THEN
            :status := 409;
            APEX_JSON.OPEN_OBJECT;
            APEX_JSON.WRITE('error', l_missing);
            APEX_JSON.WRITE('bills', l_bills);
            APEX_JSON.WRITE('bills_without_receipt', l_noreceipt);
            APEX_JSON.CLOSE_OBJECT;
            RETURN;
          END IF;
        END;

        IF l_status = 'DRAFT' THEN
          l_manager_id := get_project_manager_empid(l_project_id);
          l_finance_id := get_finance_manager_empid();

          UPDATE expenses
          SET status = 'SUBMITTED',
              current_stage = 'MANAGER',
              manager_empid = l_manager_id,
              finance_manager_empid = l_finance_id,
              submitted_by = l_emp_id,
              submitted_at = SYSTIMESTAMP
          WHERE id = :id;

          -- TO the project manager, CC the employee.
          --
          -- manager_empid and submitted_at are passed explicitly because the
          -- UPDATE above is NOT yet committed, and send_expense_mail is
          -- autonomous -- it would otherwise re-read the row, still see an
          -- unsubmitted draft with no manager, and email the employee saying
          -- no project manager was assigned.
          send_expense_mail(:id, 'SUBMITTED', l_emp_id, NULL, NULL,
                            l_manager_id, l_finance_id, SYSTIMESTAMP);

          send_push_notification(l_emp_id, 'Expense Submitted',
            'Your expense #' || :id || ' was submitted for approval.', :id);
          IF l_manager_id IS NOT NULL THEN
            send_push_notification(l_manager_id, 'Approval Needed',
              'An expense from your project is waiting for your approval.', :id);
          END IF;

        ELSIF l_status = 'REVISION_REQUESTED' THEN
          UPDATE expenses SET status = 'SUBMITTED' WHERE id = :id;

          send_push_notification(l_emp_id, 'Expense Resubmitted',
            'Your expense #' || :id || ' was resubmitted for approval.', :id);

          IF l_current_stage = 'MANAGER' AND l_manager_id IS NOT NULL THEN
            send_push_notification(l_manager_id, 'Approval Needed',
              'A revised expense is waiting for your approval.', :id);
          ELSIF l_current_stage = 'FINANCE' AND l_finance_id IS NOT NULL THEN
            send_push_notification(l_finance_id, 'Approval Needed',
              'A revised expense is waiting for your approval.', :id);
          END IF;

        ELSE
          :status := 409;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Cannot submit an expense in status ' || l_status);
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        :status := 200;
        APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('id', :id); APEX_JSON.WRITE('status', 'SUBMITTED'); APEX_JSON.CLOSE_OBJECT;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          :status := 404;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'Expense not found'); APEX_JSON.CLOSE_OBJECT;
      END;
    ]'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/submit', p_method => 'POST',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/submit', p_method => 'POST',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/submit', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT'
  );
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 5. Verify.
--------------------------------------------------------------------------------
SELECT t.uri_template, h.method,
       CASE WHEN INSTR(h.source, 'claim_for') > 0 THEN 'Y' ELSE 'N' END AS knows_claim_for,
       CASE WHEN INSTR(h.source, 'expense_items') > 0 THEN 'Y' ELSE 'N' END AS knows_bills
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND    t.uri_template IN ('draft', ':id', ':id/submit')
ORDER  BY t.uri_template, h.method;

-- draft POST, :id PUT and :id GET should all show knows_claim_for = Y.
-- :id/submit POST and :id GET should show knows_bills = Y.

-- Still no template without a handler.
SELECT t.uri_template, COUNT(h.id) AS handlers
FROM   user_ords_templates t
JOIN   user_ords_modules m ON m.id = t.module_id
LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
WHERE  m.name = 'expenses.employee'
GROUP  BY t.uri_template
HAVING COUNT(h.id) = 0;

-- Still no wildcard patterns.
SELECT pm.pattern FROM user_ords_privilege_mappings pm
WHERE  pm.pattern LIKE '/expenses/%*%' OR pm.pattern = '/expenses/*';


--------------------------------------------------------------------------------
-- 6. End-to-end test, by hand, before touching the app.
--
--   1. POST /expenses/draft
--        {"project_id":2386,"claim_for":"Client visit - Chennai",
--          "client_request_id":"test-001"}
--      -> 201 with an id. No dates or amount needed.
--
--   2. POST /expenses/{id}/submit
--      -> 409 "This claim has no bills."
--
--   3. POST /expenses/{id}/items
--        {"bill_date":"2026-08-01","type":"Taxi","description":"Airport",
--          "from_date":"2026-08-01","to_date":"2026-08-01",
--          "currency":"INR","amount":450}
--      -> 201 with exchange_rate and amount_usd computed by the server
--
--   4. POST /expenses/{id}/submit
--      -> 409 "Receipt missing on bill 1."
--
--   5. POST /expenses/{id}/items/{itemId}/attachment   (a small jpg or pdf)
--      -> 200
--
--   6. POST /expenses/{id}/submit
--      -> 200, status SUBMITTED. The project manager gets the email.
--
--   7. GET /expenses/{id}
--      -> item_count 1, bills_without_receipt 0, amount_usd matching the bill
--
-- Then add a second bill in another currency and confirm amount_usd on the
-- claim is the SUM, and from_date/to_date span both bills:
--
--   SELECT id, claim_for, from_date, to_date, amount, amount_usd
--   FROM   expenses WHERE id = ...;
--   SELECT item_no, type, currency, amount, exchange_rate, amount_usd
--   FROM   expense_items WHERE expense_id = ... ORDER BY item_no;
--------------------------------------------------------------------------------
