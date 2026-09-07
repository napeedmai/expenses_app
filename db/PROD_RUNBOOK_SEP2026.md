# Prod migration — September 2026

Prod is `REPO` @ `karyasiddhi.trinamix.com`. Dev is `HRMS` @ `karyasiddhitest`.

**Prod holds 1 draft claim, 0 approvals, 1 bill.** It is a pre-launch database,
not a live one. That is the single fact that makes this plan reasonable: there
is no in-flight work to protect, so the rename can go first and the dead columns
can go with it.

## What prod actually is right now

Established by running `PROD_STATE_SEP2026.sql`, not by assumption.

| | Prod |
|---|---|
| Module | `expenses.employee`, 22 templates, 28 handlers |
| Multi-bill | deployed (`EXPENSE_ITEMS`, `CLAIM_FOR` present) |
| Legacy columns | **all 8 still there** — script 64 §3 never ran |
| `CK_APPROVALS_ROLE` | **already correct** — script 81 not needed |
| Push | still present, and the submit handler still calls it |
| Script 62's fix | **absent** — see the warning below |
| AI scan / rate limiting | absent |
| `MAIL_WORKSPACE` | set, 4 chars — **not** `HRMSDEV` |
| `AI_SERVICE_STATIC_ID` | absent |

Two predictions I made that the database contradicted, recorded so nobody
re-derives them:

- I expected `CK_APPROVALS_ROLE` to be broken on prod as it was on dev. It is
  not. Prod's manager approval has always worked.
- I assumed prod's login handler matched dev's. It cannot — dev's hardcodes
  `SET_WORKSPACE('HRMSDEV')` and prod's workspace is a different 4-character
  name.

## ** Prod has script 62's bug right now **

`PROD_MIGRATE_AUG2026` carried scripts 69–77. It did not carry 62. So prod's
`:id/submit` handler does not pass `manager_empid` and `submitted_at` to
`send_expense_mail`, and that procedure is `AUTONOMOUS_TRANSACTION` — it re-reads
a row the handler has not committed, sees a draft with no manager, and emails
the employee to say no project manager is assigned.

Nobody has hit it because prod has never had a submission. **The first person to
submit a claim on prod would.** Script 84 fixes it on the way past.

## Order

Rename first, then features. The reason is not technical elegance: writing the
scan, login and `type_totals` work against prod's *old* names would mean every
feature existing in two variants, with the old-name variant used once and thrown
away. Only possible because prod is empty.

### Phase A — cleanup and rename

Run in this order. Everything from A2 onward is an outage; A2 to A5 must run back
to back, because between the rename and the handler rewrite every endpoint
returns a bare 403 with no body.

| # | Script | Notes |
|---|---|---|
| A1 | `84_drop_push.sql` | Also installs script 62's fix. Its guard now recognises prod's older handler as an upgrade rather than an unknown. |
| A2 | `67_multibill_stage5_cleanup.sql` | **Every drop is commented out on purpose.** Read §1, 3 and 4 first, then uncomment §5. Irreversible. |
| A3 | `85_rename_to_xxks_exp.sql` §1–4 only | **Do not run §5** — superseded. |
| A4 | `85b_rename_subprograms.sql` | Rebuilds subprograms; §3 gates on all of them compiling before anything is dropped. |
| A5 | `86_rename_handlers.sql` | Endpoint URIs and JSON field names unchanged. The API comes back here. |
| A6 | `87_who_columns.sql` | Now skips tables that do not exist — prod has no scan log or login attempts table yet. |

Smoke test before Phase B: log in, open Home, open a claim. Five minutes. If
login fails, it is the workspace — see below.

### Phase B — features, with the new names

Not yet written. Contents:

- scan log, `XXKS_EXP_SCAN_RECEIPT`, `scan-receipt` and `scan-outcome` endpoints
- `XXKS_EXP_LOGIN_ATTEMPTS` and `XXKS_EXP_LOGIN_RECORD` — audit only, **no**
  throttle ladder (removed in 89)
- `type_totals` on `mine` (script 82)
- the login handler from script 89: lock message, countdown, workspace from a
  secret, unlock on success

## Configuration prod needs

`APEX_WORKSPACE`, copied from `MAIL_WORKSPACE` so the value never has to be
typed or seen:

```sql
INSERT INTO app_secrets (secret_name, secret_value)
SELECT 'APEX_WORKSPACE', secret_value
FROM   app_secrets WHERE secret_name = 'MAIL_WORKSPACE'
AND    NOT EXISTS (SELECT 1 FROM app_secrets WHERE secret_name = 'APEX_WORKSPACE');
COMMIT;
```

Run this **before** Phase B installs the login handler that reads it. After the
rename the table is `XXKS_EXP_SECRETS`.

Also worth checking that prod's *current* login handler hardcodes the same
workspace `MAIL_WORKSPACE` holds — if it does not, one of the two is wrong and
that needs settling before the handler starts reading the secret.

## Privileges

`expenses.authenticated` protects 16 patterns on prod, `expenses.review` 4, and
`auth/login` is correctly in neither. `ORDS.DEFINE_PRIVILEGE` **replaces the
entire pattern set** — there is no call that adds one — so Phase B rebuilds it
from **prod's** 16 plus `/expenses/scan-receipt` and `/expenses/scan-outcome`.

Nothing is removed, `push-token` included: it becomes a 410 and costs nothing to
leave protected. Rebuilding from dev's list instead would silently drop whatever
prod protects that dev does not, and those endpoints would start returning 401.

## Known to ship inert

Receipt scanning will deploy and fail on prod. It needs an APEX AI service
created in prod's workspace and its id in `AI_SERVICE_STATIC_ID`, and the OpenAI
account behind dev is out of credit. Set expectations before anyone asks for a
demo.

## Still outstanding, not part of this

- `src/config.js` points at `karyasiddhitest`. Switch at launch, not before.
- The GitHub Pages bundle is stale.
- The login endpoint is public and nothing sees a password spray across many
  accounts — APEX's lock and everything we built key on the individual account.
  Per-IP limiting is the missing control. Decide before launch.
- Prod password rotation.
