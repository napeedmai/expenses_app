--------------------------------------------------------------------------------
-- 45_currency_conversion.sql
--
-- Multi-currency expenses, converted to USD.
--
-- Run as the app schema (HRMS for dev, REPO for prod). Idempotent.
--
-- WHAT THIS ADDS
--   1. EXPENSES.CURRENCY / EXCHANGE_RATE / AMOUNT_USD
--   2. get_exchange_rate(currency, date)  - month-aware rate lookup
--   3. convert_to_usd(amount, currency, date)
--   4. Backfill for existing rows
--
-- DIRECTION OF CONVERSION - the crux of the whole feature
-- -------------------------------------------------------
-- In CURRENCY_CONVERSION, EXCHANGE_RATE is the USD value of ONE unit of
-- FROM_CURR, and TO_CURR is always 'USD':
--
--     INR  0.011280559  ->  1 INR = $0.0113   (INVERSE_RATE  88.648089)
--     KWD  3.27182306   ->  1 KWD = $3.27     (INVERSE_RATE   0.30564)
--     EUR  1.17258313   ->  1 EUR = $1.17     (INVERSE_RATE   0.852818)
--
-- Therefore:
--     amount_usd = amount * EXCHANGE_RATE
--
-- INVERSE_RATE is units-per-dollar. It is for DISPLAY only ("1 USD =
-- 88.65 INR") and must never be used for the calculation. Getting these
-- backwards turns a 1,000 rupee taxi fare into an $88,648 expense, so the
-- self-test at the bottom of this file asserts the direction explicitly.
--
-- WHICH MONTH'S RATE
-- ------------------
-- The rate is chosen by the month of the expense PERIOD START (FROM_DATE),
-- not the bill date. A bill dated May for travel taken in April uses
-- April's rate. If no row covers that month, we fall back to the current
-- open rate (the one with a NULL EFFECTIVE_END_DATE).
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- 1. Columns on EXPENSES.
--
--    AMOUNT stays exactly as the user typed it; CURRENCY now states what
--    unit it is in, instead of that being an unwritten assumption.
--
--    All three are stored rather than derived on read. A rate row can be
--    corrected later, and if conversion were computed at read time that
--    correction would silently restate expenses that were already approved
--    and paid. Freezing the rate used at save time keeps history honest.
--------------------------------------------------------------------------------
DECLARE
  PROCEDURE add_column(p_ddl IN VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_ddl;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE != -1430 THEN RAISE; END IF;  -- ORA-01430: column already exists
  END;
BEGIN
  add_column('ALTER TABLE expenses ADD (currency VARCHAR2(3))');
  add_column('ALTER TABLE expenses ADD (exchange_rate NUMBER)');
  add_column('ALTER TABLE expenses ADD (amount_usd NUMBER)');
END;
/

COMMENT ON COLUMN expenses.currency      IS 'ISO code the AMOUNT is denominated in, chosen by the user (CURRENCY_CONVERSION.FROM_CURR).';
COMMENT ON COLUMN expenses.exchange_rate IS 'USD value of one unit of CURRENCY, frozen at save time. amount_usd = amount * exchange_rate.';
COMMENT ON COLUMN expenses.amount_usd    IS 'AMOUNT converted to USD using EXCHANGE_RATE. Stored, not derived, so later rate corrections never restate approved expenses.';


--------------------------------------------------------------------------------
-- 2. Rate lookup.
--
--    Returns the USD value of one unit of p_currency for the month
--    containing p_date, falling back to the current open rate.
--    Returns NULL only if the currency is unknown entirely.
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

  l_month_from := TRUNC(NVL(p_date, SYSDATE), 'MM');
  l_month_to   := LAST_DAY(l_month_from);

  -- (a) A row whose effective window overlaps that month. Newest wins if
  --     several overlap.
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
    WHEN NO_DATA_FOUND THEN NULL;  -- fall through to (b)
  END;

  -- (b) Fallback: the current open rate. Reached when the expense predates
  --     the earliest rate row on file.
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
    WHEN NO_DATA_FOUND THEN RETURN NULL;  -- currency not in the table at all
  END;
END get_exchange_rate;
/


--------------------------------------------------------------------------------
-- 3. Convenience wrapper. Rounds to 2dp for money.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION convert_to_usd(
  p_amount   IN NUMBER,
  p_currency IN VARCHAR2,
  p_date     IN DATE DEFAULT SYSDATE
) RETURN NUMBER IS
  l_rate NUMBER;
BEGIN
  IF p_amount IS NULL OR p_currency IS NULL THEN
    RETURN NULL;
  END IF;

  l_rate := get_exchange_rate(p_currency, p_date);
  IF l_rate IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN ROUND(p_amount * l_rate, 2);
END convert_to_usd;
/


--------------------------------------------------------------------------------
-- 4. Backfill existing rows.
--
--    >>> CHECK THIS BEFORE RUNNING <<<
--    Existing expenses have no currency recorded. This assumes they are all
--    INR. Change c_assumed_currency if that is wrong - there is no way to
--    recover the real value afterwards.
--
--    Each row is converted at the rate for its own FROM_DATE month, so
--    backfilled history matches what the app would have stored at the time.
--------------------------------------------------------------------------------
DECLARE
  c_assumed_currency CONSTANT VARCHAR2(3) := 'INR';   -- <<< CHANGE IF WRONG
  l_updated          NUMBER := 0;
BEGIN
  UPDATE expenses
  SET    currency      = c_assumed_currency,
         exchange_rate = get_exchange_rate(c_assumed_currency, from_date),
         amount_usd    = convert_to_usd(amount, c_assumed_currency, from_date)
  WHERE  currency IS NULL;

  l_updated := SQL%ROWCOUNT;
  COMMIT;

  DBMS_OUTPUT.PUT_LINE('Backfilled ' || l_updated || ' expense rows as ' || c_assumed_currency || '.');
END;
/


--------------------------------------------------------------------------------
-- 5. Self-test. Raises rather than leaving a silently wrong converter in
--    place. Skips cleanly if the reference currencies are absent.
--------------------------------------------------------------------------------
DECLARE
  l_rate NUMBER;
  l_usd  NUMBER;
  l_cnt  NUMBER;
BEGIN
  -- Direction check: 1000 INR must be a small number of dollars, not a
  -- large one. This is the assertion that catches EXCHANGE_RATE and
  -- INVERSE_RATE being swapped.
  SELECT COUNT(*) INTO l_cnt
  FROM   currency_conversion
  WHERE  UPPER(from_curr) = 'INR' AND UPPER(to_curr) = 'USD';

  IF l_cnt > 0 THEN
    l_rate := get_exchange_rate('INR', SYSDATE);
    l_usd  := convert_to_usd(1000, 'INR', SYSDATE);

    IF l_rate IS NULL THEN
      RAISE_APPLICATION_ERROR(-20090, 'get_exchange_rate returned NULL for INR.');
    END IF;

    IF l_usd > 500 THEN
      RAISE_APPLICATION_ERROR(-20091,
        'Conversion direction looks INVERTED: 1000 INR converted to ' || l_usd ||
        ' USD. Expected roughly 11. EXCHANGE_RATE is USD-per-unit; ' ||
        'INVERSE_RATE is units-per-USD and must not be used to multiply.');
    END IF;

    DBMS_OUTPUT.PUT_LINE('OK: 1000 INR = ' || l_usd || ' USD (rate ' || l_rate || ')');
  ELSE
    DBMS_OUTPUT.PUT_LINE('SKIP: no INR row to test against.');
  END IF;

  -- Fallback check: a date far earlier than any rate row must still return
  -- a rate rather than NULL.
  IF l_cnt > 0 THEN
    l_rate := get_exchange_rate('INR', DATE '2000-01-15');
    IF l_rate IS NULL THEN
      RAISE_APPLICATION_ERROR(-20092,
        'Fallback to the current open rate is not working - a date with no ' ||
        'matching month returned NULL.');
    END IF;
    DBMS_OUTPUT.PUT_LINE('OK: fallback rate for Jan 2000 = ' || l_rate);
  END IF;

  -- USD must convert 1:1. It exists as a FROM_CURR row.
  SELECT COUNT(*) INTO l_cnt
  FROM   currency_conversion
  WHERE  UPPER(from_curr) = 'USD' AND UPPER(to_curr) = 'USD';

  IF l_cnt > 0 THEN
    l_usd := convert_to_usd(100, 'USD', SYSDATE);
    IF l_usd != 100 THEN
      RAISE_APPLICATION_ERROR(-20093,
        '100 USD converted to ' || l_usd || ' USD. The USD->USD row should have EXCHANGE_RATE = 1.');
    END IF;
    DBMS_OUTPUT.PUT_LINE('OK: 100 USD = 100 USD');
  ELSE
    DBMS_OUTPUT.PUT_LINE('WARNING: no USD->USD row in CURRENCY_CONVERSION. ' ||
      'Users selecting USD will get a NULL rate. Add a row with EXCHANGE_RATE = 1.');
  END IF;
END;
/


--------------------------------------------------------------------------------
-- 6. Verification.
--------------------------------------------------------------------------------
-- What the dropdown will offer.
SELECT DISTINCT from_curr
FROM   currency_conversion
WHERE  UPPER(to_curr) = 'USD'
ORDER  BY from_curr;

-- Every currency at today's rate, with a worked example.
SELECT from_curr,
       get_exchange_rate(from_curr, SYSDATE)        AS rate_usd_per_unit,
       convert_to_usd(1000, from_curr, SYSDATE)     AS usd_for_1000_units
FROM   (SELECT DISTINCT from_curr FROM currency_conversion WHERE UPPER(to_curr) = 'USD')
ORDER  BY from_curr;

-- Backfill result.
SELECT currency, COUNT(*) AS rows_,
       SUM(CASE WHEN amount_usd IS NULL THEN 1 ELSE 0 END) AS missing_usd
FROM   expenses
GROUP  BY currency
ORDER  BY currency;
