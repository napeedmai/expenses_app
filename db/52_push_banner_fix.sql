--------------------------------------------------------------------------------
-- 52_push_banner_fix.sql
--
-- Run as the application schema, on every environment. Idempotent.
--
-- SYMPTOM
-- -------
-- The expense appears in the app's own notification list, but the phone never
-- shows a notification banner.
--
-- That symptom means delivery is FINE and presentation is broken. Three
-- separate things had to be wrong at once for a banner to appear, and two of
-- them were:
--
--   1. (app)    Notifications.setNotificationHandler used shouldShowAlert,
--               which expo-notifications ignores from SDK 53 onward. It was
--               split into shouldShowBanner and shouldShowList. A handler
--               still using the old key effectively answers "show nothing".
--               Fixed in src/pushNotifications.js.
--
--   2. (app)    The Android channel was created with AndroidImportance.DEFAULT.
--               On Android 8+ the CHANNEL decides how intrusive a notification
--               is -- DEFAULT means "drawer only, no banner, no sound". Also
--               fixed in src/pushNotifications.js, using a NEW channel name
--               because a channel's importance is frozen when it is first
--               created and cannot be raised afterwards.
--
--   3. (here)   The push payload named no channel, no sound and no priority.
--               This script adds them.
--
-- All three must be in place. Fixing only this script changes nothing until a
-- new app build ships with the other two.
--
-- Section 3 adds a diagnostic procedure, because the production one
-- deliberately swallows every error -- a failed notification must never roll
-- back an approval -- which also means it can never tell you why it failed.
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- 0. Are you on the right schema?
--
-- This script needs EMP_PUSH_TOKENS and JSON_ESCAPE_STR, both created by the
-- main deployment. Not every environment has them: the push feature was only
-- ever deployed to the schema the app actually talks to.
--
-- Without this check the failure is a page of ORA-00942 and PLS-00201 errors
-- naming the table, the function and a loop variable -- three symptoms of one
-- cause, none of which say "wrong schema".
--------------------------------------------------------------------------------
DECLARE
  l_tab NUMBER;
  l_fn  NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_tab FROM user_tables  WHERE table_name  = 'EMP_PUSH_TOKENS';
  SELECT COUNT(*) INTO l_fn  FROM user_objects WHERE object_name = 'JSON_ESCAPE_STR';

  IF l_tab = 0 OR l_fn = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'Wrong schema, or push was never deployed here. Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
      || '. Missing: '
      || CASE WHEN l_tab = 0 THEN 'EMP_PUSH_TOKENS ' END
      || CASE WHEN l_fn  = 0 THEN 'JSON_ESCAPE_STR ' END
      || '-- connect to the schema the app uses (the one in API_BASE_URL), '
      || 'or run MASTER_DEPLOY.sql here first.');
  END IF;

  DBMS_OUTPUT.PUT_LINE('Prerequisites present on '
    || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || '. Proceeding.');
END;
/


--------------------------------------------------------------------------------
-- 1. Before: is there anything to deliver to?
--
--    No row here means the device never registered, and no amount of payload
--    fixing will help. Registration happens on login, and only in a real build
--    -- Expo Go cannot obtain a push token at all.
--------------------------------------------------------------------------------
SELECT emp_id,
       COUNT(*)                                    AS devices,
       MAX(updated_at)                             AS last_registered,
       MAX(SUBSTR(push_token, 1, 24)) || '...'     AS sample_token
FROM   emp_push_tokens
GROUP  BY emp_id
ORDER  BY emp_id;


--------------------------------------------------------------------------------
-- 2. The production sender, with channel, sound and priority.
--
--    Unchanged from PROD_3 apart from the payload: still autonomous, still
--    silent on failure. A push that fails must never roll back the approval
--    that triggered it.
--------------------------------------------------------------------------------
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
      -- priority 'high'            -> FCM delivers now rather than batching
      --                               until the device next wakes.
      -- channelId 'expense-updates'-> must match the channel created in
      --                               src/pushNotifications.js. Android takes
      --                               the importance, and therefore whether a
      --                               banner appears at all, from the channel.
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
-- 3. Diagnostic version -- prints everything instead of swallowing it.
--
--    Use this, never the production one, when push "does not work". It shows
--    the exact payload, the HTTP status and Expo's own reply, which names the
--    problem directly.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE test_push_notification(p_emp_id IN NUMBER) IS
  l_payload  CLOB;
  l_response CLOB;
  l_count    NUMBER := 0;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Testing push for EMPID ' || p_emp_id);

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
        p_body        => l_payload
      );

      DBMS_OUTPUT.PUT_LINE('  HTTP status : ' || apex_web_service.g_status_code);
      DBMS_OUTPUT.PUT_LINE('  Expo says   : ' || SUBSTR(l_response, 1, 900));
      DBMS_OUTPUT.PUT_LINE(' ');
      DBMS_OUTPUT.PUT_LINE('  Reading the reply:');
      DBMS_OUTPUT.PUT_LINE('    "status":"ok"          -> Expo accepted it. If the phone still');
      DBMS_OUTPUT.PUT_LINE('                              shows nothing, the problem is on the');
      DBMS_OUTPUT.PUT_LINE('                              device: notifications disabled for the');
      DBMS_OUTPUT.PUT_LINE('                              app, battery saver, or an app build that');
      DBMS_OUTPUT.PUT_LINE('                              predates the channel fix.');
      DBMS_OUTPUT.PUT_LINE('    "DeviceNotRegistered"  -> the app was uninstalled or the token is');
      DBMS_OUTPUT.PUT_LINE('                              stale. Delete the row and log in again.');
      DBMS_OUTPUT.PUT_LINE('    "InvalidCredentials"   -> the token belongs to a different Expo');
      DBMS_OUTPUT.PUT_LINE('                              project than the one that built the app.');

    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('  FAILED: ' || SQLERRM);
        IF SQLCODE = -24247 THEN
          DBMS_OUTPUT.PUT_LINE('  ORA-24247 = no network ACL for exp.host.');
          DBMS_OUTPUT.PUT_LINE('  A DBA must grant it -- and to the APEX ENGINE schema, not just');
          DBMS_OUTPUT.PUT_LINE('  this one, because APEX_WEB_SERVICE runs with its owner''s');
          DBMS_OUTPUT.PUT_LINE('  privileges. See PROD_2b section 3 and DEPLOYMENT.md 9.2b.');
        END IF;
    END;
  END LOOP;

  IF l_count = 0 THEN
    DBMS_OUTPUT.PUT_LINE('  NO DEVICES REGISTERED for this employee.');
    DBMS_OUTPUT.PUT_LINE('  Nothing was sent, and nothing could have been.');
    DBMS_OUTPUT.PUT_LINE('  Registration happens at login, and only in a real build --');
    DBMS_OUTPUT.PUT_LINE('  Expo Go cannot obtain a push token at all. Check that the phone');
    DBMS_OUTPUT.PUT_LINE('  is running an EAS build and that notification permission was');
    DBMS_OUTPUT.PUT_LINE('  granted, then log out and back in.');
  END IF;
END test_push_notification;
/


--------------------------------------------------------------------------------
-- 4. Run it. SET SERVEROUTPUT ON first, then use your own EMPID.
--
--    Hold the phone while this runs.
--------------------------------------------------------------------------------
-- SET SERVEROUTPUT ON
-- BEGIN test_push_notification(3725); END;
-- /


--------------------------------------------------------------------------------
-- 5. Confirm both procedures compiled.
--------------------------------------------------------------------------------
SELECT object_name, object_type, status
FROM   user_objects
WHERE  object_name IN ('SEND_PUSH_NOTIFICATION', 'TEST_PUSH_NOTIFICATION')
ORDER  BY object_name;


--------------------------------------------------------------------------------
-- WHAT STILL HAS TO HAPPEN ON THE APP SIDE
--
-- This script alone changes nothing visible. The channel named in the payload
-- only exists once a build containing the src/pushNotifications.js fix has been
-- installed:
--
--   eas build --profile preview --platform android
--
-- Install it, log in (which re-registers the device and creates the new
-- channel), then run section 4.
--
-- Reinstalling matters. Android freezes a channel's importance when it is
-- first created, so a phone that already has the old low-importance channel
-- keeps it. The fix uses a new channel name to sidestep exactly this, but a
-- device still running the OLD build will not have that channel at all and
-- will fall back to the default one -- silently.
--------------------------------------------------------------------------------
