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
