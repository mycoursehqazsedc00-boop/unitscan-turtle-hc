# unitscan-soft (mod-aware fork)

A fork of [unitscan-soft](https://github.com/gttnvk/unitscan-soft) — a 1.12
vanilla/Turtle WoW addon that alerts you when a tracked NPC (a specific name
you add, or a curated zone list of rares/dangerous elites) spawns nearby.

This fork adds **optional** integrations with five popular 1.12 client mods.
None of them are required — with nothing installed, this addon behaves
exactly like upstream. Each integration is feature-detected at load time, so
it's safe to run with any subset of these installed.

## Why fork it

The original addon finds NPCs by calling `TargetByName(name, true)` on a
timer: it briefly switches your actual target to check for a name match, then
switches back. That's a real target change — other addons see a
`PLAYER_TARGET_CHANGED` event for it, and the scan has to stay dormant
whenever you already have something targeted, since it can't safely check
names without touching your target.

With [ClassicAPI](https://github.com/brues-code/ClassicAPI) installed, this
fork scans nameplate unit tokens instead: your real target is never touched,
the scan works even while you already have a target, and detection is
event-driven instead of polled once a second.

## Mods this integrates with (all optional)

| Mod | What it adds here |
|---|---|
| [ClassicAPI](https://github.com/brues-code/ClassicAPI) | `nameplate1..nameplateN` unit tokens (scan without touching your target), `NAME_PLATE_UNIT_ADDED` event (instant detection instead of polling), native `UnitDistanceSquared`/`UnitInLineOfSight` (range/LOS filtering) |
| [SuperWoW](https://github.com/balakethelock/SuperWoW) | `UnitExists()` returns a GUID as its 2nd value — used as a GUID source |
| [nampower](https://github.com/brues-code/nampower) | `GetUnitGUID`/`UnitGUID` — alternate GUID source; `UNIT_DIED` event — instantly drops a found zone-target instead of waiting on the reload timer |
| [UnitXP_SP3](https://codeberg.org/konaka/UnitXP_SP3) | Fallback range/LOS source if you have UnitXP but not ClassicAPI; `notify("taskbarIcon"/"systemSound")` for background alerts while tabbed out (no ClassicAPI equivalent for this one) |
| [VanillaHelpers](https://github.com/isfir/VanillaHelpers) | `SetUnitBlip` — custom minimap marker on whatever was just found |

Also uses `TargetUnit(unit)`, which is native to the base 1.12.1 client (not
added by any mod above) for reliable retargeting by GUID or live unit token.

## What's new / improved vs. upstream

- **No more target flicker.** With ClassicAPI, scanning walks nameplate
  tokens instead of hijacking `target` every second. Other addons never see
  a spurious target change from this addon.
- **Works while you already have a target.** Upstream refuses to scan at all
  if `UnitExists("target")`. The nameplate path has no such restriction.
- **Event-driven, near-instant detection.** Hooks `NAME_PLATE_UNIT_ADDED` so
  a match fires within a tick of the nameplate appearing, instead of waiting
  up to 1 second for the next poll. The 1-second poll still runs as a
  safety net (e.g. for plates that existed before the addon loaded).
- **GUID-aware.** Captures a GUID for whatever's found (via SuperWoW,
  nampower, or ClassicAPI's resolver) so retargeting and death-tracking are
  unambiguous even with duplicate-named mobs nearby.
- **Reliable retarget.** `/unitscantarget` now targets the live unit token or
  GUID directly via `TargetUnit` instead of `TargetByName(name)`, which can
  grab the wrong mob when two share a name. Falls back to the old
  name-based method if no live token/GUID is available.
- **Native range filter — `/unitscanrange <yards>`.** Only alert within a
  given distance. Uses ClassicAPI's native `UnitDistanceSquared` if present,
  falls back to UnitXP_SP3's `distanceBetween` otherwise.
- **Native line-of-sight filter — `/unitscanlos on|off`.** Same
  native-then-UnitXP-fallback pattern, using `UnitInLineOfSight`.
- **Elite noise control — `/unitscanelite on|off`.** Suppresses alerts for
  plain `"elite"`-classified mobs from the auto-populated zone list (useful
  in elite-dense open-world zones). Rares, rare-elites, and world bosses are
  never suppressed by this. Anything you added yourself with `/unitscan
  <name>` always alerts regardless of this setting — you asked for that one
  specifically.
- **Minimum level filter — `/unitscanlevel <number>`.** Only alert for mobs
  at or above a given level.
- **Instant death cleanup.** With nampower's `UNIT_DIED` event, a found
  zone-target is dropped the moment it dies instead of waiting on the
  90-second reload timer.
- **Background alerts.** With UnitXP_SP3, a found target also flashes your
  taskbar and plays an OS-level sound, so you notice even if the game window
  isn't focused.
- **Minimap blip.** With VanillaHelpers, drops a distinct marker on the
  minimap for whatever was just found.
- **`/unitscanmods`** — new command, prints exactly which of the five mods
  were detected and which scan strategy (event-driven nameplate scan vs.
  legacy flicker-scan) is currently active. Useful for confirming your
  install is actually being picked up.
- **`/unitscanhelp`** — new command, full in-game command reference.
- **Graceful degrade, always.** Every integration above is feature-detected
  independently. With zero of these mods installed, behavior is identical to
  upstream unitscan-soft.

## Slash commands

| Command | Description |
|---|---|
| `/unitscan <name>` | Toggle tracking of a specific NPC by name |
| `/unitscanlevel <number>` | Only alert for mobs at or above this level (0 = all) |
| `/unitscanwf <seconds>` | Auto-close time for the popup window (0 = manual close) |
| `/unitscanrange <yards>` | Only alert within this range (0 = unlimited). Native via ClassicAPI, or UnitXP_SP3 fallback |
| `/unitscanlos on\|off` | Also require line of sight to alert. Native via ClassicAPI, or UnitXP_SP3 fallback |
| `/unitscanelite on\|off` | Suppress plain "elite" hits from the zone-target list |
| `/unitscantarget` | Retarget the last detected NPC |
| `/unitscanmods` | Show which optional mods were detected and which scan method is active |
| `/unitscanhelp` | Show the full in-game command reference |

## Installation

1. Drop this repo's contents into `Interface/AddOns/unitscan-turtle-hc/`
   (same folder name/structure as upstream — this is a drop-in replacement
   for `unitscan.lua` only; `zonetargets.lua` and the `.toc` are unchanged).
2. Any subset of ClassicAPI, SuperWoW, nampower, UnitXP_SP3, and
   VanillaHelpers can be installed alongside it — none are required.
3. In-game, run `/unitscanmods` to confirm what was detected.

## Credits

- Original addon: [gttnvk/unitscan-soft](https://github.com/gttnvk/unitscan-soft)
- [ClassicAPI](https://github.com/brues-code/ClassicAPI)
- [SuperWoW](https://github.com/balakethelock/SuperWoW)
- [nampower](https://github.com/brues-code/nampower)
- [UnitXP_SP3](https://codeberg.org/konaka/UnitXP_SP3)
- [VanillaHelpers](https://github.com/isfir/VanillaHelpers)
