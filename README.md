# unitscan-soft (mod-aware fork)

A fork of [unitscan-soft](https://github.com/gttnvk/unitscan-soft) — a 1.12
vanilla/Turtle WoW addon that alerts you when a tracked NPC (a specific name
you add, or a curated zone list of rares/dangerous elites) spawns nearby.

## Required / Optional DLL Mods

None of these DLL mods are required — with nothing installed, the addon falls
back gracefully to pure Lua 5.0 / 1.12.1 APIs. All integrations below are
feature-detected at load time and at `PLAYER_LOGIN`.

| Mod | Role | What it adds here |
|---|---|---|
| [ClassicAPI](https://github.com/brues-code/ClassicAPI) | Optional | `nameplate1..nameplateN` unit tokens (scan without touching your target), `NAME_PLATE_UNIT_ADDED` event (instant detection), native `UnitDistanceSquared` / `UnitInLineOfSight` (range/LOS filtering) |
| [SuperWoW](https://github.com/balakethelock/SuperWoW) | Optional | `UnitExists()` returns a GUID as its 2nd value — used as a GUID source |
| [nampower](https://github.com/brues-code/nampower) | Optional | `GetUnitGUID` / `UnitGUID` — alternate GUID source; `UNIT_DIED` event — instantly drops a found zone-target instead of waiting on the reload timer |
| [UnitXP_SP3](https://codeberg.org/konaka/UnitXP_SP3) | Optional | Fallback range/LOS source when ClassicAPI is absent; `UnitXP("notify", "taskbarIcon" / "systemSound")` for background alerts while tabbed out |
| [VanillaHelpers](https://github.com/isfir/VanillaHelpers) | Optional | `SetUnitBlip` — custom minimap marker on whatever was just found |

Also uses `TargetUnit(unit)` and `SetRaidTarget(unit, index)`, which are native
to the base 1.12.1 client, for unambiguous retargeting and optional skull
marking.

## Why fork it

The original addon finds NPCs by calling `TargetByName(name, true)` on a
timer: it briefly switches your actual target to check for a name match, then
switches back. That creates spurious `PLAYER_TARGET_CHANGED` events, pauses
whenever you already have a target, and can stutter FPS in zones with large
target lists.

With [ClassicAPI](https://github.com/brues-code/ClassicAPI) installed, this
fork scans nameplate unit tokens instead: your real target is never touched,
the scan works even while you have a target, and detection is event-driven.

## What's new / improved vs. upstream

- **Auto-pause in raid instances (zero raid FPS overhead).** Automatically
  pauses scanning (`OnUpdate` script detached, `NAME_PLATE_UNIT_ADDED`
  unregistered) when entering a raid instance via `IsInInstance()`, and
  automatically resumes when leaving the raid instance (unless manually
  disabled).
- **Manual on/off toggle — `/unitscantoggle [on|off]`.** Manually turn the
  scanner on or off at any time (persisted across reloads). Turning it `on`
  inside a raid instance temporarily overrides the raid auto-pause for that
  raid.
- **Zero-allocation, faster nameplate scan.** Uses pre-allocated
  `nameplate1..40` token strings, skips `strupper()` when no custom
  `/unitscan` targets are set, and skips the loop when both target lists are
  empty. Polling safety-net runs every `0.5s` in open-world (`1.0s` in 5-man
  dungeons) alongside instant `NAME_PLATE_UNIT_ADDED` detection.
- **Time-sliced legacy fallback.** When ClassicAPI is not installed,
  `TargetByName` checks are spread across frames (`2` targets per `0.05s`
  tick) instead of scanning the entire zone list in a single frame.
- **No target flicker & works while targeting.** With ClassicAPI, scanning
  never touches `target`.
- **GUID-aware & reliable retargeting.** Captures GUIDs via nampower or
  SuperWoW so `/unitscantarget` targets the exact mob via `TargetUnit`.
- **Native range & line-of-sight filters.** `/unitscanrange <yards>` and
  `/unitscanlos on|off` using ClassicAPI native APIs (with UnitXP_SP3
  fallback).
- **Elite noise control & minimum level filter.** `/unitscanelite on|off`
  suppresses plain `"elite"` hits from the zone list while keeping rares,
  rare-elites, world bosses, and explicit `/unitscan <name>` targets;
  `/unitscanlevel <number>` filters by minimum level.
- **Instant death cleanup & background alerts.** `UNIT_DIED` (nampower) clears
  dead targets immediately; `UnitXP_SP3` flashes the taskbar/plays an OS sound
  when tabbed out; `VanillaHelpers` drops a minimap blip; `/unitscanmark`
  places a skull raid mark.
- **Diagnostics.** `/unitscanmods` shows detected mods and active scan mode;
  `/unitscantrace` toggles timestamped trace logging.

## Slash commands

| Command | Description |
|---|---|
| `/unitscantoggle [on\|off]` | Manually turn scanner on/off (persisted; `on` overrides raid auto-pause for current raid) |
| `/unitscan <name>` | Toggle tracking of a specific NPC by name |
| `/unitscanlevel <number>` | Only alert for mobs at or above this level (0 = all) |
| `/unitscanwf <seconds>` | Auto-close time for the popup window (0 = manual close) |
| `/unitscanrange <yards>` | Only alert within this range (0 = unlimited; ClassicAPI or UnitXP_SP3) |
| `/unitscanlos on\|off` | Also require line of sight to alert (ClassicAPI or UnitXP_SP3) |
| `/unitscanmark on\|off` | Drop a skull raid-mark on whatever is found |
| `/unitscanelite on\|off` | Suppress plain `"elite"` hits from the zone-target list |
| `/unitscantarget` | Retarget the last detected NPC |
| `/unitscanmods` | Show which optional mods were detected and which scan method is active |
| `/unitscantrace` | Toggle debug trace logging |
| `/unitscanhelp` | Show the full in-game command reference |

## Credits

- Original addon: [gttnvk/unitscan-soft](https://github.com/gttnvk/unitscan-soft)
- [ClassicAPI](https://github.com/brues-code/ClassicAPI)
- [SuperWoW](https://github.com/balakethelock/SuperWoW)
- [nampower](https://github.com/brues-code/nampower)
- [UnitXP_SP3](https://codeberg.org/konaka/UnitXP_SP3)
- [VanillaHelpers](https://github.com/isfir/VanillaHelpers)
