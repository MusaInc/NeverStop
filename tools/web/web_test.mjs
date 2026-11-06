// NEVER STOP browser smoke test in an emulated landscape iPhone (touch).
//   node tools/web/web_test.mjs <url> <outdir> [chromium|webkit]
// Drives the real web build: title -> PLAY by touch -> steer/brake by touch
// -> auto-acceleration -> pause. Reads window.__ns (published with ?debug=1).
import { createRequire } from "module";
const require = createRequire(import.meta.url);
const { webkit, chromium, devices } = require(process.env.PLAYWRIGHT ?? "/home/abdul/workspace/projects/FireDev/node_modules/playwright");
const [baseUrl, out, engine = "chromium"] = process.argv.slice(2);
if (!baseUrl || !out) throw new Error("usage: web_test.mjs <url> <outdir> [chromium|webkit]");
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
const state = () => page.evaluate(() => window.__ns ?? null);
async function waitFor(pred, timeout = 30000) {
  const end = Date.now() + timeout;
  let s = await state();
  while (Date.now() < end && !pred(s)) { await page.waitForTimeout(250); s = await state(); }
  return s;
}
const started = Date.now();
await page.goto(`${baseUrl}?debug=1&seed=${process.env.WEB_SEED ?? 5}`, { waitUntil: "load" });
let s = await waitFor(v => v?.state === "menu" && v?.buttons?.PLAY, 240000);
check(s?.state === "menu", `game booted to the title in ${((Date.now() - started) / 1000).toFixed(1)}s`);
const rect = await page.evaluate(() => { const b = document.querySelector("canvas").getBoundingClientRect(); return { x: b.x, y: b.y, w: b.width, h: b.height }; });
const at = (fx, fy) => [rect.x + fx * rect.w, rect.y + fy * rect.h];
const shot = name => page.screenshot({ path: `${out}/${engine}_${name}.png`, timeout: 180000 }).catch(e => logs.push(`[shot] ${name}: ${e.message.split("\n")[0]}`));
check(rect.w > rect.h, `landscape canvas ${rect.w}x${rect.h}`);
await shot("1_title");
await page.touchscreen.tap(...at(...s.buttons.PLAY));
s = await waitFor(v => v?.state === "playing", 60000);
check(s?.state === "playing", "PLAY starts a chase with a touch");
check(s?.touch === true, "touch controls are shown on a touch device");
s = await waitFor(v => (v?.speed ?? 0) > 15, 60000);
check((s?.speed ?? 0) > 15, `the car accelerates by itself (${(s?.speed ?? 0).toFixed(0)} km/h)`);
await shot("2_driving");
const active = new Map();
async function send(type, id, lifted) {
  const pts = [...active.entries()].map(([i, [x, y]]) => ({ id: i, x, y }));
  const changed = type === "touchend" ? [{ id, x: lifted[0], y: lifted[1] }] : pts.filter(p => p.id === id);
  await page.evaluate(({ type, pts, changed }) => {
    const c = document.querySelector("canvas");
    const mk = p => new Touch({ identifier: p.id, target: c, clientX: p.x, clientY: p.y, pageX: p.x, pageY: p.y, radiusX: 4, radiusY: 4, force: 1 });
    c.dispatchEvent(new TouchEvent(type, { touches: pts.map(mk), targetTouches: pts.map(mk), changedTouches: changed.map(mk), bubbles: true, cancelable: true }));
  }, { type, pts, changed });
}
const down = async (id, x, y) => { active.set(id, [x, y]); await send("touchstart", id); };
const move = async (id, x, y) => { active.set(id, [x, y]); await send("touchmove", id); };
const up = async id => { const xy = active.get(id); active.delete(id); await send("touchend", id, xy); };
if (engine === "chromium") {
  const k = rect.h / 720;
  const p0 = at(0.2, 0.6);
  await down(1, ...p0);
  await move(1, p0[0] + 70 * k, p0[1]);
  s = await waitFor(v => (v?.steer ?? 0) > 0.3, 20000);
  check((s?.steer ?? 0) > 0.3, `left-side slide steers right (${(s?.steer ?? 0).toFixed(2)})`);
  await move(1, p0[0] - 70 * k, p0[1]);
  s = await waitFor(v => (v?.steer ?? 0) < -0.3, 20000);
  check((s?.steer ?? 0) < -0.3, `and left (${(s?.steer ?? 0).toFixed(2)})`);
  // Brake with a second finger while still steering.
  const brake = at(...s.touch_buttons.brake);
  await down(2, ...brake);
  s = await waitFor(v => (v?.brake ?? 0) > 0.5, 20000);
  check((s?.brake ?? 0) > 0.5 && (s?.steer ?? 0) < -0.3, "BRAKE with another finger, steering kept");
  await shot("3_brake_steer");
  await up(2);
  await up(1);
  s = await waitFor(v => Math.abs(v?.steer ?? 1) < 0.05 && (v?.brake ?? 1) < 0.1, 20000);
  check(Math.abs(s?.steer ?? 1) < 0.05, "lifting the fingers centres the steering and releases the brake");
}
await page.waitForTimeout(4000);
s = await state();
check((s?.police ?? 0) > 0, `the police are on the way (${s?.police} units)`);
s = await state();
await page.touchscreen.tap(...at(...s.touch_buttons.pause));
s = await waitFor(v => v?.state === "paused", 30000);
check(s?.state === "paused", "the pause chip pauses");
await shot("4_pause");
const errors = [...new Set(logs.filter(l => /SCRIPT ERROR|pageerror|ERROR:/i.test(l)))];
check(errors.length === 0, `no runtime errors (${errors.length})`);
for (const e of errors.slice(0, 8)) console.log(`  ${e}`);
console.log(`RESULT ${engine}: ${checks.filter(c => c[0]).length}/${checks.length} passed (fps ~${s?.fps})`);
await browser.close();
process.exit(checks.every(c => c[0]) ? 0 : 1);
