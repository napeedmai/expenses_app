--------------------------------------------------------------------------------
-- DIAGNOSE_LOGIN_LOCKOUT.sql
--
-- ** RUN ON DEV (HRMS) ONLY. ** Section 3 deliberately submits wrong passwords.
--
-- Settles one question, empirically:
--
--   Does APEX's account lockout already protect POST /expenses/auth/login?
--
-- If it does, 80_login_rate_limit.sql is largely redundant and should not be
-- run. If it does not, the endpoint has no limit of any kind. This is worth
-- five minutes because it decides whether a whole script gets deployed.
--
--
-- WHY I THINK IT DOES NOT, AND WHY I WANT TO BE PROVED WRONG
-- ---------------------------------------------------------
-- APEX increments FAILED_ACCESS_ATTEMPTS inside its own authentication
-- process -- APEX_AUTHENTICATION.LOGIN and APEX_UTIL.SET_AUTHENTICATION_RESULT.
-- That is what runs when somebody signs in to an APEX page.
--
-- Our handler does not use any of that. It calls
--
--     APEX_UTIL.IS_LOGIN_PASSWORD_VALID(p_username => ..., p_password => ...)
--
-- which is a password COMPARISON, not a login. My reading is that it records
-- nothing. But that is a reading, and it is exactly the kind of assumption that
-- has cost this project days -- ORDS.DELETE_TEMPLATE did not exist,
-- DEFAULT ON CONVERSION ERROR was on the wrong argument, APEX_AI was a synonym.
-- So: measure it.
--
--
-- AND THE OUTCOME NOBODY WANTS
-- ----------------------------
-- If IS_LOGIN_PASSWORD_VALID *does* increment the counter, that is not simply
-- good news. It would mean anyone on the internet can lock any employee's APEX
-- account by calling our public endpoint with five wrong passwords -- and those
-- accounts are shared with everything else in the workspace, not just this app.
-- A denial-of-service against the whole HRMS, through our login form.
--
-- In that case the rate limiter becomes MORE valuable, not less: it stops the
-- attempts before they ever reach APEX's counter. Same script, different reason.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF
SET LINESIZE 200


PROMPT ============ 0. SAFETY: this must say HRMS ============

SELECT SYS_CONTEXT('USERENV','CURRENT_SCHEMA') AS schema_name,
       CASE SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
            WHEN 'HRMS' THEN 'dev -- safe to run section 3'
            WHEN 'REPO' THEN '*** PRODUCTION -- DO NOT RUN SECTION 3 ***'
            ELSE 'unrecognised -- stop'
       END AS verdict
FROM   dual;


PROMPT ============ 1. WHAT LOCKOUT IS CONFIGURED ============

-- View names differ by release, so probe rather than guess.
SELECT view_name FROM all_views
WHERE  view_name IN ('APEX_WORKSPACE_APEX_USERS','APEX_INSTANCE_PARAMETERS',
                     'APEX_WORKSPACE_PREFERENCES','APEX_WORKSPACES')
ORDER  BY view_name;

-- Instance-level setting, if readable from here.
DECLARE
  l_n NUMBER;
BEGIN
  BEGIN
    EXECUTE IMMEDIATE q'[
      SELECT COUNT(*) FROM apex_instance_parameters
      WHERE UPPER(name) LIKE '%LOGIN%' OR UPPER(name) LIKE '%LOCK%']' INTO l_n;
    DBMS_OUTPUT.PUT_LINE('apex_instance_parameters readable, ' || l_n
      || ' login/lock parameter(s). Query it directly for the values.');
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('apex_instance_parameters not readable from this schema '
      || '(normal -- usually needs the INTERNAL workspace). ' || SQLERRM);
  END;
END;
/

-- The accounts themselves. This is the column that matters.
SELECT user_name, account_locked, failed_access_attempts, last_login_on
FROM   apex_workspace_apex_users
ORDER  BY NVL(failed_access_attempts, 0) DESC, user_name
FETCH  FIRST 15 ROWS ONLY;
--
-- If failed_access_attempts is 0 or NULL for EVERYONE, that is already a hint:
-- people do mistype passwords, so a counter that is always zero suggests
-- nothing in normal use is incrementing it.


PROMPT ============ 2. PICK A TEST ACCOUNT ============
PROMPT (your own -- section 4 shows how to clear it afterwards)

SELECT user_name, account_locked, failed_access_attempts
FROM   apex_workspace_apex_users
WHERE  UPPER(user_name) = UPPER('DEEPAN.CHANDRASEKAR@TRINAMIX.COM');
-- ^ change this to whichever account you will test with.


PROMPT ============ 3. THE ACTUAL EXPERIMENT ============
PROMPT (DEV ONLY. Two wrong passwords, then read the counter.)

DECLARE
  -- CHANGE THIS to the account from section 2.
  c_user   CONSTANT VARCHAR2(300) := 'DEEPAN.CHANDRASEKAR@TRINAMIX.COM';
  c_tries  CONSTANT PLS_INTEGER   := 2;   -- deliberately well under any limit

  l_schema VARCHAR2(128) := SYS_CONTEXT('USERENV','CURRENT_SCHEMA');
  l_ws     VARCHAR2(200);
  l_before NUMBER;
  l_after  NUMBER;
  l_locked VARCHAR2(10);
  l_valid  BOOLEAN;
BEGIN
  IF l_schema = 'REPO' THEN
    RAISE_APPLICATION_ERROR(-20001,
      'This is PRODUCTION. Deliberately failing logins against a real account '
      || 'here is not worth the answer. Run it on HRMS. Nothing done.');
  END IF;

  SELECT secret_value INTO l_ws FROM app_secrets WHERE secret_name = 'MAIL_WORKSPACE';
  APEX_UTIL.SET_WORKSPACE(p_workspace => l_ws);

  SELECT NVL(failed_access_attempts, 0), account_locked
  INTO   l_before, l_locked
  FROM   apex_workspace_apex_users WHERE UPPER(user_name) = UPPER(c_user);

  DBMS_OUTPUT.PUT_LINE('Account : ' || c_user);
  DBMS_OUTPUT.PUT_LINE('Before  : failed_access_attempts = ' || l_before
    || ', locked = ' || l_locked);

  IF l_locked = 'Yes' THEN
    DBMS_OUTPUT.PUT_LINE('*** Already locked. Unlock it first (section 4) or the '
      || 'result means nothing. Stopping. ***');
    RETURN;
  END IF;

  FOR i IN 1 .. c_tries LOOP
    BEGIN
      l_valid := APEX_UTIL.IS_LOGIN_PASSWORD_VALID(
                   p_username => c_user,
                   p_password => 'definitely-not-the-password-' || i);
      DBMS_OUTPUT.PUT_LINE('  attempt ' || i || ' -> '
        || CASE WHEN l_valid IS NULL THEN 'NULL'
                WHEN l_valid THEN 'TRUE (!!)' ELSE 'FALSE' END);
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('  attempt ' || i || ' raised: ' || SQLERRM);
    END;
  END LOOP;

  SELECT NVL(failed_access_attempts, 0), account_locked
  INTO   l_after, l_locked
  FROM   apex_workspace_apex_users WHERE UPPER(user_name) = UPPER(c_user);

  DBMS_OUTPUT.PUT_LINE('After   : failed_access_attempts = ' || l_after
    || ', locked = ' || l_locked);
  DBMS_OUTPUT.PUT_LINE('');
  DBMS_OUTPUT.PUT_LINE('=====================================================');

  IF l_after > l_before THEN
    DBMS_OUTPUT.PUT_LINE('COUNTER WENT UP by ' || (l_after - l_before) || '.');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('So APEX IS counting attempts made through our endpoint,');
    DBMS_OUTPUT.PUT_LINE('and guessing is already limited. But it also means anyone');
    DBMS_OUTPUT.PUT_LINE('on the internet can LOCK any employee out of every APEX');
    DBMS_OUTPUT.PUT_LINE('application by calling our public login a few times.');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('-> Still run 80. It stops the attempts BEFORE they reach');
    DBMS_OUTPUT.PUT_LINE('   APEX''s counter, so a stranger can no longer lock your');
    DBMS_OUTPUT.PUT_LINE('   colleagues out of the HR system.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('COUNTER DID NOT MOVE (' || l_before || ' -> ' || l_after || ').');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('IS_LOGIN_PASSWORD_VALID records nothing. The lockout you');
    DBMS_OUTPUT.PUT_LINE('are thinking of protects the APEX LOGIN PAGE, not this API.');
    DBMS_OUTPUT.PUT_LINE('POST /expenses/auth/login has no limit at all.');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('-> Run 80 before the endpoint is publicly reachable.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('=====================================================');
END;
/


PROMPT ============ 4. CLEAN UP ============

-- If section 3 pushed the counter up, or locked the account, reset it.
-- APEX_UTIL.UNLOCK_ACCOUNT needs to run with the workspace set; the App Builder
-- UI (Administration -> Manage Users) does the same thing and is easier.
-- A subquery cannot be passed as a PL/SQL argument -- that is PLS-00103, and
-- it was my mistake. SELECT INTO a variable first.
DECLARE
  l_ws VARCHAR2(200);
BEGIN
  SELECT secret_value INTO l_ws FROM app_secrets WHERE secret_name = 'MAIL_WORKSPACE';
  APEX_UTIL.SET_WORKSPACE(p_workspace => l_ws);
  APEX_UTIL.UNLOCK_ACCOUNT(p_user_name => 'DEEPAN.CHANDRASEKAR@TRINAMIX.COM');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Unlocked and counter reset.');
EXCEPTION WHEN OTHERS THEN
  DBMS_OUTPUT.PUT_LINE('Could not unlock from here: ' || SQLERRM);
  DBMS_OUTPUT.PUT_LINE('Use App Builder -> Administration -> Manage Users instead.');
END;
/


--------------------------------------------------------------------------------
-- 5. THE THRESHOLD WE ARE ACTUALLY UP AGAINST
--
-- Evidence says 4: BHEEMANI.SWATHI is locked with failed_access_attempts = 4,
-- and a wrong password through the app locked an account on the 4th try.
-- Confirm it rather than working from a sample of one.
--------------------------------------------------------------------------------
SELECT name, value
FROM   apex_instance_parameters
WHERE  UPPER(name) LIKE '%LOGIN%' OR UPPER(name) LIKE '%LOCK%'
ORDER  BY name;
-- MAX_LOGIN_FAILURES is the one. Note it is an INSTANCE parameter -- it applies
-- to every workspace on this APEX, not only ours, so it is not ours to change.

-- Who is already locked or close to it. Worth running before launch either way:
-- these are people who cannot use the HR system right now.
SELECT user_name, account_locked, failed_access_attempts, date_last_login
FROM   apex_workspace_apex_users
WHERE  account_locked = 'Yes' OR NVL(failed_access_attempts, 0) >= 2
ORDER  BY account_locked DESC, failed_access_attempts DESC;

SELECT user_name, account_locked, failed_access_attempts
FROM   apex_workspace_apex_users
WHERE  UPPER(user_name) = UPPER('DEEPAN.CHANDRASEKAR@TRINAMIX.COM');


--------------------------------------------------------------------------------
-- WHAT TO DO WITH THE ANSWER
--
-- Counter moved
--   Guessing is limited already, so 80 is not urgent for THAT reason -- but it
--   is now urgent for a different one: a public endpoint that can lock company
--   accounts is a denial-of-service anyone can run. 80 stops the attempts
--   before APEX sees them. Consider lowering LOGIN_MAX_FAILURES below whatever
--   APEX's own threshold is, so ours always trips first and APEX never locks
--   anybody because of this app.
--
-- Counter did not move
--   The API is unlimited. 80 as written.
--
--
-- EITHER WAY, ONE THING THIS SETTLES
--
-- Account lockout and rate limiting are not the same control even when both
-- exist. Lockout protects an ACCOUNT and, on a public endpoint, is itself a
-- weapon. Rate limiting protects the ENDPOINT and cannot be turned on your own
-- users. That is why 80 blocks for fifteen minutes rather than locking anything.
--------------------------------------------------------------------------------
