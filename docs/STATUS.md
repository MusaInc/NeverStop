# Status: 2026-11-06 (first full build)

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
