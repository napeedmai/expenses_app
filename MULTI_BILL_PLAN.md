# Multiple bills per claim — design

One expense claim holds many bills, each with its own details and receipt.

Decisions taken (August 2026):

| Question | Decision |
|---|---|
| Structure | Bills in a child table under the existing `EXPENSES` row |
| Approval | Whole claim, all or nothing |
| Currency | Per bill; the claim total is the sum in USD |
| Existing data | Each existing expense becomes a one-bill claim |
| Cap | 20 bills per claim |
| Attachment | 1 MB per bill, **required to submit**, not to save a draft |
| Paid By | **dropped** — not captured |
| Claim For | free text |

---

## 1. What changes conceptually

**Today** one `EXPENSES` row *is* one bill: it carries the bill number, date,
type, amount and a single receipt, and the approval workflow hangs off it.

**After**, `EXPENSES` is the **claim** and `EXPENSE_ITEMS` holds the **bills**.

```
EXPENSES  (the claim -- keeps its id, workflow, approvals and audit trail)
  ├── emp_id, project_id, claim_for
  ├── status, current_stage, manager_empid, finance_manager_empid
  ├── from_date, to_date            <- now DERIVED: min/max across bills
  └── amount, amount_usd            <- now TOTALS, summed from bills
        │
        └── EXPENSE_ITEMS  (one row per bill, up to 20)
              ├── bill_no, bill_date, type, description
              ├── from_date, to_date
              ├── currency, amount, exchange_rate, amount_usd
              └── attachment_blob, filename, mime_type
```

Everything that makes this project risky to change stays put:
`EXPENSE_APPROVALS` still references the claim, `get_reviewer_role` and
`process_expense_action` are untouched, and the ORDS privileges keep their
existing patterns.

---

## 2. Fields

### Per claim

| Field | Column | Notes |
|---|---|---|
| Project | `project_id` | mandatory. Determines the reporting manager |
| Reporting Manager | — | **display only**, from `manager_empid`, resolved at submit |
| Manager (Finance) | — | **display only**, from `finance_manager_empid` |
| Claim For | `claim_for` **(new)** | mandatory. The purpose of the whole claim, e.g. "Client visit — Chennai" |
| Expense Details | — | the heading above the bill list, not a stored field |

"Claim For" is **free text** describing the whole claim ("Client visit —
Chennai"). Each bill separately has its own **Type**, from the existing
category list (Taxi, Hotel, …). Confirmed August 2026.

`from_date` and `to_date` **move to the bill**. The claim's own dates become
derived — `MIN(from_date)` and `MAX(to_date)` across its bills — because the
dashboard groups claims by month.

Which means the claim header no longer supplies a date or an amount at all, and
`EXPENSES.AMOUNT`, `FROM_DATE` and `TO_DATE` are `NOT NULL` today. They have to
become nullable, or creating a claim fails before the first bill exists. See §3.

### Per bill

All mandatory except **Bill No**.

| Field | Column | Mandatory | Notes |
|---|---|---|---|
| Bill No | `bill_no` | no | |
| Bill Date | `bill_date` | yes | |
| Type | `type` | yes | from the existing category list |
| Description | `description` | yes | |
| From Date | `from_date` | yes | **drives which month's exchange rate applies** |
| To Date | `to_date` | yes | must be ≥ From Date |
| Expense Currency | `currency` | yes | |
| Expense Amount | `amount` | yes | > 0, in that currency |
| Conversion Rate | `exchange_rate` | yes | **server-set, not typed** — see below |
| Amount | `amount_usd` | yes | **server-set** = amount × rate |
| Upload Receipt | `attachment_blob` | to submit | 1 MB, existing MIME whitelist |

> **Conversion Rate and Amount are computed, never accepted from the client.**
> They already work this way for single bills and it must stay that way: a
> client-supplied rate is a client-supplied reimbursement figure. The app shows
> both as read-only, from `GET /expenses/exchange-rate`, and the server
> recomputes on save from the stored currency, amount and the bill's
> `from_date`.

---

## 3. Schema

```sql
CREATE TABLE expense_items (
  id                    NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  expense_id            NUMBER        NOT NULL,
  item_no               NUMBER        NOT NULL,      -- display order, 1..20
  bill_no               VARCHAR2(100),               -- the only nullable input
  bill_date             DATE          NOT NULL,
  type                  VARCHAR2(100) NOT NULL,
  description           VARCHAR2(4000) NOT NULL,
  from_date             DATE          NOT NULL,
  to_date               DATE          NOT NULL,
  currency              VARCHAR2(3)   NOT NULL,
  amount                NUMBER(12,2)  NOT NULL,
  exchange_rate         NUMBER,                      -- see note
  amount_usd            NUMBER,                      -- see note
  attachment_blob       BLOB,                        -- required to submit
  attachment_filename   VARCHAR2(300),
  attachment_mime_type  VARCHAR2(150),
  creation_date         DATE DEFAULT SYSDATE NOT NULL,
  created_by            VARCHAR2(150),
  last_update_date      DATE DEFAULT SYSDATE NOT NULL,
  last_updated_by       VARCHAR2(150),
  CONSTRAINT ck_items_amount  CHECK (amount > 0),
  CONSTRAINT ck_items_dates   CHECK (to_date >= from_date),
  CONSTRAINT fk_items_expense FOREIGN KEY (expense_id)
    REFERENCES expenses(id) ON DELETE CASCADE
);

ALTER TABLE expenses ADD (claim_for VARCHAR2(400));

-- These three now belong to the BILLS, so a claim header cannot supply them.
-- Without this, POST /expenses/draft fails: all three are NOT NULL today.
ALTER TABLE expenses MODIFY (amount NULL, from_date NULL, to_date NULL);
```

The CHECK constraints need no change. An Oracle check is violated only when it
evaluates to FALSE, and both `ck_expenses_amount (amount > 0)` and
`ck_expenses_dates (to_date >= from_date)` evaluate to NULL — not FALSE — when
the column is null. They keep rejecting a zero amount or a reversed period
while permitting "not yet known".

`ON DELETE CASCADE` is deliberate: deleting a draft claim should take its bills
with it. Claims are never hard-deleted after submission, so no audit is lost.

`exchange_rate` and `amount_usd` are **nullable**, though every new bill always
gets both. Legacy rows are the reason: an expense created before the currency
feature, or one whose rate lookup found nothing, has no rate to migrate.
Declaring them `NOT NULL` would make the migration fail on exactly the oldest
data. Stage 2's endpoints always set them; the stage 1 verification lists any
that are null.

**`EXPENSES` keeps its bill columns** to hold totals and to let the migration
read them:

| Column | Before | After |
|---|---|---|
| `amount` | the bill amount | sum of bills, mixed currencies — display only |
| `amount_usd` | converted bill | **sum of bill `amount_usd`** — what the dashboard uses |
| `from_date`, `to_date` | the claim period | derived `MIN`/`MAX` across bills |
| `bill_no`, `bill_date`, `type`, `currency`, `exchange_rate` | the bill's | legacy; kept for old rows, no longer written |
| `attachment_*` | the receipt | legacy; migration copies it to bill 1 |

> `amount` as a sum of mixed currencies is not a meaningful number. It exists
> only so old reads do not break; `amount_usd` is the one to trust. Anything
> new should use `amount_usd`.

**`recalc_claim_totals(p_expense_id)`** recomputes the totals and derived dates,
and is called after any bill insert, update or delete. Deliberately not a
trigger: a trigger fires per row, so a five-bill save would recompute five
times, and mutating-table restrictions make it awkward to write correctly.

---

## 4. Validation: draft versus submit

The difference between the two is the whole answer to "when is a field
mandatory".

| Rule | Saving a bill | Submitting the claim |
|---|---|---|
| Bill Date, Type, Description, From/To Date, Currency, Amount | required | required |
| Bill No | optional | optional |
| Receipt attached | **not required** | **required on every bill** |
| At least one bill | not required | **required** |
| At most 20 bills | enforced | enforced |
| Claim: Project, Claim For | required | required |

So a draft can be parked mid-entry — the common case is typing the amounts and
then going to find the receipt photos — while nothing incomplete reaches a
reviewer. Submit returns **409** naming the bills that have no receipt, and the
app disables the button with the same message.

Enforced server-side in the submit handler, not only in the app. A client-side
check is a courtesy; the handler is the rule.

> **"Mandatory" has to mean mandatory at some moment.** A bill gets saved
> before it is finished — you type the amount, then go looking for the photo. So
> the check lives at Submit rather than at Save: bills save freely, the list
> marks any without a receipt, and Submit stays blocked until all of them have
> one. Finance still never sees a line without evidence; the employee can work
> in pieces.

### 4.1 Attaching the receipt before the bill is saved

The company's existing web app lets you pick a file before saving the row, and
we can do the same — it needs no new infrastructure, because **the app already
works this way today.**

What almost certainly happens on the web side: the browser holds the chosen
file, and on submit the whole form goes up together. In Oracle APEX
specifically, the upload lands in `APEX_APPLICATION_TEMP_FILES` and a page
process copies it into the real table afterwards. Either way nothing is
permanently stored until the row is.

Here, the same effect in two steps the user never sees:

1. Pick the receipt. It is held in app state and the row shows it as attached.
2. Tap Save. The app `POST`s the bill, gets back an `itemId`, then immediately
   `POST`s the file to `:id/items/:itemId/attachment`.

The existing single-bill screen already does exactly this for a brand-new
expense: it creates the draft, then uploads the attachment against the id it
just received. Nothing new is being invented.

**What this does not do:** if the app is killed between picking and saving, the
file is gone — the same as any unsaved form. Surviving that would need a
server-side staging table keyed by a client token, plus a cleanup job for
abandoned uploads, plus orphan rows to reason about. Not worth it for a 1 MB
receipt that takes two seconds to pick again.

The one visible consequence: a failed upload leaves a saved bill with no
receipt rather than losing the whole bill. That is the better failure — the
typing survives, the row shows the receipt is missing, and Submit stays blocked
until it is fixed.

---

## 5. Endpoints

New, all on the existing `expenses.employee` module:

| Method | Path | Purpose |
|---|---|---|
| GET | `:id/items` | list the bills |
| POST | `:id/items` | add a bill — computes rate and USD, recalcs totals, enforces the cap |
| PUT | `:id/items/:itemId` | edit a bill — recomputes rate and USD |
| DELETE | `:id/items/:itemId` | remove a bill, recalc totals |
| POST | `:id/items/:itemId/attachment` | upload that bill's receipt |
| GET | `:id/items/:itemId/attachment` | download it |

Changed:

- **`GET :id`** returns an `items` array, `claim_for`, and the totals.
- **`GET mine`** / **`GET pending`** gain `item_count`; still one row per claim.
- **`POST :id/submit`** enforces section 4.
- **`POST draft`** creates the claim header only.

Every new pattern must be added to the `expenses.authenticated` privilege — a
path no privilege matches is publicly accessible (`DEPLOYMENT.md` §13.2).

The existing `:id/attachment` endpoints stay, mapped to bill 1, so an app build
from before this change keeps working during rollout.

---

## 6. App

**`AddEditExpenseScreen`** becomes two parts:

- *Claim header* — Project, Claim For, and the read-only Reporting Manager and
  Manager (Finance).
- *Expense Details* — the bill list. Each row shows type, bill no, amount with
  currency, and a receipt indicator. Add / edit / remove, with a running USD
  total and a count out of 20.

Adding a bill opens a sheet with the eleven fields. Conversion Rate and Amount
are read-only and fill in from `GET /expenses/exchange-rate` as you type, which
is the behaviour the single-bill screen already has — that logic moves, it does
not change.

**`ReviewExpenseScreen`** lists every bill with its own View button. A reviewer
approving a large claim needs to see all of it, not the first receipt.

**`ExpenseListScreen` / `HomeScreen`** need only "3 bills" beside the total.

---

## 7. Email

The claim table gains a bill list above the total:

```
Bills:
  1. Taxi     BILL-2   99 INR      (1.04 USD)
  2. Hotel    BILL-7   4,500 INR  (47.15 USD)
  ---------------------------------------------
  Total                           48.19 USD
```

`send_expense_mail` already builds every row through one `add_row` helper, so
this is a loop over bills rather than a rewrite.

---

## 8. Order, and what breaks

| Stage | Contains | Breaks anything? | Status |
|---|---|---|---|
| 1 | Table, `claim_for`, migration, `recalc_claim_totals` | **No.** Nothing reads bills yet. Reversible | **built — `db/63_multibill_stage1_schema.sql`** |
| 2 | Item endpoints, claim reads return bills, submit validation | No. An old app ignores unknown fields |
| 3 | App screens | Old builds keep working via the legacy attachment path |
| 4 | Emails, health check, end-to-end verification | No |

Stage 1 can go to production immediately and sit there. Stage 3 is the first
point of no return, and by then the data has been in place and observable.

**Deploy stages 1 and 2 to REPO before building the app changes** — the reverse
order gives you an app calling endpoints that do not exist.

---

## 9. Migration

Each existing expense becomes a claim with exactly one bill:

```sql
INSERT INTO expense_items (
  expense_id, item_no, bill_no, bill_date, type, description,
  from_date, to_date, currency, amount, exchange_rate, amount_usd,
  attachment_blob, attachment_filename, attachment_mime_type)
SELECT e.id, 1, e.bill_no,
       NVL(e.bill_date, e.from_date),                    -- bill_date is NOT NULL now
       NVL(e.type, 'Other'),
       NVL(e.description, 'Migrated from single-bill claim'),
       e.from_date, e.to_date,
       NVL(e.currency, 'INR'),
       e.amount,
       NVL(e.exchange_rate, get_exchange_rate(NVL(e.currency,'INR'), e.from_date)),
       NVL(e.amount_usd,   convert_to_usd(e.amount, NVL(e.currency,'INR'), e.from_date)),
       e.attachment_blob, e.attachment_filename, e.attachment_mime_type
FROM   expenses e
WHERE  NOT EXISTS (SELECT 1 FROM expense_items i WHERE i.expense_id = e.id);
```

Re-runnable, and it **copies** the BLOB rather than moving it — the original
stays on the claim row, so stage 1 is reversible: drop `EXPENSE_ITEMS` and
nothing is lost.

> Two fields are invented for old rows because they are now `NOT NULL` and the
> data never captured them: `bill_date` falls back to the period start, and
> `description` gets a marker saying it was migrated. Both are visible as such
> rather than silently blank.

Verification: every expense has exactly one bill, and every bill's `amount` and
`amount_usd` match its parent.

---

## 10. Still open

Nothing blocking. Possible later additions, none of which change the schema
above:

| Idea | Note |
|---|---|
| Per-bill approve/reject | Rejected for now — whole-claim keeps the workflow untouched |
| Reviewer sees totals grouped by type | Useful for Finance; a read-only addition |
| Reinstate a "paid by" field | Dropped on request. Adding it later is one nullable column and one UI row |
| Relax the receipt requirement | Currently required at submit. One check in the submit handler if policy changes |
