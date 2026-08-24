--------------------------------------------------------------------------------
-- 49_usd_identity.sql
--
-- Run as HRMS and REPO. Requires 45, 46 and 48 already applied.
--
-- PURPOSE
-- -------
-- Treat USD -> USD as an identity in code rather than as a row in
-- CURRENCY_CONVERSION.
--
-- WHY NOT JUST INSERT A ROW
-- -------------------------
-- A USD->USD row is not an exchange rate; it is arithmetic. Storing it
-- invites someone to maintain it like the others - a monthly refresh job
-- writing 0.9998, an end date closing it off, a typo - and every dollar
-- expense in the system silently changes value. Encoding 1 in code makes
-- that impossible.
--
-- WHAT CHANGES
--   get_exchange_rate       returns 1 for USD, before touching the table
--   get_rate_effective_date returns the requested month for USD, so USD is
--                           never reported as a fallback
--   GET /expenses/currencies includes USD even though it has no row
--
-- If a USD row already exists it is now ignored, not deleted - deleting
-- data is not this script's business. Section 5 tells you if one is there.
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- 1. Rate lookup: USD is 1, always.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_exchange_rate(
  p_currency IN VARCHAR2,
  p_date     IN DATE DEFAULT SYSDATE
) RETURN NUMBER IS
  l_rate       NUMBER;
  l_month_from DATE;
  l_month_to   DATE;
BEGIN
  IF p_currency IS NULL THEN
    RETURN NULL;
  END IF;

  -- USD -> USD is arithmetic, not a rate. Short-circuit before the table so
  -- no data can ever make a dollar worth something other than a dollar.
  IF UPPER(p_currency) = 'USD' THEN
    RETURN 1;
  END IF;

  l_month_from := TRUNC(NVL(p_date, SYSDATE), 'MM');
  l_month_to   := LAST_DAY(l_month_from);

  -- (a) a row whose effective window overlaps that month
  BEGIN
    SELECT exchange_rate INTO l_rate
    FROM (
      SELECT exchange_rate
      FROM   currency_conversion
      WHERE  UPPER(from_curr) = UPPER(p_currency)
        AND  UPPER(to_curr)   = 'USD'
        AND  effective_start_date <= l_month_to
        AND  (effective_end_date IS NULL OR effective_end_date >= l_month_from)
      ORDER  BY effective_start_date DESC, conversion_id DESC
    )
    WHERE ROWNUM = 1;

    RETURN l_rate;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN NULL;
  END;

  -- (b) fallback: the current open rate
  BEGIN
    SELECT exchange_rate INTO l_rate
    FROM (
      SELECT exchange_rate
      FROM   currency_conversion
      WHERE  UPPER(from_curr) = UPPER(p_currency)
        AND  UPPER(to_curr)   = 'USD'
        AND  effective_end_date IS NULL
      ORDER  BY effective_start_date DESC, conversion_id DESC
    )
    WHERE ROWNUM = 1;

    RETURN l_rate;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;
  END;
END get_exchange_rate;
/


--------------------------------------------------------------------------------
-- 2. Effective date: USD belongs to whatever month you asked about, so it is
--    never reported as a fallback. Anything else would have the UI warning
--    "no rate loaded for JUN-2026" about dollars, which is nonsense.
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

  IF UPPER(p_currency) = 'USD' THEN
    RETURN l_month_from;
  END IF;

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
-- 3. GET /expenses/currencies - USD has no row, so add it explicitly.
--
--    Without this the dropdown cannot offer USD at all, and a user with a
--    dollar receipt has nothing correct to pick.
--------------------------------------------------------------------------------
BEGIN
  ORDS.DEFINE_HANDLER(
    p_module_name => 'expenses.employee',
    p_pattern     => 'currencies',
    p_method      => 'GET',
    p_source_type => ords.source_type_collection_feed,
    p_source      => q'[
      SELECT c.currency,
             get_exchange_rate(c.currency, SYSDATE)                      AS exchange_rate,
             ROUND(1 / get_exchange_rate(c.currency, SYSDATE), 6)        AS inverse_rate
      FROM   (SELECT DISTINCT from_curr AS currency
              FROM   currency_conversion
              WHERE  UPPER(to_curr) = 'USD'
                AND  UPPER(from_curr) != 'USD'
              UNION
              SELECT 'USD' FROM dual) c
      WHERE  is_valid_session_token(TO_NUMBER(:emp_id_hdr), :session_token_hdr) = 'Y'
      AND    get_exchange_rate(c.currency, SYSDATE) IS NOT NULL
      ORDER  BY c.currency
    ]'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'currencies', p_method => 'GET',
    p_name => 'X-Emp-Id', p_bind_variable_name => 'emp_id_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'expenses.employee', p_pattern => 'currencies', p_method => 'GET',
    p_name => 'X-Session-Token', p_bind_variable_name => 'session_token_hdr',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  COMMIT;
END;
/


--------------------------------------------------------------------------------
-- 4. Self-test. Raises rather than leaving USD mis-converting.
--------------------------------------------------------------------------------
DECLARE
  l_rate NUMBER;
  l_usd  NUMBER;
  l_eff  DATE;
BEGIN
  -- USD is 1 on every date, including months with no rate data at all.
  FOR d IN (SELECT DATE '2019-01-15' AS dt FROM dual
            UNION ALL SELECT SYSDATE FROM dual
            UNION ALL SELECT DATE '2026-06-15' FROM dual
            UNION ALL SELECT DATE '2031-12-15' FROM dual)
  LOOP
    l_rate := get_exchange_rate('USD', d.dt);
    IF l_rate IS NULL OR l_rate != 1 THEN
      RAISE_APPLICATION_ERROR(-20097,
        'USD rate on ' || TO_CHAR(d.dt,'MM/DD/YYYY') || ' is ' || NVL(TO_CHAR(l_rate),'NULL') ||
        ', expected 1.');
    END IF;

    l_usd := convert_to_usd(100, 'USD', d.dt);
    IF l_usd != 100 THEN
      RAISE_APPLICATION_ERROR(-20098,
        '100 USD converted to ' || l_usd || ' on ' || TO_CHAR(d.dt,'MM/DD/YYYY') || '.');
    END IF;

    -- USD must never look like a fallback.
    l_eff := get_rate_effective_date('USD', d.dt);
    IF TRUNC(l_eff,'MM') != TRUNC(d.dt,'MM') THEN
      RAISE_APPLICATION_ERROR(-20099,
        'USD reported as fallback on ' || TO_CHAR(d.dt,'MM/DD/YYYY') ||
        ' (effective ' || TO_CHAR(l_eff,'MM/DD/YYYY') || ').');
    END IF;
  END LOOP;

  -- Lowercase must behave identically - the app sends whatever the picker holds.
  IF get_exchange_rate('usd', SYSDATE) != 1 THEN
    RAISE_APPLICATION_ERROR(-20096, 'Lowercase "usd" did not resolve to 1.');
  END IF;

  -- A real currency must still work, i.e. the short-circuit did not eat everything.
  IF get_exchange_rate('INR', SYSDATE) IS NULL THEN
    RAISE_APPLICATION_ERROR(-20095, 'INR now returns NULL - the table lookup is broken.');
  END IF;

  DBMS_OUTPUT.PUT_LINE('OK: USD is 1 on all tested dates, never a fallback, INR unaffected.');
END;
/


--------------------------------------------------------------------------------
-- 5. Verify.
--------------------------------------------------------------------------------
-- Is there a leftover USD row? Harmless now - it is ignored - but worth
-- knowing about so nobody maintains a value that has no effect.
SELECT conversion_id, from_curr, to_curr, exchange_rate,
       effective_start_date, effective_end_date
FROM   currency_conversion
WHERE  UPPER(from_curr) = 'USD';

-- Every currency the dropdown will now offer, USD included.
SELECT c.currency,
       get_exchange_rate(c.currency, SYSDATE)    AS rate_usd_per_unit,
       convert_to_usd(1000, c.currency, SYSDATE) AS usd_for_1000
FROM   (SELECT DISTINCT from_curr AS currency
        FROM   currency_conversion
        WHERE  UPPER(to_curr) = 'USD' AND UPPER(from_curr) != 'USD'
        UNION
        SELECT 'USD' FROM dual) c
ORDER  BY c.currency;


--------------------------------------------------------------------------------
-- 6. Then from Postman:
--
--   GET /expenses/currencies
--     -> list includes USD with exchange_rate 1, inverse_rate 1
--
--   GET /expenses/exchange-rate?currency=USD&on_date=06/15/2026&amount=100
--     -> exchange_rate 1, amount_usd 100,
--        rate_month JUN-2026, is_fallback N
--
-- The last one is the point: dollars in a month with no rate data are still
-- dollars, and the UI should not warn about them.
--------------------------------------------------------------------------------
