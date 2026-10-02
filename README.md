# FS25_DroneCam

A client-side Farming Simulator 25 mod that switches to a drone-style camera
while the vehicle you are controlling is working a field, and hands back to the
normal vehicle camera when work stops.

Three modes — **Chase**, **Top-down** and **Orbit** — with framerate-independent
smoothing, terrain clamping and an obstacle raycast that lifts the shot clear of
trees and buildings. No events are sent and nothing is synchronised, so it is
safe in multiplayer and does nothing on a dedicated server.

## Controls

All four are rebindable in the game's control settings.

| Default | Action |
| --- | --- |
| `Ctrl+D` | Toggle automatic mode |
| `Ctrl+C` | Cycle Chase → Top-down → Orbit |
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
scripts/DroneCamCamera.lua       camera node, smoothing, modes
scripts/DroneCamWorkDetect.lua   field-work detection and hysteresis
scripts/DroneCamSettings.lua     defaults and XML persistence
test/test_dronecam.lua           offline test suite
```

## Running the tests

`test/test_dronecam.lua` stubs the engine and game globals the mod touches, then
drives it through a simulated work session. It covers engage/disengage timing,
framing and aim, the terrain clamp, obstacle avoidance, all three modes, combine
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

## Packaging a release

From the mod root:

```sh
zip -r ../FS25_DroneCam.zip . -x "test/*" ".git/*" ".gitignore"
```

That leaves the test suite and git metadata out of the archive. Drop the
resulting zip into your `mods/` folder.

To run it unpacked instead, put this folder in `mods/` directly — the game only
loads unzipped mods with developer controls enabled (`<development><controls>`
in `game.xml`).
