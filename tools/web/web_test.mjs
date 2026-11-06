// Browser gameplay smoke test in an emulated landscape iPhone.
// node tools/web/web_test.mjs <url> <outdir> [webkit|chromium]
import { createRequire } from "module";
const require = createRequire(import.meta.url);
const { webkit, chromium, devices } = require(process.env.PLAYWRIGHT ?? "/home/abdul/workspace/projects/FireDev/node_modules/playwright");
const [baseUrl, out, engine = "webkit"] = process.argv.slice(2);
if (!baseUrl || !out) throw new Error("usage: web_test.mjs <url> <outdir> [webkit|chromium]");
const device = devices["iPhone 13 landscape"];
const browser = await (engine === "chromium" ? chromium : webkit).launch({
  args: engine === "chromium" ? ["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"] : [],
});
const context = await browser.newContext({ ...device });
const page = await context.newPage();
const logs = [];
page.on("console", m => logs.push(`[${m.type()}] ${m.text()}`));
page.on("pageerror", e => logs.push(`[pageerror] ${e.message}`));
const checks = [];
const check = (ok, msg) => { checks.push([!!ok, msg]); console.log(`${ok ? "ok  " : "FAIL"} ${msg}`); };
const state = () => page.evaluate(() => window.__cs ?? null);
async function waitFor(predicate, timeout = 30000) {
  const end = Date.now() + timeout;
  let s = await state();
  while (Date.now() < end && !predicate(s)) { await page.waitForTimeout(200); s = await state(); }
  return s;
}
const started = Date.now();
await page.goto(`${baseUrl}${baseUrl.includes("?") ? "&" : "?"}debug=1&seed=${process.env.WEB_SEED ?? 7}`, { waitUntil: "load" });
let s = await waitFor(v => v?.state === "title", 120000);
check(s?.state === "title", `game booted in ${((Date.now() - started) / 1000).toFixed(1)}s`);
const rect = await page.evaluate(() => {
  const b = document.querySelector("canvas").getBoundingClientRect();
  return { x: b.x, y: b.y, w: b.width, h: b.height };
});
const at = (fx, fy) => [rect.x + fx * rect.w, rect.y + fy * rect.h];
// Screenshots are evidence, not checks: software-rendered Chromium can take
// longer than Playwright's 30 s default to produce one frame.
const shot = name => page.screenshot({ path: `${out}/${engine}_${name}.png`, timeout: 120000 })
  .catch(e => logs.push(`[shot] ${name}: ${e.message.split("\n")[0]}`));
check(rect.w >= 700 && rect.h >= 300 && rect.w > rect.h, `landscape canvas ${rect.w}x${rect.h}`);
await shot("1_title");
// Splash: tap anywhere, then the main menu's Free Swing card (by its
// published position – layout-independent).
await page.touchscreen.tap(...at(0.5, 0.5));
s = await waitFor(v => v?.screen === "title" && v?.menu?.free, 20000);
check(s?.screen === "title", "tap to start opens the main menu");
await page.waitForTimeout(600);  // cards slide in
s = await state();
await shot("1b_main_menu");
await page.touchscreen.tap(...at(...s.menu.free));
s = await waitFor(v => v?.state === "playing", 30000);
check(s?.state === "playing", "Free Swing starts with an iPhone touch");
await page.waitForTimeout(2500);
await shot("2_rooftop");
// Character: the skinned body loaded and, standing on the roof, both feet
// are planted on the surface (leg IK + ground raycasts).
s = await waitFor(v => v?.grounded && v?.rig?.planted === 2, 20000);
await page.waitForTimeout(3000);  // judge the settled stance, not the lock-in frame
s = await state();
check(s?.rig?.skinned, "skinned character body loaded");
check(s?.rig?.planted === 2 && s?.rig?.foot_gap < 0.03,
  `both feet planted on the rooftop (gap ${((s?.rig?.foot_gap ?? 1) * 100).toFixed(1)} cm)`);
s = await state();
const k = rect.h / 720;
const swing = [rect.x + rect.w - 150 * k, rect.y + rect.h - 150 * k];
const jump = [rect.x + rect.w - 338 * k, rect.y + rect.h - 92 * k];
const pause = [rect.x + rect.w - 44 * k, rect.y + 44 * k];
const active = new Map();
async function send(type, id, lifted) {
  const pts = [...active.entries()].map(([i, [x, y]]) => ({ id: i, x, y }));
  const changed = type === "touchend" ? [{ id, x: lifted[0], y: lifted[1] }] : pts.filter(p => p.id === id);
  await page.evaluate(({ type, pts, changed }) => {
    const c = document.querySelector("canvas");
    const mk = p => new Touch({ identifier: p.id, target: c, clientX: p.x, clientY: p.y,
      pageX: p.x, pageY: p.y, radiusX: 4, radiusY: 4, force: 1 });
    c.dispatchEvent(new TouchEvent(type, { touches: pts.map(mk), targetTouches: pts.map(mk),
      changedTouches: changed.map(mk), bubbles: true, cancelable: true }));
  }, { type, pts, changed });
}
const down = async (id, x, y) => { active.set(id, [x, y]); await send("touchstart", id); };
const move = async (id, x, y) => { active.set(id, [x, y]); await send("touchmove", id); };
const up = async id => { const xy = active.get(id); active.delete(id); await send("touchend", id, xy); };
if (engine === "chromium") {
  const fired = s?.webs_fired ?? 0;
  await down(1, ...swing);
  s = await waitFor(v => (v?.webs_fired ?? 0) > fired && v?.line === 2, 30000);
  check((s?.webs_fired ?? 0) > fired && s?.line === 2, "holding SWING attaches a web");
  check(s?.touch_web === 1, "the holding finger owns the web");
  await shot("3_holding_swing");
  const taut = await waitFor(v => (v?.rig?.hand_line ?? -1) >= 0 || v?.line !== 2, 15000);
  check((taut?.rig?.hand_line ?? -1) >= 0 && taut.rig.hand_line < 0.1,
    `web hand stays on the rope line (${((taut?.rig?.hand_line ?? -1) * 100).toFixed(1)} cm off)`);
  s = await state();
  // The left stick steers the web: push right, then left, while swinging.
  const stickAt = at(0.15, 0.77);
  await down(5, ...stickAt);
  await move(5, stickAt[0] + 70 * k, stickAt[1]);
  const sr = await waitFor(v => (v?.web?.heading_side ?? 0) > 25 || v?.line === 0, 15000);
  await move(5, stickAt[0] - 70 * k, stickAt[1]);
  const sl = await waitFor(v => (v?.web?.heading_side ?? 0) < -25 || v?.line === 0, 15000);
  await up(5);
  check((sr?.web?.heading_side ?? 0) > 25 && (sl?.web?.heading_side ?? 0) < -25,
    `left stick steers the web (right ${sr?.web?.heading_side}°, left ${sl?.web?.heading_side}°; ` +
    `pick ${sr?.web?.pick_side ?? "-"}° / ${sl?.web?.pick_side ?? "-"}°)`);
  s = await state();
  const oldYaw = s?.look_yaw ?? 0;
  await down(2, ...at(0.77, 0.33));
  s = await waitFor(v => v?.touch_web === 2 && v?.line !== 0, 20000);
  check(s?.touch_web === 2, "another right-side touch reattaches");
  await up(1);
  s = await waitFor(v => v?.touch_web === 2, 8000);
  check(s?.line !== 0, "lifting the old finger keeps the new web");
  await down(3, ...jump);
  s = await state();
  check(s?.touch_web === 2, "JUMP does not steal the web");
  await up(3);
  const stick = at(0.15, 0.77);
  await down(4, ...stick);
  await move(4, stick[0], stick[1] - 55 * k);
  await page.waitForTimeout(500);
  await up(4);
  s = await state();
  check(Math.abs((s?.look_yaw ?? 0) - oldYaw) < 0.01, "touches do not orbit the camera");
  await up(2);
  s = await waitFor(v => v?.line === 0, 15000);
  check(s?.line === 0, "lifting the owning finger releases the web");
  await shot("4_released");
  // In the air, JUMP is an acrobatic trick (chosen to fit the air time).
  // The flight is not deterministic at ~1 fps: it may end in a wall first,
  // which must then be a knockout (ragdoll), not a freeze or a wall run.
  const before = s?.rig?.tricks ?? 0;
  if (!s?.grounded && !s?.stunned) {
    // Hold until the game has seen it (headless browsers run at ~1 fps).
    await down(6, ...jump);
    s = await waitFor(v => (v?.rig?.tricks ?? 0) > before || v?.grounded || v?.stunned, 10000);
    await up(6);
  }
  if (s?.rig?.ko || s?.stunned) {
    s = await waitFor(v => v?.rig?.ragdoll, 5000);
    check(s?.rig?.ragdoll, `hit a wall after the release: knocked out (ragdoll ${s?.rig?.ragdoll})`);
    await shot("4b_knockout");
  } else if (!s?.grounded || (s?.rig?.tricks ?? 0) > before) {
    check((s?.rig?.tricks ?? 0) > before, `JUMP in the air does a trick (${s?.rig?.trick || "none"})`);
    await shot("4b_trick");
  } else {
    check(true, "landed before a trick could be tried (skipped)");
  }
} else {
  // Linux WebKit cannot construct held Touch objects; Playwright sends real taps.
  const fired = s?.webs_fired ?? 0;
  await page.touchscreen.tap(...swing);
  s = await waitFor(v => (v?.webs_fired ?? 0) > fired || v?.last_tap?.reason === "waiting", 15000);
  check((s?.webs_fired ?? 0) > fired,
    "Safari touch on SWING fires a web from the rooftop");
  s = await waitFor(v => v?.line === 0, 12000);
  check(s?.line === 0, "Safari tap release leaves no held web");
  await shot("3_after_tap");
}
await page.touchscreen.tap(...pause);
s = await waitFor(v => v?.state === "paused", 15000);
check(s?.state === "paused", "pause touch opens the menu");
await shot("5_pause");
const errors = [...new Set(logs.filter(l => /SCRIPT ERROR|pageerror|ERROR:/i.test(l)))];
check(errors.length === 0, `no runtime errors (${errors.length})`);
for (const error of errors.slice(0, 8)) console.log(`  ${error}`);
console.log(`RESULT ${engine}: ${checks.filter(c => c[0]).length}/${checks.length} passed`);
await browser.close();
process.exit(checks.every(c => c[0]) ? 0 : 1);
