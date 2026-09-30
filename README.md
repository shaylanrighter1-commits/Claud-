# Multifamily investment platform

Two completely separate areas in one codebase:

| Area | Path | Contains | Who |
|---|---|---|---|
| **Public website** | `/` (`public/`) | General multifamily education, mission, contact form | Everyone |
| **Private dashboard** | `/portal` (`private-ui/`) | Business plan, pipeline, calculators, capital, projections, documents | Owner + users the owner explicitly authorizes |

## Quick start (development)
```bash
npm install
OWNER_EMAIL=you@example.com OWNER_NAME="Your Name" npm run create-owner   # prompts for password
npm start            # http://localhost:3000  ·  dashboard: /portal/login
npm test
```
The first owner is created **from the server console only** — there is no web sign-up or setup route.

## Loading the confidential business plan
Do **not** commit it to this repository (`.gitignore` blocks PDFs/Office files and `confidential/`).
Sign in → **Business plan → Import** (Markdown/text, split by headings) and **Documents → Upload** (PDF/Word/Excel originals).
Both are stored AES-256-GCM encrypted. See `docs/SECURITY.md`.

## Production
See `docs/SECURITY.md` → *Deployment checklist*. Run `SERVE_MODE=public` and `SERVE_MODE=portal` as **separate processes/hosts**.

## Forgot your password?
From the project folder on the machine running the site (this keeps all data):
```bash
USER_EMAIL=you@example.com npm run reset-password           # prompts for the new password
USER_EMAIL=you@example.com RESET_2FA=1 npm run reset-password  # also clears 2FA if you lost your phone
```
