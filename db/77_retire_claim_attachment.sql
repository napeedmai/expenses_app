--------------------------------------------------------------------------------
-- 77_retire_claim_attachment.sql
--
-- Run as the APPLICATION SCHEMA, in SQL SCRIPTS. Idempotent.
--
--   dev  = karyasiddhitest.trinamix.com, schema HRMS
--   prod = karyasiddhi.trinamix.com,     schema REPO
--
--
-- WHY :id/attachment STILL SHOWS 0 HANDLERS
-- -----------------------------------------
-- Section 3 of 73_restore_missing_handlers.sql called
--
--     ORDS.DELETE_TEMPLATE(p_module_name => ..., p_pattern => ':id/attachment');
--
-- There is no such procedure. The ORDS package offers DELETE_MODULE,
-- DELETE_PRIVILEGE and DELETE_ROLE -- there is no per-template delete. So that
-- block failed to compile (PLS-00302, "component must be declared"), the script
-- carried on, and the template is exactly where it was. My error, and one I
-- could have checked in a query instead of assuming the API was symmetrical
-- with DEFINE_TEMPLATE.
--
--
-- SO RETIRE IT PROPERLY INSTEAD
-- -----------------------------
-- The only supported way to remove one template is DELETE_MODULE followed by
-- rebuilding all 20 others -- which is the exact destructive operation that
-- emptied this module in the first place and cost scripts 71, 72 and 73. Not
-- worth it to tidy away one obsolete path.
--
-- Better answer: give it a handler that says what happened.
--
--   * It stops being a template with no handler, which is the condition that
--     makes this whole class of fault hide -- an endpoint that answers and runs
--     nothing looks like a routing problem, a CORS problem, or a privilege
--     problem, and reads as none of them.
--   * Anything still calling the old URL gets an explanation and the new URL,
--     rather than a bare 404 that means "look somewhere else entirely".
--   * 410 Gone is the honest status. Not 404 -- the resource existed, and the
--     caller is not lost, they are out of date.
--
--
-- WHAT WAS AT THIS URL, AND WHERE IT WENT
-- ---------------------------------------
-- The CLAIM-level receipt. One expense, one file, in EXPENSES.ATTACHMENT_BLOB.
-- Multi-bill moved the receipt onto the BILL, because a claim now has up to
-- twenty of them and there was never a single file it could mean. All four
-- columns it used were dropped by db/64:
--
--     ATTACHMENT_BLOB  ATTACHMENT_FILENAME  ATTACHMENT_MIME_TYPE  ATTACHMENT_PATH
--
-- Replacement, already live and working:
--
--     POST /expenses/{id}/items/{item_id}/attachment
--     GET  /expenses/{id}/items/{item_id}/attachment
--
-- Note those take the RAW FILE as the body with Content-Type set to the file's
-- own MIME type -- NOT multipart. The old endpoint here was multipart, and
-- copying its client function is what caused the 400 on the bill receipt. See
-- the comment on uploadItemAttachment() in src/api/client.js.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF


--------------------------------------------------------------------------------
-- 0. Confirm the diagnosis rather than trusting the header above.
--
-- If ORDS.DELETE_TEMPLATE turns out to exist in this ORDS version, that is
-- worth knowing -- but this script does not need it either way.
--------------------------------------------------------------------------------
DECLARE
  l_n NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Connected as: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
  DBMS_OUTPUT.PUT_LINE('  HRMS = dev, REPO = PRODUCTION.');

  SELECT COUNT(*) INTO l_n
  FROM   all_procedures
  WHERE  owner = 'ORDS_METADATA' AND object_name = 'ORDS'
  AND    procedure_name = 'DELETE_TEMPLATE';

  IF l_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('ORDS.DELETE_TEMPLATE does not exist here -- as expected. '
      || 'Retiring the endpoint with a 410 handler instead.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('*** ORDS.DELETE_TEMPLATE DOES exist in this version. '
      || 'The 410 handler below is still the better option -- an old client gets '
      || 'told why -- but deleting the template is available if you prefer. ***');
  END IF;

  SELECT COUNT(*) INTO l_n
  FROM   user_ords_templates t
  JOIN   user_ords_modules m ON m.id = t.module_id
  WHERE  m.name = 'expenses.employee' AND t.uri_template = ':id/attachment';

  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'There is no :id/attachment template here, so there is nothing to retire. '
      || 'Nothing changed.');
  END IF;
END;
/


--------------------------------------------------------------------------------
-- 1. POST and GET both answer 410 Gone, naming the endpoint that replaced them.
--
-- source_type_plsql for GET as well as POST: the original GET was
-- source_type_media, which streams a BLOB and has no way to write a JSON body
-- or set a status.
--------------------------------------------------------------------------------
BEGIN
  FOR m IN (SELECT column_value AS meth
            FROM   TABLE(sys.odcivarchar2list('POST','GET')))
  LOOP
    ORDS.DEFINE_HANDLER(
      p_module_name => 'expenses.employee',
      p_pattern     => ':id/attachment',
      p_method      => m.meth,
      p_source_type => ords.source_type_plsql,
      p_source      => q'[
        BEGIN
          :status := 410;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error',
            'Receipts belong to a bill, not to a claim. This endpoint was '
            || 'retired when one claim became many bills.');
          APEX_JSON.WRITE('use_instead',
            '/expenses/' || :id || '/items/{item_id}/attachment');
          APEX_JSON.WRITE('note',
            'The replacement takes the raw file as the request body with '
            || 'Content-Type set to the file''s own MIME type. It is not '
            || 'multipart/form-data.');
          APEX_JSON.CLOSE_OBJECT;
        END;
      ]'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'expenses.employee', p_pattern => ':id/attachment',
      p_method => m.meth,
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
      p_source_type => 'HEADER', p_access_method => 'OUT');

    DBMS_OUTPUT.PUT_LINE('  ' || m.meth || ' :id/attachment -> 410 Gone');
  END LOOP;
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 2. Verify.
--------------------------------------------------------------------------------

-- a) THE CONDITION THAT STARTED ALL OF THIS. No template in the module may be
--    without a handler. MUST NOW RETURN NO ROWS.
SELECT t.uri_template, COUNT(h.id) AS handlers
FROM   user_ords_templates t
JOIN   user_ords_modules m ON m.id = t.module_id
LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
WHERE  m.name = 'expenses.employee'
GROUP  BY t.uri_template HAVING COUNT(h.id) = 0;

-- b) The two retired handlers are there and say 410.
SELECT t.uri_template, h.method, h.source_type,
       CASE WHEN INSTR(h.source, '410') > 0 THEN 'Y' ELSE 'N' END AS returns_410
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee' AND t.uri_template = ':id/attachment'
ORDER  BY h.method;
-- Expect two rows, both plsql/block, both Y.

-- c) The REAL receipt endpoint is untouched. Expect 2 handlers, POST and GET,
--    with 5 and 2 parameters.
SELECT t.uri_template, h.method,
       (SELECT COUNT(*) FROM user_ords_parameters pa WHERE pa.handler_id = h.id) AS params
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND    t.uri_template = ':id/items/:item_id/attachment'
ORDER  BY h.method;

-- d) Nothing in the module references a dropped column. MUST RETURN NO ROWS.
--    Worth running after every ORDS script from now on.
SELECT t.uri_template, h.method
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND   (INSTR(LOWER(h.source), 'e.bill_no')     > 0
    OR INSTR(LOWER(h.source), 'e.bill_date')   > 0
    OR INSTR(LOWER(h.source), 'e.type')        > 0
    OR INSTR(LOWER(h.source), 'e.description') > 0
    OR INSTR(LOWER(h.source), 'attachment_blob') > 0)
ORDER  BY t.uri_template, h.method;
-- The 410 handlers above mention neither, so this stays clean.


--------------------------------------------------------------------------------
-- 3. Also worth deleting, in the app, next time you are in these files
--
--   src/api/client.js
--     uploadAttachment()   and   getAttachmentUrl()
--
-- Both point at this URL. Nothing in src/screens calls either -- they are dead
-- code from before multi-bill -- but uploadAttachment() is the function that
-- uploadItemAttachment() was copied from, and copying it is what produced the
-- 400 on the bill receipt. It is marked DEAD CODE now; removing it is better.
--
--
-- WHERE THE DB SCRIPTS STAND
--
--   71  handlers stop selecting the eight dropped columns    -> the 403
--   72  currencies + exchange-rate templates restored        -> the 555
--   73  nine missing handlers restored                       -> the empty LOVs
--   75  exchange-rate parses ISO and MM/DD/YYYY              -> ORA-01843
--   76  my-projects and whoami name the two approvers        -> "Set when you submit"
--   77  :id/attachment retired with a 410                    -> this file
--
-- After 77, query (a) should be empty for the first time in this whole
-- sequence: every template in the module has a handler, and no handler
-- references anything that no longer exists.
--------------------------------------------------------------------------------
