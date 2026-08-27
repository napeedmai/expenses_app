# Migrating the August 2026 fixes to production

> | | Host | Base path | Schema |
> |---|---|---|---|
> | prod | `karyasiddhi.trinamix.com` | `/ords/repo` | **`REPO`** |
> | dev | `karyasiddhi`**`test`**`.trinamix.com` | `/ords/repo` | `HRMS` |
>
> Four letters in the hostname are the only difference. **Check
> `SYS_CONTEXT('USERENV','CURRENT_SCHEMA')` before every script** — every one of
> them prints it, and every one refuses to run on the wrong shape.

---

## Read this first

**Prod is not dev with a different hostname.** Section 3 of
`64_multibill_stage1_clean.sql` never executed there — it was run through APEX
SQL *Commands*, which silently skipped it. So on `REPO` the eight legacy columns
still exist on `EXPENSES`:

```
BILL_NO  BILL_DATE  TYPE  DESCRIPTION
ATTACHMENT_BLOB  ATTACHMENT_FILENAME  ATTACHMENT_MIME_TYPE  ATTACHMENT_PATH
```

That is why prod has shown none of the symptoms dev did. **Every fault is
present; all of them are silent.** The handlers still compile because the
columns they name are still there — and they return and write values that
multi-bill stopped maintaining.

The one with a real consequence today:

> `SEND_EXPENSE_MAIL` reads `e.bill_no` and `e.type`. Since multi-bill those
> columns are never written. **Every approval email prod has sent since then has
> carried a blank bill number and no bill list at all** — a reviewer being asked
> to approve a total with nothing behind it.

So this migration is not optional tidying.

### It is a breaking API change

`GET /expenses/mine`, `pending` and `:id` stop returning `bill_no`, `bill_date`,
`type`, `description` and `attachment_filename`. **Any app build older than the
multi-bill rewrite will break.** Confirm nobody is running an old build before
you start, or plan the app release alongside this.

---

## Step 0 — Assess. Read-only, changes nothing.

Do not skip this. Prod may have lost templates the way dev did, and I do not
know whether it has.

```
db/VERIFY_MODULE.sql          on REPO
```

Write down four things:

| Section | What to record |
|---|---|
| 0 | template and handler counts — dev's healthy numbers are 21 / 26 |
| 1 | any template with no handler |
| 3 | any endpoint `** MISSING OR EMPTY **` |
| 4 | any pattern `** UNPROTECTED **` |

Those answers decide whether steps 4 and 7 below apply. **Section 2 will show
rows on prod** — that is expected, it is the fault this migration fixes.

Also confirm the backups from the original multi-bill run still exist:

```sql
SELECT table_name, num_rows FROM user_tables
WHERE  table_name LIKE '%PRE_MULTIBILL%';

SELECT COUNT(*) AS claims        FROM expenses;
SELECT COUNT(*) AS bills         FROM expense_items;
SELECT COUNT(*) AS approvals     FROM expense_approvals;
```

---

## Step 1 — Take a fresh snapshot

The `*_PRE_MULTIBILL` tables are from months ago. Nothing below deletes data,
but "nothing below deletes data" is worth ten minutes of insurance.

```sql
CREATE TABLE expenses_pre_aug2026          AS SELECT * FROM expenses;
CREATE TABLE expense_items_pre_aug2026     AS SELECT * FROM expense_items;
CREATE TABLE expense_approvals_pre_aug2026 AS SELECT * FROM expense_approvals;
```

The ORDS metadata cannot be snapshotted this way. Its backup is the scripts
themselves — which is precisely why every one of them is idempotent and lifts
handler bodies verbatim rather than retyping them.

---

## Step 2 — The scripts, in this order

**SQL Workshop → SQL Scripts. Not SQL Commands.** SQL Commands is what skipped
section 3 of script 64 and created this whole situation.

| # | Script | Why | Skip if |
|---|---|---|---|
| 1 | `70_email_multibill.sql` | `send_expense_mail` reads the bills; adds the bill table to both email bodies | never |
| 2 | `71_handlers_drop_legacy_columns.sql` | five handlers stop naming dropped columns | never |
| 3 | `75_exchange_rate_date_parse_fix.sql` | `on_date` accepts ISO and `MM/DD/YYYY` | never |
| 4 | `72_restore_currency_endpoints.sql` | recreates the `currencies` / `exchange-rate` templates | step 0 §3 showed both present |
| 5 | `73_restore_missing_handlers.sql` | reinstalls nine handlers | step 0 §1 was empty |
| 6 | `76_name_the_approvers_up_front.sql` | `my-projects` + `whoami` name both approvers | never |
| 7 | `77_retire_claim_attachment.sql` | `:id/attachment` answers 410 | step 0 §3 showed it missing entirely |
| 8 | `69_restore_privileges.sql` | rebuilds `expenses.authenticated` from an explicit list | step 0 §4 showed nothing unprotected |
| 9 | `VERIFY_MODULE.sql` | must end **PASS** | never |

**Do not run `74`.** 75 supersedes it and contains the same change done
correctly. 74 exists only because its header documents the original ORA-01843.

**Do not run `PROD_4_endpoints.sql`.** It holds the pre-multi-bill `mine`,
`pending`, `:id`, `draft` and `:id/submit`. `DEFINE_HANDLER` replaces the whole
handler, so it would undo steps 1–3. Script 73 refuses to run if it detects this
has happened.

**Do not run `MASTER_DEPLOY.sql`.** It calls `ORDS.DEFINE_MODULE`, which deletes
every template in the module. It now has a guard at the top that refuses on an
installed schema — but do not test that guard on production.

### Order matters in two places

- **70 before 71.** Not strictly required, but 70 recompiles
  `process_expense_action`, and doing that while the handlers are mid-change
  makes a failure harder to attribute.
- **73 before 76.** 73 installs `whoami` and `my-projects` from `PROD_4`; 76
  then adds the approver fields to them. The other way round, 73 silently
  reverts 76.

---

## Step 3 — Prove it with a real claim

The database being consistent is not the same as the app working.

1. Create a claim, pick a project, add **two bills in different currencies**
2. Attach both receipts → Submit enables
3. Submit → the project manager's email lists **both bills**, each in its own
   currency, with a USD total
4. Approve as the manager → Finance gets it
5. Approve as Finance → the employee gets the approval email

Step 3 is the one to check carefully. It is the case the old `send_expense_mail`
got wrong in every possible way, and the only one that proves 70 worked.

```sql
-- PUSHED means it left the database. FAILED carries the full stack.
SELECT created_at, event, status, mail_to, mail_cc, subject, error_text
FROM   expense_mail_log ORDER BY id DESC FETCH FIRST 20 ROWS ONLY;
```

---

## Step 4 — The app

`src/config.js` currently points at **dev**. `API_BASE_URL` is compiled into the
bundle, so a release build aimed at dev can only be fixed by another release.

```javascript
export const API_BASE_URL = 'https://karyasiddhi.trinamix.com/ords/repo';
```

Also outstanding on the client side:

- `npx expo install expo-intent-launcher` — required by
  `src/utils/openAttachment.js` and not yet installed
- delete `uploadAttachment()` and `getAttachmentUrl()` from `src/api/client.js`
  — dead code aimed at the retired endpoint, and the function
  `uploadItemAttachment()` was wrongly copied from
- **commit everything** — ~15 new `db/` scripts, `DEPLOYMENT.md`,
  `DEV_PARITY.md`, `client.js`, `AddEditExpenseScreen.js`, `app.json`. None of
  this is recoverable if the folder is lost.

---

## Not part of this migration

**`67_multibill_stage5_cleanup.sql`** drops the eight legacy columns from
`EXPENSES`. It is now safe to run — after steps 1–9, nothing references them —
but it is a one-way change and it is not needed for anything to work. Leave it
until the new flow has run in prod for a while. When you do run it, prod finally
matches dev and `VERIFY_MODULE.sql` §2 goes quiet permanently.

**HomeScreen's category breakdown** groups spending by a claim-level `type` that
no longer exists, so after step 2 every claim on prod will file under "Other".
This is a visible regression and it is not fixed here — it needs a bill-level
aggregate, which is a product decision, not a patch.

**Push notifications** remain blocked on the Oracle wallet for `exp.host`. Email
is the working notification path.

---

## If something goes wrong

Every script prints its schema, refuses to run on the wrong shape, and changes
nothing before its guards pass. If one fails partway:

1. **Read the message.** These scripts raise `-20001` with a sentence, not an
   `ORA-` code. The sentence names what is missing and what to run.
2. **Do not run the next script.** They assume the previous one succeeded.
3. **Run `VERIFY_MODULE.sql`.** It tells you what state you are actually in
   rather than what you expect.
4. A handler is recoverable — re-run its script. Data is recoverable from step 1.
   The only genuinely destructive thing in this repo is `DEFINE_MODULE`, and
   nothing in steps 1–9 calls it.

And the lesson that would have saved most of the last week: **when an endpoint
fails, read the response body before the status code.** A bodiless 403 from ORDS
almost never means permissions — it means the handler references something that
is INVALID or gone. Three of the four faults here were readable straight off the
response and were diagnosed from the status instead.
