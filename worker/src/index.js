// Plozz Auth Relay — Cloudflare Worker
// Handles OAuth for MAL and AniList on behalf of the tvOS app.
//
// Flow:
// 1. TV shows QR → user scans → lands on /auth/{service}
// 2. Worker redirects to OAuth provider
// 3. Provider calls back → Worker exchanges code for token
// 4. Worker generates short 6-char code, stores token in KV
// 5. Shows user "Enter this code on your TV: XXXXXX"
// 6. TV calls /api/redeem?code=XXXXXX → gets token

const BASE_URL = "https://plozz.app";
const CODE_TTL = 600; // 10 minutes

// Generate a cryptographically random string
function randomString(length) {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789";
  const arr = new Uint8Array(length);
  crypto.getRandomValues(arr);
  return Array.from(arr, (b) => chars[b % chars.length]).join("");
}

// Generate a 4-character redeem code (uppercase, no ambiguous chars)
function generateRedeemCode() {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const arr = new Uint8Array(4);
  crypto.getRandomValues(arr);
  return Array.from(arr, (b) => chars[b % chars.length]).join("");
}

// Generate PKCE code_verifier (43-128 chars, URL-safe)
function generateCodeVerifier() {
  return randomString(64);
}

// Success page HTML
function successPage(code) {
  return `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Plozz — Connected!</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      background: #1a1a2e; color: #fff;
      display: flex; align-items: center; justify-content: center;
      min-height: 100vh; padding: 24px;
    }
    .card {
      background: #16213e; border-radius: 20px; padding: 48px;
      text-align: center; max-width: 420px; width: 100%;
      box-shadow: 0 20px 60px rgba(0,0,0,.4);
    }
    .check { font-size: 64px; margin-bottom: 16px; }
    h1 { font-size: 24px; margin-bottom: 12px; }
    p { color: #a0a0b0; margin-bottom: 32px; font-size: 16px; }
    .code {
      font-family: 'SF Mono', 'Fira Code', monospace;
      font-size: 48px; font-weight: 700; letter-spacing: 8px;
      background: #0f3460; border-radius: 12px; padding: 20px 32px;
      display: inline-block; color: #4dd0e1;
    }
    .hint { color: #707080; font-size: 14px; margin-top: 24px; }
  </style>
</head>
<body>
  <div class="card">
    <div class="check">✓</div>
    <h1>Authorization Successful</h1>
    <p>Enter this code on your TV:</p>
    <div class="code">${code}</div>
    <p class="hint">This code expires in 10 minutes.</p>
  </div>
</body>
</html>`;
}

// Error page HTML
function errorPage(message) {
  return `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Plozz — Error</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      background: #1a1a2e; color: #fff;
      display: flex; align-items: center; justify-content: center;
      min-height: 100vh; padding: 24px;
    }
    .card {
      background: #16213e; border-radius: 20px; padding: 48px;
      text-align: center; max-width: 420px; width: 100%;
    }
    .icon { font-size: 64px; margin-bottom: 16px; }
    h1 { font-size: 24px; margin-bottom: 12px; }
    p { color: #a0a0b0; font-size: 16px; }
  </style>
</head>
<body>
  <div class="card">
    <div class="icon">✗</div>
    <h1>Something went wrong</h1>
    <p>${message}</p>
  </div>
</body>
</html>`;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    // --- MAL: Start auth ---
    if (path === "/auth/mal") {
      const codeVerifier = generateCodeVerifier();
      const sessionId = randomString(32);

      // Store PKCE verifier in KV (needed for callback)
      await env.AUTH_KV.put(`session:${sessionId}`, JSON.stringify({
        service: "mal",
        codeVerifier,
        createdAt: Date.now(),
      }), { expirationTtl: CODE_TTL });

      // Redirect to MAL authorize
      const malAuthURL = new URL("https://myanimelist.net/v1/oauth2/authorize");
      malAuthURL.searchParams.set("response_type", "code");
      malAuthURL.searchParams.set("client_id", env.MAL_CLIENT_ID);
      malAuthURL.searchParams.set("code_challenge", codeVerifier);
      malAuthURL.searchParams.set("code_challenge_method", "plain");
      malAuthURL.searchParams.set("redirect_uri", `${BASE_URL}/auth/mal/callback`);
      malAuthURL.searchParams.set("state", sessionId);

      return Response.redirect(malAuthURL.toString(), 302);
    }

    // --- MAL: Callback ---
    if (path === "/auth/mal/callback") {
      const code = url.searchParams.get("code");
      const state = url.searchParams.get("state");

      if (!code || !state) {
        return new Response(errorPage("Missing authorization code."), {
          status: 400, headers: { "Content-Type": "text/html" }
        });
      }

      // Retrieve session
      const sessionData = await env.AUTH_KV.get(`session:${state}`, "json");
      if (!sessionData) {
        return new Response(errorPage("Session expired. Please try again from your TV."), {
          status: 410, headers: { "Content-Type": "text/html" }
        });
      }

      // Exchange code for token
      const tokenResp = await fetch("https://myanimelist.net/v1/oauth2/token", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          grant_type: "authorization_code",
          client_id: env.MAL_CLIENT_ID,
          code,
          code_verifier: sessionData.codeVerifier,
          redirect_uri: `${BASE_URL}/auth/mal/callback`,
        }),
      });

      if (!tokenResp.ok) {
        const err = await tokenResp.text();
        return new Response(errorPage("Token exchange failed. Please try again."), {
          status: 502, headers: { "Content-Type": "text/html" }
        });
      }

      const tokens = await tokenResp.json();

      // Generate short redeem code and store tokens
      const redeemCode = generateRedeemCode();
      await env.AUTH_KV.put(`redeem:${redeemCode}`, JSON.stringify({
        service: "mal",
        accessToken: tokens.access_token,
        refreshToken: tokens.refresh_token,
        expiresIn: tokens.expires_in,
      }), { expirationTtl: CODE_TTL });

      // Clean up session
      await env.AUTH_KV.delete(`session:${state}`);

      return new Response(successPage(redeemCode), {
        headers: { "Content-Type": "text/html" }
      });
    }

    // --- AniList: Start auth ---
    if (path === "/auth/anilist") {
      const sessionId = randomString(32);

      await env.AUTH_KV.put(`session:${sessionId}`, JSON.stringify({
        service: "anilist",
        createdAt: Date.now(),
      }), { expirationTtl: CODE_TTL });

      const aniAuthURL = new URL("https://anilist.co/api/v2/oauth/authorize");
      aniAuthURL.searchParams.set("client_id", env.ANILIST_CLIENT_ID);
      aniAuthURL.searchParams.set("response_type", "code");
      aniAuthURL.searchParams.set("redirect_uri", `${BASE_URL}/auth/anilist/callback`);
      aniAuthURL.searchParams.set("state", sessionId);

      return Response.redirect(aniAuthURL.toString(), 302);
    }

    // --- AniList: Callback ---
    if (path === "/auth/anilist/callback") {
      const code = url.searchParams.get("code");
      const state = url.searchParams.get("state");

      if (!code || !state) {
        return new Response(errorPage("Missing authorization code."), {
          status: 400, headers: { "Content-Type": "text/html" }
        });
      }

      const sessionData = await env.AUTH_KV.get(`session:${state}`, "json");
      if (!sessionData) {
        return new Response(errorPage("Session expired. Please try again from your TV."), {
          status: 410, headers: { "Content-Type": "text/html" }
        });
      }

      // Exchange code for token
      const tokenResp = await fetch("https://anilist.co/api/v2/oauth/token", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
        },
        body: JSON.stringify({
          grant_type: "authorization_code",
          client_id: env.ANILIST_CLIENT_ID,
          client_secret: env.ANILIST_CLIENT_SECRET,
          redirect_uri: `${BASE_URL}/auth/anilist/callback`,
          code,
        }),
      });

      if (!tokenResp.ok) {
        return new Response(errorPage("Token exchange failed. Please try again."), {
          status: 502, headers: { "Content-Type": "text/html" }
        });
      }

      const tokens = await tokenResp.json();

      const redeemCode = generateRedeemCode();
      await env.AUTH_KV.put(`redeem:${redeemCode}`, JSON.stringify({
        service: "anilist",
        accessToken: tokens.access_token,
      }), { expirationTtl: CODE_TTL });

      await env.AUTH_KV.delete(`session:${state}`);

      return new Response(successPage(redeemCode), {
        headers: { "Content-Type": "text/html" }
      });
    }

    // --- Redeem: TV calls this to get the token ---
    if (path === "/api/redeem") {
      const code = url.searchParams.get("code");
      if (!code) {
        return Response.json({ error: "missing_code" }, { status: 400 });
      }

      const data = await env.AUTH_KV.get(`redeem:${code.toUpperCase()}`, "json");
      if (!data) {
        return Response.json({ error: "invalid_or_expired" }, { status: 404 });
      }

      // One-time use: delete after retrieval
      await env.AUTH_KV.delete(`redeem:${code.toUpperCase()}`);

      return Response.json(data, {
        headers: { "Access-Control-Allow-Origin": "*" }
      });
    }

    // --- CORS preflight ---
    if (request.method === "OPTIONS" && path === "/api/redeem") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET",
          "Access-Control-Allow-Headers": "Content-Type",
        }
      });
    }

    // --- 404 ---
    return new Response("Not found", { status: 404 });
  },
};
