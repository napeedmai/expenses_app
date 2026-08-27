--------------------------------------------------------------------------------
-- DISCOVER_APEX_AI_3.sql
--
-- READ-ONLY apart from the AI calls themselves. Run on DEV (HRMS), SQL Scripts.
--
--
-- WHAT SCRIPT 2 ESTABLISHED
-- -------------------------
-- GENERATE has several overloads. This is the one that matters:
--
--   GENERATE overload 9  ->  RETURNS CLOB
--     1  p_prompt                       CLOB      required
--     2  p_system_prompt                CLOB
--     3  p_service_static_id            VARCHAR2
--     4  p_temperature                  NUMBER
--     5  p_attachments                  t_attachments
--     6  p_response_json_schema         CLOB
--     7  p_tools                        t_tools
--     8  p_request_handler_procedure    VARCHAR2
--     9  p_response_handler_procedure   VARCHAR2
--    10  p_max_tool_roundtrips          BINARY_INTEGER
--
-- IT TAKES A *SERVICE* STATIC ID, NOT AN AGENT OR CONFIG ID. That is the whole
-- ballgame:
--
--   * A SERVICE is workspace-level -- apex_workspace_ai_services. You have one:
--     openai_service / gpt-4.1-mini / workspace HRMSDEV.
--   * A CONFIG or AGENT is application-level, which is why the first probe hit
--     ORA-20961 "does not exist in the current application".
--
-- So there is no need for an APEX session, no need for an app-scoped config, and
-- no need to invent an APEX application to hold one. APEX_UTIL.SET_WORKSPACE is
-- enough -- exactly what send_expense_mail already does for APEX_MAIL.
--
-- And the attachment type is declared, unwrapped, in the package spec:
--
--     type t_attachment is record (
--       mime_type    varchar2(255),   -- required
--       content_blob blob,            -- images, audio, PDFs
--       ... );
--     type t_attachments is table of t_attachment;
--
--
-- ONE THING THAT COULD STILL STOP THIS
-- ------------------------------------
-- The service row says IS_BUILDER_SERVICE = Yes. It may be reserved for the
-- App Builder's own assistant and refused to application code. If section 2
-- below fails on permissions rather than on the call, that is the reason, and
-- the fix is an admin creating a second AI service -- same OpenAI credential,
-- IS_BUILDER_SERVICE = No. Five minutes, no DBA, no new secret.
--
-- Worth knowing now rather than after the handler is written.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF
SET LINESIZE 200


PROMPT ============ 1. THE ATTACHMENT RECORD, IN FULL ============

-- Fields 3 onward were cut off last time. The detail level matters: it decides
-- how much of the image the provider actually looks at, which is both accuracy
-- and cost.
SELECT line, text
FROM   all_source
WHERE  owner = 'APEX_260100' AND name = 'WWV_FLOW_AI_API' AND type = 'PACKAGE'
AND    line BETWEEN 45 AND 135
ORDER  BY line;

SELECT line, text
FROM   all_source
WHERE  owner = 'APEX_260100' AND name = 'WWV_FLOW_AI_API' AND type = 'PACKAGE'
AND    line BETWEEN 255 AND 285
ORDER  BY line;

-- And Oracle's own worked example of a JSON schema call, around line 836.
SELECT line, text
FROM   all_source
WHERE  owner = 'APEX_260100' AND name = 'WWV_FLOW_AI_API' AND type = 'PACKAGE'
AND    line BETWEEN 790 AND 870
ORDER  BY line;


PROMPT ============ 2. TEXT ONLY, VIA THE WORKSPACE SERVICE ============

-- The cheapest possible proof that an ORDS handler can reach the AI with
-- nothing but SET_WORKSPACE.
DECLARE
  l_workspace VARCHAR2(200);
  l_out       CLOB;
BEGIN
  SELECT secret_value INTO l_workspace
  FROM   app_secrets WHERE secret_name = 'MAIL_WORKSPACE';
  APEX_UTIL.SET_WORKSPACE(p_workspace => l_workspace);

  l_out := APEX_AI.GENERATE(
             p_prompt            => 'Reply with exactly the word: READY',
             p_service_static_id => 'openai_service');

  DBMS_OUTPUT.PUT_LINE('*** WORKS. Reply: ' || SUBSTR(l_out, 1, 200));
  DBMS_OUTPUT.PUT_LINE('No APEX session needed. No wallet needed.');
EXCEPTION WHEN OTHERS THEN
  DBMS_OUTPUT.PUT_LINE('FAILED: ' || SQLERRM);
  DBMS_OUTPUT.PUT_LINE(SUBSTR(DBMS_UTILITY.FORMAT_ERROR_STACK, 1, 2000));
  DBMS_OUTPUT.PUT_LINE('-- If this mentions the builder service or a privilege, '
    || 'see the note at the top: an admin needs a non-builder AI service.');
END;
/


PROMPT ============ 3. STRUCTURED JSON OUT ============

-- Same call with a response schema. If this returns clean JSON, the endpoint can
-- hand it straight to the app without any parsing of prose.
--
-- Schema written to OpenAI's structured-output rules: every property listed in
-- "required", additionalProperties false, nullable via a type union. A model
-- that cannot read a field must be able to say null rather than invent one --
-- that is the difference between a blank box and a wrong amount.
DECLARE
  l_workspace VARCHAR2(200);
  l_out       CLOB;
  l_schema    CLOB := q'~
{
  "type": "object",
  "additionalProperties": false,
  "required": ["vendor", "amount", "currency"],
  "properties": {
    "vendor":   { "type": ["string","null"] },
    "amount":   { "type": ["number","null"] },
    "currency": { "type": ["string","null"], "description": "ISO 4217 code" }
  }
}~';
BEGIN
  SELECT secret_value INTO l_workspace
  FROM   app_secrets WHERE secret_name = 'MAIL_WORKSPACE';
  APEX_UTIL.SET_WORKSPACE(p_workspace => l_workspace);

  l_out := APEX_AI.GENERATE(
             p_prompt               => 'A taxi receipt from Meru Cabs for 1,250.50 rupees.',
             p_system_prompt        => 'Extract the fields. Use null when a value is not present.',
             p_service_static_id    => 'openai_service',
             p_temperature          => 0,
             p_response_json_schema => l_schema);

  DBMS_OUTPUT.PUT_LINE('JSON: ' || SUBSTR(l_out, 1, 3000));
  DBMS_OUTPUT.PUT_LINE('Valid JSON? ' || CASE WHEN l_out IS JSON THEN 'YES' ELSE 'NO' END);
  DBMS_OUTPUT.PUT_LINE('amount read back: ' || JSON_VALUE(l_out, '$.amount'));
  DBMS_OUTPUT.PUT_LINE('currency read back: ' || JSON_VALUE(l_out, '$.currency'));
EXCEPTION WHEN OTHERS THEN
  DBMS_OUTPUT.PUT_LINE('FAILED: ' || SQLERRM);
  DBMS_OUTPUT.PUT_LINE(SUBSTR(DBMS_UTILITY.FORMAT_ERROR_STACK, 1, 2000));
END;
/


PROMPT ============ 4. A REAL RECEIPT IMAGE ============

-- THE ACTUAL FEATURE, proven end to end against a bill already in the database
-- before a line of the endpoint is written.
--
-- Uses the newest EXPENSE_ITEMS row that has an attachment. If there is none,
-- it says so -- upload one receipt through the app on dev and re-run this
-- section.
DECLARE
  l_workspace VARCHAR2(200);
  l_out       CLOB;
  l_att       APEX_AI.T_ATTACHMENTS := APEX_AI.T_ATTACHMENTS();
  l_blob      BLOB;
  l_mime      VARCHAR2(255);
  l_name      VARCHAR2(300);
  l_item      NUMBER;
  l_schema    CLOB := q'~
{
  "type": "object",
  "additionalProperties": false,
  "required": ["bill_no","bill_date","type","description","currency","amount","vendor","notes"],
  "properties": {
    "bill_no":     { "type": ["string","null"], "description": "Invoice or bill number printed on the receipt" },
    "bill_date":   { "type": ["string","null"], "description": "Date on the receipt, as YYYY-MM-DD" },
    "type":        { "type": ["string","null"],
                     "enum": ["Parking","Travelling","Hotel","Telephone","Travel","Accommodation",
                              "Meal","PerDiem","Phone","Internet/Wifi","Visa","Gift","Medical",
                              "Other","Courier","Stationary","Night Shift Allowance","Taxi",
                              "Food During Travel","Client Dinner/Lunch","Air Fare","Cell Phone",
                              "Visa Fee","Car Rental","Gas","Recruitment Incentives", null] },
    "description": { "type": ["string","null"], "description": "One short line, under 80 characters" },
    "currency":    { "type": ["string","null"], "description": "ISO 4217 code, e.g. INR, USD, EUR" },
    "amount":      { "type": ["number","null"], "description": "The TOTAL payable, including tax" },
    "vendor":      { "type": ["string","null"] },
    "notes":       { "type": ["string","null"], "description": "Anything unreadable or ambiguous" }
  }
}~';
BEGIN
  SELECT secret_value INTO l_workspace
  FROM   app_secrets WHERE secret_name = 'MAIL_WORKSPACE';

  BEGIN
    SELECT id, attachment_blob, attachment_mime_type, attachment_filename
    INTO   l_item, l_blob, l_mime, l_name
    FROM   (SELECT id, attachment_blob, attachment_mime_type, attachment_filename
            FROM   expense_items
            WHERE  attachment_blob IS NOT NULL
            ORDER  BY id DESC)
    WHERE  ROWNUM = 1;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    DBMS_OUTPUT.PUT_LINE('No EXPENSE_ITEMS row has an attachment on this schema.');
    DBMS_OUTPUT.PUT_LINE('Upload one receipt through the app on dev, then re-run '
      || 'this section. Section 3 already proved the plumbing.');
    RETURN;
  END;

  DBMS_OUTPUT.PUT_LINE('Bill id ' || l_item || ' -- ' || l_name
    || ' (' || l_mime || ', ' || ROUND(DBMS_LOB.GETLENGTH(l_blob) / 1024) || ' KB)');

  l_att.EXTEND;
  l_att(1).mime_type    := l_mime;
  l_att(1).content_blob := l_blob;

  APEX_UTIL.SET_WORKSPACE(p_workspace => l_workspace);

  l_out := APEX_AI.GENERATE(
    p_prompt        => 'Read this expense receipt and extract the fields.',
    p_system_prompt =>
      'You read receipts and invoices for a corporate expense claim system. '
      || 'Return only what is legibly printed on the document. Use null for any '
      || 'field you cannot read with confidence -- a null is useful to the person '
      || 'checking, an invented value is not. '
      || 'amount is the TOTAL PAYABLE including tax, not a subtotal or a line item. '
      || 'Never round it. If several totals appear, take the final one charged. '
      || 'bill_date must be the date the expense was incurred, formatted YYYY-MM-DD; '
      || 'resolve ambiguous formats using any other date context on the document, '
      || 'and if it stays ambiguous return null and say so in notes. '
      || 'currency must be an ISO 4217 code inferred from the symbol or the '
      || 'country -- Rs and the rupee sign mean INR. '
      || 'type must be one of the listed values or null; choose by what was '
      || 'bought, not by the vendor name.',
    p_service_static_id    => 'openai_service',
    p_temperature          => 0,
    p_attachments          => l_att,
    p_response_json_schema => l_schema);

  DBMS_OUTPUT.PUT_LINE('--');
  DBMS_OUTPUT.PUT_LINE(SUBSTR(l_out, 1, 3800));
  DBMS_OUTPUT.PUT_LINE('--');
  DBMS_OUTPUT.PUT_LINE('Valid JSON? ' || CASE WHEN l_out IS JSON THEN 'YES' ELSE 'NO' END);

  -- Compare against what the person actually typed. This is the only honest
  -- measure of whether the feature is worth shipping.
  FOR r IN (SELECT bill_no, TO_CHAR(bill_date,'YYYY-MM-DD') bill_date, type,
                   description, currency, amount
            FROM   expense_items WHERE id = l_item)
  LOOP
    DBMS_OUTPUT.PUT_LINE('WHAT THE PERSON TYPED:');
    DBMS_OUTPUT.PUT_LINE('  bill_no   ' || r.bill_no);
    DBMS_OUTPUT.PUT_LINE('  bill_date ' || r.bill_date);
    DBMS_OUTPUT.PUT_LINE('  type      ' || r.type);
    DBMS_OUTPUT.PUT_LINE('  descr     ' || SUBSTR(r.description, 1, 80));
    DBMS_OUTPUT.PUT_LINE('  currency  ' || r.currency);
    DBMS_OUTPUT.PUT_LINE('  amount    ' || r.amount);
  END LOOP;
EXCEPTION WHEN OTHERS THEN
  DBMS_OUTPUT.PUT_LINE('FAILED: ' || SQLERRM);
  DBMS_OUTPUT.PUT_LINE(SUBSTR(DBMS_UTILITY.FORMAT_ERROR_STACK, 1, 2000));
END;
/


--------------------------------------------------------------------------------
-- WHAT I NEED BACK
--
--   section 1  -- the three source ranges (the record's remaining fields, the
--                 detail-level constants, and Oracle's own schema example)
--   section 2  -- WORKS, or the error
--   section 3  -- the JSON, and whether it was valid
--   section 4  -- the JSON, and how it compares to what the person typed
--
-- Section 4 is the one that decides whether this ships. Everything before it
-- only proves the call is possible.
--
--
-- THEN I BUILD
--
--   79_ai_scan_receipt.sql
--     POST /expenses/scan-receipt
--       raw image or PDF in the body, Content-Type = its MIME type
--       returns the JSON above, stores nothing
--       session-guarded, added to expenses.authenticated
--       a size ceiling of its own -- phone photos run 3-5 MB, well over the
--       1 MB cap on STORED receipts, and scanning and storing are not the
--       same limit
--
--   src/components/BillSheet.js
--       picking a photo offers "Scan this receipt"; results land in a review
--       sheet, field by field, with an Apply button. Nothing is written until
--       the person accepts it -- your choice, and the right one while accuracy
--       is unproven.
--
--
-- TWO THINGS I WILL BUILD IN WITHOUT ASKING
--
-- A LOG TABLE. Every scan records the fields returned, and whether the person
-- kept, edited or discarded each one. Without that there is no way to answer
-- "is this actually helping" except by opinion, and no way to notice it getting
-- worse when the model behind openai_service changes under you.
--
-- A HARD RULE THAT THE AI NEVER SETS MONEY. exchange_rate and amount_usd stay
-- server-computed by price_expense_item, as they are today. The model may
-- suggest the amount and the currency, which a person then confirms; it does not
-- get to decide what anybody is reimbursed.
--------------------------------------------------------------------------------
