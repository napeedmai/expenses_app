--------------------------------------------------------------------------------
-- 89_drop_login_ladder.sql
--
-- Run as the APPLICATION SCHEMA, in SQL SCRIPTS. Idempotent.
-- Run AFTER 88. Supersedes the throttle half of it.
--
--   dev  = karyasiddhitest.trinamix.com, schema HRMS
--   prod = karyasiddhi.trinamix.com,     schema REPO
--
--
-- WE BUILT A SECOND LOCKOUT AND APEX ALREADY HAD ONE
-- --------------------------------------------------
-- Jayesh's question, and it was the right one: APEX already locks an account
-- after four wrong passwords. So what was the delay ladder for?
--
-- Very little, on inspection. If APEX locks at 4 and only an administrator can
-- undo it, then pausing 5, 10 and 60 seconds on the way to that lock buys
-- almost no protection -- an attacker gets four attempts either way. What it
-- reliably produced was a SECOND COUNTER that had to be kept in step with
-- APEX's, and every bug in this area for two days came from those two counters
-- disagreeing:
--
--   * ours reset every 15 minutes, APEX's never did, so an account locked
--     while our message promised a temporary pause
--   * a locked account was recorded as a failure by us, so an administrator's
--     unlock would have released APEX and left our throttle still blocking
--   * ACCOUNT_LOCKED is 'Yes'/'No', read into a VARCHAR2(1), swallowed as
--     ORA-06502, so a locked account was told to try again in 59 seconds
--
-- None of those were possible before there were two counters. So the ladder
-- goes, and APEX's lock is the only lockout in the system.
--
--
-- AND IT NEVER ADDRESSED THE THING IT WAS JUSTIFIED BY
-- ----------------------------------------------------
-- The stated reason for rate limiting was that the web build is on GitHub
-- Pages, so the login endpoint is public. But the ladder keyed on the EMAIL,
-- exactly as APEX's lock does. Someone trying one common password against 500
-- employee addresses gives each account a single failure: nothing locks,
-- nothing slows, and they may well get in.
--
-- Per-account controls cannot see that pattern. Per-IP limiting can, and we do
-- not do it. That is a separate piece of work and it should be argued for on
-- its own merits rather than assumed to be handled.
--
--
-- WHAT STAYS, BECAUSE APEX DOES NOT DO IT
-- ---------------------------------------
--   1. THE LOCK MESSAGE. IS_LOGIN_PASSWORD_VALID returns false for a locked
--      account, so without this the app says "invalid email or password" --
--      sending someone to re-check a password that is already correct.
--
--   2. THE COUNTDOWN. APEX's counter is invisible. People lock without warning
--      after months of ordinary mistyping.
--
--   3. THE RESET ON SUCCESS (script 80b). APEX's own login page clears the
--      counter on a successful sign-in; this endpoint never did, so failures
--      accumulated permanently. That is the reason accounts were sitting at 3
--      with nobody attacking anything.
--
--   4. XXKS_EXP_LOGIN_ATTEMPTS. APEX keeps one number and no history. This
--      table can answer whether an account was attacked or whether someone
--      mistyped three times over two months. It is now purely an audit log --
--      nothing reads it to make a decision.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF
SET LINESIZE 200


--------------------------------------------------------------------------------
-- 0. Guard: the deployed handler must be one this script is safe to replace.
--------------------------------------------------------------------------------
DECLARE
  l_nvl NUMBER;
  l_unl NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_nvl FROM user_ords_handlers h
  JOIN   user_ords_templates t ON t.id = h.template_id
  JOIN   user_ords_modules   m ON m.id = t.module_id
  WHERE  m.name LIKE 'expenses%' AND t.uri_template = 'auth/login' AND h.method = 'POST'
  AND    DBMS_LOB.INSTR(h.source, 'NVL(l_valid, FALSE) = FALSE') > 0;

  SELECT COUNT(*) INTO l_unl FROM user_ords_handlers h
  JOIN   user_ords_templates t ON t.id = h.template_id
  JOIN   user_ords_modules   m ON m.id = t.module_id
  WHERE  m.name LIKE 'expenses%' AND t.uri_template = 'auth/login' AND h.method = 'POST'
  AND    DBMS_LOB.INSTR(h.source, 'UNLOCK_ACCOUNT') > 0;

  IF l_nvl = 0 OR l_unl = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'The deployed auth/login handler is not a version this script recognises '
      || '(NVL guard: ' || l_nvl || ', UNLOCK_ACCOUNT: ' || l_unl || '). '
      || 'Send me its source first. Nothing changed.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('guard passed on ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/


--------------------------------------------------------------------------------
-- 1. The handler, with no throttle at all.
--
-- Identical to 88 apart from the removal of l_retry_after, wait_text, the 429
-- branch and the "try again in N seconds" clause. Everything that tells the
-- truth about the account is kept.
--
-- The handler must be replaced BEFORE the function is dropped in section 2, or
-- it spends the interval referencing an object that does not exist -- which is
-- the bare 403 with no body.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'auth/login',
    p_method      => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'[
DECLARE
  l_auth_header   VARCHAR2(4000) := :p_authorization;
  l_decoded       VARCHAR2(4000);
  l_colon_pos     PLS_INTEGER;
  l_username      VARCHAR2(300);
  l_password      VARCHAR2(300);
  l_apex_username VARCHAR2(300);
  l_workspace     VARCHAR2(200);
  -- VARCHAR2(10), NOT (1). ACCOUNT_LOCKED holds 'Yes'/'No'. Declared as
  -- VARCHAR2(1) the SELECT INTO raises ORA-06502, the handler swallows it, and
  -- a locked account reads as unlocked.
  l_locked        VARCHAR2(10) := 'No';
  l_apex_fails    NUMBER := 0;
  l_remaining     NUMBER;
  l_lock_at       NUMBER;
  l_access_token  VARCHAR2(4000);
  l_expires_in    NUMBER;
  l_valid         BOOLEAN := FALSE;

  PROCEDURE say_locked IS
  BEGIN
    :status_code := 403;
    APEX_JSON.OPEN_OBJECT;
    APEX_JSON.WRITE('error',
      'This account is locked after too many failed sign-in attempts. '
      || 'It cannot be unlocked by waiting -- ask your administrator to '
      || 'unlock it.');
    APEX_JSON.WRITE('account_locked', TRUE);
    APEX_JSON.CLOSE_OBJECT;
  END;
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
    XXKS_EXP_LOGIN_RECORD(l_username, 'FAIL');
    :status_code := 401;
    APEX_JSON.OPEN_OBJECT;
    APEX_JSON.WRITE('error', 'Invalid email or password.');
    APEX_JSON.CLOSE_OBJECT;
    RETURN;
  END IF;

  -- Workspace from configuration, not hardcoded. Prod's is not HRMSDEV, and a
  -- wrong workspace makes every correct password look wrong.
  BEGIN
    SELECT secret_value INTO l_workspace FROM XXKS_EXP_SECRETS
    WHERE  secret_name = 'APEX_WORKSPACE';
  EXCEPTION WHEN OTHERS THEN l_workspace := NULL;
  END;
  l_workspace := NVL(l_workspace, 'HRMSDEV');

  BEGIN
    SELECT TO_NUMBER(secret_value DEFAULT NULL ON CONVERSION ERROR)
    INTO   l_lock_at FROM XXKS_EXP_SECRETS WHERE secret_name = 'LOGIN_APEX_LOCK_AT';
  EXCEPTION WHEN OTHERS THEN l_lock_at := NULL;
  END;
  l_lock_at := NVL(l_lock_at, 4);

  -- Resolve the account and its lock state BEFORE any password work.
  -- IS_LOGIN_PASSWORD_VALID is case-sensitive on the username, so use the
  -- stored spelling rather than what the client sent.
  BEGIN
    APEX_UTIL.SET_WORKSPACE(l_workspace);
    BEGIN
      SELECT user_name, NVL(account_locked, 'No'), NVL(failed_access_attempts, 0)
      INTO   l_apex_username, l_locked, l_apex_fails
      FROM   apex_workspace_apex_users
      WHERE  UPPER(user_name) = UPPER(l_username) AND ROWNUM = 1;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        l_apex_username := l_username; l_locked := 'No'; l_apex_fails := 0;
    END;
  EXCEPTION
    WHEN OTHERS THEN
      l_apex_username := l_username; l_locked := 'No'; l_apex_fails := 0;
  END;

  -- A locked account fails EVERY password, including the right one.
  --
  -- Deliberately NOT recorded as a failure: the password was never checked,
  -- and logging it would make the audit trail read as though someone were
  -- guessing when they were simply locked out.
  IF UPPER(l_locked) IN ('Y', 'YES') THEN
    say_locked;
    RETURN;
  END IF;

  BEGIN
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
    XXKS_EXP_LOGIN_RECORD(l_username, 'FAIL');

    -- Re-read: that failure may have been the one that locked the account, and
    -- the person should be told now rather than on their next attempt.
    BEGIN
      SELECT NVL(account_locked, 'No'), NVL(failed_access_attempts, 0)
      INTO   l_locked, l_apex_fails
      FROM   apex_workspace_apex_users
      WHERE  UPPER(user_name) = UPPER(l_username) AND ROWNUM = 1;
    EXCEPTION WHEN OTHERS THEN l_locked := 'No'; l_apex_fails := l_apex_fails + 1;
    END;

    IF UPPER(l_locked) IN ('Y', 'YES') THEN
      say_locked;
      RETURN;
    END IF;

    -- The countdown. APEX's counter is the one that decides, and nobody can
    -- see it -- which is how people lock without warning. Only announced at 1
    -- or 2 remaining: saying "3 attempts remaining" after a single typo is
    -- alarming for no reason and teaches people to ignore the line.
    l_remaining := l_lock_at - l_apex_fails;

    :status_code := 401;
    APEX_JSON.OPEN_OBJECT;
    APEX_JSON.WRITE('error', 'Invalid email or password.'
      || CASE WHEN l_remaining BETWEEN 1 AND 2
              THEN ' ' || l_remaining || ' attempt'
                   || CASE WHEN l_remaining = 1 THEN '' ELSE 's' END
                   || ' remaining before this account is locked.'
              ELSE '' END);
    IF l_remaining BETWEEN 0 AND 2 THEN
      APEX_JSON.WRITE('attempts_remaining', GREATEST(l_remaining, 0));
    END IF;
    APEX_JSON.CLOSE_OBJECT;
    RETURN;
  END IF;

  XXKS_EXP_LOGIN_RECORD(l_username, 'OK');

  -- CLEAR APEX'S CUMULATIVE FAILURE COUNTER, which is what APEX's own login
  -- page does on a successful sign-in and what this endpoint has never done.
  --
  -- Without it the counter only ever goes UP. Every mistyped password through
  -- this app is permanent, so people drift toward the lock threshold over
  -- months of ordinary typing and eventually lock for no reason -- which is
  -- why JAYESH.GULVE and KAUSHIK.SHANKAR were sitting at 3 with nobody
  -- attacking anything. Once locked, a successful login is impossible, so the
  -- only way back is an administrator.
  --
  -- UNLOCK_ACCOUNT is the only call APEX exposes that resets the count; there
  -- is no reset-attempts-only procedure -- checked against HTMLDB_UTIL rather
  -- than assumed. It cannot unlock anybody here: a locked account cannot
  -- produce a correct-password result in the first place, so this line is
  -- unreachable for one.
  --
  -- Wrapped and swallowed. Bookkeeping must never turn a successful login into
  -- an error.
  BEGIN
    APEX_UTIL.UNLOCK_ACCOUNT(p_user_name => l_apex_username);
  EXCEPTION
    WHEN OTHERS THEN NULL;
  END;

  :status_code := 200;

  FOR r IN (
    SELECT e.empid,
           e.first_name || ' ' || e.last_name AS display_name,
           e.ecode,
           CASE WHEN EXISTS (SELECT 1 FROM project_manager pm
                             WHERE pm.project_manager_empid = e.empid)
                THEN 'Y' ELSE 'N' END AS is_reporting_manager,
           XXKS_EXP_IS_FINANCE_MANAGER(e.empid) AS is_fin_mgr
    FROM   apex_workspace_apex_users awau, employeedetails e
    WHERE  UPPER(awau.user_name) = UPPER(e.company_email)
      AND  UPPER(awau.user_name) = UPPER(l_username)
      AND  UPPER(e.employeestatus) IN ('ACTIVE', 'RESIGNED')
      AND  UPPER(awau.user_name) LIKE '%TRINAMIX.COM'
  ) LOOP
    BEGIN
      XXKS_EXP_GET_OAUTH_ACCESS_TOKEN(l_access_token, l_expires_in);
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
    APEX_JSON.WRITE('is_finance_manager', r.is_fin_mgr);
    APEX_JSON.WRITE('session_token', XXKS_EXP_GENERATE_SESSION_TOKEN(r.empid));
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
    ]');

  -- DEFINE_HANDLER drops the handler's parameters with it. Both must go back or
  -- every login returns 500 with an unbound bind.
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'auth/login', p_method => 'POST',
    p_name => 'Authorization', p_bind_variable_name => 'p_authorization',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'auth/login', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
    p_source_type => 'HEADER', p_access_method => 'OUT');

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('auth/login rewritten: no throttle, honest messages.');
END;
/


--------------------------------------------------------------------------------
-- 2. Drop the ladder, now that nothing calls it.
--
-- Checked rather than assumed -- section 1 could have failed and SQL Scripts
-- does not stop on error.
--------------------------------------------------------------------------------
DECLARE
  l_refs NUMBER;
BEGIN
  SELECT (SELECT COUNT(*) FROM user_ords_handlers
          WHERE  DBMS_LOB.INSTR(LOWER(source), 'login_retry_after') > 0)
       + (SELECT COUNT(*) FROM user_source
          WHERE  name != 'XXKS_EXP_LOGIN_RETRY_AFTER'
          AND    INSTR(LOWER(text), 'login_retry_after') > 0)
  INTO   l_refs FROM dual;

  IF l_refs > 0 THEN
    RAISE_APPLICATION_ERROR(-20002,
      l_refs || ' reference(s) to login_retry_after remain -- section 1 did not '
      || 'take. Not dropping anything.');
  END IF;

  BEGIN
    EXECUTE IMMEDIATE 'DROP FUNCTION xxks_exp_login_retry_after';
    DBMS_OUTPUT.PUT_LINE('dropped xxks_exp_login_retry_after');
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE IN (-4043, -942) THEN
        DBMS_OUTPUT.PUT_LINE('already gone');
      ELSE RAISE; END IF;
  END;
END;
/

-- Configuration nothing reads any more. LOGIN_APEX_LOCK_AT and APEX_WORKSPACE
-- stay -- both are still used.
DELETE FROM xxks_exp_secrets
WHERE  secret_name IN ('LOGIN_DELAYS','LOGIN_MAX_FAILURES',
                       'LOGIN_WINDOW_MINUTES','LOGIN_BLOCK_MINUTES');
COMMIT;


--------------------------------------------------------------------------------
-- 3. Verify.
--------------------------------------------------------------------------------

-- a) The function is gone and nothing is broken. Expect zero rows from both.
SELECT object_name, object_type, status FROM user_objects
WHERE  object_name = 'XXKS_EXP_LOGIN_RETRY_AFTER';

SELECT object_name, object_type, status FROM user_objects
WHERE  object_name LIKE 'XXKS\_EXP\_%' ESCAPE '\' AND status != 'VALID';

-- b) No throttle left in any handler. Expect zero rows.
SELECT t.uri_template, h.method
FROM   user_ords_handlers  h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules   m ON m.id = t.module_id
WHERE  m.name LIKE 'expenses%'
AND    REGEXP_LIKE(h.source, 'login_retry_after|429', 'i');

-- c) The login handler kept both parameters. Expect 2 rows.
SELECT p.name, p.bind_variable_name, p.source_type, p.access_method
FROM   user_ords_parameters p
JOIN   user_ords_handlers   h ON h.id = p.handler_id
JOIN   user_ords_templates  t ON t.id = h.template_id
JOIN   user_ords_modules    m ON m.id = t.module_id
WHERE  m.name LIKE 'expenses%' AND t.uri_template = 'auth/login' AND h.method = 'POST'
ORDER  BY p.name;

-- d) Remaining configuration.
SELECT secret_name, secret_value FROM xxks_exp_secrets
WHERE  secret_name LIKE '%LOGIN%' OR secret_name = 'APEX_WORKSPACE'
ORDER  BY secret_name;

-- e) Who is currently at risk. Anyone at lock_at - 1 gets a warning on their
--    next mistake; anyone locked needs an administrator.
SELECT user_name, account_locked, failed_access_attempts
FROM   apex_workspace_apex_users
WHERE  failed_access_attempts > 0 OR account_locked = 'Yes'
ORDER  BY failed_access_attempts DESC;


--------------------------------------------------------------------------------
-- 4. Test, after an administrator unlocks the account.
--
--   BEGIN
--     APEX_UTIL.SET_WORKSPACE(p_workspace => 'HRMSDEV');
--     APEX_UTIL.UNLOCK_ACCOUNT(p_user_name => 'DEEPAN.CHANDRASEKAR@TRINAMIX.COM');
--   END;
--   /
--
-- Expected, from a clean state, with no waiting at any point:
--
--   wrong password 1   401  "Invalid email or password."
--   wrong password 2   401  "... 2 attempts remaining before this account is locked."
--   wrong password 3   401  "... 1 attempt remaining before this account is locked."
--   wrong password 4   403  "This account is locked ... ask your administrator"
--   any attempt after  403  same message, and the password is never checked
--
-- The app needs a fresh bundle for the LoginScreen change that stopped it
-- discarding these messages: npx expo start -c.
--
-- The audit trail, which is now the only thing XXKS_EXP_LOGIN_ATTEMPTS is for:
--
--   SELECT attempted_at, outcome FROM xxks_exp_login_attempts
--   WHERE  email_upper = UPPER('you@trinamix.com')
--   ORDER  BY attempted_at DESC FETCH FIRST 10 ROWS ONLY;
--
-- Note there is no row for an attempt made while locked -- by design; the
-- password was never checked, so recording a failure would misrepresent it.
--------------------------------------------------------------------------------
