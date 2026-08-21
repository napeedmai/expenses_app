--------------------------------------------------------------------------------
-- 55_push_wallet.sql
--
-- Run as the application schema. Idempotent.
--
-- SYMPTOM (confirmed by 54_diagnose_push_http.sql)
-- ------------------------------------------------
--   ORA-29273: HTTP request failed
--   ORA-29024: Certificate validation failure
--
-- WHAT THIS MEANS
-- ---------------
-- The network ACL is fine -- the request reached exp.host and failed during
-- the TLS handshake. Oracle validates the server certificate on every HTTPS
-- call and refuses to continue unless it trusts the CA that signed it.
--
-- Login already makes an HTTPS call from the database and works, which is why
-- this is confusing. That call goes to your OWN ORDS host, whose certificate
-- the database already trusts. exp.host is signed by a public CA that is not
-- in the trust store. Trusting one says nothing about the other.
--
-- WHAT HAS TO HAPPEN
-- ------------------
-- A DBA creates (or extends) an Oracle wallet containing the root CA for
-- exp.host. Then the database has to be told to USE it -- there are two ways,
-- and this script implements the one that needs no APEX instance changes:
--
--   A. APEX instance-wide (cleanest, but needs an APEX administrator)
--        APEX_INSTANCE_ADMIN.SET_PARAMETER('WALLET_PATH', 'file:/path/to/wallet')
--        Every APEX_WEB_SERVICE call then uses it, and no app code changes.
--
--   B. Per call (this script)
--        send_push_notification reads an optional wallet path from APP_SECRETS
--        and passes it. Nothing outside this app is affected.
--
-- Option B also stays correct if the wallet is later configured instance-wide:
-- leave the APP_SECRETS rows unset and the calls fall back to APEX's wallet.
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- 1. FOR THE DBA -- build the wallet.  (Shell commands, not SQL.)
--
-- First find out which root CA actually signs exp.host, rather than guessing:
-- open https://exp.host in a browser, click the padlock, view the certificate,
-- and look at the top of the certification path. Download that root as PEM
-- from the CA's own site.
--
--   # once, if no wallet exists yet
--   orapki wallet create -wallet /opt/oracle/wallet_expo -auto_login -pwd <pwd>
--
--   # add the root CA
--   orapki wallet add -wallet /opt/oracle/wallet_expo -trusted_cert \
--          -cert /tmp/root_ca.pem -pwd <pwd>
--
--   # confirm
--   orapki wallet display -wallet /opt/oracle/wallet_expo
--
-- -auto_login matters: without it every call must supply the password.
-- The oracle OS user must be able to read the directory.
--
-- If you already have a wallet for other outbound calls, add the cert to that
-- one instead of creating a second.
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- 2. Record the wallet location.
--
-- Leave these unset (or delete the rows) if the DBA configures the wallet
-- instance-wide via APEX_INSTANCE_ADMIN -- section 4 then handles it and the
-- code passes NULL, which makes APEX use its own setting.
--
-- EDIT THE PATH BEFORE RUNNING. 'file:' prefix required. No trailing slash.
--------------------------------------------------------------------------------
MERGE INTO app_secrets t
USING (SELECT 'PUSH_WALLET_PATH' AS n, 'file:/opt/oracle/wallet_expo' AS v FROM dual) s
ON (t.secret_name = s.n)
WHEN MATCHED THEN UPDATE SET t.secret_value = s.v
WHEN NOT MATCHED THEN INSERT (secret_name, secret_value) VALUES (s.n, s.v);

-- Only needed if the wallet was created WITHOUT -auto_login.
-- MERGE INTO app_secrets t
-- USING (SELECT 'PUSH_WALLET_PWD' AS n, '<wallet password>' AS v FROM dual) s
-- ON (t.secret_name = s.n)
-- WHEN MATCHED THEN UPDATE SET t.secret_value = s.v
-- WHEN NOT MATCHED THEN INSERT (secret_name, secret_value) VALUES (s.n, s.v);

COMMIT;


--------------------------------------------------------------------------------
-- 3. Sender, now wallet-aware.
--
-- Unchanged from 52 apart from the two wallet parameters. Still autonomous,
-- still silent on failure -- a push that fails must never roll back the
-- approval that triggered it.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE send_push_notification(
  p_emp_id      IN NUMBER,
  p_title       IN VARCHAR2,
  p_body        IN VARCHAR2,
  p_expense_id  IN NUMBER DEFAULT NULL
) IS
  PRAGMA AUTONOMOUS_TRANSACTION;
  l_payload     CLOB;
  l_response    CLOB;
  l_wallet_path VARCHAR2(200);
  l_wallet_pwd  VARCHAR2(200);

  FUNCTION secret(p_name IN VARCHAR2) RETURN VARCHAR2 IS
    l_v VARCHAR2(200);
  BEGIN
    SELECT secret_value INTO l_v FROM app_secrets WHERE secret_name = p_name;
    RETURN l_v;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;   -- fall back to the APEX instance wallet
  END;

BEGIN
  l_wallet_path := secret('PUSH_WALLET_PATH');
  l_wallet_pwd  := secret('PUSH_WALLET_PWD');

  FOR t IN (SELECT push_token FROM emp_push_tokens WHERE emp_id = p_emp_id) LOOP
    BEGIN
      l_payload := '{"to":"' || json_escape_str(t.push_token) ||
                   '","title":"' || json_escape_str(p_title) ||
                   '","body":"' || json_escape_str(p_body) ||
                   '","sound":"default"' ||
                   ',"priority":"high"' ||
                   ',"channelId":"expense-updates"' ||
                   CASE WHEN p_expense_id IS NOT NULL
                        THEN ',"data":{"expenseId":' || p_expense_id || '}'
                        ELSE '' END ||
                   '}';

      apex_web_service.g_request_headers.DELETE;
      apex_web_service.g_request_headers(1).name  := 'Content-Type';
      apex_web_service.g_request_headers(1).value := 'application/json';
      apex_web_service.g_request_headers(2).name  := 'Accept';
      apex_web_service.g_request_headers(2).value := 'application/json';

      l_response := apex_web_service.make_rest_request(
        p_url         => 'https://exp.host/--/api/v2/push/send',
        p_http_method => 'POST',
        p_body        => l_payload,
        p_wallet_path => l_wallet_path,
        p_wallet_pwd  => l_wallet_pwd
      );
    EXCEPTION
      WHEN OTHERS THEN NULL;
    END;
  END LOOP;
  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
END send_push_notification;
/


--------------------------------------------------------------------------------
-- 4. Diagnostic version -- same wallet handling, but reports everything.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE test_push_notification(p_emp_id IN NUMBER) IS
  l_payload     CLOB;
  l_response    CLOB;
  l_count       NUMBER := 0;
  l_wallet_path VARCHAR2(200);
  l_wallet_pwd  VARCHAR2(200);

  FUNCTION secret(p_name IN VARCHAR2) RETURN VARCHAR2 IS
    l_v VARCHAR2(200);
  BEGIN
    SELECT secret_value INTO l_v FROM app_secrets WHERE secret_name = p_name;
    RETURN l_v;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;
  END;

BEGIN
  l_wallet_path := secret('PUSH_WALLET_PATH');
  l_wallet_pwd  := secret('PUSH_WALLET_PWD');

  DBMS_OUTPUT.PUT_LINE('Testing push for EMPID ' || p_emp_id);
  DBMS_OUTPUT.PUT_LINE('Wallet: ' || NVL(l_wallet_path, '(none -- using APEX instance wallet)'));

  FOR t IN (SELECT push_token FROM emp_push_tokens WHERE emp_id = p_emp_id) LOOP
    l_count := l_count + 1;
    DBMS_OUTPUT.PUT_LINE('  device ' || l_count || ': ' || SUBSTR(t.push_token, 1, 30) || '...');

    l_payload := '{"to":"' || json_escape_str(t.push_token) ||
                 '","title":"Test notification"' ||
                 ',"body":"If you can see this on your phone, push works."' ||
                 ',"sound":"default","priority":"high"' ||
                 ',"channelId":"expense-updates"}';

    BEGIN
      apex_web_service.g_request_headers.DELETE;
      apex_web_service.g_request_headers(1).name  := 'Content-Type';
      apex_web_service.g_request_headers(1).value := 'application/json';
      apex_web_service.g_request_headers(2).name  := 'Accept';
      apex_web_service.g_request_headers(2).value := 'application/json';

      l_response := apex_web_service.make_rest_request(
        p_url         => 'https://exp.host/--/api/v2/push/send',
        p_http_method => 'POST',
        p_body        => l_payload,
        p_wallet_path => l_wallet_path,
        p_wallet_pwd  => l_wallet_pwd
      );

      DBMS_OUTPUT.PUT_LINE('  HTTP status : ' || apex_web_service.g_status_code);
      DBMS_OUTPUT.PUT_LINE('  Expo says   : ' || SUBSTR(l_response, 1, 900));
      DBMS_OUTPUT.PUT_LINE(' ');
      DBMS_OUTPUT.PUT_LINE('    "status":"ok"          -> Expo accepted it. If nothing appears');
      DBMS_OUTPUT.PUT_LINE('                              on the phone, the problem is on the');
      DBMS_OUTPUT.PUT_LINE('                              device: notifications disabled, battery');
      DBMS_OUTPUT.PUT_LINE('                              saver, or a build predating the channel fix.');
      DBMS_OUTPUT.PUT_LINE('    "DeviceNotRegistered"  -> app uninstalled or token stale. Delete');
      DBMS_OUTPUT.PUT_LINE('                              the row and log in again.');
      DBMS_OUTPUT.PUT_LINE('    "InvalidCredentials"   -> the token belongs to a different Expo');
      DBMS_OUTPUT.PUT_LINE('                              project than the one that built the app.');

    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('  FAILED. Full stack:');
        DBMS_OUTPUT.PUT_LINE(DBMS_UTILITY.FORMAT_ERROR_STACK);
        IF INSTR(DBMS_UTILITY.FORMAT_ERROR_STACK, 'ORA-29024') > 0 THEN
          DBMS_OUTPUT.PUT_LINE('  Still a certificate failure. Either the wallet path above is');
          DBMS_OUTPUT.PUT_LINE('  wrong/unreadable by the oracle OS user, or the wallet does not');
          DBMS_OUTPUT.PUT_LINE('  contain the root CA that actually signs exp.host. Verify with');
          DBMS_OUTPUT.PUT_LINE('  orapki wallet display, and re-check the issuer in a browser.');
        END IF;
    END;
  END LOOP;

  IF l_count = 0 THEN
    DBMS_OUTPUT.PUT_LINE('  NO DEVICES REGISTERED for this employee.');
  END IF;
END test_push_notification;
/


--------------------------------------------------------------------------------
-- 5. Verify, then test.
--------------------------------------------------------------------------------
SELECT secret_name,
       CASE WHEN secret_name LIKE '%PWD%' OR secret_name LIKE '%SECRET%'
            THEN '(set)' ELSE secret_value END AS value
FROM   app_secrets
WHERE  secret_name LIKE 'PUSH_WALLET%'
ORDER  BY secret_name;

SELECT object_name, status FROM user_objects
WHERE  object_name IN ('SEND_PUSH_NOTIFICATION','TEST_PUSH_NOTIFICATION')
ORDER  BY object_name;

-- SET SERVEROUTPUT ON
-- BEGIN test_push_notification(3725); END;
-- /


--------------------------------------------------------------------------------
-- ALTERNATIVE: configure the wallet APEX-wide instead
--
-- Preferable if anything else in this database will ever call an external
-- HTTPS service. Run by an APEX administrator, then DELETE the APP_SECRETS
-- rows above so this app falls back to the instance setting.
--
--   BEGIN
--     APEX_INSTANCE_ADMIN.SET_PARAMETER('WALLET_PATH', 'file:/opt/oracle/wallet_expo');
--     APEX_INSTANCE_ADMIN.SET_PARAMETER('WALLET_PWD',  '<pwd>');   -- omit if -auto_login
--     COMMIT;
--   END;
--   /
--
-- NOTE FOR THE FUTURE: public CA certificates expire and get rotated. If push
-- silently stops working months from now with no code change, run
-- 54_diagnose_push_http.sql first -- an expired root in the wallet looks
-- exactly like this failure did.
--------------------------------------------------------------------------------
