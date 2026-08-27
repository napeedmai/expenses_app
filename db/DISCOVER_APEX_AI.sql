--------------------------------------------------------------------------------
-- DISCOVER_APEX_AI.sql
--
-- READ-ONLY. Changes nothing. Run on DEV (HRMS) first, in SQL Scripts.
--
-- Everything needed to write the receipt-scanning endpoint, read out of the
-- database rather than assumed:
--
--   1. Is APEX_AI there, and can this schema execute it?
--   2. The EXACT signature of GENERATE -- the parameter that names the AI
--      service was p_config_static_id and became p_agent_static_id, with the
--      old one deprecated. Which one this release wants decides the call.
--   3. Which AI service is configured, and its STATIC ID -- the footer of your
--      APEX session showed gpt-4.1-mini, so one exists.
--   4. Whether it needs APEX_UTIL.SET_WORKSPACE first, the way APEX_MAIL does.
--
-- I am not guessing any of this. Assuming an API shape is what produced the
-- ORDS.DELETE_TEMPLATE call that never existed and the DEFAULT ON CONVERSION
-- ERROR clause on the wrong argument. Both compiled. Both were wrong.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF
SET LINESIZE 200


PROMPT ============ 0. WHERE AM I, AND WHICH APEX ============

SELECT SYS_CONTEXT('USERENV','CURRENT_SCHEMA') AS schema_name,
       (SELECT MAX(version_no) FROM apex_release)          AS apex_version,
       (SELECT MAX(owner) FROM all_objects
        WHERE object_name = 'APEX_AI' AND object_type = 'PACKAGE') AS apex_ai_owner,
       (SELECT secret_value FROM app_secrets
        WHERE secret_name = 'MAIL_WORKSPACE')              AS workspace_from_secrets
FROM   dual;
-- apex_ai_owner NULL means APEX_AI does not exist here and this whole approach
-- is off the table -- stop and tell me.
-- workspace_from_secrets is what send_expense_mail already uses for
-- APEX_UTIL.SET_WORKSPACE. The AI call very likely needs the same.


PROMPT ============ 1. CAN THIS SCHEMA EXECUTE IT ============

SELECT grantee, table_name, privilege, grantor
FROM   all_tab_privs
WHERE  table_name = 'APEX_AI'
AND    privilege = 'EXECUTE'
ORDER  BY grantee;
-- PUBLIC is the normal answer for APEX packages. If neither PUBLIC nor this
-- schema appears, a DBA grant is needed and that changes the timeline.


PROMPT ============ 2. THE EXACT SIGNATURE ============

-- Every overload of GENERATE and CHAT, argument by argument. This is the
-- authoritative answer -- more reliable than any blog post about which release
-- renamed what.
SELECT object_name      AS subprogram,
       subprogram_id    AS overload,
       position,
       argument_name,
       data_type,
       in_out,
       defaulted
FROM   all_arguments
WHERE  package_name = 'APEX_AI'
AND    object_name IN ('GENERATE','CHAT')
ORDER  BY object_name, subprogram_id, position;
--
-- What I am looking for in particular:
--   * the parameter that names the service   (p_config_static_id / p_agent_static_id / p_service_static_id)
--   * the attachments parameter and its TYPE (p_attachments -- a record or a
--     table type, and what its fields are called)
--   * whether a JSON response schema can be requested, and under what name
--   * position 0 = the function's RETURN type


PROMPT ============ 3. THE ATTACHMENTS TYPE ============

-- p_attachments is not a scalar. Whatever type it is, these are its fields --
-- Oracle's example passes mime_type, content_blob and file_name, but the
-- actual type declaration is what matters.
SELECT t.type_name, a.attr_name, a.attr_type_name, a.length, a.attr_no
FROM   all_type_attrs a
JOIN   all_types t ON t.owner = a.owner AND t.type_name = a.type_name
WHERE  UPPER(t.type_name) LIKE '%ATTACHMENT%'
AND    t.owner LIKE 'APEX%'
ORDER  BY t.type_name, a.attr_no;

-- And the package-level type declarations, which is where a PL/SQL record type
-- would live instead.
SELECT owner, name, type, line, text
FROM   all_source
WHERE  name = 'APEX_AI' AND type = 'PACKAGE'
AND   (INSTR(LOWER(text), 'attachment') > 0
    OR INSTR(LOWER(text), 'response_format') > 0
    OR INSTR(LOWER(text), 'json_schema') > 0)
ORDER  BY line;


PROMPT ============ 4. WHICH AI SERVICE IS CONFIGURED ============

-- Not guessing the view name either. List every APEX dictionary view with AI in
-- its name, then we read the right one.
SELECT view_name
FROM   all_views
WHERE  view_name LIKE 'APEX%AI%'
ORDER  BY view_name;

-- The two most likely, each wrapped so a wrong guess does not abort the script.
DECLARE
  PROCEDURE try(p_sql IN VARCHAR2) IS
    l_cur SYS_REFCURSOR;
  BEGIN
    OPEN l_cur FOR p_sql;
    CLOSE l_cur;
    DBMS_OUTPUT.PUT_LINE('  QUERYABLE: ' || p_sql);
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('  not available: ' || SUBSTR(p_sql, 1, 60)
      || ' -- ' || SQLERRM);
  END;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Probing AI config views:');
  try('SELECT * FROM apex_ai_configs WHERE ROWNUM = 1');
  try('SELECT * FROM apex_appl_ai_configs WHERE ROWNUM = 1');
  try('SELECT * FROM apex_workspace_ai_configs WHERE ROWNUM = 1');
  try('SELECT * FROM apex_ai_agents WHERE ROWNUM = 1');
END;
/

-- Run whichever of the above reported QUERYABLE. The STATIC_ID column is the
-- value the GENERATE call needs.
--
--   SELECT * FROM <that view>;


PROMPT ============ 5. THE WORKSPACE, AND A LIVE TEXT-ONLY TEST ============

-- Text only, no image. Proves the credential, the network path and the
-- workspace resolution work, before any of it is wired into a handler.
--
-- ** EDIT THE STATIC ID BELOW ** to the one section 4 reports, then re-run just
-- this block. Left deliberately wrong so it cannot appear to pass by accident.
DECLARE
  l_workspace VARCHAR2(200);
  l_out       CLOB;
  c_static_id CONSTANT VARCHAR2(100) := 'PUT_THE_STATIC_ID_HERE';
BEGIN
  SELECT secret_value INTO l_workspace
  FROM   app_secrets WHERE secret_name = 'MAIL_WORKSPACE';

  DBMS_OUTPUT.PUT_LINE('Workspace: ' || l_workspace);
  APEX_UTIL.SET_WORKSPACE(p_workspace => l_workspace);

  -- Deliberately the simplest possible call. If the signature differs, this
  -- fails to compile and section 2's output tells you exactly how to correct
  -- it -- which is the point of running section 2 first.
  l_out := APEX_AI.GENERATE(
             p_prompt           => 'Reply with exactly the word: READY',
             p_config_static_id => c_static_id);

  DBMS_OUTPUT.PUT_LINE('AI replied: ' || SUBSTR(l_out, 1, 400));
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('FAILED: ' || SQLERRM);
    DBMS_OUTPUT.PUT_LINE(SUBSTR(DBMS_UTILITY.FORMAT_ERROR_STACK, 1, 2000));
    DBMS_OUTPUT.PUT_LINE('--');
    DBMS_OUTPUT.PUT_LINE('If this says PLS-00306 or "wrong number or types of '
      || 'arguments", the parameter names differ in this release -- read '
      || 'section 2 and send me that output. If it says the workspace or '
      || 'service is not found, the static id is wrong. If it mentions ORA-29024 '
      || 'or a certificate, then APEX is NOT brokering the connection after all '
      || 'and we are back to the wallet problem that stopped push.');
END;
/


--------------------------------------------------------------------------------
-- WHAT I NEED BACK
--
--   * section 0  -- one row
--   * section 2  -- the whole argument list for GENERATE
--   * section 4  -- which view was QUERYABLE, and its rows
--   * section 5  -- whether it printed READY, or the error
--
-- With those four I can write the endpoint against the real API instead of a
-- remembered one.
--
--
-- WHAT GETS BUILT NEXT, so the shape is not a surprise
--
--   POST /expenses/scan-receipt
--     body:    the raw image or PDF, Content-Type set to its MIME type
--              -- same convention as the receipt upload, NOT multipart
--     returns: JSON of SUGGESTED field values plus a per-field confidence,
--              and stores NOTHING
--
--   Stateless and not tied to a bill, deliberately: the person picks a photo in
--   BillSheet and sees the suggestions BEFORE a bill row exists. Making them
--   save an empty bill first, to have something to scan against, would be a
--   worse form to fill in than the one they have now.
--
--   The app then shows a review sheet -- what it read, field by field -- with an
--   Apply button. Nothing is written until they accept it.
--------------------------------------------------------------------------------
