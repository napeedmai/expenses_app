# Before this goes to real users

Written August 2026, after the GitHub Pages build started working. It works
because the CORS origin was added — but "it loads" and "it is ready" are not the
same thing, and the gap between them is mostly about the page now being on the
public internet.

---

## Blocking

### 1. The published page is pointed at DEV

```javascript
// src/config.js  — right now
export const API_BASE_URL = 'https://karyasiddhitest.trinamix.com/ords/repo';
```

`API_BASE_URL` is **compiled into the bundle**. Whatever it says at build time is
where every published copy talks, and a release build aimed at dev can only be
fixed with another release.

So today a public URL is reading and writing the dev database. Change it, rebuild,
redeploy:

```javascript
export const API_BASE_URL = 'https://karyasiddhi.trinamix.com/ords/repo';
```

Then check it actually took, because this is invisible from the UI:

- open the published page, DevTools → Network
- log in, and read the request host

### 2. `auth/login` has no rate limiting, and is now publicly reachable

Nothing in `db/` throttles, delays, counts failed attempts or locks an account.
That was survivable while the only way to reach the endpoint was from a machine
you controlled. A public page changes the exposure entirely:

- usernames are company email addresses, so they are not secret
- an attempt costs an attacker nothing and there is no ceiling on how many
- `APEX_UTIL.IS_LOGIN_PASSWORD_VALID` is doing the checking, and a wrong password
  currently costs exactly one round trip

The guard in `50_fix_login_null_bypass.sql` fixed *correctness* — a wrong password
no longer returns 200. It did nothing about *volume*.

At minimum, before launch: count failed attempts per email in a table, and refuse
after N within a window. A short server-side delay on failure is worth adding
alongside it — it barely affects a real person and makes bulk guessing expensive.

**This is the one I would not launch without.**

### 3. Rotate the production password that was exposed earlier

Still outstanding from July. It matters more once the endpoint it opens is
reachable from anywhere.

---

## Do before, not after

### Trim `localhost` out of the production origins

```sql
-- On REPO. Dev can keep its localhost entries.
BEGIN
  OAUTH.UPDATE_CLIENT(
    p_name            => 'EXPENSE_APP_CLIENT',
    p_origins_allowed => 'https://napeedmai.github.io',
    p_description     => NULL, p_redirect_uri  => NULL,
    p_support_email   => NULL, p_support_uri   => NULL,
    p_privilege_names => NULL);
  ORDS.SET_MODULE_ORIGINS_ALLOWED(
    p_module_name     => 'expenses.employee',
    p_origins_allowed => 'https://napeedmai.github.io');
  COMMIT;
END;
/
```

A `localhost` origin on production means a page running on any developer's
machine can call the production API. They would still need credentials, so this
is untidy rather than urgent — but it is the kind of untidy that survives for
years.

### Confirm the CORS change was made on REPO too

If it was only run on `HRMS`, the production web build fails exactly the same way
and it will look like a fresh bug.

```sql
SELECT name, origins_allowed FROM user_ords_clients;
SELECT name, origins_allowed FROM user_ords_modules WHERE name = 'expenses.employee';
```

### Decide whether the web build should be public at all

GitHub Pages has no access control. Anyone who finds the URL gets the login page.
That is normal for a web app and fine *if* item 2 is done — but it is worth a
deliberate decision rather than a default, given this is an internal tool for one
company. A private host, or Pages on a private repo, removes the whole question.

---

## Known, and shipping anyway unless you say otherwise

**Push notifications do not work on the web build.** No FCM token in a browser.
Email is the working notification path on web, and push remains blocked on the
Oracle TLS wallet for `exp.host` even on mobile.

**HomeScreen's spending-by-category chart files everything under "Other".** It
groups by a claim-level `type` that multi-bill removed. Needs a bill-level
aggregate — a product decision, not a patch, which is why it is still here.

**`expo-intent-launcher` is not installed.** `src/utils/openAttachment.js`
imports it. Opening an attachment on Android will fail until:

```
npx expo install expo-intent-launcher
```

**Receipt photos over 1 MB are scanned but not stored.** The person gets a clear
message and can attach a smaller one, but they will end up photographing some
receipts twice. Fixed properly by compressing client-side
(`expo-image-manipulator`) or by raising `c_max_bytes` in `db/65`.

**Nothing is committed to git.** Roughly twenty `db/` scripts, `DEPLOYMENT.md`,
`DEV_PARITY.md`, `PROD_MIGRATION.md`, `client.js`, `BillSheet.js`,
`AddEditExpenseScreen.js`, `app.json`. None of it is recoverable if the folder is
lost, and there is no way to see what changed between now and the last release.

---

---

# If it goes to the App Store and Play Store

## What gets easier

**CORS stops mattering.** A native app sends no `Origin` header and is not bound
by the browser's same-origin policy. The allowlist above is a web-build concern
only — nothing needs adding to it for iOS or Android.

## What gets harder, and by a lot

### You cannot hot-fix a store build. Today you cannot fix one at all.

```json
// app.json — right now
"runtimeVersion": null,
"updates": null
```

**EAS Update is not configured.** So every fix, including a one-line JavaScript
change, means a new build, a new submission and a review wait — Apple typically
a day or more, Play hours to days. The web build redeploys in minutes; that
difference is the main thing that changes about how you work.

Set up EAS Update before the first submission, not after:

```bash
npx expo install expo-updates
eas update:configure
```

Then `runtimeVersion` pins which native binary an update is compatible with, and
JS-only fixes ship the same day. Anything touching native code — a new
dependency, a permission, an SDK bump — still needs a full submission. Worth
knowing which is which before you need it in a hurry.

### An old build in someone's pocket is a client you cannot retire

This already bit us once. Multi-bill was a breaking API change: `GET
/expenses/mine` stopped returning `bill_no`, `type` and `description`, and any
build from before that rewrite breaks against today's server. On the web that is
fine — everyone loads the current bundle. On a phone, someone who does not update
keeps running last quarter's code against this quarter's API, and what they see
is an unexplained error.

So before launch the server needs to be able to say "that version is too old":

```sql
-- Config, not a literal, alongside MAIL_WORKSPACE and AI_SERVICE_STATIC_ID
INSERT INTO app_secrets (secret_name, secret_value)
VALUES ('MIN_APP_VERSION', '1.0.0');
```

The app sends its version — `expo-constants` gives
`Constants.expoConfig.version` — on login or `whoami`; the server compares and
returns a flag; the app shows a blocking "please update" screen with a store
link rather than failing somewhere confusing later.

It is perhaps an hour of work and it is the thing that makes future breaking
changes survivable. Without it, every server-side change has to stay compatible
with every build ever installed, forever.

### The login endpoint is exposed either way

Distribution does not protect the API. `API_BASE_URL` is readable in minutes from
any downloaded `.ipa` or `.apk`, and the endpoint answers anyone who calls it —
a store build changes nothing about that. Rate limiting is the same blocking item
as for web, for the same reason.

The iOS plan already helps with *who gets the app*: a private Custom App through
Apple Business Manager with redemption codes, rather than the public App Store.
Play needs the same decision — Managed Google Play private app, or public listing.
That controls distribution, not access.

## Store paperwork you do not have yet

**A privacy policy URL.** Mandatory on both stores. It must now cover the AI
feature: receipt images leave your database and go to OpenAI via the APEX
Generative AI service. That is a third-party disclosure and it has to be declared
truthfully in Play's Data Safety form and Apple's privacy labels. Worth writing
down exactly what is sent (the image), what is kept (nothing but a log row of the
extracted fields), and by whom.

**A demo account for Apple review.** A reviewer must be able to log in. Your
accounts come from `EMPLOYEEDETAILS`, so someone has to create a reviewer account
and put the credentials in App Store Connect.

**Account deletion** — Apple 5.1.1(v) requires in-app account deletion for apps
that support account *creation*. This app does not create accounts; HR does. That
usually exempts it, but be ready to explain that in review notes rather than be
surprised by a rejection.

**Back up the Android keystore.** EAS generated one. Lose it and you can never
update the Play listing again — you would have to publish a new app under a new
package name and ask everyone to reinstall. `eas credentials` will export it.

## One thing to fix before submitting, not after

```json
"permissions": ["android.permission.INTERNET", "android.permission.POST_NOTIFICATIONS"]
```

The app asks for notification permission and **push does not work** — still
blocked on the Oracle TLS wallet for `exp.host`. Shipping a permission prompt for
a feature that never delivers anything is a poor first impression and Play
reviewers do sometimes query unused permissions.

Either finish the wallet with the DBA first, or drop `POST_NOTIFICATIONS` and the
`expo-notifications` plugin from this release and add them back when push
actually works. The second is easily reversed; the first has been blocked since
July.

---

## The order I would do it in

1. Commit everything. Everything below risks making it worse first.
2. Rate limiting on `auth/login`, on dev, tested.
3. Rotate the prod password.
4. Point `config.js` at prod, rebuild, redeploy, **verify the host in DevTools**.
5. Trim the prod origins.
6. `npx expo install expo-intent-launcher`.
7. Then hand the URL to a handful of people before everyone.

Steps 2 and 4 are the ones that hurt if skipped. The rest can follow the first
real users.

**If the store release is happening too**, insert these before submitting —
every one of them is far more expensive to add after the app is in the wild:

1. `eas update:configure`, so a JavaScript fix does not need a review cycle
2. `MIN_APP_VERSION` and the "please update" screen
3. Decide on `POST_NOTIFICATIONS`: finish the wallet, or drop it this release
4. Privacy policy URL, and the data-safety declarations including OpenAI
5. Export and back up the Android keystore somewhere that is not one laptop

Item 2 is the one worth arguing for. Everything else on this list is work you
could do later at some cost; a released build with no version floor is a
constraint on every server change you make from then on.
