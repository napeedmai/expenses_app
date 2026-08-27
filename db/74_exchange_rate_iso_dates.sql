--------------------------------------------------------------------------------
-- 74_exchange_rate_iso_dates.sql
--
-- Run as the APPLICATION SCHEMA, in SQL SCRIPTS. Idempotent.
--
--   dev  = karyasiddhitest.trinamix.com, schema HRMS
--   prod = karyasiddhi.trinamix.com,     schema REPO
--
--
-- ORA-01843 ON THE CONVERSION RATE
-- --------------------------------
-- GET /expenses/exchange-rate parsed its on_date parameter with exactly one
-- format:
--
--     l_on_date := TO_DATE(:on_date, 'MM/DD/YYYY');
--
-- BillSheet.js calls it through isoFromMDY(), so it sends '2026-08-21'. Oracle
-- read 2026 as the month and raised ORA-01843, which the handler's WHEN OTHERS
-- passed straight through as SQLERRM -- so a person filling in a bill was shown
-- a raw Oracle date-format error with nothing tying it to a field.
--
-- MY MISTAKE, and a predictable one. The endpoint predates multi-bill and dates
-- from when the whole API spoke MM/DD/YYYY. Every endpoint added since speaks
-- ISO on writes -- the item endpoints, draft, PUT :id -- and when I wrote
-- BillSheet I reached for isoFromMDY() because that is what its neighbours
-- wanted, without checking that this older one disagreed. Two conventions in
-- one API and no test that crosses them.
--
--
-- THE FIX
-- -------
-- Accept BOTH formats, and fail with a sentence instead of an ORA- code.
--
-- Accepting both rather than picking one, because this is FORMAT-ONLY detection
-- with no ambiguous case: '2026-08-21' cannot be MM/DD/YYYY and '08/21/2026'
-- cannot be ISO. There is nothing to guess wrong. And a date parameter that
-- rejects the format half the codebase uses is a trap that would be stepped in
-- again.
--
-- Also: the reads still RETURN MM/DD/YYYY. That asymmetry -- ISO in, MM/DD/YYYY
-- out -- is deliberate and documented in client.js (isoFromMDY / mdyFromISO
-- exist for exactly this), but it is the reason the mismatch was easy to make.
-- Worth a look when there is time to change both ends at once.
--
-- Nothing else in the handler changes. The body is lifted from
-- 48_rate_month_truthfulness.sql, not retyped, so rate_month, is_fallback and
-- the amount/amount_usd pair are byte-for-byte what they were.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF


--------------------------------------------------------------------------------
-- 0. Prerequisites: the template must exist and the functions must be VALID.
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
      'No exchange-rate template on ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
      || '. Run 72_restore_currency_endpoints.sql first. Nothing changed.');
  END IF;

  SELECT COUNT(*) INTO l_n FROM user_objects
  WHERE  object_name IN ('GET_EXCHANGE_RATE','GET_RATE_EFFECTIVE_DATE')
  AND    object_type = 'FUNCTION' AND status = 'VALID';

  IF l_n < 2 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'get_exchange_rate / get_rate_effective_date are not both VALID here. '
      || 'Run 45, 48, 49 first. Nothing changed.');
  END IF;

  DBMS_OUTPUT.PUT_LINE('Prerequisites OK.');
END;
/


--------------------------------------------------------------------------------
-- 1. GET /expenses/exchange-rate  --  tolerant date parsing.
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
          -- SUBSTR so an ISO value carrying a time component still parses.
          l_on_date := TO_DATE(SUBSTR(:on_date, 1, 10), 'YYYY-MM-DD'
                               DEFAULT NULL ON CONVERSION ERROR);

          IF l_on_date IS NULL THEN
            l_on_date := TO_DATE(:on_date, 'MM/DD/YYYY'
                                 DEFAULT NULL ON CONVERSION ERROR);
          END IF;

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
-- 2. Verify the handler took.
--------------------------------------------------------------------------------
SELECT t.uri_template, h.method, h.source_type,
       (SELECT COUNT(*) FROM user_ords_parameters pa WHERE pa.handler_id = h.id) AS params,
       CASE WHEN INSTR(h.source, 'YYYY-MM-DD') > 0 THEN 'Y' ELSE 'N' END AS accepts_iso,
       CASE WHEN INSTR(h.source, 'MM/DD/YYYY') > 0 THEN 'Y' ELSE 'N' END AS accepts_mdy,
       CASE WHEN INSTR(h.source, 'get_rate_effective_date') > 0 THEN 'Y' ELSE 'N' END AS has_rate_month
FROM   user_ords_handlers h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules m   ON m.id = t.module_id
WHERE  m.name = 'expenses.employee' AND t.uri_template = 'exchange-rate';
-- Expect one row: GET, plsql/block, 3 params, Y, Y, Y.


--------------------------------------------------------------------------------
-- 3. Prove the parsing directly, before going near the app.
--
-- These call the same functions the handler calls, with both formats, so a
-- failure here is the function and a failure in the app is the handler.
--------------------------------------------------------------------------------
SELECT 'ISO'        AS format,
       TO_DATE('2026-08-21', 'YYYY-MM-DD') AS parsed,
       get_exchange_rate('INR', TO_DATE('2026-08-21','YYYY-MM-DD'))       AS rate,
       TO_CHAR(get_rate_effective_date('INR', TO_DATE('2026-08-21','YYYY-MM-DD')),
               'MON-YYYY')                                                AS rate_month
FROM   dual
UNION ALL
SELECT 'MM/DD/YYYY',
       TO_DATE('08/21/2026', 'MM/DD/YYYY'),
       get_exchange_rate('INR', TO_DATE('08/21/2026','MM/DD/YYYY')),
       TO_CHAR(get_rate_effective_date('INR', TO_DATE('08/21/2026','MM/DD/YYYY')),
               'MON-YYYY')
FROM   dual;
-- Both rows must show the same rate and the same rate_month. On dev that month
-- will be SEP-2025, because the rate table stops there -- so is_fallback comes
-- back 'Y' and that is the truth, not a fault.

-- And the format the parser must REJECT rather than misread.
SELECT TO_DATE(SUBSTR('21-08-2026',1,10), 'YYYY-MM-DD' DEFAULT NULL ON CONVERSION ERROR) AS as_iso,
       TO_DATE('21-08-2026', 'MM/DD/YYYY' DEFAULT NULL ON CONVERSION ERROR)              AS as_mdy
FROM   dual;
-- Both NULL -> the handler answers 400 with a readable message. That is the
-- intended behaviour: it does not try to be clever about DD-MM-YYYY.


--------------------------------------------------------------------------------
-- 4. Then in the app: open a bill, pick a currency, type an amount.
--
-- Conversion Rate and Amount should fill in read-only. BillSheet debounces at
-- 400ms and re-fetches whenever currency, amount or FROM DATE changes -- so a
-- July bill and an August bill in the same claim can legitimately price at
-- different rates. That is by design; see MULTI_BILL_PLAN.md.
--
-- If it still fails, read the message rather than the status code -- the
-- handler now names the currency and the date it was given, which is enough to
-- tell a bad parameter from a missing rate.
--
--
-- NO APP CHANGE IS NEEDED. BillSheet.js keeps sending ISO through isoFromMDY(),
-- which is right: ISO is what every endpoint written since multi-bill expects,
-- and this one now agrees with them.
--
--
-- WORTH DOING WHEN THERE IS TIME
--
-- The API is inconsistent in a way that made this mistake easy: writes take
-- ISO, reads return MM/DD/YYYY. client.js carries isoFromMDY() and mdyFromISO()
-- to bridge it, which works but means every new call site has to know which
-- side it is on. One format, both directions, would delete both helpers and
-- this whole class of bug with them. It touches every handler and every screen,
-- so it is not a change to make in the middle of testing.
--------------------------------------------------------------------------------
