# LAST CAR STANDING — audit and prototype

The original composition root (`src/core/game.gd`) owns pursuit, traffic, repairs,
progression and arena modes. LCS uses a separate scene/composition root so none of
those single-player rules run in a network match. Both scenes instantiate the same
CityWorld/CityLayout, Car, CarVisual, ChaseCamera, DriveInput and TouchDrive.

Reusable systems audited:
- Car: Jolt rigid bodies, suspension/tyres, momentum/impulse damage, side damage,
  panel loss, handling deterioration. Normalized health is exposed as 0–100 HP.
- CarVisual: shared vehicle assets, wheel animation and procedural dents.
- CityWorld: both islands, bridge, static collision, visual streaming and LOD.
- RoadNet/AIDriver: connected road graph, shared flow field and real driving AI.
- Minimap.MapPainter: city map drawn from the same layout data.
- PursuitDirector, CivilianTraffic, RepairPickups, BattleKit, ScoreKeeper and
  progression rewards are deliberately absent from the new composition root.

Implementation and measured limits are recorded below after validation.

## Playing the prototype

Open NEVER STOP and choose **LAST CAR STANDING · ONLINE**. Host a room or enter
a server address and UDP port. The room queues humans, starts when full or after
20 seconds, and optionally fills its selected capacity with explicitly named bots.
The host can start early. Rooms support 2–100 competitors. The host is authoritative;
a dedicated server removes the host-player dependency. The original Pursuit, Sky
Arena and Rooftop Rumble remain in the original scene and save/progression flow.

```sh
# Dedicated server. Expose UDP 27970 for Internet clients.
godot --headless res://scenes/last_car_standing.tscn -- \
  --lcs-server --players=100 --port=27970
# Graphical client, using the existing keyboard/gamepad/touch controls.
godot res://scenes/last_car_standing.tscn -- --join=SERVER_ADDRESS --port=27970
# Local graphical host, 10 slots, named bot fill enabled.
godot res://scenes/last_car_standing.tscn -- --host --players=10
# Existing entry point also supports --mode=lcs.
```

Use `--no-bots` for human-only rooms, `--queue-seconds=60` to extend the queue,
`--class=sports|muscle|suv|heavy` and `--name=Driver` for a command-line client.
`--touch` enables the original mobile controls on desktop. MAP toggles the full
city map; ROOM opens the room/exit panel without pausing the online simulation.
An eliminated driver automatically follows a survivor; SPECTATE NEXT switches cars.
Return to NEVER STOP to create or join another match.

This is direct-address room matchmaking. There is no deployed public server,
account service, global region/skill queue, NAT relay, host migration or iOS build
upload in this change. ENet uses native UDP; this transport is not a browser/Web
export transport. A reachable dedicated endpoint is needed for Internet play.

## Rules and isolation

- All competitors start with 100 HP. The authoritative ledger awards exactly
  +35 HP per confirmed elimination, capped at 100; no other healing exists.
- Impulse divided by vehicle mass drives Car's existing collision damage.
  Side damage, power/grip loss, dents and detached panels remain functional.
  Elimination healing restores HP, not lost panels or mechanical alignment.
- Every damage tick is resolved as a batch before paying rewards. Dead attackers
  cannot heal or earn a posthumous reward; simultaneous last deaths produce a draw.
- The last damaging vehicle receives credit for eight seconds, including a
  subsequent storm/water finish. Disconnect elimination grants no kill or healing.
- No pursuit, civilian traffic, trains, ambient vehicles, pedestrians, repair
  stations, Workshop weapons, passive repair perks or save upgrades enter LCS.
- Street furniture removal/slowdown runs on the server; clients reproduce the
  removal/debris. Reconnecting clients receive persistent removed-prop positions.
- A disconnected competitor brakes and remains vulnerable for 25 seconds. An opaque
  random token restores that same vehicle and identity. Expiry eliminates the car.
  Inputs stale for 500 ms are neutralized; quitting cannot award another player HP.

| Class | Mass kg | Top speed km/h | Engine parameter m/s² | Grip | Durability |
|---|---:|---:|---:|---:|---:|
| Sports | 1,300 | 230 | 8.0 | 1.50 | 0.95 |
| Muscle | 1,700 | 212 | 8.6 | 1.32 | 1.10 |
| SUV | 2,200 | 191 | 6.8 | 1.38 | 1.25 |
| Heavy | 2,800 | 169 | 5.7 | 1.22 | 1.40 |

These are initial competitive profiles and still need human balance playtests.

## Storm and map

Seven phases collapse the zone over 740 active seconds (12m20s), following a
five-second start countdown. Damage rises from 1 to 20 HP/s. Current and next
circles, phase countdown, player and nearby threats appear over the existing city
map painter. The boundary uses one 128-segment cylinder and an unlit animated shader.

The road-site audit supplies 1,413 sites at least 18 metres apart. Spawn selection
guarantees participation on both islands. Every site lies on a road interval whose
ends can both reach, and be reached from, the bridge graph. Water-level lanes are
excluded; raised bridge decks remain valid. Finale selection first picks among
bridge, industrial, waterfront and street categories, then selects a road site.
All successive circles remain nested and converge on that validated site.

## Authority and replication

The server accepts bounded input controls, sequence numbers and a spectator target.
It never accepts client transforms, health, damage, kills or storm claims. Inputs
are checked for non-finite values, duplicates, stale ordering and excessive rate.
Client-to-client relay is disabled. This is prototype session identity rather than
an authenticated account/anti-cheat service.

The server runs shared Jolt cars at 60 Hz. Clients immediately predict their own
car with the same driving model, retain a bounded input-ack history and reconcile
pose/velocity with latency compensation. Remote cars interpolate snapshots and
never author collision damage. This is prediction with correction, not full Jolt
rollback/replay; latency/loss and mobile suspension need further device testing.

Near vehicles replicate at approximately 10 Hz, distant ones at approximately
1 Hz. The nearest 32 are included, plus every collision threat within 60 metres.
Serialized vehicle rows are cached per tick and clients are staggered across
physics frames to avoid 100-peer send bursts. Snapshots contain at most six vehicle
rows per packet. Stable names/classes and reliable elimination events are separate
from compact periodic alive/kill status. Deformation and panel loss are replicated.

Clients retain shared city streaming/LOD and FrameGovernor. At most 24 nearby cars
use full animated/damage visuals; other visible competitors use shared body/wheel
assets with no per-car deformed mesh or shadows. Server simulation includes all
competitors regardless of rendering distance. Headless servers omit cosmetic debris.

The original AudioDirector supplies engine, tyre, wind, crash and elimination
sounds. A small LCS audio adapter drives music tension from storm phase and survivor
count. Touch HUD elements honor the display safe area and the original pause control.

## Reproducing checks

```sh
godot --headless --editor --import --quit
godot --headless --fixed-fps 60 -s res://tests/run_tests.gd
python3 tools/lcs_verify.py
# Focused original title/mode switching regression:
godot --headless --fixed-fps 60 res://scenes/main.tscn -- --gametest=9d_title
```

The sequential verifier runs five fresh-process startup checks, progressive 10/25/50/100 physical-bot benchmarks,
a real two-client movement/reconnect/elimination/winner test, a complete storm
match, and 100 independent lightweight ENet protocol clients against one physical
server. The load clients omit rendering and local prediction; this validates
connections and replication, not 100 iPhones or real Internet latency.

Detailed logs and JSON are written to `build/lcs-bench`, `build/lcs-network` and
`build/lcs-verification`. `tools/lcs_road_audit.gd` reports graph/site categories.
`tools/lcs_capture.gd` captures the actual lobby and match HUD with a renderer.

## Measurements and remaining limits (2026-11-16)

Raw, reviewable results: [benchmark JSON](lcs-benchmark-2026-11-16.json).
The CPU table is a 90-second simulated run per size, at 60 fixed physics ticks/s,
with real Jolt cars and driving bots, on the development server. Rendering and
network clients are excluded from these simulation measurements.

| Competitors | CPU frame average ms | CPU frame p95 ms | Sampled peak process RSS MiB |
|---:|---:|---:|---:|
| 10 | 1.17 | 2.08 | 440.1 |
| 25 | 2.34 | 4.20 | 440.0 |
| 50 | 4.32 | 6.70 | 438.6 |
| 100 | 9.72 | 13.58 | 441.2 |

All 100 independent ENet clients were admitted, active and receiving snapshots.
The 22-second loopback probe received 65.7 MB of snapshot payload across all clients
(about 29.2 KiB/s per client averaged over the probe). The largest serialized
snapshot payload was 952 bytes. This excludes UDP/ENet headers and reliable metadata.
With the protocol clients running, the real-time server measured 16.69 ms average
wall frame and 19.58 ms p95; these include frame pacing and are not CPU-only costs.
Staggering replication removed the earlier 100-peer send spikes.

A ten-bot storm-driven match completed at 547.6 active seconds with one winner and
nine unique eliminations. Smaller rooms can finish before the 10–15 minute target;
the 12m20s collapse schedule bounds prolonged survival. A 100-human match duration
and competitive class balance have not been playtested.

The rendered touch/audio smoke check used OpenGL Compatibility on **llvmpipe**, a
software renderer: 465 peak draw calls and a 216.2 ms p95 viewport render timestamp.
That validates the scene and timing probe, and is not an iPhone GPU/FPS benchmark.
Native rendered runs with `--bench --report=user://lcs-device.json` collect viewport
render timings, adapter name, memory and draw calls for device profiling.

Validation passed: 52 unit tests (including 12 LCS tests), real two-client driving,
reconnect, elimination/healing and reliable winner state; the completed match;
100 simultaneous protocol connections; original title/mode-switch regression.
An earlier full original chase integration run passed its first ten checks, then
hit a 240-second limit during the five-minute stress case. The entire original
long-running integration suite was not completed in this session.

One focused run exposed an intermittent native crash while the existing road-field
baker ran on worker threads. LCS now bakes those fields on the main thread during
its loading screen, then restores the original parallel setting for other modes.
Fresh-process startup checks exercise this path. Existing Godot retained-resource
teardown warnings remain visible in original and LCS headless logs.

Before a public release: provision a reachable dedicated endpoint, test real
Internet latency/loss and mobile reconnect/backgrounding, profile on physical
phones (GPU, thermal behavior and total process memory), tune classes and bots
through human matches, and complete the long-session soak suite. This change does
not claim a production-validated 100-iPhone service.
