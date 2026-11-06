# NEVER STOP

*The police will catch you. Make them work for it.*

An arcade police-pursuit survival game by Musa Studios. Godot 4.5.1 (GDScript,
Mobile renderer, Jolt physics), iPhone first (landscape), with a playable web
test build. You start in a city with one patrol car on your tail; every minute
more units join – interceptors routing ahead of you, rammers going for PIT
manoeuvres, heavy 4x4s, roadblocks with spike strips, a helicopter – until the
whole city is after one car. You are caught when you're boxed in or wrecked,
never because one car touched you.

| | |
|---|---|
| Run it | `godot res://scenes/main.tscn` (title + attract chase) · `-- --play` straight into a chase |
| Tests | `tools/test.sh` (unit/physics suite + whole-game suite) |
| Build everything | `tools/build.sh` (tests, Linux self-test, web, iOS Xcode project) |
| Web test build | `tools/export_web.sh` then `python3 -m http.server -d build/web 8160` |
| Captures | `tools/filmstrip.sh <name> "6,14,22" --play --bot --heat=4 --save=user://scratch_save.json` |

## Controls

| | Touch (default) | Keyboard | Gamepad |
|---|---|---|---|
| Accelerate | automatic | W / ↑ (automatic too) | RT |
| Steer | slide a thumb anywhere on the left side (or ◀ ▶ buttons, or tilt – Settings) | A D / ← → | left stick |
| Brake / reverse | BRAKE (hold at a standstill to reverse) | S / ↓ | LT |
| Drift (handbrake) | DRIFT | Space | A |
| Nitro (if fitted) | NOS | Shift | X |
| Recover | automatic when stuck / upside down | R | Y |
| Pause | II chip | Esc / P | Start |

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) – how the game is put together
- [docs/BUILD.md](docs/BUILD.md) – building, testing, the web build, iOS
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md) – measured results and budgets
- [docs/ASSETS.md](docs/ASSETS.md) – where every asset comes from, licences
- [docs/STATUS.md](docs/STATUS.md) – what's done, what isn't, next priorities

NEVER STOP is a standalone project. Its city systems were copied from
CitySwing (Musa Studios' own game) and adapted; there is no runtime dependency
on the CitySwing directory and CitySwing was not modified.
