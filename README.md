# FS25_DroneCam

A client-side Farming Simulator 25 mod that switches to a drone-style camera
while the vehicle you are controlling is working a field, and hands back to the
normal vehicle camera when work stops.

Three angles — **Chase**, **Top-down** and **Orbit** — plus an **Auto director**
that cuts between those, five close-ups and nine creator shots:

- **Close-ups:** wheel, implement, side tracking, front low, rear quarter.
- **Creator shots that hold a framing:** establishing (high over the whole
  field, drifting slowly), long lens (150m off, zoomed in tight), field-edge pan
  (a fixed spot on the hedge line that pans to follow) and headland (a fixed
  spot past the row end, the vehicle turning towards it).
- **Creator shots that travel:** push-in (from 150m out and high to the chase
  position), pull-out reveal, fly-over (front to back over the vehicle),
  rise-up (low behind, climbing to top-down) and slide (far off to the side).

Auto director has two styles, both on Ctrl+C. **Story** follows establishing →
push-in → two or three close-ups → fly-over → pull-out reveal and round again,
with stand-ins (long lens, field-edge pan, rise-up, slide, orbit) now and then
so no two loops match. **Random** mixes everything, roughly alternating wide and
close. In both, wide and fixed shots hold 10–15 seconds, moving shots 7–10 and
close-ups 6–10; nothing repeats twice in a row; the headland shot is taken as
the row end comes up; nothing changes during a headland turn; and a close-up
gives way to a steady wide shot as soon as a turn begins.

Fixed spots are checked before use: never inside or under a tree or building,
never tight against a wall, and with a clear line of sight past terrain, trees
and buildings to where the vehicle is and will be over the next ten seconds. A
fixed shot that loses sight of the vehicle anyway is dropped within about a
second. Close-ups are placed and scaled from the measured vehicle and
implements, and kept out of the ground, the vehicle and standing crop.

Every change of shot is a glide, never a cut: two seconds normally, longer
(up to eight, at no more than 60 m/s) when the camera has a long way to go,
swinging round and if need be over the vehicle. The long lens and the slide
zoom in, and the zoom glides too. All of it has framerate-independent
smoothing, terrain clamping and an obstacle raycast that lifts the shot clear of
trees and buildings. No events are sent and nothing is synchronised, so it is
safe in multiplayer and does nothing on a dedicated server.

> **Public beta.** DroneCam is still being tested. Please report anything odd
> on the [Issues](https://github.com/chrismpmason/FS25_DroneCam/issues) page,
> with your `log.txt` and a short clip if you can.

## Download

**[Get the latest release](https://github.com/chrismpmason/FS25_DroneCam/releases)**:
the newest version is at the top of the page. Download `FS25_DroneCam_beta.zip`
under **Assets**. `TESTERS.txt` alongside it lists what to try and what to send
back.

Current beta: [DroneCam v0.9.3 Beta](https://github.com/chrismpmason/FS25_DroneCam/releases/tag/v0.9.3-beta).

Use the zip from the release, not GitHub's green **Code** button: that
downloads the source, with development files the game doesn't need.

## Install

1. Close Farming Simulator 25.
2. Copy `FS25_DroneCam_beta.zip` into your mods folder. **Don't unzip it.**
   The folder is usually `Documents\My Games\FarmingSimulator2025\mods`. If
   OneDrive backs up your Documents, look under
   `OneDrive\Documents\My Games\FarmingSimulator2025\mods` instead.
3. Remove any older copy of DroneCam (zip or folder) from that folder.
4. Start the game and tick **DroneCam (Beta)** in the mod list for your save.

## Controls

All four are rebindable in the game's control settings.

| Default | Action |
| --- | --- |
| `Ctrl+D` | Toggle automatic mode |
| `Ctrl+C` | Cycle Chase → Top-down → Orbit → Auto director (story) → Auto director (random) |
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
scripts/DroneCamDirector.lua     Auto director: story and random, timing, turn rules
scripts/DroneCamCreator.lua      creator shots: spot planning, paths, zoom
scripts/DroneCamRig.lua          vehicle + implement measurement, vehicle floor
scripts/DroneCamField.lua        field edges and extent
scripts/DroneCamSpot.lua         fixed-spot checks: clear spot, line of sight
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
long simulated flights, the story sequence and its variety, every creator
shot's spot or path, and story and random flights through a world with a
hedge, a forest and a barn where every frame is checked for obstacles, sight
of the vehicle, smoothness and zoom, combine
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

## License

Free to use and modify for your own personal use. Please don't re-upload it to
other mod sites; link here instead. Credit **The CMM Farmer**. See [LICENSE](LICENSE)
for the full terms.
