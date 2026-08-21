# DBA request — trust the exp.host certificate (Expense App push notifications)

**Requested by:** Jayesh Gulve
**Database / schema:** the one serving `/ords/repo` — app schema `REPO`
**APEX engine schema:** `APEX_260100`
**Attached:** `root_ca.pem` — the root CA that signs `exp.host`

---

## What is needed

An Oracle wallet containing the attached root CA certificate, readable by the
`oracle` OS user, and the path to it.

## Why

The Expense App sends push notifications by calling
`https://exp.host/--/api/v2/push/send` from PL/SQL, via
`APEX_WEB_SERVICE.MAKE_REST_REQUEST`. That call currently fails:

```
ORA-29273: HTTP request failed
ORA-06512: at "APEX_260100.WWV_FLOW_WEB_SERVICES", line 745
ORA-29024: Certificate validation failure
ORA-06512: at "SYS.UTL_HTTP", line 380
```

**The network ACL is already correct** — the request reaches exp.host and
fails during the TLS handshake, not before it. The database simply has no
public CA in its trust store.

Outbound HTTPS to our own ORDS host already works (the login flow depends on
it), so this is specifically about trusting a public certificate authority.

Only push notifications are affected. Everything else in the app works.

---

## Option A — add to an existing wallet (preferred if one exists)

If the database already has a wallet for outbound HTTPS, please just add the
certificate to it and tell us the path:

```bash
orapki wallet add -wallet <existing wallet path> -trusted_cert \
       -cert /tmp/root_ca.pem -pwd <pwd>

orapki wallet display -wallet <existing wallet path>
```

## Option B — create a dedicated wallet

```bash
orapki wallet create -wallet /opt/oracle/wallet_expo -auto_login -pwd <pwd>

orapki wallet add -wallet /opt/oracle/wallet_expo -trusted_cert \
       -cert /tmp/root_ca.pem -pwd <pwd>

orapki wallet display -wallet /opt/oracle/wallet_expo
```

`-auto_login` is preferred — without it the wallet password must be stored in
the application schema, which we would rather avoid.

The `oracle` OS user needs read access to the directory. A permissions problem
there produces the identical `ORA-29024`, so it is worth confirming.

## Option C — configure it APEX-wide (best if other apps will need it)

If you would rather set this once for the whole APEX instance instead of
per-application, we will use it automatically and change nothing on our side:

```sql
BEGIN
  APEX_INSTANCE_ADMIN.SET_PARAMETER('WALLET_PATH', 'file:/opt/oracle/wallet_expo');
  APEX_INSTANCE_ADMIN.SET_PARAMETER('WALLET_PWD',  '<pwd>');  -- omit if -auto_login
  COMMIT;
END;
/
```

Please tell us if you choose this, so we leave our per-app setting empty.

> If your standard practice is to load a full public CA bundle rather than
> individual roots, that is fine and probably better — we only need exp.host
> to validate.

---

## What we need back

1. The wallet path, in the form `file:/opt/oracle/wallet_expo`
2. Whether it was created with `-auto_login` (if not, the password)
3. Or simply: "configured instance-wide via APEX_INSTANCE_ADMIN"

---

## How to verify it worked

Run as the `REPO` schema, with `SET SERVEROUTPUT ON`, substituting the path:

```sql
DECLARE
  l_response CLOB;
BEGIN
  l_response := apex_web_service.make_rest_request(
    p_url         => 'https://exp.host/--/api/v2/push/send',
    p_http_method => 'POST',
    p_body        => '[]',
    p_wallet_path => 'file:/opt/oracle/wallet_expo'
  );
  DBMS_OUTPUT.PUT_LINE('OK, status ' || apex_web_service.g_status_code);
  DBMS_OUTPUT.PUT_LINE(SUBSTR(l_response, 1, 300));
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE(DBMS_UTILITY.FORMAT_ERROR_STACK);
END;
/
```

Any HTTP status is a success here — it means the TLS handshake completed.
Expo will reject the empty payload with a validation error, which is expected
and proves the connection works. `ORA-29024` again means the wallet is not
being found or does not contain the right root.

---

## Note for the future

Public CA certificates get rotated and expire. If push notifications silently
stop working months from now with no code change, this wallet is the first
place to look — an expired root produces exactly the error above.
