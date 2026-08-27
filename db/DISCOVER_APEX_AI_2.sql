--------------------------------------------------------------------------------
-- DISCOVER_APEX_AI_2.sql
--
-- READ-ONLY. Changes nothing. Run on DEV (HRMS), in SQL Scripts.
-- Supersedes DISCOVER_APEX_AI.sql, four of whose five sections asked the wrong
-- question.
--
--
-- WHAT THE FIRST ATTEMPT GOT WRONG
-- --------------------------------
-- APEX_AI IS A SYNONYM, NOT A PACKAGE. It resolves to
-- APEX_260100.WWV_FLOW_AI_API -- visible in the error stack from section 5:
--
--     ORA-06512: at "APEX_260100.WWV_FLOW_AI_API", line 197
--
-- I looked for object_type = 'PACKAGE' with object_name = 'APEX_AI', and for
-- all_arguments where package_name = 'APEX_AI'. Both are empty by construction.
-- Hence "no data found" four times while the actual call ran perfectly well.
--
--
-- WHAT IT GOT RIGHT, AND IT MATTERS
-- ---------------------------------
--   * APEX_AI.GENERATE(p_prompt => ..., p_config_static_id => ...) COMPILED and
--     EXECUTED. The signature is fine and p_config_static_id is still accepted
--     in 26.1 -- it maps to AGENT_STATIC_ID internally.
--
--   * The failure was ORA-20961 "agent does not exist", which is a LOOKUP
--     failure. Not a certificate error, not ORA-29024, not a network ACL.
--     APEX IS BROKERING THE CONNECTION. The TLS wallet that has blocked push
--     notifications since July does not stand in the way of this.
--
--   * "...does not exist in the current APPLICATION." AI configs are
--     APPLICATION-scoped, not workspace-scoped -- the view list confirms it:
--     APEX_APPL_AI_CONFIGS and APEX_APPL_AI_AGENTS exist, APEX_WORKSPACE_AI_-
--     CONFIGS does not. APEX_WORKSPACE_AI_SERVICES is the provider credential
--     at workspace level; the CONFIG that points at it lives in an app.
--
--     So APEX_UTIL.SET_WORKSPACE alone is not enough, the way it is for
--     APEX_MAIL. An application context is needed too. Section 4 finds out what
--     that costs.
--
-- That last point is the one real design question. An ORDS handler has no APEX
-- session; if every scan needs APEX_SESSION.CREATE_SESSION, that is real
-- overhead per request and worth knowing before it is wired in.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF
SET LINESIZE 200


PROMPT ============ 1. WHAT APEX_AI ACTUALLY IS ============

SELECT owner, synonym_name, table_owner, table_name
FROM   all_synonyms
WHERE  synonym_name IN ('APEX_AI','APEX_SESSION')
ORDER  BY synonym_name;


PROMPT ============ 2. THE REAL SIGNATURE ============

-- Now asking the right package. Every overload, argument by argument.
SELECT object_name   AS subprogram,
       subprogram_id AS overload,
       position,
       argument_name,
       data_type,
       in_out,
       defaulted
FROM   all_arguments
WHERE  package_name = 'WWV_FLOW_AI_API'
AND    object_name IN ('GENERATE','CHAT')
ORDER  BY object_name, subprogram_id, position;
--
-- Looking for: the attachments parameter and its data type, and whether a JSON
-- response schema can be requested. position 0 = the RETURN type.


PROMPT ============ 3. THE ATTACHMENTS AND RESPONSE-FORMAT TYPES ============

-- p_attachments will be a collection of records. This is its declaration.
SELECT line, text
FROM   all_source
WHERE  owner = 'APEX_260100'
AND    name  = 'WWV_FLOW_AI_API'
AND    type  = 'PACKAGE'
AND   (INSTR(LOWER(text), 'attachment')      > 0
    OR INSTR(LOWER(text), 'response_format') > 0
    OR INSTR(LOWER(text), 'json_schema')     > 0
    OR INSTR(LOWER(text), 'content_blob')    > 0
    OR INSTR(LOWER(text), 'mime_type')       > 0)
ORDER  BY line;
-- If this returns nothing, the package spec is wrapped. Not fatal -- section 2
-- still gives the parameter names and types, which is enough to call it.


PROMPT ============ 4. WHICH SERVICE AND WHICH CONFIG EXIST ============

-- The workspace-level provider credential. gpt-4.1-mini should appear here.
SELECT * FROM apex_workspace_ai_services;

-- The application-level configs -- this is what p_config_static_id names, and
-- the reason section 5 failed. STATIC_ID and APPLICATION_ID are what I need.
SELECT * FROM apex_appl_ai_configs;

-- And agents, which 26.1 added alongside configs.
SELECT * FROM apex_appl_ai_agents;


PROMPT ============ 5. CAN AN ORDS HANDLER REACH IT? ============

-- THE QUESTION THAT DECIDES THE DESIGN.
--
-- Three attempts, cheapest first. Whichever one prints READY is the pattern the
-- endpoint will use. Each is wrapped so a failure does not stop the next.
DECLARE
  l_workspace VARCHAR2(200);
  l_app_id    NUMBER;
  l_static_id VARCHAR2(255);
  l_out       CLOB;

  PROCEDURE report(p_what IN VARCHAR2, p_ok IN BOOLEAN, p_msg IN VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(RPAD(p_what, 34)
      || CASE WHEN p_ok THEN 'WORKS  -- ' ELSE 'no     -- ' END
      || SUBSTR(p_msg, 1, 260));
  END;
BEGIN
  SELECT secret_value INTO l_workspace
  FROM   app_secrets WHERE secret_name = 'MAIL_WORKSPACE';

  BEGIN
    SELECT static_id, application_id
    INTO   l_static_id, l_app_id
    FROM   (SELECT static_id, application_id FROM apex_appl_ai_configs
            ORDER BY application_id)
    WHERE  ROWNUM = 1;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    DBMS_OUTPUT.PUT_LINE('*** apex_appl_ai_configs is EMPTY. No AI config exists '
      || 'in this workspace, so there is nothing to call. Someone has to create '
      || 'one in App Builder -> Shared Components -> Generative AI. Stopping. ***');
    RETURN;
  END;

  DBMS_OUTPUT.PUT_LINE('Workspace : ' || l_workspace);
  DBMS_OUTPUT.PUT_LINE('App       : ' || l_app_id);
  DBMS_OUTPUT.PUT_LINE('Static id : ' || l_static_id);
  DBMS_OUTPUT.PUT_LINE('--');

  -- A) Workspace only. What send_expense_mail does. Cheapest by far -- if this
  --    works the endpoint is trivial.
  BEGIN
    APEX_UTIL.SET_WORKSPACE(p_workspace => l_workspace);
    l_out := APEX_AI.GENERATE(p_prompt           => 'Reply with exactly: READY',
                              p_config_static_id => l_static_id);
    report('A) SET_WORKSPACE only', TRUE, l_out);
  EXCEPTION WHEN OTHERS THEN
    report('A) SET_WORKSPACE only', FALSE, SQLERRM);
  END;

  -- B) A full APEX session bound to the application that owns the config.
  --    Heavier: it builds session state per call, and must be torn down.
  BEGIN
    APEX_SESSION.CREATE_SESSION(p_app_id   => l_app_id,
                                p_page_id  => 1,
                                p_username => 'EXPENSE_APP_AI');
    l_out := APEX_AI.GENERATE(p_prompt           => 'Reply with exactly: READY',
                              p_config_static_id => l_static_id);
    report('B) CREATE_SESSION', TRUE, l_out);
    APEX_SESSION.DELETE_SESSION;
  EXCEPTION WHEN OTHERS THEN
    report('B) CREATE_SESSION', FALSE, SQLERRM);
    BEGIN APEX_SESSION.DELETE_SESSION; EXCEPTION WHEN OTHERS THEN NULL; END;
  END;

  -- C) Same, as a real workspace user rather than an invented name, in case
  --    the config lookup runs under the authenticated user's rights.
  BEGIN
    FOR u IN (SELECT user_name FROM apex_workspace_apex_users
              WHERE ROWNUM = 1)
    LOOP
      APEX_SESSION.CREATE_SESSION(p_app_id   => l_app_id,
                                  p_page_id  => 1,
                                  p_username => u.user_name);
      l_out := APEX_AI.GENERATE(p_prompt           => 'Reply with exactly: READY',
                                p_config_static_id => l_static_id);
      report('C) CREATE_SESSION as ' || u.user_name, TRUE, l_out);
      APEX_SESSION.DELETE_SESSION;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    report('C) CREATE_SESSION as real user', FALSE, SQLERRM);
    BEGIN APEX_SESSION.DELETE_SESSION; EXCEPTION WHEN OTHERS THEN NULL; END;
  END;

  DBMS_OUTPUT.PUT_LINE('--');
  DBMS_OUTPUT.PUT_LINE('The cheapest line that says WORKS is what the endpoint '
    || 'will do. If none of them work, send me all three messages.');
END;
/


--------------------------------------------------------------------------------
-- WHAT I NEED BACK
--
--   section 2  -- the full argument list for GENERATE (the important one)
--   section 4  -- the three views' contents
--   section 5  -- which of A, B or C printed WORKS
--
-- Section 3 may be empty if the package spec is wrapped. That is fine.
--
--
-- IF apex_appl_ai_configs IS EMPTY
--
-- Then the gpt-4.1-mini in your APEX footer is the BUILDER's own AI assistant
-- -- the one that helps you write SQL in the editor -- and not a config any
-- application can call. They are configured separately.
--
-- Fixing that is a five-minute job for whoever administers the workspace:
-- App Builder -> Shared Components -> Generative AI -> create a config against
-- the existing workspace AI service, give it a static id, note the app id. No
-- new credential and no DBA involvement, because the workspace service already
-- exists and already works -- section 5 of the first script proved the network
-- path by failing on a lookup rather than on TLS.
--
-- That would also raise a question worth settling early: which application
-- should own it? This expense app is ORDS-only and has no APEX application of
-- its own. A small dedicated app existing purely to hold the AI config is a
-- slightly odd artefact, but it is the normal way to do this, and it keeps the
-- config out of whatever unrelated app it would otherwise be borrowed from.
--------------------------------------------------------------------------------
