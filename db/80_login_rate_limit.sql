--------------------------------------------------------------------------------
-- 80_login_rate_limit.sql
--
-- Run as the APPLICATION SCHEMA, in SQL SCRIPTS. Idempotent.
-- ** DEV (HRMS) FIRST, AND TEST IT THERE. ** Section 6 is the test.
--
--
-- WHY
-- ---
-- POST /expenses/auth/login has no limit of any kind. Nothing counts failures,
-- nothing blocks, nothing slows down. That was survivable while the only way to
-- reach it was from a machine you controlled. It is not survivable now:
--
--   * the web build is on GitHub Pages, so the login page is public
--   * a store build puts API_BASE_URL in any downloaded .ipa or .apk, readable
--     in minutes -- distribution never protected the endpoint
--   * usernames are company email addresses, so they are not secret
--   * a wrong password costs an attacker exactly one round trip
--
-- 50_fix_login_null_bypass.sql fixed CORRECTNESS -- a wrong password no longer
-- returns 200. It did nothing about VOLUME.
--
--
-- AND A SECOND REASON, FOUND BY TESTING RATHER THAN BY READING
-- ------------------------------------------------------------
-- I claimed APEX_UTIL.IS_LOGIN_PASSWORD_VALID records nothing, and a direct
-- call in DIAGNOSE_LOGIN_LOCKOUT.sql agreed -- the counter did not move. Wrong.
-- Failing a login through the actual app DOES increment FAILED_ACCESS_ATTEMPTS,
-- and the account locks on the fourth try. The direct call did not reproduce the
-- handler's path; the app did. The measurement through the real path wins.
--
-- Which means the lockout everyone assumed was protection is reachable from a
-- PUBLIC endpoint, and that makes it a weapon rather than a defence:
--
--   * addresses are firstname.lastname@trinamix.com -- the list is guessable
--   * four wrong passwords locks an account
--   * these are APEX WORKSPACE accounts, shared with everything else in the
--     workspace, so the lockout follows people into the HR system
--
-- One stranger with a staff list could lock the company out of APEX in minutes,
-- through our login form. BHEEMANI.SWATHI is already sitting locked at 4, which
-- shows it happens without anyone trying.
--
--
-- THE DESIGN, AND THE THINGS IT DELIBERATELY DOES NOT DO
-- ------------------------------------------------------
-- THREE failures for one email inside fifteen minutes blocks that email for
-- fifteen minutes. A correct password clears the count immediately.
--
-- THREE, not five, because APEX locks at FOUR. Ours has to trip first, or the
-- limiter is decoration -- the fourth attempt would sail through and lock a real
-- person out of the HR system.
--
-- IT DOES NOT FULLY PREVENT THE LOCKOUT ATTACK, and it is worth being plain
-- about that. APEX's counter is CUMULATIVE and never decays -- it resets only on
-- a successful login. So a patient attacker uses three attempts, waits out the
-- window, and the fourth still locks the account. What this buys is roughly a
-- 30x slowdown: a lockout now needs a fresh fifteen-minute window per account
-- rather than a single burst, and casual mistyping never reaches four.
--
-- Fully preventing it would mean resetting APEX's counter from our handler. That
-- was considered and rejected: the counter is shared with the APEX login page,
-- so clearing it weakens a control on the wider HRMS -- a system this project
-- does not own and should not quietly change. If the lockout DoS matters, the
-- right fix is a conversation with whoever administers APEX, not a side effect
-- buried in an expense app's login handler.
--
-- NO SLEEP ON FAILURE. The usual advice is to add a second or two of delay, and
-- it is wrong here. An ORDS handler holds a connection-pool slot for its whole
-- life, so a deliberate delay hands an attacker a way to exhaust the pool with
-- a few hundred slow requests and take the whole API down -- a worse outcome
-- than the guessing. Counting is nearly free and cannot be turned against us.
-- (This is the same pool whose ORDS_PUBLIC_USER being locked took dev down
-- completely in July.)
--
-- THE BLOCK IS TEMPORARY, NOT A LOCKOUT. Emails are public, so a permanent lock
-- on failures is a denial-of-service anyone can aim at any employee: fail five
-- times against their address and they cannot work. Fifteen minutes makes
-- guessing hopeless -- roughly 480 attempts a day against a single account --
-- while a real person who mistyped waits through one tea break at worst.
--
-- THE THROTTLE APPLIES TO ADDRESSES THAT DO NOT EXIST. Throttling only real
-- accounts would leak the staff list: try an address, see whether it can be
-- locked, learn who works here. Every email is counted the same way.
--
-- NO CAPTCHA, NO IP BLOCKING. REMOTE_ADDR behind the load balancer is the load
-- balancer, so per-IP rules would either do nothing or block the whole company
-- at once. If a real attack happens, the useful lever is at the network edge,
-- not in PL/SQL.
--
--
-- WHAT THIS COSTS A NORMAL USER
-- -----------------------------
-- Nothing. Four wrong passwords in a quarter of an hour is already someone who
-- has forgotten it, and the fifth tells them to wait rather than letting them
-- keep guessing at their own account.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF


--------------------------------------------------------------------------------
-- 0. Prerequisites.
--------------------------------------------------------------------------------
DECLARE
  l_n NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Connected as: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
  DBMS_OUTPUT.PUT_LINE('  HRMS = dev, REPO = PRODUCTION.');

  SELECT COUNT(*) INTO l_n
  FROM   user_ords_handlers h
  JOIN   user_ords_templates t ON t.id = h.template_id
  JOIN   user_ords_modules m   ON m.id = t.module_id
  WHERE  m.name = 'expenses.employee'
  AND    t.uri_template = 'auth/login' AND h.method = 'POST';

  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'auth/login has no handler here. Run 50_fix_login_null_bypass.sql first '
      || '-- this script replaces that handler and needs it to exist. '
      || 'Nothing changed.');
  END IF;

  SELECT COUNT(*) INTO l_n FROM user_tables WHERE table_name = 'APP_SECRETS';
  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001, 'No APP_SECRETS here. Nothing changed.');
  END IF;

  DBMS_OUTPUT.PUT_LINE('Prerequisites OK.');
END;
/


--------------------------------------------------------------------------------
-- 1. Thresholds -- configuration, not literals.
--
-- So they can be tightened during an incident without a code change, and
-- loosened for a test without editing a function.
--------------------------------------------------------------------------------
DECLARE
  PROCEDURE seed(p_name IN VARCHAR2, p_value IN VARCHAR2, p_what IN VARCHAR2) IS
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n FROM app_secrets WHERE secret_name = p_name;
    IF l_n = 0 THEN
      INSERT INTO app_secrets (secret_name, secret_value) VALUES (p_name, p_value);
      DBMS_OUTPUT.PUT_LINE('  ' || RPAD(p_name, 24) || p_value || '  -- ' || p_what);
    ELSE
      DBMS_OUTPUT.PUT_LINE('  ' || RPAD(p_name, 24) || 'already set, left alone');
    END IF;
  END;
BEGIN
  seed('LOGIN_MAX_FAILURES',   '3',  'failures allowed inside the window');
  seed('LOGIN_WINDOW_MINUTES', '15', 'how far back failures are counted');
  seed('LOGIN_BLOCK_MINUTES',  '15', 'how long a block lasts');
  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 2. EXPENSE_LOGIN_ATTEMPTS
--
-- Deliberately NOT storing the password, nor any hash of it, nor the
-- Authorization header. A failed-login table is a natural place for someone to
-- later add "just the first few characters, to help debugging", and there is no
-- version of that which is safe. Email, time, outcome.
--------------------------------------------------------------------------------
DECLARE
  l_n NUMBER;
BEGIN
  -- If a table of ours already exists, confirm it is OURS before trusting it.
  -- HRMS is a shared schema carrying ~190 objects from other systems, and
  -- "the table is already there" is not the same as "the table is right".
  SELECT COUNT(*) INTO l_n FROM user_tables WHERE table_name = 'EXPENSE_LOGIN_ATTEMPTS';
  IF l_n > 0 THEN
    SELECT COUNT(*) INTO l_n FROM user_tab_columns
    WHERE  table_name = 'EXPENSE_LOGIN_ATTEMPTS'
    AND    column_name IN ('EMAIL_UPPER','OUTCOME','ATTEMPTED_AT');

    IF l_n = 3 THEN
      DBMS_OUTPUT.PUT_LINE('EXPENSE_LOGIN_ATTEMPTS already exists and matches -- left alone.');
      RETURN;
    END IF;

    RAISE_APPLICATION_ERROR(-20003,
      'A table called EXPENSE_LOGIN_ATTEMPTS exists here but does not have the '
      || 'columns this expects. It belongs to something else. Rename ours before '
      || 'continuing -- do NOT write into a table another system owns. '
      || 'Nothing changed.');
  END IF;

  EXECUTE IMMEDIATE q'[
    CREATE TABLE expense_login_attempts (
      id           NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      email_upper  VARCHAR2(300) NOT NULL,
      outcome      VARCHAR2(4)   NOT NULL,
      attempted_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      CONSTRAINT ck_exp_login_outcome CHECK (outcome IN ('OK','FAIL'))
    )]';

  -- The only query that runs on every login: failures for this email since a
  -- cutoff. Both columns, in that order, so it is an index range scan.
  EXECUTE IMMEDIATE
    'CREATE INDEX ix_expense_login_attempts ON expense_login_attempts (email_upper, attempted_at)';

  DBMS_OUTPUT.PUT_LINE('EXPENSE_LOGIN_ATTEMPTS created.');
END;
/


--------------------------------------------------------------------------------
-- 3. expense_login_record
--
-- AUTONOMOUS. The login handler does not commit on its failure paths -- it
-- writes a response and returns -- so without its own transaction the record of
-- a failed attempt would roll back and the limiter would never count anything.
--
-- It also swallows every error. A limiter that can break a login is worse than
-- no limiter: the failure mode has to be "we stopped counting", never "nobody
-- can sign in".
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE expense_login_record(
  p_email   IN VARCHAR2,
  p_outcome IN VARCHAR2
) IS
  PRAGMA AUTONOMOUS_TRANSACTION;
  l_email VARCHAR2(300) := UPPER(SUBSTR(TRIM(p_email), 1, 300));
BEGIN
  IF l_email IS NULL THEN
    ROLLBACK;
    RETURN;
  END IF;

  IF p_outcome = 'OK' THEN
    -- A correct password clears the count immediately. Someone who finally
    -- remembers their password on the fourth try should not be one mistake away
    -- from a block for the rest of the window.
    DELETE FROM expense_login_attempts WHERE email_upper = l_email;
  END IF;

  INSERT INTO expense_login_attempts (email_upper, outcome) VALUES (l_email, p_outcome);

  -- Opportunistic housekeeping, roughly one call in fifty. A scheduled job
  -- would be tidier, but it is one more thing to install per environment and
  -- to notice has stopped running; this cannot silently stop while logins
  -- continue.
  IF DBMS_RANDOM.VALUE < 0.02 THEN
    DELETE FROM expense_login_attempts WHERE attempted_at < SYSTIMESTAMP - INTERVAL '2' DAY;
  END IF;

  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;   -- never let bookkeeping break a sign-in
END expense_login_record;
/


--------------------------------------------------------------------------------
-- 4. expense_login_retry_after
--
-- Returns seconds until this email may try again, or 0 to allow.
--
-- Counts failures since the LATEST successful login, so a clean sign-in really
-- does reset the window even if the DELETE above ever fails.
--
-- On any error it returns 0 -- ALLOW. Same reasoning as above: if the limiter
-- breaks, people can still work.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION expense_login_retry_after(p_email IN VARCHAR2) RETURN NUMBER IS
  l_email    VARCHAR2(300) := UPPER(SUBSTR(TRIM(p_email), 1, 300));
  l_max      NUMBER;
  l_window   NUMBER;
  l_block    NUMBER;
  l_fails    NUMBER;
  l_last     TIMESTAMP;
  l_secs     NUMBER;

  FUNCTION cfg(p_name IN VARCHAR2, p_default IN NUMBER) RETURN NUMBER IS
    l_v VARCHAR2(200);
  BEGIN
    SELECT secret_value INTO l_v FROM app_secrets WHERE secret_name = p_name;
    RETURN NVL(TO_NUMBER(l_v DEFAULT NULL ON CONVERSION ERROR), p_default);
  EXCEPTION WHEN OTHERS THEN RETURN p_default;
  END;
BEGIN
  IF l_email IS NULL THEN RETURN 0; END IF;

  l_max    := cfg('LOGIN_MAX_FAILURES',   5);
  l_window := cfg('LOGIN_WINDOW_MINUTES', 15);
  l_block  := cfg('LOGIN_BLOCK_MINUTES',  15);

  SELECT COUNT(*), MAX(attempted_at)
  INTO   l_fails, l_last
  FROM   expense_login_attempts
  WHERE  email_upper = l_email
  AND    outcome = 'FAIL'
  AND    attempted_at > SYSTIMESTAMP - NUMTODSINTERVAL(l_window, 'MINUTE')
  AND    attempted_at > NVL((SELECT MAX(attempted_at) FROM expense_login_attempts
                             WHERE email_upper = l_email AND outcome = 'OK'),
                            TIMESTAMP '1970-01-01 00:00:00');

  IF l_fails < l_max THEN
    RETURN 0;
  END IF;

  -- Blocked. How much longer?
  l_secs := l_block * 60
          - (CAST(SYSTIMESTAMP AS DATE) - CAST(l_last AS DATE)) * 86400;

  RETURN GREATEST(CEIL(NVL(l_secs, 0)), 0);
EXCEPTION
  WHEN OTHERS THEN
    RETURN 0;   -- fail open: a broken limiter must not lock the company out
END expense_login_retry_after;
/


--------------------------------------------------------------------------------
-- 5. The login handler, with the limiter wired in.
--
-- Byte-for-byte from 50_fix_login_null_bypass.sql apart from four inserted
-- lines -- the throttle check, and three calls to record the outcome. Lifted
-- programmatically, not retyped: this handler contains the NVL guard that took
-- two sessions to find, and reconstructing it from memory has gone wrong here
-- before.
--
-- Note it still resolves the workspace at deploy time rather than hardcoding
-- it. Dev is HRMSDEV, prod is not, and a wrong workspace fails as "Invalid
-- email or password" with nothing to explain why.
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
  l_retry_after   NUMBER;
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
    expense_login_record(l_username, 'FAIL');
    :status_code := 401;
    APEX_JSON.OPEN_OBJECT;
    APEX_JSON.WRITE('error', 'Invalid email or password.');
    APEX_JSON.CLOSE_OBJECT;
    RETURN;
  END IF;

  -- THROTTLE, checked before any password work so a blocked caller costs the
  -- database one indexed lookup and nothing else.
  --
  -- Applied to ANY email, whether or not it exists. Throttling only real
  -- accounts would turn this into an account-enumeration oracle: guess an
  -- address, see whether it can be locked out, learn who works here.
  l_retry_after := expense_login_retry_after(l_username);
  IF l_retry_after > 0 THEN
    :status_code := 429;
    APEX_JSON.OPEN_OBJECT;
    APEX_JSON.WRITE('error', 'Too many sign-in attempts. Try again in '
      || CEIL(l_retry_after / 60) || ' minute(s).');
    APEX_JSON.WRITE('retry_after_seconds', l_retry_after);
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
    expense_login_record(l_username, 'FAIL');
    :status_code := 401;
    APEX_JSON.OPEN_OBJECT;
    APEX_JSON.WRITE('error', 'Invalid email or password.');
    APEX_JSON.CLOSE_OBJECT;
    RETURN;
  END IF;

  expense_login_record(l_username, 'OK');

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
-- 6. TEST IT. This is the point of running on dev first.
--
-- Tests the LIMITER, not the login endpoint -- it calls the same two programs
-- the handler calls, so a pass here means the counting and blocking are right.
-- Section 7 then checks it end to end over HTTP, which is the part that proves
-- the handler is actually wired to them.
--
-- Uses an address that cannot belong to anyone, and cleans up after itself.
--------------------------------------------------------------------------------
DECLARE
  c_email  CONSTANT VARCHAR2(300) := 'ratelimit.test@example.invalid';
  l_max    NUMBER;
  l_secs   NUMBER;
  l_pass   BOOLEAN := TRUE;

  PROCEDURE check_that(p_what IN VARCHAR2, p_ok IN BOOLEAN, p_detail IN VARCHAR2) IS
  BEGIN
    IF NOT p_ok THEN l_pass := FALSE; END IF;
    DBMS_OUTPUT.PUT_LINE(RPAD(CASE WHEN p_ok THEN '  PASS  ' ELSE '  FAIL  ' END, 8)
      || RPAD(p_what, 46) || p_detail);
  END;
BEGIN
  DELETE FROM expense_login_attempts WHERE email_upper = UPPER(c_email);
  COMMIT;

  SELECT TO_NUMBER(secret_value) INTO l_max
  FROM   app_secrets WHERE secret_name = 'LOGIN_MAX_FAILURES';

  DBMS_OUTPUT.PUT_LINE('Threshold is ' || l_max || ' failures.');
  DBMS_OUTPUT.PUT_LINE('');

  -- 1. A fresh address is allowed.
  check_that('fresh address is allowed', expense_login_retry_after(c_email) = 0,
             'retry_after = ' || expense_login_retry_after(c_email));

  -- 2. One short of the threshold is still allowed. This is the case that
  --    matters most: an off-by-one here locks people out a try early.
  FOR i IN 1 .. l_max - 1 LOOP
    expense_login_record(c_email, 'FAIL');
  END LOOP;
  l_secs := expense_login_retry_after(c_email);
  check_that((l_max - 1) || ' failures -> still allowed', l_secs = 0,
             'retry_after = ' || l_secs);

  -- 3. The threshold blocks.
  expense_login_record(c_email, 'FAIL');
  l_secs := expense_login_retry_after(c_email);
  check_that(l_max || ' failures -> blocked', l_secs > 0,
             'retry_after = ' || l_secs || 's (~' || CEIL(l_secs/60) || ' min)');

  -- 4. Case does not matter. Someone typing Jayesh.Gulve@... must not get a
  --    fresh five attempts by changing the capitalisation.
  check_that('blocking is case-insensitive',
             expense_login_retry_after(UPPER(c_email)) > 0,
             'retry_after = ' || expense_login_retry_after(UPPER(c_email)));

  -- 5. A different address is unaffected. If this fails the limiter is global
  --    and the first attacker takes the whole company offline.
  check_that('a different address is unaffected',
             expense_login_retry_after('someone.else@example.invalid') = 0, '');

  -- 6. A correct password clears it immediately.
  expense_login_record(c_email, 'OK');
  l_secs := expense_login_retry_after(c_email);
  check_that('successful login clears the block', l_secs = 0,
             'retry_after = ' || l_secs);

  -- 7. And the count really did reset -- not just one attempt short.
  FOR i IN 1 .. l_max - 1 LOOP
    expense_login_record(c_email, 'FAIL');
  END LOOP;
  check_that('counting restarts after a success',
             expense_login_retry_after(c_email) = 0,
             (l_max - 1) || ' more failures, still allowed');

  -- 8. A NULL email must not raise. The handler calls this before it knows
  --    whether the header even parsed.
  BEGIN
    l_secs := expense_login_retry_after(NULL);
    expense_login_record(NULL, 'FAIL');
    check_that('NULL email is handled', l_secs = 0, '');
  EXCEPTION WHEN OTHERS THEN
    check_that('NULL email is handled', FALSE, SQLERRM);
  END;

  DELETE FROM expense_login_attempts WHERE email_upper = UPPER(c_email);
  COMMIT;

  DBMS_OUTPUT.PUT_LINE('');
  DBMS_OUTPUT.PUT_LINE(CASE WHEN l_pass
    THEN '=== ALL CHECKS PASSED. Now do section 7 over HTTP. ==='
    ELSE '=== SOMETHING FAILED -- do not deploy this to prod. ===' END);
END;
/


--------------------------------------------------------------------------------
-- 7. Then test it for real, over HTTP, against DEV.
--
-- Section 6 proves the limiter counts. Only this proves the HANDLER calls it --
-- and a handler that compiles but never invokes the check would pass section 6
-- perfectly.
--
--   POST https://karyasiddhitest.trinamix.com/ords/repo/expenses/auth/login
--   Authorization: Basic <base64 of  your.email@trinamix.com:wrongpassword>
--
--   attempts 1-3   -> 401  "Invalid email or password."
--   attempt  4     -> 429  "Too many sign-in attempts. Try again in 15 minute(s)."
--
-- ** USE A THROWAWAY ADDRESS, NOT YOUR OWN. ** Three real failures put a real
-- account one attempt from an APEX lock, and an address that does not exist is
-- throttled exactly the same way -- that is deliberate, so it makes a perfectly
-- good test subject:
--
--   Authorization: Basic <base64 of  nobody.here@trinamix.com:wrongpassword>
--
-- Then confirm APEX's counter did NOT move for it, which is the point of
-- stopping at three:
--
--   SELECT user_name, failed_access_attempts, account_locked
--   FROM   apex_workspace_apex_users
--   WHERE  UPPER(user_name) = UPPER('your.email@trinamix.com');
--
-- Then, WITHOUT waiting, retry with the CORRECT password:
--
--   -> still 429. The block is on the address, not on the guess. This is the
--      behaviour to be sure about, because it is what will happen to a real
--      person who mistypes five times and then gets it right.
--
-- Wait out the window, or clear it by hand:
--
--   DELETE FROM expense_login_attempts WHERE email_upper = UPPER('your.email@trinamix.com');
--   COMMIT;
--
-- Watch what the limiter is seeing:
--
--   SELECT email_upper, outcome, attempted_at
--   FROM   expense_login_attempts ORDER BY id DESC FETCH FIRST 20 ROWS ONLY;
--
--   SELECT email_upper, COUNT(*) AS fails, MAX(attempted_at) AS last_try,
--          expense_login_retry_after(email_upper) AS blocked_for_s
--   FROM   expense_login_attempts
--   WHERE  outcome = 'FAIL'
--   AND    attempted_at > SYSTIMESTAMP - INTERVAL '15' MINUTE
--   GROUP  BY email_upper
--   HAVING COUNT(*) >= 3
--   ORDER  BY 2 DESC;
--   -- Worth looking at occasionally after launch. Several addresses failing
--   -- together is someone spraying; one address failing repeatedly is usually
--   -- a person with a stale saved password.
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- 8. Verify the deployment itself.
--------------------------------------------------------------------------------
SELECT object_name, object_type, status FROM user_objects
WHERE  object_name IN ('EXPENSE_LOGIN_RECORD','EXPENSE_LOGIN_RETRY_AFTER','EXPENSE_LOGIN_ATTEMPTS')
ORDER  BY object_name;
-- All VALID.

SELECT line, position, text FROM user_errors
WHERE  name IN ('EXPENSE_LOGIN_RECORD','EXPENSE_LOGIN_RETRY_AFTER') ORDER BY name, line;
-- Empty.

-- The handler must call the limiter AND still carry the NVL guard. A rebuild
-- that quietly dropped the guard would reopen the bug where every password
-- worked -- which is exactly what happened once already.
SELECT h.method,
       CASE WHEN INSTR(h.source, 'expense_login_retry_after') > 0    THEN 'Y' ELSE 'N' END AS throttled,
       CASE WHEN INSTR(h.source, 'expense_login_record') > 0 THEN 'Y' ELSE 'N' END AS records,
       CASE WHEN INSTR(UPPER(h.source), 'NVL(L_VALID, FALSE) = FALSE') > 0
            THEN 'Y' ELSE 'N' END AS nvl_guard_intact,
       CASE WHEN INSTR(h.source, '##WORKSPACE##') > 0 THEN 'N -- NOT SUBSTITUTED' ELSE 'Y' END AS workspace_resolved,
       (SELECT COUNT(*) FROM user_ords_parameters pa
        WHERE  pa.handler_id = h.id AND UPPER(pa.name) = 'AUTHORIZATION') AS auth_param
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee' AND t.uri_template = 'auth/login';
-- Expect: POST, Y, Y, Y, Y, 1.

-- auth/login must still be covered by NO privilege -- a pattern here makes
-- login impossible by construction. MUST RETURN NO ROWS.
SELECT pm.pattern, pr.name FROM user_ords_privilege_mappings pm
JOIN   user_ords_privileges pr ON pr.id = pm.privilege_id
WHERE  pm.pattern LIKE '/expenses/auth%';


--------------------------------------------------------------------------------
-- 9. Before prod
--
-- Run 80 there too, then repeat section 7 against karyasiddhi.trinamix.com with
-- a throwaway wrong password on your own account. Five 401s and a 429.
--
-- If you lock yourself out mid-test, the DELETE in section 7 clears it.
--
--
-- WHAT THIS DOES NOT PROTECT AGAINST, so nobody assumes otherwise
--
--   * A slow spray -- two attempts per address per fifteen minutes, across many
--     addresses, stays under the threshold forever. That is the accepted trade
--     for not locking real people out. The query in section 7 is how you would
--     see it.
--
--   * THE LOCKOUT ATTACK, fully. Three attempts, wait fifteen minutes, and the
--     fourth still locks the account -- because APEX's counter is cumulative and
--     only a successful login clears it. This makes that roughly 30x slower and
--     stops ordinary mistyping from ever reaching a lock. It does not close it.
--     Closing it means changing APEX's own lockout behaviour, which belongs to
--     whoever administers APEX. Worth raising with them; not worth doing
--     silently from here.
--   * A stolen valid password. Rate limiting is about guessing, not theft.
--   * Anything at the network layer. If a real attack arrives, the lever is a
--     WAF or the load balancer, not PL/SQL.
--
-- And the outstanding item this does not replace: the production password
-- exposed in July still needs rotating.
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- 10. RUN THIS FIRST if you have any doubt about name collisions.
--
-- Read-only. HRMS is shared with other systems and these names were originally
-- LOGIN_ATTEMPTS / LOGIN_RETRY_AFTER / LOGIN_RECORD_ATTEMPT -- generic enough
-- that another HR module could plausibly already own one. They are namespaced
-- now, but confirm rather than assume.
--
-- MUST RETURN NO ROWS. Anything here is not ours and must not be overwritten.
--------------------------------------------------------------------------------
SELECT object_name, object_type, status, created, last_ddl_time
FROM   user_objects
WHERE  object_name IN ('EXPENSE_LOGIN_ATTEMPTS','EXPENSE_LOGIN_RECORD',
                       'EXPENSE_LOGIN_RETRY_AFTER','IX_EXP_LOGIN_ATTEMPTS')
ORDER  BY object_name;
-- After a successful run this returns exactly those four, all VALID, created
-- today. Before the first run it should be empty.

-- And nothing else on this schema is already called anything close:
SELECT object_name, object_type
FROM   user_objects
WHERE  (object_name LIKE '%LOGIN%' OR object_name LIKE '%RATE_LIMIT%')
AND    object_name NOT LIKE 'EXPENSE#_%' ESCAPE '#'
ORDER  BY object_name;
-- Rows here are other systems' objects. That is fine -- it is only a problem if
-- one of them collides with a name above, which the first query would show.
