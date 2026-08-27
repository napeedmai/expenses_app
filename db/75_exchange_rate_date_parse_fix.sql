--------------------------------------------------------------------------------
-- 75_exchange_rate_date_parse_fix.sql
--
-- Run as the APPLICATION SCHEMA, in SQL SCRIPTS. Idempotent.
-- SUPERSEDES 74_exchange_rate_iso_dates.sql -- run this instead of, or after,
-- that one. 74 is left in the repo only because its header explains the
-- original ORA-01843.
--
--   dev  = karyasiddhitest.trinamix.com, schema HRMS
--   prod = karyasiddhi.trinamix.com,     schema REPO
--
--
-- MY BUG IN 74
-- ------------
-- Script 74 replaced a single-format date parse with what was meant to be a
-- tolerant one:
--
--     TO_DATE(SUBSTR(:on_date,1,10), 'YYYY-MM-DD' DEFAULT NULL ON CONVERSION ERROR)
--
-- That is wrong. The DEFAULT ... ON CONVERSION ERROR clause belongs to
-- TO_DATE's FIRST argument, not to the format model:
--
--     TO_DATE(expr DEFAULT NULL ON CONVERSION ERROR, 'YYYY-MM-DD')   -- correct
--
-- Written the wrong way round it still compiles, and it returns NULL for
-- EVERY input. So '2026-08-25' -- an entirely valid ISO date -- fell through
-- both branches and produced:
--
--     Could not read on_date "2026-08-25". Use YYYY-MM-DD or MM/DD/YYYY.
--
-- I copied the idiom from the line immediately above it,
-- TO_NUMBER(:amount DEFAULT NULL ON CONVERSION ERROR), where the position
-- happens to be correct because TO_NUMBER was called with one argument. The
-- new error message then reported the bad parse convincingly enough to look
-- like a client problem rather than mine.
--
--
-- THE FIX, AND WHY NOT JUST MOVE THE CLAUSE
-- -----------------------------------------
-- Nested exception blocks instead:
--
--   * no dependency on a particular Oracle version or on getting an unusual
--     clause position right,
--   * cannot fail silently in the same way -- if TO_DATE raises, the handler
--     sees it,
--   * and it also catches a date that is well-FORMED but not REAL. '2026-13-45'
--     matches the ISO shape; DEFAULT ON CONVERSION ERROR would have quietly
--     returned NULL for it too, but so would a correct implementation, and here
--     it is explicit that both cases end in the same 400.
--
-- Everything else is byte-for-byte from 74, which was byte-for-byte from 48:
-- rate_month, is_fallback, the amount/amount_usd pair, the parameter-naming
-- error message.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF


--------------------------------------------------------------------------------
-- 0. Prove the point before changing anything.
--
-- This is the whole bug in four rows. Run it and read it -- it is worth seeing
-- once, because the wrong form gives no error at all.
--------------------------------------------------------------------------------
SELECT 'wrong: clause on the FORMAT'  AS variant,
       TO_DATE('2026-08-25', 'YYYY-MM-DD' DEFAULT NULL ON CONVERSION ERROR) AS result
FROM   dual
UNION ALL
SELECT 'right: clause on the VALUE',
       TO_DATE('2026-08-25' DEFAULT NULL ON CONVERSION ERROR, 'YYYY-MM-DD')
FROM   dual
UNION ALL
SELECT 'right, and genuinely bad input',
       TO_DATE('21-08-2026' DEFAULT NULL ON CONVERSION ERROR, 'YYYY-MM-DD')
FROM   dual
UNION ALL
SELECT 'plain TO_DATE, valid ISO',
       TO_DATE('2026-08-25', 'YYYY-MM-DD')
FROM   dual;
-- Row 1 NULL is the bug. Rows 2 and 4 must show 25-AUG-26. Row 3 NULL is
-- correct behaviour.


--------------------------------------------------------------------------------
-- 1. Prerequisites.
--------------------------------------------------------------------------------
DECLARE
  l_n NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Connected as: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
  DBMS_OUTPUT.PUT_LINE('  HRMS = dev, REPO = PRODUCTION.');

  SELECT COUNT(*) INTO l_n
  FROM   user_ords_templates t
  JOIN   user_ords_modules m ON m.id = t.module_id
  WHERE  m.name = 'expenses.employee' AND t.uri_template = 'exchange-rate';

  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'No exchange-rate template here. Run 72_restore_currency_endpoints.sql '
      || 'first. Nothing changed.');
  END IF;

  SELECT COUNT(*) INTO l_n FROM user_objects
  WHERE  object_name IN ('GET_EXCHANGE_RATE','GET_RATE_EFFECTIVE_DATE')
  AND    object_type = 'FUNCTION' AND status = 'VALID';

  IF l_n < 2 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'get_exchange_rate / get_rate_effective_date are not both VALID here. '
      || 'Nothing changed.');
  END IF;

  DBMS_OUTPUT.PUT_LINE('Prerequisites OK.');
END;
/


--------------------------------------------------------------------------------
-- 2. GET /expenses/exchange-rate  --  date parsing that actually works.
--------------------------------------------------------------------------------

BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'exchange-rate',
    p_method      => 'GET',
    p_source_type => ords.source_type_plsql,
    p_source      => q'[
      DECLARE
        l_emp_id   NUMBER := TO_NUMBER(:emp_id_hdr);
        l_currency VARCHAR2(3) := UPPER(:currency);
        l_on_date  DATE;
        l_rate     NUMBER;
        l_eff      DATE;
        l_amount   NUMBER := TO_NUMBER(:amount DEFAULT NULL ON CONVERSION ERROR);
      BEGIN
        IF is_valid_session_token(l_emp_id, :session_token_hdr) != 'Y' THEN
          :status := 401;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Session expired or invalid. Please log in again.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        IF l_currency IS NULL THEN
          :status := 400;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'Missing "currency" query parameter.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        -- ACCEPT BOTH DATE FORMATS.
        --
        -- This endpoint was written before multi-bill and only ever parsed
        -- MM/DD/YYYY. Every endpoint added since speaks ISO, and BillSheet.js
        -- calls it through isoFromMDY() -- so it was sending '2026-08-21',
        -- Oracle read '2026' as a month, and the screen showed the user
        -- "ORA-01843: not a valid month". A client/server format mismatch
        -- reported as a database error, which is the least useful form it
        -- could possibly take.
        --
        -- This is FORMAT-ONLY detection, not guesswork: '2026-08-21' cannot be
        -- MM/DD/YYYY and '08/21/2026' cannot be ISO, so there is no ambiguous
        -- case to get wrong. Both are accepted rather than picking one, because
        -- the app is not the only possible caller and a date parameter that
        -- rejects the format half the codebase uses is a trap.
        IF :on_date IS NULL THEN
          l_on_date := SYSDATE;
        ELSE
          -- Try ISO, then MM/DD/YYYY, using nested exception blocks.
          --
          -- Script 74 tried to do this by hanging a DEFAULT-ON-CONVERSION-ERROR
          -- clause off TO_DATE's FORMAT argument, which is wrong -- the clause
          -- belongs to TO_DATE's FIRST
          -- argument, not to the format model. Written that way it still
          -- compiles and it returns NULL for EVERY input, so a perfectly good
          -- '2026-08-25' came back as "could not read on_date". The idiom was
          -- copied from the TO_NUMBER(:amount DEFAULT ...) line above, where
          -- the position happens to be right.
          --
          -- Doing it with exception blocks instead of fixing the placement:
          -- it needs no particular Oracle version, it cannot be got subtly
          -- wrong in the same way, and it also catches a well-formed date that
          -- is not a real one -- '2026-13-45' matches the ISO shape and is
          -- still not a date.
          --
          -- SUBSTR so an ISO value carrying a time component still parses.
          BEGIN
            l_on_date := TO_DATE(SUBSTR(:on_date, 1, 10), 'YYYY-MM-DD');
          EXCEPTION
            WHEN OTHERS THEN
              BEGIN
                l_on_date := TO_DATE(:on_date, 'MM/DD/YYYY');
              EXCEPTION
                WHEN OTHERS THEN
                  l_on_date := NULL;
              END;
          END;

          IF l_on_date IS NULL THEN
            :status := 400;
            APEX_JSON.OPEN_OBJECT;
            APEX_JSON.WRITE('error',
              'Could not read on_date "' || :on_date
              || '". Use YYYY-MM-DD or MM/DD/YYYY.');
            APEX_JSON.CLOSE_OBJECT;
            RETURN;
          END IF;
        END IF;

        l_rate := get_exchange_rate(l_currency, l_on_date);
        l_eff  := get_rate_effective_date(l_currency, l_on_date);

        IF l_rate IS NULL THEN
          :status := 404;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', 'No exchange rate on file for ' || l_currency || '.');
          APEX_JSON.CLOSE_OBJECT;
          RETURN;
        END IF;

        :status := 200;
        APEX_JSON.OPEN_OBJECT;
        APEX_JSON.WRITE('currency',        l_currency);
        APEX_JSON.WRITE('on_date',         TO_CHAR(l_on_date, 'MM/DD/YYYY'));
        APEX_JSON.WRITE('requested_month', TO_CHAR(TRUNC(l_on_date, 'MM'), 'MON-YYYY'));
        APEX_JSON.WRITE('rate_month',      TO_CHAR(l_eff, 'MON-YYYY'));
        APEX_JSON.WRITE('is_fallback',
          CASE WHEN TRUNC(l_eff, 'MM') = TRUNC(l_on_date, 'MM') THEN 'N' ELSE 'Y' END);
        APEX_JSON.WRITE('exchange_rate',   l_rate);
        APEX_JSON.WRITE('inverse_rate',    ROUND(1 / l_rate, 6));
        IF l_amount IS NOT NULL THEN
          APEX_JSON.WRITE('amount',     l_amount);
          APEX_JSON.WRITE('amount_usd', ROUND(l_amount * l_rate, 2));
        END IF;
        APEX_JSON.CLOSE_OBJECT;
      EXCEPTION
        WHEN OTHERS THEN
          -- Name the parameters. A bare SQLERRM sent an Oracle date-format
          -- error to a person filling in a bill, with nothing to connect it to
          -- the field that caused it.
          :status := 400;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error',
            'Could not price ' || NVL(:currency, '(no currency)')
            || ' on ' || NVL(:on_date, 'today') || ': ' || SQLERRM);
          APEX_JSON.CLOSE_OBJECT;
      END;
    ]'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'exchange-rate', p_method => 'GET',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'exchange-rate', p_method => 'GET',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'exchange-rate', p_method => 'GET',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status',
    p_source_type => 'HEADER', p_access_method => 'OUT');

  COMMIT;
END;
/
--------------------------------------------------------------------------------
-- 3. Verify the handler took, and that the broken form is gone.
--------------------------------------------------------------------------------
SELECT t.uri_template, h.method, h.source_type,
       (SELECT COUNT(*) FROM user_ords_parameters pa WHERE pa.handler_id = h.id) AS params,
       CASE WHEN INSTR(h.source, 'TO_DATE(SUBSTR(:on_date, 1, 10), ''YYYY-MM-DD'')') > 0
            THEN 'Y' ELSE 'N' END AS iso_parse_ok,
       CASE WHEN INSTR(h.source, 'TO_DATE(:on_date, ''MM/DD/YYYY'')') > 0
            THEN 'Y' ELSE 'N' END AS mdy_parse_ok,
       CASE WHEN INSTR(h.source, 'get_rate_effective_date') > 0
            THEN 'Y' ELSE 'N' END AS has_rate_month
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee' AND t.uri_template = 'exchange-rate';
-- Expect one row: GET, plsql/block, 3, Y, Y, Y.


-- The broken construct must not appear anywhere in the module. MUST RETURN
-- NO ROWS. Worth keeping as a habit: this is a mistake that compiles.
SELECT t.uri_template, h.method
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee'
AND    REGEXP_LIKE(h.source, '''\s*DEFAULT\s+NULL\s+ON\s+CONVERSION\s+ERROR', 'i');
-- i.e. a DEFAULT clause following a quoted format string rather than a value.


--------------------------------------------------------------------------------
-- 4. Then in the app.
--
--   Open a bill, pick a currency, type an amount.
--   Conversion Rate and Amount fill in, read-only.
--
-- If it fails again, the message now names the currency and the date it was
-- given. Send that message rather than the status code -- three of the last
-- four faults here were diagnosable from the response body and were instead
-- diagnosed from the status, which cost hours each time.
--
-- Expect rate_month = SEP-2025 and is_fallback = 'Y' on dev: the rate table
-- stops at 30-Sep-2025. That is script 48 being honest about which month it
-- used, not a fault.
--
--
-- WHERE THIS SITS IN THE SEQUENCE
--
--   71  handlers stop selecting the eight dropped columns      -> fixes the 403
--   72  currencies + exchange-rate templates restored          -> fixes the 555
--   73  the nine missing handlers restored                     -> fixes empty LOVs
--   74  exchange-rate accepts ISO                              -> superseded, see below
--   75  ...and the parse in 74 actually works                  -> this file
--
-- 74 and 75 should really be one script. They are separate because 74 was
-- already run, and a file whose header describes a bug it does not contain is
-- worse than two files. If you are deploying to prod from scratch, run 75 and
-- skip 74 entirely.
--------------------------------------------------------------------------------
