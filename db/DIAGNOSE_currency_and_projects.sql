--------------------------------------------------------------------------------
-- DIAGNOSE_currency_and_projects.sql
--
-- READ-ONLY. Changes nothing. Run as the APPLICATION SCHEMA, in SQL Scripts.
--
--   dev  = karyasiddhitest.trinamix.com, schema HRMS
--   prod = karyasiddhi.trinamix.com,     schema REPO
--
-- Four symptoms, and what each one actually depends on. Written as a script
-- rather than answered by guesswork, because the last two rounds of guessing
-- cost hours and the handler source told the truth in one query both times.
--
--   1. 555 on /expenses/exchange-rate
--        -> get_exchange_rate, get_rate_effective_date  (scripts 45, 48, 49)
--      A 555 is ORDS failing to run the handler at all. This handler has its
--      own EXCEPTION block, so a runtime error would come back as 400 with a
--      message -- a 555 means it never got that far, which points at a MISSING
--      or INVALID function rather than bad input. get_rate_effective_date is
--      the prime suspect: it is created by script 48, which DEV_PARITY.md lists
--      as never having run on HRMS.
--
--   2. Only INR in the currency list
--        -> rows in CURRENCY_CONVERSION, plus the USD identity from script 49
--      CURRENCY_CONVERSION is a PRE-EXISTING COMPANY TABLE -- nothing in this
--      project creates or populates it. If dev's copy holds only INR->USD rows,
--      that is dev data and no script here can fix it.
--      USD is separate: it is not a row in that table, it is a special case
--      script 49 adds to get_exchange_rate (1 USD = 1 USD). Without 49, USD
--      returns NULL, the handler's own filter drops it, and you get INR alone.
--
--   3. Empty project list
--        -> PROJECT_ALLOCATION_WB and PROJECTMASTER, both company tables
--      The handler wants an allocation row for this employee, not ended, on a
--      project whose STATUS = 'ACTIVE'. Any one of those three failing gives an
--      empty list with no error. Again: dev data, not code.
--
--   4. Reporting Manager and Manager (Finance) blank
--        -> EXPECTED on a new claim. See the note at the bottom -- there is a
--           real naming problem here, but not a bug.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

PROMPT ============ 0. WHERE AM I ============

SELECT SYS_CONTEXT('USERENV','CURRENT_SCHEMA') AS schema_name,
       CASE SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
            WHEN 'HRMS' THEN 'DEV  (karyasiddhitest)'
            WHEN 'REPO' THEN 'PRODUCTION  (karyasiddhi)'
            ELSE 'unrecognised -- check before changing anything'
       END AS environment
FROM   dual;


PROMPT ============ 1. THE CURRENCY FUNCTIONS ============

-- Anything MISSING or INVALID here explains the 555.
SELECT f.fn AS expected_function,
       NVL((SELECT o.status FROM user_objects o
            WHERE o.object_name = f.fn AND o.object_type = 'FUNCTION'),
           '** MISSING **') AS status,
       f.created_by_script
FROM   (SELECT 'GET_EXCHANGE_RATE'       AS fn, '45, replaced by 49' AS created_by_script FROM dual
        UNION ALL SELECT 'GET_RATE_EFFECTIVE_DATE', '48, replaced by 49'  FROM dual
        UNION ALL SELECT 'CONVERT_TO_USD',          '45'                  FROM dual) f;

-- If any is INVALID, this says why.
SELECT name, type, line, position, text
FROM   user_errors
WHERE  name IN ('GET_EXCHANGE_RATE','GET_RATE_EFFECTIVE_DATE','CONVERT_TO_USD')
ORDER  BY name, line;


PROMPT ============ 2. THE RATE DATA ============

-- Is the company table even visible from this schema?
SELECT COUNT(*) AS currency_conversion_visible
FROM   all_tables
WHERE  table_name = 'CURRENCY_CONVERSION'
AND    owner IN (SYS_CONTEXT('USERENV','CURRENT_SCHEMA'), 'HRMS', 'REPO');

-- Which currencies dev actually has rates for, and how recent they are.
-- This is the answer to "only INR is showing".
SELECT UPPER(from_curr)   AS currency,
       COUNT(*)           AS rate_rows,
       MIN(effective_date) AS earliest,
       MAX(effective_date) AS latest
FROM   currency_conversion
WHERE  UPPER(to_curr) = 'USD'
GROUP  BY UPPER(from_curr)
ORDER  BY 1;

-- What the handler itself would return. If USD is absent from this list,
-- script 49 has not run here.
SELECT c.currency,
       get_exchange_rate(c.currency, SYSDATE) AS rate_today
FROM   (SELECT DISTINCT from_curr AS currency FROM currency_conversion
        WHERE  UPPER(to_curr) = 'USD' AND UPPER(from_curr) != 'USD'
        UNION  SELECT 'USD' FROM dual) c
ORDER  BY c.currency;


PROMPT ============ 3. THE PROJECT LIST ============

-- Substitute the empid you are logged in as.
DEFINE emp = 3725

-- 3a. Does this employee have ANY allocation row at all?
SELECT COUNT(*) AS allocation_rows_any
FROM   project_allocation_wb
WHERE  emp_id = &emp;

-- 3b. The handler's exact three conditions, one column each, so you can see
--     WHICH one is eliminating the rows rather than guessing.
SELECT pa.project_id,
       pm.project_name,
       pa.res_end_date,
       CASE WHEN pa.res_end_date IS NULL OR pa.res_end_date >= TRUNC(SYSDATE)
            THEN 'ok' ELSE 'ENDED -- excluded' END        AS allocation_current,
       pm.status,
       CASE WHEN pm.status = 'ACTIVE'
            THEN 'ok' ELSE 'NOT ACTIVE -- excluded' END   AS project_active,
       -- The project manager lives in its own table, PROJECT_MANAGER, keyed on
       -- P_ID -- not on PROJECTMASTER. get_project_manager_empid takes the
       -- earliest row by creation_date, sr_no.
       get_project_manager_empid(pa.project_id)           AS project_manager_empid
FROM   project_allocation_wb pa
LEFT   JOIN projectmaster pm ON pm.project_id = pa.project_id
WHERE  pa.emp_id = &emp
ORDER  BY pm.project_name;

-- 3c. And what the endpoint would actually return. Empty here with rows in 3b
--     means one of the two filters above is the cause.
SELECT DISTINCT pa.project_id, pm.project_name
FROM   project_allocation_wb pa
JOIN   projectmaster pm ON pm.project_id = pa.project_id
WHERE  pa.emp_id = &emp
AND   (pa.res_end_date IS NULL OR pa.res_end_date >= TRUNC(SYSDATE))
AND    pm.status = 'ACTIVE'
ORDER  BY pm.project_name;

-- 3d. If 3a is 0: does this employee exist on dev under the email you logged
--     in with? Dev is a different database with different people in it.
SELECT empid, first_name, last_name, company_email, status
FROM   employeedetails
WHERE  empid = &emp;


PROMPT ============ 4. THE TWO MANAGER FIELDS ============

-- Blank on a NEW claim is correct: manager_empid is resolved from the PROJECT
-- at submit, and no project is chosen yet. But check the finance manager id is
-- someone who exists on DEV -- it is hardcoded, and dev's people differ.
SELECT get_finance_manager_empid() AS configured_finance_empid,
       (SELECT first_name || ' ' || last_name || '  <' || company_email || '>'
        FROM   employeedetails
        WHERE  empid = get_finance_manager_empid())
         AS resolves_to;
-- resolves_to NULL means the id is a prod employee who does not exist on dev,
-- and every claim will submit with no finance manager. Fix by redefining
-- get_finance_manager_empid -- it is the only place the id appears.

-- Which of THIS employee's projects have no manager? A claim on one of these
-- cannot be approved at the first stage, and the submit email says so.
SELECT DISTINCT pm.project_id, pm.project_name,
       get_project_manager_empid(pm.project_id) AS pm_empid,
       (SELECT first_name || ' ' || last_name FROM employeedetails
        WHERE  empid = get_project_manager_empid(pm.project_id)) AS pm_name
FROM   project_allocation_wb pa
JOIN   projectmaster pm ON pm.project_id = pa.project_id
WHERE  pa.emp_id = &emp
AND    pm.status = 'ACTIVE'
ORDER  BY pm.project_name;
-- pm_empid NULL means PROJECT_MANAGER has no row for that project on dev.


PROMPT ============ 5. WHICH CURRENCY SCRIPTS HAVE RUN ============

-- Script 48 replaced the exchange-rate handler; 49 replaced the currencies
-- handler. Their fingerprints are visible in the live handler source.
SELECT t.uri_template, h.method,
       CASE WHEN INSTR(h.source, 'get_rate_effective_date') > 0
            THEN 'Y -- 48 ran' ELSE 'N -- 48 has NOT run' END AS has_48,
       CASE WHEN INSTR(h.source, 'rate_month') > 0
            THEN 'Y' ELSE 'N' END AS returns_rate_month
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND    t.uri_template IN ('exchange-rate','currencies')
ORDER  BY t.uri_template;


--------------------------------------------------------------------------------
-- WHAT TO DO WITH THE ANSWERS
--------------------------------------------------------------------------------
--
-- Section 1 shows a MISSING function
--   Run, on HRMS, in SQL Scripts, in this order -- all idempotent:
--       45_currency_conversion.sql
--       46_currency_endpoints.sql
--       48_rate_month_truthfulness.sql
--       49_usd_identity.sql
--
--   *** DO NOT run MASTER_DEPLOY.sql to get these. *** It calls
--   ORDS.DEFINE_MODULE, and re-running that WIPES EVERY TEMPLATE in the
--   module -- including the multi-bill endpoints from 65/66 and the fixes in
--   70/71. Run the four scripts individually.
--
-- Section 2 shows only INR, and USD missing
--   The missing USD is script 49. The missing EUR/GBP/etc is dev's copy of
--   CURRENCY_CONVERSION having no rows for them, which no script here can
--   change -- that table belongs to the company's own system. Either ask for
--   dev's rates to be loaded, or accept testing in INR and USD only. Testing
--   the mixed-currency path needs at least two, so INR + USD is enough.
--
-- Section 3 returns nothing at 3a
--   The employee has no project allocation on DEV. Nothing in this codebase
--   can fix that; someone has to allocate them, or you test as an employee
--   who already is. This is the likeliest single cause of the empty LOV.
--
-- Section 4 resolves_to is NULL
--   get_finance_manager_empid returns a prod empid. Redefine it for dev --
--   DEV_PARITY.md Step 2 has the statement.
--------------------------------------------------------------------------------
