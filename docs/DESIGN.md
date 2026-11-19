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
| `SC:Lift(frame, strata?)` / `SC:Drop(frame)` / `SC:IsLifted(frame)` | Take one of the consumer's **own** frames out from under UIParent (scale compensated, idempotent) and put it back. Never a Blizzard frame (a StaticPopup above all: see Blizzard dialogs). The library itself lifts GameTooltip (inherited from AltStable; measured not to taint it: Guarantees). |
| `SC:LiftPopup(dialog)` | "Reveal for a dialog": while this instance holds the lease with the UI hidden, brings the game UI back as a dialog appearing does (Guarantees). Returns the dialog **untouched**; does nothing otherwise. |
| `SC:DropPopup(dialog)` | A no-op, kept for API stability. |

Library functions (dot): `lib.SuppressExperimentalCVarPopup()` (returns a count),
`lib.ShoulderOffsetFor(raceFileOrID, zoom, mounted?)`. Public tables, filled in place:
`lib.CENTRING_CVARS`, `lib.SHOULDER_FACTORS`, `lib.MOUNTED_SHOULDER_FACTORS`, `lib.RACE_IDS`,
`lib.WORLD_NAME_CVARS` (MINOR 4). The db keys: `lib.DB_KEY` (`"LibShowcaseCapture"`) and
`lib.NAMES_DB_KEY` (`"LibShowcaseNames"`, MINOR 4).

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
| `orbit`, `orbitSpeed` | true, 0.005 | The orbit's `MoveView*Start` speed at the default `cameraYawMoveSpeed` (180). Since MINOR 7 (#39) it is scaled by `180 / cameraYawMoveSpeed`, as the entry turn is, so the orbit looks the same whatever the player's camera turn speed |
| `savedViewSlot` | 5 | 2-5, the player's own view |
| `presentationViewSlot` | 4 | castAware's settled view; ignored when equal to `savedViewSlot` |
| `hideUI`, `anchorStrata` | true, "DIALOG" | |
| `salute` | false | `DoEmote("SALUTE")` once settled, out of combat |
| `castAware` | false | PortalRoulette: a player cast returns to the settled view and holds still; its end resumes the orbit |
| `dynamicPitch` | false | `test_cameraDynamicPitch` = 1. MEASURED 70959 (`/fp steps ls pitch`, 2026-11-19, centring cleared): the write raises the camera angle at once (the character lower on screen, more above it in view), the angle follows the zoom, nothing follows the movement, and the view comes back on restore. Clearing centring alone moved nothing. 69913 had read it as inert |
| `pitchLimit` | nil | `ConsoleExec("pitchlimit N")`, `pitchlimit 88` on restore |
| `viewBlendStyle` | nil | `cameraViewBlendStyle` |
| `hideWorldNames` | false | MINOR 4: world name text off while the showcase is up (Guarantees, World names) |

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
  restores the camera at once; a **protected** lifted frame keeps its record (parent,
  scale, strata, level; points recorded but not re-applied, so a drag made while lifted survives)
  and is put back at `PLAYER_REGEN_ENABLED`, the record cleared only after the reparent succeeded.
  The library never hides a protected frame; `onForcedExit` lets the consumer close its window.
  Enter refuses in combat, and so does lifting a protected frame.
  MEASURED 70959 (`/fp steps ls combat`, 2026-11-19): once `InCombatLockdown()` is true,
  `SetUIVisibility(false)` and `(true)` from addon code are **blocked** (`ADDON_ACTION_BLOCKED`, the
  `pcall` returns true, `UIParent` doesn't change). The player's own Alt+Z or Escape still works.
  So the library never calls it there (MINOR 5, #42): `HideUI` refuses in combat, and a show due
  inside a lockdown (a restore, a release, a dialog's reveal) is **owed**: the UI stays marked
  hidden, the lease is held and the lifts stay up (a window put back under the still-hidden UI
  would vanish), and `PLAYER_REGEN_ENABLED` shows the UI, drops the lifts and gives the lease back.
  A reveal owed that way calls `onGameUIShown(reason)` then, when the UI is really back, not
  before. The player's own Escape or Alt+Z in a lockdown does show the UI: the hook then only
  follows it (no second call), and a `SetUIVisibility(true)` hook run that changed nothing (a
  blocked call, `UIParent` still hidden) is not read as Escape. Getting the UI hidden into a
  lockdown at all is #21.
- **A drop is re-entrant.** Putting a frame back under a hidden `UIParent` fires its `OnHide`
  during the `SetParent` call, which may drop it again, so a record leaves the list before
  anything moves. Reparenting also sets the frame level (the new parent's + 1, 0 with no
  parent), so a drop puts the recorded level back after the parent. MEASURED 70959 by
  WowTestKit's probe (`/fp steps tk reparent`, WowTestKit #99): `OnShow` / `OnHide` fire on a
  visibility change only, children first, under an Alt+Z-hidden `UIParent` too; the level rule
  held raised and lowered, children one above.
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
  `START_LOOT_ROLL` (all in the 70205 dump), and since MINOR 6 (#40) the timers drawn under
  UIParent: `START_PLAYER_COUNTDOWN` (a group's pull countdown) and `START_TIMER` (a battleground
  or arena start timer), both in the 70959 dump with their time in seconds. They reveal as
  `"dialog"` too, like every prompt. Each stays **open** until its end event
  (`READY_CHECK_FINISHED`, `LFG_PROPOSAL_DONE`/`_FAILED`/`_SUCCEEDED`, `LFG_ROLE_CHECK_HIDE`/
  `_DECLINED`, `PVP_ROLE_POPUP_HIDE`, `CANCEL_LOOT_ROLL` by rollID, `CANCEL_ALL_LOOT_ROLLS`,
  `CANCEL_PLAYER_COUNTDOWN`, `STOP_TIMER_OF_TYPE` by timer type), its own time limit (the ready
  check's, the roll's, the countdown's, the timer's), or 60 s (the role poll has no end event). A roll
  the player answers ends no earlier than its time limit, so the UI may stay up a little longer.
  **A StaticPopup already up, or a prompt still open,** when the UI would be hidden keeps it up:
  its Show already happened, so nothing would bring it back (`HideGameUI` returns
  `false, "dialog"`; `Enter` presents with the UI up). That covers a prompt started before `Enter`,
  and a `HideGameUI` right after a prompt revealed the UI. For a prompt that started **before the
  first copy of the library loaded** (a load-on-demand consumer: no start event seen), the client
  is asked too, read-only: `GetReadyCheckStatus("player") == "waiting"` with
  `GetReadyCheckTimeLeft() > 0`, `GetLFGProposal()`, `GetLFGRoleUpdate()`, and
  `GetLootRollTimeLeft(id) > 0` for each of `GetActiveLootRollIDs()`. These are in the 70205 dump by
  name only; each call is `pcall`ed, and an unexpected answer counts as "not open". MEASURED 70959
  (`/fp steps ls prompts`, 2026-11-19, runs #460, #415 to #417, #420): `GetReadyCheckStatus("player")` is
  `"waiting"` until the player answers, then `"ready"` while the check runs on for the others (the
  one who started it is `"ready"` from the start), then nil; `GetReadyCheckTimeLeft()` counts down
  in seconds, then 0. So testing `"waiting"` (not the time left) is right: an answered player has
  nothing to answer. With nothing pending `GetLFGProposal()` returns nothing, `GetLFGRoleUpdate()`
  returns `false, 0, 0, nil, nil, false` and `GetActiveLootRollIDs()` an empty table. With a group
  loot roll up (run #420), `GetActiveLootRollIDs()` is the list of roll IDs (`{1=1}`) and
  `GetLootRollTimeLeft(id)` the time left in **milliseconds** (52237), as `START_LOOT_ROLL`'s roll
  time is; empty again once rolled. Retail's shapes. Forever has **no automated dungeon finder** (the owner), so `GetLFGProposal`,
  `GetLFGRoleUpdate` and the `LFG_PROPOSAL_*` / `LFG_ROLE_CHECK_*` events never report anything
  there; they stay, harmless. No getter sees the role poll (`ROLE_POLL_BEGIN`; run #415), the PvP
  role popup, or the role prompt that comes with a dungeon invite (run #417; it is not a
  `StaticPopup_Show` dialog, but `StaticPopupSpecial_Show(LFGInvitePopup)`, run #419): the library
  knows them only by their events or dialog hooks. MEASURED 70959 (`/fp steps ls invite`, run #421):
  that popup while presenting gives `onGameUIShown("dialog")`, the UI back, the camera still
  orbiting and the lease held; accepting and Logout work, no blocked action. (In run #419 a
  presentation of AltStable's ended on it: that is AltStable's own handling, not the library's.)
  MEASURED 70205: a real ready check while presenting brought the UI back
  (`onGameUIShown("dialog")`, presentation active, lease held) with no `StaticPopup_Show`:
  through `READY_CHECK`.
  MEASURED 70205 (`/lsprobe invite`): a real party invite while presenting brought the UI back
  (`onGameUIShown("dialog")`, presentation active, lease held), the `PARTY_INVITE` dialog's
  `which` read secure (`issecurevariable`), accepting it worked, and the later `QUIT` dialog was
  secure and quit the game.
- **GameTooltip and the chat edit box** (both touched by `HideUI`, as AltStable did: GameTooltip
  lifted, an open edit box closed with `ChatEdit_DeactivateChat`) come out untainted. MEASURED
  70205 (`/lsprobe taint` before and after three presentations, one opened mid-typing): every
  GameTooltip field secure; `ACTIVE_CHAT_EDIT_BOX` and `LAST_ACTIVE_CHAT_EDIT_BOX` secure; no
  edit-box field newly tainted. (`ChatFrame1EditBox` always reads shown, so the close ran each
  time. Its `autoCompleteParams` read tainted by the probe already in the baseline, before any
  presentation: typing an addon's slash command does that.) `issecurevariable` sees Lua fields,
  not the client's internal state.
- **Consumers must never call `StaticPopup_Show` for their own prompts: use their own frames.**
  `SC:Lift` is for the consumer's own frames, never a Blizzard one.
- **Crash self-heal:** `Enter` writes the capture (view slot, zoom, every CVar it changes, the
  pitch limit, the zoom cap) into `db.LibShowcaseCapture`; a restore clears it; a capture still
  there at `PLAYER_LOGIN` (or at `New`, after login, or at that instance's next `Enter`, before
  it captures) is restored. Never while another instance holds the lease (camera-OFF, deferred
  cleanup) or presents: the capture is kept, and that instance's next `Enter` heals it. MEASURED 70205: `CameraKeepCharacterCentered` keeps a changed value
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
- **World names (`hideWorldNames`, MINOR 4, opt-in; off, nothing changes).** Player, pet/minion and
  NPC names drawn in the world stay up with the game UI hidden; an opted-in owner's showcase sets
  the "show name" CVars of `lib.WORLD_NAME_CVARS` to `"0"`. Nameplates are a separate feature and
  untouched. The list is FrameXML 70338's Names settings (`UnitNameOwn`,
  `UnitNameFriendlyPlayerName`, `UnitNameFriendlyMinionName`, `UnitNameEnemyPlayerName`,
  `UnitNameEnemyMinionName`, `UnitNameNPC`, `UnitNameFriendlySpecialNPCName`, `UnitNameHostleNPC`
  (the client's spelling), `UnitNameInteractiveNPC`, `UnitNameNonCombatCreatureName`) and
  Blizzard_Commentator's pet/guardian/totem flags. MEASURED 70338 (`/lsprobe names`, a crowded
  place): all 16 exist; with the 11 that were on set to `"0"` (own name and the special, hostile,
  interactive and non-combat NPC flags already off), **no name text was left in the world**:
  players, guild/title lines, pets/minions and NPCs (through `UnitNameNPC`) all gone; Escape
  restored all 21 logged values (the list plus `UnitSurnameOwn`, `UnitNamePlayerGuild`,
  `UnitNamePlayerPVPTitle`, `UnitNameGuildTitle`, `UnitNameForceHideMinus`, never written) exactly,
  and a `/reload` kept them (checked again after the camera-OFF run; a full client restart was not
  run separately: a `/reload` also goes through `PLAYER_LOGOUT`). Camera OFF (`/lsprobe names ui`: `Acquire` + `HideGameUI`) the same:
  names gone while the UI was hidden, all back on closing. Not separated: which entries are strictly needed (the flags already off
  were not exercised; the whole list is kept, as writing an entry that exists and is on is harmless).
  - **When:** while the owner's presentation runs (`Enter` to the end of the exit animation; with
    `hideUI = false` too), and camera OFF while its `HideGameUI` has the UI hidden. The option is
    read with the others at `Enter` (the presentation keeps that value), and live for `HideGameUI`.
  - **Ends with the showcase:** whatever ends it puts the names back: `Exit` (at the end of the
    animation, with the other CVars), Escape/Alt+Z, `ForceRestore`, `Release`, `RestoreGameUI`,
    combat (`PLAYER_REGEN_DISABLED`, still unlocked), `PLAYER_LOGOUT` (so `/reload` and quitting),
    `PLAYER_ENTERING_WORLD`. All of them pass through the lease's release check, which restores
    the names once nothing wants them hidden.
  - **A dialog revealing the UI** keeps a presentation's names off (the presentation goes on);
    camera OFF the hidden UI was the showcase, so its names come back with it, and a later
    `HideGameUI` takes a fresh capture.
  - **The capture:** only CVars the client has (`GetCVar` not nil: none is created) and that are not
    already `"0"` (one already off is never written, so it keeps its value). Read whole before the
    first write, written to `db.LibShowcaseNames` first, and taken **once**: a second `Enter`, or
    `HideGameUI` then `Enter`, keeps the first; re-entering during the exit animation restores, then
    captures afresh, so the zeroes are never taken for the player's.
  - **The release check only restores:** it never starts a capture, so an unrelated `Drop` or failed
    `Lift` after the consumer changed `opts.hideWorldNames` cannot hide names mid-session.
  - **The player's changes meanwhile:** a name turned on stays on (one that was off is not
    captured; one that was on goes back on). One turned off reads as the library's `"0"` and goes
    back to its value from before. The CVars are booleans, so that is every case.
  - **Combat:** `Enter` and `HideGameUI` refuse in combat, and combat restores at
    `PLAYER_REGEN_DISABLED` (unlocked), so the library's own paths never write the CVars in a
    lockdown. Not guaranteed against a consumer that calls `Enter` from its own
    `PLAYER_REGEN_DISABLED` handler after the library's (`InCombatLockdown()` is still false
    there): the presentation then outlives the restore, camera and names alike (a gap that predates
    this option). MEASURED 70338 (`/lsprobe names list`): every `WORLD_NAME_CVARS` entry exists, none
    `isSecure`, `isLockedFromUser` or `isReadOnly`.
  - **The lease:** written only by the owner, inside its lease; a refused `Enter`/`HideGameUI`
    writes nothing, and another instance's stale names capture is not healed under someone else's
    lease.
  - **Crash self-heal:** the names capture is its own key, `db.LibShowcaseNames`, so
    `db.LibShowcaseCapture` keeps r3's shape (an r3 copy healing it finds what it knows; an r3 copy
    leaves the names key alone). It heals with the camera one (`PLAYER_LOGIN`, `New` after login,
    the instance's next `Enter`) and before a `HideGameUI` capture; not while this instance has the
    names hidden (that capture is live). A heal writes only `WORLD_NAME_CVARS` entries the client
    has, with a string or number value: a hand-edited capture cannot set another CVar. The restore
    clears the capture from the db table it was written to (kept in `st.names`), even if the
    consumer's db function no longer answers. **The same limit as the camera capture:**
    `PLAYER_LOGOUT` restores and clears it before SavedVariables are written, and a crash writes
    none, so after a real crash there is nothing to heal. If the client keeps the names' `"0"`
    across a crash (Config.wtf, or server-stored CVars: not measured), the player turns them back on
    in the settings.
- **The OnUpdate runner hangs from WorldFrame**: `SetUIVisibility(false)` hides UIParent's
  children, and a hidden frame's OnUpdate stops.

## Upgrades

Several addons embed copies and the newest one loaded wins (`EMBEDDED-LIBRARIES.md` §5):
methods in `lib.methods` (a plain table, the instances' `__index`) dispatch to `lib.impl` at call
time, as do the `SetUIVisibility` and StaticPopup hooks, the scripts and timer callbacks; every table keeps its
identity; frames, events and the hook are created once; a newer copy fills only missing option
keys. `lib.ready = MINOR` is the last line. `tests/test_upgrade.lua` proves it with a synthetic
newer copy loaded mid-presentation, and with each released copy, whole (`tests/fixtures/LibShowcase-r3/`,
`-r4/`: its XML, LibShowcase.lua and LibStub, byte for byte the tag's) under a newer copy, in both
orders (r4's instance with its world names hidden: the newer code puts them back); `tests/mutate.lua` breaks each rule (110 mutations, all red).
An r3 instance upgraded in place gets `hideWorldNames = false` (`tests/test_names.lua`).

## Deliberate differences from AltStable's block

- One owner, enforced (AltStable had a single caller).
- The orbit is scaled by the player's `cameraYawMoveSpeed` (#39); AltStable scaled only the entry
  turn, so its orbit sped up or slowed down with the setting. The same at the default 180, where
  `tests/test_parity.lua` runs.
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

## Open measurements (`Tools/LibShowcaseProbe`, `/fp ls`)

The probe is a ForeverProbe module (#26): `pwsh Tools/deploy-probe.ps1` installs the host and the
probe with this checkout embedded, `/reload`, then `/fp steps ls <name>` runs a procedure (a panel
of buttons that saves every outcome) and `/fp ls <command>` a one-off. Its lines go to the `/fp`
console and `LibShowcaseProbeDB.log`; each procedure's record is in `ForeverProbe.lua`
(`steps.records["LibShowcaseProbe/<name>"]`). The MEASURED notes above name the commands as they
were then: `/lsprobe <command>` is now `/fp ls <command>`.

None is open.

Closed on 70959 (2026-11-19, issue #3): dynamic pitch (the `dynamicPitch` option row), the prompt
getters and the dungeon-invite role prompt, `SetUIVisibility` in a lockdown (above), and the
`CameraZoomIn(0)` nudge: `/fp steps ls nudge` saw the shoulder offset apply at once with and
without it, so the library doesn't need it (and never did it).

Every `StaticPopup_Show` is logged by the probe with whether the dialog's `which` was written
securely (`issecurevariable`), every blocked action is copied into its log, and `/fp ls focus`
lists the tainted fields of the frame under the mouse. Re-run `/fp steps ls invite`,
`/fp steps ls rereg`, `/fp steps ls names` and `/fp ls taint` when the build changes.
