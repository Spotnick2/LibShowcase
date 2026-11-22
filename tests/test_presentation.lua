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
    ticks(0.1, 16)
    eq(WoW.camera.yaw, -0.005, "after the swing: the slow orbit, leftward")
    check(not lib.animFrame:IsShown(), "and the runner stops")

    check(SC:Exit("closed"), "Exit answers true")
    check(UIParent:IsShown(), "Exit gives the UI back at once")
    eq(win:GetParent(), UIParent, "the window back under UIParent")
    eq(win:GetFrameStrata(), "MEDIUM", "  at its own strata")
    eq(win:GetScale(), 1, "  and scale")
    eq(GameTooltip:GetParent(), UIParent, "GameTooltip back")
    eq(WoW.camera.view, 2, "the exit ends on the player's own view, 2 when unknown (#51)")
    check(SC:IsActive(), "the presentation is still winding down")
    ticks(0.1, 5)
    check(not SC:IsActive(), "and ends after exitDuration")
    check(not SC:IsOwner(), "giving the showcase back")
    local same, which = sameCVars(before, WoW.cvars)
    check(same, "every CVar is exactly as found: " .. tostring(which))
    eq(WoW.camera.zoom, 12, "and the zoom")
    eq(WoW.popupShown, 0, "still no popup, the restore write included")
    eq(#WoW.timers, 0, "nothing is scheduled to give the popup back")
    WoW.flushTimers()
    eq(WoW.internal.EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED, nil,
       "the popup stays off (re-registering from addon code taints the dialog pool)")
    check(not hasCall("RegisterInternalEvent"), "RegisterInternalEvent is never called")
    SetCVar("test_cameraOverShoulder", "0")
    eq(WoW.popupShown, 0, "so a later test_* write applies without asking, until /reload")
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
do
    local lib = freshLibrary()
    local SC = lib:New({ owner = "A", castAware = true })
    WoW.cvars.test_cameraOverShoulder = nil
    WoW.cvars.cameraDistanceMaxZoomFactor = nil
    check(SC:Enter(newWindow()), "enters without the shoulder CVar and the zoom cap")
    WoW.fire("UNIT_SPELLCAST_START", "player")      -- a cast reset writes the shoulder again
    eq(WoW.cvars.test_cameraOverShoulder, nil, "  creates no shoulder CVar, a cast reset included")
    eq(WoW.cvars.cameraDistanceMaxZoomFactor, nil, "  nor the zoom cap")
    SC:ForceRestore("test")
    eq(WoW.cvars.test_cameraOverShoulder, nil, "nor on the way out")
    eq(WoW.cvars.cameraDistanceMaxZoomFactor, nil, "  either of them")
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
    ticks(0.1, 30)
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
    WoW.combat = true
    local ok, why = SC:Enter(newWindow())
    check(ok == false and why == "combat", "in combat: false, \"combat\"")
    check(not SC:IsOwner(), "  and no lease taken")
    WoW.combat = false
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
    ticks(0.1, 10)
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
    -- No dump lists it as a frame event (GameEvent's internal event), so
    -- RegisterEvent refuses the name: the registration is set directly.
    f._events.EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED = true
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
    ticks(0.1, 16)
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
    ticks(0.1, 16)
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
    ticks(0.1, 5)
    eq(WoW.camera.yaw, -0.005, "  then resumes the orbit")
    SC:ForceRestore()
    check(not lib.eventFrame:IsEventRegistered("UNIT_SPELLCAST_START"), "cast events dropped on restore")

    -- A client without RegisterUnitEvent: plain events, filtered by unit here.
    lib = freshLibrary()
    rawset(lib.eventFrame, "RegisterUnitEvent", false)
    SC = lib:New({ owner = "PortalRoulette", castAware = true })
    SC:Enter()
    ticks(0.1, 16)
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


------------------------------------------------------------------------------
-- #39: the orbit follows the player's cameraYawMoveSpeed as the turn does.
-- MoveView*Start's speed is a multiple of it, so orbitSpeed is scaled to
-- mean the same speed whatever the setting (the default 180: unchanged).
------------------------------------------------------------------------------
for _, case in ipairs({ { "90", 180 / 90 }, { "180", 1 }, { "360", 180 / 360 }, { "0", 1 }, { "fast", 1 } }) do
    local lib = freshLibrary()
    WoW.cvars.cameraYawMoveSpeed = case[1]
    local SC = lib:New({ owner = "PortalRoulette", castAware = true })
    SC:Enter()
    ticks(0.1, 16)
    local want = -(0.005 * case[2])
    eq(WoW.camera.yaw, want, "cameraYawMoveSpeed " .. case[1] .. ": the settled orbit at orbitSpeed scaled by " .. case[2])
    WoW.fire("UNIT_SPELLCAST_START", "player")
    WoW.fire("UNIT_SPELLCAST_STOP", "player")
    eq(WoW.camera.yaw, want, "  and the orbit a cast's end resumes")
    SC:ForceRestore()
end

-- The setting changed after Enter (Codex, #48): the orbit reads it again when
-- it starts at the end of the entry, and when a cast's end resumes it.
do
    local lib = freshLibrary()
    WoW.cvars.cameraYawMoveSpeed = "90"
    local SC = lib:New({ owner = "PortalRoulette", castAware = true })
    SC:Enter()
    ticks(0.1, 3)
    WoW.cvars.cameraYawMoveSpeed = "180"
    ticks(0.1, 13)
    eq(WoW.camera.yaw, -0.005, "changed to 180 during the entry: the orbit starts at 180's speed, not 90's")
    WoW.fire("UNIT_SPELLCAST_START", "player")
    WoW.cvars.cameraYawMoveSpeed = "360"
    WoW.fire("UNIT_SPELLCAST_STOP", "player")
    eq(WoW.camera.yaw, -0.0025, "changed to 360 during a cast: its end resumes at 360's speed")
    SC:ForceRestore()
    WoW.cvars.cameraYawMoveSpeed = "180"
end


------------------------------------------------------------------------------
-- #38: the female column. ShoulderOffsetFor(race, zoom, mounted, sex): sex 3
-- takes lib.FEMALE_SHOULDER_FACTORS, anything else (or none) the male pair,
-- as before; a race missing from the female table takes its male pair. The
-- player's own offset asks UnitSex("player").
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    eq(lib.ShoulderOffsetFor("Human", 2.1, nil, 3), 2.1 * 0.38 + 0.0311, "female Human: the female pair")
    eq(lib.ShoulderOffsetFor("Human", 2.1, nil, 2), 2.1 * 0.3283 - 0.02, "male Human: the male pair")
    eq(lib.ShoulderOffsetFor("Human", 2.1), 2.1 * 0.3283 - 0.02, "  and without a sex, as before")
    eq(lib.ShoulderOffsetFor(6, 4, nil, 3), 4 * 0.2427 - 0.1867, "female Tauren, by race ID")
    eq(lib.ShoulderOffsetFor("HighOrderSkyborne", 2, nil, 3), 2 * 0.361 - 0.1654, "an unknown race, female: the default")
    -- #59: Forever's Skyborne (95, 96; race file "Skyborne") takes the Blood
    -- Elf pairs: the same models' rig.
    for _, race in ipairs({ 95, 96, "Skyborne" }) do
        eq(lib.ShoulderOffsetFor(race, 2.2, nil, 3), 2.2 * 0.3177 + 0.0683, "Skyborne " .. race .. ", female: the Blood Elf female pair")
        eq(lib.ShoulderOffsetFor(race, 2.2, nil, 2), 2.2 * 0.361 - 0.1654, "  male: the Blood Elf male pair")
    end
    eq(lib.ShoulderOffsetFor(nil, 8, true, 3), 8 * 1.2495 - 4.0, "mounted: one pair for both")
    eq(lib.ShoulderOffsetFor(99, 2, nil, 3), 2 * 0.361 - 0.1654, "an unknown race ID, female: the default")
    eq(lib.ShoulderOffsetFor(99, 2), 2 * 0.361 - 0.1654, "  and male, as before")
    lib.SHOULDER_FACTORS[50] = { 0.1, 0.2 }
    eq(lib.ShoulderOffsetFor(50, 1, nil, 3), 0.1 + 0.2, "a race the female table lacks: its male pair")
    lib.SHOULDER_FACTORS[50] = nil
    eq(lib.FEMALE_SHOULDER_FACTORS[1][1], 0.38, "lib.FEMALE_SHOULDER_FACTORS is public")

    for _, case in ipairs({ { 3, 0.38, 0.0311, "female" }, { 2, 0.3283, -0.02, "male" }, { nil, 0.3283, -0.02, "unknown sex" } }) do
        WoW.sex = case[1]
        local SC = lib:New({ owner = "Sex" .. case[4], shoulderRef = 2.1 })
        SC:Enter()
        local want = 2.1 * case[2] + case[3]
        check(math.abs(tonumber(WoW.cvars.test_cameraOverShoulder) - want) < 1e-9,
              "the player's own offset, " .. case[4] .. " Human: " .. want)
        SC:ForceRestore()
    end
    WoW.sex = 2
end

------------------------------------------------------------------------------
-- #54: gamepad mode holds the centring CVars with temp values; a SetCVar
-- under them lands, unseen, on the player's own (MEASURED 70959). The stub
-- models both layers: WoW.cvars is the stored value, WoW.tempCVars the temp.
------------------------------------------------------------------------------
do
    local function stored() return WoW.cvars.CameraKeepCharacterCentered .. WoW.cvars.CameraReduceUnexpectedMovement end

    -- Entered in gamepad mode: the centring CVars are left alone.
    local lib = freshLibrary()
    local db = {}
    local SC = lib:New({ owner = "A", db = db })
    WoW.cvars.CameraKeepCharacterCentered, WoW.cvars.CameraReduceUnexpectedMovement = "0", "1"   -- the player's own
    WoW.gamepadMode(true)
    check(SC:Enter(), "gamepad mode: Enter presents")
    check(not hasCall("SetCVar(CameraKeepCharacterCentered") and not hasCall("SetCVar(CameraReduceUnexpectedMovement"),
          "  no centring write")
    check(db.LibShowcaseCapture.CameraKeepCharacterCentered == nil and db.LibShowcaseCapture.CameraReduceUnexpectedMovement == nil,
          "  nothing captured for them")
    check(tonumber(WoW.cvars.test_cameraOverShoulder) > 0, "  the shoulder offset still written")
    SC:ForceRestore()
    WoW.gamepadMode(false)
    eq(stored(), "01", "  the player's own values are intact once gamepad mode ends")

    -- Entered on mouse and keyboard, the player switches to gamepad mid-
    -- presentation: the restore writes the captured (stored) values back,
    -- which lands on the stored layer, where they belong.
    WoW.calls = {}
    check(SC:Enter(), "mouse and keyboard: Enter presents")
    eq(stored(), "00", "  centring cleared")
    WoW.gamepadMode(true)
    SC:ForceRestore()
    WoW.gamepadMode(false)
    eq(stored(), "01", "  restored to the player's own, though in gamepad mode at the exit")

    -- The heal, in gamepad mode: the capture is written back. The session
    -- that left it wrote "0" over the stored values (its Enter), so writing
    -- the capture is never worse than leaving that "0".
    db.LibShowcaseCapture = { CameraKeepCharacterCentered = "0", CameraReduceUnexpectedMovement = "1" }
    WoW.cvars.CameraKeepCharacterCentered, WoW.cvars.CameraReduceUnexpectedMovement = "0", "0"
    WoW.gamepadMode(true)
    WoW.fire("PLAYER_LOGIN")
    WoW.gamepadMode(false)
    eq(stored(), "01", "heal in gamepad mode: the capture lands on the stored values")
    eq(db.LibShowcaseCapture, nil, "  and is cleared")
end

------------------------------------------------------------------------------
-- #56: a client (or a consumer's strict mock) without UnitAffectingCombat or
-- UnitSex: the library reads them through rawget, so a presentation still
-- enters (male framing, the lockdown alone for combat) and exits.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    local SC = lib:New({ owner = "A" })
    local affecting, sex = rawget(_G, "UnitAffectingCombat"), rawget(_G, "UnitSex")
    rawset(_G, "UnitAffectingCombat", nil)
    rawset(_G, "UnitSex", nil)
    local ok, entered = pcall(SC.Enter, SC)
    check(ok and entered, "without UnitAffectingCombat and UnitSex, Enter presents: " .. tostring(entered))
    local okExit = pcall(SC.ForceRestore, SC)
    check(okExit and not SC:IsActive(), "  and restores")
    rawset(_G, "UnitAffectingCombat", affecting)
    rawset(_G, "UnitSex", sex)
end

------------------------------------------------------------------------------
-- #51: the view an exit ends on. Ending on the saved view stops the camera
-- following (MEASURED 70959+, viewfix runs #577 to #590): on a style that
-- follows, the exit ends on the player's own view and puts the zoom back; on
-- Never, it snaps back to the saved view and writes cameraView back.
------------------------------------------------------------------------------
local function firstSetView(from)
    for _, c in ipairs(callsSince(from)) do if c:find("^SetView") then return c end end
end
local function present(style, view, slot)
    local lib = freshLibrary()
    WoW.cvars.cameraSmoothStyle, WoW.cvars.cameraView = style, view
    local SC = lib:New({ owner = "A", savedViewSlot = slot })
    WoW.camera.zoom = 12
    check(SC:Enter(newWindow("MEDIUM")), "presenting on style " .. style .. ", view " .. view)
    ticks(0.1, 16)
    return lib, SC
end

for _, style in ipairs({ "1", "2", "4" }) do
    local lib, SC = present(style, "3")
    local from = #WoW.calls
    SC:Exit("closed")
    eq(firstSetView(from), "SetView(3)", "style " .. style .. ": the exit ends on the player's own view at once")
    eq(WoW.camera.zoom, 12, "  and puts the zoom back")
    local mid = #WoW.calls
    ticks(0.1, 6)
    check(not SC:IsActive(), "  the exit completes")
    local again = false
    for _, c in ipairs(callsSince(mid)) do if c:find("^SetView") or c:find("^CameraZoom") then again = true end end
    check(not again, "  with no second SetView or zoom (it would snap the zoom mid-animation)")
    eq(WoW.cvars.cameraView, "3", "  cameraView is the player's")
end

do  -- Stuck on the saved view already (an older copy's exit): the exit ends on 2.
    local lib, SC = present("4", "5")
    SC:Exit("closed"); ticks(0.1, 6)
    eq(WoW.cvars.cameraView, "2", "entered on the saved view: the exit ends on view 2")
end

do  -- A forced restore mid-presentation (combat) also ends on the own view.
    local lib, SC = present("2", "4")
    WoW.enterCombat()
    eq(WoW.cvars.cameraView, "4", "combat mid-presentation: back on the player's own view")
    eq(WoW.camera.zoom, 12, "  at their zoom")
    WoW.leaveCombat()
end

do  -- Never: the exact snap-back, then cameraView written back.
    local lib, SC = present("0", "3")
    local from = #WoW.calls
    SC:Exit("closed")
    eq(firstSetView(from), "SetView(5)", "Never: the exit snaps back to the saved view")
    ticks(0.1, 6)
    eq(WoW.camera.view, 5, "  and stays on its framing")
    eq(WoW.cvars.cameraView, "3", "  with cameraView written back: the next login loads the player's own view")
    check(hasCall("SetCVar(cameraView, 3)"), "  written by SetCVar, not SetView")
end

do  -- A consumer's own savedViewSlot.
    local lib, SC = present("4", "2", 3)
    SC:Exit("closed"); ticks(0.1, 6)
    eq(WoW.cvars.cameraView, "2", "savedViewSlot 3: the exit ends on the player's view 2")
end

------------------------------------------------------------------------------
-- #51: the login repair, once per db, on a style that follows.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    WoW.cvars.cameraSmoothStyle, WoW.cvars.cameraView = "4", "5"
    local DB = {}
    lib:New({ owner = "A", db = function() return DB end })
    WoW.fire("PLAYER_LOGIN")
    eq(WoW.cvars.cameraView, "2", "login on the saved view: back to view 2")
    eq(DB.LibShowcaseViewRepaired, true, "  the db marked")
    eq(lib.VIEW_REPAIR_DB_KEY, "LibShowcaseViewRepaired", "  under the public key")
    WoW.cvars.cameraView = "5"   -- the player chose it again
    WoW.fire("PLAYER_LOGIN")
    eq(WoW.cvars.cameraView, "5", "  never twice")
end

do  -- Never: left alone, and not marked, so a later switch still repairs.
    local lib = freshLibrary()
    WoW.cvars.cameraSmoothStyle, WoW.cvars.cameraView = "0", "5"
    local DB = {}
    lib:New({ owner = "A", db = function() return DB end })
    WoW.fire("PLAYER_LOGIN")
    eq(WoW.cvars.cameraView, "5", "Never at login: left on the saved view")
    eq(DB.LibShowcaseViewRepaired, nil, "  and not marked")
    WoW.cvars.cameraSmoothStyle = "2"
    WoW.fire("PLAYER_LOGIN")
    eq(WoW.cvars.cameraView, "2", "  repaired once the style follows")
end

do  -- Not on the saved view: marked, nothing moved.
    local lib = freshLibrary()
    WoW.cvars.cameraSmoothStyle, WoW.cvars.cameraView = "4", "3"
    local DB = {}
    lib:New({ owner = "A", db = function() return DB end })
    local from = #WoW.calls
    WoW.fire("PLAYER_LOGIN")
    eq(#callsSince(from), 0, "login on the player's own view: nothing called")
    eq(DB.LibShowcaseViewRepaired, true, "  the db marked")
end

do  -- No db: nothing to remember it in, so nothing done.
    local lib = freshLibrary()
    WoW.cvars.cameraSmoothStyle, WoW.cvars.cameraView = "4", "5"
    lib:New({ owner = "A" })
    WoW.fire("PLAYER_LOGIN")
    eq(WoW.cvars.cameraView, "5", "no db: no repair")
end

do  -- An instance created after login repairs at New.
    local lib = freshLibrary()
    WoW.loggedIn = true
    WoW.cvars.cameraSmoothStyle, WoW.cvars.cameraView = "4", "3"
    local DB = {}
    lib:New({ owner = "A", db = DB, savedViewSlot = 3 })
    eq(WoW.cvars.cameraView, "2", "New after login, on its own savedViewSlot 3: back to view 2")
    eq(DB.LibShowcaseViewRepaired, true, "  marked")
end

do  -- Not while another instance presents.
    local lib = freshLibrary()
    WoW.cvars.cameraSmoothStyle, WoW.cvars.cameraView = "4", "2"
    local A = lib:New({ owner = "A" })
    check(A:Enter(newWindow("MEDIUM")), "A presents")
    WoW.cvars.cameraView = "5"
    WoW.loggedIn = true
    local DB = {}
    lib:New({ owner = "B", db = DB })
    eq(DB.LibShowcaseViewRepaired, nil, "B created mid-presentation: no repair, not marked")
    A:ForceRestore()
end

done("test_presentation")
