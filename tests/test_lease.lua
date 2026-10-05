-- The lease: one owner at a time, held until every deferred cleanup is done.
-- Also the camera-OFF lease, combat during cleanup, a protected frame's
-- deferred drop, Blizzard dialogs, and the crash self-heal.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

------------------------------------------------------------------------------
-- Single owner: a second instance is refused everything that mutates.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    local A = lib:New({ owner = "AltStable" })
    local B = lib:New({ owner = "PortalRoulette" })
    local wa, wb = newWindow(), newWindow()
    check(A:Enter(wa), "A enters")
    local mark = #WoW.calls
    local ok, why = B:Enter(wb)
    check(ok == false and why == "busy", "B: false, \"busy\"")
    check(not B:Lift(wb), "B cannot lift")
    eq(wb:GetParent(), UIParent, "  its frame stays put")
    check(not B:HideGameUI(), "B cannot hide the UI")
    check(not B:RestoreGameUI(), "B cannot restore it either")
    check(not UIParent:IsShown(), "  A's hidden UI stays hidden")
    check(not B:ForceRestore("x"), "B cannot force a restore")
    check(not B:Exit("x"), "B cannot exit A's presentation")
    check(not B:Release(), "B cannot release A's lease")
    check(B:Acquire() == false, "B cannot acquire it")
    check(not B:Drop(wa), "B cannot drop A's lifted window")
    eq(wa:GetParent(), nil, "  A's window stays lifted")
    local d = CreateFrame("Frame", nil, UIParent)
    eq(B:LiftPopup(d), d, "B's LiftPopup hands the dialog back")
    eq(d:GetParent(), UIParent, "  untouched")
    eq(#callsSince(mark), 0, "B made no camera, CVar or UI call at all")
    check(A:IsActive() and not B:IsActive(), "IsActive is per owner")
    check(B:IsGameUIHidden(), "IsGameUIHidden reports the shared truth")

    A:Exit("closed")
    ok, why = B:Enter(wb)
    check(ok == false and why == "busy", "still busy during A's exit animation")
    WoW.tick(0.1, 10)
    check(not A:IsOwner(), "A's exit finished: the lease is free")
    check(B:Enter(wb), "now B enters")
    B:ForceRestore()
end

------------------------------------------------------------------------------
-- Camera OFF: Acquire, hide the UI, lift frames, Release.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    local SC = lib:New({ owner = "A" })
    local win, extra = newWindow("HIGH"), newWindow("LOW")
    extra:SetScale(0.8)
    check(SC:Acquire(), "Acquire")
    check(SC:Acquire(), "  twice is fine")
    local mark = #WoW.calls
    check(SC:HideGameUI(win), "HideGameUI without a camera")
    check(not UIParent:IsShown() and win:IsVisible(), "  the UI is hidden, the window lifted and visible")
    check(SC:Lift(extra, "FULLSCREEN_DIALOG"), "Lift another frame")
    check(SC:Lift(extra, "FULLSCREEN_DIALOG"), "  lifting it again is a no-op")
    check(SC:IsLifted(extra), "IsLifted")
    for _, c in ipairs(callsSince(mark)) do
        check(c:match("^SetUIVisibility") ~= nil, "no camera or CVar call without a camera: " .. c)
    end
    check(SC:RestoreGameUI(), "RestoreGameUI")
    check(UIParent:IsShown(), "  the UI is back")
    eq(extra:GetParent(), UIParent, "  every lifted frame is put back")
    eq(extra:GetFrameStrata(), "LOW", "  at its strata")
    eq(extra:GetScale(), 0.8, "  and scale (a double lift saved nothing twice)")
    check(SC:IsOwner(), "an Acquired lease outlives an idle moment")
    check(SC:Release(), "Release")
    check(not SC:IsOwner(), "  gives it back")

    -- Implicit: a Lift alone takes the lease and its Drop gives it back.
    local f = newWindow()
    check(SC:Lift(f), "a Lift with no lease takes it")
    check(SC:IsOwner(), "  ")
    check(SC:Drop(f), "Drop")
    check(not SC:IsOwner(), "  gives it back once nothing is lifted")
    check(SC:Drop(f), "a second Drop is a no-op")

    -- A frame whose own OnHide drops it: putting it back under a hidden
    -- UIParent fires that OnHide half way through the first drop. The nested
    -- drop must find nothing to undo, and the other records must survive.
    SetUIVisibility(false)                    -- the player's Alt+Z
    local f1, f2 = newWindow(), newWindow()
    f1:SetScript("OnHide", function(self) SC:Drop(self) end)
    SC:Lift(f1); SC:Lift(f2)
    SC:Drop(f1)
    eq(f1:GetParent(), UIParent, "a drop re-entered from its own OnHide puts the frame back")
    check(SC:IsLifted(f2) and f2:GetParent() == nil, "  and leaves the other lift's record alone")
    SC:Drop(f2)
    SetUIVisibility(true)

    -- Release restores everything first.
    SC:Acquire()
    SC:HideGameUI(win)
    SC:Lift(extra)
    SC:Release()
    check(UIParent:IsShown() and win:GetParent() == UIParent and extra:GetParent() == UIParent,
          "Release restores the UI and every lift")
    check(not SC:IsOwner(), "  then lets go")
end

------------------------------------------------------------------------------
-- Combat during cleanup: the exit animation is cut short at
-- PLAYER_REGEN_DISABLED, which still runs unlocked.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    local reasons = {}
    local SC = lib:New({ owner = "A", onForcedExit = function(r) reasons[#reasons + 1] = r end })
    local win = newWindow()
    SC:Enter(win)
    SC:Exit("closed")
    check(SC:IsActive(), "mid exit animation")
    WoW.enterCombat()
    check(not SC:IsActive() and not SC:IsOwner(), "combat start restores and releases at once")
    eq(WoW.cvars.CameraKeepCharacterCentered, "1", "  centring restored")
    eq(WoW.cvars.test_cameraOverShoulder, "0", "  offset restored")
    eq(#WoW.blocked, 0, "  nothing was blocked: done before the lockdown")
    eq(reasons[1], "combat", "  the owner is told")
    WoW.tick(0.1, 10)
    eq(WoW.cvars.CameraKeepCharacterCentered, "1", "the dead exit animation writes nothing more")
    local ok, why = SC:Enter(win)
    check(ok == false and why == "combat", "no showcase in combat")
    WoW.leaveCombat()

    -- Presenting when combat starts: everything restored in the handler.
    SC:Enter(win)
    WoW.enterCombat()
    check(UIParent:IsShown() and win:GetParent() == UIParent, "combat during a presentation: UI and window back")
    eq(WoW.camera.yaw, nil, "  the orbit stopped")
    WoW.leaveCombat()
end

------------------------------------------------------------------------------
-- A protected frame lifted when a restore lands INSIDE the lockdown: its
-- record is kept, it is not touched (no Hide, no SetParent), and it goes
-- back at PLAYER_REGEN_ENABLED. The lease is held until then.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    local reasons = {}
    local SC = lib:New({ owner = "A", onForcedExit = function(r) reasons[#reasons + 1] = r end })
    local other = lib:New({ owner = "B" })
    local secure = newWindow("MEDIUM")
    secure._protected = true
    secure:SetScale(0.9)
    secure:SetFrameLevel(7)
    local plain = newWindow("LOW")
    SC:Enter(secure)
    SC:Lift(plain)
    eq(secure:GetParent(), nil, "the protected window is lifted (out of combat)")

    WoW.inCombat = true                      -- e.g. Escape pressed mid-fight
    SetUIVisibility(true)
    eq(reasons[1], "ui-shown", "the owner is told")
    check(UIParent:IsShown(), "the UI is back")
    eq(WoW.cvars.CameraKeepCharacterCentered, "0", "(exit animation pending)")
    SC:ForceRestore("test")
    eq(WoW.cvars.CameraKeepCharacterCentered, "1", "the camera is restored immediately, in combat")
    eq(#WoW.blocked, 0, "nothing protected was touched")
    eq(secure:GetParent(), nil, "the protected window keeps its lift")
    check(secure:IsShown(), "  and was never hidden")
    check(SC:IsLifted(secure), "  its record is kept")
    eq(plain:GetParent(), UIParent, "an unprotected frame goes back at once")
    check(SC:IsOwner(), "the lease is held while a drop is owed")
    local ok, why = other:Enter()
    check(ok == false and why == "busy", "  so another addon is still refused")
    check(SC:Lift(newWindow()), "an unprotected frame can still be lifted in combat")
    local p2 = newWindow(); p2._protected = true
    local okLift, whyLift = SC:Lift(p2)
    check(okLift == false and whyLift == "combat", "lifting a protected frame in combat is refused")

    WoW.leaveCombat()
    eq(secure:GetParent(), UIParent, "PLAYER_REGEN_ENABLED puts it back")
    eq(secure:GetScale(), 0.9, "  at its scale")
    eq(secure:GetFrameStrata(), "MEDIUM", "  strata")
    eq(secure:GetFrameLevel(), 7, "  and level")
    check(not SC:IsLifted(secure), "  and only then clears the record")
    SC:ForceRestore()
    check(not SC:IsOwner(), "then the lease is free")
    check(other:Enter(), "and the other addon can present")
    other:ForceRestore()
end

------------------------------------------------------------------------------
-- Blizzard dialogs are never touched. A dialog shown while the library has
-- the UI hidden brings the UI back (through the library's own restore, not
-- read as Escape); the camera, the lease and the window stay.
-- MEASURED 70205: an addon that showed a StaticPopup and reparented, raised
-- and hooked it tainted the pool: the player's Quit dialog then failed.
------------------------------------------------------------------------------
-- Every call on the dialog other than a read (Get*/Is*, which the test makes).
local function untouched(d, what)
    local writes = {}
    for _, c in ipairs(d._log) do
        if not c[1]:match("^Get") and not c[1]:match("^Is") then writes[#writes + 1] = c[1] end
    end
    eq(table.concat(writes, ","), "", what .. ": the library made no call on the dialog (no SetParent/SetFrameStrata/HookScript)")
end

do
    local lib = freshLibrary()
    local shown, forced = {}, {}
    local SC = lib:New({ owner = "A",
        onGameUIShown = function(r) shown[#shown + 1] = r end,
        onForcedExit = function(r) forced[#forced + 1] = r end })
    local win = newWindow("MEDIUM")
    SC:Enter(win)
    WoW.tick(0.1, 16)
    local yaw = WoW.camera.yaw
    check(not UIParent:IsShown(), "presenting with the UI hidden")

    local d = StaticPopup_Show("PARTY_INVITE", "Friend")
    check(UIParent:IsShown(), "a StaticPopup_Show while hidden brings the UI back")
    check(d:IsVisible(), "  so the dialog is visible where Blizzard put it")
    eq(d:GetParent(), UIParent, "  still under UIParent")
    eq(d:GetFrameStrata(), "DIALOG", "  at its own strata")
    untouched(d, "StaticPopup_Show")
    check(not SC:IsGameUIHidden(), "  the library knows the UI is up")
    eq(shown[1], "dialog", "onGameUIShown(\"dialog\")")
    eq(#shown, 1, "  once")
    eq(#forced, 0, "not read as Escape/Alt+Z: no onForcedExit")
    check(SC:IsActive() and lib.state.cam.mode ~= "exit", "the presentation goes on")
    eq(WoW.camera.yaw, yaw, "  the orbit keeps turning")
    eq(WoW.cvars.CameraKeepCharacterCentered, "0", "  the camera CVars stay")
    check(SC:IsOwner(), "the lease is kept")
    check(win:IsVisible() and win:GetParent() == UIParent, "the window stays open, back under the shown UI")

    -- A second dialog with the UI already up: nothing more.
    local mark = #WoW.calls
    local d2 = StaticPopup_Show("GUILD_INVITE")
    eq(#callsSince(mark), 0, "a dialog with the UI up makes no call")
    eq(#shown, 1, "  and no callback")
    untouched(d2, "with the UI up")
    WoW.closeDialog(d); WoW.closeDialog(d2)

    SC:Exit("closed")
    WoW.tick(0.1, 10)
    check(not SC:IsOwner(), "the exit still finishes and releases")
    eq(WoW.cvars.CameraKeepCharacterCentered, "1", "  restoring the camera")
    untouched(d, "after the restore")
end

-- StaticPopupSpecial_Show, a refused StaticPopup_Show, LiftPopup/DropPopup.
do
    local lib = freshLibrary()
    local shown = {}
    local SC = lib:New({ owner = "A", onGameUIShown = function(r) shown[#shown + 1] = r end })
    local other = lib:New({ owner = "B" })
    local win = newWindow()
    SC:Enter(win)

    WoW.refuseDialogs = true
    eq(StaticPopup_Show("X"), nil, "a refused StaticPopup_Show (nil)")
    check(not UIParent:IsShown() and #shown == 0, "  leaves the UI hidden: no dialog is shown")
    WoW.refuseDialogs = false

    local special = CreateFrame("Frame", nil, UIParent)
    special._log = {}
    StaticPopupSpecial_Show(special)
    check(UIParent:IsShown(), "StaticPopupSpecial_Show while hidden brings the UI back")
    untouched(special, "StaticPopupSpecial_Show")
    eq(shown[1], "dialog", "  onGameUIShown")
    check(SC:IsActive() and SC:IsOwner(), "  presentation and lease kept")
    WoW.closeDialog(special)
    SC:ForceRestore()

    -- LiftPopup: "reveal for a dialog", the dialog handed back untouched.
    SC:Enter(win)
    local d = CreateFrame("Frame", nil, UIParent)
    d._log = {}
    eq(other:LiftPopup(d), d, "another instance's LiftPopup hands the dialog back")
    check(not UIParent:IsShown(), "  and does not touch A's hidden UI")
    eq(SC:LiftPopup(d), d, "LiftPopup hands the dialog back")
    check(UIParent:IsShown(), "  having brought the UI back")
    check(SC:IsActive() and SC:IsOwner(), "  with the presentation and the lease kept")
    eq(#shown, 2, "  and onGameUIShown called")
    SC:LiftPopup(d)
    eq(#shown, 2, "a LiftPopup with the UI already up does nothing")
    StaticPopupSpecial_Show(CreateFrame("Frame", nil, UIParent))
    eq(#shown, 2, "nor does a special dialog")
    eq(SC:DropPopup(d), nil, "DropPopup is a no-op")
    untouched(d, "LiftPopup/DropPopup")
    eq(SC:LiftPopup(nil), nil, "LiftPopup(nil) is nil")
    SC:ForceRestore()
    eq(SC:LiftPopup(d), d, "LiftPopup with no lease")
    check(not SC:IsOwner(), "  takes no lease")
end

-- No lease, or the player's own Alt+Z: nothing happens.
do
    local lib = freshLibrary()
    local shown = 0
    lib:New({ owner = "A", onGameUIShown = function() shown = shown + 1 end })
    local mark = #WoW.calls
    local d = StaticPopup_Show("PARTY_INVITE")
    eq(#callsSince(mark), 0, "no lease: a dialog makes no call")
    untouched(d, "no lease")
    WoW.closeDialog(d)
    SetUIVisibility(false)                    -- the player's Alt+Z, no lease
    mark = #WoW.calls
    d = StaticPopup_Show("PARTY_INVITE")
    eq(#callsSince(mark), 0, "the player's own Alt+Z is left alone")
    check(not UIParent:IsShown(), "  the UI stays hidden")
    eq(shown, 0, "no callback")
    untouched(d, "under the player's Alt+Z")
    check(not lib.state.owner, "and no lease taken")
end

-- A dialog already up when the UI would be hidden: its Show already happened,
-- so nothing would bring it back. The UI stays up; the camera still presents.
do
    local lib = freshLibrary()
    local shown = {}
    local SC = lib:New({ owner = "A", onGameUIShown = function(r) shown[#shown + 1] = r end })
    local d = StaticPopup_Show("PARTY_INVITE")
    local win = newWindow()
    check(SC:Enter(win), "Enter with a dialog up still presents")
    check(SC:IsActive(), "  the camera runs")
    check(UIParent:IsShown() and d:IsVisible(), "  but the UI, and the dialog, stay up")
    eq(win:GetParent(), UIParent, "  the window is not lifted")
    check(not SC:IsGameUIHidden(), "  and the library knows the UI is up")
    eq(#shown, 0, "  nothing was hidden, so no onGameUIShown")
    untouched(d, "a dialog up at Enter")
    SC:ForceRestore()
    local ok, why = SC:HideGameUI(win)
    check(ok == false and why == "dialog", "HideGameUI refuses: false, \"dialog\"")
    check(not SC:IsOwner(), "  and takes no lease")
    WoW.closeDialog(d)
    check(SC:HideGameUI(win), "once the dialog is closed, the UI hides")
    SC:RestoreGameUI()
end

-- Prompts that are not StaticPopups (a ready check, a dungeon proposal, a
-- loot roll, ...) bring the UI back through their events.
do
    local lib = freshLibrary()
    local shown, forced = {}, {}
    local SC = lib:New({ owner = "A",
        onGameUIShown = function(r) shown[#shown + 1] = r end,
        onForcedExit = function(r) forced[#forced + 1] = r end })
    -- { start event, its args, the end event (nil: none), its args }
    local prompts = {
        { "READY_CHECK", { "Leader", 35 }, "READY_CHECK_FINISHED", {} },
        { "LFG_PROPOSAL_SHOW", {}, "LFG_PROPOSAL_FAILED", {} },
        { "LFG_ROLE_CHECK_SHOW", { false }, "LFG_ROLE_CHECK_HIDE", {} },
        { "ROLE_POLL_BEGIN", { "Leader" }, nil },
        { "PVP_ROLE_POPUP_SHOW", { {} }, "PVP_ROLE_POPUP_HIDE", {} },
        { "START_LOOT_ROLL", { 7, 60000 }, "CANCEL_LOOT_ROLL", { 7 } },
    }
    for i, p in ipairs(prompts) do
        local ev = p[1]
        local win = newWindow()
        SC:Enter(win)
        check(not UIParent:IsShown(), ev .. ": presenting with the UI hidden")
        WoW.fire(ev, unpack(p[2]))
        check(UIParent:IsShown(), ev .. " brings the UI back")
        check(SC:IsActive() and SC:IsOwner(), "  presentation and lease kept")
        check(#shown == i and shown[i] == "dialog", "  onGameUIShown(\"dialog\"), once")
        -- Revealed, then HideGameUI: the prompt is still open, so no.
        local ok, why = SC:HideGameUI(win)
        check(ok == false and why == "dialog", "  HideGameUI while it is open: false, \"dialog\"")
        check(UIParent:IsShown(), "  the UI stays up")
        if p[3] then
            WoW.fire(p[3], unpack(p[4]))
            check(SC:HideGameUI(win), "  after " .. p[3] .. ", the UI hides again")
        else
            WoW.advance(30)
            eq(select(2, SC:HideGameUI(win)), "dialog", "  no end event: still open 30 s later")
            WoW.advance(31)
            check(SC:HideGameUI(win), "  and closed by the timeout")
        end
        SC:ForceRestore()
    end
    eq(#forced, 0, "none is read as Escape/Alt+Z")

    -- Started before Enter: Enter presents with the UI up, until it ends.
    WoW.fire("READY_CHECK", "Leader", 35)
    local win = newWindow()
    check(SC:Enter(win), "a ready check open before Enter: Enter still presents")
    check(UIParent:IsShown() and not SC:IsGameUIHidden(), "  with the UI up")
    WoW.advance(37)
    check(SC:HideGameUI(win), "  its own time limit (35 s) ends it")
    SC:ForceRestore()

    -- Started before the first copy of the library loaded (a load-on-demand
    -- consumer): no start event was seen, so the client's getters decide.
    local live = {
        { "a ready check", function() WoW.readyCheck = { status = "waiting", left = 20 } end,
          function() WoW.readyCheck = { status = "ready", left = 15 } end },
        { "an LFG proposal", function() WoW.lfgProposal = true end, function() WoW.lfgProposal = false end },
        { "an LFG role check", function() WoW.roleCheck = true end, function() WoW.roleCheck = false end },
        { "a loot roll", function() WoW.lootRolls[42] = 45000 end, function() WoW.lootRolls[42] = 0 end },
    }
    for _, l in ipairs(live) do
        l[2]()
        local w = newWindow()
        check(SC:Enter(w), l[1] .. " open before the library loaded: Enter presents")
        check(UIParent:IsShown() and w:IsVisible(), "  with the UI, and the prompt, still up")
        l[3]()
        check(SC:HideGameUI(w), "  once the client reports it answered or gone, the UI hides")
        SC:ForceRestore()
    end
    WoW.readyCheck = { status = "waiting", left = 0 }
    check(SC:HideGameUI(), "a ready check still 'waiting' with no time left is over")
    SC:RestoreGameUI()
    WoW.readyCheck = nil

    -- Loot rolls by rollID; CANCEL_ALL_LOOT_ROLLS ends them all.
    WoW.fire("START_LOOT_ROLL", 1, 60000)
    WoW.fire("START_LOOT_ROLL", 2, 60000)
    WoW.fire("CANCEL_LOOT_ROLL", 1)
    eq(select(2, SC:HideGameUI()), "dialog", "roll 2 still open after roll 1 ends")
    WoW.fire("CANCEL_ALL_LOOT_ROLLS")
    check(SC:HideGameUI(), "CANCEL_ALL_LOOT_ROLLS ends every roll")
    SC:RestoreGameUI()

    local mark = #WoW.calls
    WoW.fire("READY_CHECK", "Leader", 30)
    eq(#callsSince(mark), 0, "with no lease, a ready check makes no call")
    WoW.fire("READY_CHECK_FINISHED")
end

-- Codex's ordering: READY_CHECK fires before the FIRST copy loads (nobody
-- listens yet), then the library loads and enters.
do
    WoW.reset()
    WoW.resetLibStub()
    WoW.readyCheck = { status = "waiting", left = 30 }
    WoW.fire("READY_CHECK", "Leader", 30)
    local lib = loadCopy(copyOf(), "LoadOnDemand")
    local SC = lib:New({ owner = "LoD" })
    local win = newWindow()
    check(SC:Enter(win), "a ready check before the first load: Enter presents")
    check(UIParent:IsShown() and not SC:IsGameUIHidden(), "  without hiding the open ready check")
    eq(lib.state.prompts.ready, nil, "  (the event was never seen: the client's getters told)")
    SC:ForceRestore()
end

-- HideGameUI, then Enter(window): the window still comes up above the UI.
do
    local lib = freshLibrary()
    local SC = lib:New({ owner = "A" })
    local win = newWindow()
    check(SC:HideGameUI(), "the UI hidden with no window")
    check(SC:Enter(win), "then Enter(window)")
    check(win:IsVisible() and win:GetParent() == nil, "  the window is lifted above the hidden UI")
    SC:ForceRestore()
    eq(win:GetParent(), UIParent, "  and put back on restore")
end

-- An idle Acquire lease: combat, logout and loading screens have nothing to
-- restore and no exit to report.
do
    local lib = freshLibrary()
    local forced = {}
    local SC = lib:New({ owner = "A", onForcedExit = function(r) forced[#forced + 1] = r end })
    check(SC:Acquire(), "an idle Acquire lease")
    local mark = #WoW.calls
    WoW.enterCombat(); WoW.leaveCombat()
    WoW.fire("PLAYER_ENTERING_WORLD")
    eq(#callsSince(mark), 0, "combat and a loading screen make no call (no MoveView*Stop)")
    eq(#forced, 0, "  and report no forced exit")
    check(SC:IsOwner(), "  the lease stays")
    SC:Release()
end

-- Camera OFF (Acquire + HideGameUI): the UI comes back, the lease stays.
do
    local lib = freshLibrary()
    local SC = lib:New({ owner = "A" })
    local win = newWindow()
    SC:Acquire()
    SC:HideGameUI(win)
    StaticPopup_Show("PARTY_INVITE")
    check(UIParent:IsShown() and win:GetParent() == UIParent, "camera off: the UI and the window come back")
    check(SC:IsOwner(), "  and the Acquired lease stays")
    SC:Release()
end

------------------------------------------------------------------------------
-- Crash self-heal: Enter writes the capture into the consumer's db; a clean
-- restore clears it; a capture still there at login is put back.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    local DB = {}
    local SC = lib:New({ owner = "A", db = function() return DB end, pitchLimit = 1, dynamicPitch = true })
    SC:Enter()
    local cap = DB.LibShowcaseCapture
    check(type(cap) == "table", "Enter writes the capture to the db")
    eq(cap.savedViewSlot, 5, "  the view slot")
    eq(cap.zoom, 4, "  the zoom")
    eq(cap.CameraKeepCharacterCentered, "1", "  each centring CVar")
    eq(cap.shoulderOffset, 0, "  the shoulder offset")
    eq(cap.cameraDistanceMaxZoomFactor, 1, "  the zoom cap")
    eq(cap.dynamicPitch, "0", "  the pitch CVar")
    eq(cap.pitchLimit, true, "  and that pitchlimit was changed")
    SC:ForceRestore()
    eq(DB.LibShowcaseCapture, nil, "a clean restore clears it")

    -- A crash: the session ends with the presentation up and no restore.
    SC:Enter()
    local saved = {}
    for k, v in pairs(DB.LibShowcaseCapture) do saved[k] = v end
    local camAfterCrash = WoW.cvars.CameraKeepCharacterCentered

    -- Next session: CameraKeepCharacterCentered persisted the changed value
    -- (MEASURED across a /reload); test_cameraOverShoulder reverted to 0.
    local persisted = { CameraKeepCharacterCentered = camAfterCrash }
    lib = freshLibrary()
    for k, v in pairs(persisted) do WoW.cvars[k] = v end
    WoW.camera.pitchlimit = 1
    local DB2 = { LibShowcaseCapture = saved }
    lib:New({ owner = "A", db = function() return DB2 end })
    eq(WoW.cvars.CameraKeepCharacterCentered, "0", "next session starts with the crash's value")
    WoW.fire("PLAYER_LOGIN")
    eq(WoW.cvars.CameraKeepCharacterCentered, "1", "PLAYER_LOGIN puts the player's value back")
    eq(WoW.camera.pitchlimit, 88, "  and the pitch limit")
    eq(WoW.camera.view, 5, "  and the saved view")
    eq(DB2.LibShowcaseCapture, nil, "  and clears the capture")
    eq(WoW.popupShown, 0, "  without the experimental popup")
    local n = #WoW.calls
    WoW.fire("PLAYER_LOGIN")
    eq(#WoW.calls, n, "a second login has nothing to do")

    -- A load-on-demand consumer created after login heals in New.
    lib = freshLibrary()
    WoW.loggedIn = true
    WoW.cvars.CameraKeepCharacterCentered = "0"
    local DB3 = { LibShowcaseCapture = { CameraKeepCharacterCentered = "1" } }
    lib:New({ owner = "LoD", db = DB3 })
    eq(WoW.cvars.CameraKeepCharacterCentered, "1", "created after login: healed at once")
    eq(DB3.LibShowcaseCapture, nil, "  (db given as a table works too)")

    -- Created after login WHILE another addon presents: not healed then (the
    -- camera is A's); healed at its own Enter, before the capture, so the
    -- capture holds the player's value and not the crash's.
    lib = freshLibrary()
    WoW.loggedIn = true
    local A = lib:New({ owner = "A" })
    check(A:Enter(newWindow()), "A presents")
    local DB4 = { LibShowcaseCapture = { CameraKeepCharacterCentered = "1" } }
    local B = lib:New({ owner = "B", db = DB4 })
    check(DB4.LibShowcaseCapture ~= nil, "B created while A presents: not healed yet")
    A:ForceRestore()
    WoW.cvars.CameraKeepCharacterCentered = "0"    -- the crash's value, still in place
    check(B:Enter(newWindow()), "B presents")
    eq(DB4.LibShowcaseCapture.CameraKeepCharacterCentered, "1", "  healed first: its capture holds the player's value")
    B:ForceRestore()
    eq(WoW.cvars.CameraKeepCharacterCentered, "1", "  so its restore puts the player's value back")

    -- A camera-OFF owner (no presentation, cam.active false) still owns the
    -- camera: a load-on-demand New with a leftover capture leaves it alone.
    lib = freshLibrary()
    WoW.loggedIn = true
    local C = lib:New({ owner = "C" })
    C:Acquire()
    C:HideGameUI(newWindow())
    WoW.cvars.CameraKeepCharacterCentered = "0"
    local DB5 = { LibShowcaseCapture = { savedViewSlot = 5, zoom = 12, CameraKeepCharacterCentered = "1" } }
    local mark = #WoW.calls
    local D = lib:New({ owner = "D", db = DB5 })
    eq(#callsSince(mark), 0, "another instance's camera-OFF lease: New heals nothing (no camera call)")
    check(DB5.LibShowcaseCapture ~= nil, "  the capture is kept")
    check(C:IsOwner() and not D:IsOwner(), "  the lease is untouched")
    C:Release()
    check(D:Enter(newWindow()), "once it is free, D presents")
    eq(DB5.LibShowcaseCapture.CameraKeepCharacterCentered, "1", "  healed first, holding the lease")
    D:ForceRestore()
end

done("test_lease")
