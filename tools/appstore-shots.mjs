#!/usr/bin/env node
/**
 * Composes App Store Connect screenshots from the captures in build/shots.
 *
 * App Store screenshots are not raw captures. A raw 3840x2160 frame of a
 * detail page is legible on a laptop and unreadable in the 200px-wide strip a
 * shopper actually scrolls past, so every panel here pairs the capture with one
 * short line saying what it is. Apple allows this — the rule is that the shot
 * must depict the real app, which it does: the frames are the app photographing
 * itself against a real library.
 *
 * Panels are laid out in HTML and rendered by headless Chrome rather than
 * composited with ImageMagick, because they have to sit next to the marketing
 * site without looking like a different product. Sharing the site's tokens —
 * its background, its Jellyfin blue, its type scale, its corner radii — is
 * something CSS does for free and a compositing pipeline does badly.
 *
 *   node tools/appstore-shots.mjs                # every platform it has shots for
 *   node tools/appstore-shots.mjs --platform tv
 *   node tools/appstore-shots.mjs --out DIR
 *   node tools/appstore-shots.mjs --keep-html    # leave the intermediate pages
 *
 * Output sizes are the ones App Store Connect asks for:
 *   Apple TV     3840 x 2160   (landscape)
 *   iPhone 6.9"  1320 x 2868   (portrait; scales down to every smaller iPhone)
 *   iPad 13"     2064 x 2752   (portrait; scales down to every smaller iPad)
 *
 * Ten panels per platform is the maximum Apple accepts; the lists below stay
 * under it.
 */

import { mkdir, readdir, rm, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import path from 'node:path';

const run = promisify(execFile);

const ROOT = path.resolve(import.meta.dirname, '..');
/**
 * Captures land in one directory per platform, because a tvOS run and an iOS
 * run are separate simulator sessions and were overwriting each other's output
 * when they shared one.
 */
const SHOT_DIRS = [
  path.join(ROOT, 'build', 'shots'),
  path.join(ROOT, 'build', 'shots-ios'),
];
const CHROME =
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

/**
 * The site's tokens, copied rather than imported because the site is a separate
 * repo that this must not depend on. If they drift, these are the ones to fix.
 */
const TOKENS = {
  bg: '#080809',
  text: '#f2f2f3',
  muted: '#b0b0b5',
  brand: '#00a4dc',
  brand2: '#aa5cc3',
  border: '#29292d',
};

/**
 * Each panel is a capture plus the one thing that panel is there to say.
 *
 * The lines are deliberately flat statements of fact rather than slogans. The
 * app's whole pitch is that it plays what you already own without asking for an
 * account, and that reads as more credible unadorned.
 */
const PLATFORMS = {
  tv: {
    label: 'Apple TV',
    width: 3840,
    height: 2160,
    orientation: 'landscape',
    panels: [
      ['plozz-tv-home', 'Your library, the way it should look'],
      ['plozz-tv-oppenheimer', 'Artwork, ratings and cast — from bare files'],
      ['plozz-tv-lotr', 'Every version, every server, one title'],
      ['plozz-tv-lastofus', 'Pick up exactly where you left off'],
      ['plozz-tv-cast', 'Follow an actor through your whole library'],
      ['plozz-tv-library', 'Browse everything you own'],
      ['plozz-tv-player', 'A player built for the remote in your hand'],
      ['plozz-tv-subtitles', 'Subtitles that look the way you want them to'],
      ['plozz-tv-settings', 'Plex, Jellyfin, Emby, SMB, NFS, WebDAV, SFTP, FTP'],
    ],
  },
  iphone: {
    label: 'iPhone',
    width: 1320,
    height: 2868,
    orientation: 'portrait',
    panels: [
      ['plozz-iphone-home', 'Your whole library in your pocket'],
      ['plozz-iphone-oppenheimer', 'Artwork, ratings and cast — from bare files'],
      ['plozz-iphone-lastofus', 'Pick up exactly where you left off'],
      ['plozz-iphone-cast', 'Follow an actor through your whole library'],
      ['plozz-iphone-library', 'Browse everything you own'],
      ['plozz-iphone-search', 'Search every server at once'],
      ['plozz-iphone-player', 'Native playback, nothing transcoded'],
    ],
  },
  ipad: {
    label: 'iPad',
    width: 2064,
    height: 2752,
    orientation: 'portrait',
    panels: [
      ['plozz-ipad-home', 'Your whole library, everywhere you watch'],
      ['plozz-ipad-oppenheimer', 'Artwork, ratings and cast — from bare files'],
      ['plozz-ipad-lastofus', 'Pick up exactly where you left off'],
      ['plozz-ipad-cast', 'Follow an actor through your whole library'],
      ['plozz-ipad-library', 'Browse everything you own'],
      ['plozz-ipad-search', 'Search every server at once'],
      ['plozz-ipad-player', 'Native playback, nothing transcoded'],
    ],
  },
};

const args = process.argv.slice(2);
const keepHTML = args.includes('--keep-html');
const platformIndex = args.indexOf('--platform');
const onlyPlatform = platformIndex === -1 ? null : args[platformIndex + 1];
const outIndex = args.indexOf('--out');
const OUT = outIndex === -1
  ? path.join(ROOT, 'build', 'appstore')
  : path.resolve(args[outIndex + 1]);

/**
 * One panel's HTML.
 *
 * The capture is inset rather than bled to the edges: a full-bleed frame has
 * nowhere to put the caption that isn't on top of the picture, and text over a
 * screenshot of a movie is text over whatever that movie happens to be showing.
 * A quiet margin also reads as deliberate at thumbnail size, which is the size
 * that decides whether anyone taps.
 */
function page({ width, height, orientation, image, caption, capture }) {
  const landscape = orientation === 'landscape';
  // Proportional so one stylesheet serves a 3840px TV panel and a 1320px phone.
  const pad = Math.round(width * (landscape ? 0.055 : 0.07));
  const titleSize = Math.round(width * (landscape ? 0.036 : 0.062));
  const radius = Math.round(width * (landscape ? 0.014 : 0.035));

  // A 16:9 capture laid out at 100% of a 3840px panel's content width is 1923px
  // tall, which together with the caption overflows a 2160px panel — and
  // `overflow: hidden` then silently cropped the bottom two thirds of every
  // landscape shot rather than failing. So the frame is fitted to whatever the
  // caption leaves.
  //
  // Fitted by the browser, not computed here: computing it meant guessing how
  // many lines the caption would wrap to, and one caption that guessed high
  // ("Plex, Jellyfin, Emby, SMB, NFS, WebDAV, SFTP, FTP") shrank its panel's
  // frame to noticeably smaller than every other panel's. `aspect-ratio` with
  // both a max width and a max height is the same fit without the guess.
  const gap = Math.round(pad * 0.85);
  const aspect = `${capture.width} / ${capture.height}`;

  return `<!doctype html>
<meta charset="utf-8">
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  html, body {
    width: ${width}px;
    height: ${height}px;
    overflow: hidden;
    background: ${TOKENS.bg};
  }
  body {
    /* auto + 1fr gives the caption exactly the height it needs and hands the
       rest to the frame, whatever the caption wrapped to. */
    display: grid;
    grid-template-rows: auto 1fr;
    justify-items: center;
    gap: ${gap}px;
    padding: ${pad}px;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
    color: ${TOKENS.text};
    /* Two off-canvas glows in the brand colours. They keep a page of otherwise
       near-black panels from reading as a column of dead rectangles in the
       App Store's grid, without putting anything on top of the app itself. */
    background:
      radial-gradient(${Math.round(width * 0.9)}px ${Math.round(height * 0.6)}px
        at 12% -10%, ${TOKENS.brand}22, transparent 70%),
      radial-gradient(${Math.round(width * 0.8)}px ${Math.round(height * 0.5)}px
        at 100% 108%, ${TOKENS.brand2}20, transparent 70%),
      ${TOKENS.bg};
  }
  h1 {
    font-size: ${titleSize}px;
    line-height: 1.12;
    letter-spacing: -0.022em;
    font-weight: 700;
    text-align: center;
    text-wrap: balance;
    max-width: ${Math.round(width * 0.9)}px;
  }
  figure {
    aspect-ratio: ${aspect};
    width: 100%;
    max-width: 100%;
    max-height: 100%;
    margin: auto;
    border-radius: ${radius}px;
    overflow: hidden;
    border: ${Math.max(2, Math.round(width * 0.0012))}px solid ${TOKENS.border};
    /* Lifts the capture off a background that is nearly the same black as the
       app's own chrome, so the frame has an edge instead of dissolving. */
    box-shadow:
      0 ${Math.round(width * 0.012)}px ${Math.round(width * 0.05)}px rgba(0,0,0,0.75),
      0 0 ${Math.round(width * 0.09)}px ${TOKENS.brand}1c;
    line-height: 0;
  }
  img { width: 100%; height: 100%; display: block; }
</style>
<h1>${caption}</h1>
<figure><img src="${image}"></figure>
`;
}

async function main() {
  if (!existsSync(CHROME)) {
    throw new Error(
      `Google Chrome is required to render the panels and was not at:\n  ${CHROME}`
    );
  }
  const present = SHOT_DIRS.filter((dir) => existsSync(dir));
  if (present.length === 0) {
    throw new Error(
      `No captures found. Run ./tools/capture-shots.sh first.\nLooked in:\n  ` +
        SHOT_DIRS.join('\n  ')
    );
  }

  /** Capture name -> the file it came from, across every platform's directory. */
  const available = new Map();
  for (const dir of present) {
    for (const file of await readdir(dir)) {
      if (file.endsWith('.png')) available.set(file, path.join(dir, file));
    }
  }

  const wanted = onlyPlatform
    ? { [onlyPlatform]: PLATFORMS[onlyPlatform] }
    : PLATFORMS;
  if (onlyPlatform && !PLATFORMS[onlyPlatform]) {
    throw new Error(
      `Unknown platform "${onlyPlatform}". One of: ${Object.keys(PLATFORMS).join(', ')}`
    );
  }

  for (const [key, platform] of Object.entries(wanted)) {
    const found = platform.panels.filter(([name]) =>
      available.has(`${name}.png`)
    );
    const missing = platform.panels.filter(
      ([name]) => !available.has(`${name}.png`)
    );

    console.log(`\n${platform.label}  ${platform.width}x${platform.height}`);
    if (found.length === 0) {
      console.log('  no captures yet — skipped');
      for (const [name] of missing) console.log(`    missing ${name}.png`);
      continue;
    }

    const dir = path.join(OUT, key);
    await mkdir(dir, { recursive: true });

    let index = 0;
    for (const [name, caption] of found) {
      index += 1;
      const stem = `${String(index).padStart(2, '0')}-${name.replace(/^plozz-/, '')}`;
      const html = path.join(dir, `${stem}.html`);
      const png = path.join(dir, `${stem}.png`);

      const capturePath = available.get(`${name}.png`);
      const { stdout: raw } = await run('magick', [
        'identify', '-format', '%w %h', capturePath,
      ]);
      const [captureWidth, captureHeight] = raw.trim().split(' ').map(Number);

      await writeFile(
        html,
        page({
          width: platform.width,
          height: platform.height,
          orientation: platform.orientation,
          image: capturePath,
          caption,
          capture: { width: captureWidth, height: captureHeight },
        })
      );

      await run(CHROME, [
        '--headless',
        '--disable-gpu',
        '--hide-scrollbars',
        '--force-device-scale-factor=1',
        '--allow-file-access-from-files',
        `--window-size=${platform.width},${platform.height}`,
        `--screenshot=${png}`,
        `file://${html}`,
      ]);

      const { stdout } = await run('magick', [
        'identify',
        '-format',
        '%wx%h',
        png,
      ]);
      const size = stdout.trim();
      const ok = size === `${platform.width}x${platform.height}`;
      console.log(`  ${stem}.png`.padEnd(42) + `${size}${ok ? '' : '  ← WRONG SIZE'}`);

      if (!keepHTML) await rm(html);
    }

    for (const [name] of missing) {
      console.log(`  (skipped, no capture: ${name}.png)`);
    }
  }

  console.log(`\nWrote to ${OUT}`);
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
