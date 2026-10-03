# FS25_DroneCam

A client-side Farming Simulator 25 mod that switches to a drone-style camera
while the vehicle you are controlling is working a field, and hands back to the
normal vehicle camera when work stops.

Three angles — **Chase**, **Top-down** and **Orbit** — plus an **Auto director**
mode that mixes them with five close-ups (wheel, implement, side tracking, front
low and rear quarter), roughly alternating wide and close. Wide angles are held
10–15 seconds and close-ups 6–10, no angle repeats twice in a row, nothing
changes during a headland turn, and a close-up gives way to a wide angle as soon
as a turn begins. Close-ups are placed and scaled from the measured vehicle and
implements, so they suit a compact tractor and a combine alike, and they are
kept out of the ground, the vehicle and standing crop. Every change of angle is
a two-second blend that swings round (and if need be over) the vehicle rather
than a hard cut. All of it
has framerate-independent smoothing, terrain clamping and an obstacle raycast
that lifts the shot clear of trees and buildings. No events are sent and nothing is synchronised, so it is
safe in multiplayer and does nothing on a dedicated server.

## Controls

All four are rebindable in the game's control settings.

| Default | Action |
| --- | --- |
| `Ctrl+D` | Toggle automatic mode |
| `Ctrl+C` | Cycle Chase → Top-down → Orbit → Auto director |
| `Ctrl+F` | Force the drone camera on, even when not working |
| `Ctrl+H` | Hide the HUD while the drone is flying |

Settings persist to `modSettings/FS25_DroneCam.xml` in your game profile
directory. Values out of range are clamped on load, so a hand-edited file cannot
leave the camera unusable.

## Layout

```
modDesc.xml                      descVersion, input bindings, l10n
icon_DroneCam.dds                256x256 DXT1
l10n/l10n_en.xml
scripts/DroneCam.lua             manager: state machine and input
scripts/DroneCamCamera.lua       camera node, smoothing, angles and blends
scripts/DroneCamDirector.lua     Auto director: shot timing, choice, turn hold
scripts/DroneCamRig.lua          vehicle + implement measurement, vehicle floor
scripts/DroneCamWorkDetect.lua   field-work detection and hysteresis
scripts/DroneCamSettings.lua     defaults and XML persistence
test/test_dronecam.lua           offline test suite
tools/make_icon.py               regenerates icon_DroneCam.dds
```

`test/` and `tools/` are development-only and are left out of the release zip.

## Running the tests

`test/test_dronecam.lua` stubs the engine and game globals the mod touches, then
drives it through a simulated work session. It covers engage/disengage timing,
framing and aim, the terrain clamp, obstacle avoidance, all three angles, the
Auto director (hold times, no repeats, headland hold, no hard cuts), close-up
placement and scaling on a small tractor, a mid tractor with a cultivator and a
combine with a 9m header, ground/vehicle/crop clearance checked every frame of
long simulated flights, combine
and hired-helper detection, settings round-tripping, and every path that must
return the player to their own camera.

The game runs Lua 5.1, and macOS ships no Lua, so build one once:

```sh
curl -sSLO https://www.lua.org/ftp/lua-5.1.5.tar.gz
tar xzf lua-5.1.5.tar.gz
cd lua-5.1.5 && make macosx && cd ..
```

Then, from the mod root:

```sh
lua-5.1.5/src/lua test/test_dronecam.lua
```

It prints a line per check and exits non-zero if any fail. Set `MOD_DIR` to run
it against a mod folder somewhere else. Lua 5.1 specifically: the suite and the
mod both use `math.atan2`, which later versions removed.

## Regenerating the icon

`icon_DroneCam.dds` is a 256x256 DXT1 texture built by `tools/make_icon.py`,
which needs nothing beyond the Python 3 that ships with macOS:

```sh
python3 tools/make_icon.py icon_DroneCam.dds
```

The output is deterministic, so re-running it on an unchanged script reproduces
the committed file byte for byte.

## Packaging a release

From the mod root:

```sh
zip -r ~/Desktop/FS25_DroneCam.zip . -x "test/*" "tools/*" "README.md" ".git/*" ".gitignore"
```

That leaves the development-only files and git metadata out of the archive.
It writes to the Desktop deliberately: `mods/` is the parent of this folder, and
a zip sitting next to the unpacked folder would leave the game seeing the mod
twice. Move the zip into `mods/` only after removing the folder.

To run it unpacked instead, put this folder in `mods/` directly — the game only
loads unzipped mods with developer controls enabled (`<development><controls>`
in `game.xml`).
