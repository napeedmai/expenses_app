--------------------------------------------------------------------------------
-- 50_fix_login_null_bypass.sql
--
-- SECURITY FIX. Run on BOTH environments: HRMS and REPO.
-- The APEX workspace is resolved at deploy time, so the file is identical
-- for both.
--
-- THE VULNERABILITY
-- -----------------
-- POST /expenses/auth/login accepted ANY password for a valid username.
-- Anyone knowing a colleague's email could sign in as them and see, submit
-- and approve their expenses.
--
-- ROOT CAUSE - PL/SQL three-valued logic
-- --------------------------------------
-- The guard was:
--
--     l_valid BOOLEAN := FALSE;
--     ...
--     l_valid := APEX_UTIL.IS_LOGIN_PASSWORD_VALID(...);
--     IF NOT l_valid THEN  ...reject...  RETURN;  END IF;
--     ...issue session and OAuth tokens...
--
-- For a wrong password APEX_UTIL.IS_LOGIN_PASSWORD_VALID returns NULL here,
-- not FALSE. In PL/SQL, NOT NULL evaluates to NULL, and an IF only executes
-- its branch when the condition is TRUE. NULL is not TRUE, so the rejection
-- was skipped and control fell straight through to the success path.
--
-- A BOOLEAN in PL/SQL has three states - TRUE, FALSE and NULL - and
-- "IF NOT x" silently does nothing for the third. Initialising the variable
-- to FALSE gave no protection because the assignment overwrote it with NULL.
--
-- This was hard to see because the obvious diagnostic hides it:
--     CASE WHEN l_valid THEN 'Y' ELSE 'N' END
-- renders NULL as 'N', identical to FALSE. The endpoint reported the
-- password as invalid and issued a token in the same response.
--
-- THE FIX
-- -------
--     IF NVL(l_valid, FALSE) = FALSE THEN  ...reject...  RETURN;  END IF;
--
-- NVL collapses NULL to FALSE before the test, so anything that is not
-- explicitly TRUE is rejected. The check now fails closed.
--
-- Section 3 verifies this against the live endpoint. Do not skip it.
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- 1. Redeploy the login handler with the corrected guard.
--------------------------------------------------------------------------------
DECLARE
  l_workspace VARCHAR2(128);
  l_source    CLOB;
BEGIN
  -- Resolve this environment's workspace rather than hardcoding it: dev is
  -- HRMS, prod is REPO, and the wrong value fails as "Invalid email or
  -- password" with nothing to explain why.
  SELECT workspace_name INTO l_workspace
  FROM (
    SELECT workspace_name, COUNT(*) AS c
    FROM   apex_workspace_apex_users
    WHERE  UPPER(workspace_name) != 'INTERNAL'
    GROUP  BY workspace_name
    ORDER  BY c DESC
  )
  WHERE ROWNUM = 1;

  DBMS_OUTPUT.PUT_LINE('Deploying login handler for workspace: ' || l_workspace);

  l_source := REPLACE(q'[
DECLARE
  l_auth_header   VARCHAR2(4000) := :p_authorization;
  l_decoded       VARCHAR2(4000);
  l_colon_pos     PLS_INTEGER;
  l_username      VARCHAR2(300);
  l_password      VARCHAR2(300);
  l_apex_username VARCHAR2(300);
  l_access_token  VARCHAR2(4000);
  l_expires_in    NUMBER;
  l_valid         BOOLEAN := FALSE;
BEGIN
  IF l_auth_header IS NULL OR SUBSTR(l_auth_header, 1, 6) != 'Basic ' THEN
    :status_code := 401;
    APEX_JSON.OPEN_OBJECT;
    APEX_JSON.WRITE('error', 'Missing or invalid Authorization header.');
    APEX_JSON.CLOSE_OBJECT;
    RETURN;
  END IF;

  l_decoded := UTL_RAW.CAST_TO_VARCHAR2(
                 UTL_ENCODE.BASE64_DECODE(
                   UTL_RAW.CAST_TO_RAW(SUBSTR(l_auth_header, 7))));

  l_colon_pos := INSTR(l_decoded, ':');
  IF l_colon_pos = 0 THEN
    :status_code := 401;
    APEX_JSON.OPEN_OBJECT;
    APEX_JSON.WRITE('error', 'Malformed credentials.');
    APEX_JSON.CLOSE_OBJECT;
    RETURN;
  END IF;

  -- Password may itself contain colons, so split on the FIRST one only.
  l_username := TRIM(SUBSTR(l_decoded, 1, l_colon_pos - 1));
  l_password := SUBSTR(l_decoded, l_colon_pos + 1);

  IF l_password IS NULL THEN
    :status_code := 401;
    APEX_JSON.OPEN_OBJECT;
    APEX_JSON.WRITE('error', 'Invalid email or password.');
    APEX_JSON.CLOSE_OBJECT;
    RETURN;
  END IF;

  BEGIN
    APEX_UTIL.SET_WORKSPACE('##WORKSPACE##');

    -- IS_LOGIN_PASSWORD_VALID is case-sensitive on the username; resolve the
    -- stored spelling rather than trusting what the client sent.
    BEGIN
      SELECT user_name INTO l_apex_username
      FROM   apex_workspace_apex_users
      WHERE  UPPER(user_name) = UPPER(l_username) AND ROWNUM = 1;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN l_apex_username := l_username;
    END;

    l_valid := APEX_UTIL.IS_LOGIN_PASSWORD_VALID(p_username => l_apex_username,
                                                 p_password => l_password);
  EXCEPTION
    WHEN OTHERS THEN l_valid := FALSE;
  END;

  -- SECURITY: NVL is load-bearing. IS_LOGIN_PASSWORD_VALID returns NULL for
  -- a wrong password, and "IF NOT l_valid" does NOT fire on NULL - NOT NULL
  -- is NULL, and IF only branches on TRUE. That let every wrong password
  -- fall through to the success path below. Reject anything not explicitly
  -- TRUE. Do not "simplify" this back to IF NOT l_valid.
  IF NVL(l_valid, FALSE) = FALSE THEN
    :status_code := 401;
    APEX_JSON.OPEN_OBJECT;
    APEX_JSON.WRITE('error', 'Invalid email or password.');
    APEX_JSON.CLOSE_OBJECT;
    RETURN;
  END IF;

  :status_code := 200;

  FOR r IN (
    SELECT e.empid,
           e.first_name || ' ' || e.last_name AS display_name,
           e.ecode,
           CASE WHEN EXISTS (SELECT 1 FROM project_manager pm
                             WHERE pm.project_manager_empid = e.empid)
                THEN 'Y' ELSE 'N' END AS is_reporting_manager,
           is_finance_manager(e.empid) AS is_finance_manager
    FROM   apex_workspace_apex_users awau, employeedetails e
    WHERE  UPPER(awau.user_name) = UPPER(e.company_email)
      AND  UPPER(awau.user_name) = UPPER(l_username)
      AND  UPPER(e.employeestatus) IN ('ACTIVE', 'RESIGNED')
      AND  UPPER(awau.user_name) LIKE '%TRINAMIX.COM'
  ) LOOP
    BEGIN
      get_oauth_access_token(l_access_token, l_expires_in);
    EXCEPTION
      WHEN OTHERS THEN
        :status_code := 500;
        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.WRITE('error', 'Logged in, but could not issue an access token: ' || SQLERRM);
        APEX_JSON.CLOSE_OBJECT;
        RETURN;
    END;

    APEX_JSON.OPEN_OBJECT;
    APEX_JSON.WRITE('empid', r.empid);
    APEX_JSON.WRITE('display_name', r.display_name);
    APEX_JSON.WRITE('ecode', r.ecode);
    APEX_JSON.WRITE('is_reporting_manager', r.is_reporting_manager);
    APEX_JSON.WRITE('is_finance_manager', r.is_finance_manager);
    APEX_JSON.WRITE('session_token', generate_session_token(r.empid));
    APEX_JSON.WRITE('access_token', l_access_token);
    APEX_JSON.WRITE('expires_in', l_expires_in);
    APEX_JSON.CLOSE_OBJECT;
    RETURN;
  END LOOP;

  :status_code := 403;
  APEX_JSON.OPEN_OBJECT;
  APEX_JSON.WRITE('error', 'This account is not linked to an active employee record.');
  APEX_JSON.CLOSE_OBJECT;
END;
]', '##WORKSPACE##', l_workspace);

  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'auth/login',
    p_method      => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source      => l_source);

  -- Mandatory: without this parameter :p_authorization is NULL on every
  -- request and login always 401s.
  ORDS.DEFINE_PARAMETER(
    p_module_name        => 'expenses.employee',
    p_pattern            => 'auth/login',
    p_method             => 'POST',
    p_name               => 'Authorization',
    p_bind_variable_name => 'p_authorization',
    p_source_type        => 'HEADER',
    p_param_type         => 'STRING',
    p_access_method      => 'IN');

  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 2. Confirm the deployed source contains the fix and no debug markers.
--    Expect: has_nvl_guard = Y, has_unsafe_guard = N, has_debug_marker = N
--------------------------------------------------------------------------------
SELECT CASE WHEN INSTR(UPPER(h.source), 'NVL(L_VALID, FALSE) = FALSE') > 0
            THEN 'Y' ELSE 'N' END AS has_nvl_guard,
       CASE WHEN REGEXP_INSTR(UPPER(h.source), 'IF[[:space:]]+NOT[[:space:]]+L_VALID[[:space:]]+THEN') > 0
            THEN 'Y' ELSE 'N' END AS has_unsafe_guard,
       CASE WHEN INSTR(UPPER(h.source), 'HANDLER_BUILD') > 0
            THEN 'Y' ELSE 'N' END AS has_debug_marker,
       REGEXP_SUBSTR(h.source, 'SET_WORKSPACE\(''([^'']+)''', 1, 1, NULL, 1) AS workspace,
       (SELECT COUNT(*) FROM user_ords_parameters pa
        WHERE  pa.handler_id = h.id AND UPPER(pa.name) = 'AUTHORIZATION') AS auth_param
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
  AND  t.uri_template = 'auth/login'
  AND  h.method = 'POST';


--------------------------------------------------------------------------------
-- 3. MANDATORY live test. The SQL above proves the source; only an HTTP call
--    proves the behaviour.
--
--    Auth type must be "No Auth" with the header set manually - Postman's
--    Basic Auth tab retains the last good password and will mislead you.
--
--    a) correct password  -> 200 with empid, session_token, access_token
--    b) WRONG password    -> 401 {"error":"Invalid email or password."}
--    c) unknown user      -> 401
--    d) empty password    -> 401
--
--    Run (b) at least twice. If ANY wrong-password attempt returns 200, the
--    endpoint is still open - redeploy and retest before leaving it live.
--
--    Build the header in PowerShell:
--      [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("user@trinamix.com:wrong-9999"))
--    then send:  Authorization: Basic <that string>
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- 4. Aftermath.
--
--    Anyone who knew a colleague's email could have signed in as them for as
--    long as this endpoint has been live. Worth considering:
--
--    - Rotate credentials that were shared or exposed during debugging.
--    - Session tokens issued during the exposure remain valid for 12 hours
--      (see generate_session_token). To invalidate every existing session at
--      once, rotate the signing key - every user simply logs in again:
--
--        UPDATE app_secrets
--        SET    secret_value = DBMS_RANDOM.STRING('X', 48)
--                              || RAWTOHEX(SYS_GUID()) || RAWTOHEX(SYS_GUID())
--        WHERE  secret_name = 'SESSION_TOKEN_KEY';
--        COMMIT;
--
--    - Review EXPENSES and EXPENSE_APPROVALS for activity that does not
--      match the employee it is attributed to.
--
--    Whether that is warranted depends on whether this was ever reachable
--    by anyone outside the team.
--------------------------------------------------------------------------------
