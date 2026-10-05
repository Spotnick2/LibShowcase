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
| `SC:HideGameUI(anchor?)` / `SC:RestoreGameUI()` | `SetUIVisibility(false/true)`, lifting `anchor` and GameTooltip. Restoring drops every lift. `HideGameUI` returns `false, "combat" \| "unsupported" \| "busy" \| "dialog"` (a Blizzard dialog is up: the UI stays up). With the UI already hidden, it only lifts `anchor`. `Enter` hides the UI the same way, and presents with the UI up when it can't (check `IsGameUIHidden()`). |
| `SC:IsGameUIHidden()` | Whether the library has the UI hidden (shared truth, any owner). |
| `SC:Lift(frame, strata?)` / `SC:Drop(frame)` / `SC:IsLifted(frame)` | Take one of the consumer's **own** frames out from under UIParent (scale compensated, idempotent) and put it back. Never a Blizzard frame (a StaticPopup above all: see Blizzard dialogs). The library itself lifts GameTooltip, inherited from AltStable; whether that taints is an open measurement. |
| `SC:LiftPopup(dialog)` | "Reveal for a dialog": while this instance holds the lease with the UI hidden, brings the game UI back as a dialog appearing does (Guarantees). Returns the dialog **untouched**; does nothing otherwise. |
| `SC:DropPopup(dialog)` | A no-op, kept for API stability. |

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
| `onGameUIShown(reason)` | nil | `"dialog"`: the library brought the game UI back for a Blizzard dialog; the presentation, the lease and the window stay (a consumer that tracks "UI hidden" updates it here) |
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

- **Every mutation needs the lease**: hiding the UI, lifting a frame, the camera,
  GameTooltip. Another instance's calls are refused (`false`, `"busy"` where there is a reason)
  and make no call at all.
- **Implicit**: `Enter`, `HideGameUI` and `Lift` take the lease when it is free and
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
  Combat, logout and loading screens leave an **idle** `Acquire` lease alone (nothing hidden,
  lifted or presenting): no call, no `onForcedExit`.
- **Blizzard dialogs are never touched.** The library never calls `StaticPopup_Show` and never
  calls `SetParent`, `SetFrameStrata`, `HookScript` (or anything else) on a StaticPopup or
  StaticPopupSpecial frame. MEASURED 70205: the probe's old `/lsprobe popup` called `StaticPopup_Show("LSPROBE_TEST")` from addon code, then `SC:LiftPopup(dialog)` (`SetParent(nil)`, `SetFrameStrata`, `HookScript("OnHide")` on the dialog frame); the player's later Quit dialog failed with `[ADDON_ACTION_FORBIDDEN] AddOn 'LibShowcaseProbe' tried to call the protected function 'ForceQuit()'` (`StaticPopup_OnClick` -> `OnAccept`). StaticPopup frames are a pool shared with Blizzard's secure code: touching one taints it, and protected buttons (accept a guild invite, Quit, Logout) then fail.
  Instead, `hooksecurefunc("StaticPopup_Show")` and `hooksecurefunc("StaticPopupSpecial_Show")`
  (post-hooks: Blizzard's call stays secure; installed once, at load or at `PLAYER_LOGIN`)
  notice a dialog appearing while a lease holds the UI hidden (for `StaticPopup_Show`, only when
  `StaticPopup_ForEachShownDialog` reports one: a refused show returns nil). The library then
  brings the game UI back through its own restore path (so the `SetUIVisibility` hook does not
  read it as Escape/Alt+Z), drops its lifts (the window goes back under the now-shown UIParent,
  still open), keeps the camera presentation running and the lease, and calls
  `onGameUIShown("dialog")`. The dialog shows where Blizzard put it. A dialog with the UI up, under
  the player's own Alt+Z, or with no lease changes nothing. (A lease taken implicitly by
  `HideGameUI` alone is given back, as always once nothing is left to restore.)
  **Prompts that are not StaticPopups** (each its own frame under UIParent) do the same through
  their events, which the library listens to (touching nothing): `READY_CHECK`,
  `LFG_PROPOSAL_SHOW`, `LFG_ROLE_CHECK_SHOW`, `ROLE_POLL_BEGIN`, `PVP_ROLE_POPUP_SHOW`,
  `START_LOOT_ROLL` (all in the 70205 dump). **A StaticPopup already up** when the UI would be
  hidden keeps it up: its Show already happened, so nothing would bring it back (`HideGameUI`
  returns `false, "dialog"`; `Enter` presents with the UI up).
  MEASURED 70205 (`/lsprobe invite`): a real party invite while presenting brought the UI back
  (`onGameUIShown("dialog")`, presentation active, lease held), the `PARTY_INVITE` dialog's
  `which` read secure (`issecurevariable`), accepting it worked, and the later `QUIT` dialog was
  secure and quit the game.
- **Consumers must never call `StaticPopup_Show` for their own prompts: use their own frames.**
  `SC:Lift` is for the consumer's own frames, never a Blizzard one.
- **Crash self-heal:** `Enter` writes the capture (view slot, zoom, every CVar it changes, the
  pitch limit, the zoom cap) into `db.LibShowcaseCapture`; a restore clears it; a capture still
  there at `PLAYER_LOGIN` (or at `New`, after login, or at that instance's next `Enter`, before
  it captures) is restored. MEASURED 70205: `CameraKeepCharacterCentered` keeps a changed value
  across a `/reload`. **Limit:** the client writes SavedVariables only at a logout or a
  `/reload`, and both fire `PLAYER_LOGOUT`, whose restore clears the capture first. So after a
  real crash the file on disk holds no capture and nothing is healed. (Whether the changed CVars
  themselves survive a crash, given that Config.wtf is also written on exit, is not measured.)
  The heal covers a `PLAYER_LOGOUT` restore that failed, and costs nothing otherwise.
- **A CVar the client lacks is never created**, on the way in or out: the centring CVars,
  `test_cameraOverShoulder` (a cast reset included), `cameraDistanceMaxZoomFactor` and the extras
  are captured only when `GetCVar` returns a value, and only captured ones are written.
- **The experimental-CVar popup** is suppressed before each `test_*` write with
  `GameEvent.UnregisterInternalEvent` (MEASURED 70205: callable, no ADDON_ACTION_BLOCKED, no popup)
  and **never given back**: it stays off until the next `/reload`, so a later `test_*` write (the
  player's, another addon's) applies without the "experimental camera features" confirmation.
  That is the trade-off, and it is what AltStable's frame walk always did. The reason, MEASURED
  70205 (`/lsprobe rereg`): Blizzard's own registration shows the popup (`StaticPopup_Show
  "EXPERIMENTAL_CVAR_WARNING"`) with `issecurevariable(dialog, "which")` secure; after
  `UnregisterInternalEvent` + `RegisterInternalEvent` from addon code, the player's own
  `/console test_cameraOverShoulder` write brought it back **TAINTED by the registering addon**,
  with an addon closure (r2's way) and with `GameEvent.HandleExperimentalCVarConfirmationNeeded`
  passed itself alike. A tainted StaticPopup is what broke Quit (Blizzard dialogs, above).
  `lib.impl.UnsuppressPopup` stays as a no-op: an r2 copy's pending `C_Timer` callback calls it.
  AltStable's frame walk (`GetFramesRegisteredForEvent`, varargs) is only the fallback when
  `GameEvent` is absent.
- **The OnUpdate runner hangs from WorldFrame**: `SetUIVisibility(false)` hides UIParent's
  children, and a hidden frame's OnUpdate stops.

## Upgrades

Several addons embed copies and the newest one loaded wins (`EMBEDDED-LIBRARIES.md` §5):
methods in `lib.methods` (a plain table, the instances' `__index`) dispatch to `lib.impl` at call
time, as do the `SetUIVisibility` and StaticPopup hooks, the scripts and timer callbacks; every table keeps its
identity; frames, events and the hook are created once; a newer copy fills only missing option
keys. `lib.ready = MINOR` is the last line. `tests/test_upgrade.lua` proves it with a synthetic
newer copy loaded mid-presentation; `tests/mutate.lua` breaks each rule (75 mutations, all red).

## Deliberate differences from AltStable's block

- One owner, enforced (AltStable had a single caller).
- Every restore drops **every** lifted frame (AltStable put back the sheet and GameTooltip; its
  menu put itself back).
- Blizzard dialogs are never touched: AltStable lifted and raised its StaticPopups over the hidden
  UI, which taints the pool (Guarantees, Blizzard dialogs); the library brings the UI back instead.
  `tests/test_parity.lua` shows no dialog.
- A drop restores the frame level it recorded, and puts the frame back under its recorded parent
  (AltStable: always UIParent).
- Popup suppression through `GameEvent` (AltStable's frame walk did nothing on 70205); like
  AltStable, never given back (Guarantees).
- Events and the hook stay active whenever the lease is held, not only while the camera runs.
- A Blizzard dialog already up keeps the UI up; ready checks, LFG proposals, role checks and loot
  rolls bring it back (AltStable lifted only its StaticPopups).
- A CVar the client lacks is never created (AltStable wrote `test_cameraOverShoulder` and the zoom
  cap regardless; `tests/test_parity.lua` runs on a client that has them).
- Combat, logout and zoning also call `onForcedExit`.
- The `UnitBuff` mount-icon scan is gone: `UnitBuff` is absent from the 70205 API dump, so it
  never ran on Forever.

## Open measurements (`Tools/LibShowcaseProbe`, `/lsprobe`)

| Question | Command |
|---|---|
| Does `test_cameraDynamicPitch` do anything with centring cleared? (69913: inert, not re-tested) | `/lsprobe pitch` |
| Is Narcissus's `CameraZoomIn(0)` nudge needed for the offset to apply at once? | `/lsprobe nudge 0`, `/lsprobe nudge 1` |
| `SetUIVisibility` inside a real lockdown (waits for `InCombatLockdown()` to turn true) | `/lsprobe combat` |
| Does lifting GameTooltip (`SetParent(nil)`, `SetFrameStrata`, `SetScale`, then back) taint it? | `/lsprobe taint`, `/lsprobe show`, Escape, `/lsprobe taint` |
| Does closing an open chat edit box (`ChatEdit_DeactivateChat` from addon code) taint the edit box or `ACTIVE_CHAT_EDIT_BOX`? | `/lsprobe taint`, `/lsprobe show 5` (open chat and type meanwhile), Escape, `/lsprobe taint` |

Every `StaticPopup_Show` is logged by the probe with whether the dialog's `which` was written
securely (`issecurevariable`), and `/lsprobe focus` lists the tainted fields of the frame under the
mouse: re-run `/lsprobe invite` and `/lsprobe rereg` when the build changes.
