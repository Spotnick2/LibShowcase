-- The lease: one owner at a time, held until every deferred cleanup is done.
-- Also the camera-OFF lease, combat during cleanup, a protected frame's
-- deferred drop, popups, and the crash self-heal.
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

    local d2 = CreateFrame("Frame", nil, UIParent)
    A:LiftPopup(d2)
    A:Exit("closed")
    d2:Hide()                                 -- a popup closing mid-exit checks the lease
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
-- Popups: raised above a DIALOG window, lifted out of a hidden UI, put back
-- however they close; never left detached.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    local SC = lib:New({ owner = "A" })
    local function popup()
        local d = CreateFrame("Frame", nil, UIParent)
        d:SetFrameStrata("DIALOG")
        return d
    end

    -- UI up: raised, not lifted.
    local d = popup()
    eq(SC:LiftPopup(d), d, "LiftPopup hands the dialog back")
    eq(d:GetFrameStrata(), "FULLSCREEN_DIALOG", "  raised above a DIALOG window")
    eq(d:GetParent(), UIParent, "  not lifted while the UI is up")
    d:Hide()                                  -- accept, cancel and Escape all hide it
    eq(d:GetFrameStrata(), "DIALOG", "hiding it puts the strata back (OnHide hook)")
    check(not SC:IsOwner(), "  and the lease is free")

    -- The player's own Alt+Z (no showcase): lifted.
    SetUIVisibility(false)
    d = popup()
    SC:LiftPopup(d)
    check(d:GetParent() == nil and d:IsVisible(), "with the UI hidden by Alt+Z it is lifted and visible")
    SC:DropPopup(d)
    eq(d:GetParent(), UIParent, "DropPopup puts it back")
    eq(d:GetFrameStrata(), "DIALOG", "  at its strata")
    check(not SC:IsLifted(d), "  nothing left marked")
    SC:DropPopup(d)
    eq(d:GetFrameStrata(), "DIALOG", "a second DropPopup is a no-op")

    -- Re-entrant: the drop's own reparent under the hidden UIParent fires
    -- OnHide (our hook) half way through.
    d = popup()
    SC:LiftPopup(d)
    d:Show()
    SC:DropPopup(d)
    eq(d:GetFrameStrata(), "DIALOG", "a drop interrupted by its own OnHide ends at the right strata")
    eq(d:GetParent(), UIParent, "  and under UIParent")
    SetUIVisibility(true)

    -- Presenting: a popup shown over the showcase, and the showcase ends
    -- first. The pooled frame must not stay detached.
    local win = newWindow()
    SC:Enter(win)
    d = popup()
    SC:LiftPopup(d)
    check(d:GetParent() == nil and d:IsVisible(), "a popup over the showcase is lifted")
    SC:ForceRestore("test")
    eq(d:GetParent(), UIParent, "a restore drops it too")
    eq(d:GetFrameStrata(), "DIALOG", "  with its strata")
    check(not SC:IsOwner(), "  and nothing holds the lease")
    -- The hook stays on the pooled frame, harmlessly.
    d:Show(); d:Hide()
    eq(d:GetFrameStrata(), "DIALOG", "a later, unrelated show/hide of the pooled frame is left alone")

    eq(SC:LiftPopup(nil), nil, "LiftPopup(nil) is nil (a refused StaticPopup_Show)")
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
end

done("test_lease")
