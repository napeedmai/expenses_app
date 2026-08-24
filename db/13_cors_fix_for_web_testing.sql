--------------------------------------------------------------------------------
-- CORS fix — only needed for testing the app in a web browser (Expo's "w"
-- preview). Real phone/Expo Go usage never hits this, since CORS is a
-- browser-only security rule; native apps aren't subject to it at all.
--
-- Two separate places need the browser's origin (protocol + host + port)
-- allow-listed:
--   1. The OAuth client itself (blocks the /oauth/token request)
--   2. The 'expenses.employee' module (would block every /expenses/*
--      request once you get past step 1)
--
-- Listing a few common Expo web dev-server ports below, since the exact
-- port can shift between runs (8081/8082/8083 have all been seen already
-- in this session). Add more later the same way if a new port shows up in
-- a browser console CORS error.
--------------------------------------------------------------------------------

BEGIN
  OAUTH.UPDATE_CLIENT(
    p_name            => 'EXPENSE_APP_CLIENT',
    p_description     => NULL,
    p_origins_allowed => 'http://localhost:8081,http://localhost:8082,http://localhost:8083,http://localhost:19006',
    p_redirect_uri    => NULL,
    p_support_email   => NULL,
    p_suppor_uri      => NULL,
    p_privilege_names => NULL
  );
  COMMIT;
END;
/

BEGIN
  ORDS.SET_MODULE_ORIGINS_ALLOWED(
    p_module_name     => 'expenses.employee',
    p_origins_allowed => 'http://localhost:8081,http://localhost:8082,http://localhost:8083,http://localhost:19006'
  );
  COMMIT;
END;
/
