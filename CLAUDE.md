# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

LibShowcase-1.0 is the **"showcase" camera presentation for World of Warcraft: Forever 1.60.1**
(Interface `16001`) addons, written in **Lua 5.1**, as an **embedded LibStub library**. Single
owner (Spotnick). It replaces AltStable's `AltStableCameraPresentation` block (`SheetUI.lua`) and
takes PortalRoulette's `Camera/CameraMode.lua` extras as opt-in options.

Players never install it: each addon embeds a copy under `Libs\LibShowcase-1.0\` through
`.pkgmeta` externals, and LibStub runs the newest copy loaded.

**Status (2026-10-04): r1 implemented, local only.** No GitHub repo, no tag yet. AltStable is
the pilot consumer (branch `feature/libshowcase` there). `docs/DESIGN.md` is the design.

When it is published it must be **public** (the packager clones externals anonymously). MIT.

## Layout

- **No TOC.** Entry point `LibShowcase-1.0.xml`: `LibStub\LibStub.lua`, then `LibShowcase.lua`.
- **`LibShowcase.lua`**: the one runtime file. `MAJOR, MINOR = "LibShowcase-1.0", N`.
- **`Tools\deploy.ps1`**: copies this checkout into `AddOns\<Addon>\Libs\LibShowcase-1.0`
  (preflight: the XML, every file it loads, LICENSE).
  **`Tools\LibShowcaseProbe\`**: a dev addon (`/lsprobe`) for the in-game measurements the design
  still depends on; `Tools\deploy-probe.ps1` installs it. Never shipped.
- **`docs\DESIGN.md`**: the design, the guarantees and the measured facts. **Any behaviour change
  updates it in the same commit.**
- **`tests\`**: see Testing.

## The contract (read before changing anything)

Within `LibShowcase-1.0` **the API only grows**: never remove, rename or change the meaning of a
function, option, default, public table or table key. A breaking change is `LibShowcase-2.0`.

- **`LibShowcase:New(opts)`** (colon; a dot call errors) returns a per-addon **instance**. Options
  are validated (unknown key or wrong type errors). The instance keeps them in `inst.opts`, its own
  table, read at each `Enter` (a consumer may change them between presentations).
- Instance methods, **colon-called**: `Enter(anchor?)`, `Exit(reason?)`, `ForceRestore(reason?)`,
  `IsActive()`, `IsOwner()`, `Acquire()`, `Release()`, `HideGameUI(anchor?)`, `RestoreGameUI()`,
  `IsGameUIHidden()`, `Lift(frame, strata?)`, `Drop(frame)`, `IsLifted(frame)`,
  `LiftPopup(dialog)` ("reveal for a dialog": brings the UI back, returns the dialog untouched),
  `DropPopup(dialog)` (a no-op, kept for API stability).
- Library functions, **dot-called**: `lib.SuppressExperimentalCVarPopup()`,
  `lib.ShoulderOffsetFor(race, zoom, mounted?)`.
- Public tables, filled in place: `lib.CENTRING_CVARS`, `lib.SHOULDER_FACTORS`,
  `lib.MOUNTED_SHOULDER_FACTORS`, `lib.RACE_IDS`.
- The crash-heal key in a consumer's `db` table: `LibShowcaseCapture`.
- **One owner.** The camera and the game UI are global, so `lib.state` holds one lease. Every
  mutation (UI hide, lift, camera, GameTooltip) needs it; another instance's calls are refused.

## Blizzard dialogs: never touch them

The library never calls `StaticPopup_Show` and never calls `SetParent`, `SetFrameStrata`,
`HookScript` or anything else on a StaticPopup / StaticPopupSpecial frame. MEASURED 70205: the probe's old `/lsprobe popup` called `StaticPopup_Show("LSPROBE_TEST")` from addon code, then `SC:LiftPopup(dialog)` (`SetParent(nil)`, `SetFrameStrata`, `HookScript("OnHide")` on the dialog frame); the player's later Quit dialog failed with `[ADDON_ACTION_FORBIDDEN] AddOn 'LibShowcaseProbe' tried to call the protected function 'ForceQuit()'` (`StaticPopup_OnClick` -> `OnAccept`). StaticPopup frames are a pool shared with Blizzard's secure code: touching one taints it, and protected buttons (accept a guild invite, Quit, Logout) then fail.
A dialog that appears while a lease holds the UI hidden is noticed by `hooksecurefunc` post-hooks
on `StaticPopup_Show` / `StaticPopupSpecial_Show`; the library brings the UI back through its own
restore (`ShowUI`, not read as Escape), keeps the presentation and the lease, and calls
`onGameUIShown("dialog")`. **Consumers must never call `StaticPopup_Show` for their own prompts:
use their own frames.** `SC:Lift` is for the consumer's own frames, never a Blizzard one.

## Upgrade rules (several addons ship copies; the newest one wins, and it may not be yours)

These follow `C:\Projects\References\EMBEDDED-LIBRARIES.md` §5. Treat it as fact.

- **Dispatch at call time.** Instance methods live in `lib.methods` (the instances' shared
  `__index`, a plain table) as `function(self, ...) return lib.impl[name](self, ...) end`. The
  `SetUIVisibility` and StaticPopup hooks, the event and `OnUpdate` scripts and every
  `C_Timer` callback call `lib.impl.<name>` when they run. Never capture an implementation
  function in anything that outlives the load.
- **Reuse tables in place.** `lib.impl`, `lib.methods`, `lib.instances`, `lib.state`, the frames
  and every public table keep their identity (`X = X or {}`, filled in place). Hooks are installed
  once (`lib.hooked`), events registered once each (`lib.events`).
- **Narrow migration.** A newer copy fills only missing option keys (`== nil`) on older
  instances, adds methods `lib.methods` lacks, and never touches a frame or the camera.
- **Completion marker:** `lib.ready = MINOR` on the **last line**; `New` fails loudly when it
  isn't the active MINOR.

## Releasing

As LibGlass: raise `MINOR` for every behaviour change in the same PR, tag the merge commit
`r<MINOR>`, never move a tag. Consumers pin `tag: rN` and bump only in a release they make anyway,
and repeat this repo's non-dot ignores under `Libs/LibShowcase-1.0/`. Before tagging: the pilot's
tests against this checkout (`$env:LIBSHOWCASE`, `pwsh ..\AltStable\tests\run.ps1`) and an in-game
check. No library CHANGELOG.

## Testing

Plain Lua 5.1, no dependencies, modelled on LibGlass's harness: `tests\wow_stubs.lua` (strict
globals, every stubbed global confirmed in the API dump; camera, CVars, `SetUIVisibility`,
combat lockdown and protected frames modelled; every global camera call logged in order),
`tests\harness.lua` (loads the library **through the XML's order**), `tests\run.ps1` (`luac -p` +
every `tests\test_*.lua`), `tests\mutate.lua` (mutation run; not part of the suite).

- **Behaviour parity:** `tests/test_parity.lua` runs AltStable's original block (frozen as
  `tests/fixtures/altstable_camera.lua`, `SheetUI.lua:196-911` @ AltStable `5297196`) and the
  library through the same scenarios and compares every camera, CVar and UI call in order.
- Must cover: upgrade (r1: a synthetic newer copy), isolation (two instances), single owner,
  the camera-OFF lease, combat during cleanup, a protected frame's deferred drop, the crash
  self-heal round trip, Blizzard dialogs (never touched; the UI brought back, the presentation
  kept), widget methods against the dump.
- **Mutation-test new tests** (`lua tests\mutate.lua`): every mutation must turn the suite red.

## Toolchain and commands

```powershell
& 'C:\Program Files (x86)\Lua\5.1\luac.exe' -p LibShowcase.lua   # syntax check; silent on success
pwsh tests\run.ps1                                               # luac -p + every tests\test_*.lua
& 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\mutate.lua      # mutation run
```

## References

- `C:\Projects\References\EMBEDDED-LIBRARIES.md`: the embedded-library guide.
- `C:\Projects\References\PORTING-TBC-TO-FOREVER.md`: measured client facts (the camera section:
  "A CVar that does nothing may be obeyed and then overruled").
- `C:\Projects\References\forever-api-1.60.1.70205.md`: the API dump.
- `C:\Projects\AltStable` (`docs/forever-api-notes.md`, CVars section) and
  `C:\Projects\PortalRoulette\docs\FOREVER-PROBE.md`: where the camera facts were measured.

## Conventions

- **Right-size for a single maintainer.** Simplest thing that works; no speculative config.
- **Measured beats reasoned.** If a claim about the client can be checked in game, check it
  (`/lsprobe`), and record it in `docs/DESIGN.md` as MEASURED with the build.
- Keep the `lib._test` seam for test-only internals; don't promote internals to globals.
- Consumers are separate repos; change them only on their own branches.
