--------------------------------------------------------------------------------
-- 80b_login_reset_failure_count.sql
--
-- Run as the APPLICATION SCHEMA, in SQL SCRIPTS. Idempotent.
-- Run AFTER 80_login_rate_limit.sql. DEV (HRMS) first.
--
--
-- WHAT THE TEST ON DEV ACTUALLY SHOWED
-- ------------------------------------
-- The rate limiter worked and the account still locked. Both are true, and the
-- log explains why:
--
--   11:47:42  OK              APEX counter -> 0
--   11:47:53  FAIL   (1)      APEX 1
--   11:47:54  FAIL   (2)      APEX 2
--   11:47:56  FAIL   (3)      APEX 3   <- our block starts
--             ... 51 minutes, our 15-minute window expires ...
--   12:38:17  FAIL   (1)      APEX 4   <- LOCKED
--
-- Our limiter allows three per WINDOW. APEX counts CUMULATIVELY and never
-- decays. So the first attempt of the second window was the fourth failure
-- overall. No threshold fixes that: three per fifteen minutes just means a
-- lockout takes two windows instead of one.
--
--
-- BUT THE LOG SHOWS THE REAL BUG, at 11:47:42
-- -------------------------------------------
-- A SUCCESSFUL login -- and APEX's counter carried straight on from there.
--
-- APEX's own login page resets FAILED_ACCESS_ATTEMPTS when you sign in
-- correctly. This endpoint never has, because IS_LOGIN_PASSWORD_VALID only
-- compares a password. So the counter is a one-way ratchet: every typo any
-- employee has ever made through this app is still counted, months later.
--
-- That is why the workspace looks like this with nobody attacking anything:
--
--   BHEEMANI.SWATHI     locked, 4
--   JAYESH.GULVE        3
--   KAUSHIK.SHANKAR     3
--   JAIMINI.MACWAN      2
--   SHREYA.AGARWAL      2
--   SOMASEKHAR.C        2
--
-- Six people, three of them one or two typos from being locked out of every
-- APEX application -- and no way for them to clear it by using the app
-- correctly. At launch, with everyone using it daily, this produces a steady
-- trickle of lockouts that look inexplicable.
--
-- Fixing that is worth more day to day than the rate limiting is.
--
--
-- THE FIX, AND WHY IT IS SAFE
-- ---------------------------
-- On a SUCCESSFUL password check, call APEX_UTIL.UNLOCK_ACCOUNT, which resets
-- the counter to zero.
--
-- Two things were checked rather than assumed, because guessing at APEX APIs
-- has cost this project days:
--
--   1. There is no reset-the-count-only procedure. HTMLDB_UTIL (which APEX_UTIL
--      is a synonym for -- it is NOT WWV_FLOW_UTILITIES) exposes LOCK_ACCOUNT,
--      UNLOCK_ACCOUNT, GET_ACCOUNT_LOCKED_STATUS, RESET_PASSWORD and the expiry
--      calls. UNLOCK_ACCOUNT is the only lever that clears the count.
--
--   2. It cannot unlock anyone. A locked account is refused by
--      IS_LOGIN_PASSWORD_VALID -- confirmed on dev, the app would not let a
--      locked account in with the correct password -- so this line is
--      unreachable while an account is locked. It only ever fires for an
--      account that was already unlocked and just proved its password.
--
-- That is exactly the semantic APEX itself has. It is not a weakening of
-- anything; it is the missing half of an integration.
--
--
-- WHAT THIS STILL DOES NOT DO
-- ---------------------------
-- It does not stop a determined attacker locking an account, because an
-- attacker never supplies a correct password and so never triggers the reset.
-- Combined with the limiter that costs them a fifteen-minute wait per attempt
-- beyond the third, which is a real slowdown and not a fix.
--
-- Closing that properly means changing MAX_LOGIN_FAILURES, which is an APEX
-- INSTANCE parameter affecting every workspace on the server -- a conversation
-- with whoever administers APEX, not something to do from here.
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

  SELECT COUNT(*) INTO l_n FROM user_objects
  WHERE  object_name IN ('EXPENSE_LOGIN_RETRY_AFTER','EXPENSE_LOGIN_RECORD')
  AND    status = 'VALID';
  IF l_n < 2 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'The rate limiter is not installed here. Run 80_login_rate_limit.sql '
      || 'first. Nothing changed.');
  END IF;

  SELECT COUNT(*) INTO l_n
  FROM   user_ords_handlers h
  JOIN   user_ords_templates t ON t.id = h.template_id
  JOIN   user_ords_modules m   ON m.id = t.module_id
  WHERE  m.name = 'expenses.employee'
  AND    t.uri_template = 'auth/login' AND h.method = 'POST'
  AND    INSTR(h.source, 'expense_login_retry_after') > 0;
  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'The login handler does not call the limiter -- 80 has not run here, or '
      || 'something replaced the handler since. Run 80 first. Nothing changed.');
  END IF;

  DBMS_OUTPUT.PUT_LINE('Rate limiter present. Adding the counter reset.');
END;
/


--------------------------------------------------------------------------------
-- 1. The login handler, with the reset on the success path.
--
-- Lifted programmatically from 80, which was lifted from 50. This handler
-- contains the NVL guard that took two sessions to find; it has never been
-- retyped and is not being retyped now.
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
-- 2. Verify the handler took.
--------------------------------------------------------------------------------
SELECT h.method,
       CASE WHEN INSTR(h.source, 'UNLOCK_ACCOUNT') > 0            THEN 'Y' ELSE 'N' END AS resets_counter,
       CASE WHEN INSTR(h.source, 'expense_login_retry_after') > 0 THEN 'Y' ELSE 'N' END AS throttled,
       CASE WHEN INSTR(h.source, 'expense_login_record') > 0      THEN 'Y' ELSE 'N' END AS records,
       CASE WHEN INSTR(UPPER(h.source), 'NVL(L_VALID, FALSE) = FALSE') > 0
            THEN 'Y' ELSE 'N' END AS nvl_guard_intact,
       CASE WHEN INSTR(h.source, '##WORKSPACE##') > 0 THEN 'N -- NOT SUBSTITUTED' ELSE 'Y' END AS workspace_resolved,
       (SELECT COUNT(*) FROM user_ords_parameters pa
        WHERE  pa.handler_id = h.id AND UPPER(pa.name) = 'AUTHORIZATION') AS auth_param
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee' AND t.uri_template = 'auth/login';
-- Expect: POST, Y, Y, Y, Y, Y, 1.
-- nvl_guard_intact = N means STOP -- every password would be accepted.


--------------------------------------------------------------------------------
-- 3. Test it on dev. Three steps, in this order.
--
-- FIRST unlock yourself, since the earlier test locked the account:
--
--   DECLARE l_ws VARCHAR2(200);
--   BEGIN
--     SELECT secret_value INTO l_ws FROM app_secrets WHERE secret_name = 'MAIL_WORKSPACE';
--     APEX_UTIL.SET_WORKSPACE(p_workspace => l_ws);
--     APEX_UTIL.UNLOCK_ACCOUNT(p_user_name => 'DEEPAN.CHANDRASEKAR@TRINAMIX.COM');
--     COMMIT;
--   END;
--   /
--
-- THEN, from the app:
--
--   1. Log in with a WRONG password TWICE.        -> 401 each
--      Check the counter is 2:
--        SELECT user_name, failed_access_attempts, account_locked
--        FROM   apex_workspace_apex_users
--        WHERE  UPPER(user_name) = UPPER('your.email@trinamix.com');
--
--   2. Log in with the CORRECT password.          -> 200
--
--   3. Check the counter again.                   -> 0
--
-- Step 3 going to zero is the whole point of this script. Before it, that
-- counter stayed at 2 forever and the next two typos -- next week, next month --
-- would have locked the account.
--
-- Two failures, not three, so a mistake in this test cannot lock you out.
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- 4. The six people already carrying stale counts.
--
-- READ FIRST. This is other people's accounts, so it is deliberately not
-- automatic.
--------------------------------------------------------------------------------
SELECT user_name, account_locked, failed_access_attempts, date_last_login
FROM   apex_workspace_apex_users
WHERE  account_locked = 'Yes' OR NVL(failed_access_attempts, 0) > 0
ORDER  BY account_locked DESC, failed_access_attempts DESC;
--
-- Everyone here is carrying old typos. From now on their next successful login
-- clears it by itself -- EXCEPT anyone already locked, who cannot log in at all
-- and needs an administrator.
--
-- BHEEMANI.SWATHI is locked and has never logged in (DATE_LAST_LOGIN is null),
-- which is worth a separate look: that may be someone who has never been able
-- to get in rather than someone who forgot a password.
--
-- To clear the unlocked ones now rather than waiting for each person's next
-- sign-in, uncomment this. It resets counts and unlocks the locked -- so decide
-- deliberately whether BHEEMANI.SWATHI should be unlocked without anyone
-- checking why she was locked.
--
--   DECLARE
--     l_ws VARCHAR2(200);
--     l_n  PLS_INTEGER := 0;
--   BEGIN
--     SELECT secret_value INTO l_ws FROM app_secrets WHERE secret_name = 'MAIL_WORKSPACE';
--     APEX_UTIL.SET_WORKSPACE(p_workspace => l_ws);
--     FOR u IN (SELECT user_name FROM apex_workspace_apex_users
--               WHERE NVL(failed_access_attempts, 0) > 0
--               AND   account_locked = 'No')          -- unlocked only
--     LOOP
--       BEGIN
--         APEX_UTIL.UNLOCK_ACCOUNT(p_user_name => u.user_name);
--         l_n := l_n + 1;
--       EXCEPTION WHEN OTHERS THEN
--         DBMS_OUTPUT.PUT_LINE('  skipped ' || u.user_name || ': ' || SQLERRM);
--       END;
--     END LOOP;
--     COMMIT;
--     DBMS_OUTPUT.PUT_LINE('Reset ' || l_n || ' counter(s).');
--   END;
--   /


--------------------------------------------------------------------------------
-- 5. Where login stands after this
--
--   Wrong password              401, counted by us and by APEX
--   3 wrong in 15 minutes       429 from us, APEX never sees the 4th in that window
--   Correct password            200, and APEX's counter goes back to zero
--   Locked account              401 "Invalid email or password."
--
-- That last line is the one still worth improving. A locked person is told
-- their password is wrong, so they will try again, fail again, and raise a
-- ticket -- when the truthful answer is "your account is locked, ask IT".
-- GET_ACCOUNT_LOCKED_STATUS exists and would make that a five-line change.
-- Left out because you scoped it out earlier; say the word and it goes in.
--------------------------------------------------------------------------------
