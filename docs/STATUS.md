# Status: 2026-11-13 (1.0.0, TestFlight)

## Feedback pass (from playing 0.5.0)

- **Camera fits the vehicle** (`ChaseCamera.size_fit`): distance, lens height, look-ahead and
  look-at height come from the body's real length and roof height (a touch of extra FOV for big
  ones). Normal cars keep the old framing; the Mammoth now sits ~3 m further back and ~5 m up, so
  the road ahead shows over the box instead of the box filling the screen. Test:
  `test_systems.test_camera_fits_the_vehicle`.
- **Headlights: the two dark circles are gone.** They were the visible "air beams" (two
  additive cones, one per lamp): from the chase camera each cone's dim tip read as a dark hole in
  the lit road. The beams (and `head_beam.gdshader`) are removed. Now: one main spot (42°, 75 m,
  softer edge) plus a wide, short, dim spill spot so the kerbs either side of the nose are lit.
- **Choppy clouds**: they drifted at 0.004 uv/s, under a pixel per frame, so 8-bit output stepped
  them about once a second. They drift ~6x faster now with a faster cross-flow detail layer
  (billowing instead of one sliding sheet), crisper edges, and the sky colours update every frame
  (they were set 4x a second, a visible judder at dusk with the day cycle on).
- **Civilian cars turn like cars** (`CivilianTraffic._pose`): the rear axle follows the lane and
  the nose points at the lane a wheelbase ahead (buses swing wide and their tails cut in), the
  front wheels steer into the bend, the body leans out a little, and it's all interpolated, so the
  heading no longer snaps at every 3 m path point. (They used to pivot on their middle with a
  heading that stepped and static front wheels.)
- **Road markings** (ground shader, from the road field: ring = hw 11, boulevards hw 13):
  - the coastal ring is an expressway: darker fresh surface, a hatched central reservation
    between solid lines, solid edge lines with a hard shoulder, long lane dashes;
  - boulevards: red bus lanes along the kerb on some stretches (solid line beside them);
  - streets: green cycle lanes on some, dashed give-way double lines at their junction mouths
    (boulevards and the ring keep solid stop lines);
  - big junctions get a criss-cross yellow box.
- **Exploring the middle of the city**:
  - **Cash drops** (`RepairPickups` with `kind = "cash"`): 4-9 gold coins on beacons, +600 points
    (chained) and +$120 each (added to the run's cash, `last_result.drop_cash`), gold dots on the
    minimap, always replaced somewhere new.
  - Repair stations and cash drops are placed by lane type: streets x1.6, boulevards x0.9, the
    coastal ring x0.12, never in junctions. (Weighting by length alone put lots of them on the
    long ring road, which pulled you round the edge.)

Not done (bigger jobs, worth doing next): real highways with on/off ramps and interchanges,
elevated sections, more roundabout types (they're all one style), and a hand-made cross-city
route with a reason to take it (e.g. a downtown score multiplier).

# Status: 2026-11-12 (1.0.0, release candidate)

## Completion pass for App Store submission

- **Bridge see-through patch fixed** (`BuildingMesher._bridge`): the road surface, markings, walkways
  and side girders were drawn from the west anchorage's far edge, but the deck you drive on (and
  the approach viaduct it joins) starts 16.5 m further west. Over the anchorage you saw bare stone
  2 m below an invisible road. Drawn from the same x as the collision deck now.
- **New app icon** (`src/ui/icon_art.gd` → `assets/icon_1024.png`, baked with the splash by
  `tools/make_splash.sh`): your amber getaway car from behind, twin stripes and wing, racing down a
  road into the red / blue glow of the police ahead. Opaque, no text. The old one was a dark render
  of a car's nose that read as a blur at home-screen size. `tools/icon_shot.gd` is retired.
- **First-launch stalls (CitySwing's 2.1 rejection)**, ported from CitySwing:
  - `ShaderPrewarm` draws every mid-game shader (sirens, head beams, paint, glass, particles,
    ad screens, rain, water, beacons...) and the StandardMaterial3D variants once behind the
    loading screen, so a fresh install doesn't compile them mid-chase.
  - 3-D pixel budget (`Settings.render_scale_cap`, presets' `pixels`: Low 1.2 MP, Medium 2.0 MP,
    High 2.8 MP) with MetalFX spatial upscaling on iPhone / iPad. Medium/High used to render the
    full panel (an iPhone is ~3 MP, a 13" iPad ~5.7 MP) with 4x MSAA.
  - `FrameGovernor`: dynamic resolution, eases the 3-D scale down when the GPU falls behind.
  - Soft shadow filter quality 1 on mobile (was 3).
- **Store pack** (`store/`): `APP_STORE.md` (fields, keywords, age-rating suggestions, privacy
  label, a pre-submit checklist), `description.txt`, `review_notes.txt`, `privacy-neverstop.html`,
  and the screenshot gallery (`store/screenshots/iphone69`, `ipad13`; `tools/store_shots.sh`
  renders genuine gameplay at native size, `tools/store_compose.sh` adds the headlines).
- Version 1.0.0 (project, iOS export preset, TestFlight workflow default).
- `--view=x,y,z` capture option: fixed lens looking at the car (how the bridge hole was found).

# Status: 2026-11-11 (0.5.0 + start-up and title, unreleased)

## Trees knock down

- Street and park trees were solid (`CityWorld.SOLID_PROPS`): they line every pavement and were
  too hard to avoid at speed. They're breakable street furniture now (`Destructibles`): the car
  loses 12-14 % of its speed and no health, the tree topples over the bonnet as a heavy piece of
  debris, with a thump, a lens punch, a haptic and **TIMBER +120** (chained; not in battles). It
  counts for "smash" contracts and Street Sweeper. Police and civilians knock trees down too.
  Bus shelters and planters stay solid.
- Fix (all furniture): the hit check measured height in the car's own frame, so a car pitched up
  a kerb could pass straight through an item's base. Height is now compared in world terms.
  Furniture also breaks from 1 m/s (was 4 m/s) since nothing breakable blocks you any more.
- Test: `game.test_8b_trees_are_knocked_down` (a clear run-up at 72 km/h: the tree is gone, the
  car drives on past it, no damage).

## Start-up and title screen

- **No Godot splash.** `assets/ui/splash.png` (the NEVER STOP logo on asphalt ink with a red / blue
  siren glow, baked from `src/ui/splash_art.gd` by `tools/make_splash.sh`) is the boot splash, the iOS
  launch screen (`storyboard/custom_image@2x/@3x`) and the web loader image. Its edges are the
  background colour, so letterboxing on iPad / wide iPhones has no seam.
- **Loading screen** (`src/ui/loading_screen.gd`): start-up builds the whole city (~5.5 s on this
  server) on a frozen frame after the splash. `Game._ready` now runs in five drawn stages behind the
  same image (fit-centred exactly like the splash, so the hand-over is invisible) with a red→blue
  progress line, a status line and a gameplay tip, holds a few frames while the first 3-D frames
  compile shaders, then zooms through the logo into the title. Headless runs (tests, benchmarks)
  build in one go as before.
- **Title redesign** (`Menus._build_title`):
  - Top bar: rank shield + name + XP bar + "N XP to <next rank>" (left), cash and a settings gear (right).
  - Mode cards: Pursuit / Sky Arena / Rooftop Rumble, each with a drawn icon and your record in it
    ("Beat 18,477", "2 won of 18"). A card selects; PLAY (now the only primary action) starts it, with
    "PURSUIT · KESTREL · DOWNTOWN" underneath. Modes no longer start on one tap from the title.
  - Dock: Garage / Records / How to play with icons.
  - The attract camera frames your car on the right third (`ChaseCamera.frame_shift`), clear of
    the panels; edge shading top and bottom so the bar and dock read over bright streets.
  - The daily streak bonus is a one-off banner with a chime, not a permanent chip.
  - Blocks fade up in sequence; PLAY fades through black so the cut to the start spot isn't seen
    (both skipped with Reduce motion). Gamepad / keyboard focus starts on PLAY.
- **Safe area**: every menu screen's margins now keep clear of the notch / home indicator (the HUD
  and touch controls already did; menus sat 64 canvas px from the edge, inside the notch on iPhone).
- Test: `game.test_9d_title_screen` (all title controls on screen, card selects without starting,
  PLAY starts the selected mode, camera framing on the title and centred in the chase).
- Checked here at 16:9, 4:3 (iPad) and 19.5:9 (iPhone) under Xvfb. Needs a person: the launch →
  splash → loading → title sequence on a real iPhone (load time there), and whether one extra tap to
  pick a battle mode is fine.

# Status: 2026-11-11 (0.4.0)

## 0.5.0: battle modes, tighter turning, bigger stick, police from ahead

- **Turning** (`Car.TURN`, `LOW_SPEED_PIVOT`, `DRIFT_PATH`): at town speeds (fading out by
  ~50 km/h) full lock pivots the car tighter and may rotate further past tyre grip; held drifts
  curve 1.25x tyre grip (was 0.8x, so a slide used to run wider than gripping). U-turn at
  30 km/h: 1.25-2.05 s and 5-10 m wide (was 1.7-2.9 s, 8-14 m); 60 km/h unchanged for grip cars,
  RWD cars 33-43 m (was 39-49). High-speed handling unchanged (steering tests pass).
  `test_steering.test_u_turns` checks it.
- **Smart stick**: radius 115 (was 72), knob 46, brake 36 px / NOS 54 px / drift 72 px down /
  up / sideways (drift was 32 px, so steering on the stick kept pulling the handbrake), sits
  further in from the corner; JUMP / DROP buttons 90 px.
- **Police come from ahead**: units start on one of the player's possible onward routes
  (random routes through the road graph), usually just round a corner off it, never behind;
  units waiting to come in hold ahead and to the sides instead of behind the camera. Heat 3,
  40 s: 28 / 31 started ahead, 13 / 16 reached the player as cars from in front, 0 seen
  appearing. `game.test_2_police_arrive_fairly` checks >= 80 % ahead.

## Battle modes (Sky Arena, Rooftop Rumble)

Two new modes on the title screen under PLAY (`Game.start_mode`, `--mode=sky|rooftops`;
`src/modes/arena.gd`). Ten cars (yours plus one of each of the other nine garage cars, some with
ram bars / plating), no police, no traffic, no rails: whoever goes over the edge is out, last
car standing wins. 3-2-1 countdown with everyone held; HUD shows cars left and your knockouts;
minimap shows rivals; results show your finish, knockouts and a cash bonus (win $2,500,
otherwise $150 per car you outlasted); Records shows wins / best finish per mode
(`SaveData.data["battles"]`).

- **Sky Arena**: a 64 m floating disc 72 m above the nearest open spot to downtown (picked from
  the layout so no building reaches it), hazard-striped rim, glowing edge and thrusters underneath.
- **Rooftop Rumble**: steel decks on five of the tallest business towers (decks ~330 m up), joined
  by five open girder bridges. Decks may stand up to 24 m over their roof on a frame so towers of
  different heights meet with gentle ramps (≤ 20 %); a thin mast through a deck's middle stays
  as a pillar. Chosen from the layout at start-up (~80 ms).
- **Rivals** (`Arena.Bot`): drive at a victim with `AIDriver` (rams on), route deck to deck over
  the bridges, cap their speed by the deck left ahead so they can stop, back off when the nose is
  over the edge, shove what they hit, spread out (a car hunted by two others is less appealing),
  and are righted when flipped. Knockout credit goes to whoever last touched the car (contact
  checks, so slow pushes count) within 4 s. Mines / caltrops work on rivals.
- Test: `game.test_9c_battle_arenas` (arena placement, slots and bridge ramps drivable, decks
  connected, cars held during the countdown, knockouts happen, city restored afterwards).
- Not published / not on TestFlight yet. Needs a person: whether the fights feel fair on touch,
  the arena sizes, how hard the rivals are, and frame rate on a real iPhone with ten cars.

## 0.4.1: smart stick, harder-hitting crashes, water and ghost-police fixes

- **Smart stick** (Settings → Right hand → Smart stick, the default). Thumb down
  anywhere on the right half = gas; drag down = brake (held = reverse), up = gas
  + NOS (cars with nitro), sideways = drift (and steers, if the left thumb is
  free). Diagonals combine. A haptic tick marks each zone. "Pedals" and "Auto
  gas" are still there. JUMP / DROP sit up the right edge.
- **Rams** (`Game._ram`): driving into a car (closing ≥ 6 m/s, us the faster one)
  shoves and spins it with a pop, gives back part of our speed, hit-stop + lens
  punch, a low crunch layer, the victim's paint flying, a panel ripped off on
  big hits, and SLAM / BIG SLAM / SMASH points without breaking the chain. A cop
  wrecked within 1.5 s of contact = TAKEDOWN with a short slow-motion beat. Time
  effects are off with Reduce motion and in headless runs.
- **Water**: the collision floor sits 1.4 m under the surface, so cars used to
  drive about on the bottom. Now `Car.in_water`: engine dead, heavy drag, a
  splash; the player is fished back onto a dry road after 1.4 s, police are
  written off, sunk civilians recycled.
- **Ghost police**: units on the road graph (over the car budget, or waiting to
  come in out of view) used to drive right up to the player with no car, which
  left map dots with nothing there (and civilians pulled over for them). They now
  hold 150 m out, slip to an out-of-view spot if the player drives up to them,
  and show on the minimap as hollow rings. `test_2b` counts ghosts (0) and wet
  police (0); `test_2d_water_and_ramming` is new.
- Needs a person: stick thresholds on a real iPad / iPhone; whether hit-stop
  feels punchy or stuttery.

## 0.4.0: iPad, police fixes, breakable cars, repair stations, the Workshop

- **iPad.** The iOS build now targets iPhone and iPad (`targeted_device_family=2`, Xcode `TARGETED_DEVICE_FAMILY = "1,2"`,
  iPad icons 152/167 generated, landscape full-screen as before). On a 4:3 screen the chase camera keeps the 16:9
  horizontal field of view (more sky and street above, nothing cropped at the sides) and so does the garage preview.
  Touch controls are scaled by real screen size (`TouchDrive.control_scale`: canvas units are ~2.3x bigger in the
  hand on a 12.9" iPad than on an iPhone), so pedals and the steering slide stay thumb-sized; they still come out a
  little larger than on a phone. Not checked on a real iPad yet.
- **Police / map bugs** (new `game.test_2b_police_stay_sane`: a 90 s heat-5 chase, every police car sampled
  twice a second; checked on 10 seeds):
  - Police nosed into a wall or wreck sat there for good: the whiskers held the target speed at 0 but the throttle
    formula still gave 0.4, under the car's 0.5 stuck threshold, so recovery never started. The driver now backs out
    after 0.9 s blocked, and the stuck threshold is 0.3.
  - Crippled police (front end at 100 %) reversed in circles forever: the "stuck 6 s and damaged = wreck" rule never
    fired because the AI's own reverse reset the stuck timer. The director now has a watchdog that measures real
    progress: a unit that goes nowhere, wanders off the road (away from the player) or ends up inside a building's
    collision is put back on the road graph out of view, or written off if crippled and in view.
  - Demoted units kept the car's off-road position, so their minimap dot (and the next spawn) could sit inside a
    block; they now snap to the nearest lane.
  - A wreck was occasionally shot 130 m into the air by the solver (squeezed out of a pile-up); cars are now capped
    at 18 m/s upwards and 95 m/s overall.
  - Before: 2 inside buildings, 4 stuck per 90 s run. After: 0 inside, 0 stuck, 0 falling through, every map marker on
    a road (off-road counts are cars chasing across plazas).
- **Breakable cars.** Bumpers, bonnet, boot and both doors wear per hit and fall off (`Car.parts`, `part_lost`):
  the panel flies off as debris (16 pieces shared, 9 s each) and primed bare metal shows where it was. A side whose
  panel is gone takes 25 % more per missing panel. Done by filtering the body's index buffer (no extra draw calls
  until something falls off). Police and civilians lose panels too.
- **The engine never dies.** The player's car can't be wrecked by damage any more (`Car.immortal`): health bottoms
  out at 20 %, power at 62 %, with heavy smoke. Busted still means boxed in and stopped.
- **Repair stations** (`src/world/repair_pickups.gd`): green beacons 70 m tall, a spinning wrench-cross and a ring
  on the road. Always 3-6 in the city (a run starts with 4-5; a used one is replaced at once, 230 m+ from the player;
  another appears every 18-32 s up to 6), at least 200 m apart, anywhere on the road network. Drive through one:
  panels back on, dents out, tyres fixed, +250. The minimap shows them and pins the nearest to its rim; the HUD shows
  "REPAIR 340 m" with an arrow once the car is damaged.
- **Workshop** (garage tab; `CarCatalog.MODS`, `src/vehicle/battle_kit.gd`), Arena-style battle conversions that
  show on the car (garage preview and in the chase) and can be knocked off again:
  - Ram Bar: push bar (rams 1.5x, nose takes 40 % less) / spiked plough (2.2x, 60 % less).
  - Armour Plating: light / heavy / Juggernaut (-20/-35/-50 % damage, heavier, slightly slower). The plates are parts
    themselves: a hit wears the plate first and it falls off before the bodywork is touched. Juggernaut adds window cages.
  - Spiked Wheels: side swipes shred police tyres and hit 1.3x harder.
  - Hydraulics: JUMP hops ~3 m every 6 s / ~5 m every 4 s (over roadblocks and spike strips).
  - Rear dropper: Caltrops (3/5 charges, puncture police tyres) or Proximity Mines (2/4, wreck the police car that
    finds one and throw nearby ones about); one fitted at a time, charges refill.
  - Controls: touch JUMP / DROP buttons above BRAKE / DRIFT (with recharge rings), keys E / Q, pad B / LB.
- HUD: a top-down diagram of the car's panels beside the damage bar (and the plates round it).
- Sounds (synthesised, `gen_sounds.py assets/audio battle`): repair, panel off, explosion, hydraulics, drop.
- Tests: 38 unit/physics + 14 whole-game, all passing (new: panels fall off / engine never dies / repair; Workshop
  mods; police sanity; repairs + battle kit). Swarm benchmark (heat 9, 105 units, Medium) avg 10.8 ms / p95 14.8
  (0.3.2 code on the same seed: 13.2 / 17.7). Web build 13/13 in Chromium. iOS Xcode project exports.
- `tools/lineup.sh` takes mods and missing panels: `marlin+ram2+plating3+spikes1+mines2~bumper_f~door_l`.
- **Not checked by a person yet:** iPad layout and control size on a real iPad, the feel of losing panels, whether
  3-6 repair stations is the right number for the map size, Workshop prices against the cash curve.

# Status: 2026-11-09 (0.3.2)

## 0.3.2: driving pass (`tests/test_driving.gd`, every car, every manoeuvre)

Measured before → after; each is now a test with a target.

| Manoeuvre | Before | After |
|---|---|---|
| Lift off GAS at 100 km/h | 0.4 m/s² (coasted: 97 km/h after 2 s) | ~2.1 m/s² engine braking (85 km/h after 2 s) |
| Brake hard mid-corner at 90 km/h | every car slid to ~65° (spin) | 10–15°: ABS keeps cornering grip; the drift assist (which holds a slide) now only engages for the handbrake or power-oversteer |
| GAS while rolling backwards | slow to change direction | brakes first, then drives off (+27 km/h in 1.5 s from −22) |
| Nitro, 2 s from 100 km/h | Brute +11 km/h (boost went into rear wheelspin) | a direct push: +20 to +53 km/h on every car |
| Player hit by police | full spin carried through | spin halved at the hit, 0.6 s of strong stability after |
| Keyboard steering ramp | 0.31 s to full lock | 0.15 s |

Already good and now guarded by tests: lane change at 100 km/h (4.3–5.7 m sideways, settles straight, ≤ 6° slip),
slalom at 80 km/h (≤ 7° slip, keeps pace), handbrake flick at 60 km/h (70–83° in 1 s, drives away clean),
turning circle at 15 km/h (4.2–6.9 m), glancing a wall at 30°/90 km/h (keeps 63–68 km/h, no spin-out).

Also: the test runner's watchdog used game time, which `--fixed-fps` runs much faster than real time, so a
long but healthy suite was killed at "600 s"; it now uses wall-clock time (full unit suite: 12 s).


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
