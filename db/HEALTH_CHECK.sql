--==============================================================================
-- HEALTH_CHECK.sql   --   Expense App, read-only environment check
--
-- Run as the APPLICATION SCHEMA, on EVERY environment (dev and prod), with
-- SERVEROUTPUT ON. Takes a few seconds.
--
-- READ-ONLY. Nothing here creates, alters, drops or updates anything. Safe on
-- production during business hours.
--
-- Every check prints PASS, FAIL or WARN, plus what to do about a FAIL. A
-- summary line at the end counts them.
--
-- WHY THIS EXISTS
-- ---------------
-- Every failure it looks for reaches the app as an HTTP status that names the
-- wrong cause -- a missing PL/SQL object arrives as 403 "Access to the
-- resource is prohibited", a wrong column arrives as 555. Checking here is
-- minutes; diagnosing it from the HTTP side is hours. See DEPLOYMENT.md
-- section 12.
--==============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET FEEDBACK OFF

DECLARE
  g_pass NUMBER := 0;
  g_fail NUMBER := 0;
  g_warn NUMBER := 0;

  PROCEDURE hdr(p_text IN VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE('-- ' || p_text || ' ' || RPAD('-', 74 - LENGTH(p_text), '-'));
  END;

  PROCEDURE result(p_status IN VARCHAR2, p_label IN VARCHAR2, p_detail IN VARCHAR2 DEFAULT NULL) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(RPAD(p_status, 6) || p_label || CASE WHEN p_detail IS NOT NULL THEN '  [' || p_detail || ']' END);
    IF    p_status = 'PASS' THEN g_pass := g_pass + 1;
    ELSIF p_status = 'FAIL' THEN g_fail := g_fail + 1;
    ELSE                         g_warn := g_warn + 1;
    END IF;
  END;

  PROCEDURE fix(p_text IN VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE('      -> ' || p_text);
  END;

BEGIN
  DBMS_OUTPUT.PUT_LINE('==============================================================================');
  DBMS_OUTPUT.PUT_LINE('Expense App health check');
  DBMS_OUTPUT.PUT_LINE('Schema  : ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
  DBMS_OUTPUT.PUT_LINE('Database: ' || SYS_CONTEXT('USERENV','DB_NAME'));
  DBMS_OUTPUT.PUT_LINE('Run at  : ' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'));
  DBMS_OUTPUT.PUT_LINE('==============================================================================');

  ------------------------------------------------------------------------------
  hdr('1. Tables');
  ------------------------------------------------------------------------------
  DECLARE
    l_n NUMBER;
  BEGIN
    FOR t IN (SELECT column_value AS name FROM TABLE(sys.odcivarchar2list(
                'EXPENSES','EXPENSE_APPROVALS','EMP_PUSH_TOKENS','APP_SECRETS')))
    LOOP
      SELECT COUNT(*) INTO l_n FROM user_tables WHERE table_name = t.name;
      IF l_n = 1 THEN
        result('PASS', 'Table ' || t.name || ' exists');
      ELSE
        result('FAIL', 'Table ' || t.name || ' MISSING');
        fix('Run MASTER_DEPLOY.sql part 1.');
      END IF;
    END LOOP;
  END;

  -- Currency columns (added by part 5).
  DECLARE
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n FROM user_tab_columns
    WHERE  table_name = 'EXPENSES' AND column_name IN ('CURRENCY','EXCHANGE_RATE','AMOUNT_USD');
    IF l_n = 3 THEN
      result('PASS', 'EXPENSES has CURRENCY / EXCHANGE_RATE / AMOUNT_USD');
    ELSE
      result('FAIL', 'EXPENSES is missing currency columns', l_n || ' of 3 present');
      fix('Run MASTER_DEPLOY.sql part 5 (45_currency_conversion.sql).');
    END IF;
  END;

  -- CLIENT_REQUEST_ID drives idempotent draft creation; its absence shows up
  -- as a 555 on save, not as anything mentioning a column.
  DECLARE
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n FROM user_tab_columns
    WHERE  table_name = 'EXPENSES' AND column_name = 'CLIENT_REQUEST_ID';
    IF l_n = 1 THEN
      result('PASS', 'EXPENSES.CLIENT_REQUEST_ID present');
    ELSE
      result('FAIL', 'EXPENSES.CLIENT_REQUEST_ID missing', 'draft POST will return 555');
      fix('ALTER TABLE expenses ADD (client_request_id VARCHAR2(64));');
    END IF;
  END;

  ------------------------------------------------------------------------------
  hdr('2. Approvals comment column (the COMMENT / COMMENTS trap)');
  ------------------------------------------------------------------------------
  -- process_expense_action inserts into COMMENTS. If the column is still named
  -- COMMENT the procedure stays INVALID for good, and every accept/revise/
  -- reject fails with a bare 403 or 555 that reads as a permissions problem.
  DECLARE
    l_old NUMBER;
    l_new NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_old FROM user_tab_columns
    WHERE  table_name = 'EXPENSE_APPROVALS' AND column_name = 'COMMENT';
    SELECT COUNT(*) INTO l_new FROM user_tab_columns
    WHERE  table_name = 'EXPENSE_APPROVALS' AND column_name = 'COMMENTS';

    IF l_new = 1 AND l_old = 0 THEN
      result('PASS', 'EXPENSE_APPROVALS.COMMENTS correct');
    ELSIF l_old = 1 AND l_new = 0 THEN
      result('FAIL', 'EXPENSE_APPROVALS.COMMENT should be COMMENTS');
      fix('Re-run PROD_1_schema.sql (section 2.1 renames it and recompiles), or:');
      fix('ALTER TABLE expense_approvals RENAME COLUMN "COMMENT" TO comments;');
    ELSIF l_old = 1 AND l_new = 1 THEN
      result('WARN', 'EXPENSE_APPROVALS has BOTH COMMENT and COMMENTS');
      fix('Check which one holds real data before dropping either.');
    ELSE
      result('FAIL', 'EXPENSE_APPROVALS has neither COMMENT nor COMMENTS');
    END IF;
  END;

  ------------------------------------------------------------------------------
  hdr('3. PL/SQL objects');
  ------------------------------------------------------------------------------
  -- Only this app's objects. A shared schema may hold many INVALID objects
  -- belonging to other systems; those are not ours to recompile.
  DECLARE
    l_status VARCHAR2(30);
    l_bad    NUMBER := 0;
  BEGIN
    FOR o IN (SELECT column_value AS name FROM TABLE(sys.odcivarchar2list(
                'IS_FINANCE_MANAGER','GET_PROJECT_MANAGER_EMPID','IS_ALLOWED_ATTACHMENT',
                'GET_REVIEWER_ROLE','HMAC_SHA256_HEX','GENERATE_SESSION_TOKEN',
                'IS_VALID_SESSION_TOKEN','GET_OAUTH_ACCESS_TOKEN','JSON_ESCAPE_STR',
                'SEND_PUSH_NOTIFICATION','PROCESS_EXPENSE_ACTION',
                'GET_EXCHANGE_RATE','CONVERT_TO_USD','GET_RATE_EFFECTIVE_DATE')))
    LOOP
      BEGIN
        SELECT status INTO l_status FROM user_objects
        WHERE  object_name = o.name AND object_type IN ('FUNCTION','PROCEDURE');
        IF l_status = 'VALID' THEN
          result('PASS', o.name);
        ELSE
          result('FAIL', o.name || ' is ' || l_status);
          l_bad := l_bad + 1;
        END IF;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          result('FAIL', o.name || ' MISSING');
          l_bad := l_bad + 1;
        WHEN TOO_MANY_ROWS THEN
          result('WARN', o.name || ' defined more than once');
      END;
    END LOOP;

    IF l_bad > 0 THEN
      fix('An ORDS handler calling an INVALID or missing object returns a bare');
      fix('403/555 with no body. Recompile the named object, then read USER_ERRORS:');
      fix('  ALTER FUNCTION <name> COMPILE;   /   ALTER PROCEDURE <name> COMPILE;');
      fix('  SELECT line, position, text FROM user_errors WHERE name = ''<NAME>'';');
      fix('Do NOT run DBMS_UTILITY.COMPILE_SCHEMA on a shared schema.');
    END IF;
  END;

  ------------------------------------------------------------------------------
  hdr('4. Secrets');
  ------------------------------------------------------------------------------
  DECLARE
    l_n NUMBER;
  BEGIN
    FOR s IN (SELECT column_value AS name FROM TABLE(sys.odcivarchar2list(
                'SESSION_TOKEN_KEY','OAUTH_CLIENT_ID','OAUTH_CLIENT_SECRET','OAUTH_TOKEN_URL')))
    LOOP
      SELECT COUNT(*) INTO l_n FROM app_secrets
      WHERE  secret_name = s.name AND secret_value IS NOT NULL;
      IF l_n = 1 THEN
        result('PASS', 'APP_SECRETS.' || s.name || ' present');
      ELSE
        result('FAIL', 'APP_SECRETS.' || s.name || ' missing or null');
        fix('Login will fail. Seed it -- PROD_2b_oauth_and_network_acl.sql sections 1-2.');
      END IF;
    END LOOP;
  EXCEPTION
    WHEN OTHERS THEN
      result('FAIL', 'Could not read APP_SECRETS', SQLERRM);
  END;

  -- The token URL must point at THIS environment's ORDS base path. Pointing at
  -- another environment's fails as "invalid_client", which reads like a wrong
  -- secret rather than a wrong URL.
  DECLARE
    l_url VARCHAR2(200);
  BEGIN
    SELECT secret_value INTO l_url FROM app_secrets WHERE secret_name = 'OAUTH_TOKEN_URL';
    IF l_url LIKE '%/oauth/token' THEN
      result('PASS', 'OAUTH_TOKEN_URL ends in /oauth/token', l_url);
    ELSE
      result('FAIL', 'OAUTH_TOKEN_URL looks wrong', l_url);
    END IF;
    fix('Confirm this host and base path are THIS environment, not another one.');
  EXCEPTION
    WHEN NO_DATA_FOUND THEN NULL;
  END;

  ------------------------------------------------------------------------------
  hdr('5. ORDS templates and handlers');
  ------------------------------------------------------------------------------
  -- A template with no handler is a registered URL that answers but runs no
  -- code. It does not look like a missing endpoint, which is what makes it
  -- expensive: whoami and :id/accept were both in this state on dev.
  DECLARE
    l_dead NUMBER := 0;
    l_tot  NUMBER := 0;
  BEGIN
    FOR r IN (SELECT t.uri_template, COUNT(h.id) AS handlers
              FROM   user_ords_templates t
              JOIN   user_ords_modules m ON m.id = t.module_id
              LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
              WHERE  m.name = 'expenses.employee'
              GROUP  BY t.uri_template
              ORDER  BY COUNT(h.id), t.uri_template)
    LOOP
      l_tot := l_tot + 1;
      IF r.handlers = 0 THEN
        result('FAIL', 'Template ' || r.uri_template || ' has NO handler');
        l_dead := l_dead + 1;
      END IF;
    END LOOP;

    IF l_tot = 0 THEN
      result('FAIL', 'Module expenses.employee not found');
      fix('Run MASTER_DEPLOY.sql part 2.');
    ELSIF l_dead = 0 THEN
      result('PASS', 'All templates have at least one handler', l_tot || ' templates');
    ELSE
      fix('Run 51_restore_missing_handlers.sql, then re-run this check.');
    END IF;
  END;

  -- The 21 endpoints the app actually calls.
  DECLARE
    l_n NUMBER;
    l_missing NUMBER := 0;
  BEGIN
    FOR e IN (SELECT * FROM TABLE(sys.odcivarchar2list(
                'auth/login|POST','whoami|GET','my-projects|GET','currencies|GET',
                'exchange-rate|GET','mine|GET','draft|POST',':id|GET',':id|PUT',
                ':id|DELETE',':id/submit|POST',':id/attachment|POST',':id/attachment|GET',
                'push-token|POST','pending|GET',':id/accept|POST',':id/revise|POST',
                ':id/reject|POST','bulk-accept|POST','bulk-revise|POST','bulk-reject|POST')))
    LOOP
      SELECT COUNT(*) INTO l_n
      FROM   user_ords_handlers h
      JOIN   user_ords_templates t ON t.id = h.template_id
      JOIN   user_ords_modules m   ON m.id = t.module_id
      WHERE  m.name = 'expenses.employee'
      AND    t.uri_template = SUBSTR(e.column_value, 1, INSTR(e.column_value,'|') - 1)
      AND    h.method       = SUBSTR(e.column_value, INSTR(e.column_value,'|') + 1);

      IF l_n = 0 THEN
        result('FAIL', 'No handler for ' || REPLACE(e.column_value, '|', ' '));
        l_missing := l_missing + 1;
      END IF;
    END LOOP;

    IF l_missing = 0 THEN
      result('PASS', 'All 21 expected handlers present');
    END IF;
  END;

  ------------------------------------------------------------------------------
  hdr('6. Login handler');
  ------------------------------------------------------------------------------
  DECLARE
    l_src        CLOB;
    l_auth_param NUMBER;
    l_ws         VARCHAR2(200);
  BEGIN
    SELECT h.source,
           (SELECT COUNT(*) FROM user_ords_parameters pa
            WHERE  pa.handler_id = h.id AND UPPER(pa.name) = 'AUTHORIZATION')
    INTO   l_src, l_auth_param
    FROM   user_ords_handlers h
    JOIN   user_ords_templates t ON t.id = h.template_id
    JOIN   user_ords_modules m   ON m.id = t.module_id
    WHERE  m.name = 'expenses.employee'
    AND    t.uri_template = 'auth/login'
    AND    h.method = 'POST';

    -- Without this parameter the bind is NULL and EVERY login returns 401,
    -- including correct ones.
    IF l_auth_param = 1 THEN
      result('PASS', 'Authorization header parameter defined');
    ELSE
      result('FAIL', 'Authorization header parameter MISSING', 'every login returns 401');
      fix('ORDS.DEFINE_PARAMETER(... p_name => ''Authorization'', p_source_type => ''HEADER'' ...)');
    END IF;

    -- THE authentication bypass check. IS_LOGIN_PASSWORD_VALID returns NULL
    -- for a wrong password; "IF NOT l_valid" does not fire on NULL, so the
    -- rejection is skipped and a session is issued anyway.
    IF INSTR(UPPER(l_src), 'NVL(L_VALID, FALSE) = FALSE') > 0 THEN
      result('PASS', 'Login guard uses NVL(l_valid, FALSE) = FALSE');
    ELSE
      result('FAIL', 'LOGIN GUARD MISSING -- possible authentication bypass');
      fix('Any valid username may be accepted with ANY password.');
      fix('Run 50_fix_login_null_bypass.sql NOW, then test S2 twice.');
    END IF;

    IF INSTR(UPPER(l_src), 'IF NOT L_VALID THEN') > 0 THEN
      result('FAIL', 'Login handler still contains the unsafe IF NOT l_valid form');
    END IF;

    l_ws := REGEXP_SUBSTR(l_src, 'SET_WORKSPACE\(''([^'']+)''', 1, 1, NULL, 1);
    IF l_ws IS NOT NULL THEN
      result('WARN', 'Workspace hardcoded in handler', l_ws);
      fix('Confirm this is THIS environment''s APEX workspace. A wrong one fails');
      fix('as "Invalid email or password", indistinguishable from a bad password.');
    ELSE
      result('PASS', 'Workspace resolved at deploy time, not hardcoded');
    END IF;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      result('FAIL', 'No POST handler on auth/login');
  END;

  ------------------------------------------------------------------------------
  hdr('7. ORDS privileges');
  ------------------------------------------------------------------------------
  -- A wildcard also matches /expenses/auth/login and makes login impossible by
  -- construction: you would need a Bearer token to obtain a Bearer token.
  DECLARE
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n FROM user_ords_privilege_mappings
    WHERE  pattern LIKE '/expenses/%*%' OR pattern = '/expenses/*';
    IF l_n = 0 THEN
      result('PASS', 'No wildcard privilege patterns');
    ELSE
      result('FAIL', 'Wildcard privilege pattern found', l_n || ' pattern(s)');
      fix('Login will fail with a 401 sign-in page. List endpoints explicitly.');
    END IF;
  END;

  -- auth/login must be covered by NO privilege at all.
  DECLARE
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n FROM user_ords_privilege_mappings
    WHERE  pattern IN ('/expenses/auth/login', '/expenses/auth/*');
    IF l_n = 0 THEN
      result('PASS', 'auth/login is not covered by a privilege');
    ELSE
      result('FAIL', 'auth/login IS covered by a privilege', 'login impossible');
    END IF;
  END;

  -- Every protected endpoint must be covered by one. A path no privilege
  -- matches is publicly accessible.
  DECLARE
    l_n       NUMBER;
    l_missing NUMBER := 0;
  BEGIN
    FOR p IN (SELECT column_value AS pat FROM TABLE(sys.odcivarchar2list(
                '/expenses/whoami','/expenses/my-projects','/expenses/currencies',
                '/expenses/exchange-rate','/expenses/draft','/expenses/mine',
                '/expenses/:id','/expenses/:id/submit','/expenses/:id/attachment',
                '/expenses/:id/accept','/expenses/:id/revise','/expenses/:id/reject',
                '/expenses/push-token','/expenses/pending','/expenses/bulk-accept',
                '/expenses/bulk-revise','/expenses/bulk-reject')))
    LOOP
      SELECT COUNT(*) INTO l_n FROM user_ords_privilege_mappings WHERE pattern = p.pat;
      IF l_n = 0 THEN
        result('FAIL', 'UNPROTECTED: ' || p.pat);
        l_missing := l_missing + 1;
      END IF;
    END LOOP;

    IF l_missing = 0 THEN
      result('PASS', 'All 17 protected patterns are mapped to a privilege');
    ELSE
      fix('These URLs are reachable without a token. Add them to a privilege.');
    END IF;
  END;

  ------------------------------------------------------------------------------
  hdr('8. Currency conversion direction');
  ------------------------------------------------------------------------------
  -- EXCHANGE_RATE is the USD value of ONE unit. Inverting it turns a 1,000 INR
  -- taxi fare into an $88,000 expense, and nothing else in the system would
  -- flag that -- the arithmetic is valid, only the direction is wrong.
  DECLARE
    l_usd NUMBER;
  BEGIN
    l_usd := convert_to_usd(1000, 'INR', SYSDATE);
    IF l_usd IS NULL THEN
      result('WARN', 'No INR rate available to test with');
    ELSIF l_usd BETWEEN 1 AND 100 THEN
      result('PASS', '1000 INR converts sensibly', 'USD ' || ROUND(l_usd, 2));
    ELSE
      result('FAIL', '1000 INR converts to USD ' || ROUND(l_usd, 2), 'direction likely inverted');
      fix('Use EXCHANGE_RATE (USD per unit), not INVERSE_RATE. amount * EXCHANGE_RATE.');
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      result('WARN', 'Could not test INR conversion', SQLERRM);
  END;

  -- USD must be exactly 1, from code rather than from a data row.
  DECLARE
    l_rate NUMBER;
  BEGIN
    l_rate := get_exchange_rate('USD', SYSDATE);
    IF l_rate = 1 THEN
      result('PASS', 'USD rate is exactly 1');
    ELSE
      result('FAIL', 'USD rate is ' || l_rate || ', expected 1');
      fix('Run 49_usd_identity.sql.');
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      result('FAIL', 'get_exchange_rate(''USD'') failed', SQLERRM);
  END;

  ------------------------------------------------------------------------------
  hdr('9. Configuration to confirm by eye');
  ------------------------------------------------------------------------------
  -- Not a pass/fail: correct values differ per environment. Read them.
  DECLARE
    l_line VARCHAR2(4000);
    l_emp  VARCHAR2(100);
  BEGIN
    SELECT MAX(TRIM(text)) INTO l_line FROM user_source
    WHERE  name = 'IS_FINANCE_MANAGER' AND UPPER(text) LIKE '%RETURN CASE%';
    l_emp := REGEXP_SUBSTR(l_line, '=\s*(\d+)', 1, 1, NULL, 1);
    IF l_emp IS NOT NULL THEN
      result('WARN', 'is_finance_manager is hardcoded to EMPID ' || l_emp);
      fix('Confirm that employee is the finance approver in THIS environment.');
    ELSE
      result('PASS', 'is_finance_manager is not a simple hardcoded EMPID');
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      result('WARN', 'Could not read is_finance_manager source');
  END;

  DECLARE
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n FROM expenses WHERE currency IS NULL;
    IF l_n = 0 THEN
      result('PASS', 'Every expense has a currency');
    ELSE
      result('WARN', l_n || ' expense(s) have no currency', 'backfill not run?');
    END IF;
  EXCEPTION
    WHEN OTHERS THEN NULL;
  END;

  ------------------------------------------------------------------------------
  DBMS_OUTPUT.PUT_LINE(' ');
  DBMS_OUTPUT.PUT_LINE('==============================================================================');
  DBMS_OUTPUT.PUT_LINE('PASS ' || g_pass || '   FAIL ' || g_fail || '   WARN ' || g_warn);
  IF g_fail = 0 THEN
    DBMS_OUTPUT.PUT_LINE('No structural faults. Now run the HTTP tests -- this script cannot');
    DBMS_OUTPUT.PUT_LINE('check them. DEPLOYMENT.md section 11.2, especially S2 and S6.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Fix the FAIL lines above and re-run. Each one reaches the app as an');
    DBMS_OUTPUT.PUT_LINE('HTTP status that names the wrong cause -- DEPLOYMENT.md section 12.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('==============================================================================');
END;
/

SET FEEDBACK ON

--==============================================================================
-- WHAT THIS SCRIPT CANNOT CHECK
--
--   * The network ACL. Needs DBA_HOST_ACES, which the app schema cannot read.
--     If login fails with ORA-24247, that is this. DEPLOYMENT.md section 9.2b.
--   * Whether ORDS_PUBLIC_USER is locked. Needs DBA_USERS. If EVERY endpoint
--     returns 5xx, ask a DBA to check. DEPLOYMENT.md section 9.3.
--   * That a wrong password is actually rejected. Structure is not behaviour:
--     run security test S2 by hand, twice, with a manually built Basic header
--     and the auth type set to "No Auth". Postman's Basic Auth tab retains the
--     last good password and will hide the failure -- that is exactly how the
--     bypass survived several rounds of testing.
--   * That one employee cannot read another's expenses (test S6).
--==============================================================================
