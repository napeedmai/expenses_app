# Expense App — Handover & Deployment Guide

Everything needed to take this project over: what it is, how it is built,
how to deploy it somewhere new, and what to check before trusting it.

Two files are the deliverable. This one, and `db/MASTER_DEPLOY.sql`, which
is the entire backend in one runnable script.

**Read [§12 Fault dictionary](#12-fault-dictionary) before debugging
anything.** Almost every failure in this stack reports a cause that is not
the real one — a missing PL/SQL object arrives as an HTTP 403, a wrong APEX
workspace arrives as "invalid password". That section is the translation
table, and it is the single most time-saving part of this document.

---

## Contents

**Understand it**

1. [What the system does](#1-what-the-system-does)
2. [Repository tour](#2-repository-tour)
3. [Architecture and the life of a request](#3-architecture-and-the-life-of-a-request)
4. [Data model](#4-data-model)
5. [Identity, sessions and authorisation](#5-identity-sessions-and-authorisation)
6. [Business rules](#6-business-rules)
7. [API reference](#7-api-reference)

**Deploy it**

8. [Prerequisites and values to collect](#8-prerequisites-and-values-to-collect)
9. [Database deployment](#9-database-deployment)
10. [The app](#10-the-app)
11. [Verification](#11-verification)

**Run it**

12. [Fault dictionary](#12-fault-dictionary)
13. [Design constraints — do not "simplify" these](#13-design-constraints--do-not-simplify-these)
14. [How to make common changes](#14-how-to-make-common-changes)
15. [Known limitations and open items](#15-known-limitations-and-open-items)
16. [Handover checklist](#16-handover-checklist)

---

# Understand it

## 1. What the system does

Employees submit expense claims from a phone (or a browser); two people
approve them in sequence.

```
Employee                Project Manager            Finance Manager
   │                          │                          │
   ├─ create DRAFT            │                          │
   ├─ attach receipt          │                          │
   ├─ submit ────────────> SUBMITTED                     │
   │                     stage=MANAGER                   │
   │                          ├─ accept ──────────> stage=FINANCE
   │                          ├─ revise ─────┐            ├─ accept ──> APPROVED
   │                          └─ reject ─────┼──> REJECTED│
   │                                         │            ├─ revise ──┐
   │  <── REVISION_REQUESTED ────────────────┴────────────────────────┘
   └─ edit and resubmit
```

Everything is entered in the currency on the receipt and converted to USD
at save time, so a dashboard can add up expenses from different countries.

Three roles, decided per expense rather than per user:

| Role | Who | How it is decided |
|---|---|---|
| Employee | everyone | any authenticated user, acting on their own rows |
| Project Manager | the manager of the expense's project | `PROJECT_MANAGER` table, resolved and stamped onto the row at submit time |
| Finance Manager | one person | `is_finance_manager()` — currently a hardcoded `EMPID`, see [§15](#15-known-limitations-and-open-items) |

The same person can be all three on different expenses. `get_reviewer_role`
answers "may *this* employee act on *this* expense at *its current* stage",
and returns NULL when the answer is no.

## 2. Repository tour

```
expense-app/
├── DEPLOYMENT.md            this file
├── db/                      the entire backend
│   ├── MASTER_DEPLOY.sql    all 8 deployment scripts concatenated — run this
│   ├── HEALTH_CHECK.sql     read-only PASS/FAIL check — run after deploying
│   ├── README.md            what each script is, and what to run separately
│   ├── PROD_1..PROD_4       schema / ORDS setup / business logic / endpoints
│   ├── PROD_2b_*.sql        OAuth client + network ACL — run separately, needs a DBA
│   ├── 45,46,48,49_*.sql    the currency feature (included in MASTER_DEPLOY)
│   ├── 47,50,51,52,53_*.sql remediation for already-deployed environments
│   └── 13_cors_*.sql        only if serving from a browser
├── App.js                   providers, and the login-vs-app switch
├── index.js                 Expo entry point
├── app.json                 Expo config — package name, icons, web baseUrl
├── eas.json                 native build profiles
└── src/
    ├── config.js            API_BASE_URL — the ONLY environment-specific value
    ├── SessionContext.js    who is logged in; expiry handling
    ├── ThemeContext.js      light/dark
    ├── theme.js             colours, status labels, icons
    ├── api/client.js        one function per endpoint; token handling
    ├── pushNotifications.js device registration for Expo push
    ├── navigation/MainTabs.js  bottom tabs; Approvals tab is role-gated
    ├── components/
    │   ├── DateField.js     native picker on device, <input type=date> on web
    │   └── PickerField.js   dropdown used for project, type, currency
    ├── constants/expenseTypes.js  the expense-type list (client-side)
    ├── utils/alert.js       Alert.alert on native, window.confirm on web
    ├── utils/openAttachment.js  download + open a receipt, per platform
    └── screens/
        ├── LoginScreen.js
        ├── HomeScreen.js            dashboard, monthly totals in USD
        ├── ExpenseListScreen.js     My Expenses, with filters
        ├── AddEditExpenseScreen.js  the big one — create/edit/submit/attach
        ├── PendingApprovalsScreen.js  review queue, bulk actions
        ├── ReviewExpenseScreen.js   single-expense review
        └── SettingsScreen.js        theme, logout
```

Source files carry long comments explaining *why* the non-obvious code is
shaped the way it is. They are not noise — most of them record a bug that
took a day to find. Read them before changing the code they sit on.

> **Not in the public repo.** `.gitignore` excludes `deploy-web.ps1`,
> `DEPLOY_WEB_GITHUB_PAGES.md`, `AGENTS.md`, `CLAUDE.md` and `.claude/`.
> Anyone cloning gets the app and `db/` but not the web-deploy script — the
> commands are inlined in [§10.4](#104-web-build-and-github-pages) so it is
> not needed.

## 3. Architecture and the life of a request

```
Expo app ──HTTPS──> ORDS ──> PL/SQL handler ──> Oracle schema
                     │
                     └─ the database also calls its OWN ORDS /oauth/token
                        endpoint over HTTPS to mint the app's Bearer token
```

There is no application server. Every endpoint is a PL/SQL block stored in
ORDS metadata. This has one consequence that shapes all debugging:

> **ORDS stores handler source without validating it.** A handler that
> references a missing column or an INVALID package installs silently and
> fails only when someone calls it — as a bare 403 or 555 with no body.

**A login, step by step:**

1. App sends `POST /expenses/auth/login` with an HTTP Basic header. No
   Bearer token — this is the only endpoint reachable without one.
2. The handler base64-decodes the header itself. ORDS does not do this; see
   [§13.3](#133-ords-does-not-validate-basic-auth).
3. `APEX_UTIL.SET_WORKSPACE` + `IS_LOGIN_PASSWORD_VALID` check the password
   against the APEX user store. The workspace name is resolved at deploy
   time, not hardcoded.
4. The email is matched to an `EMPLOYEEDETAILS` row (`ACTIVE` or
   `RESIGNED`). No match → 403.
5. `generate_session_token` signs `empid.expiry` with HMAC-SHA256.
6. `get_oauth_access_token` calls the database's own ORDS `/oauth/token`
   endpoint using a client id and secret kept in `APP_SECRETS`, and gets a
   Bearer token back.
7. Response: identity, role flags, `session_token`, `access_token`,
   `expires_in`.

Step 6 is why the app holds no client secret. An earlier design embedded
one in the app package, where anyone could extract it.

**Every request after that** carries three headers:

| Header | Checked by | Purpose |
|---|---|---|
| `Authorization: Bearer <access_token>` | ORDS | satisfies the ORDS privilege — gets you to the URL |
| `X-Emp-Id` | the handler | which employee is calling |
| `X-Session-Token` | the handler | proves the caller really logged in as that employee |

The session token is verified inside each handler's `WHERE` clause. A
forged `X-Emp-Id` therefore matches no rows rather than returning someone
else's data. Without it, any valid token holder could read anyone's
expenses by editing one header — which is what security test S6 exists to
catch.

## 4. Data model

Created by this project:

**`EXPENSES`** — one row per claim.

| Column | Notes |
|---|---|
| `id` | identity PK |
| `emp_id` | owner → `EMPLOYEEDETAILS.EMPID` |
| `bill_no`, `bill_date` | from the receipt |
| `from_date`, `to_date` | the expense period. `from_date`'s month picks the exchange rate |
| `project_id`, `type`, `description` | |
| `amount` | as entered, `> 0` |
| `currency`, `exchange_rate`, `amount_usd` | added by script 45; all three stored so later rate corrections never restate an approved expense |
| `attachment_blob`, `_filename`, `_mime_type` | receipt, stored in-row |
| `status` | `DRAFT` / `SUBMITTED` / `REVISION_REQUESTED` / `APPROVED` / `REJECTED` |
| `current_stage` | `MANAGER` / `FINANCE` / NULL. Meaningful only while `SUBMITTED` |
| `manager_empid` | resolved at submit time and frozen, so re-assigning a project later cannot strand an in-flight approval |
| `finance_manager_empid` | defaulted on the column |
| `submitted_by`, `submitted_at` | |
| `client_request_id` | idempotency key — see [§6.4](#64-idempotent-draft-creation) |
| `creation_date`, `created_by`, `last_update_date`, `last_updated_by` | |

**`EXPENSE_APPROVALS`** — append-only audit log, one row per action.
`role` is `PROJECT_MANAGER` or `FINANCE_MANAGER`; `action` is `ACCEPTED`,
`REVISED` or `REJECTED`. The comment column is **`comments`** — see
[§13.6](#136-the-approvals-comment-column).

**`EMP_PUSH_TOKENS`** — one row per registered device, unique on the token.

**`APP_SECRETS`** — `SESSION_TOKEN_KEY` (generated at deploy),
`OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, `OAUTH_TOKEN_URL`. Never leaves
the database.

Read from the existing HR system, never written:
`EMPLOYEEDETAILS`, `PROJECT_ALLOCATION_WB`, `PROJECTMASTER`,
`PROJECT_MANAGER`, `CURRENCY_CONVERSION`.

## 5. Identity, sessions and authorisation

**Three layers, each doing one job:**

| Layer | Mechanism | Answers |
|---|---|---|
| Authentication | APEX password check at login | are you who you say you are? |
| URL access | ORDS privilege + OAuth role | may you reach this URL at all? |
| Row access | `is_valid_session_token` + ownership/stage checks in the handler | may you touch *this row*? |

Skipping the third layer is the classic mistake here: the ORDS privilege on
`/expenses/:id` says "any signed-in employee", and it is the handler's
`WHERE emp_id = :emp_id_hdr` that stops one employee reading another's.

**Two ORDS privileges:**

- `expenses.authenticated` — `EMPLOYEE_ROLE`, `PROJECT_MANAGER_ROLE`,
  `FINANCE_MANAGER_ROLE` on the everyday endpoints.
- `expenses.review` — the two reviewer roles only, on `pending` and the
  three `bulk-*` endpoints.

A pattern may belong to exactly one privilege. Listing the same URL in both
fails with *ORA-20039: Pattern already mapped*.

`auth/login` is deliberately covered by **neither**, and nothing may ever
cover it — see [§13.2](#132-privilege-patterns--never-use-a-wildcard).

**Lifetimes.** Session token 12h, access token 1h, no refresh. The app
handles expiry in two places: an `AppState` listener signs the user out on
resume if the token has already expired, and any 401 from any endpoint
triggers the same path mid-session. Both land on one message rather than a
raw error.

## 6. Business rules

### 6.1 Approval routing

`process_expense_action` is the single gate for accept / revise / reject.
It locks the row `FOR UPDATE`, then:

1. Not found → 404.
2. Status is not `SUBMITTED` → 409. This is what stops two reviewers
   double-approving the same claim.
3. `get_reviewer_role` returns NULL → 403. You are not the reviewer for
   this expense at this stage.
4. Writes the audit row, then applies the transition:
   - Manager accepts → `current_stage = FINANCE`.
   - Finance accepts → `APPROVED`, stage cleared. Email to employee and
     manager.
   - Revise → `REVISION_REQUESTED`; the employee can edit and resubmit.
   - Reject → `REJECTED`, terminal.

Push notifications and `APEX_MAIL` calls are wrapped so a mail failure
cannot roll back an approval.

### 6.2 Currency conversion

`CURRENCY_CONVERSION.EXCHANGE_RATE` is **the USD value of one unit** of
`FROM_CURR`:

```
INR 0.011280559   ->  1 INR = $0.0113      amount_usd = amount * EXCHANGE_RATE
KWD 3.27182306    ->  1 KWD = $3.27
```

`INVERSE_RATE` is units-per-dollar and is **display only**. Multiplying by
it inverts every conversion — and nothing in the system would flag it,
because ₹1,000 becoming $88,648 is arithmetically valid.

Rate selection uses the month of `from_date` — a May bill for April travel
uses April's rate — falling back to the current open rate (null
`EFFECTIVE_END_DATE`) when no row covers that month. The API returns
`rate_month` (the month actually used) and `is_fallback`, so the UI never
claims a rate exists when it does not.

USD is handled as `1` in code, never as a table row, so no data change can
make a dollar worth something else.

### 6.3 Attachments

One receipt per expense, stored as a BLOB in `EXPENSES`. 1 MB limit,
MIME type checked by `is_allowed_attachment`. Upload and download are
separate endpoints on `/{id}/attachment`.

### 6.4 Idempotent draft creation

`POST /expenses/draft` takes a `client_request_id` the app generates. A
repeat with the same id returns the existing row instead of creating a
second one. This exists because a request can time out after the server has
already committed — the app's 45-second timeout says "check My Expenses
before retrying" for exactly this reason.

### 6.5 Email notifications

Every notification goes through one procedure, `send_expense_mail`, which
decides recipients from the event and the actor. The matrix:

| Event | TO | CC |
|---|---|---|
| `SUBMITTED` | project manager | employee |
| `MANAGER_ACCEPTED` | finance manager | project manager + employee |
| `FINANCE_ACCEPTED` | employee | project manager |
| `REVISED` | employee | project manager |
| `REJECTED` | employee | project manager |

Each mail carries an Expense Claim table — project, employee / manager /
finance names with ecodes, type, bill no, currency, amount, the USD equivalent
with the rate that was actually used, and the relevant remarks. HTML with a
plain-text fallback.

**Deploy it with `db/EMAIL_DEPLOY.sql`** — one file, correct order, refuses to
run on the wrong schema. Scripts 56–61 are the same work in the order it was
discovered; `EMAIL_DEPLOY.sql` supersedes them.

Three things that are easy to get wrong here:

- **`send_expense_mail` must be created before `process_expense_action`.**
  Reversed, the workflow compiles against the older 4-argument version and
  rejects the role argument with `PLS-00306`.
- **The actor's role is passed in, not derived.** `is_finance_manager()`
  answers "is this person the finance manager", not "which role were they
  acting in just now". When one person holds both, those differ —
  `process_expense_action` passes `get_reviewer_role`'s answer, which is
  derived from the stage and is the only correct source.
- **No address is not the same as no manager.** A claim whose manager has no
  `COMPANY_EMAIL` can still be approved; only the notification is lost. A
  claim with no `MANAGER_EMPID` is genuinely stuck. The emails say different
  things for each — see script 61 section 2 for who is affected.

**Three things are required for any mail to leave the database**, and all
three were missing originally, which is why nothing ever arrived:

1. **`APEX_MAIL.PUSH_QUEUE`.** `APEX_MAIL.SEND` does not send — it writes to
   `APEX_MAIL_QUEUE`. Without a push, or APEX's background flush job, mail
   sits there forever while the application believes it sent.
2. **A workspace.** `APEX_MAIL.SEND` needs a security group id. There is no
   APEX session inside an ORDS handler, so `APEX_UTIL.SET_WORKSPACE` must be
   called first — the workspace name is seeded into `APP_SECRETS` at deploy
   time as `MAIL_WORKSPACE`.
3. **An SMTP host** configured at APEX instance level, plus a network ACL for
   it. `56_email_notifications.sql` section 4 reports whether it is set.

Failures are written to **`EXPENSE_MAIL_LOG`**, never swallowed:

```sql
SELECT created_at, event, status, mail_to, mail_cc, error_text
FROM   expense_mail_log ORDER BY id DESC FETCH FIRST 20 ROWS ONLY;
```

`PUSHED` means it reached the mail server. `FAILED` carries the full error
stack. `SKIPPED` almost always means a missing `COMPANY_EMAIL`. If rows say
`PUSHED` and nothing arrives, the problem is past the database — SMTP, its
ACL, or spam filtering of the `MAIL_FROM` address.

> A mail failure must never roll back the approval that triggered it, so the
> procedure is autonomous and swallows errors *after logging them*. The
> original code swallowed them without logging, which is what made this
> undiagnosable.

### 6.6 Push notifications

Expo push, sent from PL/SQL via `APEX_WEB_SERVICE` to Expo's API. Devices
register through `POST /expenses/push-token`. Expo Go cannot receive remote
pushes since SDK 53 — a development build is required to test them. The
code detects Expo Go and quietly does nothing there.

## 7. API reference

Base: `https://<HOSTNAME>/ords/<ORDS_BASE_PATH>/expenses/`
Module `expenses.employee`, base path `/expenses/`.

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `auth/login` | Basic | log in; returns identity + both tokens |
| GET | `whoami` | Bearer + session | caller's identity and role flags |
| GET | `my-projects` | Bearer + session | project dropdown values |
| GET | `currencies` | Bearer + session | currency dropdown values |
| GET | `exchange-rate` | Bearer + session | rate + converted amount for a currency/date |
| GET | `mine` | Bearer + session | caller's expenses |
| POST | `draft` | Bearer + session | create a draft (idempotent) |
| GET / PUT / DELETE | `:id` | Bearer + session | read / edit / delete own expense |
| POST | `:id/submit` | Bearer + session | submit for approval |
| POST / GET | `:id/attachment` | Bearer + session | upload / download receipt |
| POST | `push-token` | Bearer + session | register a device |
| GET | `pending` | reviewer roles | review queue |
| POST | `:id/accept` `:id/revise` `:id/reject` | Bearer + session | review actions |
| POST | `bulk-accept` `bulk-revise` `bulk-reject` | reviewer roles | bulk review actions |

21 handlers in total — 19 from `PROD_4`, plus `currencies` and
`exchange-rate` from script 46 (which also redefines the `draft` POST and
`:id` PUT handlers to be currency-aware). `src/api/client.js` has one
function per endpoint and is the fastest way to see exact request and
response shapes.

---

# Deploy it

## 8. Prerequisites and values to collect

**Database**

- Oracle with APEX and ORDS installed
- An application schema (`<APP_SCHEMA>` below), REST-enabled
- `SELECT` on `EMPLOYEEDETAILS`, `PROJECT_ALLOCATION_WB`, `PROJECTMASTER`,
  `PROJECT_MANAGER`, `CURRENCY_CONVERSION`
- An APEX workspace whose user accounts are the employees' company emails

**Not required:** `DBMS_CRYPTO` — see
[§13.1](#131-no-dbms_crypto).

**Build machine:** Node.js and npm; `npx expo` (Expo SDK 54); EAS CLI only
for native binaries.

**Collect these before starting.** Several are not discoverable later
without guessing, and a wrong value fails as something else entirely.

| Value | How to find it | Used by |
|---|---|---|
| `<APP_SCHEMA>` | the schema owning the app tables | everything |
| `<ORDS_BASE_PATH>` | `SELECT pattern FROM user_ords_schemas;` | app `API_BASE_URL` |
| `<HOSTNAME>` | the ORDS host, e.g. `ords.example.com` | network ACL, OAuth token URL |
| `<APEX_WORKSPACE>` | `SELECT DISTINCT workspace_name FROM apex_workspace_apex_users;` (ignore `INTERNAL`) | login handler |
| `<APEX_ENGINE_SCHEMA>` | `SELECT owner FROM dba_objects WHERE object_name = 'APEX_WEB_SERVICE';` — the `APEX_nnnnnn` one | network ACL |
| `<OAUTH_CLIENT_ID>` / `<SECRET>` | `SELECT client_id, client_secret FROM user_ords_clients;` after creating the client | `APP_SECRETS` |
| `<FINANCE_MANAGER_EMPID>` | your finance approver's `EMPID` | `is_finance_manager` |

> **The workspace name catches everyone out.** It differs per environment
> and a wrong value fails as *"Invalid email or password"* —
> indistinguishable from a genuinely wrong password. The scripts resolve it
> automatically at deploy time rather than hardcoding it. Keep that
> behaviour if you edit them.

## 9. Database deployment

### 9.1 Run the master script

As `<APP_SCHEMA>`:

```
@db/MASTER_DEPLOY.sql
```

It contains, in dependency order:

| Part | Script | Creates |
|---|---|---|
| 1 | `PROD_1_schema.sql` | tables, indexes, `APP_SECRETS`, session signing key |
| 2 | `PROD_2_ords_and_security_setup.sql` | roles, module, templates, privileges |
| 3 | `PROD_3_business_logic.sql` | session tokens, OAuth fetch, approval workflow, push, mail |
| 4 | `PROD_4_endpoints.sql` | all 19 base handlers and their parameters |
| 5 | `45_currency_conversion.sql` | currency columns, rate functions, backfill |
| 6 | `46_currency_endpoints.sql` | `/currencies`, `/exchange-rate`, currency-aware save |
| 7 | `48_rate_month_truthfulness.sql` | honest fallback reporting |
| 8 | `49_usd_identity.sql` | USD as 1 in code |

Idempotent and safe to re-run. Parts 6–8 deliberately replace objects
created earlier in the file; later definitions win. It ends with the
structural verification queries from [§11.1](#111-structural).

> **Before running on a schema with real data:** part 5 stamps every
> existing expense with an **assumed** currency (`INR` by default) and
> computes `amount_usd` from it. **Irreversible.** Check first:
>
> ```sql
> SELECT COUNT(*) FROM expenses WHERE currency IS NULL;
> SELECT MIN(amount), MAX(amount) FROM expenses;
> ```
>
> If the existing amounts are not all in the assumed currency, change
> `c_assumed_currency` before running, or every converted value will be
> wrong by roughly the exchange rate.

### 9.2 Then run these separately

**a) OAuth client and `APP_SECRETS`** — `PROD_2b_oauth_and_network_acl.sql`
sections 1–2, as `<APP_SCHEMA>`. Then confirm all four rows exist:

| `SECRET_NAME` | Value |
|---|---|
| `SESSION_TOKEN_KEY` | generated by part 1 — **never change on a live system**, it invalidates every session |
| `OAUTH_CLIENT_ID` | from `user_ords_clients` |
| `OAUTH_CLIENT_SECRET` | from `user_ords_clients` |
| `OAUTH_TOKEN_URL` | `https://<HOSTNAME>/ords/<ORDS_BASE_PATH>/oauth/token` |

**b) Network ACL** — `PROD_2b` section 3, **as a DBA**. Mandatory: the
database calls its own ORDS endpoint over HTTPS during login, and without
this login fails at the last step with `ORA-24247`.

```sql
-- as SYS / SYSTEM / ADMIN
BEGIN
  FOR p IN (SELECT '<APEX_ENGINE_SCHEMA>' AS n FROM dual
            UNION ALL SELECT '<APP_SCHEMA>'      FROM dual
            UNION ALL SELECT 'APEX_PUBLIC_USER'  FROM dual)
  LOOP
    BEGIN
      DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
        host => '<HOSTNAME>',
        ace  => xs$ace_type(privilege_list => xs$name_list('http'),
                            principal_name => p.n,
                            principal_type => xs_acl.ptype_db));
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;
  COMMIT;
END;
/

SELECT * FROM dba_host_aces WHERE host = '<HOSTNAME>' ORDER BY principal;
```

> **Granting only `<APP_SCHEMA>` will not work.** The call goes through
> `APEX_WEB_SERVICE.MAKE_REST_REQUEST`, and PL/SQL packages execute with
> their *owner's* privileges — so the principal that matters is the APEX
> engine schema. This costs hours when missed, because the error names
> neither schema.

**c) `is_finance_manager`** — still returns `'Y'` for one hardcoded
`EMPID`. Set it for this environment.

**d) CORS** — `13_cors_fix_for_web_testing.sql`, only if the app will be
served from a browser. Native apps are not subject to CORS.

### 9.3 DBA: connection pool account

If ORDS returns 5xx for *every* endpoint, check the pool user is not
locked. This happened during development and looks exactly like broken
code:

```sql
SELECT username, account_status, lock_date, expiry_date
FROM   dba_users WHERE account_status != 'OPEN';

ALTER USER ORDS_PUBLIC_USER ACCOUNT UNLOCK;
```

Also check `FAILED_LOGIN_ATTEMPTS` and `PASSWORD_LIFE_TIME` on its profile,
or it will lock again on a schedule.

## 10. The app

### 10.1 Configuration

One line, `src/config.js`:

```javascript
export const API_BASE_URL = 'https://<HOSTNAME>/ords/<ORDS_BASE_PATH>';
```

That is the only environment-specific value in the entire app. There are no
secrets in the client.

### 10.2 Running locally

```bash
npm install
npx expo start           # Metro + Expo Go
npx expo start --clear   # after adding new files
npx expo start --web     # browser
```

### 10.3 Native builds

```bash
eas build --profile development --platform android   # dev client, for push testing
eas build --profile preview      --platform android  # installable APK, no store
```

`API_BASE_URL` is baked in at build time — a build points at one environment
for life. Push notifications need a development build, not Expo Go.

For store releases see [§10.7](#107-releasing-to-the-app-store-and-play-store).
iOS has no `preview` device build here: `preview` produces a simulator
build, and on-device iOS testing goes through TestFlight.

### 10.4 Web build and GitHub Pages

```bash
npx expo export -p web        # produces dist/
```

For a project sub-path (e.g. GitHub Pages at `/<repo-name>`), `app.json`
needs:

```json
"experiments": { "baseUrl": "/<repo-name>" }
```

and `dist/.nojekyll` must exist. GitHub Pages runs Jekyll, which ignores
folders starting with `_`, and Expo puts all its JavaScript in `_expo/`.
Without that file you get a blank page and a 404 on every bundle.

Full deploy, from the project root:

```powershell
npx expo export -p web
New-Item -ItemType File -Path "dist\.nojekyll" -Force
cd dist
git init; git add -A; git commit -m "Web build"
git branch -M gh-pages
git remote add origin https://github.com/<owner>/<repo>.git
git push --force origin gh-pages
```

Web also needs CORS enabled on ORDS for the hosting origin
([§9.2d](#92-then-run-these-separately)).

### 10.5 Web platform differences

`react-native-web` silently no-ops several React Native APIs. Each of these
is already handled; keep the pattern when adding features:

| API | Web behaviour | Handled by |
|---|---|---|
| `Alert.alert` | does nothing at all | `src/utils/alert.js` → `window.alert` / `window.confirm` |
| `@react-native-community/datetimepicker` | no web implementation | `DateField.js` → `<input type="date">` |
| `FormData` file upload | needs a real `Blob` | `client.js` `uploadAttachment` |
| `FileSystem.cacheDirectory` | `null` | attachment preview branches on `Platform.OS` |

### 10.6 Push notification credentials

The backend has been sending pushes since long before any device could receive
one. Getting a token requires per-platform credentials that live on EAS, not
in this repo.

**The symptom when they are missing** (Android):

```
Default FirebaseApp is not initialized in this process com.trinamix.expenseapp.
Make sure to call FirebaseApp.initializeApp(Context) first.
```

That is not an app bug. Expo push on Android is delivered *through* Firebase
Cloud Messaging, so the build needs a Firebase project even though no
Firebase code is used anywhere.

**Android — four steps, all required:**

1. Create a Firebase project at `console.firebase.google.com`, and add an
   **Android app** with package name **`com.trinamix.expenseapp`**. It must
   match `app.json` exactly.
2. Download **`google-services.json`**, put it in the project root, and point
   `app.json` at it:

   ```json
   "android": {
     "googleServicesFile": "./google-services.json"
   }
   ```

   Commit this file. It contains public identifiers, not secrets, and builds
   fail without it.
3. In Firebase: **Project settings → Service accounts → Generate new private
   key**. Upload that JSON to EAS:

   ```bash
   eas credentials
   # Android > production > Google Service Account
   #   > Manage your Google Service Account Key for Push Notifications (FCM V1)
   #   > Set up ... > Upload a new service account key
   ```

   **Do not commit this one** — it grants the ability to send push
   notifications as this project. `.gitignore` already excludes the usual
   filenames.
4. Rebuild. Credentials are baked in at build time, so no existing build will
   ever start working.

> If pushes still fail after this, check whether the API key in
> `google-services.json` is restricted, in the Google Cloud console. It needs
> the **FCM Registration API** and **Firebase Installations API** allowed, and
> any Android app restriction must use the SHA-1 from Play Console →
> **App Integrity → App signing key certificate** — not the upload key. A
> mismatch returns `403 PERMISSION_DENIED` and the app never gets a token.

**iOS —** needs a **paid** Apple Developer account; there is no free path.
Register the test device with EAS *before* the first build, then answer yes to
"Setup Push Notifications" when `eas build` prompts, or run `eas credentials`
and generate an Apple Push Notifications service key.

#### Push is optional — current status: NOT ENABLED

As of August 2026 push does not work in production, and **the app is fully
usable without it**. Do not treat this as a launch blocker.

Where it got to: the Firebase side is done and devices register successfully
(`EMP_PUSH_TOKENS` fills up). The remaining failure is the database being
unable to complete a TLS handshake with `exp.host`:

```
ORA-29273: HTTP request failed
ORA-29024: Certificate validation failure
```

The network ACL is correct; the database has no public CA in its trust store.
Fixing it needs a DBA to build an Oracle wallet — see
`db/DBA_REQUEST_push_wallet.md`, which is written and ready to send, and
`db/55_push_wallet.sql`, which wires it up afterwards. Nothing else is
outstanding.

**What happens meanwhile.** Failures are swallowed by design —
`send_push_notification` cannot roll back the approval that triggered it — so
every workflow action still completes normally. Users get:

- **Email** on all five workflow events, including the manager-accept
  transition that used to be push-only — see the matrix in
  [§6.5](#65-email-notifications).
- **The in-app notification list**, which reads from the API and needs nothing
  external.

Email now covers every event push would have, so nobody is left uninformed
with push disabled — provided the SMTP host is configured.

If push is never enabled, nothing needs to be removed — the calls are already
harmless no-ops.

### 10.7 Releasing to the App Store and Play Store

#### What is already configured

`app.json` and `eas.json` are set up for both stores:

| Setting | Value |
|---|---|
| Display name | `Expenses` |
| Android package | `com.trinamix.expenseapp` |
| iOS bundle identifier | `com.trinamix.expenseapp` |
| Android production artifact | `app-bundle` (AAB — Play requires this, not an APK) |
| Versioning | `appVersionSource: remote` — **EAS owns the build numbers** |
| Play submit track | `internal`, as a `draft` |

> **Identifiers are permanent.** The Android package can never be changed
> once published, and the iOS bundle ID is bound to the App Store Connect
> record. They were changed from `com.napeedmai.*` before any store upload;
> after the first upload that is impossible. Change them now or not at all.

**Versioning works like this:** `version` in `app.json` (`1.0.0`) is the
user-facing number and you bump it by hand for each release. The Android
`versionCode` and iOS `buildNumber` are held on EAS's servers and
incremented automatically by `autoIncrement` in the production profile —
deliberately, so two people building from two branches cannot collide, and
so nobody can forget. Do not add them back to `app.json`; two sources of
truth for a build number is a bad afternoon.

#### Accounts to obtain first

Nothing can be submitted without these, and both take real time to approve.

| Account | Cost | Lead time | Notes |
|---|---|---|---|
| Apple Developer Program | US$99/year | days to weeks | An **Organization** account needs a D-U-N-S number for Trinamix. Start this first; it is the long pole |
| Google Play Console | US$25 once | 1–3 days, sometimes longer | Organization accounts require identity and business verification |
| Expo (EAS) | free tier is enough | immediate | see the ownership warning below |

> **Account ownership — done, keep it that way.** `app.json` has
> `"owner": "trinamix"`, so builds, push credentials and signing keys all
> belong to the company organisation rather than to an individual. Never
> point `owner` back at a personal account: whoever holds that account is
> then the only person who can ship an update.

> **"Expo Go" and "the Expo account" are different things.** Expo Go is the
> sandbox app used during development; employees never install it and it has
> nothing to do with a store release. The Expo *account* is the EAS build
> service — it compiles the store binaries and stores the signing
> credentials, so it is needed permanently, for every future update. That is
> what has to move to a company org.
>
> The only way to not depend on it is `npx expo prebuild` and building the
> native projects yourself in Xcode and Android Studio, which means owning
> the `ios/` and `android/` folders and their upgrades from then on. Not
> recommended here.

#### One-time setup — done

Already completed: the `trinamix` organisation exists, `owner` points at
it, and `eas init` has written `extra.eas.projectId` into `app.json`. That
`projectId` is committed and must stay identical for every developer — two
different values means push tokens minted against two different Expo
projects, and notifications that go nowhere.

For a new machine, only this is needed:

```bash
npm install -g eas-cli
eas login
```

Still outstanding: signing credentials.

```bash
eas credentials
```

Take the default (EAS-managed) unless Trinamix already has an Android
upload key. **Losing the Android upload key means you can never update the
Play listing again** — a new package name and a new listing is the only way
back. EAS holds it, which is exactly why the account belongs to the
company org rather than to a person.

`eas init` is not optional. Without `extra.eas.projectId` the app cannot
obtain an Expo push token, so **push notifications silently do nothing** —
no error, no log, the feature simply never fires. The backend half is
already deployed and waiting for it.

#### Build and submit

```bash
# Android — AAB for Play
eas build --profile production --platform android
eas submit --profile production --platform android

# iOS — App Store build, goes to TestFlight first
eas build --profile production --platform ios
eas submit --profile production --platform ios
```

Fill in the three iOS placeholders in `eas.json` (`appleId`, `ascAppId`,
`appleTeamId`) after creating the app record in App Store Connect. Android
submission needs a Google Play service account JSON — `eas submit` prompts
for it and can store it on EAS.

`eas build` reads `src/config.js` at build time, so **confirm
`API_BASE_URL` points at production before building a store release.** A
store build aimed at a test host cannot be corrected without a new
submission.

#### What the stores will ask for

Prepare these before submitting; a missing one holds up review:

- **Privacy policy URL** — both stores require one, hosted publicly, even
  for an internal business app.
- **Data safety / privacy nutrition labels** — declare what is collected.
  This app collects work email, employee identity, expense records and
  receipt images, and it does *not* use advertising or third-party
  analytics.
- **Screenshots** — several sizes per platform, from a real device or
  simulator.
- **Test account credentials** — reviewers must be able to log in.
  Both stores reject apps whose login they cannot get past, and this app
  authenticates against your APEX workspace. Supply a working account with
  a few sample expenses on it, so the reviewer sees a populated app rather
  than an empty list — [see below](#the-network-question--settled).
- **Export compliance** — already answered by
  `ITSAppUsesNonExemptEncryption: false` in `app.json`. The app uses HTTPS
  only, which is exempt.

Expect roughly a day for Play's first review and one to three days for
Apple's, with rejections adding a cycle each. Budget two weeks for the
first release on each store and plan the internal announcement around
approval, not around submission.

#### The network question — settled

**The ORDS host is reachable from any network.** Confirmed August 2026.
Store review is therefore unblocked: Apple's and Google's reviewers can
reach the API and log in with the test account you supply, and employees
can use the app without VPN.

The trade is that the login endpoint is on the public internet, so the
security tests in [§11.2](#112-security-tests--run-every-one) stop being a
formality and become the perimeter. Two consequences worth acting on:

- **S2 is now the thing standing between the internet and every expense
  record in the system.** The bypass it tests for was live once. Re-run it
  after any change to the login handler, on every environment.
- **There is no rate limiting on `auth/login`.** Nothing in ORDS or in the
  handler slows down repeated password guesses against a known company
  email address. This was acceptable while the host was internal; on a
  public endpoint it is worth adding — ORDS request throttling, a WAF rule,
  or a lockout counter in the handler. Not currently implemented.

Also confirm the ORDS host serves a valid public TLS certificate. Both
platforms refuse plain HTTP by default (ATS on iOS, cleartext blocked on
Android), and a self-signed or internal-CA certificate will fail on
reviewers' devices in a way that looks like the server is down.

#### Releasing an update

1. Change the code; bump `version` in `app.json` (e.g. `1.0.1`).
2. `eas build --profile production --platform all`
3. `eas submit --profile production --platform all`
4. Android arrives on the `internal` track as a draft — promote it to
   production in the Play Console when you are ready.
5. iOS arrives in TestFlight — test, then release from App Store Connect.

Every native release is a store review. A backend-only change needs no
release at all, and a web-only change is a redeploy of `dist`
([§10.4](#104-web-build-and-github-pages)) with no review.

#### The other two channels, still available

Store distribution does not replace these:

- **Web** — the fastest path to a pilot group. No install, no review, fix
  and redeploy within the hour. Needs CORS enabled
  ([§9.2d](#92-then-run-these-separately)). Note that the current web
  deployment is a **public** GitHub Pages site: the login page is reachable
  by anyone, which is a deliberate decision to make rather than inherit.
- **APK** — `eas build --profile preview --platform android` gives a
  directly installable file for MDM or a download link. Useful for testing
  the exact production flow before committing to a store review.

### 10.8 Walkthrough: launching as a Custom App (iOS) — THE CHOSEN ROUTE

**Decision, August 2026: iOS ships as a private Custom App, distributed by
redemption code. Not the public App Store, and not via MDM.**

Why: the app is useless to anyone outside Trinamix, so a public listing risks
rejection under Guideline 4.2 (Minimum Functionality) and needlessly
advertises a login endpoint that has no rate limiting. Redemption codes rather
than MDM because Trinamix does not need to manage the devices — codes work on
personal iPhones with personal Apple IDs.

The whole journey below, from nothing to the app on an employee's phone. A
Custom App is distributed only to named organisations instead of the public
App Store — Apple's own description is "a proprietary app for your
organisation's internal use".

```
  Trinamix                 Apple                    You                  Employee
     │                       │                       │                      │
  ┌──┴──┐                 ┌──┴──┐                    │                      │
  │ ABM │──Org ID────────>│     │<──app record───────┤                      │
  └─────┘                 │     │<──build────────────┤                      │
                          │Review│                                          │
                          └──┬──┘                                           │
                             │ approved                                     │
                             v                                              │
                     appears in Trinamix's ABM ──MDM or redeem code────────>│
```

**Two one-way doors. Read these before starting.**

1. **Private vs Public must be chosen before the app is approved.** Apple:
   "this option is only available before your app has been approved." Switching
   later means a new app record and starting over.
2. **The bundle identifier is permanent** once the App Store Connect record
   exists. It is `com.trinamix.expenseapp`.

---

#### Phase 1 — Accounts (weeks, start now)

Both are enrolled per-company and both need a D-U-N-S number for Trinamix.
They are separate signups and can run in parallel.

| What | Where | Cost | Who |
|---|---|---|---|
| Apple Developer Program (Organization) | `developer.apple.com/programs` | US$99/yr | whoever can sign for the company |
| Apple Business Manager | `business.apple.com` | free | IT / whoever manages Apple devices |

Then get the **Organization ID**: Apple Business Manager → your name at the
bottom of the sidebar → **Preferences** → **Enrollment Information** → first
section. It looks like a long number. You cannot proceed without it.

> If Trinamix already manages company iPhones with an MDM, Apple Business
> Manager almost certainly exists already — ask before starting a new
> enrolment.

#### Phase 2 — Credentials

```bash
eas credentials      # iOS -> generate the distribution certificate,
                     # provisioning profile, and the APNs key for push
```

Take the EAS-managed defaults. They live in the `trinamix` Expo org, which is
why that ownership move mattered.

#### Phase 3 — Test on a real iPhone first

Do not submit an app that has never run on the platform. See
[§10.3](#103-native-builds).

```bash
eas device:create                              # register the iPhone FIRST
eas build --profile preview --platform ios     # install from the link
```

Work through the five iOS-specific paths in
[§15](#15-known-limitations-and-open-items): date picker, PDF preview,
keyboard overlap, push permission prompt, notch spacing.

#### Phase 4 — Create the app record and make it Private

In **App Store Connect** → **Apps** → **+** → New App. Bundle ID
`com.trinamix.expenseapp`, name `Expenses`.

Then, **before submitting anything**:

> **Pricing and Availability** → **App Distribution Methods** →
> select **Private** → Type: **Organization ID** → paste Trinamix's ID.

This is the step that makes it a Custom App. Everything else is a normal
submission.

#### Phase 5 — Build and submit

```bash
# confirm src/config.js points at PRODUCTION before this
eas build  --profile production --platform ios
eas submit --profile production --platform ios
```

Fill the three placeholders in `eas.json` (`appleId`, `ascAppId`,
`appleTeamId`) from the App Store Connect record first.

Optionally invite colleagues as TestFlight **internal** testers at this point
— internal testers skip Beta App Review, so it is available in minutes.

#### Phase 6 — Review

Custom Apps are still reviewed. Provide:

- **A working demo account** on production, with a few expenses already on it
  in different states, plus a second account that can approve — so the
  reviewer sees the workflow rather than an empty list. Apple's requirement is
  "an active demo account... plus any other hardware or resources".
- **Review notes**: internal expense tool for Trinamix employees; accounts are
  provisioned by HR, so the app has no signup and therefore no in-app account
  deletion; the backend is live at the URL given.
- **Privacy policy URL** and the data-collection declarations — work email,
  employee identity, expense records, receipt images; no advertising, no
  third-party analytics.

Apple's note for exactly this case: "If your app contains sensitive data,
provide sample data and authentication for the App Store Review team."

Budget one to three days, plus a cycle for each rejection.

#### Phase 7 — It appears in Apple Business Manager, and you generate codes

Once approved, the app shows up in Trinamix's ABM under **Custom Apps**. It is
invisible on the public App Store; searching for it finds nothing.

In Apple Business Manager:

1. **Apps and Books** → find `Expenses` under Custom Apps
2. Choose the quantity of licences needed and acquire them (the app is free,
   so this costs nothing — it is still a "purchase" of zero-price licences)
3. Switch the assignment type to **redemption codes** rather than managed
   distribution, and download the codes. ABM gives you a spreadsheet, one
   code per licence.

Each code is single-use. Buy more licences than people, so there is slack for
mistyped codes and new joiners.

> Apple's supported distribution methods for a Custom App are "Mobile Device
> Management or redemption codes". MDM would push the app silently and handle
> updates automatically — worth revisiting if Trinamix ever adopts one, but it
> is not needed here.

#### Phase 8 — The employee installs it

Send the person a code. On their iPhone:

1. Open the **App Store** app
2. Tap the profile picture, top right
3. **Redeem Gift Card or Code** → **Enter Code Manually**
4. Type the code → the app downloads and installs

No Apple Business Manager account, no MDM enrolment, no company-owned device.
A personal Apple ID is fine. From their side it is an ordinary app that simply
never came from the store.

Then they log in with their Trinamix email and password — the same credentials
as every other internal system, since authentication goes to the APEX
workspace.

> **Write the install instructions into your rollout email**, with the four
> steps above. "Redeem Gift Card or Code" is not an obvious place to look for
> a company app, and this is the step where a rollout generates the most
> support questions.

---

#### Releasing an update afterwards

Same as any other release, and still reviewed:

1. Bump `version` in `app.json`
2. `eas build --profile production --platform ios`
3. `eas submit --profile production --platform ios`
4. Approved → the new version reaches ABM

**Existing users do not need new codes.** Once the app is on a phone, updates
arrive through the normal App Store update mechanism like any other app — the
code was only ever for the initial install. New joiners need a fresh code.

Backend-only changes need no release at all.

#### What this route does NOT require

Worth stating plainly, because each is a common assumption:

- **No MDM.** Codes work on unmanaged, personal iPhones.
- **No company-owned devices.**
- **No Managed Apple IDs.** A personal Apple ID redeems the code fine.
- **No public App Store listing.** The app is not findable or downloadable by
  anyone outside Trinamix.
- **No cost beyond the $99/yr Developer Program.** Apple Business Manager is
  free and the app's licences are zero-price.

### 10.9 Android distribution options

Android has a private-publishing route, but it is **not** the mirror image of
Apple's. The decisive difference:

> Apple's Custom Apps can be distributed by redemption code, with no device
> management. Google's private apps **can only be distributed through an EMM
> console** — Google's own words: "You can then use your EMM console to
> distribute these apps to users."

So if Trinamix has no MDM/EMM, the Apple route works and the equivalent Google
route does not.

The good news is that Android does not need it. Google Play has **no
equivalent of Apple's Guideline 4.2** — a login-gated internal business app on
the public Play Store is unremarkable and not a rejection risk. The reason for
going private on iOS mostly evaporates here.

#### The four options

| Option | Needs EMM | Needs review | Auto-updates | Cap |
|---|---|---|---|---|
| **Direct APK** | no | no | **no** | none |
| **Play internal testing** | no | minimal | yes | 100 testers |
| **Play production (public)** | no | yes | yes | none |
| **Managed Google Play private** | **yes** | yes | yes | 1000 orgs |

**Direct APK.** `eas build --profile preview --platform android`, then email
the file or host it. Android permits sideloading, so this needs no account, no
review and no fee. The costs: people must allow "install from unknown
sources", Play Protect may warn them, and **there are no automatic updates** —
every release means re-sending the file and asking everyone to reinstall. Fine
for a pilot, painful as a permanent channel.

**Play internal testing.** Add testers by email in the Play Console; they get
a link, opt in, and install through the Play Store like any other app —
including automatic updates. No meaningful review, available in hours. Capped
at 100 testers. This is the best pilot channel.

**Play production, public listing.** The normal route. Findable by anyone,
who will hit the login and stop. Automatic updates, no cap, and low rejection
risk on Play.

**Managed Google Play private app.** The true Apple-Custom-App equivalent:
Play Console → **Release → Setup → Advanced settings → Managed Google Play**
→ Add organization → paste Trinamix's Organization ID (found at
`play.google.com/work` → **Admin Settings**). Invisible publicly, distributed
via the EMM console. Requires an EMM.

> **One-way door, same as Apple's.** Google: "Once your app is restricted to
> organizations, your app will be private... If you want your app to be
> publicly available, you will need to publish a new app with a different
> package name." Restricting to an organisation cannot be undone — it costs
> you the package name `com.trinamix.expenseapp`.

#### Recommendation

Without an EMM: **internal testing for the pilot, then a public production
listing** for the real rollout. Automatic updates are worth more here than
obscurity, since the API is internet-facing either way and Play carries no
minimum-functionality risk.

Revisit the managed Google Play route only if Trinamix adopts an EMM — and
decide before the first production release, because of the one-way door above.

## 11. Verification

Do not skip this. Several of these failures are silent.

### 11.1 Structural

Run `db/HEALTH_CHECK.sql` as the app schema with `SET SERVEROUTPUT ON`. It
is read-only and safe on production, and covers everything below plus
secrets, privilege coverage and the currency direction — printing PASS,
FAIL or WARN per check with the fix for each failure. Run it on **both**
environments; most of the trouble in this project came from the two
drifting apart.

The individual queries, which `MASTER_DEPLOY.sql` also ends with. Expect: no
INVALID rows, no `handler_count = 0`, `auth_param = 1`, `has_safe_guard = Y`,
no wildcard rows, and `COMMENTS` (not `COMMENT`) on the approvals table.

```sql
SELECT object_name, object_type, status FROM user_objects
WHERE  status = 'INVALID' ORDER BY object_name;

SELECT t.uri_template, COUNT(h.id) AS handler_count,
       LISTAGG(h.method, ', ') WITHIN GROUP (ORDER BY h.method) AS methods
FROM   user_ords_templates t
JOIN   user_ords_modules m ON m.id = t.module_id
LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
WHERE  m.name = 'expenses.employee'
GROUP  BY t.uri_template ORDER BY handler_count;

SELECT pm.pattern FROM user_ords_privilege_mappings pm
WHERE  pm.pattern LIKE '/expenses/%*%' OR pm.pattern = '/expenses/*';
```

### 11.2 Security tests — run every one

Use Postman with **Auth type "No Auth"** and a manually built header.
Postman's Basic Auth tab retains the last good password: it will tell you
the endpoint is broken when it is fine, and fine when it is broken. That
mistake hid a live authentication bypass for several rounds of testing.

```powershell
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("user@example.com:password"))
```

| # | Test | Required result |
|---|---|---|
| S1 | login, correct password | 200 with `empid`, `session_token`, `access_token` |
| S2 | login, **wrong** password (run twice) | **401** `Invalid email or password.` |
| S3 | login, unknown user | 401 |
| S4 | `GET /expenses/mine`, no headers | 401 |
| S5 | `GET /expenses/mine`, valid Bearer, no `X-Session-Token` | 401 or 403, never 200 |
| S6 | `GET /expenses/mine`, your session token + **someone else's** `X-Emp-Id` | 401/403/404, never 200 |
| S7 | `GET /expenses/whoami`, your token + another `X-Emp-Id` | 404, never their identity |

> **S2 and S6 are the two that matter.** S2 catches the authentication
> bypass described in [§13.4](#134-the-login-guard) — which shipped live and
> let any valid username in with any password. S6 is what stops `X-Emp-Id`
> being a way to read anyone's expenses.

### 11.3 Functional

| Test | Expected |
|---|---|
| `GET /expenses/currencies` | list including `USD` at rate `1` |
| `GET /expenses/exchange-rate?currency=INR&amount=1000` | ≈ `11.28`, **not** ≈ `88648` |
| same for a month with no rate row | `is_fallback: Y`, `rate_month` = month actually used |
| `POST /expenses/draft` with `currency` | 201 with `amount_usd` |
| `PUT /expenses/{id}` changing only `amount` | `amount_usd` follows |
| full flow | draft → attach → submit → manager accept → finance accept → `APPROVED` |
| approval audit | one `EXPENSE_APPROVALS` row per action, comment stored |
| dashboard | monthly totals in USD, mixed currencies added correctly |

The INR direction check is the important one. Getting it backwards turns a
₹1,000 taxi fare into an $88,648 expense and nothing else would flag it.

---

# Run it

## 12. Fault dictionary

Every symptom below was hit during development. Each has one cause, and
none of the error messages point at it.

| Symptom | Cause |
|---|---|
| **403, no JSON body**, "Access to the resource is prohibited" | a PL/SQL object the handler references is INVALID or missing. ORDS refuses the resource before running it. **Not** a permissions problem despite the wording. Check `user_objects` for `INVALID` |
| **555** (ORDS-25001) | same class: handler PL/SQL failed to compile or run. Usually a missing column or object |
| **570** | same class. Also seen when the ORDS connection-pool user is locked |
| **401 "The request is unauthenticated"** | the `Authorization` header parameter is missing from the handler, or a privilege pattern matches the login URL |
| **Full HTML "Unauthorized — please sign in" page** | a privilege pattern (usually a wildcard) covers an endpoint that must stay open |
| **401 "Invalid email or password" with correct credentials** | wrong workspace in `SET_WORKSPACE` |
| **Login succeeds with ANY password** | the `IF NOT l_valid` bug — [§13.4](#134-the-login-guard) |
| **500 ORA-24247** | network ACL missing, or granted to the wrong principal — [§9.2b](#92-then-run-these-separately) |
| **500 ORA-20051** | `APP_SECRETS` OAuth rows not seeded |
| **500 invalid_client** | wrong client id/secret, or `OAUTH_TOKEN_URL` pointing at the wrong base path |
| **403 "not linked to an active employee record"** | genuine: no `ACTIVE`/`RESIGNED` `employeedetails` row matches that `company_email` |
| **404 on a URL that exists** | template registered with no handler attached. `51_restore_missing_handlers.sql` fixes the two known cases |
| **Accept/revise/reject fails with a bare 403 or 555** | `PROCESS_EXPENSE_ACTION` is INVALID — usually the `COMMENT`/`COMMENTS` mismatch, [§13.6](#136-the-approvals-comment-column) |
| **401 an hour into a session** | access token expired (3600s). Log in again |
| **Amounts ~88× too large** | conversion direction inverted — [§6.2](#62-currency-conversion) |
| **Blank web page, 404 on every bundle** | missing `.nojekyll`, or `baseUrl` not matching the sub-path |
| **Buttons do nothing on web, work on device** | a react-native-web no-op — [§10.5](#105-web-platform-differences) |

**General method.** When ORDS returns a bare 4xx/5xx with no JSON body, the
handler did not run. Copy its PL/SQL into SQL Developer, substitute the
binds, and execute it — the real Oracle error appears immediately. This is
faster than any amount of reasoning about ORDS status codes.

```sql
-- retrieve a handler's source to run by hand
SELECT h.method, h.source
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee' AND t.uri_template = ':id/accept';
```

## 13. Design constraints — do not "simplify" these

Each of these looks like it could be written more simply. Each was written
this way because the simpler version failed.

### 13.1 No DBMS_CRYPTO

App schemas commonly lack execute on `SYS.DBMS_CRYPTO`, and granting it
needs a DBA. Session tokens therefore use `STANDARD_HASH` with an explicit
two-pass HMAC (RFC 2104) in `hmac_sha256_hex`.

This is **not** the naive `hash(secret || payload)`, which SHA-256's
length-extension property makes forgeable. The deployment self-tests it
against the published test vector and refuses to install if the result is
wrong.

`SESSION_TOKEN_KEY` is generated with `DBMS_RANDOM`/`SYS_GUID` for the same
reason. When that block once failed on a schema without the grant, the key
was never created, `GENERATE_SESSION_TOKEN` compiled INVALID, and every
login returned a bare 403 with no hint that PL/SQL was the cause.

### 13.2 Privilege patterns — never use a wildcard

ORDS applies **every** privilege whose pattern matches a URI, and offers no
way to exempt one path. `/expenses/*` therefore also captures
`/expenses/auth/login`, making login impossible by construction: you need a
Bearer token to log in, and logging in is how you get one.

List each protected endpoint explicitly. Use exact patterns —
`/expenses/pending/*` does **not** match `/expenses/pending`, silently
leaving that endpoint unprotected.

Add a pattern whenever you add an endpoint. A path no privilege matches is
publicly accessible.

### 13.3 ORDS does not validate Basic Auth

ORDS privileges authenticate via OAuth2 Bearer tokens and roles. They never
validate Basic Auth against APEX accounts, whatever a privilege's
description claims. On an endpoint no privilege covers, `:current_user` is
always NULL — an earlier design relied on it and returned 403 for every
correct login.

The login handler therefore decodes the header and validates the password
itself, and must have an explicit `Authorization` header parameter defined
(`ORDS.DEFINE_PARAMETER`). Without that parameter the bind is NULL and
every login returns 401.

Note also that `IS_LOGIN_PASSWORD_VALID` is **case-sensitive on the
username** while stored account names may be uppercase. The handler
resolves the stored spelling first, so any casing works — do not add
`.toLowerCase()` in the client, which is what broke it before.

### 13.4 The login guard

`APEX_UTIL.IS_LOGIN_PASSWORD_VALID` returns **NULL**, not FALSE, for a
wrong password in this context. In PL/SQL `NOT NULL` is NULL, and an `IF`
only branches on TRUE:

```sql
IF NOT l_valid THEN ... reject ... END IF;    -- WRONG: skipped entirely on NULL
IF NVL(l_valid, FALSE) = FALSE THEN ...       -- correct
```

The first form shipped as a live authentication bypass: any valid username
with any password received a full session. It hides well, because
`CASE WHEN l_valid THEN 'Y' ELSE 'N' END` renders NULL as `'N'` — the
endpoint reported the password as invalid *and issued a token in the same
response*.

`PROD_4` now carries the fixed guard, so a fresh deployment is safe.
Test S2 exists to prove it, and is worth running after any change to the
login handler.

### 13.5 Role names differ between environments

ORDS role names may differ per environment. Scripts that rebuild privileges
read the existing roles rather than hardcoding them, and check a role
exists *before* deleting a privilege — the reverse order can destroy the
privilege and leave every endpoint unprotected. `ORDS.DEFINE_PRIVILEGE`
does not create roles implicitly; a missing role fails with `ORA-01403`.

### 13.6 The approvals comment column

The column is `COMMENTS`, not `COMMENT`. `COMMENT` is an Oracle reserved
word, and `process_expense_action` inserts into `COMMENTS`. When the two
disagreed, `PROCESS_EXPENSE_ACTION` compiled INVALID and every approval
action failed with a bare 403/555 that looked like a permissions problem.

`PROD_1` section 2.1 renames the column in place on schemas built before
this fix and then recompiles the procedure. Check it after deploying:

```sql
SELECT column_name FROM user_tab_columns
WHERE  table_name = 'EXPENSE_APPROVALS' AND column_name LIKE 'COMMENT%';
-- expect exactly: COMMENTS
```

## 14. How to make common changes

**Add an endpoint.** Four steps, and skipping either of the last two is a
silent failure:

1. `ORDS.DEFINE_TEMPLATE` for the pattern.
2. `ORDS.DEFINE_HANDLER` — and `ORDS.DEFINE_PARAMETER` for every header the
   handler binds, including `X-Emp-Id`, `X-Session-Token` and any
   `X-APEX-STATUS-CODE` output.
3. Add the pattern to a privilege, or it is publicly accessible
   ([§13.2](#132-privilege-patterns--never-use-a-wildcard)).
4. Validate the session inside the handler —
   `is_valid_session_token(:emp_id_hdr, :session_token_hdr)` — and add a
   client function in `src/api/client.js`.

Then re-run the structural checks: a template with no handler answers but
runs nothing.

**Add a field to an expense.** Column (idempotent `ALTER`) → the `draft`
POST and `:id` PUT handlers → the `:id` GET and `mine` selects → the form
in `AddEditExpenseScreen.js`. Handlers referencing a column that does not
exist yet fail as 555, so deploy the column first.

**Add a second finance manager.** `is_finance_manager` currently returns
`'Y'` for one hardcoded `EMPID`. Replace the body with a lookup — a small
table, or `PROJECT_MANAGER`-style resolution. Everything downstream calls
this one function, so nothing else changes.

**Change an exchange rate source.** `get_exchange_rate` is the only place
rates are read; `convert_to_usd` and `get_rate_effective_date` sit on top of
it. Keep the `EXCHANGE_RATE`-is-USD-per-unit convention, and keep the USD
short-circuit in [§13](#13-design-constraints--do-not-simplify-these).

**Point the app at a different environment.** `src/config.js`, then rebuild
and redeploy — the value is compiled into the bundle.

## 15. Known limitations and open items

**Limitations**

| Item | Detail |
|---|---|
| Finance manager is hardcoded | `is_finance_manager` returns `'Y'` for one `EMPID`. A second approver needs a code change — see [§14](#14-how-to-make-common-changes) |
| Rate coverage | if rates exist only from one start date with an open end date, every earlier month reports `is_fallback: Y`. Expected; load monthly rates to remove it |
| Session lifetime | 12h session token, 1h access token, no refresh. Users re-login |
| Attachments | one per expense, 1 MB, restricted MIME types, stored as BLOB in `EXPENSES` |
| Three-button alerts on web | `window.confirm` offers two choices; a three-button `Alert` would lose its middle option. None currently used |
| Push notifications | Expo push; needs the EAS `projectId`. Changing Expo project requires new credentials. Not testable in Expo Go |
| Expense types | hardcoded in `src/constants/expenseTypes.js`, not in the database |

**Open items at handover**

| Item | Action |
|---|---|
| Dev `ORDS_PUBLIC_USER` locked (`ORA-28000`) | DBA must unlock and fix the profile ([§9.3](#93-dba-connection-pool-account)). Dev is unusable until then |
| Dev `PROCESS_EXPENSE_ACTION` / `GET_REVIEWER_ROLE` INVALID | re-run `PROD_1` section 2.1, then recompile — likely the `COMMENT`/`COMMENTS` mismatch ([§13.6](#136-the-approvals-comment-column)) |
| Missing handlers | `whoami` and `:id/accept` had templates with no handler on dev. Run the check in [§11.1](#111-structural) on **both** environments; `51_restore_missing_handlers.sql` fixes it |
| Wrong-password test | confirm S2 returns **401 on both environments** after the login fix |
| Credential rotation | a production password was exposed in plaintext during debugging and should be rotated. Rotating `SESSION_TOKEN_KEY` is optional and logs everyone out |
| Web build is stale | the currency picker, USD totals and the web alert/date fixes are in source but not in the deployed `gh-pages` bundle. Rebuild per [§10.4](#104-web-build-and-github-pages) |
| **Push notifications not enabled** | Devices register fine; the database cannot complete TLS to `exp.host` (`ORA-29024`). Needs a DBA wallet — `db/DBA_REQUEST_push_wallet.md`, then `db/55_push_wallet.sql`. **Not a launch blocker**; email and the in-app list cover the same events — [§10.6](#106-push-notification-credentials) |
| SMTP host may not be configured | Mail cannot leave the database until an APEX administrator sets `SMTP_HOST_ADDRESS`, and it needs a network ACL like `exp.host` did. `56_email_notifications.sql` section 4 reports whether it is set — [§6.5](#65-email-notifications) |
| No rate limiting on `auth/login` | the API is public, so password guessing against a known company email is unthrottled. Worth adding before the store launch — [§10.7](#107-releasing-to-the-app-store-and-play-store) |
| Store accounts not obtained | Apple Developer Program (D-U-N-S number, weeks) and Play Console. Start the Apple one first |

## 16. Handover checklist

**Deploying to a new environment**

- [ ] Collect every value in [§8](#8-prerequisites-and-values-to-collect)
- [ ] Confirm the assumed backfill currency before running on real data
- [ ] Run `db/MASTER_DEPLOY.sql` as the app schema
- [ ] `PROD_2b` sections 1–2: OAuth client, then seed all four `APP_SECRETS` rows
- [ ] DBA: network ACL **including the APEX engine schema**
- [ ] DBA: confirm `ORDS_PUBLIC_USER` is unlocked
- [ ] Set `<FINANCE_MANAGER_EMPID>` in `is_finance_manager`
- [ ] CORS script, if serving from a browser
- [ ] `db/HEALTH_CHECK.sql` — zero FAIL lines, every WARN read and understood
- [ ] Security tests S1–S7 — **S2 and S6 are not optional**
- [ ] Functional tests, including the INR direction check
- [ ] Point `API_BASE_URL` at the new environment, rebuild, redeploy

**Releasing to the App Store and Play Store** ([§10.7](#107-releasing-to-the-app-store-and-play-store))

- [x] Production API reachable from any network — confirmed, review unblocked
- [x] iOS route chosen: **private Custom App, redemption codes**
      ([§10.8](#108-walkthrough-launching-as-a-custom-app-ios--the-chosen-route))
- [ ] Confirm the ORDS host has a valid public TLS certificate
- [ ] Consider rate limiting `auth/login` — the API is public regardless of
      how the app is distributed
- [ ] Apple Developer Program (organisation, needs a D-U-N-S number)
- [ ] Apple Business Manager enrolment, and the **Organization ID**
- [ ] Decide the Android route ([§10.9](#109-android-distribution-options)) —
      private on Play needs an EMM, which Apple's route does not
- [x] Expo project owned by the `trinamix` organisation
- [x] `eas init` run — `extra.eas.projectId` present in `app.json`
- [ ] `eas credentials` — and record who holds the Android upload key
- [ ] Confirm `API_BASE_URL` points at production, then
      `eas build --profile production --platform all`
- [ ] Privacy policy URL, data-safety answers, screenshots, and a **working
      reviewer test account**
- [ ] Fill the three iOS placeholders in `eas.json`, then `eas submit`
- [ ] Promote from Play `internal` and release from TestFlight when ready

**Taking the project over**

- [ ] Read [§12 Fault dictionary](#12-fault-dictionary) and
      [§13 Design constraints](#13-design-constraints--do-not-simplify-these) —
      together they are most of the hard-won knowledge here
- [ ] Get access: the app schema, the APEX workspace, a DBA contact, the git
      repo, the Expo/EAS account
- [ ] Run the full flow yourself in a non-production environment
- [ ] Work through the open items in [§15](#15-known-limitations-and-open-items)
