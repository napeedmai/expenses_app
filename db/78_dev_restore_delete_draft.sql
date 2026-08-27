--------------------------------------------------------------------------------
-- 78_dev_restore_delete_draft.sql
--
-- FOR DEV (HRMS) ONLY. Run in SQL SCRIPTS. Idempotent.
-- Prod already has this handler -- the script refuses to run on REPO, because
-- replacing a working production handler to fix a dev gap is not a trade worth
-- making by accident.
--
--
-- WHY
-- ---
-- Comparing the two modules after the prod migration:
--
--             templates  handlers   :id methods
--   prod             22        28   GET PUT DELETE
--   dev              21        26   GET PUT
--
-- DEV IS MISSING :id DELETE. It is how the app deletes a draft --
-- deleteExpense() in src/api/client.js -- so on dev that button fails and on
-- prod it works. A test environment that cannot do something production can do
-- is worse than no test environment for that path, because it produces a
-- confident false negative.
--
-- The cause is the same one behind scripts 72 and 73: something re-ran
-- ORDS.DEFINE_MODULE on HRMS, and the scripts that rebuilt afterwards
-- (66 covered draft, PUT, GET and submit) did not include DELETE. Nobody
-- noticed because nobody deleted a draft on dev.
--
-- Body lifted verbatim from PROD_4_endpoints.sql. Checked against the eight
-- columns db/64 dropped: it references none of them.
--
--
-- ONE THING WORTH KNOWING ABOUT IT
-- --------------------------------
-- The handler is a bare DELETE FROM expenses, with no mention of EXPENSE_ITEMS
-- -- which did not exist when it was written. That is still correct, because
-- the foreign key was declared
--
--     CONSTRAINT fk_items_expense FOREIGN KEY (expense_id)
--       REFERENCES expenses(id) ON DELETE CASCADE
--
-- so the bills go with the claim. Without the CASCADE this would have raised
-- ORA-02292 on any draft that had a bill on it, which is most of them. Worth
-- checking rather than assuming, since the handler predates the table.
--
-- Its guards are unchanged and still right: owner must match, status must be
-- DRAFT, 409 otherwise. A submitted claim cannot be deleted by anyone.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF


--------------------------------------------------------------------------------
-- 0. Dev only, and only if it is actually missing.
--------------------------------------------------------------------------------
DECLARE
  l_schema VARCHAR2(128) := SYS_CONTEXT('USERENV','CURRENT_SCHEMA');
  l_n      NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Connected as: ' || l_schema);

  IF l_schema = 'REPO' THEN
    RAISE_APPLICATION_ERROR(-20001,
      'This is PRODUCTION, which already has :id DELETE. This script exists to '
      || 'close a DEV gap. Nothing changed.');
  END IF;

  SELECT COUNT(*) INTO l_n
  FROM   user_ords_templates t
  JOIN   user_ords_modules m ON m.id = t.module_id
  WHERE  m.name = 'expenses.employee' AND t.uri_template = ':id';

  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'No :id template on ' || l_schema || '. Run 73_restore_missing_handlers.sql '
      || 'first. Nothing changed.');
  END IF;

  SELECT COUNT(*) INTO l_n
  FROM   user_ords_handlers h
  JOIN   user_ords_templates t ON t.id = h.template_id
  JOIN   user_ords_modules m   ON m.id = t.module_id
  WHERE  m.name = 'expenses.employee'
  AND    t.uri_template = ':id' AND h.method = 'DELETE';

  IF l_n > 0 THEN
    DBMS_OUTPUT.PUT_LINE(':id DELETE already present -- it will be replaced with '
      || 'the same body. Harmless.');
  ELSE
    DBMS_OUTPUT.PUT_LINE(':id DELETE is missing. Installing it.');
  END IF;

  -- The CASCADE this handler quietly depends on.
  SELECT COUNT(*) INTO l_n
  FROM   user_constraints
  WHERE  constraint_name = 'FK_ITEMS_EXPENSE' AND delete_rule = 'CASCADE';

  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'FK_ITEMS_EXPENSE is not ON DELETE CASCADE on ' || l_schema || '. This '
      || 'handler deletes only the claim row, so without the cascade it would '
      || 'raise ORA-02292 on any draft that has a bill. Nothing changed.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('FK_ITEMS_EXPENSE is ON DELETE CASCADE. Bills will go with '
    || 'the claim.');
END;
/


--------------------------------------------------------------------------------
-- 1. DELETE /expenses/:id   -- verbatim from PROD_4_endpoints.sql.
--------------------------------------------------------------------------------

BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => ':id',
    p_method      => 'DELETE',
    p_source_type => ords.source_type_plsql,
    p_source      => q'[
      DECLARE
        l_emp_id   NUMBER := TO_NUMBER(:emp_id_hdr);
        l_owner_id NUMBER;
        l_status   VARCHAR2(30);
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

        IF l_status != 'DRAFT' THEN
          :status := 409;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Only DRAFT expenses can be deleted (current status: ' || l_status || ')');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        DELETE FROM expenses WHERE id = :id;
        :status := 204;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          :status := 404;
          APEX_JSON.OPEN_OBJECT; APEX_JSON.WRITE('error', 'Expense not found'); APEX_JSON.CLOSE_OBJECT;
      END;
    ]'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id', p_method => 'DELETE',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id', p_method => 'DELETE',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'
  );
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => ':id', p_method => 'DELETE',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT'
  );
  COMMIT;
END;
/

--------------------------------------------------------------------------------
-- 2. Verify. Expect one row: DELETE, plsql/block, 3 params.
--------------------------------------------------------------------------------
SELECT t.uri_template, h.method, h.source_type,
       (SELECT COUNT(*) FROM user_ords_parameters pa WHERE pa.handler_id = h.id) AS params
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee' AND t.uri_template = ':id'
ORDER  BY h.method;
-- All three methods should now be listed: DELETE, GET, PUT -- matching prod.

-- And the counts should now match production: 26 -> 27 handlers on dev.
SELECT (SELECT COUNT(*) FROM user_ords_templates t
        JOIN   user_ords_modules m ON m.id = t.module_id
        WHERE  m.name = 'expenses.employee') AS templates,
       (SELECT COUNT(h.id) FROM user_ords_handlers h
        JOIN   user_ords_templates t ON t.id = h.template_id
        JOIN   user_ords_modules m   ON m.id = t.module_id
        WHERE  m.name = 'expenses.employee') AS handlers
FROM   dual;
-- Dev: 21 templates, 27 handlers.
-- Prod: 22 and 28 -- the extra one is the `authcheck` template, which exists
-- only on prod and is not part of this project's 21 documented endpoints.
-- Find out what it is before assuming it is harmless: it is covered by NO
-- privilege, so it is reachable without a token.


--------------------------------------------------------------------------------
-- 3. Then test it: create a draft, add a bill, delete the draft.
--
-- The bill must go with it. If it does not, the cascade is not doing what the
-- guard above says it is:
--
--   SELECT COUNT(*) AS orphaned_bills FROM expense_items i
--   WHERE  NOT EXISTS (SELECT 1 FROM expenses e WHERE e.id = i.expense_id);
--   -- must be 0
--
-- And a submitted claim must refuse with 409, not delete.
--------------------------------------------------------------------------------
