# Database scripts

Everything needed to stand up the Expense App backend.
Read `../DEPLOYMENT.md` first — it explains the values you need, the DBA
tasks, the verification steps, and the fault dictionary.

---

## Fresh environment

Run **`MASTER_DEPLOY.sql`** as the application schema. It concatenates the
eight scripts below in dependency order and is safe to re-run.

Three things it deliberately cannot do, and login fails without them:

1. **OAuth client + `APP_SECRETS`** — `PROD_2b_oauth_and_network_acl.sql`
   sections 1–2, then seed `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET` and
   `OAUTH_TOKEN_URL`.
2. **Network ACL** — `PROD_2b` section 3, run by a DBA, granted to the
   **APEX engine schema** (not just the app schema). See `DEPLOYMENT.md`
   §5.1; granting only the app schema does not work.
3. **`is_finance_manager`** — still returns `'Y'` for one hardcoded
   `EMPID`. Set it for this environment.

> Before running on a schema with real data: part 5 backfills every existing
> expense with an **assumed currency** and computes `amount_usd` from it.
> Irreversible. Check `c_assumed_currency` first.

---

## Files

### Included in `MASTER_DEPLOY.sql`

| Order | File | Creates |
|---|---|---|
| 1 | `PROD_1_schema.sql` | `EXPENSES`, `EXPENSE_APPROVALS`, `EMP_PUSH_TOKENS`, `APP_SECRETS`, session signing key, and the `COMMENT`→`COMMENTS` repair (§2.1) |
| 2 | `PROD_2_ords_and_security_setup.sql` | ORDS roles, privileges, pattern mappings |
| 3 | `PROD_3_business_logic.sql` | Session tokens, OAuth fetch, approval workflow, push |
| 4 | `PROD_4_endpoints.sql` | All ORDS modules, templates, handlers, parameters |
| 5 | `45_currency_conversion.sql` | Currency columns, `get_exchange_rate`, `convert_to_usd`, backfill |
| 6 | `46_currency_endpoints.sql` | `/currencies`, `/exchange-rate`, currency-aware save |
| 7 | `48_rate_month_truthfulness.sql` | `get_rate_effective_date`, honest fallback reporting |
| 8 | `49_usd_identity.sql` | USD as `1` in code rather than a data row |

Parts 6–8 intentionally replace objects and handlers defined earlier in the
file. Later definitions win.

### Run separately

| File | When |
|---|---|
| `PROD_2b_oauth_and_network_acl.sql` | Always — OAuth client (app schema) and network ACL (DBA) |
| `HEALTH_CHECK.sql` | After deploying, and any time something breaks. Read-only |
| `13_cors_fix_for_web_testing.sql` | Only if serving the app from a browser. Native apps aren't subject to CORS |

`HEALTH_CHECK.sql` is read-only and safe on production during business
hours. Run it as the app schema with `SET SERVEROUTPUT ON`; it prints
PASS/FAIL/WARN for tables, columns, PL/SQL objects, secrets, every handler,
the login guard, privilege coverage and the currency direction, with the fix
for each failure. Run it on **both** environments — most of the trouble in
this project came from the two drifting apart.

### Remediation — existing environments only

Not needed for a fresh install; each fixes a specific defect found in a
deployed environment.

| File | Fixes |
|---|---|
| `47_align_role_names.sql` | ORDS role named differently between environments |
| `50_fix_login_null_bypass.sql` | Authentication bypass — **already folded into `PROD_4`** |
| `51_restore_missing_handlers.sql` | Templates registered with no handler (`whoami`, `:id/accept`) |

---

## The one thing not to skip

`50_fix_login_null_bypass.sql` corrects a live authentication bypass: any
valid username with **any password** received a session.

`APEX_UTIL.IS_LOGIN_PASSWORD_VALID` returns **NULL**, not `FALSE`, for a
wrong password. In PL/SQL `NOT NULL` is NULL, and an `IF` only branches on
TRUE — so the rejection was skipped entirely and execution fell through to
the success path:

```sql
IF NOT l_valid THEN ...            -- WRONG: never fires on NULL
IF NVL(l_valid, FALSE) = FALSE THEN  -- correct
```

It hides well: `CASE WHEN l_valid THEN 'Y' ELSE 'N' END` renders NULL as
`'N'`, so the endpoint reported the password as invalid *and issued a token
in the same response*.

`PROD_4_endpoints.sql` now carries the fixed guard, so a fresh deployment is
safe. **Verify it anyway** — test S2 in `DEPLOYMENT.md` §6.2, twice, with a
manually built header and Postman's auth type set to "No Auth". Postman's
Basic Auth tab retains the last good password and will hide the failure.

---

## After deploying

Work through `DEPLOYMENT.md` §6. The three checks that catch the most:

```sql
-- 1. Nothing INVALID. A handler referencing an INVALID object fails with a
--    bare 403 or 555 and no body -- it looks like a permissions problem.
SELECT object_name, object_type, status FROM user_objects WHERE status = 'INVALID';

-- 2. No template without a handler -- that is a URL that does nothing.
SELECT t.uri_template, COUNT(h.id) AS handlers
FROM   user_ords_templates t
JOIN   user_ords_modules m ON m.id = t.module_id
LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
WHERE  m.name = 'expenses.employee'
GROUP  BY t.uri_template ORDER BY handlers;

-- 3. Must return no rows. A wildcard also matches /expenses/auth/login and
--    makes logging in impossible: you would need a token to get a token.
SELECT pm.pattern FROM user_ords_privilege_mappings pm
WHERE  pm.pattern LIKE '/expenses/%*%' OR pm.pattern = '/expenses/*';

-- 4. Must return exactly COMMENTS. process_expense_action inserts into
--    COMMENTS; if the column is still named COMMENT the procedure stays
--    INVALID and every approval fails with a bare 403/555.
SELECT column_name FROM user_tab_columns
WHERE  table_name = 'EXPENSE_APPROVALS' AND column_name LIKE 'COMMENT%';
```

Then the HTTP tests — S1–S7 and the functional set. The INR conversion check
matters: getting the direction backwards turns a ₹1,000 taxi fare into an
$88,648 expense, and nothing else would flag it.
