--------------------------------------------------------------------------------
-- 65b_delete_handler_only.sql
--
-- Run as the APPLICATION SCHEMA (REPO), in SQL Scripts. Idempotent.
--
-- Script 65 created five of its six handlers. The DELETE on
-- :id/items/:item_id failed with nothing but "=> invalid", which names no
-- cause. This defines that one handler on its own, with the exception caught
-- and printed, so the actual ORA number appears.
--
-- Section 3 has a fallback if ORDS turns out to dislike the DELETE method here.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF


--------------------------------------------------------------------------------
-- 1. What is actually there now?
--------------------------------------------------------------------------------
SELECT t.uri_template, h.method, h.source_type
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND    t.uri_template LIKE ':id/items%'
ORDER  BY t.uri_template, h.method;


--------------------------------------------------------------------------------
-- 2. The DELETE handler, with the error surfaced.
--
-- Note ORDS.DEFINE_HANDLER does not validate the PL/SQL body -- it stores it
-- verbatim. So any failure here is about the HANDLER DEFINITION (method,
-- source type, a duplicate, a parameter) and not about the code inside.
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

        -- Close the gap. item_no is capped at 20 and new bills take MAX+1, so
        -- leaving a hole would eventually make the cap on HOW MANY bills act
        -- as a cap on how many were ever added. Ascending order is required:
        -- descending would collide with a row that still holds the number.
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
        APEX_JSON.WRITE('bills_on_claim', l_left);
        APEX_JSON.CLOSE_OBJECT;
      EXCEPTION
        WHEN OTHERS THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', SQLERRM); APEX_JSON.CLOSE_OBJECT;
      END;
    ]'
  );
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('DELETE handler defined.');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('DEFINE_HANDLER failed. Full stack:');
    DBMS_OUTPUT.PUT_LINE('--------------------------------------------------');
    DBMS_OUTPUT.PUT_LINE(DBMS_UTILITY.FORMAT_ERROR_STACK);
    DBMS_OUTPUT.PUT_LINE('--------------------------------------------------');
    DBMS_OUTPUT.PUT_LINE('SQLCODE: ' || SQLCODE);
    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE('If this says the method is not supported, or a handler');
    DBMS_OUTPUT.PUT_LINE('already exists, use the fallback in section 3.');
END;
/

-- Parameters, defined separately so a failure here is distinguishable from a
-- failure above. Each is wrapped: re-running is harmless.
DECLARE
  PROCEDURE add_param(p_name IN VARCHAR2, p_bind IN VARCHAR2,
                      p_access IN VARCHAR2, p_type IN VARCHAR2 DEFAULT 'STRING') IS
  BEGIN
    IF p_access = 'OUT' THEN
      ORDS.DEFINE_PARAMETER(
        p_module_name => 'expenses.employee', p_pattern => ':id/items/:item_id',
        p_method => 'DELETE', p_name => p_name, p_bind_variable_name => p_bind,
        p_source_type => 'HEADER', p_access_method => 'OUT');
    ELSE
      ORDS.DEFINE_PARAMETER(
        p_module_name => 'expenses.employee', p_pattern => ':id/items/:item_id',
        p_method => 'DELETE', p_name => p_name, p_bind_variable_name => p_bind,
        p_source_type => 'HEADER', p_param_type => p_type, p_access_method => 'IN');
    END IF;
    DBMS_OUTPUT.PUT_LINE('  parameter ' || p_name || ' ok');
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('  parameter ' || p_name || ' FAILED: ' || SQLERRM);
  END;
BEGIN
  add_param('X-Emp-Id',            'emp_id_hdr',        'IN');
  add_param('X-Session-Token',     'session_token_hdr', 'IN');
  add_param('X-APEX-STATUS-CODE',  'status',            'OUT');
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 3. FALLBACK -- only if section 2 could not define a DELETE handler.
--
-- Some ORDS configurations refuse DELETE on a parameterised template. The
-- workaround is a POST to a distinct path, which is behaviourally identical:
--
--     POST /expenses/{id}/items/{itemId}/remove
--
-- Not as tidy as DELETE, and it means one more privilege pattern, but it is a
-- URL the app can call today rather than a REST purity argument.
--
-- Uncomment and run ONLY if section 2 failed. Then add the pattern to the
-- privilege, or the endpoint is publicly reachable:
--
--     /expenses/:id/items/:item_id/remove
--------------------------------------------------------------------------------
/*
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee',
                       p_pattern => ':id/items/:item_id/remove');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => ':id/items/:item_id/remove',
    p_method      => 'POST',
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
    p_module_name => 'expenses.employee', p_pattern => ':id/items/:item_id/remove',
    p_method => 'POST', p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/items/:item_id/remove',
    p_method => 'POST', p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id/items/:item_id/remove',
    p_method => 'POST', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Fallback POST .../remove defined.');
END;
/
*/


--------------------------------------------------------------------------------
-- 4. Where did we end up?
--
--    :id/items/:item_id should show BOTH PUT and DELETE. If it shows only PUT,
--    section 2 failed and the fallback is the way forward.
--------------------------------------------------------------------------------
SELECT t.uri_template, h.method, h.source_type
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND    t.uri_template LIKE ':id/items%'
ORDER  BY t.uri_template, h.method;

-- Its three parameters, if the handler exists.
SELECT h.method, pa.name, pa.bind_variable_name, pa.access_method, pa.source_type
FROM   user_ords_parameters pa
JOIN   user_ords_handlers h  ON h.id = pa.handler_id
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND    t.uri_template = ':id/items/:item_id'
ORDER  BY h.method, pa.name;
