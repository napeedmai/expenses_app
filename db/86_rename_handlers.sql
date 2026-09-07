--------------------------------------------------------------------------------
-- 86_rename_handlers.sql
--
-- Run as the APPLICATION SCHEMA, in SQL SCRIPTS. Idempotent.
-- ** RUN IMMEDIATELY AFTER 85_rename_to_xxks_exp.sql. **
--
-- Between 85 and this script every endpoint is broken. This is the script that
-- brings the API back.
--
--
-- WHAT IT DOES
-- ------------
-- Reads each ORDS handler's live source, substitutes the renamed tables and
-- subprograms, and writes it back. Endpoint URIs, module names, JSON field
-- names and HTTP status codes are all untouched, so the mobile app needs no
-- change and no release.
--
-- Generated from USER_ORDS_HANDLERS rather than from this repo, for the same
-- reason 85 reads USER_SOURCE: what is deployed has repeatedly not been what
-- the repo says. Rewriting the thirty handlers by hand from PROD_4_endpoints
-- would have quietly reverted scripts 71 through 82.
--
--
-- WHAT A BLIND SUBSTITUTION WOULD BREAK
-- -------------------------------------
-- The collection feeds build their own self-link:
--
--   SELECT 'expenses/' || e.id "$.id", ...
--
-- That 'expenses/' is a URL FRAGMENT IN A STRING LITERAL, not a table name.
-- A quote and a slash are both non-identifier characters, so a word-boundary
-- match takes it happily and turns the link into 'xxks_exp_claims/123',
-- changing the JSON that goes to the app -- exactly what this rename is not
-- allowed to do. Handler error messages are the same hazard.
--
-- So substitution happens ONLY OUTSIDE single-quoted literals: each line is
-- split on the quote character and quoted segments are copied through
-- untouched. This is the same fix as 85b, which was written after finding that
-- the naive version would have rewritten the sign-off line of every
-- notification email. Section 4 verifies the self-links positively rather than
-- trusting the reasoning.
--
--
-- DEFINE_HANDLER DESTROYS THE PARAMETERS
-- --------------------------------------
-- Handler parameters hang off the handler and go with it. Script 71 re-declares
-- them for that reason. Here they are read out of USER_ORDS_PARAMETERS first
-- and put back afterwards, so a handler cannot lose a binding it had --
-- forgetting them leaves :emp_id_hdr unbound and every request 500s.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF
SET LINESIZE 200


--------------------------------------------------------------------------------
-- 0. Refuse to run out of order.
--------------------------------------------------------------------------------
DECLARE
  l_new NUMBER;
  l_old NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_new FROM user_tables WHERE table_name = 'XXKS_EXP_CLAIMS';
  SELECT COUNT(*) INTO l_old FROM user_tables WHERE table_name = 'EXPENSES';

  IF l_new = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'XXKS_EXP_CLAIMS does not exist -- run 85_rename_to_xxks_exp.sql first.');
  END IF;
  IF l_old > 0 THEN
    RAISE_APPLICATION_ERROR(-20002,
      'Both EXPENSES and XXKS_EXP_CLAIMS exist. 85 did not finish. Fix that '
      || 'before rewriting handlers against a half-renamed schema.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('schema: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
                       || ' -- rename is in place, rewriting handlers.');
END;
/


--------------------------------------------------------------------------------
-- 1. Rewrite every handler in the expenses modules.
--------------------------------------------------------------------------------
DECLARE
  TYPE t_map IS TABLE OF VARCHAR2(128) INDEX BY VARCHAR2(128);
  l_map t_map;

  TYPE t_h IS RECORD (
    module   VARCHAR2(128), pattern VARCHAR2(400), method VARCHAR2(10),
    src_type VARCHAR2(60),  src CLOB, ipp NUMBER, mimes VARCHAR2(400));
  TYPE t_hs IS TABLE OF t_h INDEX BY PLS_INTEGER;
  l_h t_hs;

  TYPE t_p IS RECORD (
    module VARCHAR2(128), pattern VARCHAR2(400), method VARCHAR2(10),
    name VARCHAR2(400), bindv VARCHAR2(128), src_type VARCHAR2(60),
    ptype VARCHAR2(60), access VARCHAR2(30));
  TYPE t_ps IS TABLE OF t_p INDEX BY PLS_INTEGER;
  l_p t_ps;

  l_changed NUMBER := 0;
  l_same    NUMBER := 0;

  -- Whole-identifier substitution on a fragment already known to be outside a
  -- literal. Oracle regex has no \b, so a non-identifier character is required
  -- on each side and restored through \1 and \2; the fragment is padded so a
  -- name at either end still has one. Run twice because two renameable names
  -- separated by one character -- "expenses e JOIN expense_items" -- share it,
  -- and the first pass consumes it.
  FUNCTION swap_all(p_frag IN VARCHAR2) RETURN VARCHAR2 IS
    l_t VARCHAR2(32767);
    l_k VARCHAR2(128);
  BEGIN
    IF p_frag IS NULL THEN RETURN p_frag; END IF;
    l_t := ' ' || p_frag || ' ';
    l_k := l_map.FIRST;
    WHILE l_k IS NOT NULL LOOP
      FOR i IN 1 .. 2 LOOP
        l_t := REGEXP_REPLACE(l_t,
                 '([^A-Za-z0-9_])' || l_k || '([^A-Za-z0-9_])',
                 '\1' || l_map(l_k) || '\2', 1, 0, 'i');
      END LOOP;
      l_k := l_map.NEXT(l_k);
    END LOOP;
    RETURN SUBSTR(l_t, 2, LENGTH(l_t) - 2);
  END;

  -- One line, substituted OUTSIDE single-quoted literals only. Doubled quotes
  -- ('') toggle twice and so leave the state unchanged, which is the correct
  -- reading of an escaped quote. Parity resets per line on purpose: an
  -- apostrophe in a comment would otherwise desynchronise everything after it.
  FUNCTION swap_line(p_line IN VARCHAR2) RETURN VARCHAR2 IS
    l_out VARCHAR2(32767) := NULL;
    l_pos PLS_INTEGER := 1;
    l_q   PLS_INTEGER;
    l_in  BOOLEAN := FALSE;
    l_seg VARCHAR2(32767);
  BEGIN
    IF p_line IS NULL THEN RETURN p_line; END IF;
    LOOP
      l_q := INSTR(p_line, '''', l_pos);
      IF l_q = 0 THEN
        l_seg := SUBSTR(p_line, l_pos);
        l_out := l_out || CASE WHEN l_in THEN l_seg ELSE swap_all(l_seg) END;
        EXIT;
      END IF;
      l_seg := SUBSTR(p_line, l_pos, l_q - l_pos);
      l_out := l_out || CASE WHEN l_in THEN l_seg ELSE swap_all(l_seg) END || '''';
      l_in  := NOT l_in;
      l_pos := l_q + 1;
    END LOOP;
    RETURN l_out;
  END;

  -- A whole handler source, line by line.
  FUNCTION swap_clob(p_src IN CLOB) RETURN CLOB IS
    l_out  CLOB;
    l_pos  PLS_INTEGER := 1;
    l_nl   PLS_INTEGER;
    l_len  PLS_INTEGER := DBMS_LOB.GETLENGTH(p_src);
    l_line VARCHAR2(32767);
  BEGIN
    DBMS_LOB.CREATETEMPORARY(l_out, TRUE);
    WHILE l_pos <= l_len LOOP
      l_nl := DBMS_LOB.INSTR(p_src, CHR(10), l_pos);
      IF l_nl = 0 THEN
        l_line := swap_line(DBMS_LOB.SUBSTR(p_src, l_len - l_pos + 1, l_pos));
        l_pos  := l_len + 1;
      ELSE
        l_line := swap_line(DBMS_LOB.SUBSTR(p_src, l_nl - l_pos, l_pos)) || CHR(10);
        l_pos  := l_nl + 1;
      END IF;
      IF l_line IS NOT NULL AND LENGTH(l_line) > 0 THEN
        DBMS_LOB.WRITEAPPEND(l_out, LENGTH(l_line), l_line);
      END IF;
    END LOOP;
    RETURN l_out;
  END;
BEGIN
  l_map('EXPENSES')                       := 'XXKS_EXP_CLAIMS';
  l_map('EXPENSE_ITEMS')                  := 'XXKS_EXP_ITEMS';
  l_map('EXPENSE_APPROVALS')              := 'XXKS_EXP_APPROVALS';
  l_map('EXPENSE_MAIL_LOG')               := 'XXKS_EXP_MAIL_LOG';
  l_map('EXPENSE_SCAN_LOG')               := 'XXKS_EXP_SCAN_LOG';
  l_map('EXPENSE_LOGIN_ATTEMPTS')         := 'XXKS_EXP_LOGIN_ATTEMPTS';
  l_map('APP_SECRETS')                    := 'XXKS_EXP_SECRETS';
  l_map('PROCESS_EXPENSE_ACTION')         := 'XXKS_EXP_PROCESS_ACTION';
  l_map('SEND_EXPENSE_MAIL')              := 'XXKS_EXP_SEND_MAIL';
  l_map('RECALC_CLAIM_TOTALS')            := 'XXKS_EXP_RECALC_CLAIM_TOTALS';
  l_map('PRICE_EXPENSE_ITEM')             := 'XXKS_EXP_PRICE_ITEM';
  l_map('SCAN_RECEIPT')                   := 'XXKS_EXP_SCAN_RECEIPT';
  l_map('EXPENSE_LOGIN_RECORD')           := 'XXKS_EXP_LOGIN_RECORD';
  l_map('EXPENSE_LOGIN_RETRY_AFTER')      := 'XXKS_EXP_LOGIN_RETRY_AFTER';
  l_map('GET_OAUTH_ACCESS_TOKEN')         := 'XXKS_EXP_GET_OAUTH_ACCESS_TOKEN';
  l_map('GENERATE_SESSION_TOKEN')         := 'XXKS_EXP_GENERATE_SESSION_TOKEN';
  l_map('IS_VALID_SESSION_TOKEN')         := 'XXKS_EXP_IS_VALID_SESSION_TOKEN';
  l_map('HMAC_SHA')                       := 'XXKS_EXP_HMAC_SHA';
  l_map('JSON_ESCAPE_STR')                := 'XXKS_EXP_JSON_ESCAPE_STR';
  l_map('IS_ALLOWED_ATTACHMENT')          := 'XXKS_EXP_IS_ALLOWED_ATTACHMENT';
  l_map('CONVERT_TO_USD')                 := 'XXKS_EXP_CONVERT_TO_USD';
  l_map('GET_EXCHANGE_RATE')              := 'XXKS_EXP_GET_EXCHANGE_RATE';
  l_map('GET_RATE_EFFECTIVE_DATE')        := 'XXKS_EXP_GET_RATE_EFFECTIVE_DATE';
  l_map('GET_FINANCE_MANAGER_EMPID')      := 'XXKS_EXP_GET_FINANCE_MGR_EMPID';
  l_map('GET_PROJECT_MANAGER_EMPID')      := 'XXKS_EXP_GET_PROJECT_MGR_EMPID';
  l_map('GET_REVIEWER_ROLE')              := 'XXKS_EXP_GET_REVIEWER_ROLE';
  l_map('IS_FINANCE_MANAGER')             := 'XXKS_EXP_IS_FINANCE_MANAGER';
  l_map('CAN_VIEW_CLAIM')                 := 'XXKS_EXP_CAN_VIEW_CLAIM';
  l_map('CAN_EDIT_CLAIM')                 := 'XXKS_EXP_CAN_EDIT_CLAIM';

  ------------------------------------------------------------------------------
  -- Snapshot first. Redefining a handler inside a cursor over the very view
  -- being redefined is asking for a moving target.
  ------------------------------------------------------------------------------
  SELECT m.name, t.uri_template, h.method, h.source_type, h.source,
         h.items_per_page, h.mimes_allowed
  BULK   COLLECT INTO l_h
  FROM   user_ords_handlers  h
  JOIN   user_ords_templates t ON t.id = h.template_id
  JOIN   user_ords_modules   m ON m.id = t.module_id
  WHERE  m.name LIKE 'expenses%';

  SELECT m.name, t.uri_template, h.method,
         p.name, p.bind_variable_name, p.source_type, p.param_type, p.access_method
  BULK   COLLECT INTO l_p
  FROM   user_ords_parameters p
  JOIN   user_ords_handlers   h ON h.id = p.handler_id
  JOIN   user_ords_templates  t ON t.id = h.template_id
  JOIN   user_ords_modules    m ON m.id = t.module_id
  WHERE  m.name LIKE 'expenses%';

  DBMS_OUTPUT.PUT_LINE('handlers: ' || l_h.COUNT || ', parameters: ' || l_p.COUNT);

  ------------------------------------------------------------------------------
  -- Rewrite.
  ------------------------------------------------------------------------------
  FOR i IN 1 .. l_h.COUNT LOOP
    DECLARE
      l_src    CLOB;
      l_before CLOB := l_h(i).src;
    BEGIN
      l_src := swap_clob(l_h(i).src);

      IF DBMS_LOB.COMPARE(l_src, l_before) = 0 THEN
        l_same := l_same + 1;
        DBMS_OUTPUT.PUT_LINE(RPAD(l_h(i).method || ' ' || l_h(i).pattern, 40)
                             || ' -- no change needed');
      ELSE
        ORDS.DEFINE_HANDLER(
          p_module_name   => l_h(i).module,
          p_pattern       => l_h(i).pattern,
          p_method        => l_h(i).method,
          p_source_type   => l_h(i).src_type,
          p_source        => l_src,
          p_items_per_page=> l_h(i).ipp,
          p_mimes_allowed => l_h(i).mimes);

        -- Parameters, straight back on.
        FOR j IN 1 .. l_p.COUNT LOOP
          IF  l_p(j).module  = l_h(i).module
          AND l_p(j).pattern = l_h(i).pattern
          AND l_p(j).method  = l_h(i).method THEN
            ORDS.DEFINE_PARAMETER(
              p_module_name        => l_p(j).module,
              p_pattern            => l_p(j).pattern,
              p_method             => l_p(j).method,
              p_name               => l_p(j).name,
              p_bind_variable_name => l_p(j).bindv,
              p_source_type        => l_p(j).src_type,
              p_param_type         => l_p(j).ptype,
              p_access_method      => l_p(j).access);
          END IF;
        END LOOP;

        l_changed := l_changed + 1;
        DBMS_OUTPUT.PUT_LINE(RPAD(l_h(i).method || ' ' || l_h(i).pattern, 40)
                             || ' -- rewritten');
      END IF;
    END;
  END LOOP;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('---');
  DBMS_OUTPUT.PUT_LINE('rewritten: ' || l_changed || ', unchanged: ' || l_same);
END;
/


--------------------------------------------------------------------------------
-- 2. Every handler kept its parameters. Zero rows is the pass condition.
--
-- A handler whose source binds :emp_id_hdr but which has no matching parameter
-- returns 500 on every call. This finds that before a user does.
--------------------------------------------------------------------------------
SELECT t.uri_template, h.method,
       (SELECT COUNT(*) FROM user_ords_parameters p WHERE p.handler_id = h.id) AS params
FROM   user_ords_handlers  h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules   m ON m.id = t.module_id
WHERE  m.name LIKE 'expenses%'
AND    DBMS_LOB.INSTR(h.source, ':emp_id_hdr') > 0
AND   (SELECT COUNT(*) FROM user_ords_parameters p WHERE p.handler_id = h.id) = 0;


--------------------------------------------------------------------------------
-- 3. No handler may still name a renamed object. Zero rows.
--------------------------------------------------------------------------------
SELECT t.uri_template, h.method
FROM   user_ords_handlers  h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules   m ON m.id = t.module_id
WHERE  m.name LIKE 'expenses%'
-- REGEXP_LIKE takes the CLOB directly. An earlier version wrapped it in
-- DBMS_LOB.SUBSTR(h.source, 32000, 1), which raises ORA-06502: called from SQL
-- rather than PL/SQL, that function returns a VARCHAR2 capped at 4000 bytes
-- unless the database is running MAX_STRING_SIZE = EXTENDED. The wrapper
-- bought nothing and broke the check.
AND    REGEXP_LIKE(
         h.source,
         '[^A-Za-z0-9_/]('
         || 'expenses|expense_items|expense_approvals|expense_mail_log'
         || '|expense_scan_log|app_secrets|expense_login_attempts'
         || '|process_expense_action|send_expense_mail|recalc_claim_totals'
         || '|price_expense_item|scan_receipt|is_valid_session_token'
         || '|get_reviewer_role|get_project_manager_empid'
         || '|get_finance_manager_empid|can_view_claim|can_edit_claim'
         || ')[^A-Za-z0-9_]', 'i')
ORDER  BY t.uri_template;
-- The / in the leading character class is what stops 'expenses/' self-links
-- being reported. Section 4 checks those separately and positively.


--------------------------------------------------------------------------------
-- 4. The self-links survived intact.
--
-- Expect every collection feed to say 'expenses/'. If one says
-- 'xxks_exp_claims/', the sentinel did not do its job and the JSON going to the
-- app has changed.
--------------------------------------------------------------------------------
SELECT t.uri_template, h.method,
       CASE WHEN DBMS_LOB.INSTR(h.source, '''expenses/') > 0 THEN 'ok'
            WHEN DBMS_LOB.INSTR(LOWER(h.source), '''xxks_exp_claims/') > 0
                 THEN '** SELF-LINK CORRUPTED **'
            ELSE 'no self-link' END AS self_link
FROM   user_ords_handlers  h
JOIN   user_ords_templates t ON t.id = h.template_id
JOIN   user_ords_modules   m ON m.id = t.module_id
WHERE  m.name LIKE 'expenses%'
AND    h.source_type = 'json/collection'
ORDER  BY t.uri_template;


--------------------------------------------------------------------------------
-- 5. No template may be left without a handler.
--
-- A template with no handler is a URL that answers and runs nothing -- the 555
-- from script 72. Zero rows.
--------------------------------------------------------------------------------
SELECT m.name AS module_name, t.uri_template
FROM   user_ords_templates t
JOIN   user_ords_modules   m ON m.id = t.module_id
LEFT   JOIN user_ords_handlers h ON h.template_id = t.id
WHERE  m.name LIKE 'expenses%'
GROUP  BY m.name, t.uri_template
HAVING COUNT(h.id) = 0;


--------------------------------------------------------------------------------
-- 6. NOW TEST THE APP. None of the above executes a single handler.
--
-- Reading handler source proves the text was stored. It does not prove the SQL
-- parses, and a handler that does not parse returns a BARE 403 WITH NO BODY --
-- indistinguishable from a permissions problem, and the single most expensive
-- error on this project.
--
-- In this order, because each depends on the one before:
--
--   1. Log in                      -- exercises the auth handlers and the
--                                     session token functions
--   2. Home                        -- /expenses/mine, and "Where it's going"
--                                     should show real categories (script 82)
--   3. Open a claim                -- /expenses/{id} and its items
--   4. Open a bill, tap the file   -- the receipt endpoints
--   5. Create a draft, attach,
--      submit                      -- the write path and the submit handler
--                                     that 84 rewrote
--   6. Approve as PM               -- process_action, now XXKS_EXP_PROCESS_ACTION
--   7. Approve as Finance          -- and the mail on each step
--
--   SELECT created_at, event, status, mail_to, mail_cc, subject
--   FROM   xxks_exp_mail_log ORDER BY id DESC FETCH FIRST 10 ROWS ONLY;
--
-- If any step returns 403 with an empty body, the handler for it has a bad
-- object reference. Find it with:
--
--   SELECT name, type, line, text FROM user_errors
--   WHERE  name LIKE 'XXKS\_EXP\_%' ESCAPE '\';
--
-- and read the handler's source before changing anything.
--------------------------------------------------------------------------------
