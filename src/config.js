// Mobile Expense Upload App — config
//
// No OAuth client id/secret here anymore — the app no longer holds them.
// Logging in (POST /expenses/auth/login) now returns BOTH the session
// token and a short-lived OAuth access token in one response; the server
// fetches that access token on the app's behalf using credentials it
// keeps to itself (see PROD_2_ords_and_security_setup.sql section 5.1 and
// PROD_3_business_logic.sql's get_oauth_access_token). This closes the gap
// where a client secret used to be extractable from the installed app
// package.
 
export const API_BASE_URL = 'https://karyasiddhitest.trinamix.com/ords/repo';