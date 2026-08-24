// Mobile Expense Upload App — API client
//
// Handles: holding the OAuth2 access token issued at login, and one
// function per backend endpoint we built in Phase 2. Every function takes
// empId as its first argument and sends it as the X-Emp-Id header,
// matching the identity model documented in 04_oauth2_setup_guide.md
// (Option A).
//
// NOTE: this app no longer fetches its own OAuth token with an embedded
// client secret. POST /expenses/auth/login now returns a short-lived
// access_token directly (the server fetches it on the app's behalf — see
// PROD_3_business_logic.sql's get_oauth_access_token) alongside the
// session_token. setAccessToken() below just holds whatever the login
// response gave us; there's nothing left in this file that knows a
// client secret.

import { Platform } from 'react-native';
import { API_BASE_URL } from '../config';

// Small pure-JS base64 encoder — used only for the Basic Auth header when
// requesting a token. Not relying on global btoa/Buffer, since availability
// of those varies across React Native/Expo versions and engines.
function base64Encode(str) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let output = '';
  let i = 0;
  while (i < str.length) {
    const c1 = str.charCodeAt(i++);
    const c2 = str.charCodeAt(i++);
    const c3 = str.charCodeAt(i++);
    const e1 = c1 >> 2;
    const e2 = ((c1 & 3) << 4) | (isNaN(c2) ? 0 : c2 >> 4);
    const e3 = isNaN(c2) ? 64 : ((c2 & 15) << 2) | (isNaN(c3) ? 0 : c3 >> 6);
    const e4 = isNaN(c3) ? 64 : c3 & 63;
    // e3/e4 === 64 means "no more real data, pad instead" — chars[64] is
    // out of range (chars only has indices 0-63) and was silently producing
    // the literal text "undefined" in the output. Must emit '=' here.
    output +=
      chars[e1] +
      chars[e2] +
      (e3 === 64 ? '=' : chars[e3]) +
      (e4 === 64 ? '=' : chars[e4]);
  }
  return output;
}

// Wraps fetch() with a hard timeout (AbortController), so a request that
// never gets a response from the server — instead of merely getting a
// clear error — doesn't just hang the "Saving..." spinner forever. This
// also means a "did it actually go through?" situation (the request may
// have reached the server and even succeeded there, but the response
// never made it back before the timeout fired) is now labeled clearly as
// a timeout rather than a generic failure, since that's the class of bug
// most likely behind requests occasionally failing with a non-standard
// status like 555 while the server had, in fact, already saved the data.
// Bumped up from 20s to 45s — real-world testing on slow/high-latency
// mobile connections (tunnel mode, weak signal, congested Wi-Fi) showed
// requests occasionally still in flight past 20s that would have succeeded
// given a bit more time, surfacing as a confusing "network issue" even
// though the server was perfectly reachable.
const DEFAULT_TIMEOUT_MS = 45000;

async function fetchWithTimeout(url, options = {}, timeoutMs = DEFAULT_TIMEOUT_MS) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } catch (e) {
    if (e.name === 'AbortError') {
      const err = new Error(
        'The request timed out waiting for a response. Your connection may be slow, or the server may be temporarily unavailable. If you were saving or submitting an expense, check My Expenses before retrying — it may have gone through even though this timed out.'
      );
      err.timeout = true;
      throw err;
    }
    throw e;
  } finally {
    clearTimeout(timer);
  }
}

// The signed, per-employee session token issued at login (see
// 43_secure_session_tokens.sql) — proves that whoever is calling with a
// given X-Emp-Id actually logged in as that employee, closing the gap
// where the header alone used to be trusted on its own. Held in memory
// here (not just in SessionContext's state) so every API call below can
// attach it automatically without every function needing a new parameter.
// SessionContext.js calls setSessionToken() right after login, and again
// on app startup when restoring a saved session from storage.
let currentSessionToken = null;

export function setSessionToken(token) {
  currentSessionToken = token || null;
}

// The OAuth access token returned directly by POST /expenses/auth/login
// (the server fetches it on the app's behalf — see PROD_3's
// get_oauth_access_token — so this app never holds a client secret).
// Same in-memory pattern as currentSessionToken above: SessionContext.js
// calls setAccessToken() right after login, and again on app startup
// when restoring a saved session.
let currentAccessToken = null;
let currentAccessTokenExpiresAt = 0; // epoch ms, informational only —
// there's no silent client-side refresh anymore (that would need a
// secret again). When this expires, requests will start getting 401s and
// the app's existing "session expired, please log in again" handling
// takes over, same as it already does for an expired session_token.

// p_expiresAtMs is an ABSOLUTE epoch-ms timestamp, not a "seconds from
// now" duration — this matters because this function is called both right
// after a fresh login (where we compute that absolute timestamp from the
// server's expires_in) AND when restoring a saved session after an app
// restart (where using a fresh "expires_in seconds from now" instead of
// the original absolute expiry would make an already-stale token look
// brand new again every time the app restarts).
export function setAccessToken(token, p_expiresAtMs) {
  currentAccessToken = token || null;
  currentAccessTokenExpiresAt = token ? (p_expiresAtMs || 0) : 0;
}

// Lets a caller (SessionContext.js) check — WITHOUT making a network call
// — whether the access token has already passed its known expiry. Used to
// catch the "left the app in the background for a while, came back, and
// the very first tap threw a confusing raw error" case: instead of firing
// a request that's doomed to fail, the app can proactively sign the
// employee out with a clear message the moment it notices the token is
// stale (see the AppState listener in SessionContext.js).
export function isAccessTokenExpired() {
  return !currentAccessToken || Date.now() >= currentAccessTokenExpiresAt;
}

// Fired from handle() below whenever a request comes back 401 (session or
// access token rejected server-side) — this is the fallback path for
// expiry that happens WHILE a screen is actively making calls, rather
// than being caught proactively on app-resume. SessionContext.js registers
// itself here so it can log the employee out and show a clear message,
// instead of every individual screen having to special-case 401 itself.
let onAuthFailure = null;

export function setOnAuthFailure(callback) {
  onAuthFailure = callback;
}

async function authHeaders(empId, extra = {}) {
  return {
    Authorization: `Bearer ${currentAccessToken || ''}`,
    'X-Emp-Id': String(empId),
    // Proves this X-Emp-Id is really who logged in — see currentSessionToken
    // above. Sent as an empty string (rather than omitted) if somehow
    // missing, so the backend's check fails closed with a clear "log in
    // again" response instead of silently skipping the check.
    'X-Session-Token': currentSessionToken || '',
    ...extra,
  };
}

async function parseJsonSafe(res) {
  const text = await res.text();
  try {
    return text ? JSON.parse(text) : {};
  } catch (e) {
    return { raw: text };
  }
}

// p_skipAuthFailureHook is true only for the login call itself (see
// login() below) — a 401 there just means "wrong password," not "your
// existing session expired," so it must NOT trigger the global
// log-out-and-show-a-message flow the way a 401 on any OTHER endpoint
// does.
async function handle(res, p_skipAuthFailureHook = false) {
  const data = await parseJsonSafe(res);
  if (!res.ok) {
    if (res.status === 401 && !p_skipAuthFailureHook && onAuthFailure) {
      onAuthFailure();
    }
    const message = data && data.error ? data.error : `Request failed with status ${res.status}`;
    const err = new Error(message);
    err.status = res.status;
    err.body = data;
    throw err;
  }
  return data;
}

// ---- Login (APEX workspace credentials) ----
//
// This is the ONE endpoint reachable with no OAuth Bearer token at all.
//
// It stays reachable only because no ORDS privilege pattern matches it.
// ORDS applies EVERY privilege whose pattern matches a URI and offers no
// way to exclude one path from a wildcard — so a pattern like
// /expenses/* would silently capture this endpoint and make login
// impossible by construction: you would need a Bearer token to log in,
// and logging in is how you obtain one. The privileges must therefore
// list each protected endpoint explicitly (/expenses/:id,
// /expenses/draft, /expenses/mine, ...) and never use a bare
// /expenses/* wildcard. Dev regressed to a wildcard once and login
// returned an unexplained 401 sign-in page until it was replaced.
//
// The backend decodes this Basic header itself and validates it with
// APEX_UTIL.IS_LOGIN_PASSWORD_VALID — ORDS does NOT do that check for
// us. (An earlier design assumed ORDS would populate :current_user from
// Basic Auth; it does not, and that bind is always NULL here.) On
// success the backend maps the account to an employee record and
// returns the role flags, a signed session_token, and an OAuth
// access_token fetched server-side — see SessionContext.js and
// LoginScreen.js for where those get captured.
//
// NOTE ON CASING: APEX_UTIL.IS_LOGIN_PASSWORD_VALID is case-SENSITIVE on
// the username. An earlier comment here claimed APEX usernames were always
// lowercase and this function forced .toLowerCase() to match. That was
// wrong — the accounts are stored UPPERCASE (e.g. NAME@TRINAMIX.COM), so
// lowercasing guaranteed failure: Postman worked (it sent the address as
// typed) while the app always returned "Invalid email or password".
//
// The backend now resolves the account's real stored username
// case-insensitively before validating (FIX_login_username_case.sql), so
// any casing works. We send the address as typed, merely trimmed — no
// client-side casing assumption, because that assumption is what broke.

export async function login(username, password) {
  const basicAuth = base64Encode(`${username.trim()}:${password}`);
  const res = await fetchWithTimeout(`${API_BASE_URL}/expenses/auth/login`, {
    method: 'POST',
    headers: { Authorization: `Basic ${basicAuth}` },
  });
  return handle(res, /* p_skipAuthFailureHook */ true);
}

// ---- Currency ----
//
// Expenses are entered in whatever currency the receipt is in and converted
// to USD for reporting. The rate is chosen by the month the expense PERIOD
// starts in (from_date), not the bill date — a May bill for April travel
// uses April's rate. See 45_currency_conversion.sql.
//
// The conversion shown here and the conversion stored on save both come from
// the same server-side get_exchange_rate() function, so the preview can
// never disagree with what actually gets saved.

export async function listCurrencies(empId) {
  const res = await fetchWithTimeout(`${API_BASE_URL}/expenses/currencies`, {
    headers: await authHeaders(empId),
  });
  return handle(res);
}

// on_date should be the expense's from_date in MM/DD/YYYY. Passing amount is
// optional — when given, the response includes amount_usd so the screen
// doesn't have to do the multiplication itself and risk drifting from the
// server's rounding.
export async function getExchangeRate(empId, currency, onDate, amount) {
  const params = new URLSearchParams({ currency });
  if (onDate) params.append('on_date', onDate);
  if (amount !== undefined && amount !== null && amount !== '') {
    params.append('amount', String(amount));
  }

  const res = await fetchWithTimeout(`${API_BASE_URL}/expenses/exchange-rate?${params.toString()}`, {
    headers: await authHeaders(empId),
  });
  return handle(res);
}

// ---- Employee-facing endpoints (Phase 2A) ----

// Checks that an EMPID actually exists in EMPLOYEEDETAILS, and returns their
// display name. Used by LoginScreen instead of listMine() — listMine() was
// the old (buggy) validation check, since an empty expense list is still a
// "successful" response even for a made-up EMPID. This one 404s properly.
export async function whoami(empId) {
  const res = await fetchWithTimeout(`${API_BASE_URL}/expenses/whoami`, {
    headers: await authHeaders(empId),
  });
  return handle(res);
}

// NOTE: /expenses/mine is an ORDS auto-paginated collection feed — with no
// limit specified, ORDS defaults to returning only the first 25 rows
// (newest first), silently hiding anything older once an employee has
// more than 25 expenses total. ?limit=1000 asks for effectively "all of
// them" instead of relying on the default page size. If any employee ever
// exceeds 1000 expenses, this would need real pagination (following
// hasMore/offset) instead of just a bigger number.
export async function listMine(empId) {
  const res = await fetchWithTimeout(`${API_BASE_URL}/expenses/mine?limit=1000`, {
    headers: await authHeaders(empId),
  });
  return handle(res);
}

// Returns the active projects (id + real name) this employee is currently
// allocated to — joins PROJECT_ALLOCATION_WB to PROJECTMASTER server-side —
// so the Add/Edit screen can offer a real dropdown instead of a free-typed
// number.
export async function listMyProjects(empId) {
  const res = await fetchWithTimeout(`${API_BASE_URL}/expenses/my-projects`, {
    headers: await authHeaders(empId),
  });
  return handle(res);
}

export async function getExpense(empId, id) {
  const res = await fetchWithTimeout(`${API_BASE_URL}/expenses/${id}`, {
    headers: await authHeaders(empId),
  });
  return handle(res);
}

export async function createDraft(empId, expense) {
  const res = await fetchWithTimeout(`${API_BASE_URL}/expenses/draft`, {
    method: 'POST',
    headers: await authHeaders(empId, { 'Content-Type': 'application/json' }),
    body: JSON.stringify(expense),
  });
  return handle(res);
}

export async function updateExpense(empId, id, expense) {
  const res = await fetchWithTimeout(`${API_BASE_URL}/expenses/${id}`, {
    method: 'PUT',
    headers: await authHeaders(empId, { 'Content-Type': 'application/json' }),
    body: JSON.stringify(expense),
  });
  return handle(res);
}

export async function deleteExpense(empId, id) {
  const res = await fetchWithTimeout(`${API_BASE_URL}/expenses/${id}`, {
    method: 'DELETE',
    headers: await authHeaders(empId),
  });
  // 204 No Content has no body
  if (res.status === 204) return {};
  return handle(res);
}

export async function submitExpense(empId, id) {
  const res = await fetchWithTimeout(`${API_BASE_URL}/expenses/${id}/submit`, {
    method: 'POST',
    headers: await authHeaders(empId),
  });
  return handle(res);
}

// Uploads a file the user picked (via expo-document-picker) to
// POST /expenses/{id}/attachment as multipart/form-data.
// `file` is expected to look like { uri, name, mimeType } — exactly what
// expo-document-picker's result gives you.
export async function uploadAttachment(empId, id, file) {
  const formData = new FormData();

  if (Platform.OS === 'web') {
    // React Native's FormData accepts a plain {uri, name, type} object and
    // resolves the file itself. The browser's FormData does NOT — it needs a
    // real Blob/File, and silently serialises that object to the string
    // "[object Object]" instead. The upload then "succeeds" with a useless
    // body, which is why attaching a file did nothing on web with no error.
    //
    // expo-document-picker gives us the actual File on web via .file; fall
    // back to fetching the blob: URI if a future version stops doing that.
    const blob = file.file || (await (await fetch(file.uri)).blob());
    formData.append('file', blob, file.name);
  } else {
    formData.append('file', {
      uri: file.uri,
      name: file.name,
      type: file.mimeType || 'application/octet-stream',
    });
  }

  const res = await fetchWithTimeout(`${API_BASE_URL}/expenses/${id}/attachment`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${currentAccessToken || ''}`,
      'X-Emp-Id': String(empId),
      'X-Session-Token': currentSessionToken || '',
      // Deliberately NOT setting Content-Type here — fetch/FormData sets
      // the correct multipart boundary automatically, same lesson learned
      // from the Postman testing earlier (manually setting it breaks it).
    },
    body: formData,
  });
  return handle(res);
}

// Returns the URL + headers needed to download an attachment
// (GET /expenses/{id}/attachment). Used with expo-file-system's
// downloadAsync, which supports passing custom headers directly, rather
// than fetch()+blob() — simpler for saving straight to a local file for
// previewing.
export function getAttachmentUrl(id) {
  return `${API_BASE_URL}/expenses/${id}/attachment`;
}

export async function getAttachmentDownloadHeaders(empId) {
  return authHeaders(empId);
}

// ---- Bills within a claim ----
//
// An expense is a CLAIM: who, which project, what it was for, and its status
// in the approval workflow. The BILLS live underneath it, one row each, with
// their own dates, currency, amount and receipt — see MULTI_BILL_PLAN.md and
// db/64..66.
//
// The claim's amount_usd is the SUM of its bills, maintained server-side by
// recalc_claim_totals. The app never computes it: two places deciding what a
// claim is worth is how they end up disagreeing.
//
// Conversion rate and USD amount are likewise NEVER sent from here. The server
// derives them from the currency, the amount and the bill's own from_date. A
// client-supplied rate would be a client-supplied reimbursement figure. Fields
// like `exchange_rate` in a response are read-only.

export async function listItems(empId, expenseId) {
  const res = await fetchWithTimeout(`${API_BASE_URL}/expenses/${expenseId}/items`, {
    headers: await authHeaders(empId),
  });
  return handle(res);
}

// `bill` takes ISO dates (YYYY-MM-DD) — the item endpoints expect ISO, unlike
// the older claim endpoints which use MM/DD/YYYY. Deliberate: ISO sorts and
// parses unambiguously, and the mismatch is contained to this one function
// rather than leaking into the screens. Use isoFromMDY below if you have the
// app's display format.
//
// Everything except bill_no is required:
//   { bill_no?, bill_date, type, description,
//     from_date, to_date, currency, amount }
export async function addItem(empId, expenseId, bill) {
  const res = await fetchWithTimeout(`${API_BASE_URL}/expenses/${expenseId}/items`, {
    method: 'POST',
    headers: await authHeaders(empId, { 'Content-Type': 'application/json' }),
    body: JSON.stringify(bill),
  });
  return handle(res);
}

// Send only what changed — an omitted field is left as-is server-side. The
// rate and USD amount are recomputed from the stored row afterwards, so
// changing the currency, the amount or from_date all reprice correctly.
export async function updateItem(empId, expenseId, itemId, changes) {
  const res = await fetchWithTimeout(
    `${API_BASE_URL}/expenses/${expenseId}/items/${itemId}`,
    {
      method: 'PUT',
      headers: await authHeaders(empId, { 'Content-Type': 'application/json' }),
      body: JSON.stringify(changes),
    }
  );
  return handle(res);
}

export async function deleteItem(empId, expenseId, itemId) {
  const res = await fetchWithTimeout(
    `${API_BASE_URL}/expenses/${expenseId}/items/${itemId}`,
    { method: 'DELETE', headers: await authHeaders(empId) }
  );
  if (res.status === 204) return {};
  return handle(res);
}

// Same two-step as a brand-new claim has always used: save the row, then
// upload against the id it returns. That is what makes "attach the receipt
// before saving" work from the user's point of view — the file is held in
// screen state and posted the moment the bill exists.
export async function uploadItemAttachment(empId, expenseId, itemId, file) {
  const formData = new FormData();

  if (Platform.OS === 'web') {
    // See uploadAttachment above: browser FormData needs a real Blob, and
    // silently serialises a {uri,name,type} object to "[object Object]".
    const blob = file.file || (await (await fetch(file.uri)).blob());
    formData.append('file', blob, file.name);
  } else {
    formData.append('file', {
      uri: file.uri,
      name: file.name,
      type: file.mimeType || 'application/octet-stream',
    });
  }

  const res = await fetchWithTimeout(
    `${API_BASE_URL}/expenses/${expenseId}/items/${itemId}/attachment`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${currentAccessToken || ''}`,
        'X-Emp-Id': String(empId),
        'X-Session-Token': currentSessionToken || '',
        'X-File-Name': file.name,
        // Content-Type is set by fetch/FormData with the right multipart
        // boundary. Setting it by hand breaks the upload.
      },
      body: formData,
    }
  );
  return handle(res);
}

export function getItemAttachmentUrl(expenseId, itemId) {
  return `${API_BASE_URL}/expenses/${expenseId}/items/${itemId}/attachment`;
}

// The app shows and stores dates as MM/DD/YYYY (see src/components/DateField.js)
// while the item endpoints take ISO. One conversion, in one place, rather than
// scattered .split('/') calls in the screens.
export function isoFromMDY(mdy) {
  if (!mdy) return null;
  const parts = String(mdy).split('/');
  if (parts.length !== 3) return null;
  const [mm, dd, yyyy] = parts;
  return `${yyyy}-${mm.padStart(2, '0')}-${dd.padStart(2, '0')}`;
}

export function mdyFromISO(iso) {
  if (!iso) return '';
  const parts = String(iso).slice(0, 10).split('-');
  if (parts.length !== 3) return '';
  const [yyyy, mm, dd] = parts;
  return `${mm}/${dd}/${yyyy}`;
}

// Registers (or updates) this device's Expo push token for empId, so the
// backend knows where to deliver real phone notifications — see
// src/pushNotifications.js for where this gets called from.
export async function registerPushToken(empId, token) {
  const res = await fetchWithTimeout(`${API_BASE_URL}/expenses/push-token`, {
    method: 'POST',
    headers: await authHeaders(empId, { 'Content-Type': 'application/json' }),
    body: JSON.stringify({ push_token: token }),
  });
  return handle(res);
}

// ---- Reviewer-facing endpoints (Phase 2B — Reporting Manager / Finance Manager) ----

// Returns whatever expenses are waiting on THIS empId to review — the
// backend figures out whether that means "as reporting manager" or "as
// finance manager" (or nothing, if this empId isn't a reviewer at all).
// Same pagination note as listMine() above — this is also an
// auto-paginated collection feed.
export async function listPending(empId) {
  const res = await fetchWithTimeout(`${API_BASE_URL}/expenses/pending?limit=1000`, {
    headers: await authHeaders(empId),
  });
  return handle(res);
}

async function reviewAction(empId, id, action, comment) {
  const res = await fetchWithTimeout(`${API_BASE_URL}/expenses/${id}/${action}`, {
    method: 'POST',
    headers: await authHeaders(empId, { 'Content-Type': 'application/json' }),
    body: JSON.stringify({ comment: comment || null }),
  });
  return handle(res);
}

export const acceptExpense = (empId, id, comment) => reviewAction(empId, id, 'accept', comment);
export const reviseExpense = (empId, id, comment) => reviewAction(empId, id, 'revise', comment);
export const rejectExpense = (empId, id, comment) => reviewAction(empId, id, 'reject', comment);

// Bulk actions — one comment applies to every id in the batch. The backend
// processes each id independently (one bad id doesn't block the rest) and
// returns a per-item result: { results: [ { id, status_code, message }, ... ] }
async function bulkReviewAction(empId, action, ids, comment) {
  const res = await fetchWithTimeout(`${API_BASE_URL}/expenses/bulk-${action}`, {
    method: 'POST',
    headers: await authHeaders(empId, { 'Content-Type': 'application/json' }),
    body: JSON.stringify({ ids, comment: comment || null }),
  });
  return handle(res);
}

export const bulkAccept = (empId, ids, comment) => bulkReviewAction(empId, 'accept', ids, comment);
export const bulkRevise = (empId, ids, comment) => bulkReviewAction(empId, 'revise', ids, comment);
export const bulkReject = (empId, ids, comment) => bulkReviewAction(empId, 'reject', ids, comment);