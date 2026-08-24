--------------------------------------------------------------------------------
-- PRODUCTION SETUP — File 2b of 5: OAuth client, secrets, and Network ACL
-- grants.
--
-- Run this AFTER PROD_2_ords_and_security_setup.sql, as the same schema
-- owner (the ACL blocks in sections 3/3.1 typically need a DBA/ADMIN
-- account instead — see the note there).
--
-- Unlike PROD_2, this file is SAFE to re-run, tweak, or re-order at any
-- time — nothing here touches ORDS.DEFINE_MODULE/DEFINE_TEMPLATE, so
-- there's no risk of wiping endpoint handlers. If you need to fix a typo,
-- add another ACL grant, or rotate a secret, just re-run the specific
-- block you need from this file — no need to touch PROD_2/3/4 at all.
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- 1. Production OAuth2 client (client_credentials grant) — this should be a
-- DIFFERENT registration than whatever you used for testing, not a reused
-- test client. After running this THE FIRST TIME, get the generated
-- client_id/secret from SQL Developer Web (REST Workshop > OAuth Clients)
-- — CREATE_CLIENT doesn't return them via PL/SQL, only the UI shows the
-- generated secret once.
--
-- Safe to re-run: if the client already exists, ORA-00001 is caught and
-- ignored below rather than left to surface as a scary-looking error.
-- NOTE: this means re-running this block will NOT rotate the client's
-- secret if you already have one recorded in app_secrets (section 2) —
-- that's intentional, since changing it here without updating section 2
-- to match would break login for everyone until you did.
--------------------------------------------------------------------------------
BEGIN
  OAUTH.CREATE_CLIENT(
    p_name            => 'EXPENSE_APP_CLIENT_PROD',
    p_grant_type      => 'client_credentials',
    p_owner           => 'deepan.chandrasekar@trinamix.com',
    p_description     => 'Mobile Expense App ',
    p_support_email   => 'deepan.chandrasekar@trinamix.com',
    p_privilege_names => 'expenses.authenticated,expenses.review'
  );
  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1 THEN RAISE; END IF; -- -1 = client already exists, safe to ignore
END;
/

BEGIN
  OAUTH.GRANT_CLIENT_ROLE(p_client_name => 'EXPENSE_APP_CLIENT_PROD', p_role_name => 'EMPLOYEE_ROLE');
  OAUTH.GRANT_CLIENT_ROLE(p_client_name => 'EXPENSE_APP_CLIENT_PROD', p_role_name => 'PROJECT_MANAGER_ROLE');
  OAUTH.GRANT_CLIENT_ROLE(p_client_name => 'EXPENSE_APP_CLIENT_PROD', p_role_name => 'FINANCE_MANAGER_ROLE');
  COMMIT;
END;
/

--------------------------------------------------------------------------------
-- 2. Store the OAuth client's own credentials SERVER-SIDE ONLY
--SELECT *
--FROM user_ords_clients;
--------------------------------------------------------------------------------
DECLARE
  PROCEDURE set_secret(p_name IN VARCHAR2, p_value IN VARCHAR2) IS
  BEGIN
    MERGE INTO app_secrets t
    USING (SELECT p_name AS secret_name FROM dual) s
    ON (t.secret_name = s.secret_name)
    WHEN MATCHED THEN UPDATE SET t.secret_value = p_value
    WHEN NOT MATCHED THEN INSERT (secret_name, secret_value) VALUES (p_name, p_value);
  END;
BEGIN
  set_secret('OAUTH_CLIENT_ID',     'PASTE_THE_GENERATED_CLIENT_ID_HERE');
  set_secret('OAUTH_CLIENT_SECRET', 'PASTE_THE_GENERATED_CLIENT_SECRET_HERE');
  set_secret('OAUTH_TOKEN_URL',     'https://your-prod-domain.com/ords/your_schema/oauth/token');
  COMMIT;
END;
/

--------------------------------------------------------------------------------
-- 3. Network ACL grants for your app schema — lets the database make
-- outbound HTTPS calls to (a) Expo's push service, and (b) its OWN ORDS
-- host, needed for get_oauth_access_token (PROD_3_business_logic.sql) to
-- call the /oauth/token endpoint from inside a PL/SQL handler. Replace
-- 'YOUR_SCHEMA_NAME' and 'your-prod-domain.com' below with the real
-- production schema name (run `SELECT SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
-- FROM DUAL;` while connected as the app schema if you're not sure) and
-- domain. This typically needs to be run by a DBA/ADMIN account rather
-- than the regular app schema user.
BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host       => 'exp.host',
    ace        => xs$ace_type(
                    privilege_list => xs$name_list('http'),
                    principal_name => 'YOUR_SCHEMA_NAME',  
                    principal_type => xs_acl.ptype_db
                  )
  );
END;
/

BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host       => 'your-prod-domain.com',  
    ace        => xs$ace_type(
                    privilege_list => xs$name_list('http'),
                    principal_name => 'YOUR_SCHEMA_NAME',  
                    principal_type => xs_acl.ptype_db
                  )
  );
END;
/

--------------------------------------------------------------------------------
-- 3.1 — ALSO grant both hosts to APEX_PUBLIC_USER (the runtime connection
-- pool user). Harmless to keep even though it turned out not to be the
-- actual answer for this specific error — see 3.1b below for the real fix.
--------------------------------------------------------------------------------
BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host       => 'exp.host',
    ace        => xs$ace_type(
                    privilege_list => xs$name_list('http'),
                    principal_name => 'APEX_PUBLIC_USER',
                    principal_type => xs_acl.ptype_db
                  )
  );
END;
/

BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host       => 'your-prod-domain.com',  
    ace        => xs$ace_type(
                    privilege_list => xs$name_list('http'),
                    principal_name => 'APEX_PUBLIC_USER',
                    principal_type => xs_acl.ptype_db
                  )
  );
END;
/

--------------------------------------------------------------------------------
-- 3.1b — ALSO grant both hosts to the schema that ACTUALLY owns the
-- APEX_WEB_SERVICE package. get_oauth_access_token and
-- send_push_notification both go through apex_web_service.make_rest_
-- request, and since PL/SQL packages run with their owner's privileges,
-- the outbound network call really executes as that owning schema — NOT
-- your app schema, and NOT APEX_PUBLIC_USER either (that guess, in 3.1
-- above, turned out to be wrong; it's the runtime connection-pool user,
-- not the schema that owns the package).
--
-- Find the real owner by running (needs DBA_ view access):
--   SELECT owner, object_name, object_type FROM dba_objects
--   WHERE object_name = 'APEX_WEB_SERVICE';
-- APEX_WEB_SERVICE is reached through a chain of synonyms, so you may see
-- more than one row — the one to use is the Oracle APEX engine schema
-- itself, named like APEX_<version>, e.g. APEX_240200 for APEX 24.2.
-- (Confirmed for this instance: APEX_240200 — substitute your own
-- version's schema name below if this differs on another environment.)
--------------------------------------------------------------------------------
BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host       => 'exp.host',
    ace        => xs$ace_type(
                    privilege_list => xs$name_list('http'),
                    principal_name => 'APEX_240200',  -- <<< CHANGE THIS if your APEX version differs
                    principal_type => xs_acl.ptype_db
                  )
  );
END;
/

BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host       => 'your-prod-domain.com',  -- <<< CHANGE THIS to match OAUTH_TOKEN_URL's host
    ace        => xs$ace_type(
                    privilege_list => xs$name_list('http'),
                    principal_name => 'APEX_240200',  -- <<< CHANGE THIS if your APEX version differs
                    principal_type => xs_acl.ptype_db
                  )
  );
END;
/

--------------------------------------------------------------------------------
-- 3.2 — Verify the grants above actually took, for both hosts. Should
-- return two rows per host (one per principal). If a host/principal
-- combination is missing here, its ACL grant above did not succeed (or
-- was run by the wrong account) — that's exactly what produces
-- "ORA-24247: network access denied by access control list (ACL)" at
-- runtime.
--
-- Uses DBA_HOST_ACES — the view that matches APPEND_HOST_ACE's unified
-- ACL model (NOT dba_network_acl_privileges, which is the older XML-ACL
-- model and doesn't have a HOST column at all). Requires DBA_ view access
-- — if this errors with "table or view does not exist", you don't have
-- SELECT_CATALOG_ROLE and need to ask your Oracle admin to run this check
-- instead.
--
-- Deliberately SELECT * here rather than naming specific columns — exact
-- column names/casing for this view have varied enough across Oracle
-- versions that it's more reliable to just look at whatever your version
-- actually returns than to guess a column list.
--------------------------------------------------------------------------------
SELECT *
FROM   dba_host_aces
WHERE  host IN ('exp.host', 'your-prod-domain.com')  -- <<< CHANGE 2nd value to match above
ORDER BY host;

COMMIT;

--------------------------------------------------------------------------------
-- After this file: PROD_3_business_logic.sql, then PROD_4_endpoints.sql.
-- Also enable CORS (13_cors_fix_for_web_testing.sql) ONLY if you'll ever
-- access these endpoints from a browser — skip it for a mobile-app-only
-- production deployment.
--------------------------------------------------------------------------------
