# Performance

## What has actually been measured (2026-11-06)

CPU cost of a whole frame (scripts + Jolt physics + audio mixing + UI logic),
headless, `--fixed-fps 60`, on the development VPS (AMD EPYC 9645, 8 vCPU).
**No rendering is included** (headless) and **nothing has been measured on an
iPhone** – the VPS has no device and no GPU.

| Scenario (60 s, autopilot) | Quality | Physical police (max) | Units in pursuit (max) | Frame avg | p95 | p99 | worst |
|---|---|---|---|---|---|---|---|
| Heat 1–2 | Medium | 2 | 4 | 5.8 ms | 8.3 | 10.7 | 15.3 |
| Heat 4 | Medium | 7 | 14 | 8.4 ms | 12.2 | 13.6 | 18.2 |
| Heat 8 swarm | Low | 8 | 43 | 7.4 ms | 10.8 | 12.6 | 17.5 |
| Heat 8 swarm | Medium | 12 | 48 | 8.3 ms | 11.7 | 13.6 | 18.4 |
| Heat 8 swarm | High | 16 | 47 | 8.9 ms | 12.6 | 15.0 | 22.1 |

Reproduce: `godot --headless --fixed-fps 60 res://scenes/main.tscn -- --play --bot --scenario=swarm --bench --quit-after=60 --quality=1 --save=user://scratch_save.json`
(prints `BENCH` lines and a per-section `PROF` breakdown).

A phone CPU core is slower than this server's and rendering comes on top, so
these numbers are an upper bound on what the simulation *needs*, not a device
frame rate. They do show the cost scales with the physical-car budget, not
with the size of the pursuit.

## Budgets that keep it flat
- **Simulation tiers**: only `cars_near` (Low 8 / Medium 12 / High 16) police
  are physical; the rest move along the road graph as points and are promoted
  out of view when they get close. Distant cars are demoted.
- **Shared routing**: one flow field to the player and one to the intercept
  point serve every unit, computed in ~1 ms slices (`RoadNet.FieldJob`).
  Before slicing, each recompute was a ~22 ms hitch twice a second.
- **AI**: tier-B units decide 5×/s; whiskers 10×/s.
- **Pools**: police cars per kind, civilians (14/22/30 by quality),
  particles (MultiMesh, 500 total), skid marks (1,400 ring buffer), debris
  chunks and thrown street furniture (budgeted by quality, 7–10 s lifetimes).
- **City**: CitySwing's streaming chunks, LODs, occluders, visibility ranges.

## Notes
- Godot's `TIME_PHYSICS_PROCESS` / `TIME_PROCESS` monitors report the worst
  frame of each second, not an average – the benchmark measures wall-clock
  time per frame instead.
- The web build (Compatibility renderer, single-threaded, software GL in the
  test harness) runs at ~1 fps headless; its test checks behaviour, not speed.
- On device: Settings → Show performance overlays FPS, frame ms, draw calls
  and police counts during a chase.
