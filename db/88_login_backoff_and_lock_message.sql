--------------------------------------------------------------------------------
-- 88_login_backoff_and_lock_message.sql
--
-- Run as the APPLICATION SCHEMA, in SQL SCRIPTS. Idempotent.
-- Run AFTER 87. DEV FIRST -- and read section 6 before testing, because the
-- test can lock your own account and only an administrator can undo that.
--
--
-- TWO BUGS, FOUND BY TESTING RATHER THAN BY READING
-- -------------------------------------------------
--
-- 1. TWO COUNTERS, AND THE INVISIBLE ONE WINS.
--
--    Our limiter counted failures in a 15-MINUTE WINDOW. APEX's own counter is
--    CUMULATIVE and only clears on a successful login. So:
--
--      window 1:  3 failures -> ours says "wait 15 minutes"   APEX count = 3
--      window 2:  3 failures -> ours says "wait 15 minutes"   APEX count = 6
--
--    APEX locks at 4. The account was locked during window 2 while our limiter
--    reported a temporary 15-minute pause, because ours had reset and APEX's
--    had not. The user did everything our message told them to and got locked
--    anyway.
--
--    Fixed by counting the same thing APEX counts: failures SINCE THE LAST
--    SUCCESSFUL LOGIN, no window. The two now move together.
--
-- 2. IT REPORTED A LOCKED ACCOUNT AS A WRONG PASSWORD.
--
--    Once an account is locked, IS_LOGIN_PASSWORD_VALID returns false for
--    EVERY password including the correct one. The handler had no way to tell
--    that apart from a genuine mismatch, so it said "Invalid email or
--    password" -- sending the person off to re-check a password that was fine,
--    while the actual problem needed an administrator.
--
--    Fixed by reading ACCOUNT_LOCKED before doing any password work, and again
--    immediately after a failure, so the message is right at the moment it
--    changes.
--
--
-- THE LADDER
-- ----------
--    failure 1  ->  wait 5 seconds
--    failure 2  ->  wait 10 seconds
--    failure 3  ->  wait 1 minute
--    failure 4  ->  APEX locks the account; the message says so
--
-- Three rungs, not five, because APEX remains the backstop and locks at 4.
-- Giving five tries would have meant resetting APEX's counter after every
-- failure below our own threshold -- making this code the only thing standing
-- between the internet and the login endpoint. Not worth it for two extra
-- attempts.
--
-- The wait decays from the LAST failure, so after sitting out the pause you
-- get one more real attempt. That attempt is the one that reaches APEX and
-- locks, which is exactly the behaviour asked for.
--
--
-- ON TELLING PEOPLE THEIR ACCOUNT IS LOCKED
-- -----------------------------------------
-- A "your account is locked" message for a real address, and "invalid email or
-- password" for one that does not exist, does tell an attacker which addresses
-- are real. The previous code avoided that by never distinguishing anything.
--
-- Here the trade is worth making, and it should be a decision rather than an
-- accident: company addresses are firstname.lastname@trinamix.com and already
-- guessable, so the oracle leaks almost nothing -- while the alternative leaves
-- a locked-out employee re-typing a correct password with no idea why it is
-- being refused. That is a real cost paid by real people, every time.
--
--
-- ALSO FIXED HERE: A HARDCODED WORKSPACE
-- --------------------------------------
-- The handler contained APEX_UTIL.SET_WORKSPACE('HRMSDEV'). Prod's workspace is
-- almost certainly not HRMSDEV, and there it would fail as "bad credentials"
-- for everyone, which is a miserable thing to debug during a release. It now
-- reads APEX_WORKSPACE from XXKS_EXP_SECRETS and falls back to the literal, so
-- dev behaviour is identical and prod is a one-row insert instead of a code
-- change.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF
SET LINESIZE 200


--------------------------------------------------------------------------------
-- 0. Guards. Refuse rather than guess.
--------------------------------------------------------------------------------
DECLARE
  l_n    NUMBER;
  l_nvl  NUMBER;
  l_unl  NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_n FROM user_objects
  WHERE  object_name = 'XXKS_EXP_LOGIN_RETRY_AFTER';
  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'XXKS_EXP_LOGIN_RETRY_AFTER not found -- run 80, 80b and the rename first.');
  END IF;

  -- The deployed handler must be the one I was shown. Section 4 replaces it
  -- wholesale, and these two lines are the parts that took longest to get right
  -- and would be silently lost if the deployed copy were a different version.
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
    RAISE_APPLICATION_ERROR(-20002,
      'The deployed auth/login handler is not the version this script was '
      || 'written against (NVL guard: ' || l_nvl || ', UNLOCK_ACCOUNT: ' || l_unl
      || '). Send me its source before running this. Nothing changed.');
  END IF;

  DBMS_OUTPUT.PUT_LINE('guards passed on '
                       || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/


--------------------------------------------------------------------------------
-- 1. Configuration.
--
-- LOGIN_DELAYS is the ladder, in seconds, one rung per consecutive failure.
-- The last rung repeats if there are somehow more failures than rungs.
--
-- APEX_WORKSPACE replaces the hardcoded 'HRMSDEV'. On prod, set it BEFORE
-- running section 4 there.
--------------------------------------------------------------------------------
MERGE INTO xxks_exp_secrets s
USING (SELECT 'LOGIN_DELAYS' AS n, '5,10,60' AS v FROM dual) d
ON    (s.secret_name = d.n)
WHEN NOT MATCHED THEN INSERT (secret_name, secret_value) VALUES (d.n, d.v);

MERGE INTO xxks_exp_secrets s
USING (SELECT 'APEX_WORKSPACE' AS n, 'HRMSDEV' AS v FROM dual) d
ON    (s.secret_name = d.n)
WHEN NOT MATCHED THEN INSERT (secret_name, secret_value) VALUES (d.n, d.v);

-- The attempt at which APEX locks the account. Used ONLY to count down in the
-- failure message; APEX does the locking either way, so a wrong value here
-- makes the warning inaccurate, not the security.
MERGE INTO xxks_exp_secrets s
USING (SELECT 'LOGIN_APEX_LOCK_AT' AS n, '4' AS v FROM dual) d
ON    (s.secret_name = d.n)
WHEN NOT MATCHED THEN INSERT (secret_name, secret_value) VALUES (d.n, d.v);
COMMIT;

-- MERGE, not INSERT: a re-run must not overwrite a value someone has tuned.
SELECT secret_name, secret_value FROM xxks_exp_secrets
WHERE  secret_name IN ('LOGIN_DELAYS','APEX_WORKSPACE','LOGIN_MAX_FAILURES',
                       'LOGIN_WINDOW_MINUTES','LOGIN_BLOCK_MINUTES')
ORDER  BY secret_name;
-- LOGIN_MAX_FAILURES / WINDOW / BLOCK are no longer read by anything. Left in
-- place rather than deleted: removing configuration during a fix makes it
-- harder to reconstruct what the old behaviour was if this needs reverting.


--------------------------------------------------------------------------------
-- 2. The ladder.
--
-- Counts failures SINCE THE LAST SUCCESSFUL LOGIN -- deliberately the same
-- thing APEX counts. The old version counted within a rolling 15-minute
-- window, which is what let the two drift apart.
--------------------------------------------------------------------------------
--
-- p_fails: APEX's own FAILED_ACCESS_ATTEMPTS, when the caller has it. That is
-- the number that decides the lock, so using it for the ladder guarantees the
-- two can never disagree -- and an administrator's UNLOCK_ACCOUNT, which resets
-- APEX's count, releases this throttle in the same instant. Counting our own
-- rows instead leaves a just-unlocked user blocked by us for reasons they
-- cannot see or clear.
--
-- Defaulted to NULL so anything already calling this with one argument keeps
-- working and falls back to counting our own table.
CREATE OR REPLACE FUNCTION xxks_exp_login_retry_after(
  p_email IN VARCHAR2,
  p_fails IN NUMBER DEFAULT NULL
) RETURN NUMBER IS
  l_email  VARCHAR2(300) := UPPER(SUBSTR(TRIM(p_email), 1, 300));
  l_delays VARCHAR2(200);
  l_fails  NUMBER;
  l_last   TIMESTAMP;
  l_rungs  PLS_INTEGER;
  l_rung   PLS_INTEGER;
  l_delay  NUMBER;
  l_secs   NUMBER;
BEGIN
  IF l_email IS NULL THEN RETURN 0; END IF;

  BEGIN
    SELECT secret_value INTO l_delays FROM xxks_exp_secrets
    WHERE  secret_name = 'LOGIN_DELAYS';
  EXCEPTION WHEN OTHERS THEN l_delays := NULL;
  END;
  l_delays := NVL(l_delays, '5,10,60');

  SELECT COUNT(*), MAX(attempted_at)
  INTO   l_fails, l_last
  FROM   xxks_exp_login_attempts
  WHERE  email_upper = l_email
  AND    outcome = 'FAIL'
  AND    attempted_at > NVL((SELECT MAX(attempted_at)
                             FROM   xxks_exp_login_attempts
                             WHERE  email_upper = l_email AND outcome = 'OK'),
                            TIMESTAMP '1970-01-01 00:00:00');

  -- The caller's count wins when it has one; ours is the fallback.
  l_fails := NVL(p_fails, NVL(l_fails, 0));

  IF l_fails = 0 THEN RETURN 0; END IF;

  l_rungs := REGEXP_COUNT(l_delays, ',') + 1;
  l_rung  := LEAST(l_fails, l_rungs);
  l_delay := TO_NUMBER(TRIM(REGEXP_SUBSTR(l_delays, '[^,]+', 1, l_rung))
                       DEFAULT NULL ON CONVERSION ERROR);
  IF l_delay IS NULL THEN RETURN 0; END IF;

  -- Seconds since the last failure. DATE arithmetic drops sub-second precision,
  -- which does not matter for a five-second floor.
  l_secs := l_delay - (CAST(SYSTIMESTAMP AS DATE) - CAST(l_last AS DATE)) * 86400;

  RETURN GREATEST(CEIL(NVL(l_secs, 0)), 0);
EXCEPTION
  WHEN OTHERS THEN
    RETURN 0;   -- fail open: a broken limiter must never lock the company out
END xxks_exp_login_retry_after;
/


--------------------------------------------------------------------------------
-- 3. The login handler.
--
-- Rewritten from the source read back out of USER_ORDS_HANDLERS, not
-- reconstructed from this repo. Everything outside the four changes below is
-- byte-identical, including the NVL guard and its comment.
--
-- Changes:
--   a. workspace comes from a secret
--   b. the workspace is set and the account resolved EARLY, so lock status is
--      known before any password work
--   c. locked -> its own message, checked before validating and again straight
--      after a failure
--   d. waits are worded in seconds or minutes, and a failure says how long
--      until the next attempt
--
-- Also tidied: the rename had produced
--     XXKS_EXP_IS_FINANCE_MANAGER(e.empid) AS XXKS_EXP_IS_FINANCE_MANAGER
-- because a column alias matched the substitution. Harmless -- the alias and
-- its use were renamed together and the JSON key is a protected literal -- but
-- an alias named after a function is a trap for whoever reads this next. It is
-- now AS is_fin_mgr. The JSON key 'is_finance_manager' is unchanged, so the app
-- sees exactly what it saw before.
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
  -- VARCHAR2(10), NOT (1). APEX_WORKSPACE_APEX_USERS.ACCOUNT_LOCKED holds
  -- 'Yes' / 'No', not 'Y' / 'N'. Declared as VARCHAR2(1) this raises ORA-06502
  -- on the SELECT INTO, which the surrounding handler swallows -- so a locked
  -- account read as not-locked and fell through to the throttle, answering
  -- "try again in 59 seconds" to someone who could never get in by waiting.
  -- The view's actual values were visible in a query I had already run.
  l_locked        VARCHAR2(10) := 'No';
  l_apex_fails    NUMBER := 0;
  l_remaining     NUMBER;
  l_lock_at       NUMBER;
  l_access_token  VARCHAR2(4000);
  l_expires_in    NUMBER;
  l_valid         BOOLEAN := FALSE;
  l_retry_after   NUMBER;

  -- "5 seconds" reads better than "1 minute(s)" when the wait is five seconds.
  -- The old message divided by 60 unconditionally, so the first rung of this
  -- ladder would have announced itself as "0 minute(s)".
  FUNCTION wait_text(p_secs IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    IF p_secs < 60 THEN
      RETURN CEIL(p_secs) || ' second' || CASE WHEN CEIL(p_secs) = 1 THEN '' ELSE 's' END;
    END IF;
    RETURN CEIL(p_secs / 60) || ' minute' || CASE WHEN CEIL(p_secs / 60) = 1 THEN '' ELSE 's' END;
  END;

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

  -- APEX's own lock threshold. Read from configuration rather than queried:
  -- APEX_WORKSPACE_PREFERENCES returned nothing for this workspace, so the
  -- value is not reliably readable from here. 4 is what dev demonstrably does.
  -- If a workspace is set to something else, correct the secret rather than
  -- this code -- and note the countdown is only a message, so being wrong makes
  -- the warning inaccurate, not the lock.
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

  -- A locked account fails EVERY password, including the right one. Saying
  -- "invalid email or password" here is the single most misleading answer
  -- available, and it is what this endpoint used to give.
  --
  -- 'Y' OR 'YES' because the view says 'Yes' and hardcoding one spelling is
  -- how this went wrong the first time.
  IF UPPER(l_locked) IN ('Y', 'YES') THEN
    -- Deliberately NOT recorded as a failure.
    --
    -- It is not a credential failure -- the password was never checked. And
    -- recording it would do real harm: the ladder counts failures since the
    -- last success, an administrator's UNLOCK_ACCOUNT does not touch our
    -- table, and someone who kept trying while locked would be released by the
    -- admin and then immediately throttled by us for attempts made while they
    -- could not possibly have succeeded.
    say_locked;
    RETURN;
  END IF;

  -- THROTTLE, checked before any password work so a blocked caller costs the
  -- database one indexed lookup and nothing else.
  --
  -- Applied to ANY email, whether or not it exists. Throttling only real
  -- accounts would turn this into an account-enumeration oracle: guess an
  -- address, see whether it can be locked out, learn who works here.
  --
  -- APEX's counter is passed in, so the ladder position comes from the number
  -- that also decides the lock. That keeps them from diverging, and it means an
  -- administrator's UNLOCK_ACCOUNT -- which resets APEX's count -- releases our
  -- throttle at the same moment. Counting our own rows instead would leave a
  -- freshly unlocked user still blocked by us, with nothing they could do.
  l_retry_after := XXKS_EXP_LOGIN_RETRY_AFTER(l_username, l_apex_fails);
  IF l_retry_after > 0 THEN
    :status_code := 429;
    APEX_JSON.OPEN_OBJECT;
    APEX_JSON.WRITE('error', 'Too many sign-in attempts. Try again in '
      || wait_text(l_retry_after) || '.');
    APEX_JSON.WRITE('retry_after_seconds', l_retry_after);
    APEX_JSON.CLOSE_OBJECT;
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

    -- That failure may have been the one that tipped APEX over its own
    -- threshold. Re-read rather than infer: the person needs to be told at the
    -- moment it happens, not on their next attempt.
    --
    -- FAILED_ACCESS_ATTEMPTS is read at the same time, and it is the number
    -- that actually decides. Our own ladder cannot be trusted to predict the
    -- lock, because APEX's counter is CUMULATIVE and may already be part-way up
    -- before this sign-in attempt began -- which is exactly what happened in
    -- testing: an account carrying one old failure locked on what looked like
    -- the third try, not the fourth.
    --
    -- Nobody can see that counter. So people lock without warning after months
    -- of ordinary mistyping, and the first they know of it is a message telling
    -- them to find an administrator. Counting down out loud is the whole point
    -- of this block.
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

    l_retry_after := XXKS_EXP_LOGIN_RETRY_AFTER(l_username, l_apex_fails);
    l_remaining   := l_lock_at - l_apex_fails;

    :status_code := 401;
    APEX_JSON.OPEN_OBJECT;
    APEX_JSON.WRITE('error', 'Invalid email or password.'
      || CASE WHEN l_retry_after > 0
              THEN ' Try again in ' || wait_text(l_retry_after) || '.'
              ELSE '' END
      -- Only once it is close enough to matter. Announcing "3 attempts
      -- remaining" on a single typo is alarming for no reason, and trains
      -- people to ignore the line by the time it counts.
      || CASE WHEN l_remaining BETWEEN 1 AND 2
              THEN ' ' || l_remaining || ' attempt'
                   || CASE WHEN l_remaining = 1 THEN '' ELSE 's' END
                   || ' remaining before this account is locked.'
              ELSE '' END);
    IF l_retry_after > 0 THEN
      APEX_JSON.WRITE('retry_after_seconds', l_retry_after);
    END IF;
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
  -- this app is permanent, so people drift toward MAX_LOGIN_FAILURES over
  -- months of ordinary typing and eventually lock for no reason -- which is
  -- why JAYESH.GULVE and KAUSHIK.SHANKAR were sitting at 3 with nobody
  -- attacking anything. Once locked, a successful login is impossible, so the
  -- only way back is an administrator.
  --
  -- UNLOCK_ACCOUNT is the only call APEX exposes that resets the count; there
  -- is no reset-attempts-only procedure -- checked against HTMLDB_UTIL rather
  -- than assumed. It cannot unlock anybody here: a locked account cannot
  -- produce a correct-password result in the first place, so this line is
  -- unreachable for one. Verified on dev -- a locked account is refused by
  -- IS_LOGIN_PASSWORD_VALID.
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

  -- DEFINE_HANDLER drops the handler's parameters with it. Both of these must
  -- go back or every login returns 500 with an unbound bind.
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'auth/login', p_method => 'POST',
    p_name => 'Authorization', p_bind_variable_name => 'p_authorization',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'auth/login', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
    p_source_type => 'HEADER', p_access_method => 'OUT');

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('auth/login rewritten: ladder + honest lock message.');
END;
/


--------------------------------------------------------------------------------
-- 4. Verify the shape.
--------------------------------------------------------------------------------
SELECT object_name, status FROM user_objects
WHERE  object_name = 'XXKS_EXP_LOGIN_RETRY_AFTER';

SELECT name, line, text FROM user_errors
WHERE  name = 'XXKS_EXP_LOGIN_RETRY_AFTER' ORDER BY line;

-- Both parameters survived. Expect 2 rows.
SELECT p.name, p.bind_variable_name, p.source_type, p.access_method
FROM   user_ords_parameters p
JOIN   user_ords_handlers   h ON h.id = p.handler_id
JOIN   user_ords_templates  t ON t.id = h.template_id
JOIN   user_ords_modules    m ON m.id = t.module_id
WHERE  m.name LIKE 'expenses%' AND t.uri_template = 'auth/login' AND h.method = 'POST'
ORDER  BY p.name;

-- The ladder, computed for an email with no recent failures. Expect 0.
SELECT xxks_exp_login_retry_after('nobody.here@trinamix.com') AS should_be_zero
FROM   dual;

-- The ladder driven by an explicit count, as the handler now calls it.
-- Expect 0 for 0 failures, and a non-zero wait only if that email has a recent
-- failure recorded.
SELECT xxks_exp_login_retry_after('nobody.here@trinamix.com', 0) AS fails_0,
       xxks_exp_login_retry_after('nobody.here@trinamix.com', 3) AS fails_3
FROM   dual;

-- ** THE VALUES THIS VIEW ACTUALLY USES. **
--
-- Expect 'Yes' and 'No'. Assuming 'Y' and 'N' -- while a query I had already
-- run was printing 'Yes' on screen -- is what made a locked account answer
-- "try again in 59 seconds" instead of saying it was locked. Check, do not
-- assume, and do not let a VARCHAR2(1) turn a wrong guess into a swallowed
-- ORA-06502.
SELECT DISTINCT account_locked FROM apex_workspace_apex_users;


--------------------------------------------------------------------------------
-- 5. Where any account currently stands.
--
-- Run this BEFORE testing. our_fails and apex_fails should now agree; if they
-- do not, the account has failures from before this script and the ladder will
-- start lower than APEX's counter.
--------------------------------------------------------------------------------
SELECT u.user_name,
       u.account_locked,
       u.failed_access_attempts AS apex_fails,
       (SELECT COUNT(*) FROM xxks_exp_login_attempts a
        WHERE  a.email_upper = UPPER(u.user_name) AND a.outcome = 'FAIL'
        AND    a.attempted_at > NVL((SELECT MAX(attempted_at)
                                     FROM   xxks_exp_login_attempts
                                     WHERE  email_upper = UPPER(u.user_name)
                                     AND    outcome = 'OK'),
                                    TIMESTAMP '1970-01-01 00:00:00')) AS our_fails,
       xxks_exp_login_retry_after(u.user_name) AS retry_after_secs
FROM   apex_workspace_apex_users u
WHERE  u.failed_access_attempts > 0 OR u.account_locked = 'Y'
ORDER  BY u.failed_access_attempts DESC;


--------------------------------------------------------------------------------
-- 6. ** TESTING THIS CAN LOCK YOUR ACCOUNT. **
--
-- That is the point -- the fourth wrong password is meant to lock -- but only
-- an administrator can undo it, so decide before you start whether you are
-- willing to be locked out of dev.
--
-- Expected, from a clean state (apex_fails 0, our_fails 0):
--
--   attempt 1  401  "Invalid email or password. Try again in 5 seconds."
--   attempt 2  429  if within 5s -- otherwise 401 "... in 10 seconds"
--   attempt 3  401  "... Try again in 1 minute."
--   attempt 4  403  "This account is locked ... ask your administrator"
--
-- Then, whatever happened:
--
--   SELECT attempted_at, outcome FROM xxks_exp_login_attempts
--   WHERE  email_upper = UPPER('you@trinamix.com')
--   ORDER  BY attempted_at DESC FETCH FIRST 10 ROWS ONLY;
--
-- The unlock, which needs an APEX administrator account:
--
--   BEGIN
--     APEX_UTIL.SET_WORKSPACE(p_workspace => 'HRMSDEV');
--     APEX_UTIL.UNLOCK_ACCOUNT(p_user_name => 'YOU@TRINAMIX.COM');
--   END;
--   /
--
-- UNLOCK_ACCOUNT clears the failure count as well as the lock, so the ladder
-- resets with it. Log in successfully once afterwards to confirm both counters
-- are back to zero.
--
-- A safer test, if you would rather not risk your own account: use an APEX
-- account that is not yours to lose, or set LOGIN_DELAYS to '5,10,60,120' and
-- stop at the third failure -- the ladder is exercised without ever reaching
-- APEX's threshold.
--------------------------------------------------------------------------------
