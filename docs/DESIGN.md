# LibShowcase-1.0: design

The "showcase" presentation (Narcissus-style) as an embedded library: while a window is open, the
camera swings round to the character's front, zooms in, pushes the character to one side
(`test_cameraOverShoulder`), optionally orbits slowly, and the game UI is hidden Alt+Z style with
the window lifted above it. Everything is put back on close, combat, logout, a loading screen, and
after a crash (at the next login).

Source: AltStable's `AltStableCameraPresentation` (`SheetUI.lua:196-911` @ `5297196`), behaviour
kept and proven call for call by `tests/test_parity.lua` against a frozen copy
(`tests/fixtures/altstable_camera.lua`). PortalRoulette's `Camera/CameraMode.lua` extras are
opt-in options.

## API

```lua
local SC = LibStub("LibShowcase-1.0"):New(opts)   -- colon; a dot call errors
```

| Instance method (colon) | Does |
|---|---|
| `SC:Enter(anchor?)` | Start the presentation. `anchor` is the consumer's window, lifted above the hidden UI. Returns `true`, or `false, "combat" \| "unsupported" \| "busy"`. Re-entering during the exit animation finishes the exit and starts afresh. |
| `SC:Exit(reason?)` | UI back at once, view snapped back, the rest restored when `exitDuration` has passed. |
| `SC:ForceRestore(reason?)` | Everything back now. |
| `SC:IsActive()` / `SC:IsOwner()` | This instance's presentation is running / holds the lease. |
| `SC:Acquire()` / `SC:Release()` | Hold the lease without a camera (a camera-OFF consumer); `Release` restores everything first. |
| `SC:HideGameUI(anchor?)` / `SC:RestoreGameUI()` | `SetUIVisibility(false/true)`, lifting `anchor` and GameTooltip. Restoring drops every lift. |
| `SC:IsGameUIHidden()` | Whether the library has the UI hidden (shared truth, any owner). |
| `SC:Lift(frame, strata?)` / `SC:Drop(frame)` / `SC:IsLifted(frame)` | Take a frame out from under UIParent (scale compensated, idempotent) and put it back. |
| `SC:LiftPopup(dialog)` / `SC:DropPopup(dialog)` | A StaticPopup over a DIALOG window or a hidden UI. Returns the dialog. |

Library functions (dot): `lib.SuppressExperimentalCVarPopup()` (returns a count),
`lib.ShoulderOffsetFor(raceFileOrID, zoom, mounted?)`. Public tables, filled in place:
`lib.CENTRING_CVARS`, `lib.SHOULDER_FACTORS`, `lib.MOUNTED_SHOULDER_FACTORS`, `lib.RACE_IDS`.

### Options

Validated in `New` (unknown key or wrong type errors); kept in `SC.opts`, the instance's own table,
which `Enter` reads (and clamps, to AltStable's ranges) each time.

| Option | Default | |
|---|---|---|
| `owner` | required | the addon's name |
| `db` | nil | a table, or a function returning one (a SavedVariables table is replaced at ADDON_LOADED): crash self-heal |
| `onForcedExit(reason)` | nil | `"ui-shown"` (Escape/Alt+Z), `"combat"`, `"logout"`, `"loading"` |
| `debug` | nil | `true` (chat) or a function(msg) |
| `zoom`, `mountedZoom` | 2.2, 8.0 | 1.2-18 |
| `shoulderRef` | nil (= zoom) | the zoom the shoulder formula uses (AltStable: 6.2) |
| `shoulderMult` | 1.0 | |
| `mountedShoulder` | nil (= `mountedZoom * 1.2495 - 4`) | 0-12 (AltStable: 8.0) |
| `forceMounted` | false | |
| `yawDegrees`, `yawOffset` | 430, -0.22 | the entry swing; the sign of `yawOffset` is its direction |
| `enterDuration`, `exitDuration` | 1.5, 0.45 | 0.35-1.5, 0.25-1.2 |
| `orbit`, `orbitSpeed` | true, 0.005 | |
| `savedViewSlot` | 5 | 2-5, the player's own view |
| `presentationViewSlot` | 4 | castAware's settled view; ignored when equal to `savedViewSlot` |
| `hideUI`, `anchorStrata` | true, "DIALOG" | |
| `salute` | false | `DoEmote("SALUTE")` once settled, out of combat |
| `castAware` | false | PortalRoulette: a player cast returns to the settled view and holds still; its end resumes the orbit |
| `dynamicPitch` | false | `test_cameraDynamicPitch` = 1 (see Open measurements) |
| `pitchLimit` | nil | `ConsoleExec("pitchlimit N")`, `pitchlimit 88` on restore |
| `viewBlendStyle` | nil | `cameraViewBlendStyle` |

## One owner: the lease

The camera, the CVars and the UI's visibility are global, so `lib.state` is one table with one
owner.

- **Every mutation needs the lease**: hiding the UI, lifting a frame or popup, the camera,
  GameTooltip. Another instance's calls are refused (`false`, `"busy"` where there is a reason)
  and make no call at all.
- **Implicit**: `Enter`, `HideGameUI`, `Lift` and `LiftPopup` take the lease when it is free and
  give it back when nothing is left to restore. **Explicit**: `Acquire` holds it until `Release`.
- **Held until deferred cleanup finishes**: the exit animation, a protected frame waiting for
  combat to end.

## Guarantees

- **Combat.** `PLAYER_REGEN_DISABLED` runs before the lockdown (MEASURED 70205: `InCombatLockdown()`
  is false inside its handlers), so the library restores everything there, synchronously, then
  calls `onForcedExit("combat")`. A restore that lands inside a lockdown anyway (Escape mid-fight)
  restores the UI and the camera at once; a **protected** lifted frame keeps its record (parent,
  scale, strata, level; points recorded but not re-applied, so a drag made while lifted survives)
  and is put back at `PLAYER_REGEN_ENABLED`, the record cleared only after the reparent succeeded.
  The library never hides a protected frame; `onForcedExit` lets the consumer close its window.
  Enter refuses in combat, and so does lifting a protected frame.
- **Escape/Alt+Z** with the UI hidden: a `hooksecurefunc("SetUIVisibility")` hook calls
  `onForcedExit("ui-shown")`; if the consumer does not exit, the library does.
- **Logout, loading screens:** `PLAYER_LOGOUT` and `PLAYER_ENTERING_WORLD` restore everything.
- **Popups:** a lifted StaticPopup is put back by an `OnHide` hook (accept, cancel and Escape all
  hide it), by `DropPopup`, and by every restore, so a pooled dialog never stays detached. Drops
  are re-entrant (putting a frame back under a hidden UIParent fires its OnHide mid-drop).
- **Crash self-heal:** `Enter` writes the capture (view slot, zoom, every CVar it changes, the
  pitch limit, the zoom cap) into `db.LibShowcaseCapture`; a restore clears it; a capture still
  there at `PLAYER_LOGIN` (or at `New`, after login) is restored. MEASURED 70205:
  `CameraKeepCharacterCentered` keeps a changed value across a `/reload`, so this matters.
- **A CVar the client lacks is never created**, on the way in or out.
- **The experimental-CVar popup** is suppressed before each `test_*` write with
  `GameEvent.UnregisterInternalEvent` (MEASURED 70205: callable, no ADDON_ACTION_BLOCKED, no popup)
  and given back one frame after the restore with
  `GameEvent.RegisterInternalEvent(event, function(...) GameEvent.HandleExperimentalCVarConfirmationNeeded(...) end)`.
  AltStable's frame walk (`GetFramesRegisteredForEvent`, varargs) is only the fallback when
  `GameEvent` is absent; that path does not re-register (as in AltStable).
- **The OnUpdate runner hangs from WorldFrame**: `SetUIVisibility(false)` hides UIParent's
  children, and a hidden frame's OnUpdate stops.

## Upgrades

Several addons embed copies and the newest one loaded wins (`EMBEDDED-LIBRARIES.md` §5):
methods in `lib.methods` (a plain table, the instances' `__index`) dispatch to `lib.impl` at call
time, as do the hook, the popup hooks, the scripts and timer callbacks; every table keeps its
identity; frames, events and the hook are created once; a newer copy fills only missing option
keys. `lib.ready = MINOR` is the last line. `tests/test_upgrade.lua` proves it with a synthetic
newer copy loaded mid-presentation; `tests/mutate.lua` breaks each rule (56 mutations, all red).

## Deliberate differences from AltStable's block

- One owner, enforced (AltStable had a single caller).
- Every restore drops **every** lifted frame (AltStable put back the sheet and GameTooltip; popups
  and its menu put themselves back).
- A drop restores the frame level it recorded, and puts the frame back under its recorded parent
  (AltStable: always UIParent).
- Popup suppression through `GameEvent`, re-registered afterwards.
- Events and the hook stay active whenever the lease is held, not only while the camera runs.
- Combat, logout and zoning also call `onForcedExit`.
- The `UnitBuff` mount-icon scan is gone: `UnitBuff` is absent from the 70205 API dump, so it
  never ran on Forever.

## Open measurements (`Tools/LibShowcaseProbe`, `/lsprobe`)

| Question | Command |
|---|---|
| Does `test_cameraDynamicPitch` do anything with centring cleared? (69913: inert, not re-tested) | `/lsprobe pitch` |
| Is Narcissus's `CameraZoomIn(0)` nudge needed for the offset to apply at once? | `/lsprobe nudge 0`, `/lsprobe nudge 1` |
| `SetUIVisibility` inside a real lockdown (waits for `InCombatLockdown()` to turn true) | `/lsprobe combat` |
| Is a lifted StaticPopup visible over a hidden UI, and put back on accept/cancel? | `/lsprobe popup` |
| The whole presentation; does the experimental popup come back after it? | `/lsprobe show`, then `/lsprobe testcvar` |
