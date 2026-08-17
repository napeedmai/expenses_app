

--------------------------------------------------------------------------------
-- 1. REST-enable this schema.
--------------------------------------------------------------------------------
BEGIN
  ORDS.ENABLE_SCHEMA(p_enabled => TRUE, p_schema => NULL);
  COMMIT;
END;
/

--------------------------------------------------------------------------------
-- 2. Roles.
--------------------------------------------------------------------------------
BEGIN
  ORDS.CREATE_ROLE(p_role_name => 'EMPLOYEE_ROLE');
EXCEPTION WHEN OTHERS THEN NULL; 
END;
/
BEGIN
  ORDS.CREATE_ROLE(p_role_name => 'PROJECT_MANAGER_ROLE');
EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
  ORDS.CREATE_ROLE(p_role_name => 'FINANCE_MANAGER_ROLE');
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

--------------------------------------------------------------------------------
-- 3. Module + every URI template used across the whole app. One
-- DEFINE_MODULE call, ever — re-running DEFINE_MODULE on an existing module
-- would wipe out every template already on it, so this whole file is
-- structured to call it only once at the very top.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_MODULE(
    p_module_name => 'expenses.employee',
    p_base_path   => '/expenses/',
    p_comments    => 'All expense app endpoints — employee-facing and reviewer-facing.'
  );

  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => 'auth/login');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => 'whoami');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => 'my-projects');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => 'draft');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => 'mine');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => ':id');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => ':id/submit');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => ':id/attachment');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => 'pending');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => ':id/accept');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => ':id/revise');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => ':id/reject');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => 'bulk-accept');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => 'bulk-revise');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => 'bulk-reject');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'expenses.employee', p_pattern => 'push-token');
  COMMIT;
END;
/

--------------------------------------------------------------------------------
-- 4. Privileges — the coarse gate (authenticated at all vs. reviewer-only).
-- Fine-grained "is this the RIGHT reviewer for THIS expense right now"
-- happens inside the handlers (PROD_4_endpoints.sql), via
-- get_reviewer_role()/is_valid_session_token() — ORDS URL-pattern
-- privileges can't express per-row ownership on their own.
--
-- IMPORTANT: 'auth/login' is deliberately NOT in this list. It's the one
-- endpoint the app can reach with no OAuth Bearer token at all — it's the
-- single door in, and it only opens for a real employee username/password
-- (see PROD_4_endpoints.sql). It then hands back both the OAuth access
-- token AND the session token in one response, so the app never needs to
-- hold the OAuth client secret itself (see PROD_3_business_logic.sql,
-- get_oauth_access_token). Every pattern below still requires a valid
-- Bearer token — and the only way to get one is through that real login.
--
-- NEVER USE A WILDCARD LIKE '/expenses/*' HERE. This is not a style
-- preference. ORDS applies EVERY privilege whose pattern matches a URI, and
-- provides no way to exempt a single path from a wildcard — so '/expenses/*'
-- silently captures '/expenses/auth/login' too and makes login impossible by
-- construction: a Bearer token becomes required to log in, and logging in is
-- the only way to obtain one. A dev environment was set up that way and every
-- login returned a full ORDS "Unauthorized — please sign in" HTML page, with
-- nothing anywhere naming the privilege responsible. Each protected endpoint
-- must be listed explicitly, exactly as below. Add a line here whenever a new
-- endpoint is added to PROD_4_endpoints.sql.
--
-- Use EXACT patterns, not trailing wildcards. '/expenses/pending/*' does NOT
-- match '/expenses/pending', which is the URL the app actually calls — dev
-- shipped that typo and left the reviewer queue endpoints unprotected.
--
-- Verify after any change to this file; the second query must return no rows:
--   SELECT pm.pattern, p.name FROM user_ords_privilege_mappings pm
--     JOIN user_ords_privileges p ON p.id = pm.privilege_id ORDER BY 1;
--   SELECT pm.pattern FROM user_ords_privilege_mappings pm
--     WHERE pm.pattern LIKE '/expenses/%*%' OR pm.pattern = '/expenses/*';
--
-- Role names differ between environments (dev uses REPORTING_MANAGER_ROLE
-- where prod uses PROJECT_MANAGER_ROLE). Confirm against
-- user_ords_privilege_roles before copying this file between instances — the
-- OAuth client is granted the local names, and a mismatch locks out every
-- protected endpoint.
--
-- ALSO IMPORTANT: 'pending', 'bulk-accept', 'bulk-revise', and
-- 'bulk-reject' are deliberately NOT in this list either — ORDS does not
-- allow the same URI pattern to be covered by two different privileges
-- (it errors with "ORA-20039: Pattern already mapped"), and those four
-- patterns belong exclusively to the expenses.review privilege below,
-- since only Project Manager/Finance Manager should reach them at all —
-- not every employee.
--------------------------------------------------------------------------------
DECLARE
  l_roles    owa.vc_arr;
  l_patterns owa.vc_arr;
BEGIN
  l_roles(1) := 'EMPLOYEE_ROLE';
  l_roles(2) := 'PROJECT_MANAGER_ROLE';
  l_roles(3) := 'FINANCE_MANAGER_ROLE';

  l_patterns(1)  := '/expenses/whoami';
  l_patterns(2)  := '/expenses/my-projects';
  l_patterns(3)  := '/expenses/draft';
  l_patterns(4)  := '/expenses/mine';
  l_patterns(5)  := '/expenses/:id';
  l_patterns(6)  := '/expenses/:id/submit';
  l_patterns(7)  := '/expenses/:id/attachment';
  l_patterns(8)  := '/expenses/:id/accept';
  l_patterns(9)  := '/expenses/:id/revise';
  l_patterns(10) := '/expenses/:id/reject';
  l_patterns(11) := '/expenses/push-token';

  ORDS.DEFINE_PRIVILEGE(
    p_privilege_name => 'expenses.authenticated',
    p_roles          => l_roles,
    p_patterns       => l_patterns,
    p_label          => 'Expense App - Authenticated Access',
    p_description    => 'Any signed-in Employee, Project Manager, or Finance Manager may call expense endpoints. Row-level ownership/stage checks happen in the handler. auth/login is intentionally excluded — see note above.'
  );
  COMMIT;
END;
/

DECLARE
  l_roles    owa.vc_arr;
  l_patterns owa.vc_arr;
BEGIN
  l_roles(1) := 'PROJECT_MANAGER_ROLE';
  l_roles(2) := 'FINANCE_MANAGER_ROLE';
  l_patterns(1) := '/expenses/pending';
  l_patterns(2) := '/expenses/bulk-accept';
  l_patterns(3) := '/expenses/bulk-revise';
  l_patterns(4) := '/expenses/bulk-reject';

  ORDS.DEFINE_PRIVILEGE(
    p_privilege_name => 'expenses.review',
    p_roles          => l_roles,
    p_patterns       => l_patterns,
    p_label          => 'Expense App - Reviewer Only',
    p_description    => 'Project Manager / Finance Manager review queues and bulk actions. Employees cannot reach these URLs.'
  );
  COMMIT;
END;
/

