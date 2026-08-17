

--------------------------------------------------------------------------------
-- Is this EMPID the Finance Manager? Hardcoded to 3680 — the one place to
-- change if a second Finance Manager is ever added.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION is_finance_manager(p_emp_id IN NUMBER) RETURN VARCHAR2 IS
BEGIN
  RETURN CASE WHEN p_emp_id = 3680 THEN 'Y' ELSE 'N' END;
END is_finance_manager;
/

--------------------------------------------------------------------------------
-- Which employee is the Project Manager for a given project? Looks up
-- PROJECT_MANAGER (P_ID -> PROJECT_MANAGER_EMPID). If more than one row
-- exists for the same project, picks the earliest-assigned one
-- (CREATION_DATE ascending) as a deterministic tie-break — change the
-- ORDER BY below if a different rule is wanted.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_project_manager_empid(p_project_id IN NUMBER) RETURN NUMBER IS
  l_pm_empid NUMBER;
BEGIN
  IF p_project_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT project_manager_empid INTO l_pm_empid
  FROM (
    SELECT project_manager_empid
    FROM   project_manager
    WHERE  p_id = p_project_id
    ORDER BY creation_date ASC, sr_no ASC
  )
  WHERE ROWNUM = 1;

  RETURN l_pm_empid;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RETURN NULL;
END get_project_manager_empid;
/

--------------------------------------------------------------------------------
-- Allowed attachment types: pdf, jpg, jpeg, png, xlsx, xls, csv, rar.
-- Size limit (1MB) is enforced separately, in the upload handler.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION is_allowed_attachment(p_mime IN VARCHAR2) RETURN VARCHAR2 IS
BEGIN
  IF p_mime IS NULL THEN
    RETURN 'Y'; -- attachment is optional at draft stage
  END IF;
  RETURN CASE
    WHEN p_mime IN (
      'application/pdf',
      'image/jpeg', 'image/jpg', 'image/png',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', -- xlsx
      'application/vnd.ms-excel',                                          -- xls
      'text/csv',
      'application/x-rar-compressed', 'application/vnd.rar', 'application/x-rar'
    ) THEN 'Y'
    ELSE 'N'
  END;
END is_allowed_attachment;
/

--------------------------------------------------------------------------------
-- Given an expense + a caller's EMPID, which reviewer role (if any) can
-- they act as on THIS expense right now? NULL if they're not the assigned
-- reviewer at its current stage.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_reviewer_role(
  p_expense_id IN NUMBER,
  p_emp_id     IN NUMBER
) RETURN VARCHAR2 IS
  l_stage         VARCHAR2(20);
  l_manager_empid NUMBER;
BEGIN
  SELECT current_stage, manager_empid
  INTO   l_stage, l_manager_empid
  FROM   expenses
  WHERE  id = p_expense_id;

  IF l_stage = 'MANAGER' AND l_manager_empid = p_emp_id THEN
    RETURN 'PROJECT_MANAGER';
  ELSIF l_stage = 'FINANCE' AND is_finance_manager(p_emp_id) = 'Y' THEN
    RETURN 'FINANCE_MANAGER';
  ELSE
    RETURN NULL;
  END IF;
EXCEPTION
  WHEN NO_DATA_FOUND THEN RETURN NULL;
END get_reviewer_role;
/

--------------------------------------------------------------------------------
-- HMAC-SHA256, built on STANDARD_HASH.
--
-- DELIBERATELY NOT DBMS_CRYPTO. An app schema often has no execute
-- privilege on SYS.DBMS_CRYPTO and granting it requires a DBA. On the dev
-- schema that grant was absent, so both token functions below compiled
-- INVALID — and an ORDS PL/SQL handler that references an INVALID object is
-- refused before it runs, with ORDS returning a bare "403 Forbidden -
-- Access to the resource is prohibited" and no body. That reads as a
-- permissions problem and is not one; it cost most of a day to trace.
-- STANDARD_HASH is a SQL built-in available to every schema.
--
-- STANDARD_HASH only does plain SHA-256, so HMAC is constructed explicitly
-- per RFC 2104:
--
--     HMAC(K, m) = H( (K XOR opad) || H( (K XOR ipad) || m ) )
--
-- This is NOT the naive hash(secret || payload), which SHA-256's
-- length-extension property makes forgeable: an attacker holding one valid
-- token could produce a signature for a longer payload without the key.
--
-- STANDARD_HASH is a SQL function and cannot be called directly in a PL/SQL
-- expression, hence SELECT ... INTO ... FROM dual.
--
-- Verified against the standard test vector:
--   key='key', msg='The quick brown fox jumps over the lazy dog'
--   => f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hmac_sha256_hex(
  p_message IN VARCHAR2,
  p_key     IN VARCHAR2
) RETURN VARCHAR2 IS
  c_block CONSTANT PLS_INTEGER := 64;   -- SHA-256 block size in bytes
  l_key   RAW(256);
  l_klen  PLS_INTEGER;
  l_ipad  RAW(64);
  l_opad  RAW(64);
  l_inner RAW(32);
  l_outer RAW(32);
BEGIN
  l_key  := UTL_I18N.STRING_TO_RAW(p_key, 'AL32UTF8');
  l_klen := UTL_RAW.LENGTH(l_key);

  IF l_klen > c_block THEN
    SELECT STANDARD_HASH(l_key, 'SHA256') INTO l_key FROM dual;
    l_klen := UTL_RAW.LENGTH(l_key);
  END IF;

  IF l_klen < c_block THEN
    l_key := UTL_RAW.CONCAT(l_key, UTL_RAW.COPIES(HEXTORAW('00'), c_block - l_klen));
  END IF;

  l_ipad := UTL_RAW.BIT_XOR(l_key, UTL_RAW.COPIES(HEXTORAW('36'), c_block));
  l_opad := UTL_RAW.BIT_XOR(l_key, UTL_RAW.COPIES(HEXTORAW('5C'), c_block));

  SELECT STANDARD_HASH(
           UTL_RAW.CONCAT(l_ipad, UTL_I18N.STRING_TO_RAW(p_message, 'AL32UTF8')),
           'SHA256')
    INTO l_inner FROM dual;

  SELECT STANDARD_HASH(UTL_RAW.CONCAT(l_opad, l_inner), 'SHA256')
    INTO l_outer FROM dual;

  RETURN RAWTOHEX(l_outer);
END hmac_sha256_hex;
/

-- Fail the deployment rather than install a broken signer.
DECLARE
  c_expected CONSTANT VARCHAR2(64) :=
    'F7BC83F430538424B13298E6AA6FB143EF4D59A14946175997479DBC2D1A3CD8';
  l_actual VARCHAR2(64);
BEGIN
  l_actual := hmac_sha256_hex('The quick brown fox jumps over the lazy dog', 'key');
  IF UPPER(l_actual) != c_expected THEN
    RAISE_APPLICATION_ERROR(-20099,
      'HMAC-SHA256 self-test FAILED. Expected ' || c_expected ||
      ' but got ' || UPPER(l_actual) || '. Do not use these tokens.');
  END IF;
END;
/


--------------------------------------------------------------------------------
-- Signed session tokens (see PROD_1_schema.sql's APP_SECRETS table).
-- Token shape: "<emp_id>.<expiry_epoch_seconds>.<hmac_signature>".
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION generate_session_token(p_emp_id IN NUMBER) RETURN VARCHAR2 IS
  l_secret  VARCHAR2(200);
  l_expiry  NUMBER;
  l_payload VARCHAR2(100);
BEGIN
  SELECT secret_value INTO l_secret FROM app_secrets WHERE secret_name = 'SESSION_TOKEN_KEY';

  l_expiry  := ROUND((SYSDATE - DATE '1970-01-01') * 86400) + (12 * 3600); -- now + 12h
  l_payload := p_emp_id || '.' || l_expiry;

  RETURN l_payload || '.' || hmac_sha256_hex(l_payload, l_secret);
END generate_session_token;
/

CREATE OR REPLACE FUNCTION is_valid_session_token(
  p_emp_id IN NUMBER,
  p_token  IN VARCHAR2
) RETURN VARCHAR2 IS
  l_secret       VARCHAR2(200);
  l_tok_emp      VARCHAR2(50);
  l_tok_exp      VARCHAR2(50);
  l_tok_sig      VARCHAR2(200);
  l_expected_sig VARCHAR2(200);
  l_now          NUMBER;
  l_dot1         NUMBER;
  l_dot2         NUMBER;
BEGIN
  IF p_token IS NULL OR p_emp_id IS NULL THEN
    RETURN 'N';
  END IF;

  l_dot1 := INSTR(p_token, '.');
  l_dot2 := INSTR(p_token, '.', 1, 2);
  IF l_dot1 = 0 OR l_dot2 = 0 THEN
    RETURN 'N';
  END IF;

  l_tok_emp := SUBSTR(p_token, 1, l_dot1 - 1);
  l_tok_exp := SUBSTR(p_token, l_dot1 + 1, l_dot2 - l_dot1 - 1);
  l_tok_sig := SUBSTR(p_token, l_dot2 + 1);

  IF TO_NUMBER(l_tok_emp) != p_emp_id THEN
    RETURN 'N';
  END IF;

  l_now := ROUND((SYSDATE - DATE '1970-01-01') * 86400);
  IF TO_NUMBER(l_tok_exp) < l_now THEN
    RETURN 'N';
  END IF;

  SELECT secret_value INTO l_secret FROM app_secrets WHERE secret_name = 'SESSION_TOKEN_KEY';
  l_expected_sig := hmac_sha256_hex(l_tok_emp || '.' || l_tok_exp, l_secret);

  IF UPPER(l_expected_sig) = UPPER(l_tok_sig) THEN
    RETURN 'Y';
  ELSE
    RETURN 'N';
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    RETURN 'N';
END is_valid_session_token;
/

--------------------------------------------------------------------------------
-- Fetches an app-level OAuth Bearer token on the app's behalf, using the
-- client id/secret/token-URL stored server-side in APP_SECRETS (seeded in
-- PROD_2_ords_and_security_setup.sql, section 5.1) — never sent to any
-- client. Called only from inside POST /expenses/auth/login
-- (PROD_4_endpoints.sql), right after a real employee username/password
-- has been verified. This is what lets the app stop shipping
-- OAUTH_CLIENT_ID/OAUTH_CLIENT_SECRET entirely: instead of the app
-- fetching its own token with an embedded secret, the server fetches it
-- for the app and hands it back alongside the session token, in one
-- login response.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE get_oauth_access_token(
  p_access_token OUT VARCHAR2,
  p_expires_in   OUT NUMBER
) IS
  l_client_id     VARCHAR2(200);
  l_client_secret VARCHAR2(200);
  l_token_url     VARCHAR2(500);
  l_response      CLOB;
BEGIN
  SELECT secret_value INTO l_client_id     FROM app_secrets WHERE secret_name = 'OAUTH_CLIENT_ID';
  SELECT secret_value INTO l_client_secret FROM app_secrets WHERE secret_name = 'OAUTH_CLIENT_SECRET';
  SELECT secret_value INTO l_token_url     FROM app_secrets WHERE secret_name = 'OAUTH_TOKEN_URL';

  apex_web_service.g_request_headers.DELETE;
  apex_web_service.g_request_headers(1).name  := 'Content-Type';
  apex_web_service.g_request_headers(1).value := 'application/x-www-form-urlencoded';

  BEGIN
    l_response := apex_web_service.make_rest_request(
      p_url         => l_token_url,
      p_http_method => 'POST',
      p_username    => l_client_id,
      p_password    => l_client_secret,
      p_body        => 'grant_type=client_credentials'
    );
  EXCEPTION
    -- ORA-29273 ("HTTP request failed") is just a wrapper — the real
    -- cause (missing ACL grant, SSL/certificate problem, DNS failure,
    -- connection refused, etc.) is in UTL_HTTP's detailed error, which
    -- SQLERRM alone does NOT include. Surface that instead of the vague
    -- wrapper message.
    WHEN OTHERS THEN
      RAISE_APPLICATION_ERROR(-20052,
        'OAuth token request to ' || l_token_url || ' failed. ' ||
        UTL_HTTP.GET_DETAILED_SQLERRM || ' (top-level: ' || SQLERRM || ')');
  END;

  p_access_token := JSON_VALUE(l_response, '$.access_token');
  p_expires_in   := NVL(JSON_VALUE(l_response, '$.expires_in' RETURNING NUMBER), 3600);

  IF p_access_token IS NULL THEN
    RAISE_APPLICATION_ERROR(-20050,
      'OAuth token request did not return an access_token. Check OAUTH_CLIENT_ID/OAUTH_CLIENT_SECRET/OAUTH_TOKEN_URL in APP_SECRETS, and confirm the Network ACL grant for your own domain (PROD_2, section 6) is in place. Raw response: ' ||
      DBMS_LOB.SUBSTR(l_response, 500, 1));
  END IF;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RAISE_APPLICATION_ERROR(-20051,
      'OAuth client credentials are not configured yet — see PROD_2_ords_and_security_setup.sql, section 5.1.');
END get_oauth_access_token;
/

--------------------------------------------------------------------------------
-- Push notifications: escaping helper + the sender itself.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION json_escape_str(p_str IN VARCHAR2) RETURN VARCHAR2 IS
BEGIN
  IF p_str IS NULL THEN RETURN ''; END IF;
  RETURN REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(p_str,
    '\', '\\'), '"', '\"'), CHR(10), '\n'), CHR(13), ''), CHR(9), '\t');
END json_escape_str;
/

CREATE OR REPLACE PROCEDURE send_push_notification(
  p_emp_id      IN NUMBER,
  p_title       IN VARCHAR2,
  p_body        IN VARCHAR2,
  p_expense_id  IN NUMBER DEFAULT NULL
) IS
  PRAGMA AUTONOMOUS_TRANSACTION;
  l_payload  CLOB;
  l_response CLOB;
BEGIN
  FOR t IN (SELECT push_token FROM emp_push_tokens WHERE emp_id = p_emp_id) LOOP
    BEGIN
      l_payload := '{"to":"' || json_escape_str(t.push_token) ||
                   '","title":"' || json_escape_str(p_title) ||
                   '","body":"' || json_escape_str(p_body) || '"' ||
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
        p_body        => l_payload
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
-- Core approval-action logic, shared by the single-item and bulk
-- accept/revise/reject endpoints (PROD_4_endpoints.sql).
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE process_expense_action(
  p_expense_id  IN  NUMBER,
  p_emp_id      IN  NUMBER,
  p_action      IN  VARCHAR2,   -- 'ACCEPTED' | 'REVISED' | 'REJECTED'
  p_comment     IN  VARCHAR2,
  p_result_code OUT NUMBER,
  p_result_msg  OUT VARCHAR2
) IS
  l_status         VARCHAR2(30);
  l_role           VARCHAR2(30);
  l_emp_owner      NUMBER;
  l_manager_empid  NUMBER;
  l_finance_empid  NUMBER;
  l_emp_email      VARCHAR2(255);
  l_mgr_email      VARCHAR2(255);
  l_fin_email      VARCHAR2(255);
BEGIN
  BEGIN
    SELECT status, emp_id, manager_empid, finance_manager_empid
    INTO   l_status, l_emp_owner, l_manager_empid, l_finance_empid
    FROM   expenses
    WHERE  id = p_expense_id
    FOR UPDATE;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      p_result_code := 404;
      p_result_msg  := 'Expense ' || p_expense_id || ' not found';
      RETURN;
  END;

  IF l_status != 'SUBMITTED' THEN
    p_result_code := 409;
    p_result_msg  := 'Expense ' || p_expense_id || ' is not awaiting review (current status: ' || l_status || ')';
    RETURN;
  END IF;

  l_role := get_reviewer_role(p_expense_id, p_emp_id);
  IF l_role IS NULL THEN
    p_result_code := 403;
    p_result_msg  := 'You are not the assigned reviewer for expense ' || p_expense_id || ' at its current stage';
    RETURN;
  END IF;

  INSERT INTO expense_approvals (expense_id, approver_id, role, action, comments)
  VALUES (p_expense_id, p_emp_id, l_role, p_action, p_comment);

  IF p_action = 'ACCEPTED' THEN
    IF l_role = 'PROJECT_MANAGER' THEN
      UPDATE expenses SET current_stage = 'FINANCE' WHERE id = p_expense_id;

      send_push_notification(l_emp_owner, 'Approved by Manager',
        'Your expense #' || p_expense_id || ' was approved by your project manager — now with Finance.', p_expense_id);
      IF l_finance_empid IS NOT NULL THEN
        send_push_notification(l_finance_empid, 'Approval Needed',
          'An expense approved by its project manager is waiting for your review.', p_expense_id);
      END IF;

    ELSE -- FINANCE_MANAGER accepting = final approval
      UPDATE expenses SET status = 'APPROVED', current_stage = NULL WHERE id = p_expense_id;

      BEGIN
        SELECT company_email INTO l_emp_email FROM employeedetails WHERE empid = l_emp_owner;
        IF l_manager_empid IS NOT NULL THEN
          SELECT company_email INTO l_mgr_email FROM employeedetails WHERE empid = l_manager_empid;
        END IF;

        IF l_emp_email IS NOT NULL THEN
          APEX_MAIL.SEND(p_to => l_emp_email, p_from => l_emp_email,
            p_subj => 'Expense #' || p_expense_id || ' approved',
            p_body => 'Your expense has been fully approved by Finance.');
        END IF;
        IF l_mgr_email IS NOT NULL THEN
          APEX_MAIL.SEND(p_to => l_mgr_email, p_from => l_emp_email,
            p_subj => 'Expense #' || p_expense_id || ' approved',
            p_body => 'An expense you approved has now been fully approved by Finance.');
        END IF;
      EXCEPTION
        WHEN OTHERS THEN NULL;
      END;

      send_push_notification(l_emp_owner, 'Expense Approved',
        'Your expense #' || p_expense_id || ' was fully approved.', p_expense_id);
    END IF;

  ELSIF p_action = 'REVISED' THEN
    UPDATE expenses SET status = 'REVISION_REQUESTED' WHERE id = p_expense_id;

    BEGIN
      IF l_manager_empid IS NOT NULL THEN
        SELECT company_email INTO l_mgr_email FROM employeedetails WHERE empid = l_manager_empid;
      END IF;
      IF l_finance_empid IS NOT NULL THEN
        SELECT company_email INTO l_fin_email FROM employeedetails WHERE empid = l_finance_empid;
      END IF;

      IF l_mgr_email IS NOT NULL THEN
        APEX_MAIL.SEND(p_to => l_mgr_email, p_from => NVL(l_fin_email, l_mgr_email),
          p_subj => 'Expense #' || p_expense_id || ' sent back for revision',
          p_body => 'Comment: ' || NVL(p_comment, '(none)'));
      END IF;
      IF l_fin_email IS NOT NULL THEN
        APEX_MAIL.SEND(p_to => l_fin_email, p_from => l_fin_email,
          p_subj => 'Expense #' || p_expense_id || ' sent back for revision',
          p_body => 'Comment: ' || NVL(p_comment, '(none)'));
      END IF;
    EXCEPTION
      WHEN OTHERS THEN NULL;
    END;

    send_push_notification(l_emp_owner, 'Revision Needed',
      'Your expense #' || p_expense_id || ' needs changes before it can be approved.' ||
      CASE WHEN p_comment IS NOT NULL THEN ' Comment: ' || p_comment ELSE '' END,
      p_expense_id);

  ELSIF p_action = 'REJECTED' THEN
    UPDATE expenses SET status = 'REJECTED', current_stage = NULL WHERE id = p_expense_id;

    BEGIN
      IF l_manager_empid IS NOT NULL THEN
        SELECT company_email INTO l_mgr_email FROM employeedetails WHERE empid = l_manager_empid;
      END IF;
      IF l_finance_empid IS NOT NULL THEN
        SELECT company_email INTO l_fin_email FROM employeedetails WHERE empid = l_finance_empid;
      END IF;

      IF l_mgr_email IS NOT NULL THEN
        APEX_MAIL.SEND(p_to => l_mgr_email, p_from => NVL(l_fin_email, l_mgr_email),
          p_subj => 'Expense #' || p_expense_id || ' rejected',
          p_body => 'Comment: ' || NVL(p_comment, '(none)'));
      END IF;
      IF l_fin_email IS NOT NULL THEN
        APEX_MAIL.SEND(p_to => l_fin_email, p_from => l_fin_email,
          p_subj => 'Expense #' || p_expense_id || ' rejected',
          p_body => 'Comment: ' || NVL(p_comment, '(none)'));
      END IF;
    EXCEPTION
      WHEN OTHERS THEN NULL;
    END;

    send_push_notification(l_emp_owner, 'Expense Rejected',
      'Your expense #' || p_expense_id || ' was rejected.' ||
      CASE WHEN p_comment IS NOT NULL THEN ' Comment: ' || p_comment ELSE '' END,
      p_expense_id);
  END IF;

  p_result_code := 200;
  p_result_msg  := 'OK';
EXCEPTION
  WHEN OTHERS THEN
    p_result_code := 400;
    p_result_msg  := SQLERRM;
END process_expense_action;
/

COMMIT;
