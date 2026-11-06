// Renders the billboard atlas (tools/ads/ads.html) with Playwright's Chromium:
//   node tools/ads/render.mjs   → assets/ads/ads_atlas.png (RGB = adverts,
//   alpha = motion mask: 0 where the shader animates) + assets/ads/ads_meta.json
// Needs ffmpeg (alphamerge). PLAYWRIGHT overrides the Playwright module path.
import { createRequire } from "module";
import { fileURLToPath } from "url";
import { execFileSync } from "child_process";
import path from "path";
import fs from "fs";
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT ?? "/home/abdul/workspace/projects/FireDev/node_modules/playwright");
const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");
const out = path.join(root, "assets/ads");
fs.mkdirSync(out, { recursive: true });
const tmp = fs.mkdtempSync(path.join(process.env.TMPDIR ?? "/tmp", "ads-"));

const browser = await chromium.launch({ args: ["--allow-file-access-from-files"] });
const page = await browser.newPage({ deviceScaleFactor: 1 });
await page.setViewportSize({ width: 3072, height: 2880 });
let meta = null;
for (const mode of ["", "mask"]) {
  await page.goto("file://" + path.join(here, "ads.html") + (mode ? "?mask" : ""));
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(300);
  if (!mode) meta = await page.evaluate(() => window.ATLAS_META);
  await page.screenshot({ path: path.join(tmp, (mode || "rgb") + ".png"), clip: { x: 0, y: 0, width: 3072, height: 2880 } });
}
await browser.close();
// Alpha = 1 - mask (opaque where the advert is static).
execFileSync("ffmpeg", ["-y", "-loglevel", "error", "-i", path.join(tmp, "rgb.png"), "-i", path.join(tmp, "mask.png"),
  "-filter_complex", "[1]format=gray,negate[a];[0]format=rgb24[c];[c][a]alphamerge", "-pix_fmt", "rgba",
  path.join(out, "ads_atlas.png")]);
fs.writeFileSync(path.join(out, "ads_meta.json"), JSON.stringify(meta, null, 1));
fs.copyFileSync(path.join(tmp, "rgb.png"), path.join(here, "preview.png"));
console.log("rendered assets/ads/ads_atlas.png + ads_meta.json (" + meta.ads.length + " brands)");
