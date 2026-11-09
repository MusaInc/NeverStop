# Status: 2026-11-09 (0.3.1)

## 0.3.1: feedback from the first iPhone build

- **Headlights**: two dark discs in the light pool. Each lamp had its own spotlight inside the lamp housing, which
  shadowed its own light. Now one soft, wide spotlight from just ahead of the bumper, no self-shadowing.
- **Steering too weak / no sharp turns**: full lock is now an arcade turn (allowed ~1.7x past plain tyre grip, a turn
  assist brings the nose round, a path-follow force swings the direction of travel with the nose instead of sliding
  wide), wheels reach lock twice as fast. Measured at 90 km/h full lock: 0.53 → 0.79–1.05 rad/s (turning circle
  ~47 m → ~28 m); nose response 0.15–0.22 s; overshoot ≤ 4 %; no rollover at full lock at 144 km/h. Touch slider
  full lock 105 → 85 px. `test_steering` now requires > 0.75 rad/s at full lock.
- **Blurry / blotchy graphics**: Medium (the phone default) rendered 3-D at 85 % and stretched it bilinearly. Now
  full resolution on Medium/High with 4x MSAA, 8x anisotropic filtering, a 4096 shadow map; Low upscales with FSR.
  The road-marking field was sampled every 2 m (smeared paint, blotchy junctions): now 1.25 m (+0.7 s startup here).
- **Build-up too slow, too few police**: heat 2 at 15 s (was 40 s), heat 6 at ~2 min (was ~7 min), then +1 every
  45 s. 3 police from the start (was 1); heat 6 brings 22 chasing cars and 60 units (was 13 / 34); several dispatched
  at once; roadblocks from heat 2, helicopter and spikes from heat 3. Physical police cap: Low 12 / Medium 18 /
  High 24 (was 8 / 12 / 16). Heat-8 swarm on this server, Medium: 18 cars, 105 units, frame avg 10.4 ms,
  p95 13.8 ms; High: 24 cars, avg 12.2, p95 16.8. Heat challenges moved up to match.


## 0.3.0: controls, steering, car designs, a finished game loop

- **Press to accelerate.** Touch now has a tall GAS pedal (far right) with BRAKE beside it; the thumb rocks between
  them without lifting. Keyboard needs W / ↑, pad RT. Settings → Accelerate → Auto brings back the always-on throttle.
  Steering slider: 105 px to full lock (was 80) with a 5 px dead zone; tilt has a small dead zone. NOS shows its tank.
- **Steering model fixed** (`Car.max_steer_angle`, new `tests/test_steering.gd`). Measured before: at 110 km/h a
  60 % steering step overshot the target yaw rate by 40–72 % within 50 ms (the nose snapped in, then backed off), and
  60 % input already saturated grip, so the top of the range did nothing. Now full lock at every speed asks for just
  over what the tyres can deliver, the wheel takes a constant ~0.17 s from centre to lock, and a stability control
  catches yaw beyond what the steering asks for. After: overshoot ≤ 20 % on every car, steering is proportional across
  the range, full-lock grip turns don't fall into drift mode, let-go settles in ~0.2 s.
- **Car designs** (`tools/blender/build_vehicles.py`): the wheel rim "lip" was a solid disc that hid the spokes, so
  every alloy read as a flat silver hubcap; it is a ring now (spokes, discs and calipers show). Tyres fill the arches
  (arch gap 75 → 45 mm), bigger wheels on the sporty cars, body-colour flares and dark sills for stance. The Kestrel
  is a proper hot hatch (was a one-box people-carrier silhouette); the Marlin has a lower, longer glasshouse and a
  blunter nose; the Stiletto's wing is smaller. Physics sizes follow the models as before.
- **Contracts** (`src/core/contracts.gd`): three rolling objectives on the HUD (near misses, wrecks, drift, air, top
  speed, distance, chain, smashing street furniture, roadblocks). Each pays score through the chain plus cash; a
  harder one replaces it.
- **Career ranks**: every point scored is XP; 11 ranks from Joyrider to Never Stop, each rank-up pays cash. Shown on
  the title, results and records.
- **First-run coach**: GAS → steer both ways → brake → drift → goal, one prompt at a time; each gives up after 25 s.
- **How to Play** screen (controls for touch / keys / pad, the rules). 8 new challenges (22 total).
- **Car switching fixed.** The garage's ◀ ▶ buttons sat under the details column, which grew taller than the
  screen, so they were cut off (and off-screen behind an iPhone's safe area). The switcher now sits under the car,
  always visible, with a dots indicator. Also fixed: after switching car, the effects and street-furniture systems
  hit the freed old car (a script error every frame until the list refreshed). `game.test_9` now drives the real
  buttons (Next → Buy → Prev → Drive → Back → Play), checks each is on screen and that the chase uses the chosen car.
- **UI redesign, minimal / Arcade-style**: frosted-glass cards, pill buttons, sentence-case headings, one amber
  accent. Garage: a details card with tabs – Performance (each upgrade shows the stat it improves, the next level as
  a ghost bar, level pips, one price button), Style (paint swatches, wheels), Start (start location) – and one main
  action under the car (Buy / Drive this / Selected). Touch controls: glass pedals with a single chevron, glass
  round buttons. HUD panels are rounded.
- **Completion pass**:
  - Auto-pause when the app is backgrounded or loses focus (call, home swipe, notification centre), and the save is
    flushed when iOS suspends or closes the app.
  - Controller / keyboard: B or Esc goes back on every screen and resumes from pause (no instant re-pause); LB / RB or
    Q / E switch car in the garage.
  - Settings: High-contrast HUD (it was a setting nothing used; now solid backing behind every readout), Replay
    tutorial, Reset everything (two taps), About (version, credits, privacy statement, Godot's licence text).
  - Daily streak bonus on the title ($250 rising to $2,500 on day 7; a missed day restarts the streak).
  - Music: a menu theme and a PEAK layer (arpeggio, 16th hats, stabs) from heat 5, both synthesised like the rest
    (`gen_sounds.py ... music_extra`); the menu theme crossfades with the chase bed.
  - iOS marketing version 0.3.0 (export preset and the TestFlight workflow default).
- Tests: 26 unit/physics + 12 whole-game, all passing; packaged Linux self-test OK; web build 13/13 in Chromium;
  iOS Xcode project exports (the .ipa itself needs macOS / the TestFlight workflow).
- **Still needs a person** (can't be done from this server): playing it on an iPhone (touch feel, steering,
  FPS/thermals), listening to the new music and the sound mix, a difficulty pass with real players, App Store
  screenshots and listing.
- Not checked by a person yet: the new pedals and steering on a phone.

# Status: 2026-11-07 (vehicles pass 2, unreleased)

## Kerbs, handling, smoke, headlights, car looks (2026-11-07)

- **Kerbs and low ledges no longer crash you.** The physics hull floor sits at 0.3 m (kerbs are 0.15 m) with wedged
  nose/tail, the damper speed is capped (no launch when a wheel drops onto a kerb), and anything up to 0.62 m tall
  that the hull touches low down is climbed: the car hops up and keeps its speed, with no damage. Walls still crash
  (a probe ray checks the obstacle's real height). New test `test_kerbs_and_low_ledges_are_driven_over`: on the old
  physics the Stiletto and Kestrel stopped dead (health 0.81 / 0.87); now all six cases climb at 36-58 km/h, no damage.
- **Steering**: unwinding and counter-steer are 1.7x quicker than turning in; the straight-line hold blends out with
  steering instead of switching off at 4 %.
- **Smoke never blinds you**: every puff fades out near the camera and as it fills the screen; tyre smoke is lower,
  thinner and shorter-lived; engine smoke streams back with speed; lumpy rotating puffs instead of discs; dust fades too.
- **Headlights**: player car has two real spotlights (shadows on HIGH) plus a faint visible beam, night only; every
  car gets lamp glows at night (one draw call per car); lenses and tail lamps brighten at night.
- **Looks**: car paint shader with sky reflections, horizon line, sun glint and fake occlusion; glass reflects the sky;
  wheels rebuilt (dark deep wells, brake discs, red calipers that don't spin, sidewall band, brighter alloy).
- Not checked by a person yet: the new kerb behaviour and steering on a phone.

# Status: 2026-11-06 (0.2.0)

## 0.2.0 (2026-11-06, later): vehicles, lighting, bridge

- **Cars rebuilt** (`tools/blender/build_vehicles.py` v2): section-lofted bodies with hard creases, lamps/grilles/vents/
  seams/livery ray-projected onto the surface, wings, exhausts, bull bars, cargo boxes. Review renders:
  `tools/lineup.sh "<ids>" <name>` (real game lighting on the bridge deck).
- **Ten player cars**, four new: Scout (rally hatch), Goliath (lifted pickup), Mammoth (7 t cab-over truck), Stiletto
  (wedge hypercar). Each has a perk that really changes play (ram damage, run-flat tyres, self-repair, score
  multipliers, longer combo window, faster nitro) and its own upgrade limits (1–5 levels per upgrade, per-car pricing).
  Physics sizes come from the models (`assets/vehicles/body_dims.gd`, generated).
  Measured on the bench: 0–100 km/h from 2.8 s (Stiletto) to 7.1 s (Mammoth); no car rolls at full lock at 144 km/h.
- **Civilian traffic** has its own models: compacts, saloons, taxis, SUVs, vans, box trucks, buses (length-aware gaps).
- **Police** rebuilt with proper liveries (patrol white doors, interceptor chequer + stripes, heavy battenburg).
- **Lighting**: sun shadow opacity 0.62, more ambient fill, contrast 1.03, lighter asphalt: shaded streets stay readable.
- **Road gaps**: the bridge deck stopped 16 m short of the approach viaduct (a 2 m drop onto the west anchorage that
  trapped cars). Fixed, and `game.test_0_roads_are_continuous` now ray-casts all ~47,000 lane points: 0 holes; 4 points
  with a 0.64 m step where the island ramp meets its roundabout (cosmetic for kinematic civilians; still listed).
- Not checked by a person yet: how the new cars feel to drive on a phone, and whether the heavy trucks are fun.

## Working and tested
- **Standalone project**, city copied from CitySwing (CitySwing untouched).
  Road audit: ~38 km, both lands joined over the bridge, 0 dead ends, 99.9 %
  of graph nodes reach the centre.
- **Driving** (`test_vehicle`, 9 checks): 0–100 km/h 5.2 s (Kestrel) to 3.0 s
  (Halcyon), 100–0 in 27 m, no rollover at full lock at 144 km/h on any car,
  handbrake drifts held at ~34° and recovered, ramp jumps land on four
  wheels, wall hits damage the side that hit. Six distinct cars.
- **Pursuit**: heat 1→6 then climbing, 5 roles, tiers A–D, roadblocks with
  escapable gaps (announced), spike strips (heat 4+), helicopter (heat 4+),
  wrecks that stay as obstacles. Game tests: every spawn/promotion out of view
  and at a fair distance; a lone touch doesn't bust you; a stopped car
  surrounded is busted; results shown.
- **Civilians, destruction, jumps**, scoring with chains, offline progression
  (cash, 6 cars, 4 upgrade tracks, 10 paints, 5 wheels, 5 starts,
  14 challenges, records, history), garage turntable, settings, pause,
  results with instant RETRY, synthesised audio, particles/skids/dents.
- **Exports**: Linux packaged self-test OK; web build passes 12/12 browser
  checks in Chromium (iPhone 13 landscape, real touch: PLAY, slide steering
  both ways, two-finger brake + steer, pause); iOS Xcode project exports.
- 30 automated tests (20 unit/physics/road, 10 whole-game incl. a 5-minute
  session with bounded nodes/memory).

## Not done / honest gaps
- **No iPhone testing at all** – no device FPS, no thermal, no real touch
  feel. The touch layout is checked only in an emulated browser.
- **Nobody has played it with hands yet.** Handling and escalation were
  tuned with numeric tests and an autopilot; the feel of steering, drift
  and the difficulty curve need a human playtest (expect retuning of
  `CarCatalog` and `PursuitDirector.HEAT_AT`).
- **Balance flags**: an autopilot driver lasts ~1–4 min; police sometimes
  lose the player for stretches at heat 3–4 (they drop to tier C and catch
  up); a stationary car at heat 4 took ~40 s to be busted (units must drive
  in from ≥170 m).
- Not yet done from the brief: traffic lights/junction logic for civilians,
  elevated motorway / tunnels / car parks (the map is CitySwing's road
  network plus ramps – no new road geometry), detachable panels (dents are
  vertex deformation only), broken-headlight effects, vehicle LOD meshes
  (police/civilian bodies are ~5k triangles each, drawn at all distances),
  tilt steering is untested on hardware, controller menu navigation is
  untested, the app icon is a first pass, no music beyond two synthesised
  stems, sounds have not been listened to by a person.
- Civilian cars use the player-car bodies in muted colours (consistent
  style, but a smaller variety than real traffic).

## Next priorities
1. Hands-on playtest on an iPhone (Xcode build) – handling feel, touch,
   FPS with Settings → Show performance; retune from that.
2. LOD meshes for vehicles; check GPU cost of 16 cars + particles at night.
3. Junction logic for civilians; road set pieces (elevated section, tunnel,
   car park ramp) for the "dramatic jumps / hidden routes" brief.
4. Balance pass on heat timings and bust time with real players.
