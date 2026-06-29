// Plozz Auth Relay — Cloudflare Worker
// Handles OAuth for MAL and AniList on behalf of the tvOS app.
//
// See worker/README.md for full docs (architecture, endpoints, deploy, gotchas).
//
// Flow (high level):
// 1. TV shows a QR for plozz.app/myanimelist or plozz.app/anilist.
// 2. User opens it on their phone and approves with the provider.
// 3. MAL: Worker exchanges the code for a token server-side (PKCE + secret).
//    AniList: Worker IPs are blocked, so the token arrives in the URL fragment
//    (implicit grant) and a browser page POSTs it back to /api/store.
// 4. Worker stores the token in KV under a single-use 4-digit redeem code.
// 5. User types the 4 digits on the TV.
// 6. TV calls /api/redeem?code=NNNN → gets the token (code is then deleted).
//
// 4-digit numeric codes are used because they're easy to DICTATE into the
// Apple TV remote (letter dictation via Siri is unreliable).

const BASE_URL = "https://plozz.app";
const CODE_TTL = 600; // 10 minutes

// Inline logos as data URIs for instant loading
const PLOZZ_LOGO = "data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMzIiIGhlaWdodD0iMzIiIHZpZXdCb3g9IjAgMCAzMiAzMiIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj4KPGcgY2xpcC1wYXRoPSJ1cmwoI2NsaXAwXzEyNF8xMjU1KSI+CjxwYXRoIGQ9Ik00IDExSDNWMTNWMjNWMjVINFYyN0g1VjI4SDdIMjVIMjZWMjdIMjdWMjZIMjhWMjVIMjlWMjJWMTNWMTFIMjhWOUgyN1Y4SDI2SDI0SDhIN0g1VjlINFYxMVoiIGZpbGw9IiMwMEE0REMiLz4KPHJlY3QgeD0iNSIgeT0iMjkiIHdpZHRoPSIyMiIgaGVpZ2h0PSIxIiBmaWxsPSJibGFjayIvPgo8cmVjdCB4PSIyNyIgeT0iMjgiIHdpZHRoPSIxIiBoZWlnaHQ9IjEiIGZpbGw9ImJsYWNrIi8+CjxyZWN0IHg9IjI4IiB5PSIyNyIgd2lkdGg9IjEiIGhlaWdodD0iMSIgZmlsbD0iYmxhY2siLz4KPHJlY3QgeD0iMjkiIHk9IjI1IiB3aWR0aD0iMSIgaGVpZ2h0PSIyIiBmaWxsPSJibGFjayIvPgo8cmVjdCB4PSIyOSIgeT0iOSIgd2lkdGg9IjEiIGhlaWdodD0iMTYiIGZpbGw9ImJsYWNrIi8+CjxyZWN0IHg9IjI4IiB5PSI4IiB3aWR0aD0iMSIgaGVpZ2h0PSIxIiBmaWxsPSJibGFjayIvPgo8cmVjdCB4PSIyNyIgeT0iNyIgd2lkdGg9IjEiIGhlaWdodD0iMSIgZmlsbD0iYmxhY2siLz4KPHJlY3QgeD0iMjUiIHk9IjYiIHdpZHRoPSIyIiBoZWlnaHQ9IjEiIGZpbGw9ImJsYWNrIi8+CjxyZWN0IHg9IjciIHk9IjYiIHdpZHRoPSIxOCIgaGVpZ2h0PSIxIiBmaWxsPSJibGFjayIvPgo8cmVjdCB4PSI1IiB5PSI2IiB3aWR0aD0iMiIgaGVpZ2h0PSIxIiBmaWxsPSJibGFjayIvPgo8cmVjdCB4PSI0IiB5PSI3IiB3aWR0aD0iMSIgaGVpZ2h0PSIxIiBmaWxsPSJibGFjayIvPgo8cmVjdCB4PSIxMyIgeT0iNSIgd2lkdGg9IjEiIGhlaWdodD0iMSIgZmlsbD0iYmxhY2siLz4KPHJlY3QgeD0iMTQiIHk9IjUiIHdpZHRoPSIxIiBoZWlnaHQ9IjEiIGZpbGw9ImJsYWNrIi8+CjxyZWN0IHg9IjE1IiB5PSI0IiB3aWR0aD0iMSIgaGVpZ2h0PSIxIiBmaWxsPSJibGFjayIvPgo8cmVjdCB4PSIxNiIgeT0iMyIgd2lkdGg9IjEiIGhlaWdodD0iMSIgZmlsbD0iYmxhY2siLz4KPHJlY3QgeD0iMTciIHk9IjIiIHdpZHRoPSIxIiBoZWlnaHQ9IjEiIGZpbGw9ImJsYWNrIi8+CjxyZWN0IHg9IjE4IiB5PSIyIiB3aWR0aD0iMSIgaGVpZ2h0PSIxIiBmaWxsPSJibGFjayIvPgo8cmVjdCB4PSIxNyIgeT0iMyIgd2lkdGg9IjEiIGhlaWdodD0iMSIgZmlsbD0iYmxhY2siLz4KPHJlY3QgeD0iMTYiIHk9IjQiIHdpZHRoPSIxIiBoZWlnaHQ9IjEiIGZpbGw9ImJsYWNrIi8+CjxyZWN0IHg9IjE1IiB5PSI1IiB3aWR0aD0iMSIgaGVpZ2h0PSIxIiBmaWxsPSJibGFjayIvPgo8cmVjdCB4PSIxMiIgeT0iNSIgd2lkdGg9IjEiIGhlaWdodD0iMSIgZmlsbD0iYmxhY2siLz4KPHJlY3QgeD0iMTEiIHk9IjQiIHdpZHRoPSIxIiBoZWlnaHQ9IjEiIGZpbGw9ImJsYWNrIi8+CjxyZWN0IHg9IjEwIiB5PSIzIiB3aWR0aD0iMSIgaGVpZ2h0PSIxIiBmaWxsPSJibGFjayIvPgo8cmVjdCB4PSI5IiB5PSIyIiB3aWR0aD0iMSIgaGVpZ2h0PSIxIiBmaWxsPSJibGFjayIvPgo8cmVjdCB4PSIxMiIgeT0iNCIgd2lkdGg9IjEiIGhlaWdodD0iMSIgZmlsbD0iYmxhY2siLz4KPHJlY3QgeD0iMTEiIHk9IjMiIHdpZHRoPSIxIiBoZWlnaHQ9IjEiIGZpbGw9ImJsYWNrIi8+CjxyZWN0IHg9IjEwIiB5PSIyIiB3aWR0aD0iMSIgaGVpZ2h0PSIxIiBmaWxsPSJibGFjayIvPgo8cmVjdCB4PSIzIiB5PSI4IiB3aWR0aD0iMSIgaGVpZ2h0PSIxIiBmaWxsPSJibGFjayIvPgo8cmVjdCB4PSIyIiB5PSI5IiB3aWR0aD0iMSIgaGVpZ2h0PSIxNiIgZmlsbD0iYmxhY2siLz4KPHJlY3QgeD0iMiIgeT0iMjUiIHdpZHRoPSIxIiBoZWlnaHQ9IjIiIGZpbGw9ImJsYWNrIi8+CjxyZWN0IHg9IjMiIHk9IjI3IiB3aWR0aD0iMSIgaGVpZ2h0PSIxIiBmaWxsPSJibGFjayIvPgo8cmVjdCB4PSI0IiB5PSIyOCIgd2lkdGg9IjEiIGhlaWdodD0iMSIgZmlsbD0iYmxhY2siLz4KPHJlY3QgeD0iMyIgeT0iMjUiIHdpZHRoPSIxIiBoZWlnaHQ9IjIiIGZpbGw9IiMwMDdBQUYiLz4KPHJlY3QgeD0iNCIgeT0iMjciIHdpZHRoPSIxIiBoZWlnaHQ9IjEiIGZpbGw9IiMwMDdBQUYiLz4KPHJlY3QgeD0iMjgiIHk9IjI1IiB3aWR0aD0iMSIgaGVpZ2h0PSIyIiBmaWxsPSIjMDA3QUFGIi8+CjxyZWN0IHg9IjI3IiB5PSIyNiIgd2lkdGg9IjEiIGhlaWdodD0iMiIgZmlsbD0iIzAwN0FBRiIvPgo8cmVjdCB4PSIyNiIgeT0iMjciIHdpZHRoPSIxIiBoZWlnaHQ9IjEiIGZpbGw9IiMwMDdBQUYiLz4KPHJlY3QgeD0iMjYiIHk9IjI4IiB3aWR0aD0iMSIgaGVpZ2h0PSIxIiBmaWxsPSIjMDA3QUFGIi8+CjxyZWN0IHg9IjI0IiB5PSIyOCIgd2lkdGg9IjIiIGhlaWdodD0iMSIgZmlsbD0iIzAwN0FBRiIvPgo8cmVjdCB4PSI1IiB5PSIyOCIgd2lkdGg9IjE5IiBoZWlnaHQ9IjEiIGZpbGw9IiMwMEE0REMiLz4KPHJlY3QgeD0iNSIgeT0iMjgiIHdpZHRoPSIxIiBoZWlnaHQ9IjEiIGZpbGw9IiMwMDdBQUYiLz4KPHJlY3QgeD0iNiIgeT0iMjgiIHdpZHRoPSIxIiBoZWlnaHQ9IjEiIGZpbGw9IiMwMDdBQUYiLz4KPHJlY3QgeD0iNyIgeT0iMjgiIHdpZHRoPSIxNyIgaGVpZ2h0PSIxIiBmaWxsPSIjMDA3QUFGIi8+CjxyZWN0IHg9IjMiIHk9IjkiIHdpZHRoPSIxIiBoZWlnaHQ9IjIiIGZpbGw9IiM0MUM2RjUiLz4KPHJlY3QgeD0iNCIgeT0iOCIgd2lkdGg9IjEiIGhlaWdodD0iMSIgZmlsbD0iIzQxQzZGNSIvPgo8cmVjdCB4PSI1IiB5PSI3IiB3aWR0aD0iMiIgaGVpZ2h0PSIxIiBmaWxsPSIjNDFDNkY1Ii8+CjxyZWN0IHg9IjciIHk9IjciIHdpZHRoPSIxOCIgaGVpZ2h0PSIxIiBmaWxsPSIjMDBBNERDIi8+CjxyZWN0IHg9IjciIHk9IjciIHdpZHRoPSIyMCIgaGVpZ2h0PSIxIiBmaWxsPSIjNDFDNkY1Ii8+CjxyZWN0IHg9IjI3IiB5PSI4IiB3aWR0aD0iMSIgaGVpZ2h0PSIxIiBmaWxsPSIjNDFDNkY1Ii8+CjxyZWN0IHg9IjI4IiB5PSI5IiB3aWR0aD0iMSIgaGVpZ2h0PSIyIiBmaWxsPSIjNDFDNkY1Ii8+CjxyZWN0IHg9IjE3IiB5PSIxMyIgd2lkdGg9IjQiIGhlaWdodD0iMSIgZmlsbD0iYmxhY2siLz4KPHJlY3QgeD0iMTkiIHk9IjE0IiB3aWR0aD0iMiIgaGVpZ2h0PSIxIiBmaWxsPSJibGFjayIvPgo8cmVjdCB4PSIxOCIgeT0iMTUiIHdpZHRoPSIyIiBoZWlnaHQ9IjEiIGZpbGw9ImJsYWNrIi8+CjxyZWN0IHg9IjE3IiB5PSIxNiIgd2lkdGg9IjIiIGhlaWdodD0iMSIgZmlsbD0iYmxhY2siLz4KPHJlY3QgeD0iMTciIHk9IjE3IiB3aWR0aD0iMSIgaGVpZ2h0PSIxIiBmaWxsPSJibGFjayIvPgo8cmVjdCB4PSIxNyIgeT0iMTciIHdpZHRoPSI0IiBoZWlnaHQ9IjEiIGZpbGw9ImJsYWNrIi8+CjxyZWN0IHg9IjExIiB5PSIxMyIgd2lkdGg9IjQiIGhlaWdodD0iMSIgZmlsbD0iYmxhY2siLz4KPHJlY3QgeD0iMTMiIHk9IjE0IiB3aWR0aD0iMiIgaGVpZ2h0PSIxIiBmaWxsPSJibGFjayIvPgo8cmVjdCB4PSIxMiIgeT0iMTUiIHdpZHRoPSIyIiBoZWlnaHQ9IjEiIGZpbGw9ImJsYWNrIi8+CjxyZWN0IHg9IjExIiB5PSIxNiIgd2lkdGg9IjIiIGhlaWdodD0iMSIgZmlsbD0iYmxhY2siLz4KPHJlY3QgeD0iMTEiIHk9IjE3IiB3aWR0aD0iMSIgaGVpZ2h0PSIxIiBmaWxsPSJibGFjayIvPgo8cmVjdCB4PSIxMSIgeT0iMTciIHdpZHRoPSI0IiBoZWlnaHQ9IjEiIGZpbGw9ImJsYWNrIi8+CjxyZWN0IHg9IjEyIiB5PSIyMCIgd2lkdGg9IjEiIGhlaWdodD0iMiIgZmlsbD0iYmxhY2siLz4KPHJlY3QgeD0iMTMiIHk9IjIxIiB3aWR0aD0iMSIgaGVpZ2h0PSIyIiBmaWxsPSJibGFjayIvPgo8cmVjdCB4PSIxOCIgeT0iMjEiIHdpZHRoPSIxIiBoZWlnaHQ9IjIiIGZpbGw9ImJsYWNrIi8+CjxyZWN0IHg9IjE5IiB5PSIyMCIgd2lkdGg9IjEiIGhlaWdodD0iMiIgZmlsbD0iYmxhY2siLz4KPHJlY3QgeD0iMTQiIHk9IjIyIiB3aWR0aD0iNCIgaGVpZ2h0PSIxIiBmaWxsPSJibGFjayIvPgo8cmVjdCB4PSI1IiB5PSIxMSIgd2lkdGg9IjEiIGhlaWdodD0iMTQiIGZpbGw9ImJsYWNrIi8+CjxyZWN0IHg9IjI2IiB5PSIxMSIgd2lkdGg9IjEiIGhlaWdodD0iMTQiIGZpbGw9ImJsYWNrIi8+CjxyZWN0IHg9IjYiIHk9IjI1IiB3aWR0aD0iMSIgaGVpZ2h0PSIxIiBmaWxsPSJibGFjayIvPgo8cmVjdCB4PSIyNSIgeT0iMjUiIHdpZHRoPSIxIiBoZWlnaHQ9IjEiIGZpbGw9ImJsYWNrIi8+CjxyZWN0IHg9IjYiIHk9IjEwIiB3aWR0aD0iMSIgaGVpZ2h0PSIxIiBmaWxsPSJibGFjayIvPgo8cmVjdCB4PSIyNSIgeT0iMTAiIHdpZHRoPSIxIiBoZWlnaHQ9IjEiIGZpbGw9ImJsYWNrIi8+CjxyZWN0IHg9IjciIHk9IjI2IiB3aWR0aD0iMTgiIGhlaWdodD0iMSIgZmlsbD0iYmxhY2siLz4KPHJlY3QgeD0iNyIgeT0iOSIgd2lkdGg9IjE4IiBoZWlnaHQ9IjEiIGZpbGw9ImJsYWNrIi8+CjwvZz4KPGRlZnM+CjxjbGlwUGF0aCBpZD0iY2xpcDBfMTI0XzEyNTUiPgo8cmVjdCB3aWR0aD0iMjgiIGhlaWdodD0iMjgiIGZpbGw9IndoaXRlIiB0cmFuc2Zvcm09InRyYW5zbGF0ZSgyIDIpIi8+CjwvY2xpcFBhdGg+CjwvZGVmcz4KPC9zdmc+Cg==";
const ANILIST_LOGO = "data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iNTEyIiBoZWlnaHQ9IjUxMiIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj48dGl0bGU+QW5pTGlzdCBsb2dvPC90aXRsZT48ZGVzYz5BbmltZSBhbmQgbWFuZ2EgdHJhY2tpbmcgd2Vic2l0ZTwvZGVzYz48cGF0aCBkPSJNMCAwaDUxMnY1MTJIMCIgZmlsbD0iIzFlMjYzMCIvPjxwYXRoIGQ9Ik0zMjEuOTIgMzIzLjI3VjEzNi42YzAtMTAuNjk4LTUuODg3LTE2LjYwMi0xNi41NTgtMTYuNjAyaC0zNi40MzNjLTEwLjY3MiAwLTE2LjU2MSA1LjkwNC0xNi41NjEgMTYuNjAydjg4LjY1MWMwIDIuNDk3IDIzLjk5NiAxNC4wODkgMjQuNjIzIDE2LjU0MSAxOC4yODIgNzEuNjEgMy45NzIgMTI4LjkyLTEzLjM1OSAxMzEuNiAyOC4zMzcgMS40MDUgMzEuNDU1IDE1LjA2NCAxMC4zNDggNS43MzEgMy4yMjktMzguMjA5IDE1LjgyOC0zOC4xMzQgNTIuMDQ5LTEuNDA2LjMxLjMxNyA3LjQyNyAxNS4yODIgNy44NyAxNS4yODJoODUuNTQ1YzEwLjY3MiAwIDE2LjU1OC01LjkgMTYuNTU4LTE2LjZ2LTM2LjUyNGMwLTEwLjY5OC01Ljg4Ni0xNi42MDItMTYuNTU4LTE2LjYwMnoiIGZpbGw9IiMwMmE5ZmYiLz48cGF0aCBkPSJNMTcwLjY4IDEyMCA3NC45OTkgMzkzaDc0LjMzOGwxNi4xOTItNDcuMjIyaDgwLjk2TDI2Mi4zMTUgMzkzaDczLjk2OGwtOTUuMzE0LTI3M3ptMTEuNzc2IDE2NS4yOCAyMy4xODMtNzUuNjI5IDI1LjM5MyA3NS42Mjl6IiBmaWxsPSIjZmVmZWZlIi8+PC9zdmc+";
const MAL_LOGO = "data:image/png;base64,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";

// Generate a cryptographically random string
function randomString(length) {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789";
  const arr = new Uint8Array(length);
  crypto.getRandomValues(arr);
  return Array.from(arr, (b) => chars[b % chars.length]).join("");
}

// Generate a 4-digit redeem code (digits only — easy to dictate on Apple TV)
function generateRedeemCode() {
  const arr = new Uint8Array(4);
  crypto.getRandomValues(arr);
  return Array.from(arr, (b) => String(b % 10)).join("");
}

// Generate PKCE code_verifier (43-128 chars, URL-safe)
function generateCodeVerifier() {
  return randomString(64);
}

// Success page HTML
function successPage(code, service) {
  const logos = {
    mal: {
      url: MAL_LOGO,
      name: "MyAnimeList",
    },
    anilist: {
      url: ANILIST_LOGO,
      name: "AniList",
    },
  };
  const svc = logos[service] || { url: "", name: "Service" };
  const codeDigits = String(code).split("").map((d) => `<span>${d}</span>`).join("");
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
      background: #16213e; border-radius: 24px; padding: 40px 36px;
      text-align: center; max-width: 460px; width: 100%;
      box-shadow: 0 20px 60px rgba(0,0,0,.4);
      container-type: inline-size;
    }
    .logos {
      display: flex; align-items: center; justify-content: center;
      gap: 14px; margin-bottom: 52px;
    }
    .logos img {
      width: 60px; height: 60px; border-radius: 12px;
      object-fit: contain;
    }
    .connector {
      display: flex; align-items: center; gap: 4px;
    }
    .connector .dot {
      width: 5px; height: 5px; border-radius: 50%; background: #fff;
    }
    .connector .line {
      width: 28px; height: 2px; background: #fff;
    }
    .subtitle { color: #c8c8d4; font-size: 19px; font-weight: 600; margin-bottom: 30px; }
    .code {
      display: flex; justify-content: center; align-items: center; gap: 0.1em;
      width: fit-content; max-width: 100%; margin: 0 auto; line-height: 1;
      font-family: 'SF Mono', 'Menlo', 'Cascadia Code', 'Fira Code', monospace;
      font-size: clamp(44px, 30cqi, 104px); font-weight: 700; color: #fff;
      background: #0a2a4a; border-radius: 14px; padding: 20px 40px;
      box-sizing: border-box;
    }
    .code span { flex: 0 0 auto; text-align: center; }
    .hint { color: #85889a; font-size: 13px; margin-top: 20px; }
  </style>
</head>
<body>
  <div class="card">
    <div class="logos">
      <img src="${svc.url}" alt="${svc.name}">
      <div class="connector"><div class="dot"></div><div class="line"></div><div class="dot"></div></div>
      <img src="${PLOZZ_LOGO}" alt="Plozz">
    </div>
    <p class="subtitle">Enter code on your Apple TV</p>
    <div class="code">${codeDigits}</div>
    <p class="hint">Expires in 10 minutes</p>
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

// AniList implicit grant landing page — reads token from URL fragment,
// stores it via /api/store, and shows the redeem code.
function anilistImplicitPage() {
  return `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Plozz — Connecting to AniList...</title>
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
      text-align: center; max-width: 460px; width: 100%;
      container-type: inline-size;
    }
    .logos {
      display: flex; align-items: center; justify-content: center;
      gap: 14px; margin-bottom: 52px;
    }
    .logos img {
      width: 60px; height: 60px; border-radius: 12px;
      object-fit: contain;
    }
    .connector {
      display: flex; align-items: center; gap: 4px;
    }
    .connector .dot {
      width: 6px; height: 6px; border-radius: 50%; background: #fff;
    }
    .connector .line {
      width: 32px; height: 2px; background: #fff;
    }
    .subtitle { color: #c8c8d4; font-size: 19px; font-weight: 600; margin-bottom: 30px; }
    .code {
      display: flex; justify-content: center; align-items: center; gap: 0.1em;
      width: fit-content; max-width: 100%; margin: 30px auto; line-height: 1;
      font-family: 'SF Mono', 'Menlo', 'Cascadia Code', 'Fira Code', monospace;
      font-size: clamp(44px, 30cqi, 104px); font-weight: 700; color: #fff;
      background: #0a2a4a; border-radius: 14px; padding: 20px 40px;
      box-sizing: border-box;
    }
    .code span { flex: 0 0 auto; text-align: center; }
    .icon { font-size: 64px; margin-bottom: 16px; }
    h1 { font-size: 22px; margin-bottom: 8px; }
    p { color: #a0a0b0; font-size: 16px; }
    .hint { color: #85889a; font-size: 13px; margin-top: 20px; }
    .spinner { display: inline-block; width: 48px; height: 48px; border: 4px solid #0f3460; border-top-color: #4fc3f7; border-radius: 50%; animation: spin 1s linear infinite; margin-bottom: 16px; }
    @keyframes spin { to { transform: rotate(360deg); } }
    .error { color: #ff6b6b; }
  </style>
</head>
<body>
  <div class="card" id="card">
    <div class="spinner"></div>
    <h1>Connecting to AniList...</h1>
    <p>Please wait a moment.</p>
  </div>
  <script>
    (async () => {
      const card = document.getElementById('card');
      try {
        const hash = window.location.hash.substring(1);
        const params = new URLSearchParams(hash);
        const accessToken = params.get('access_token');
        if (!accessToken) throw new Error('No access token received from AniList.');
        const storeResp = await fetch('${BASE_URL}/api/store', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ service: 'anilist', accessToken }),
        });
        if (!storeResp.ok) throw new Error('Failed to store token');
        const { code } = await storeResp.json();
        const codeDigits = String(code).split('').map(function(d){ return '<span>' + d + '</span>'; }).join('');
        card.innerHTML = '<div class="logos"><img src="${ANILIST_LOGO}" alt="AniList"><div class="connector"><div class="dot"></div><div class="line"></div><div class="dot"></div></div><img src="${PLOZZ_LOGO}" alt="Plozz"></div><p class="subtitle">Enter code on your Apple TV</p><div class="code">' + codeDigits + '</div><p class="hint">Expires in 10 minutes</p>';
      } catch (e) {
        card.innerHTML = '<div class="icon">✗</div><h1>Something went wrong</h1><p class="error">' + e.message + '</p>';
      }
    })();
  </script>
</body>
</html>`;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    // --- MAL: Start auth ---
    if (path === "/myanimelist") {
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
          client_secret: env.MAL_CLIENT_SECRET,
          code,
          code_verifier: sessionData.codeVerifier,
          redirect_uri: `${BASE_URL}/auth/mal/callback`,
        }),
      });

      if (!tokenResp.ok) {
        const errBody = await tokenResp.text();
        return new Response(errorPage(`Token exchange failed: ${errBody}`), {
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

      return new Response(successPage(redeemCode, "mal"), {
        headers: { "Content-Type": "text/html" }
      });
    }

    // --- AniList: Start auth (implicit grant) ---
    if (path === "/anilist") {
      const aniAuthURL = new URL("https://anilist.co/api/v2/oauth/authorize");
      aniAuthURL.searchParams.set("client_id", env.ANILIST_CLIENT_ID);
      aniAuthURL.searchParams.set("response_type", "token");

      return Response.redirect(aniAuthURL.toString(), 302);
    }

    // --- AniList: Implicit grant landing page ---
    // AniList redirects to the registered redirect_uri with #access_token=...
    // The fragment is only visible to JS, so we serve a page that reads it.
    if (path === "/auth/anilist/callback") {
      return new Response(anilistImplicitPage(), {
        headers: { "Content-Type": "text/html" }
      });
    }

    // --- Store: browser-side token exchange results ---
    if (path === "/api/store" && request.method === "POST") {
      try {
        const body = await request.json();
        if (!body.service || !body.accessToken) {
          return Response.json({ error: "missing_fields" }, { status: 400 });
        }
        const redeemCode = generateRedeemCode();
        await env.AUTH_KV.put(`redeem:${redeemCode}`, JSON.stringify({
          service: body.service,
          accessToken: body.accessToken,
          refreshToken: body.refreshToken || null,
          expiresIn: body.expiresIn || null,
        }), { expirationTtl: CODE_TTL });
        return Response.json({ code: redeemCode }, {
          headers: { "Access-Control-Allow-Origin": "*" }
        });
      } catch {
        return Response.json({ error: "invalid_body" }, { status: 400 });
      }
    }

    // CORS preflight for /api/store
    if (path === "/api/store" && request.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "POST",
          "Access-Control-Allow-Headers": "Content-Type",
        }
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
