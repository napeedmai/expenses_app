--------------------------------------------------------------------------------
-- 48_rate_month_truthfulness.sql
--
-- Run as HRMS, then REPO. Requires 45 and 46 already applied.
--
-- THE BUG
-- -------
-- GET /expenses/exchange-rate reported rate_month as the month of the date
-- you asked about, regardless of which rate row was actually used. Ask for
-- June 2026, get no June rate, silently fall back to the October 2025 open
-- rate - and the screen still said "JUN-2026 rate".
--
-- The number was right. The label was a lie. An approver reading
-- "JUN-2026 rate" would reasonably assume a June rate existed.
--
-- THE FIX
-- -------
-- get_rate_effective_date() mirrors get_exchange_rate()'s selection logic
-- exactly and returns the EFFECTIVE_START_DATE of the row that was actually
-- chosen. The endpoint now reports that month, plus a flag saying whether
-- the fallback was used, so the UI can say so out loud.
--
-- The two functions must stay in step. If the lookup rule in
-- get_exchange_rate ever changes, change it here too - section 4 asserts
-- they agree, and fails the deployment if they drift.
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- 1. Which rate row does get_exchange_rate actually pick?
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_rate_effective_date(
  p_currency IN VARCHAR2,
  p_date     IN DATE DEFAULT SYSDATE
) RETURN DATE IS
  l_eff        DATE;
  l_month_from DATE;
  l_month_to   DATE;
BEGIN
  IF p_currency IS NULL THEN
    RETURN NULL;
  END IF;

  l_month_from := TRUNC(NVL(p_date, SYSDATE), 'MM');
  l_month_to   := LAST_DAY(l_month_from);

  -- (a) window overlapping the requested month - same ORDER BY as
  --     get_exchange_rate, so the same row wins.
  BEGIN
    SELECT effective_start_date INTO l_eff
    FROM (
      SELECT effective_start_date
      FROM   currency_conversion
      WHERE  UPPER(from_curr) = UPPER(p_currency)
        AND  UPPER(to_curr)   = 'USD'
        AND  effective_start_date <= l_month_to
        AND  (effective_end_date IS NULL OR effective_end_date >= l_month_from)
      ORDER  BY effective_start_date DESC, conversion_id DESC
    )
    WHERE ROWNUM = 1;

    RETURN l_eff;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN NULL;
  END;

  -- (b) fallback: the current open rate.
  BEGIN
    SELECT effective_start_date INTO l_eff
    FROM (
      SELECT effective_start_date
      FROM   currency_conversion
      WHERE  UPPER(from_curr) = UPPER(p_currency)
        AND  UPPER(to_curr)   = 'USD'
        AND  effective_end_date IS NULL
      ORDER  BY effective_start_date DESC, conversion_id DESC
    )
    WHERE ROWNUM = 1;

    RETURN l_eff;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;
  END;
END get_rate_effective_date;
/


--------------------------------------------------------------------------------
-- 2. GET /expenses/exchange-rate - now tells the truth about the rate month.
--
--    New/changed fields:
--      rate_month     month of the rate ACTUALLY used (was: month requested)
--      requested_month  month asked about, so the UI can compare
--      is_fallback    'Y' when no rate covers the requested month
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

        l_on_date := CASE
                       WHEN :on_date IS NULL THEN SYSDATE
                       ELSE TO_DATE(:on_date, 'MM/DD/YYYY')
                     END;

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
          :status := 400;
          APEX_JSON.OPEN_OBJECT;
          APEX_JSON.WRITE('error', SQLERRM);
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
-- 3. Verify against real data.
--
--    For every currency: today should NOT be a fallback (there is an open
--    rate), and a date far in the future SHOULD be, since no row covers it.
--------------------------------------------------------------------------------
SELECT c.from_curr,
       TO_CHAR(TRUNC(SYSDATE,'MM'), 'MON-YYYY')                        AS asked_now,
       TO_CHAR(get_rate_effective_date(c.from_curr, SYSDATE),'MON-YYYY') AS used_now,
       TO_CHAR(get_rate_effective_date(c.from_curr, DATE '2026-06-15'),'MON-YYYY') AS used_for_jun_2026,
       CASE WHEN TRUNC(get_rate_effective_date(c.from_curr, DATE '2026-06-15'),'MM')
                 = DATE '2026-06-01'
            THEN 'N' ELSE 'Y' END                                      AS jun_is_fallback
FROM   (SELECT DISTINCT from_curr
        FROM   currency_conversion
        WHERE  UPPER(to_curr) = 'USD') c
ORDER  BY c.from_curr;


--------------------------------------------------------------------------------
-- 4. Self-test: the two functions must select the SAME row.
--
--    Compares the rate returned by get_exchange_rate against the rate on the
--    row get_rate_effective_date points at, across every currency and a
--    spread of dates. Raises if they ever disagree - that would mean the
--    displayed month belongs to a different row than the number.
--------------------------------------------------------------------------------
DECLARE
  l_rate      NUMBER;
  l_eff       DATE;
  l_rate_at   NUMBER;
  l_checked   PLS_INTEGER := 0;
BEGIN
  FOR c IN (SELECT DISTINCT from_curr
            FROM   currency_conversion
            WHERE  UPPER(to_curr) = 'USD')
  LOOP
    FOR d IN (SELECT DATE '2024-03-15' AS dt FROM dual
              UNION ALL SELECT DATE '2025-10-15' FROM dual
              UNION ALL SELECT SYSDATE FROM dual
              UNION ALL SELECT DATE '2026-06-15' FROM dual
              UNION ALL SELECT DATE '2030-01-15' FROM dual)
    LOOP
      l_rate := get_exchange_rate(c.from_curr, d.dt);
      l_eff  := get_rate_effective_date(c.from_curr, d.dt);

      IF l_rate IS NULL AND l_eff IS NULL THEN
        CONTINUE;  -- currency genuinely absent; both agree
      END IF;

      IF l_rate IS NULL OR l_eff IS NULL THEN
        RAISE_APPLICATION_ERROR(-20095,
          'Disagreement for ' || c.from_curr || ' on ' || TO_CHAR(d.dt,'MM/DD/YYYY') ||
          ': one function returned NULL and the other did not.');
      END IF;

      SELECT MAX(exchange_rate) INTO l_rate_at
      FROM   currency_conversion
      WHERE  UPPER(from_curr) = UPPER(c.from_curr)
        AND  UPPER(to_curr)   = 'USD'
        AND  effective_start_date = l_eff;

      IF l_rate_at IS NULL OR l_rate_at != l_rate THEN
        RAISE_APPLICATION_ERROR(-20096,
          'Row mismatch for ' || c.from_curr || ' on ' || TO_CHAR(d.dt,'MM/DD/YYYY') ||
          ': get_exchange_rate gave ' || l_rate ||
          ' but the row dated ' || TO_CHAR(l_eff,'MM/DD/YYYY') || ' holds ' || l_rate_at ||
          '. The two lookups have drifted apart.');
      END IF;

      l_checked := l_checked + 1;
    END LOOP;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('OK: ' || l_checked || ' currency/date combinations agree.');
END;
/


--------------------------------------------------------------------------------
-- 5. Then test from Postman:
--
--   GET /expenses/exchange-rate?currency=INR&on_date=06/15/2026&amount=1000
--     -> requested_month JUN-2026
--        rate_month      OCT-2025      (the rate actually applied)
--        is_fallback     Y
--
--   GET /expenses/exchange-rate?currency=INR&on_date=10/15/2025&amount=1000
--     -> requested_month OCT-2025
--        rate_month      OCT-2025
--        is_fallback     N
--
-- The point: is_fallback = Y means "no rate on file for that month, this is
-- the current rate instead." The user should be able to see that.
--------------------------------------------------------------------------------
