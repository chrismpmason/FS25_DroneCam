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
- **Hero shot: drive-over.** The camera sits 0.3m up on the ground 30–40m
  ahead, between the wheels, and the vehicle drives over it. As it passes
  the camera swings round in about 1.4 seconds to watch it go. It stays on the
  ground until everything towed (trailers, a sprayer and its boom) has gone
  over it too, then rises into the chase position. It is only used on a
  straight run with no headland coming, at 7 km/h or more, out of tall
  standing crop, not under trees, on even ground (a steady slope is fine, a
  bump is not), and when raycasts against the collision of the whole train
  find a line between the wheels with at least 0.32m clear underneath, front
  to back. The camera takes the line with the most room (beside a drawbar or
  hitch rather than under it, never in the track of a towed unit's wheels)
  and comes down to 0.2m below the underside, never lower than 0.12m.

  Mod collision is often rough, so a low reading isn't taken at face value
  everywhere. Any shape whose name (or a parent's) says wheel, tyre, hub or
  axle counts at hub height. So does any reading under a towed unit's axles
  that is lower than its hubs: an axle runs at hub height, so anything lower
  there is the collision, not the trailer. Each axle line gets its own rays,
  so a thin axle can't slip between them. The lowest collision shape found
  (name, node, height, where, and what it was counted as) goes into
  `log.txt` as a `[DroneCam] Underside:` line and onto the Ctrl+Shift+D
  overlay.

  If a vehicle is still turned down and you know it clears, put it on the
  allow list in `modSettings/FS25_DroneCam.xml`. The overlay's "Train:" line
  and the rejection message both give the name to use:

  ```xml
  <droneCam>
      ...
      <driveOverAllow>
          <vehicle xmlFilename="FS25_SomeTrailer/xml/trailer.xml"/>
          <vehicle xmlFilename="FS25_AnotherMod"/>
      </driveOverAllow>
  </droneCam>
  ```

  An entry can be the whole name, the end of it after a slash, or just the
  mod's folder name. A vehicle on the list always gets the drive-over, whatever
  kind of implement it is. Its collision is trusted no lower than its hubs (or
  ignored if it has no wheels). Edit the file with the game closed.

  What is attached decides whether it may try at all:

  | Attached | Drive-over |
  | --- | --- |
  | Tippers, grain trailers, chaser bins, bale trailers, low loaders, muck spreaders | yes, if the underside clears |
  | Sprayers, trailed or self-propelled, boom folded or unfolded | yes, if the underside clears; a lowered boom has to clear the camera too |
  | Slurry tankers | yes, unless a dribble bar or injector is lowered |
  | Balers, forage wagons | never |
  | Mowers, rakes, tedders, drills, cultivators, ploughs and anything else working the ground | not while lowered |
  | Combine headers and other front tools | only while raised |

  Every unit in the train is checked. Anything that can't say whether it is
  lowered counts as lowered. If anything folds, unfolds, is lowered or raised
  during the pass, the drive-over is called off: with a glide if nothing has
  reached the camera yet, otherwise with a straight cut to the next shot, so
  the camera never moves through the kit.

Auto director has two styles, both on Ctrl+C. **Story** follows establishing →
push-in → two or three close-ups → fly-over → pull-out reveal and round again,
with stand-ins (long lens, field-edge pan, rise-up, slide, orbit) now and then
so no two loops match, and the drive-over in place of the fly-over in about
one loop in three when it can be done. **Random** mixes everything, roughly alternating wide and
close. In both, wide and fixed shots hold 10–15 seconds, moving shots 7–10 and
close-ups 6–10; nothing repeats twice in a row; the headland shot is taken as
the row end comes up; nothing changes during a headland turn; and a close-up
gives way to a steady wide shot as soon as a turn begins.

**Field-size aware.** The field being worked is looked up in the game's own
field data (its outline and area) and sorted into small (under 2 ha), medium
(2–10 ha) or large (over 10 ha); both limits are settings (`fieldSmallHa`,
`fieldLargeHa` in `modSettings/FS25_DroneCam.xml`). Wide shots never pull out
much further than the field's longest dimension (never under 40m, so chase and
orbit keep their usual framing), heights are held to match, and the limit eases
in or out at no more than 40 m/s when you cross into another field. Story mode
adjusts its mix: on a small field chase opens each loop, there are three or four
close-ups, the drive-over plays in about six loops in ten, and orbit or chase
replaces the long pull-out; on a large field the establishing, push-in and
pull-out shots play more often, there are two close-ups, and each loop ends on a
long lens. Medium fields, and anywhere no field is found, get the usual mix. A
change of field takes effect at the start of the next loop.

Fixed spots are checked before use: never inside or under a tree or building,
never tight against a wall, and with a clear line of sight past terrain, trees
and buildings to where the vehicle is and will be over the next ten seconds. A
fixed shot that loses sight of the vehicle anyway is dropped within about a
second. Close-ups are placed and scaled from the measured vehicle and
implements, and kept out of the ground, the vehicle and standing crop.

Every change of shot is a glide, never a cut (the one exception: a ground
pass called off with kit already over or beside the camera, where any glide
would go through it): two seconds normally, longer
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

Current beta: [DroneCam v0.9.4.4 Beta](https://github.com/chrismpmason/FS25_DroneCam/releases/tag/v0.9.4.4-beta).

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

All are rebindable in the game's control settings.

| Default | Action |
| --- | --- |
| `Ctrl+D` | Toggle automatic mode |
| `Ctrl+C` | Cycle Chase → Top-down → Orbit → Auto director (story) → Auto director (random) → Drive-over |
| `Ctrl+F` | Force the drone camera on, even when not working |
| `Ctrl+H` | Hide the HUD while the drone is flying |
| `Ctrl+G` | Drive-over now, if it can be done safely (says why not if it can't) |
| `Ctrl+Shift+D` | Debug overlay, on until pressed again (details below) |

**Ctrl+G** asks for a drive-over straight away, in any mode, taking off first
if the drone is down. It still never skips anything that could put the
camera into the vehicle; only the row-end check is relaxed. The result
("started", or why not) stays top left for 8 seconds, and every result,
including a drive-over that is later dropped and why, goes into `log.txt` as a
`[DroneCam] Ctrl+G:` line.

**Ctrl+Shift+D** shows the debug overlay. It stays up until you press it
again, even with the drone landed. It shows the shot on screen (and the
drive-over's phase), the field and its size class, and the train as DroneCam
sees it: each unit, its name for the allow list, whether it is lowered ("n/a"
where that doesn't matter) and its fold state. It also gives the lowest
collision shape underneath, and whether a drive-over is possible right now:
the camera height and line it would use, or why not. Underneath that are the
last dropped pass and the last Ctrl+G result, and the camera's height with any
obstacle lift.

**Drive-over mode.** The last mode on Ctrl+C sets up a drive-over on every
straight run. When the drive-over isn't allowed (see the table above) or the
underside doesn't clear, it sets up a **wheel pass** instead. The camera
stands still 0.4m up, just outside the widest part of the combination, and
turns to follow the rig live. It watches the front of the tractor come in,
then pans back along it (front wheel, cab, rear wheel) to the implement
working the ground. Once everything has gone by it watches the implement
drive away for 2.5 seconds, then rises into the chase. The pan starts and
ends gently, and the view is held exactly on its subject from the moment the
camera sets off for its spot, so nothing trails behind even at speed. A boom
unfolding beside the camera calls the pass off too. The log says why it wasn't a drive-over ("wheel pass set
up (no drive-over: …)"). In between, and through headland turns, it holds a
low chase, and sets up the next pass once the vehicle has been straight for
1.5s (and at least 5s after the last). If a pass can't be done the reason stays
on screen ("Drive-over mode: waiting - …") and goes into `log.txt` as a
`[DroneCam]` line each time it changes. The Ctrl+Shift+D overlay lists the
train as DroneCam sees it, with each unit's fold and lowered state.

**Hired workers, Courseplay and AutoDrive.** While one of their jobs is running
on your vehicle, a drone that is up stays up, even while the vehicle waits or
isn't working, until the job ends, you leave the vehicle or change camera, or you
press Ctrl+D or Ctrl+F (which stands it down for the rest of that job). While the
vehicle stands still only steady wide shots are used — chase, top-down, a slower
orbit, establishing, long lens — never close-ups, drive-overs or moving shots.

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
scripts/DroneCamCreator.lua      creator shots and drive-over: planning, paths, zoom
scripts/DroneCamRig.lua          vehicle + implement measurement, vehicle floor
scripts/DroneCamField.lua        game field lookup, size class, field edges
scripts/DroneCamSpot.lua         fixed-spot checks: clear spot, line of sight
scripts/DroneCamKit.lua          what is attached: drive-over rules, fold/lower watch
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
of the vehicle, smoothness and zoom, the drive-over (every reason to skip it,
then full runs over a tractor with a real collision underside, one and two
trailers, a sprayer with its boom down and a combine with its header raised,
checked every frame for distance to every collision body; the rule for each
kind of implement; kit folding or lowering mid-pass; a base-game tipper and
a mod tipper with crude box collision round its axles, and the allow list),
combine
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
