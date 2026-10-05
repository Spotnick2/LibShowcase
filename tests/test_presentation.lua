-- The presentation itself: what Enter changes, that every route out puts it
-- all back, the experimental-CVar popup, the opt-in extras and castAware.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local function snapshot()
    local t = {}
    for k, v in pairs(WoW.cvars) do t[k] = v end
    return t
end
local function sameCVars(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false, k end end
    for k, v in pairs(b) do if a[k] ~= v then return false, k end end
    return true
end

------------------------------------------------------------------------------
-- Enter, then Exit and the exit animation: everything back as found.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    local SC = lib:New({ owner = "AltStable" })
    local before = snapshot()
    local win = newWindow("MEDIUM")
    WoW.camera.zoom = 12

    local ok, why = SC:Enter(win)
    check(ok == true and why == nil, "Enter answers true")
    check(SC:IsActive(), "and the presentation is active")
    check(SC:IsOwner(), "with this instance owning the showcase")
    eq(WoW.cvars.CameraKeepCharacterCentered, "0", "the centring CVar is cleared")
    eq(WoW.cvars.CameraReduceUnexpectedMovement, "0", "and the damping one")
    check(tonumber(WoW.cvars.test_cameraOverShoulder) > 0, "the shoulder offset is written")
    eq(WoW.cvars.cameraDistanceMaxZoomFactor, "2", "the zoom cap is lifted")
    eq(WoW.camera.savedViews[5], 12, "the player's view is saved in slot 5")
    eq(WoW.camera.view, 2, "the presentation starts from view 2")
    eq(WoW.popupShown, 0, "no experimental-CVar popup")
    check(hasCall("UnregisterInternalEvent(" .. "EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED"), "suppressed through GameEvent")
    check(WoW.camera.yaw and WoW.camera.yaw < 0, "the swing turns left (yawOffset < 0)")
    check(not UIParent:IsShown(), "the game UI is hidden")
    check(SC:IsGameUIHidden(), "and the library says so")
    check(win:GetParent() == nil and win:IsVisible(), "the window is lifted out of it, still visible")
    eq(win:GetFrameStrata(), "DIALOG", "  at DIALOG")
    check(GameTooltip:GetParent() == nil and GameTooltip:GetFrameStrata() == "TOOLTIP", "GameTooltip lifted too, at TOOLTIP")

    -- The animation runs from WorldFrame, so it keeps ticking with the UI hidden.
    check(lib.animFrame:GetParent() == WorldFrame, "the OnUpdate runner hangs from WorldFrame")
    WoW.tick(0.1, 16)
    eq(WoW.camera.yaw, -0.005, "after the swing: the slow orbit, leftward")
    check(not lib.animFrame:IsShown(), "and the runner stops")

    check(SC:Exit("closed"), "Exit answers true")
    check(UIParent:IsShown(), "Exit gives the UI back at once")
    eq(win:GetParent(), UIParent, "the window back under UIParent")
    eq(win:GetFrameStrata(), "MEDIUM", "  at its own strata")
    eq(win:GetScale(), 1, "  and scale")
    eq(GameTooltip:GetParent(), UIParent, "GameTooltip back")
    eq(WoW.camera.view, 5, "the saved view is snapped back")
    check(SC:IsActive(), "the presentation is still winding down")
    WoW.tick(0.1, 5)
    check(not SC:IsActive(), "and ends after exitDuration")
    check(not SC:IsOwner(), "giving the showcase back")
    local same, which = sameCVars(before, WoW.cvars)
    check(same, "every CVar is exactly as found: " .. tostring(which))
    eq(WoW.camera.zoom, 12, "and the zoom")
    eq(WoW.popupShown, 0, "still no popup, the restore write included")
    eq(WoW.internal.EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED, nil, "the popup stays off until the next frame")
    WoW.flushTimers()
    check(type(WoW.internal.EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED) == "function",
          "then Blizzard's handler is registered again")
    SetCVar("test_cameraOverShoulder", "0")
    eq(WoW.popupShown, 1, "so a later test_* write asks again, as it would without us")
end

------------------------------------------------------------------------------
-- A CVar the client lacks is never created, on the way in or out.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    local SC = lib:New({ owner = "A" })
    WoW.cvars.CameraKeepCharacterCentered = nil
    WoW.cvars.CameraReduceUnexpectedMovement = nil
    check(SC:Enter(newWindow()), "enters without the centring CVars")
    eq(WoW.cvars.CameraKeepCharacterCentered, nil, "and does not create one")
    SC:ForceRestore("test")
    eq(WoW.cvars.CameraKeepCharacterCentered, nil, "nor on the way out")
    eq(WoW.cvars.CameraReduceUnexpectedMovement, nil, "nor the other")
end

------------------------------------------------------------------------------
-- Reopened during the exit animation: a real, fresh entry.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    local SC = lib:New({ owner = "A" })
    SC:Enter(newWindow())
    SC:Exit("closed")
    eq(WoW.cvars.CameraKeepCharacterCentered, "0", "centring stays off during the exit animation")
    local mark = #WoW.calls
    check(SC:Enter(newWindow()), "re-entering during the exit")
    eq(lib.state.cam.mode, "enter", "restarts the presentation")
    eq(WoW.cvars.CameraKeepCharacterCentered, "0", "  with centring off")
    local calls = callsSince(mark)
    local restoredFirst = false
    for i, c in ipairs(calls) do
        if c == "SetCVar(CameraKeepCharacterCentered, 1)" then restoredFirst = i end
    end
    check(restoredFirst, "  after finishing the exit (the old capture restored)")
    WoW.tick(0.1, 30)
    check(SC:IsActive(), "and the old exit does not fire with the window open")
    SC:ForceRestore("test")
    eq(WoW.cvars.CameraKeepCharacterCentered, "1", "the fresh capture restores the player's value")
end

------------------------------------------------------------------------------
-- Refusals.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    local SC = lib:New({ owner = "A" })
    WoW.inCombat = true
    local ok, why = SC:Enter(newWindow())
    check(ok == false and why == "combat", "in combat: false, \"combat\"")
    check(not SC:IsOwner(), "  and no lease taken")
    WoW.inCombat = false
    local realSaveView = SaveView
    rawset(_G, "SaveView", false)        -- absent on this client
    ok, why = SC:Enter(newWindow())
    rawset(_G, "SaveView", realSaveView)
    check(ok == false and why == "unsupported", "without the camera API: false, \"unsupported\"")
    check(not SC:IsOwner(), "  and no lease taken")
    check(not SC:Exit(), "Exit with nothing running answers false")
end

------------------------------------------------------------------------------
-- hideUI = false, and Enter without an anchor: the UI stays up.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    local SC = lib:New({ owner = "A", hideUI = false })
    local win = newWindow()
    SC:Enter(win)
    check(UIParent:IsShown() and win:GetParent() == UIParent, "hideUI = false leaves the UI and the window alone")
    SC:ForceRestore()
    local SC2 = lib:New({ owner = "B" })
    SC2:Enter()
    check(UIParent:IsShown(), "no anchor: nothing to lift, so the UI is not hidden")
    SC2:ForceRestore()
end

------------------------------------------------------------------------------
-- Esc / Alt+Z with the UI hidden: onForcedExit("ui-shown"), and nothing is
-- left half-shown even if the consumer ignores it.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    local reasons = {}
    local win = newWindow()
    local SC
    SC = lib:New({ owner = "A", onForcedExit = function(r)
        reasons[#reasons + 1] = r
        if r == "ui-shown" then win:Hide(); SC:Exit("closed") end
    end })
    SC:Enter(win)
    SetUIVisibility(true)                   -- the player presses Escape
    eq(reasons[1], "ui-shown", "the owner is told the UI came back")
    eq(lib.state.cam.mode, "exit", "its Exit runs the normal exit")
    eq(win:GetParent(), UIParent, "the window is back under UIParent")
    eq(GameTooltip:GetParent(), UIParent, "and GameTooltip")
    eq(#reasons, 1, "once")

    local lib2 = freshLibrary()
    local SC2 = lib2:New({ owner = "B" })   -- no onForcedExit
    local w2 = newWindow()
    SC2:Enter(w2)
    SetUIVisibility(true)
    eq(lib2.state.cam.mode, "exit", "with no handler the library exits by itself")
    check(not SC2:IsGameUIHidden() and w2:GetParent() == UIParent, "  and drops what it lifted")
    WoW.tick(0.1, 10)
    check(not SC2:IsOwner(), "  and finishes")
end

------------------------------------------------------------------------------
-- Logout and a loading screen restore everything and tell the owner.
------------------------------------------------------------------------------
do
    for _, ev in ipairs({ "PLAYER_LOGOUT", "PLAYER_ENTERING_WORLD" }) do
        local lib = freshLibrary()
        local got
        local SC = lib:New({ owner = "A", onForcedExit = function(r) got = r end })
        SC:Enter(newWindow())
        WoW.fire(ev)
        check(not SC:IsActive() and not SC:IsOwner(), ev .. " restores and releases")
        eq(WoW.cvars.CameraKeepCharacterCentered, "1", "  centring back")
        check(UIParent:IsShown(), "  the UI back")
        eq(got, ev == "PLAYER_LOGOUT" and "logout" or "loading", "  and the owner is told why")
    end
end

------------------------------------------------------------------------------
-- Mounted: the mounted zoom and the Narcissus mounted offset (no override),
-- or the consumer's.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    WoW.mounted = true
    local SC = lib:New({ owner = "A" })
    SC:Enter()
    eq(WoW.camera.zoom, 8, "mounted: zoom to mountedZoom")
    eq(tonumber(WoW.cvars.test_cameraOverShoulder), 8 * 1.2495 - 4.0, "  Narcissus's mounted offset")
    SC:ForceRestore()
    SC.opts.mountedShoulder = 6
    SC:Enter()
    eq(tonumber(WoW.cvars.test_cameraOverShoulder), 6, "  or the consumer's mountedShoulder")
    SC:ForceRestore()
end

------------------------------------------------------------------------------
-- Library functions.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    eq(lib.ShoulderOffsetFor("Tauren", 6.2), 6.2 * 0.2027 - 0.18, "ShoulderOffsetFor by race file")
    eq(lib.ShoulderOffsetFor(6, 6.2), 6.2 * 0.2027 - 0.18, "  and by race ID")
    eq(lib.ShoulderOffsetFor("HighOrderSkyborne", 2), 2 * 0.361 - 0.1654, "  an unknown race takes the default")
    eq(lib.ShoulderOffsetFor(nil, 8, true), 8 * 1.2495 - 4.0, "  mounted")
    local realGameEvent = GameEvent
    rawset(_G, "GameEvent", false)       -- absent on this client
    local f = CreateFrame("Frame")
    f:RegisterEvent("EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED")
    WoW.eventFrames.EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED = { f }
    eq(lib.SuppressExperimentalCVarPopup(), 1, "without GameEvent: the frame fallback (varargs)")
    check(not f:IsEventRegistered("EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED"), "  unregisters the owner")
    rawset(_G, "GameEvent", realGameEvent)
end

------------------------------------------------------------------------------
-- Opt-in extras: dynamicPitch, pitchLimit, viewBlendStyle; and salute.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    local before = snapshot()
    local SC = lib:New({ owner = "PortalRoulette", dynamicPitch = true, pitchLimit = 1, viewBlendStyle = 2,
                         salute = true })
    SC:Enter()
    eq(WoW.cvars.test_cameraDynamicPitch, "1", "dynamicPitch")
    eq(WoW.camera.pitchlimit, 1, "pitchLimit")
    eq(WoW.cvars.cameraViewBlendStyle, "2", "viewBlendStyle")
    eq(WoW.popupShown, 0, "no popup for the test_ pitch write either")
    WoW.tick(0.1, 16)
    check(hasCall("DoEmote(SALUTE)"), "salute once settled")
    SC:ForceRestore()
    local same, which = sameCVars(before, WoW.cvars)
    check(same, "all restored: " .. tostring(which))
    eq(WoW.camera.pitchlimit, 88, "pitchlimit back to 88")

    -- Off by default: none of them written.
    lib = freshLibrary()
    lib:New({ owner = "A" }):Enter()
    check(not hasCall("SetCVar(test_cameraDynamicPitch") and not hasCall("ConsoleExec")
          and not hasCall("SetCVar(cameraViewBlendStyle") and not hasCall("DoEmote"),
          "the extras are opt-in")
end

------------------------------------------------------------------------------
-- castAware: a cast puts the presentation view back and holds; its end
-- resumes the orbit.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    local SC = lib:New({ owner = "PortalRoulette", castAware = true })
    SC:Enter()
    check(lib.eventFrame:IsEventRegistered("UNIT_SPELLCAST_START"), "cast events registered while presenting")
    WoW.tick(0.1, 16)
    eq(WoW.camera.savedViews[4], WoW.camera.zoom, "the settled view is saved in slot 4")
    check(WoW.camera.yaw ~= nil, "orbiting")
    WoW.fire("UNIT_SPELLCAST_START", "target")
    check(WoW.camera.yaw ~= nil, "another unit's cast changes nothing")
    WoW.fire("UNIT_SPELLCAST_START", "player")
    eq(WoW.camera.view, 4, "a cast returns to the presentation view")
    eq(WoW.camera.yaw, nil, "and holds still")
    eq(lib.state.cam.mode, "castHold", "")
    WoW.fire("UNIT_SPELLCAST_STOP", "player")
    eq(WoW.camera.yaw, -0.005, "its end resumes the orbit")

    -- Without a saved presentation view: a short reset swing, then hold.
    lib.state.cam.presentationViewSaved = false
    WoW.fire("UNIT_SPELLCAST_CHANNEL_START", "player")
    eq(lib.state.cam.mode, "castReset", "no saved view: a reset swing")
    WoW.fire("UNIT_SPELLCAST_CHANNEL_STOP", "player")
    eq(lib.state.cam.mode, "castReset", "a stop during the swing waits for it")
    WoW.tick(0.1, 5)
    eq(WoW.camera.yaw, -0.005, "  then resumes the orbit")
    SC:ForceRestore()
    check(not lib.eventFrame:IsEventRegistered("UNIT_SPELLCAST_START"), "cast events dropped on restore")

    -- A client without RegisterUnitEvent: plain events, filtered by unit here.
    lib = freshLibrary()
    rawset(lib.eventFrame, "RegisterUnitEvent", false)
    SC = lib:New({ owner = "PortalRoulette", castAware = true })
    SC:Enter()
    WoW.tick(0.1, 16)
    WoW.fire("UNIT_SPELLCAST_START", "target")
    eq(WoW.camera.yaw, -0.005, "without RegisterUnitEvent another unit's cast is still ignored")
    SC:ForceRestore()

    lib = freshLibrary()
    lib:New({ owner = "A" }):Enter()
    check(not lib.eventFrame:IsEventRegistered("UNIT_SPELLCAST_START"), "not registered without castAware")
end

------------------------------------------------------------------------------
-- Options: validated in New, clamped at Enter, live in inst.opts.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    check(not pcall(lib.New, lib, { owner = "A", zoomm = 2 }), "an unknown option errors")
    check(not pcall(lib.New, lib, { owner = "A", zoom = "2" }), "a wrong type errors")
    check(not pcall(lib.New, lib, {}), "owner is required")
    check(pcall(lib.New, lib, { owner = "A", onGameUIShown = function() end }), "onGameUIShown takes a function")
    check(not pcall(lib.New, lib, { owner = "A", onGameUIShown = true }), "  and nothing else")
    check(not pcall(lib.New, { owner = "A" }), "a dot call errors")
    local SC = lib:New({ owner = "A", zoom = 99, savedViewSlot = 9, enterDuration = 0 })
    SC:Enter()
    eq(WoW.camera.zoom, 18, "zoom clamped to 18")
    eq(WoW.camera.savedViews[5] ~= nil, true, "savedViewSlot clamped to 5")
    eq(lib.state.cam.cfg.enterDuration, 0.35, "enterDuration clamped")
    SC:ForceRestore()
    SC.opts.zoom = 3
    SC:Enter()
    eq(WoW.camera.zoom, 3, "an option changed between presentations is read at the next Enter")
    SC:ForceRestore()
    check(not pcall(SC.Enter, nil), "a dot-called method errors")
end

done("test_presentation")
