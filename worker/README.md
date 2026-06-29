# Plozz Auth Relay (Cloudflare Worker)

This directory contains the **OAuth relay** that lets the Plozz tvOS app connect
to trackers that **cannot** do an on‑device device‑code/PIN flow — currently
**MyAnimeList (MAL)** and **AniList**.

It is deployed as a Cloudflare Worker at **`https://plozz.app`**.

> Trakt and Simkl do **not** use this relay. They support native device‑code /
> PIN flows, so the TV app talks to them directly. Only MAL and AniList route
> through here.

---

## Why this exists

MAL and AniList only offer browser‑based OAuth (`authorization_code` / implicit
grant) with a redirect back to a registered HTTPS `redirect_uri`. An Apple TV
has no usable browser and is painful to type on, so we can't run that flow on
the device.

The relay bridges that gap:

1. The TV shows a URL (`plozz.app/myanimelist` or `plozz.app/anilist`) as a QR code.
2. The user opens it on their **phone**, signs in, and approves.
3. The relay captures the resulting token and hands back a short **4‑digit code**.
4. The user types those 4 digits on the TV.
5. The TV redeems the code for the real access token.

The 4‑digit code is the whole point: digits are unambiguous to **dictate** into
the Apple TV remote (saying letters to Siri dictation is unreliable).

### Important constraint: AniList blocks Cloudflare Worker IPs

AniList returns `403 "manually blocked / principal's office"` for requests
coming from Cloudflare Worker egress IPs, so the Worker **cannot** call
AniList's `/oauth/token` endpoint server‑side. To work around this we use the
**implicit grant** (`response_type=token`): AniList puts the token directly in
the URL fragment (`#access_token=...`), and a tiny page served by the Worker
reads it **in the browser** and POSTs it back to us. No Worker→AniList call ever
happens.

MAL has no such restriction, so MAL uses the normal server‑side
`authorization_code` + PKCE exchange.

---

## Architecture / flow

```
            ┌─────────┐   shows QR for plozz.app/<service>
            │ Apple TV│──────────────────────────────────────┐
            └─────────┘                                       │
                 ▲                                            ▼
                 │ 5. POST /api/redeem?code=1234      ┌──────────────┐
                 │    → { accessToken, ... }          │  User's phone│
                 │                                    └──────────────┘
                 │                                            │ 1. opens URL
                 │                                            ▼
         ┌───────────────────────────── Cloudflare Worker (plozz.app) ──────────┐
         │                                                                       │
         │  MAL  (server-side authorization_code + PKCE):                        │
         │    /myanimelist ──302──▶ myanimelist.net/authorize                    │
         │    /auth/mal/callback  ──server POST──▶ myanimelist.net/token         │
         │                         → store token, show 4-digit code              │
         │                                                                       │
         │  AniList (implicit grant, browser-side — Worker IPs are blocked):     │
         │    /anilist ──302──▶ anilist.co/authorize?response_type=token         │
         │    /auth/anilist/callback → serves a page whose JS reads the          │
         │       #access_token fragment and POSTs it to /api/store               │
         │    /api/store → stores token, returns 4-digit code                    │
         │                                                                       │
         │  Shared:                                                              │
         │    /api/redeem?code=NNNN → returns token once, then deletes it        │
         │                                                                       │
         │  State lives in Workers KV (binding: AUTH_KV), 10-min TTL.            │
         └───────────────────────────────────────────────────────────────────────┘
```

---

## Endpoints

| Path | Method | Who calls it | Purpose |
|------|--------|--------------|---------|
| `/myanimelist` | GET | Phone (from QR) | Starts MAL auth. Generates a PKCE verifier, stores a `session:` record in KV, then 302‑redirects to MAL's authorize page. |
| `/auth/mal/callback` | GET | MAL | MAL redirects here with `?code=&state=`. Worker exchanges the code (with `client_secret` + PKCE verifier) for a token server‑side, stores a `redeem:` record, and serves the success page with the 4‑digit code. |
| `/anilist` | GET | Phone (from QR) | Starts AniList auth. 302‑redirects to AniList's authorize page with `response_type=token` (implicit grant). |
| `/auth/anilist/callback` | GET | AniList | AniList redirects here with `#access_token=...` in the **fragment**. Worker serves a page whose JS reads the fragment and POSTs it to `/api/store`. |
| `/api/store` | POST | The AniList callback page (browser JS) | Accepts `{ service, accessToken, refreshToken?, expiresIn? }`, stores a `redeem:` record, returns `{ code }`. Has CORS + an `OPTIONS` preflight. |
| `/api/redeem?code=NNNN` | GET | The TV app | Looks up the `redeem:` record, returns the token JSON, and **deletes it** (one‑time use). Returns 404 if missing/expired. Has CORS + an `OPTIONS` preflight. |

All unknown paths return `404 Not found`.

### KV key shapes (binding `AUTH_KV`)

- `session:<32-char id>` — MAL only. Holds the PKCE `codeVerifier` between
  `/myanimelist` and `/auth/mal/callback`. Deleted after the callback succeeds.
- `redeem:<4-digit code>` — Holds the final token(s) until the TV redeems them.
  Deleted on redeem. Both key types expire after `CODE_TTL` (600 s = 10 min).

### The 4‑digit code

`generateRedeemCode()` returns 4 random digits (`0000`–`9999`). It's:
- short and **dictation‑friendly** for the Apple TV remote,
- single‑use (deleted on redeem),
- short‑lived (10‑min TTL).

10,000 combinations is acceptable here because each code is single‑use and
expires in 10 minutes. If abuse ever becomes a concern, lengthen the code in
`generateRedeemCode()`.

---

## Domain & infrastructure

- **Provider:** Cloudflare Workers.
- **Domain:** `plozz.app` is a Cloudflare‑managed zone. The Worker is bound to
  the route `plozz.app/*`, so it handles every path on the apex domain.
- **KV namespace:** binding `AUTH_KV`, id `152ec5bca6e1429d82e5b93e0fc549c3`
  (see `wrangler.toml`).
- **Config:** `wrangler.toml`
  - `[vars]` holds the **public** client IDs (`MAL_CLIENT_ID`,
    `ANILIST_CLIENT_ID`).
  - `[[kv_namespaces]]` binds `AUTH_KV`.

### Secrets (never committed)

Set with `wrangler secret put` — they live in Cloudflare, **not** in the repo:

| Secret | Used by | Where to get it |
|--------|---------|-----------------|
| `MAL_CLIENT_SECRET` | MAL token exchange in `/auth/mal/callback` | MAL API app settings (https://myanimelist.net/apiconfig). Required because the app's `redirect_uri` is a web URL, so MAL classifies it as a "Web" app and demands a secret. |
| `ANILIST_CLIENT_SECRET` | *(reserved)* | AniList dev settings (https://anilist.co/settings/developer). **Currently unused** at runtime because AniList uses the implicit grant — kept set in case a server‑side flow becomes possible again. |

```bash
cd worker
npx wrangler secret put MAL_CLIENT_SECRET
npx wrangler secret put ANILIST_CLIENT_SECRET   # optional / reserved
```

### OAuth provider app settings that must match

Each provider's developer app must have its **redirect URI** registered exactly:

- **MAL** (`myanimelist.net/apiconfig`): redirect URI = `https://plozz.app/auth/mal/callback`
- **AniList** (`anilist.co/settings/developer`): redirect URI = `https://plozz.app/auth/anilist/callback`

If you change `BASE_URL` or the callback paths in `src/index.js`, you **must**
update these in the provider dashboards too, or auth will fail.

---

## Deploying

```bash
cd worker
npm install            # first time only
npx wrangler deploy --no-bundle
```

`--no-bundle` is used because `src/index.js` is a single self‑contained file
with no imports — there's nothing to bundle.

You'll need to be logged in to the correct Cloudflare account
(`npx wrangler login`, or set `CLOUDFLARE_API_TOKEN`).

### Local development

```bash
cd worker
npx wrangler dev
```

Note: OAuth callbacks need to reach a public HTTPS URL that matches what's
registered in the provider dashboards, so the full round‑trip can't be tested
against `localhost`. `wrangler dev` is mainly useful for editing/serving the
HTML pages and exercising `/api/store` + `/api/redeem` manually.

---

## The TV‑app side (how Swift talks to this)

Two Swift modules consume the relay; both default `relayBaseURL` to
`https://plozz.app`:

- `Sources/MALService/` — `MALConfig.relayBaseURL`, and
  `MALService.connect()` shows `"<relay>/myanimelist"`; the entered code is
  redeemed at `"<relay>/api/redeem?code=…"`.
- `Sources/AniListService/` — `AniListConfig.relayBaseURL`,
  `AniListService` redeems at `"<relay>/api/redeem?code=…"`.

The redeem response shape is decoded by `RelayRedeemResponse` in each service.
If you change the JSON returned by `/api/redeem`, update those structs.

Client IDs on the app side come from `Secrets.plist` / environment
(`MAL_CLIENT_ID`, etc.); see each `*Config.swift`. The client IDs in
`wrangler.toml` and on the app side must refer to the **same** provider apps.

---

## Logos on the success pages

The MAL/AniList/Plozz logos shown on the phone pages are **inlined as base64
`data:` URIs** (constants `PLOZZ_LOGO`, `ANILIST_LOGO`, `MAL_LOGO` at the top of
`src/index.js`) so they render instantly with no extra network request and no
hotlink dependency (AniList previously blocked hotlinking its logo).

To regenerate them, base64‑encode the source image and replace the constant.
The Plozz logo source is
`App/Resources/Assets.xcassets/PlozzLogo.imageset/plozz_logo.svg`.

---

## Gotchas / things that bit us

- **AniList blocks Worker IPs** → must use implicit grant (browser reads the
  token from the URL fragment). Don't "simplify" this back into a server‑side
  token exchange; it will 403.
- **MAL PKCE uses `code_challenge_method=plain`**, not `S256`. MAL rejects
  `S256`. The verifier is sent as both the challenge (`plain`) and the verifier.
- **MAL needs `client_secret`** in the token exchange because the redirect URI
  is a web URL (Web app type).
- **Codes are single‑use** — `/api/redeem` deletes the record on read. If a
  redeem "mysteriously fails the second time," that's expected.
- **Everything is 10‑minute TTL.** A code that sat too long is gone; the user
  just restarts from the TV.
- **Route is `plozz.app/*`**, so the Worker owns the whole apex domain. Adding
  any other site content on `plozz.app` means adding routes/paths here.
