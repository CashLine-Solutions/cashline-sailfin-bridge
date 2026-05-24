# Salesforce Connected App + JWT Bearer Setup

One-time operator runbook for provisioning Salesforce JWT Bearer authentication for cashline-ontology. Repeat per environment (sandbox, production).

Username/Password OAuth has been progressively disabled by Salesforce; JWT Bearer is the only durable server-to-server flow as of 2026.

## 1. Generate a self-signed cert + private key

On your workstation (not in the repo):

```bash
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout sf_private.pem \
  -out sf_cert.crt \
  -days 365 \
  -subj "/CN=cashline-ontology-$(date +%Y)"
```

This produces two files:
- `sf_private.pem` — private key. Stays on your machine, then in Rails encrypted credentials. **Never commit.**
- `sf_cert.crt` — public cert. Uploaded to Salesforce.

Make a calendar reminder ~30 days before the `-days` expiry — Salesforce supports two active certs simultaneously during rotation windows, so you can deploy a new key before the old one expires without downtime.

## 2. Create the Connected App in Salesforce

**External Client App (newer model, recommended):** Setup → quick-find **"External Client App Manager"** → **New External Client App**.

| Field | Value |
|---|---|
| External Client App Name | `cashline_ontology` |
| Contact Email | a real person on your team |
| Distribution State | Local |
| Enable OAuth | ✅ |
| Callback URL | `https://login.salesforce.com/services/oauth2/callback` (used only for one-time pre-auth in step 5) |
| Selected OAuth Scopes | `api`, `offline_access` (External Client App naming for `refresh_token`), `web` |
| Flow Enablement → Enable JWT Bearer Flow | ✅ |
| Certificate Upload | upload `sf_cert.crt` (appears after JWT Bearer is checked) |

Save. **Then go to the app's Policies tab → Edit:** set **IP Relaxation** to **Relax IP restrictions** (required for JWT from non-whitelisted IPs like your laptop or any cloud host).

Wait 2-10 minutes for the policy to propagate (Salesforce's quoted SLA).

> **Legacy Connected App users:** Setup → App Manager → New Connected App. The form labels differ (e.g., "Use digital signatures" replaces the JWT Bearer checkbox), but the same fields are present.

## 3. Note the consumer key

App Manager → cashline-ontology → View → "Consumer Key" (sometimes labeled "Client ID"). Copy it.

## 4. (Optional but recommended) Pre-authorize the integration user via permission set

For JWT to issue tokens without browser interaction, the integration user must have already authorized this Connected App. The cleanest way is via a permission set:

1. Setup → Manage Connected Apps → cashline-ontology → Permitted Users → "Admin approved users are pre-authorized."
2. Create a permission set `cashline_ontology_integration` assigned to your integration user.
3. Assign the Connected App to that permission set: Setup → Connected Apps OAuth Usage → Install → Choose "Admin approved users are pre-authorized."

If permission sets feel like too much, do step 5 instead.

## 5. (Alternative to #4) Manual browser pre-authorization

Once, via browser:

```
https://login.salesforce.com/services/oauth2/authorize?
  client_id=<CONSUMER_KEY>&
  redirect_uri=https://login.salesforce.com/services/oauth2/callback&
  response_type=code
```

Sign in as the integration user. Click "Allow." Salesforce now considers this user pre-authorized for the Connected App; JWT Bearer will succeed.

> The single most common JWT error is `invalid_grant: user hasn't approved this consumer`. It looks like a cert problem but is actually missing pre-auth.

## 6. Stash credentials in Rails encrypted credentials

```bash
bin/rails credentials:edit --environment development
```

Add:

```yaml
salesforce:
  consumer_key: <CONSUMER_KEY from step 3>
  username: integration@yourcompany.com.cashline.sandbox  # sandbox usernames have a suffix
  instance_url: https://yourdomain--cashline.sandbox.my.salesforce.com
  sandbox: true  # false in production credentials
  private_key: |
    -----BEGIN PRIVATE KEY-----
    <contents of sf_private.pem>
    -----END PRIVATE KEY-----
```

Repeat for `--environment production`.

## 7. Smoke test the handshake

```bash
bin/rails sailfin:smoke
```

Expected: `OK — authenticated. Sample user: integration@yourcompany.com.sandbox (Id: 005...)`.

The task wraps a one-row SOQL query against the `User` table; both auth (JWT exchange) and API connectivity (REST query) are exercised in one shot.

If it fails, the task prints the common causes:
- `invalid_grant` → pre-auth missed (#4 or #5 above)
- `invalid_client_id` → consumer key wrong, or app still propagating (wait 2–10 min)
- `KeyError on :username` → credentials block missing or misindented
- IP rejection → Permitted Users → **Relax IP restrictions** in External Client App Manager → Policies

After smoke succeeds, you can also run:

```bash
bin/rails sailfin:namespaces  # histogram of all visible objects by namespace prefix
bin/rails sailfin:limits      # current API quota snapshot
```

`sailfin:namespaces` is the most useful step before triggering an extraction — it tells you what the managed-package namespace is and which standard objects to seed from.

## 8. Cert rotation (annual)

About 30 days before expiry:

1. Generate a new keypair (step 1 with a new filename, e.g. `sf_private_2027.pem`).
2. In the Connected App, upload the new public cert *as a second cert* — Salesforce supports two active certs during rotation.
3. Update Rails encrypted credentials with the new `private_key`. Deploy.
4. Smoke-test (#7) using the new key.
5. After a few clean days, remove the old cert from the Connected App.
6. **Flush the token cache** (`bin/rails runner "Salesforce::TokenCache.purge!"`) so any access tokens minted under the old key are forgotten.

## Notes

- Sandbox `aud` claim must be `https://test.salesforce.com`; production is `https://login.salesforce.com`. Restforce 8 derives this from the `host:` config — make sure `instance_url` (or `host:`) is sandbox-shaped in the sandbox credentials.
- JWT `exp` must be within 3 minutes of Salesforce's clock. Ensure NTP is healthy on the host.
- Sandbox refresh: when Salesforce refreshes a sandbox, the `instance_url` can change. Run `bin/rails runner "Salesforce::TokenCache.purge!"` after a refresh, or wait for the 401-retry path (Unit 6) to invalidate stale entries automatically.
