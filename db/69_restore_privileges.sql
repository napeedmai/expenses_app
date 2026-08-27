--------------------------------------------------------------------------------
-- 69_restore_privileges.sql
--
-- Run as the APPLICATION SCHEMA (REPO), in SQL SCRIPTS. Idempotent.
--
--   *** RUN 50_fix_login_null_bypass.sql FIRST. ***
--
-- That one restores the auth/login POST handler, which has gone missing --
-- without it nobody can log in from anything, and this script's verification
-- will tell you it is still absent.
--
--
-- WHAT WENT WRONG
-- ---------------
-- Two regressions found August 2026, while chasing a "Failed to fetch" on web:
--
-- 1. THE auth/login HANDLER DISAPPEARED. The template still existed with no
--    handler on it -- a registered URL that answers but runs nothing. Every
--    symptom followed from that and none of them named it:
--
--      * GET returns ORDS's "no resource handlers" 404          (looks normal:
--        auth/login is POST-only, so a browser GET always 404s)
--      * the CORS preflight OPTIONS also 404s
--      * a 404 carries no Access-Control-Allow-Origin header
--      * so the browser reports "blocked by CORS policy"
--
--    Two hours went into CORS configuration that was correct the whole time.
--    The origin was allow-listed; there was simply nothing there to answer.
--
-- 2. TWO PRIVILEGE PATTERNS WERE LOST: /expenses/currencies and
--    /expenses/exchange-rate. Script 65 rebuilt expenses.authenticated by
--    reading back its existing patterns and adding three -- it reported 16, but
--    only 14 are present now. A URI that no privilege matches is reachable by
--    ANYONE, so both have been unprotected since.
--
--    Neither endpoint leaks employee data -- they return currency codes and
--    exchange rates -- so this is untidy rather than urgent. But the same
--    mechanism could as easily have dropped /expenses/mine.
--
--
-- THE LESSON, worth carrying into any future privilege change
-- ----------------------------------------------------------
-- ORDS has no "add one pattern" call: DEFINE_PRIVILEGE replaces the entire
-- set. Read-modify-write on the live set is therefore fragile -- anything the
-- read misses is silently dropped. This script instead compares against an
-- EXPLICIT expected list, so a missing pattern is added rather than inherited.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF


--------------------------------------------------------------------------------
-- 0. Is the login handler back? If not, stop -- 50 has not been run.
--------------------------------------------------------------------------------
DECLARE
  l_n NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Connected as: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));

  SELECT COUNT(*) INTO l_n
  FROM   user_ords_handlers h
  JOIN   user_ords_templates t ON t.id = h.template_id
  JOIN   user_ords_modules m   ON m.id = t.module_id
  WHERE  m.name = 'expenses.employee'
  AND    t.uri_template = 'auth/login' AND h.method = 'POST';

  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'auth/login POST has no handler. Run 50_fix_login_null_bypass.sql first '
      || '-- login is down until you do. Nothing changed here.');
  END IF;

  DBMS_OUTPUT.PUT_LINE('auth/login handler present. Proceeding.');
END;
/


--------------------------------------------------------------------------------
-- 1. Rebuild expenses.authenticated from an EXPLICIT list.
--
-- Every everyday endpoint. Reviewer-only paths (pending, bulk-*) belong to
-- expenses.review and must NOT appear here: ORDS refuses the same pattern in
-- two privileges with "ORA-20039: Pattern already mapped".
--
-- auth/login is deliberately absent. A pattern covering it makes login
-- impossible by construction -- you would need a Bearer token to obtain a
-- Bearer token. See DEPLOYMENT.md 13.2.
--------------------------------------------------------------------------------
DECLARE
  l_roles    owa.vc_arr;
  l_patterns owa.vc_arr;
  r          PLS_INTEGER := 0;
  p          PLS_INTEGER := 0;
  l_added    VARCHAR2(4000);

  FUNCTION mapped_elsewhere(p_pat IN VARCHAR2) RETURN VARCHAR2 IS
    l_priv VARCHAR2(200);
  BEGIN
    SELECT MAX(pr.name) INTO l_priv
    FROM   user_ords_privilege_mappings pm
    JOIN   user_ords_privileges pr ON pr.id = pm.privilege_id
    WHERE  pm.pattern = p_pat AND pr.name != 'expenses.authenticated';
    RETURN l_priv;
  END;
BEGIN
  -- Roles read, not hardcoded: they differ between environments and a wrong
  -- name locks out every protected endpoint.
  FOR x IN (SELECT DISTINCT pr.role_name
            FROM   user_ords_privilege_roles pr
            JOIN   user_ords_privileges p ON p.id = pr.privilege_id
            WHERE  p.name = 'expenses.authenticated'
            ORDER  BY pr.role_name)
  LOOP
    r := r + 1; l_roles(r) := x.role_name;
  END LOOP;

  IF r = 0 THEN
    RAISE_APPLICATION_ERROR(-20002,
      'expenses.authenticated has no roles. Refusing to rebuild it and lock '
      || 'everyone out. Check PROD_2_ords_and_security_setup.sql.');
  END IF;

  FOR np IN (SELECT column_value AS pat FROM TABLE(sys.odcivarchar2list(
               '/expenses/whoami',
               '/expenses/my-projects',
               '/expenses/currencies',                      -- was missing
               '/expenses/exchange-rate',                   -- was missing
               '/expenses/draft',
               '/expenses/mine',
               '/expenses/:id',
               '/expenses/:id/submit',
               '/expenses/:id/attachment',
               '/expenses/:id/accept',
               '/expenses/:id/revise',
               '/expenses/:id/reject',
               '/expenses/push-token',
               '/expenses/:id/items',
               '/expenses/:id/items/:item_id',
               '/expenses/:id/items/:item_id/attachment')))
  LOOP
    IF mapped_elsewhere(np.pat) IS NOT NULL THEN
      DBMS_OUTPUT.PUT_LINE('  SKIP ' || np.pat || ' -- already in '
        || mapped_elsewhere(np.pat));
    ELSE
      p := p + 1; l_patterns(p) := np.pat;
    END IF;
  END LOOP;

  -- What is being added that was not there before?
  FOR np IN (SELECT column_value AS pat FROM TABLE(sys.odcivarchar2list(
               '/expenses/currencies', '/expenses/exchange-rate')))
  LOOP
    DECLARE l_n NUMBER;
    BEGIN
      SELECT COUNT(*) INTO l_n FROM user_ords_privilege_mappings
      WHERE  pattern = np.pat;
      IF l_n = 0 THEN l_added := l_added || np.pat || ' '; END IF;
    END;
  END LOOP;

  ORDS.DELETE_PRIVILEGE(p_name => 'expenses.authenticated');
  ORDS.DEFINE_PRIVILEGE(
    p_privilege_name => 'expenses.authenticated',
    p_roles          => l_roles,
    p_patterns       => l_patterns,
    p_label          => 'Expense App - Authenticated Access',
    p_description    => 'Any signed-in employee or reviewer may call these. '
      || 'Row-level ownership and stage checks happen in the handlers. '
      || 'auth/login is deliberately excluded -- a pattern covering it makes '
      || 'login impossible.');
  COMMIT;

  DBMS_OUTPUT.PUT_LINE('Rebuilt with ' || p || ' pattern(s), ' || r || ' role(s).');
  IF l_added IS NOT NULL THEN
    DBMS_OUTPUT.PUT_LINE('Newly protected (were public): ' || l_added);
  ELSE
    DBMS_OUTPUT.PUT_LINE('Nothing was newly protected -- all were already mapped.');
  END IF;
END;
/


--------------------------------------------------------------------------------
-- 2. Verify. This is the check that should have been run after script 65.
--------------------------------------------------------------------------------

-- a) auth/login must have exactly one POST handler, with the safe guard and
--    its Authorization parameter.
SELECT h.method,
       CASE WHEN INSTR(UPPER(h.source), 'NVL(L_VALID, FALSE) = FALSE') > 0
            THEN 'Y' ELSE 'N' END AS has_nvl_guard,
       (SELECT COUNT(*) FROM user_ords_parameters pa
        WHERE  pa.handler_id = h.id AND UPPER(pa.name) = 'AUTHORIZATION') AS auth_param
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee' AND t.uri_template = 'auth/login';
-- Expect one row: POST, Y, 1.

-- b) auth/login must be covered by NO privilege. Must return no rows.
SELECT pm.pattern, pr.name
FROM   user_ords_privilege_mappings pm
JOIN   user_ords_privileges pr ON pr.id = pm.privilege_id
WHERE  pm.pattern LIKE '/expenses/auth%';

-- c) EVERY endpoint the app calls must be protected. Must return no rows --
--    anything listed is publicly reachable.
SELECT x.pat AS unprotected_pattern
FROM   (SELECT column_value AS pat FROM TABLE(sys.odcivarchar2list(
          '/expenses/whoami','/expenses/my-projects','/expenses/currencies',
          '/expenses/exchange-rate','/expenses/draft','/expenses/mine',
          '/expenses/:id','/expenses/:id/submit','/expenses/:id/attachment',
          '/expenses/:id/accept','/expenses/:id/revise','/expenses/:id/reject',
          '/expenses/push-token','/expenses/:id/items',
          '/expenses/:id/items/:item_id','/expenses/:id/items/:item_id/attachment',
          '/expenses/pending','/expenses/bulk-accept','/expenses/bulk-revise',
          '/expenses/bulk-reject'))) x
WHERE  NOT EXISTS (SELECT 1 FROM user_ords_privilege_mappings pm
                   WHERE pm.pattern = x.pat);

-- d) No template without a handler -- the fault that started all this. Must
--    return no rows.
SELECT t.uri_template, COUNT(h.id) AS handlers
FROM   user_ords_templates t
JOIN   user_ords_modules m ON m.id = t.module_id
LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
WHERE  m.name = 'expenses.employee'
GROUP  BY t.uri_template
HAVING COUNT(h.id) = 0;

-- e) No wildcards. Must return no rows.
SELECT pm.pattern FROM user_ords_privilege_mappings pm
WHERE  pm.pattern LIKE '/expenses/%*%' OR pm.pattern = '/expenses/*';

-- f) The full picture, for the record.
SELECT pr.name AS privilege, pm.pattern
FROM   user_ords_privilege_mappings pm
JOIN   user_ords_privileges pr ON pr.id = pm.privilege_id
WHERE  pm.pattern LIKE '/expenses/%'
ORDER  BY pr.name, pm.pattern;


--------------------------------------------------------------------------------
-- 3. Then test login BEFORE going back to the browser.
--
-- Postman, auth type "No Auth", header built by hand:
--
--   POST https://<host>/ords/<base>/expenses/auth/login
--   Authorization: Basic <base64 of email:password>
--
--   -> 200 with empid, session_token, access_token
--
-- And the wrong password, twice (security test S2):
--   -> 401 "Invalid email or password."
--
-- Only then retry the browser. Web adds CORS on top; proving the endpoint
-- works first means a browser failure is definitely CORS and not this again.
--------------------------------------------------------------------------------
