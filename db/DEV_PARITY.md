# Bringing dev (HRMS) level with prod (REPO)

> **The environments, for the avoidance of doubt:**
>
> | | Host | Base path | Schema |
> |---|---|---|---|
> | prod | `karyasiddhi.trinamix.com` | `/ords/repo` | `REPO` |
> | dev | `karyasiddhi`**`test`**`.trinamix.com` | `/ords/repo` | `HRMS` |
>
> The base path is `repo` on both. On dev it is served by the `HRMS` schema.
> So a `/ords/repo` URL tells you nothing about which environment you are in --
> only the hostname does, and only four letters differ.
>
> **The app's `src/config.js` points at the DEV host.** That is deliberate
> while testing; it must be changed to `karyasiddhi.trinamix.com` before any
> release build, because `API_BASE_URL` is compiled into the bundle.

Dev has drifted behind. Everything below is what it takes to make it a usable
test environment.

**Much of it has since been done** — the multi-bill work (64-66, 68) and the
email work are on HRMS already, which is why the multi-bill scripts ran there
successfully. Treat the list below as a checklist to confirm rather than a
sequence to run blindly, and use `HEALTH_CHECK.sql` to see what is actually
missing.

---

## Where dev actually is

Evidence gathered from errors dev returned during this work. Several of these
have since been fixed by running MASTER_DEPLOY and the later scripts there:

| Missing / broken on HRMS | How we know |
|---|---|
| `ORDS_PUBLIC_USER` **locked** | `ORA-28000` — every endpoint returns 5xx, nothing works |
| `GET_PROJECT_MANAGER_EMPID` | "not there in hrms" |
| `EMP_PUSH_TOKENS`, `JSON_ESCAPE_STR` | `ORA-00942` running script 52 |
| `SEND_PUSH_NOTIFICATION` INVALID | `PLS-00905`, which blocks `PROCESS_EXPENSE_ACTION` compiling |
| `GET_REVIEWER_ROLE`, `PROCESS_EXPENSE_ACTION` INVALID | earlier `user_objects` check |
| Currency feature (45, 46, 48, 49) | unknown, assume absent |
| Email work (56–62) | never run there |
| Multi-bill (64, 65, 66, 68) | never run there |

So this is not a patch-up. It is a full deployment.

---

## Step 0 — the blocker

**A DBA must unlock the connection pool account.** Until then dev cannot serve
a single request and nothing below can be tested, only installed.

```sql
SELECT username, account_status, lock_date, expiry_date
FROM   dba_users WHERE username = 'ORDS_PUBLIC_USER';

ALTER USER ORDS_PUBLIC_USER ACCOUNT UNLOCK;
```

Also ask them to check `FAILED_LOGIN_ATTEMPTS` and `PASSWORD_LIFE_TIME` on its
profile, or it will lock itself again in a few weeks and this will repeat.

---

## Step 1 — collect dev's own values

**Do not copy prod's.** Three of these differ per environment and a wrong one
fails as something unrelated — see `DEPLOYMENT.md` §8.

| Value | Where from | Note |
|---|---|---|
| APEX workspace | `SELECT DISTINCT workspace_name FROM apex_workspace_apex_users;` | earlier output suggested `HRMSDEV` |
| OAuth client id / secret | `SELECT client_id, client_secret FROM user_ords_clients;` | after `PROD_2b` creates it |
| ORDS base path | `SELECT pattern FROM user_ords_schemas;` | goes in `API_BASE_URL` |
| APEX engine schema | `SELECT owner FROM dba_objects WHERE object_name='APEX_WEB_SERVICE';` | `APEX_260100` on prod |
| Finance manager EMPID | whoever it is on dev | may not be 3725 |

> A wrong workspace fails as **"Invalid email or password"** — indistinguishable
> from a genuinely wrong password. It has cost hours before.

---

## Step 2 — run these on HRMS, in order

**Use SQL Workshop → SQL Scripts, not SQL Commands.** SQL Commands silently
skipped a whole section of script 64 on prod and prompts for `:bind` variables
inside handler bodies.

| # | Script | Notes |
|---|---|---|
| 1 | `MASTER_DEPLOY.sql` | the whole base: tables, ORDS, business logic, endpoints, currency |
| 2 | `PROD_2b_oauth_and_network_acl.sql` §1–2 | OAuth client, then seed `APP_SECRETS` |
| 3 | `PROD_2b` §3 — **DBA** | network ACL, granted to the **APEX engine schema** |
| 4 | `EMAIL_DEPLOY.sql` | mail log, config, `send_expense_mail`, workflow, submit handler |
| 5 | `62_email_autonomous_read_fix.sql` | the uncommitted-read fix |
| 6 | `64_multibill_stage1_clean.sql` | **deletes all dev claims** — fine, they are test data |
| 7 | `65_multibill_stage2_items.sql` | six bill endpoints + privileges |
| 8 | `66_multibill_stage2_claims.sql` | claim header, submit rules |
| 9 | `68_multibill_list_fields.sql` | `mine` and `pending` field additions |
| 10 | `70_email_multibill.sql` | **not optional** — see below |
| 11 | `71_handlers_drop_legacy_columns.sql` | **not optional** — this is the 403 |
| 12 | `HEALTH_CHECK.sql` | **read-only** — should end with zero FAIL lines |

> **70 and 71 are the same bug in two places.** Script 64 dropped eight columns
> from `EXPENSES`. Everything written afterwards was produced by copying the old
> code and *adding* the new fields — adding, never removing. So six things went
> on referencing columns that no longer exist:
>
> | | Referenced | Fixed by |
> |---|---|---|
> | `SEND_EXPENSE_MAIL` | `e.bill_no` | 70 |
> | `GET /expenses/mine` | `bill_no, bill_date, type, description, attachment_filename` | 71 |
> | `GET /expenses/pending` | same | 71 |
> | `GET /expenses/:id` | same, plus all three `attachment_*` | 71 |
> | `POST /expenses/draft` | `INSERT ... description` | 71 |
> | `PUT /expenses/:id` | `UPDATE ... description` | 71 |
>
> Each is `ORA-00904` at runtime, which ORDS reports as **a bare 403 with no
> body**. That is the 403 on Home and Approvals. Roles and privilege patterns
> were correct the whole time; hours went into them anyway.
>
> `DEPLOYMENT.md` §12 already said a bodiless 403 means an invalid reference.
> The check that finds it in one step is to read the **handler's own source**
> and compare it against `user_tab_columns` — not to run a simplified version
> of the query, which only proves the columns you remembered to include exist.
>
> **Prod needs both**, for the opposite reason: section 3 of script 64 never ran
> there, so the columns survive, nothing 403s, and the faults are silent —
> reviewers have been getting approval emails with a blank bill number and no
> bill list at all.

Then set the finance manager for dev, if it differs:

```sql
-- get_finance_manager_empid is the ONLY place this id appears
CREATE OR REPLACE FUNCTION get_finance_manager_empid RETURN NUMBER IS
  c_finance_manager CONSTANT NUMBER := <dev empid>;
BEGIN
  RETURN c_finance_manager;
END get_finance_manager_empid;
/
```

Skip `13_cors_fix_for_web_testing.sql` unless you will test dev from a browser.

Skip 52–61: every one of those fixes is already folded into `EMAIL_DEPLOY.sql`
and `PROD_3`. Running them would just replay the same journey.

---

## Step 3 — point the app at dev

```javascript
// src/config.js
export const API_BASE_URL = 'https://<dev-host>/ords/<dev-base-path>';
```

This is the **only** environment-specific value in the app.

> **Change it back before building anything for release.** `API_BASE_URL` is
> compiled into the bundle — a store build aimed at dev can only be fixed with
> a new submission.

A safer habit, if you will be switching often: keep two lines and comment one
out, so the choice is visible in a diff rather than something you have to
remember.

---

## Step 4 — what to actually test

The multi-bill flow, which is what is new:

1. New claim → project + Claim For → **Add Bill** (proves the header is created
   transparently)
2. Bill in INR — rate and USD fill in read-only
3. Save with no receipt → row shows **NO RECEIPT**, Submit disabled
4. Second bill in another currency → claim total is the **USD sum**, not a
   mixed-currency number
5. Attach both receipts → Submit enables
6. Submit → 200, and the project manager gets an email listing both bills
7. Approve as manager → Finance gets the email
8. Approve as Finance → employee gets the approval email

Then the two things worth checking directly, because the UI cannot show them
being wrong:

```sql
-- The rollup: from_date/to_date should span BOTH bills, amount_usd is the sum
SELECT id, claim_for, from_date, to_date, amount, amount_usd FROM expenses;
SELECT item_no, type, currency, amount, exchange_rate, amount_usd
FROM   expense_items ORDER BY expense_id, item_no;

-- Mail: PUSHED means it left the database. FAILED carries the full stack.
SELECT created_at, event, status, mail_to, mail_cc, error_text
FROM   expense_mail_log ORDER BY id DESC FETCH FIRST 20 ROWS ONLY;
```

---

## Two things dev will not do

**Push notifications.** The Firebase credentials are attached to the build, and
a build points at one API at a time. Dev is realistically email-only.

**Email, unless dev has its own SMTP.** `EMAIL_DEPLOY.sql` §4 reports whether
`SMTP_HOST_ADDRESS` is set. If it is not, mail queues and never leaves, and
`EXPENSE_MAIL_LOG` will say `QUEUED` rather than `PUSHED`.

---

## Honest assessment

This is roughly half a day: ten scripts, a DBA for two of them, and a config
switch — plus the DBA unlock, which is the actual blocker and outside your
control.

**Is it worth it?** It is largely done. The remaining gap is the locked
`ORDS_PUBLIC_USER`, which is what stops dev serving requests at all, and that
is a DBA task outside your control. Everything else can be confirmed with
`HEALTH_CHECK.sql` in a few minutes.

The sensible sequencing is to raise the DBA unlock now, since it has a queue
time, and do the ten scripts while waiting for the Apple and Play accounts —
that dead time has to go somewhere.
