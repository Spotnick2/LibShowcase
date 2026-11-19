-- LibShowcaseProbe (Tools/LibShowcaseProbe), a ForeverProbe module: it loads
-- on the host with this checkout's library, every command runs without an
-- error, its lines go to its saved log and never to chat, and every
-- procedure walks end to end. Needs a ForeverProbe checkout ($FOREVERPROBE,
-- else ..\ForeverProbe); with FOREVERPROBE_OPTIONAL=1 it skips without one.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local root = foreverProbeRoot("test_probe")

-- What the host and the probe read beyond the shared stub (the host reads
-- every client API through rawget, so the rest may stay absent).
local errors, shots = {}, 0
local expectedErrors = 0      -- errors a scenario below raises on purpose
rawset(_G, "SlashCmdList", {})
rawset(_G, "GetBuildInfo", function() return "1.60.1", "70959", "Nov 1 2026", 16001 end)
rawset(_G, "geterrorhandler", function() return function(e) errors[#errors + 1] = tostring(e) end end)
rawset(_G, "Screenshot", function() shots = shots + 1 end)
-- Every field reads as written securely, but a dialog's `which` when the
-- test says it was written tainted.
local taintedBy
rawset(_G, "issecurevariable", function(t, k)
    if type(t) == "table" and k == "which" and taintedBy then return false, taintedBy end
    return true
end)

local FP = loadForeverProbe(root)
local ns = loadProbe()
local T = ns._test
local DB = LibShowcaseProbeDB
local SC = T.instance()
local S = FP.Steps
local function fp(msg) SlashCmdList.FOREVERPROBE(msg) end
local function logHas(text)
    for _, l in ipairs(DB.log) do if l:find(text, 1, true) then return true end end
    return false
end
local function logCount(text)
    local n = 0
    for _, l in ipairs(DB.log) do if l:find(text, 1, true) then n = n + 1 end end
    return n
end
-- The host shoots from its OnUpdate driver, then waits for SCREENSHOT_SUCCEEDED.
local function shoot()
    for _ = 1, 8 do WoW.tick(0.5) end
    WoW.fire("SCREENSHOT_SUCCEEDED")
end
local function record(name) return ForeverProbeDB.steps.records["LibShowcaseProbe/" .. name] end

check(type(DB) == "table" and type(DB.log) == "table", "the saved table is made at the probe's ADDON_LOADED")
eq(DB.loads, 1, "and counts loads")
check(logHas("loaded (1 loads), LibShowcase r" .. currentMinor()), "the load line names the running LibShowcase")
check(SC and SC.owner == "LibShowcaseProbe", "its instance is made at ADDON_LOADED")

------------------------------------------------------------------------------
-- The commands
------------------------------------------------------------------------------
fp("ls")
check(logHas("/fp ls <command>:") and logHas("  names - "), "/fp ls lists the commands")

fp("ls pitch")
eq(WoW.cvars.test_cameraDynamicPitch, "1", "pitch: dynamic pitch on")
eq(WoW.cvars.CameraKeepCharacterCentered, "0", "  centring cleared")
fp("ls pitch off")
eq(WoW.cvars.test_cameraDynamicPitch, "0", "pitch off: put back")
eq(WoW.cvars.CameraKeepCharacterCentered, "1", "  centring too")

fp("ls nudge 1")
check(hasCall("CameraZoomIn(0)"), "nudge 1: the CameraZoomIn(0) nudge")
eq(WoW.cvars.test_cameraOverShoulder, "1.5", "  after the offset")
fp("ls restore")
eq(WoW.cvars.test_cameraOverShoulder, "0", "restore puts the offset back")

fp("ls show")
local win = T.window()
check(win and win:IsShown() and SC:IsActive(), "show: the presentation on the probe window")
check(not UIParent:IsShown(), "  with the UI hidden")
fp("ls show")
check(not win:IsShown(), "show again closes it")
ticks(0.1, 20)
WoW.flushTimers()
check(not SC:IsActive() and UIParent:IsShown(), "  and the presentation ends, the UI back")
check(logHas("type: /console test_cameraOverShoulder"), "  then the /console line to type is logged")

fp("ls show 2")
check(not win:IsShown(), "show N waits")
WoW.advance(2)
check(win:IsShown(), "  and opens it after N seconds")
fp("ls show")
ticks(0.1, 20)
WoW.flushTimers()

fp("ls invite")
check(win:IsShown() and not UIParent:IsShown(), "invite: the presentation, the UI hidden")
local d = StaticPopup_Show("PARTY_INVITE")
check(UIParent:IsShown() and SC:IsActive(), "  a dialog brings the UI back, the presentation kept")
check(logHas("onGameUIShown dialog"), "  and the probe logs why")
check(logHas("StaticPopup_Show PARTY_INVITE"), "every StaticPopup_Show is logged")
local special = CreateFrame("Frame", "LFGInvitePopup", UIParent)
StaticPopupSpecial_Show(special)
check(logHas("StaticPopupSpecial_Show LFGInvitePopup"), "  and every StaticPopupSpecial_Show, by frame name")
WoW.closeDialog(special)
WoW.flushTimers()
check(logHas("[PARTY_INVITE] dialog pool which=PARTY_INVITE: written SECURELY"), "  and, a frame later, how its `which` was written")
WoW.closeDialog(d)
fp("ls show")
ticks(0.1, 20)
WoW.flushTimers()

taintedBy = "SomeAddon"
local d2 = StaticPopup_Show("CONFIRM_SUMMON")
rawset(_G, "StaticPopup1", d2)
fp("ls dialogs")
check(logHas("[now] dialog 1 which=CONFIRM_SUMMON: TAINTED by SomeAddon"), "dialogs: a tainted write names the addon")
WoW.flushTimers()
WoW.closeDialog(d2)
rawset(_G, "StaticPopup1", nil)
taintedBy = nil
fp("ls dialogs")
check(logHas("[now] no shown dialog found"), "  and says when none is shown")

-- UnitAffectingCombat (in the 70959 dump): what #21 asks, true once combat starts.
rawset(_G, "UnitAffectingCombat", function(unit) return unit == "player" and WoW.affecting == true end)
WoW.affecting = true
fp("ls combat")
check(logHas("== combat: armed"), "combat: armed")
WoW.enterCombat()
check(logHas("in the handler InCombatLockdown() = false, UnitAffectingCombat(\"player\") = true"),
      "  REGEN_DISABLED runs unlocked; the client's combat flag is logged there (#21)")
WoW.advance(0.05)
check(logHas("SetUIVisibility(false) in combat: pcall true"), "  once locked, the UI is hidden")
WoW.advance(0.5)
check(logHas("SetUIVisibility(true) in combat: pcall true"), "  and shown again")
eq(T.combat().state, "done", "  the check is done")
WoW.leaveCombat()

WoW.readyCheck = { status = "waiting", left = 30 }
WoW.lootRolls = { [7] = 25000 }
fp("ls prompts")
check(logHas('GetReadyCheckStatus("player") -> "waiting"'), "prompts: every getter's returns")
check(logHas("GetLootRollTimeLeft(7) -> 25000"), "  one per active roll")
check(logHas("GetActiveLootRollIDs() -> {1=7}"), "  the roll IDs shown as their contents (the roll's ID), not an address")
WoW.readyCheck, WoW.lootRolls = nil, {}

WoW.cvars.UnitNameOwn = "1"
fp("ls names")
check(win:IsShown() and SC:IsActive(), "names: the presentation")
check(logHas("[before] UnitNameOwn = 1"), "  the name CVars listed before")
eq(WoW.cvars.UnitNameOwn, "0", "  and hidden")
eq(SC.opts.hideWorldNames, false, "  the option off again once Enter has read it")
fp("ls names")
ticks(0.1, 20)
WoW.advance(1.5)
eq(WoW.cvars.UnitNameOwn, "1", "names again: put back")
check(logHas("after the restore: every value as before"), "  and checked against the list before")
fp("ls names ui")
check(SC:IsOwner() and SC:IsGameUIHidden(), "names ui: camera OFF, the UI hidden")
fp("ls names")
WoW.advance(1.5)
check(not SC:IsOwner(), "  again: released")
fp("ls names list")
check(logHas("[now] UnitNameOwn = 1"), "names list: the values only")

fp("ls testcvar")
check(logHas("== testcvar"), "testcvar")
fp("ls rereg closure")
eq(type(WoW.internal.EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED), "function", "rereg closure: a handler registered")
check(WoW.internal.EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED ~= GameEvent.HandleExperimentalCVarConfirmationNeeded, "  a closure")
fp("ls rereg direct")
check(WoW.internal.EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED == GameEvent.HandleExperimentalCVarConfirmationNeeded, "rereg direct: Blizzard's own")
fp("ls rereg none")
eq(WoW.internal.EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED, nil, "rereg none: left unregistered")
eq(WoW.cvars.test_cameraOverShoulder, "0", "  the CVar at 0, so the typed 0.5 changes it")
fp("ls restore")

fp("ls taint")
check(logHas("GameTooltip shown=true: "), "taint: GameTooltip's fields")
fp("ls focus")
WoW.advance(3)
check(logHas("nothing under the mouse"), "focus: 3 s later, the frame under the mouse")
fp("ls next")
check(logHas("type: /console test_cameraOverShoulder 0.1"), "next: the line to type")

WoW.fire("ADDON_ACTION_BLOCKED", "LibShowcaseProbe", "SomeProtected()")
check(logHas("ADDON_ACTION_BLOCKED: LibShowcaseProbe SomeProtected()"), "a blocked action lands in the module's log")

------------------------------------------------------------------------------
-- The procedures, end to end
------------------------------------------------------------------------------
fp("steps ls pitch")
local rec = record("pitch")
check(rec and rec.status == "active", "/fp steps ls pitch starts it")
S.Next(); shoot()
eq(shots, 1, "pitch 1: a screenshot of the view before")
S.Run(); shoot()
eq(WoW.cvars.CameraKeepCharacterCentered, "0", "pitch 2: centring cleared")
eq(WoW.cvars.test_cameraDynamicPitch, "0", "  dynamic pitch untouched")
eq(shots, 2, "  a screenshot after the write")
S.Answer(true)
S.Run(); shoot()
eq(WoW.cvars.test_cameraDynamicPitch, "1", "pitch 4: dynamic pitch 1")
eq(shots, 3, "  a screenshot after it")
S.Answer(false)
S.Answer(true)
shoot()
eq(WoW.cvars.test_cameraDynamicPitch, "0", "pitch 7: put back")
eq(WoW.cvars.CameraKeepCharacterCentered, "1", "  centring too")
eq(shots, 4, "  a screenshot of the view restored")
S.Answer(true)
eq(rec.results[3].status .. "," .. rec.results[5].status .. "," .. rec.results[6].status, "yes,no,yes", "  every answer saved")
shots = 0   -- the procedures below count their own
eq(rec.status, "done", "the pitch procedure finishes")

fp("steps ls nudge")
rec = record("nudge")
S.Run(); eq(WoW.cvars.test_cameraOverShoulder, "1.4", "nudge 1: no nudge")
S.Answer(true)
eq(WoW.cvars.test_cameraOverShoulder, "0", "nudge 3: put back")
S.Run(); check(hasCall("CameraZoomIn(0)"), "nudge 4: with the nudge")
S.Answer(false)
eq(rec.status, "done", "the nudge procedure finishes")
eq(rec.results[2].status, "yes", "  each answer saved")

fp("steps ls combat")
rec = record("combat")
S.Run()
S.Poll()
eq(rec.at, 2, "combat 2: waits for the checks")
WoW.enterCombat()
WoW.advance(0.05); WoW.advance(0.5)
S.Poll()
eq(rec.results[2].status, "done", "  done once both calls ran")
check(tostring(rec.results[2].detail):find("done", 1, true), "  with what they did")
check(tostring(rec.results[2].detail):find("UnitAffectingCombat in the handler true", 1, true), "  and the client's combat flag in the handler (#21)")
WoW.leaveCombat()
S.Answer(true)
eq(rec.status, "done", "the combat procedure finishes")

-- No lockdown within the poll (10 s): the wait ends, saved as a FAIL.
fp("steps ls combat")
rec = record("combat")
S.Run()
WoW.fire("PLAYER_REGEN_DISABLED")             -- combat starts, the lockdown never comes
WoW.advance(11)
S.Poll()
eq(rec.results[2].check, "FAIL", "combat 2: no lockdown is a FAIL, not a completed measurement")
check(tostring(rec.results[2].checkDetail):find("no lockdown", 1, true), "  saying why")
S.Answer(false)
eq(rec.status, "done", "  the procedure still finishes")

fp("steps ls prompts")
rec = record("prompts")
WoW.readyCheck = { status = "waiting", left = 20 }
S.Next(); S.Run()
check(tostring(rec.results[2].detail):find("waiting", 1, true), "prompts 2: the returns saved on the step")
WoW.readyCheck = nil
S.Next()
eq(rec.status, "done", "the prompts procedure finishes (the last read on arrival)")

-- Another addon's showcase holds the lease: Open must say the presentation
-- did not start, as a FAIL (run #419), not "true".
local other = LibStub("LibShowcase-1.0"):New({ owner = "AnotherAddon" })
check(other:Enter(), "another addon presents")
fp("steps ls invite")
rec = record("invite")
S.Run()
eq(rec.results[1].check, "FAIL", "invite 1: a refused Enter is a FAIL")
check(logHas("NOT ready: another showcase holds the presentation: close it, then press Back and Open again"),
      "  and says why, and the way back the panel offers")
other:ForceRestore()
ticks(0.1, 20)
WoW.flushTimers()
-- A prompt already up: Enter starts the camera but the UI stays visible, so
-- no invite could bring it back. Also a FAIL (Codex, PR #44).
WoW.readyCheck = { status = "waiting", left = 30 }
S.Back(); S.Run()
eq(rec.results[1].check, "FAIL", "invite 1: the UI kept up by a pending prompt is a FAIL")
check(logHas("a dialog or prompt kept the UI up: answer or close it"), "  and says why")
WoW.readyCheck = nil
win:Hide()
ticks(0.1, 20)
WoW.flushTimers()
S.Back(); S.Run()
eq(rec.results[1].check, "PASS", "invite 1: Back, then Open, with nothing in the way starts it")
check(win:IsShown() and not UIParent:IsShown(), "invite 1: presenting")
S.Poll()
eq(rec.at, 2, "invite 2: waits for the dialog")
local d3 = StaticPopup_Show("GUILD_INVITE")
WoW.flushTimers()
S.Poll()
eq(rec.at, 3, "  done once the dialog brought the UI back")
S.Answer(true)
shoot()
eq(shots, 1, "invite 3: a screenshot")
WoW.closeDialog(d3)
S.Answer(true)
local hints = logCount("type: /console test_cameraOverShoulder")
S.Run()
check(not win:IsShown(), "invite 5: closed")
S.Poll()
eq(rec.at, 6, "invite 6: waits while the exit animation runs")
ticks(0.1, 20)
WoW.flushTimers()
S.Poll()
check(tostring(rec.results[6].detail):find("the presentation ended", 1, true), "  and saves that it ended")
eq(logCount("type: /console test_cameraOverShoulder"), hints, "  no /console hint in the middle of the procedure")
S.Answer(true)
eq(rec.status, "done", "the invite procedure finishes")
eq(rec.results[8].check, "PASS", "  no blocked action since it started")

-- #32 changed only the names procedure's functions: its rev went to 2, so a
-- run started before is stopped at /reload rather than resumed.
eq((FP.procedures["LibShowcaseProbe/names"].identity:match("^(%d+):")), "2", "the names procedure is rev 2")

WoW.cvars.UnitNameOwn = "1"
-- A one-off names check left open: the procedure's Hide refuses (a logged
-- error, the step stays) rather than closing it, and Retry works once closed.
fp("ls names")
eq(WoW.cvars.UnitNameOwn, "0", "a one-off names check is open")
local errorsBefore = #errors
fp("steps ls names")
rec = record("names")
S.Next(); S.Run()
eq(rec.at, 2, "names 2: refused while a names check is open")
eq(rec.results[2].errors, 1, "  as an error on the step")
eq(#errors, errorsBefore + 1, "  sent to the error handler")
eq(WoW.cvars.UnitNameOwn, "0", "  the open check is left as it was")
expectedErrors = 1
fp("ls names")
ticks(0.1, 20)
WoW.advance(1.5)
eq(WoW.cvars.UnitNameOwn, "1", "closed by hand")
local hints2 = logCount("type: /console test_cameraOverShoulder")
S.Run()
eq(WoW.cvars.UnitNameOwn, "0", "names 2: Retry hides them")
shoot()
eq(shots, 2, "  with a screenshot")
S.Answer(false)
S.Run()
S.Poll()
eq(rec.at, 5, "names 5: waits while the exit animation runs")
ticks(0.1, 20)
WoW.flushTimers()
S.Poll()
check(tostring(rec.results[5].detail):find("the presentation ended", 1, true), "  and saves that it ended")
eq(rec.results[6].check, "PASS", "names 6: every value back after the restore")
eq(logCount("[after (check)]"), 0, "  the check gives the run's verdict, no second read")
eq(logCount("type: /console test_cameraOverShoulder"), hints2, "  no /console hint in the middle of the procedure")
eq(rec.at, 7, "names 7: the /reload")
S.Next()
eq(rec.results[8].check, "PASS", "names 8: and after it")
eq(rec.status, "done", "the names procedure finishes")

fp("steps ls rereg")
rec = record("rereg")
S.Run(); eq(WoW.internal.EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED, nil, "rereg 1: unregistered")
S.Answer(false)
S.Run(); check(WoW.internal.EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED == GameEvent.HandleExperimentalCVarConfirmationNeeded, "rereg 3: Blizzard's own")
S.Answer(true)
S.Run(); eq(type(WoW.internal.EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED), "function", "rereg 5: a closure")
S.Answer(true)
eq(rec.at, 8, "rereg 8: the /reload (the CVar put back on 7)")
S.Next()
eq(rec.status, "done", "the rereg procedure finishes")

-- #41: the target-lost click. UnitExists and IsTargetLoose are in the 70959 dump.
-- A trial that can't happen (no target, a soft one, the hide refused) keeps
-- its step for Retry, so no answer is saved for it (Codex, PR #50).
local hasTarget, loose = false, false
rawset(_G, "UnitExists", function(unit) return unit == "target" and hasTarget end)
rawset(_G, "IsTargetLoose", function() return loose end)
fp("steps ls sound")
rec = record("sound")
local errs = #errors
S.Run()
eq(rec.at, 1, "sound 1: no target, Ready keeps the step")
check(logHas("no target: click an NPC or player, then Retry"), "  and says why")
hasTarget, loose = true, true
S.Run()
eq(rec.at, 1, "sound 1: a soft target keeps it too")
loose = false
S.Run()
eq(rec.at, 2, "sound 1: a hard target goes on")
-- The Alt+Z control is observed (Codex, PR #50): a hide without a hard
-- target doesn't count, a hide with one then a show does.
-- A showcase's own hide and show never count (Codex, PR #50).
local other4 = LibStub("LibShowcase-1.0"):New({ owner = "AnotherAddon" })
check(other4:Enter(newWindow()) and not UIParent:IsShown(), "another addon's showcase hides the UI")
other4:ForceRestore(); ticks(0.1, 20); WoW.flushTimers()
S.Poll()
eq(rec.at, 2, "sound 2: a showcase's hide and show don't pass the control")
hasTarget = false
WoW.playerSetUIVisibility(false); hasTarget = true; WoW.playerSetUIVisibility(true)
S.Poll()
eq(rec.at, 2, "sound 2: Alt+Z without a hard target at the hide doesn't count")
check(logHas("no hard target when the UI hid"), "  and says so")
WoW.playerSetUIVisibility(false)
S.Poll()
eq(rec.at, 2, "sound 2: the hide alone isn't enough")
WoW.playerSetUIVisibility(true)
S.Poll()
eq(rec.at, 3, "sound 2: the hide with a hard target, then the show, completes it")
S.Answer(false)
eq(rec.results[3].check, "PASS", "sound 3: the answer is for a control that ran")
local other2 = LibStub("LibShowcase-1.0"):New({ owner = "AnotherAddon" })
other2:Enter()
S.Run()
eq(rec.at, 4, "sound 4: the hide refused (another showcase) keeps the step")
check(not win:IsShown(), "  its window closed again")
other2:ForceRestore(); ticks(0.1, 20); WoW.flushTimers()
S.Run()
expectedErrors = expectedErrors + (#errors - errs)
eq(#errors - errs, 3, "  three refusals, each sent to the error handler")
check(SC:IsActive() and SC:IsGameUIHidden() and not UIParent:IsShown(), "sound 4: Retry presents, the UI hidden")
check(tostring(rec.results[4].detail):find("target exists true, IsTargetLoose false, UI shown true", 1, true),
      "  the target read before the hide")
S.Answer(true)
S.Run()
ticks(0.1, 20)
WoW.flushTimers()
S.Poll()
check(tostring(rec.results[7].detail):find("the presentation ended", 1, true), "sound 7: the presentation ended")
S.Answer(true)
eq(rec.status, "done", "the sound procedure finishes")
check(tostring(rec.results[9].detail):find("target exists true", 1, true), "  reading the target again")
eq(rec.results[5].status, "yes", "  the answers saved")

-- #51: does the camera still follow after a presentation? ConsoleGetAllCommands
-- is in the 70959 dump; here it lists two camera CVars, a command and another.
WoW.cvars.cameraView, WoW.cvars.cameraSmoothStyle = "0", "4"
rawset(_G, "ConsoleGetAllCommands", function()
    return { { command = "cameraSmoothStyle", commandType = 0 }, { command = "cameraView", commandType = 0 },
             { command = "cameraZoomReset", commandType = 1 }, { command = "Sound_EnableSFX", commandType = 0 } }
end)
local function untilEnded()
    ticks(0.1, 20)
    WoW.flushTimers()
    S.Poll()
end
fp("steps ls follow")
rec = record("follow")
S.Next()
check(tostring(rec.results[2].detail):find("cameraView 0, cameraSmoothStyle 4", 1, true), "follow 2: the before snapshot")
eq(DB.follow.before.cameraSmoothStyle, "4", "  kept in the saved variables")
eq(DB.follow.before.Sound_EnableSFX, nil, "  camera CVars only")
-- A failed control: no trial can be measured, Open refuses (Codex, PR #52).
local errs2 = #errors
S.Answer(false)
S.Run()
eq(rec.at, 4, "follow 4: after a failed control, Open keeps the step")
check(not SC:IsActive(), "  and nothing presents")
check(logHas("the camera did not follow before this trial"), "  saying why")
-- The tester fixes the camera, then the control passes: the trial is
-- compared with the camera as it is now, not the start's (Codex, PR #52).
WoW.cvars.cameraSmoothStyle = "2"
S.Back(); S.Answer(true)
eq(DB.follow.trial.cameraSmoothStyle, "2", "follow 3: a passing control snapshots the camera for the trial")
-- Open refused by another showcase keeps the passing control for Retry.
local other3 = LibStub("LibShowcase-1.0"):New({ owner = "AnotherAddon" })
other3:Enter()
S.Run()
eq(rec.at, 4, "follow 4: another showcase holds the camera, Open keeps the step")
other3:ForceRestore(); ticks(0.1, 20); WoW.flushTimers()
-- A prompt that keeps the UI up refuses too: Escape could not end it.
WoW.readyCheck = { status = "waiting", left = 30 }
S.Run()
eq(rec.at, 4, "follow 4: the UI kept up by a prompt, Open keeps the step")
check(not win:IsShown(), "  its window closed again")
WoW.readyCheck = nil
ticks(0.1, 20); WoW.flushTimers()
S.Run()
check(SC:IsActive() and win:IsShown() and SC:IsGameUIHidden(), "follow 4: Retry with the control still good presents, the UI hidden")
S.Run(); untilEnded()
check(tostring(rec.results[6].detail):find("the presentation ended", 1, true), "follow 6: a normal exit")
eq(DB.follow.exit[1], "cameraView 0 -> 5", "follow 7: the view left on 5 is named, and saved")
eq(#DB.follow.exit, 1, "  and only that: compared with the trial's camera, not the start's")
S.Answer(false)
-- Reset puts the view back and reads it back; one Open per control.
S.Run()
eq(WoW.cvars.cameraView, "0", "follow 9: Reset puts the view back")
eq(WoW.cvars.cameraSmoothStyle, "4", "  and the start's camera CVars")
S.Answer(true)
-- The Escape trial, ended another way: its comparison is refused.
S.Run()
win:Hide(); untilEnded()
eq(rec.at, 13, "follow 13: not ended by Escape, the comparison keeps the step")
check(logHas("the presentation did not end by Escape"), "  saying why")
S.Back(); S.Back(); S.Back(); S.Answer(true)
S.Run()
WoW.playerSetUIVisibility(true)
untilEnded()
eq(rec.at, 14, "follow 12: Escape ends it, then the comparison runs")
check(tostring(rec.results[13].detail):find("escape: ", 1, true), "follow 13: compared")
S.Answer(true)
S.Run(); S.Answer(true)
S.Run()
WoW.enterCombat(); WoW.leaveCombat()
untilEnded()
eq(rec.at, 20, "follow 18: combat ends it, then the comparison runs")
S.Answer(true)
S.Run(); S.Answer(true)
S.Run()
check(SC:IsActive(), "follow 23: presenting before the /reload")
S.Next()   -- the /reload
win:Hide(); untilEnded()
check(tostring(rec.results[25].detail):find("reload: ", 1, true), "follow 25: compared after the /reload")
-- A restore that doesn't read back keeps its step (Codex, PR #52).
local realSet = SetCVar
rawset(_G, "SetCVar", function(name, value) if name ~= "cameraSmoothStyle" then return realSet(name, value) end end)
WoW.cvars.cameraSmoothStyle = "0"
S.Answer(true)
eq(rec.at, 27, "follow 27: a CVar that won't go back keeps the step")
check(logHas("not put back: cameraSmoothStyle 0 (want 4)"), "  naming it")
rawset(_G, "SetCVar", realSet)
S.Run()
eq(WoW.cvars.cameraSmoothStyle, "4", "follow 27: Retry puts it back")
eq(rec.status, "done", "the follow procedure finishes")
expectedErrors = expectedErrors + (#errors - errs2)
eq(#errors - errs2, 5, "  five refusals, each sent to the error handler")
rawset(_G, "ConsoleGetAllCommands", nil)

-- #51's follow-up: back to the default view. C_CVar.GetCVarDefault is in the
-- 70959 dump; the default here is "0", the view left on 5.
local hadCVar = rawget(_G, "C_CVar")
rawset(_G, "C_CVar", { GetCVarDefault = function(name) return name == "cameraView" and "0" or nil end })
WoW.cvars.cameraView = "5"
fp("steps ls view")
rec = record("view")
check(tostring(rec.results[1].detail):find("start: cameraView 5 (default 0)", 1, true), "view 1: the view and its default read")
S.Answer(false)
S.Run()
eq(WoW.cvars.cameraView, "0", "view 3: the CVar written to its default")
check(tostring(rec.results[3].detail):find("SetCVar to the default 0 from 5", 1, true), "  and logged")
S.Answer(false)
WoW.cvars.cameraView = "5"
S.Run()
eq(WoW.camera.view, 0, "view 5: SetView with the default")
S.Answer(true)
eq(rec.at, 7, "view 7: the /reload")
S.Next()
check(tostring(rec.results[8].detail):find("reload: cameraView", 1, true), "view 8: read again after it")
S.Answer(true)
eq(rec.status, "done", "the view procedure finishes")
rawset(_G, "C_CVar", hadCVar)

-- #51's gamepad lead: a library write over a temp CVar. SetTempCVar,
-- RemoveTempCVar and GetCVarInfo are in the 70959 dump. The client's layering
-- is what the procedure measures; here a temp simply replaces the value and
-- its removal is recorded.
local removed = {}
rawset(_G, "C_CVar", {
    SetTempCVar = function(n, v) WoW.cvars[n] = v end,
    RemoveTempCVar = function(n) removed[#removed + 1] = n end,
    GetCVarInfo = function(n) return WoW.cvars[n] end,
})
WoW.cvars.CameraKeepCharacterCentered, WoW.cvars.CameraReduceUnexpectedMovement = "1", "0"
-- In gamepad mode the start values would be the temps: refused, Retry once
-- off it (Codex, PR #52). C_InputInterfaceStyle is in the 70959 dump.
local style = 1
rawset(_G, "C_InputInterfaceStyle", { GetCurrentStyle = function() return style end })
local errs3 = #errors
fp("steps ls tempcvar")
rec = record("tempcvar")
eq(rec.at, 1, "tempcvar 1: refused in gamepad mode")
check(logHas("gamepad mode is on: use the mouse and keyboard"), "  saying why")
eq(DB.temp and DB.temp.pending, nil, "  nothing saved as the start values")
style = 0
S.Run()
check(tostring(rec.results[1].detail):find("start: CameraKeepCharacterCentered=1 (info 1)", 1, true), "tempcvar 1: read, with GetCVarInfo")
S.Run(); S.Run()
-- Switched to gamepad mid-run: Remove refuses before touching the temps,
-- which would be Blizzard's now (Codex, PR #52).
style = 1
S.Run()
eq(rec.at, 4, "tempcvar 4: Remove refused in gamepad mode, the step stays")
eq(#removed, 0, "  nothing removed")
style = 0
S.Run()
expectedErrors = expectedErrors + (#errors - errs3)
rawset(_G, "C_InputInterfaceStyle", nil)
eq(#removed, 2, "tempcvar 2-4: the control, Base, Temp and Remove with no write between")
check(tostring(rec.results[4].detail):find("remove: ", 1, true), "  read after the removal")
S.Run()
eq(WoW.cvars.CameraKeepCharacterCentered .. WoW.cvars.CameraReduceUnexpectedMovement, "01", "tempcvar 5: the base values")
S.Run()
eq(WoW.cvars.CameraKeepCharacterCentered .. WoW.cvars.CameraReduceUnexpectedMovement, "10", "tempcvar 6: the gamepad's temp values")
S.Run()
eq(WoW.cvars.CameraKeepCharacterCentered .. WoW.cvars.CameraReduceUnexpectedMovement, "00", "tempcvar 7: the presentation's write")
S.Run()
eq(WoW.cvars.CameraKeepCharacterCentered .. WoW.cvars.CameraReduceUnexpectedMovement, "10", "tempcvar 8: restored to what was read under the temp")
S.Run()
eq(#removed, 4, "tempcvar 9: both temps removed")
S.Run()
check(SC:IsActive() and win:IsShown(), "tempcvar 10: a real presentation over the temp")
S.Run(); untilEnded()
check(tostring(rec.results[12].detail):find("the presentation ended", 1, true), "tempcvar 12: ended")
check(tostring(rec.results[13].detail):find("after presentation: CameraKeepCharacterCentered=1", 1, true), "tempcvar 13: read with the temp on")
S.Run()
eq(#removed, 6, "tempcvar 14: removed again")
eq(rec.at, 15, "tempcvar 15: the /reload")
S.Next()
eq(WoW.cvars.CameraKeepCharacterCentered .. WoW.cvars.CameraReduceUnexpectedMovement, "10", "tempcvar 17: put back as at the start")
eq(rec.status, "done", "the tempcvar procedure finishes")
eq(DB.temp.pending, nil, "  its start values cleared once put back")

-- Stopped after Base (Codex, PR #52): the start values stay, a new run keeps
-- them, and /fp ls tempback puts them back.
fp("steps ls tempcvar")
rec = record("tempcvar")
S.Run()
eq(WoW.cvars.CameraKeepCharacterCentered .. WoW.cvars.CameraReduceUnexpectedMovement, "01", "a new run's Base written")
fp("steps stop")
eq(DB.temp.pending.CameraKeepCharacterCentered .. DB.temp.pending.CameraReduceUnexpectedMovement, "10", "stopped: the start values kept")
fp("steps ls tempcvar")
check(logHas("keeping an earlier run's start values"), "a new run keeps them")
eq(DB.temp.pending.CameraKeepCharacterCentered .. DB.temp.pending.CameraReduceUnexpectedMovement, "10", "  not the Base write's")
fp("steps stop")
-- In gamepad mode the put-back is refused: removing the temps would take
-- Blizzard's own away (Codex, PR #52).
local errs4 = #errors
rawset(_G, "C_InputInterfaceStyle", { GetCurrentStyle = function() return 1 end })
fp("ls tempback")
check(logHas("tempback: gamepad mode is on"), "/fp ls tempback refuses in gamepad mode")
check(DB.temp.pending ~= nil, "  and keeps the start values")
rawset(_G, "C_InputInterfaceStyle", nil)
expectedErrors = expectedErrors + (#errors - errs4)
fp("ls tempback")
eq(WoW.cvars.CameraKeepCharacterCentered .. WoW.cvars.CameraReduceUnexpectedMovement, "10", "/fp ls tempback puts them back")
eq(DB.temp.pending, nil, "  and clears them")
fp("ls tempback")
check(logHas("tempback: nothing to put back"), "  a second time, nothing to do")
-- The older probe's `orig`, left even by a finished run, is never trusted:
-- a new run drops it and records its own start values (Codex, PR #52).
DB.temp.orig = { CameraKeepCharacterCentered = "0", CameraReduceUnexpectedMovement = "1" }
fp("ls tempback")
eq(WoW.cvars.CameraKeepCharacterCentered .. WoW.cvars.CameraReduceUnexpectedMovement, "10", "tempback ignores the older probe's orig")
fp("steps ls tempcvar")
check(logHas("dropped an older probe's start values"), "a new run drops it")
eq(DB.temp.orig, nil, "  gone")
eq(DB.temp.pending.CameraKeepCharacterCentered .. DB.temp.pending.CameraReduceUnexpectedMovement, "10", "  its own start values recorded")
fp("steps stop")
fp("ls tempback")
rawset(_G, "C_CVar", hadCVar)

------------------------------------------------------------------------------
-- Nothing went wrong, nothing went to chat, the log clears in place
------------------------------------------------------------------------------
eq(logCount("ERROR"), expectedErrors, "no command or step logged an error but the refusals on purpose")
eq(#errors, expectedErrors, "nothing else reached the error handler" .. (errors[2] and (": " .. errors[2]) or ""))
eq(#WoW.chat, 0, "nothing went to chat" .. (WoW.chat[1] and (": " .. WoW.chat[1]) or ""))
-- The client reads "|x" as an escape and drops it (GlassChat #55): no line
-- the probe saved has a stray one (its help lines included).
local stray
for _, l in ipairs(DB.log) do if WoW.StrayPipe(l) then stray = stray or l end end
eq(stray, nil, "no stray | in any saved line")
local log = DB.log
fp("ls clear")
check(DB.log == log, "clear empties the saved log in place")
eq(#DB.log, 1, "leaving the one line after it")
check(DB.log[1] and DB.log[1]:find("log cleared", 1, true), "which is that one")

-- Every widget method the probe, the library and the host called exists on
-- this client, for that widget type.
Kit.checkMethods()

done("test_probe")
