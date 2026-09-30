# Security architecture

Hiding things in the UI is not security. Controls are enforced in layers; each holds even if the layer above is bypassed.

## 1. Server / network layer
- **Two surfaces, two processes.** `SERVE_MODE=public` never loads `private-db.js`, the portal router, or `DATA_KEY`; `/portal` returns 404. Deploy public and portal on different hosts (`www.` vs `portal.`) for network isolation.
- **TLS only in production:** HTTP→HTTPS 308 redirect, HSTS (2y, preload), `Secure` + `__Host-` cookie. Terminate TLS at a proxy and set `TRUST_PROXY=1`.
- **Host-header allow-list** (`PUBLIC_ORIGIN`/`PORTAL_ORIGIN`), strict CSP (`default-src 'none'`, no inline script/style), `X-Frame-Options: DENY`, `nosniff`, `Referrer-Policy: no-referrer`, COOP/CORP.
- **Never indexed / cached:** every `/portal` response carries `X-Robots-Tag: noindex, nofollow, noarchive` and `Cache-Control: no-store`. `robots.txt` deliberately does *not* list private paths (that would advertise them).
- Generic error handler (no stack traces); rate limits on login, password, 2FA, publish and the public form.

## 2. Application layer
- **No private code in the public bundle.** The calculator engine (`finance.js`) and dashboard (`app.js`) live in `private-ui/`, outside the static web root, and are served only to fully authenticated sessions (404 otherwise). View-source on the public site reveals nothing.
- **Authentication:** scrypt (N=2¹⁵) password hashes, 14+ char policy, constant-work login for unknown users, lockout after 5 failures/15 min per account (and per IP), opaque 256-bit session tokens stored only as SHA-256, `HttpOnly; SameSite=Strict; Secure`, 30-min idle / 8-h absolute expiry, sessions revoked on password change/disable. TOTP 2FA (RFC 6238, verified against the RFC vector); `REQUIRE_2FA=1` blocks all data access until enrolled.
- **Authorization (server-side, every route):** `viewer` read-only · `analyst` read/write/upload/export · `owner` delete, users, audit, export, publishing. Denials are audited. There is no self-registration; only an owner can create accounts, and new accounts must change the temporary password first.
- **CSRF:** Origin check + per-session synchroniser token on every mutating request.
- **Publication gate:** the only way anything becomes public is owner-only `POST /portal/api/publish` with password re-entry and an explicit confirmation flag. Published rows are HMAC-signed (`PUBLISH_KEY`); the public API serves only rows whose signature verifies, so rows injected directly into the public DB are ignored. The public API has no code path to private data.
- Output is rendered with `textContent` (no HTML injection); CSV export neutralises spreadsheet formulas.

## 3. Database & storage layer
- **Separate databases:** `public.db` (inquiries, published content) vs `private.db`.
- **Field-level encryption at rest:** every plan section, property, pricing target, financing record and report is one AES-256-GCM blob (`records.data`) with AAD bound to `kind:id` — copying a ciphertext to another row fails authentication (tested). A stolen database file or backup contains no plan content.
- **Document vault:** files are encrypted, stored under random names outside the web root (mode 0600), metadata (name/type) encrypted; download is authenticated, audited, `Content-Disposition: attachment`; extension allow-list; 25 MB cap.
- **DB-enforced invariants (SQLite triggers):** audit log append-only; users can't be deleted; the last active owner can't be demoted/disabled; only owners can create owners.
- **Tamper-evident audit log:** hash-chained; verified on the Audit page.

## Production deployment checklist
1. `npm run gen-keys`; store `DATA_KEY` and `PUBLISH_KEY` in a secret manager. **Back up `DATA_KEY` separately from data — losing it makes the vault unrecoverable.**
2. Run two processes: `SERVE_MODE=public` (shares only `public.db`) and `SERVE_MODE=portal`. Restrict the portal by IP/VPN/zero-trust proxy if possible.
3. `NODE_ENV=production`, `TRUST_PROXY=1`, `REQUIRE_2FA=1`, real `PUBLIC_ORIGIN`/`PORTAL_ORIGIN`.
4. Encrypt the disk/volume, restrict `DATA_DIR` to the service account, back up `private.db` + `vault/` encrypted.
5. Create the owner with `npm run create-owner`, sign in, enable 2FA, then authorize others.
6. `npm audit` / dependency updates on a schedule; monitor the Audit page for `login.failed` and `authz.denied`.

## Scaling to Postgres / Supabase
SQLite suits a single-owner tool. To move to Postgres keep the same model and add database-enforced policies:
```sql
ALTER TABLE records ENABLE ROW LEVEL SECURITY;
CREATE POLICY records_read  ON records FOR SELECT USING (current_setting('app.role', true) IN ('viewer','analyst','owner'));
CREATE POLICY records_write ON records FOR ALL    USING (current_setting('app.role', true) IN ('analyst','owner'));
REVOKE ALL ON records, documents, users FROM anon, public_web;   -- public role: only inquiries(INSERT) and published_content(SELECT)
```
Keep the app-level AES-GCM encryption even with RLS (defence in depth against DB/backups leaks).

## Known limits
- Single-process in-memory rate limiter (use a shared store if you scale horizontally).
- Encryption keys live in the app process; use a KMS/HSM for stronger key custody.
- The business-plan file was not present in this repository; nothing confidential is committed.
