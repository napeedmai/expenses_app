--------------------------------------------------------------------------------
-- 47_align_role_names.sql
--
-- Run as HRMS (dev) only. Prod already uses PROJECT_MANAGER_ROLE.
--
-- WHY
-- ---
-- Dev's ORDS privileges use REPORTING_MANAGER_ROLE where prod uses
-- PROJECT_MANAGER_ROLE. That divergence is a trap: every script touching
-- privileges has to read the existing roles rather than state them, and
-- copying a working script between environments silently locks out every
-- protected endpoint. This aligns dev to prod's name.
--
-- Note the underlying concept moved some time ago - the first approval stage
-- routes via the PROJECT_MANAGER table, not a reporting-manager hierarchy
-- (see the comment on EXPENSE_APPROVALS in PROD_1_schema.sql). So
-- PROJECT_MANAGER_ROLE is also the more accurate of the two names.
--
-- ORDER MATTERS
-- -------------
-- The OAuth client is granted the NEW role before the privileges start
-- requiring it. Doing it the other way round leaves a window - potentially
-- permanent, if a later step fails - where the client holds no role that
-- satisfies the privilege and every protected endpoint returns 403.
--
-- NOT CHANGED: the is_reporting_manager field in the login and whoami JSON.
-- The app reads that name, so renaming it here would break the installed
-- builds for no functional gain. It is a display flag, not a role.
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- 1. Where we are now.
--------------------------------------------------------------------------------
SELECT privilege_name, role_name
FROM   user_ords_privilege_roles
ORDER  BY privilege_name, role_name;

SELECT id, name, client_id FROM user_ords_clients;


--------------------------------------------------------------------------------
-- 2a. Create the role.
--
--     ORDS.DEFINE_PRIVILEGE does NOT create roles implicitly - it looks them
--     up and raises ORA-01403 (no data found) from deep inside
--     ORDS_SERVICES_INTERNAL if one is missing. That error names no role and
--     points at ORDS internals, so it reads like an ORDS bug rather than a
--     missing prerequisite.
--
--     This matters more than it looks: DEFINE_PRIVILEGE runs AFTER
--     DELETE_PRIVILEGE in section 3. Had the delete committed before the
--     define failed, the privilege would have been destroyed and its
--     endpoints left unprotected. It did not - both survived - but the role
--     must exist before section 3 runs.
--------------------------------------------------------------------------------
BEGIN
  ORDS.CREATE_ROLE(p_role_name => 'PROJECT_MANAGER_ROLE');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Created PROJECT_MANAGER_ROLE.');
EXCEPTION
  WHEN OTHERS THEN
    -- Already exists on a rerun; harmless.
    DBMS_OUTPUT.PUT_LINE('CREATE_ROLE skipped: ' || SQLERRM);
END;
/

-- Must list PROJECT_MANAGER_ROLE before continuing.
SELECT name FROM user_ords_roles ORDER BY name;


--------------------------------------------------------------------------------
-- 2b. Grant PROJECT_MANAGER_ROLE to every existing OAuth client, BEFORE the
--     privileges start requiring it. Clients keep REPORTING_MANAGER_ROLE too
--     at this point, so access is uninterrupted throughout.
--------------------------------------------------------------------------------
DECLARE
  l_granted NUMBER := 0;
BEGIN
  FOR c IN (SELECT name FROM user_ords_clients) LOOP
    BEGIN
      OAUTH.GRANT_CLIENT_ROLE(c.name, 'PROJECT_MANAGER_ROLE');
      l_granted := l_granted + 1;
      DBMS_OUTPUT.PUT_LINE('Granted PROJECT_MANAGER_ROLE to client: ' || c.name);
    EXCEPTION
      WHEN OTHERS THEN
        -- Already granted, or the role does not exist yet (it is created by
        -- the DEFINE_PRIVILEGE below). Either is fine to skip.
        DBMS_OUTPUT.PUT_LINE('Skipped ' || c.name || ': ' || SQLERRM);
    END;
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Clients granted: ' || l_granted);
END;
/


--------------------------------------------------------------------------------
-- 3. Rebuild both privileges with PROJECT_MANAGER_ROLE, preserving each
--    privilege's existing PATTERNS exactly. Only the role name changes.
--------------------------------------------------------------------------------
DECLARE
  PROCEDURE reroll(
    p_privilege   IN VARCHAR2,
    p_label       IN VARCHAR2,
    p_description IN VARCHAR2
  ) IS
    l_roles    owa.vc_arr;
    l_patterns owa.vc_arr;
    r          PLS_INTEGER := 0;
    p          PLS_INTEGER := 0;
    l_seen_pm  BOOLEAN := FALSE;
  BEGIN
    -- Existing roles, with REPORTING_MANAGER_ROLE swapped for
    -- PROJECT_MANAGER_ROLE and duplicates avoided.
    FOR x IN (SELECT role_name
              FROM   user_ords_privilege_roles
              WHERE  privilege_name = p_privilege
              ORDER  BY role_name)
    LOOP
      IF x.role_name = 'REPORTING_MANAGER_ROLE' OR x.role_name = 'PROJECT_MANAGER_ROLE' THEN
        IF NOT l_seen_pm THEN
          r := r + 1; l_roles(r) := 'PROJECT_MANAGER_ROLE';
          l_seen_pm := TRUE;
        END IF;
      ELSE
        r := r + 1; l_roles(r) := x.role_name;
      END IF;
    END LOOP;

    IF r = 0 THEN
      RAISE_APPLICATION_ERROR(-20085,
        p_privilege || ' has no roles - aborting rather than recreating it '||
        'with none, which would block every endpoint it covers.');
    END IF;

    FOR x IN (SELECT pm.pattern
              FROM   user_ords_privilege_mappings pm
              JOIN   user_ords_privileges pr ON pr.id = pm.privilege_id
              WHERE  pr.name = p_privilege
              ORDER  BY pm.pattern)
    LOOP
      p := p + 1; l_patterns(p) := x.pattern;
    END LOOP;

    IF p = 0 THEN
      RAISE_APPLICATION_ERROR(-20086,
        p_privilege || ' has no patterns - aborting rather than losing them.');
    END IF;

    -- Confirm every role exists BEFORE deleting anything. DEFINE_PRIVILEGE
    -- raises a bare ORA-01403 for a missing role, and by then the privilege
    -- is already gone and its endpoints unprotected. Check first, delete second.
    FOR i IN 1 .. r LOOP
      DECLARE
        l_n NUMBER;
      BEGIN
        SELECT COUNT(*) INTO l_n FROM user_ords_roles WHERE name = l_roles(i);
        IF l_n = 0 THEN
          RAISE_APPLICATION_ERROR(-20087,
            'Role ' || l_roles(i) || ' does not exist. Run section 2a first. '||
            'Aborting BEFORE deleting ' || p_privilege || ', so it stays protected.');
        END IF;
      END;
    END LOOP;

    ORDS.DELETE_PRIVILEGE(p_name => p_privilege);

    ORDS.DEFINE_PRIVILEGE(
      p_privilege_name => p_privilege,
      p_roles          => l_roles,
      p_patterns       => l_patterns,
      p_label          => p_label,
      p_description    => p_description);

    DBMS_OUTPUT.PUT_LINE(p_privilege || ': ' || r || ' roles, ' || p || ' patterns preserved.');
  END reroll;
BEGIN
  reroll(
    'expenses.authenticated',
    'Expense App - Authenticated Access',
    'Any signed-in employee or reviewer may call expense endpoints. Row-level checks happen in the handlers. auth/login is intentionally excluded - a wildcard here makes login impossible.');

  reroll(
    'expenses.review',
    'Expense App - Reviewer Only',
    'Project Manager / Finance Manager review queues and bulk actions. Employees cannot reach these URLs.');

  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 4. Verify BEFORE cleaning up. Both privileges should now list
--    PROJECT_MANAGER_ROLE and no REPORTING_MANAGER_ROLE, with their pattern
--    lists unchanged.
--------------------------------------------------------------------------------
SELECT privilege_name, role_name
FROM   user_ords_privilege_roles
ORDER  BY privilege_name, role_name;

SELECT p.name AS privilege_name, pm.pattern
FROM   user_ords_privileges p
JOIN   user_ords_privilege_mappings pm ON pm.privilege_id = p.id
ORDER  BY p.name, pm.pattern;

-- Must return zero rows.
SELECT pm.pattern FROM user_ords_privilege_mappings pm
WHERE  pm.pattern LIKE '/expenses/%*%' OR pm.pattern = '/expenses/*';


--------------------------------------------------------------------------------
-- 5. NOW re-test the app end to end on dev: log in, load your expense list,
--    open a pending item as a reviewer.
--
--    A 403 on a protected endpoint means the OAuth client is not carrying
--    PROJECT_MANAGER_ROLE - re-check section 2's output.
--
--    Only once that passes, optionally drop the obsolete grant below.
--    Leaving it costs nothing: no privilege references REPORTING_MANAGER_ROLE
--    any more, so it grants nothing. Removing it is tidiness, not security.
--------------------------------------------------------------------------------
/*
BEGIN
  FOR c IN (SELECT name FROM user_ords_clients) LOOP
    BEGIN
      OAUTH.REVOKE_CLIENT_ROLE(c.name, 'REPORTING_MANAGER_ROLE');
      DBMS_OUTPUT.PUT_LINE('Revoked REPORTING_MANAGER_ROLE from ' || c.name);
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Skipped ' || c.name || ': ' || SQLERRM);
    END;
  END LOOP;
  COMMIT;
END;
/
*/
