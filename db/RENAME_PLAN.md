# XXKS_EXP_ rename — plan and proposed map

**Status: provisional.** Nothing here is safe to run until `83_inventory_before_rename.sql`
comes back. That script is read-only and safe on prod.

## The constraint that shapes everything

HRMS is a **shared** schema. It holds this app, an unrelated resource-management
application, the company HR tables, and ~190 pre-existing invalid objects owned
by nobody in this conversation. So the rename works from an **explicit list**,
never from `SELECT * FROM user_objects`.

Never renamed — renaming these breaks the company's HR systems:

`EMPLOYEEDETAILS` · `PROJECTMASTER` · `PROJECT_ALLOCATION_WB` · `CURRENCY_CONVERSION`

Two more hard constraints:

- **No endpoint URI changes.** The app calls `/expenses/mine`, `/expenses/{id}` and
  the rest. A schema tidy-up that forces a mobile release is not a tidy-up.
- **No JSON field name changes.** Same reason — `client.js` reads those keys.

Only the objects *behind* the handlers change. The app needs no code change at all.

## Tables

| Now | Proposed | Rows | Who columns |
|---|---|---|---|
| `EXPENSES` | `XXKS_EXP_CLAIMS` | live | has all 4 |
| `EXPENSE_ITEMS` | `XXKS_EXP_ITEMS` | live | has all 4 |
| `EXPENSE_APPROVALS` | `XXKS_EXP_APPROVALS` | live | check §2 |
| `EXPENSE_MAIL_LOG` | `XXKS_EXP_MAIL_LOG` | live | **likely missing** |
| `EXPENSE_SCAN_LOG` | `XXKS_EXP_SCAN_LOG` | 0 (no OpenAI credit) | **likely missing** |
| `EXPENSE_LOGIN_ATTEMPTS` | `XXKS_EXP_LOGIN_ATTEMPTS` | live | **likely missing** |
| `APP_SECRETS` | `XXKS_EXP_SECRETS` | live | **likely missing** |

`APP_SECRETS` is the urgent one regardless of convention — it is a generic name
sitting in a schema three systems share, and it holds the mail workspace, the
OAuth client and the AI service id.

**One naming choice worth your override:** `EXPENSES` → `XXKS_EXP_CLAIMS`. The
header/line pair reads better as `CLAIMS`/`ITEMS`, and the PL/SQL already calls
it "the claim" everywhere. If you would rather keep the noun, it becomes
`XXKS_EXP_EXPENSES` and nothing else in this plan changes.

## Procedures and functions

Standalone, as you chose. Rule: prefix with `XXKS_EXP_`, drop a redundant
`EXPENSE_`, no abbreviating (Oracle allows 128 characters, so there is no reason
to make these harder to read).

| Now | Proposed |
|---|---|
| `PROCESS_EXPENSE_ACTION` | `XXKS_EXP_PROCESS_ACTION` |
| `SEND_EXPENSE_MAIL` | `XXKS_EXP_SEND_MAIL` |
| `RECALC_CLAIM_TOTALS` | `XXKS_EXP_RECALC_CLAIM_TOTALS` |
| `PRICE_EXPENSE_ITEM` | `XXKS_EXP_PRICE_ITEM` |
| `SCAN_RECEIPT` | `XXKS_EXP_SCAN_RECEIPT` |
| `EXPENSE_LOGIN_RECORD` | `XXKS_EXP_LOGIN_RECORD` |
| `EXPENSE_LOGIN_RETRY_AFTER` | `XXKS_EXP_LOGIN_RETRY_AFTER` |
| `GET_OAUTH_ACCESS_TOKEN` | `XXKS_EXP_GET_OAUTH_ACCESS_TOKEN` |
| `GENERATE_SESSION_TOKEN` | `XXKS_EXP_GENERATE_SESSION_TOKEN` |
| `IS_VALID_SESSION_TOKEN` | `XXKS_EXP_IS_VALID_SESSION_TOKEN` |
| `HMAC_SHA` | `XXKS_EXP_HMAC_SHA` |
| `JSON_ESCAPE_STR` | `XXKS_EXP_JSON_ESCAPE_STR` |
| `IS_ALLOWED_ATTACHMENT` | `XXKS_EXP_IS_ALLOWED_ATTACHMENT` |
| `CONVERT_TO_USD` | `XXKS_EXP_CONVERT_TO_USD` |
| `GET_EXCHANGE_RATE` | `XXKS_EXP_GET_EXCHANGE_RATE` |
| `GET_RATE_EFFECTIVE_DATE` | `XXKS_EXP_GET_RATE_EFFECTIVE_DATE` |
| `GET_FINANCE_MANAGER_EMPID` | `XXKS_EXP_GET_FINANCE_MGR_EMPID` |
| `GET_PROJECT_MANAGER_EMPID` | `XXKS_EXP_GET_PROJECT_MGR_EMPID` |
| `GET_REVIEWER_ROLE` | `XXKS_EXP_GET_REVIEWER_ROLE` |
| `IS_FINANCE_MANAGER` | `XXKS_EXP_IS_FINANCE_MANAGER` |
| `CAN_VIEW_CLAIM` | `XXKS_EXP_CAN_VIEW_CLAIM` |
| `CAN_EDIT_CLAIM` | `XXKS_EXP_CAN_EDIT_CLAIM` |

`HMAC_SHA`, `CONVERT_TO_USD` and `JSON_ESCAPE_STR` are the ones that most need
prefixing — those are names another team could plausibly create tomorrow, and
whoever creates the second one gets a compile error they will not understand.

## Indexes, constraints, triggers

EBS convention, since that is what `XXKS_` is:

- indexes — `XXKS_EXP_ITEMS_N1`, `_N2`, unique `_U1`
- primary keys — `XXKS_EXP_CLAIMS_PK`
- foreign keys — `XXKS_EXP_ITEMS_FK1`
- check constraints — keep the meaning: `XXKS_EXP_APPROVALS_CK_ROLE`
- triggers — `XXKS_EXP_CLAIMS_T1`

System-generated `SYS_C00…` names are NOT NULL checks. They cannot usefully be
renamed and do not need to be.

## Proposed drops — needs your approval

Confident:

| Object | Why |
|---|---|
| `EMP_PUSH_TOKENS` | push notifications were removed from the app entirely |
| `SEND_PUSH_NOTIFICATION` | same |
| `TEST_PUSH_NOTIFICATION` | same, and it was only ever a test harness |
| `src/pushNotifications.js` | client side of the same removal |

Needs a decision:

| Object | The question |
|---|---|
| `EXPENSES_PRE_CLEANUP` | The pre-multi-bill backup from script 64. It is your only copy of the old shape. Keep until you are certain, or drop now? |
| `TRG_COPY_PM_TO_EXPENSE` | **Not in the repo and never explained.** If it writes `MANAGER_EMPID`, it competes with the submit handler, which also writes it — and the last one wins. Its body needs reading before the rename, not after. |

Pending evidence — section 4 of the inventory decides these. Any subprogram with
zero handler references and zero PL/SQL callers is dead:

`GET_RATE_EFFECTIVE_DATE` · `JSON_ESCAPE_STR` · `IS_ALLOWED_ATTACHMENT` ·
`CAN_VIEW_CLAIM` · `CAN_EDIT_CLAIM`

## Order of work

1. Run `83` on dev **and** prod. Read section 6 first — anything outside the app
   that depends on the app's objects breaks the moment we rename, and it is
   owned by someone who does not know this is happening.
2. You approve the drop list.
3. `84` — drops (approved only).
4. `85` — the rename. Tables first, then indexes/constraints/triggers, then
   subprograms.
5. `86` — rewrite every ORDS handler against the new names. URIs and JSON fields
   unchanged. Handler parameters re-declared, because `DEFINE_HANDLER` drops them.
6. `87` — who columns on every table, with defaults and triggers so they are
   populated rather than merely present.
7. Verify: nothing invalid, no `user_errors`, every endpoint answers, a claim
   submits and approves, email sends.
8. Repeat on prod.

Steps 4 and 5 are one outage. Between the rename and the handler rewrite every
endpoint is broken, so they run back to back, not on different days.

## The risk worth naming

`ALTER TABLE … RENAME TO` keeps the data, the indexes, the constraints and the
triggers. What it does **not** do is fix the PL/SQL and ORDS handlers that name
the old table — those go INVALID, and an ORDS handler referencing an invalid
object returns a **bare 403 with no body**. That exact failure cost two days
earlier on this project.

So the rename is not risky because renaming is hard. It is risky because it
produces the single most confusing error this stack can produce, roughly thirty
times at once. Which is why step 5 is one script that rewrites every handler,
and why the verification runs the endpoints rather than reading the source.
