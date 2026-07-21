// Plozz pairing links Worker.
//
// Serves exactly two paths on plozz.app (see wrangler.toml routes):
//   1. /.well-known/apple-app-site-association
//        The Apple App Site Association (AASA) file that lets iOS treat
//        https://plozz.app/pair as a Universal Link into the Plozz app.
//   2. /pair
//        The Universal Link target. When Plozz is INSTALLED, iOS intercepts the
//        link before this page ever loads and opens the app straight into the
//        "Set up another device" flow (the pairing payload rides in the URL
//        fragment, so it never reaches this server). When Plozz is NOT installed,
//        Safari loads this page, which explains how to get Plozz and finish setup.
//
// Everything else on plozz.app is still served by the existing `plozz-website`
// Cloudflare Pages project — this Worker only claims these two paths.

const APP_ID = "N8Z5T4AK3X.com.thatcube.Plozz";

// Public App Store URL for Plozz. Leave empty until the app is published; the
// /pair page adapts its copy when this is empty. TestFlight public link also
// works here once available.
const APP_STORE_URL = "";

const AASA = {
  applinks: {
    apps: [],
    details: [
      {
        appID: APP_ID,
        appIDs: [APP_ID],
        paths: ["/pair", "/pair/*"],
        components: [{ "/": "/pair" }, { "/": "/pair/*" }],
      },
    ],
  },
};

export default {
  async fetch(request) {
    const url = new URL(request.url);

    if (url.pathname === "/.well-known/apple-app-site-association") {
      return new Response(JSON.stringify(AASA), {
        headers: {
          "content-type": "application/json",
          "cache-control": "public, max-age=3600",
        },
      });
    }

    if (url.pathname === "/pair") {
      return new Response(pairPage(), {
        headers: {
          "content-type": "text/html; charset=utf-8",
          "cache-control": "no-store",
        },
      });
    }

    // Should not happen given the routes, but fall through gracefully.
    return new Response("Not found", { status: 404 });
  },
};

function pairPage() {
  const hasStore = APP_STORE_URL.length > 0;
  const cta = hasStore
    ? `<a class="btn" href="${APP_STORE_URL}">Get Plozz</a>`
    : `<p class="soon">Plozz isn’t on the App Store just yet.</p>`;

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="dark light">
<title>Set up Plozz</title>
<style>
  :root { color-scheme: dark light; }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
    font: 16px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    background: radial-gradient(120% 120% at 50% 0%, #1c2140 0%, #0b0d18 60%, #05060c 100%);
    color: #f2f3f8; padding: 32px;
  }
  .card {
    max-width: 420px; width: 100%; text-align: center;
    background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.08);
    border-radius: 24px; padding: 40px 28px; backdrop-filter: blur(20px);
  }
  .logo {
    width: 72px; height: 72px; margin: 0 auto 20px; border-radius: 18px;
    display: flex; align-items: center; justify-content: center; font-size: 38px;
    background: linear-gradient(135deg, #6d7bff, #a45bff);
  }
  h1 { font-size: 24px; margin: 0 0 10px; letter-spacing: -0.02em; }
  p { margin: 0 0 14px; color: #c6c9da; }
  .soon { color: #ffd479; font-weight: 600; }
  .btn {
    display: inline-block; margin-top: 12px; padding: 14px 26px; border-radius: 14px;
    background: #fff; color: #0b0d18; font-weight: 700; text-decoration: none;
  }
  ol { text-align: left; margin: 20px auto 0; max-width: 320px; color: #c6c9da; padding-left: 22px; }
  li { margin-bottom: 8px; }
  .foot { margin-top: 26px; font-size: 13px; color: #7f849c; }
</style>
</head>
<body>
  <main class="card">
    <div class="logo">▶</div>
    <h1>Finish setting up Plozz</h1>
    <p>You scanned a Plozz pairing code. Open this link on a device that already
       has <strong>Plozz</strong> installed to sign it in automatically.</p>
    ${cta}
    <ol>
      <li>Install Plozz on the device you’re setting up (if it isn’t already).</li>
      <li>Open Plozz and choose <strong>“Set up from another device.”</strong></li>
      <li>On a device that’s already signed in, scan the code shown — everything
          transfers privately over your local network.</li>
    </ol>
    <p class="foot">Your pairing details are never sent to this page — they stay
       on your devices, end-to-end encrypted.</p>
  </main>
</body>
</html>`;
}
