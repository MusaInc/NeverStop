# Architecture

`scenes/main.tscn` is a single `Game` node (`src/core/game.gd`): the
composition root and state machine (MENU → PLAYING → PAUSED / BUSTED → …).
Everything else is a plain node or RefCounted built in code.

## World (`src/world/`, from CitySwing)
- `CityLayout` / `CityRoads` / `CityTerrain` – the deterministic island city
  (~1.0 × 1.3 km) and the mainland across a suspension bridge: districts,
  boulevards, ring road, roundabouts, terrain with real gradients. ~38 km of
  road, zero dead ends (`tools/road_dump.gd` + `tools/road_map.py` render the
  audit map).
- `CityWorld` – collision up front (buildings, street trimesh, props),
  streamed visual chunks with LODs and occluders. NEVER STOP changes: the
  GPU traffic and static parked cars are off (cars must be hittable),
  trees/bus shelters/planters are solid to cars (`SOLID_LAYER`), knocked-
  down furniture is filtered out (`broken`, `refresh_props`).
- `Jumps` – chevron kicker ramps placed on long straights (≥60 m run-up,
  ≥95 m landing), ~17 across the city.
- `Destructibles` – a spatial hash of ~3,600 lamp posts, traffic lights,
  signs, bins, benches, hydrants, bollards; cars knock them flying (a pooled
  physical copy, the city's instance removed).
- `RepairPickups` – 3–6 repair stations live at any time anywhere on the
  road network (spaced, spawned away from the player, replaced when used);
  driving through one calls `Car.repair_full()`.
- Atmosphere (day/night/weather), sea and sky, ad screens, trains: unchanged.

## Vehicles (`src/vehicle/`)
- `Car` (RigidBody3D) – the one driving model for player, police and wrecked
  civilians: four suspension rays (spring/damper, bump stop, anti-roll),
  slip-angle tyre model with a friction circle, RWD/FWD/AWD, handbrake,
  nitro, gears/rpm for audio. Arcade layer: speed-sensitive steering, a yaw
  assist capped at what the tyres can deliver, a drift controller that
  holds a slide angle from the steering and catches spins, air levelling,
  lateral force at a raised roll centre (no tripping). Damage from contact
  impulses per side → less power/grip, steering pull, grip loss after side
  hits, immobilised at 0 (not the player: `immortal`). Body panels
  (`parts`: bumpers, bonnet, boot, doors, Workshop plates) wear per hit and
  emit `part_lost`. `puncture` from spike strips / caltrops / spiked wheels.
- `CarCatalog` – ten player cars, three police kinds, upgrades, Workshop
  mods (`MODS`, `apply_mods`), paints, wheels.
- `CarVisual` – runtime materials keyed off glTF material names, spinning /
  steering / riding wheels, brake lamps, GPU police beacons
  (`beacon.gdshader`), procedural dents (vertices pushed in at the hit).
  Panels: each body triangle is assigned to a panel by region (`part_map`,
  cached per body); a lost panel is dropped from the index buffer, thrown
  as debris and replaced by a bare-metal inset. The Workshop kit (ram bar,
  plates, cages, spiked hubs, dropper) is built from primitives fitted to
  the body's `profile`.
- `BattleKit` – the player's active gear: hydraulic jump, caltrops and
  proximity mines with charges.
- Models: `tools/blender/build_vehicles.py` (lofted superellipse bodies,
  boolean wheel wells, painted-on lamps/livery, five wheel styles).

## Pursuit (`src/ai/`)
- `RoadNet` – CitySwing's lane network (both lands, stitched over the
  bridge) as a junction graph (~7,500 nodes). Routing is by *flow field*: one
  reverse Dijkstra from a target serves every unit. `FieldJob` computes it
  in slices (~1 ms a frame) so it never causes a frame spike.
- `AIDriver` – drives a Car through its normal controls: pure pursuit on a
  route or at a moving point, corner speed from curvature and skill,
  whiskers, stuck recovery. Police mistakes come from the same physics.
- `PursuitDirector` – heat escalation (time + wrecks/roadblocks), dispatch,
  roles (pursuer, interceptor, aggressor/PIT, blocker, heavy), simulation
  tiers (A close/every frame, B nearby/5 Hz, C distant road-graph points, D
  the count still to come), pooled cars, roadblocks + spike strips ahead on
  the predicted route, the helicopter, the bust meter. Fairness: spawns and
  promotions only out of view (frustum + occlusion ray) and away from the
  player; every one is logged in `audit` and checked by the game tests.
- `CivilianTraffic` – kinematic cars on wandering lane routes (queueing,
  pulling over for sirens, riding ramps) that wake into physics wrecks when
  hit; recycled out of view.

## Game systems (`src/core/`, `src/ui/`, `src/audio/`, `src/fx/`)
- `ScoreKeeper` – survival/distance income plus skill events (near misses,
  drifts, air, flat-out runs, cops wrecked, roadblocks) under a chain
  multiplier; heavy crashes break the chain.
- `SaveData` (autoload) – offline profile, atomic saves with backup
  recovery. `Progression` – 14 challenges, 5 starting locations.
- `Hud`, `Minimap`, `TouchDrive`, `Menus` (title, garage with `GarageView`
  turntable, records, settings, pause, results), `UiStyle`.
- `AudioDirector` – rpm-crossfaded engine loops, tyres, wind, scrape, 3-D
  sirens with doppler on the nearest four, helicopter, crash one-shots,
  heat-driven music stems, buses + limiter.
- `VehicleFx` – pooled MultiMesh particles (smoke, sparks, fire), skid
  marks, debris chunks. `SpeedFx` – speed streaks.
- `ChaseCamera` – smoothed heading, speed FOV/distance, wall pull-in,
  ground clamp, trauma shake, bust orbit.
