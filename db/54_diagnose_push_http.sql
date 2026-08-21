--------------------------------------------------------------------------------
-- 54_diagnose_push_http.sql
--
-- Run as the application schema, with SET SERVEROUTPUT ON. Read-only.
--
-- SYMPTOM
-- -------
--   FAILED: ORA-29273: HTTP request failed
--
-- The device IS registered (a token was found), so the app side is working.
-- The database cannot reach https://exp.host.
--
-- ORA-29273 IS NOT THE CAUSE. It is a wrapper that UTL_HTTP raises around
-- whatever actually went wrong, and SQLERRM only returns the outermost line --
-- which is why the real reason has been invisible. There are four very
-- different causes hiding behind it, each needing a different person to fix:
--
--   ORA-24247  network ACL missing for exp.host          -> DBA
--   ORA-29024  TLS certificate validation failed         -> DBA (wallet)
--   ORA-12535  timeout / no route to host                -> network team
--   ORA-29276  transfer timeout                          -> network team
--
-- Section 1 prints the full error stack so you can tell which.
--
-- NOTE: login already makes an HTTPS call from the database, to your own ORDS
-- host, and that works. So this is NOT "the database cannot do HTTPS". It is
-- specifically about reaching a host on the public internet -- which is a
-- different ACL entry, a different certificate authority, and quite possibly
-- a firewall that permits internal traffic only.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF


--------------------------------------------------------------------------------
-- 1. The real error.
--------------------------------------------------------------------------------
DECLARE
  l_response CLOB;
  l_stack    VARCHAR2(4000);
BEGIN
  DBMS_OUTPUT.PUT_LINE('Calling https://exp.host ...');
  DBMS_OUTPUT.PUT_LINE(' ');

  apex_web_service.g_request_headers.DELETE;
  apex_web_service.g_request_headers(1).name  := 'Content-Type';
  apex_web_service.g_request_headers(1).value := 'application/json';

  -- Deliberately an empty message list: Expo replies with a harmless
  -- validation error, which is all we need. A 200 or a 400 both prove the
  -- connection works.
  l_response := apex_web_service.make_rest_request(
    p_url         => 'https://exp.host/--/api/v2/push/send',
    p_http_method => 'POST',
    p_body        => '[]'
  );

  DBMS_OUTPUT.PUT_LINE('SUCCESS -- the database can reach Expo.');
  DBMS_OUTPUT.PUT_LINE('HTTP status: ' || apex_web_service.g_status_code);
  DBMS_OUTPUT.PUT_LINE('Response   : ' || SUBSTR(l_response, 1, 500));
  DBMS_OUTPUT.PUT_LINE(' ');
  DBMS_OUTPUT.PUT_LINE('If this succeeds but real pushes fail, the problem is the');
  DBMS_OUTPUT.PUT_LINE('payload or the token, not connectivity. Re-run');
  DBMS_OUTPUT.PUT_LINE('test_push_notification and read Expo''s reply.');

EXCEPTION
  WHEN OTHERS THEN
    l_stack := DBMS_UTILITY.FORMAT_ERROR_STACK;

    DBMS_OUTPUT.PUT_LINE('FAILED. Full error stack -- the SECOND line is the real cause:');
    DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------------');
    DBMS_OUTPUT.PUT_LINE(l_stack);
    DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------------');
    DBMS_OUTPUT.PUT_LINE(' ');

    IF INSTR(l_stack, 'ORA-24247') > 0 THEN
      DBMS_OUTPUT.PUT_LINE('DIAGNOSIS: no network ACL for exp.host.');
      DBMS_OUTPUT.PUT_LINE('WHO FIXES IT: a DBA. Give them section 3 below.');
      DBMS_OUTPUT.PUT_LINE('Note the ACL must be granted to the APEX ENGINE schema, not just');
      DBMS_OUTPUT.PUT_LINE('this one -- APEX_WEB_SERVICE runs with its owner''s privileges.');

    ELSIF INSTR(l_stack, 'ORA-29024') > 0 THEN
      DBMS_OUTPUT.PUT_LINE('DIAGNOSIS: TLS certificate validation failed.');
      DBMS_OUTPUT.PUT_LINE('The database does not trust the certificate authority that signed');
      DBMS_OUTPUT.PUT_LINE('exp.host. Your own ORDS host works because ITS certificate is');
      DBMS_OUTPUT.PUT_LINE('already trusted -- a public CA is a separate matter.');
      DBMS_OUTPUT.PUT_LINE('WHO FIXES IT: a DBA. See section 4.');

    ELSIF INSTR(l_stack, 'ORA-12535') > 0
       OR INSTR(l_stack, 'ORA-12541') > 0
       OR INSTR(l_stack, 'ORA-29276') > 0
       OR INSTR(l_stack, 'ORA-12170') > 0 THEN
      DBMS_OUTPUT.PUT_LINE('DIAGNOSIS: the connection timed out or had no route.');
      DBMS_OUTPUT.PUT_LINE('The database server itself has no outbound internet access to');
      DBMS_OUTPUT.PUT_LINE('exp.host on port 443. An ACL grants PERMISSION to connect; it does');
      DBMS_OUTPUT.PUT_LINE('not create a ROUTE. A firewall or proxy is in the way.');
      DBMS_OUTPUT.PUT_LINE('WHO FIXES IT: whoever runs the network. See section 5 for the');
      DBMS_OUTPUT.PUT_LINE('proxy option and the fallback if egress is refused.');

    ELSE
      DBMS_OUTPUT.PUT_LINE('DIAGNOSIS: not one of the four known causes. Search the ORA number');
      DBMS_OUTPUT.PUT_LINE('in the stack above -- it is the specific one, not ORA-29273.');
    END IF;
END;
/


--------------------------------------------------------------------------------
-- 2. What the app schema can see of its own ACLs.
--
--    Usually empty for a non-DBA -- absence here proves nothing. Section 3 is
--    the authoritative check and needs DBA rights.
--------------------------------------------------------------------------------
-- USER_NETWORK_ACL_PRIVILEGES has no PRINCIPAL column -- the principal is
-- implicitly the current user. Selecting it fails with ORA-00904.
BEGIN
  FOR r IN (SELECT host, lower_port, upper_port, privilege, status
            FROM   user_network_acl_privileges
            ORDER  BY host)
  LOOP
    DBMS_OUTPUT.PUT_LINE('ACL visible: ' || r.host || ' ' || r.privilege
      || ' -> ' || r.status);
  END LOOP;
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Cannot read ACL views from this schema (expected).');
END;
/

SET FEEDBACK ON


--------------------------------------------------------------------------------
-- 3. FOR THE DBA -- grant the ACL for exp.host.
--
-- Only needed if section 1 reported ORA-24247.
--
-- Replace <APEX_ENGINE_SCHEMA> with the result of:
--   SELECT owner FROM dba_objects WHERE object_name = 'APEX_WEB_SERVICE'
--   AND rownum = 1;                       -- the APEX_nnnnnn one
-- and <APP_SCHEMA> with the schema the app uses.
--------------------------------------------------------------------------------
/*
BEGIN
  FOR p IN (SELECT '<APEX_ENGINE_SCHEMA>' AS n FROM dual
            UNION ALL SELECT '<APP_SCHEMA>'     FROM dual
            UNION ALL SELECT 'APEX_PUBLIC_USER' FROM dual)
  LOOP
    BEGIN
      DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
        host => 'exp.host',
        ace  => xs$ace_type(privilege_list => xs$name_list('http'),
                            principal_name => p.n,
                            principal_type => xs_acl.ptype_db));
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;
  COMMIT;
END;
/

SELECT host, principal, privilege, grant_type
FROM   dba_host_aces
WHERE  host = 'exp.host'
ORDER  BY principal;
*/


--------------------------------------------------------------------------------
-- 4. FOR THE DBA -- certificate trust, if section 1 reported ORA-29024.
--
-- Oracle validates the server certificate on every HTTPS call and needs the
-- signing CA in its trust store.
--
--   Autonomous Database: a public CA bundle is already present. ORA-29024
--   against a public host is unexpected -- check for an intercepting proxy.
--
--   On-premises: the DBA adds the CA that signs exp.host (currently Amazon /
--   ISRG) to the database wallet:
--
--     orapki wallet add -wallet /path/to/wallet -trusted_cert \
--            -cert amazon_root_ca1.pem -pwd <password>
--
--   Then the call must reference it:
--     apex_web_service.make_rest_request(..., p_wallet_path => 'file:/path/to/wallet')
--   or the wallet is set database-wide via the WALLET_PATH APEX instance
--   parameter, which is preferable -- send_push_notification passes no wallet.
--
-- Certificates expire. If push stops working in a year with no code change,
-- look here first.
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- 5. If the database has no outbound internet access at all
--
-- Entirely possible, and often deliberate: a production database that cannot
-- reach the internet is a reasonable security posture, and no ACL will change
-- it. Options, best first:
--
--   a) Allow egress to exp.host:443 only. One host, one port, outbound only.
--      The narrowest possible exception, and worth asking for.
--
--   b) Route through the existing corporate proxy:
--         apex_web_service.make_rest_request(..., p_proxy_override => 'proxy.trinamix.com:8080')
--      Needs the same change in send_push_notification.
--
--   c) Drop database-initiated push. Have the app poll instead -- it already
--      refreshes on focus, so approvals would appear on next open rather than
--      as a banner. Loses real-time alerts; costs no infrastructure.
--
-- Everything else in the app works regardless. Push is the only feature that
-- needs the database to reach the internet.
--------------------------------------------------------------------------------
