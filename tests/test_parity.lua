-- Behaviour parity: the library does exactly what AltStable's original block
-- did (frozen as tests/fixtures/altstable_camera.lua, SheetUI.lua:196-911 @
-- 5297196), for the same configuration.
--
-- Each scenario runs twice, in a fresh client each time: once through the
-- frozen block (configured through AltStableConfig, as AltStable did) and once
-- through the library (configured through New's options, mapped the way
-- AltStable's adapter maps them). Compared: every camera, CVar and UI call in
-- order with its arguments (SetCVar, SetView, SaveView, CameraZoomIn/Out,
-- MoveView*, SetUIVisibility, DoEmote, ConsoleExec), every SetParent /
-- SetScale / SetFrameStrata on the window and GameTooltip, and the end state.
--
-- Not compared, on purpose (deliberate changes, tested elsewhere):
-- - the experimental-popup suppression (the library uses
--   GameEvent.UnregisterInternalEvent, which the block did not have);
-- - SetFrameLevel on a drop (the library restores the level it recorded).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local IGNORED = { UnregisterInternalEvent = true, RegisterInternalEvent = true }
local FRAME_CALLS = { SetParent = true, SetScale = true, SetFrameStrata = true }

-- AltStable's defaults (Config.lua EnsureConfigDefaults, camera part).
local DEFAULTS = {
    enableWorldCameraPresentation = true,
    worldCameraEnterDuration = 1.50, worldCameraExitDuration = 0.45,
    worldCameraZoomPreset = 2.2, worldCameraShoulderZoomReference = 6.2,
    worldCameraMountedZoomPreset = 8.0, worldCameraMountedShoulderOffset = 8.0,
    worldCameraForceMountedPresentation = false, worldCameraYawOffset = -0.22,
    worldCameraYawDegrees = 430, worldCameraSavedViewSlot = 5, worldCameraShoulderMult = 1.0,
    worldCameraContinuousOrbit = true, worldCameraOrbitSpeed = 0.005, enableWorldCameraSalute = false,
}
local function config(over)
    local c = {}
    for k, v in pairs(DEFAULTS) do c[k] = v end
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end

-- The mapping AltStable's adapter makes (same fallbacks as the block's
-- _GetConfig).
local function optsFrom(c)
    return {
        enterDuration = tonumber(c.worldCameraEnterDuration),
        exitDuration = tonumber(c.worldCameraExitDuration),
        zoom = tonumber(c.worldCameraZoomPreset),
        shoulderRef = tonumber(c.worldCameraShoulderZoomReference) or 6.2,
        mountedZoom = tonumber(c.worldCameraMountedZoomPreset),
        mountedShoulder = tonumber(c.worldCameraMountedShoulderOffset) or 8.0,
        forceMounted = c.worldCameraForceMountedPresentation == true,
        yawOffset = tonumber(c.worldCameraYawOffset),
        yawDegrees = tonumber(c.worldCameraYawDegrees),
        savedViewSlot = tonumber(c.worldCameraSavedViewSlot),
        shoulderMult = tonumber(c.worldCameraShoulderMult) or 1.0,
        orbit = c.worldCameraContinuousOrbit == true,
        orbitSpeed = tonumber(c.worldCameraOrbitSpeed),
        hideUI = c.hideGameUIOnPresentation ~= false,
        salute = c.enableWorldCameraSalute == true,
    }
end

-- A recording of one run.
local function record(win)
    local calls = {}
    for _, c in ipairs(WoW.calls) do
        if not IGNORED[c:match("^(%w+)")] then calls[#calls + 1] = c end
    end
    local function frameCalls(w)
        local t = {}
        for _, call in ipairs(w._log) do
            if FRAME_CALLS[call[1]] then
                local args = {}
                for j = 1, call.n do
                    local v = call[j + 1]
                    args[j] = v == UIParent and "UIParent" or tostring(v)
                end
                t[#t + 1] = call[1] .. "(" .. table.concat(args, ", ") .. ")"
            end
        end
        return t
    end
    local cv = {}
    for k, v in pairs(WoW.cvars) do cv[#cv + 1] = k .. "=" .. v end
    table.sort(cv)
    return {
        calls = calls, win = frameCalls(win), tip = frameCalls(GameTooltip),
        final = table.concat(cv, " ") .. " zoom=" .. tostring(WoW.camera.zoom) .. " view=" .. tostring(WoW.camera.view)
            .. " yaw=" .. tostring(WoW.camera.yaw) .. " ui=" .. tostring(UIParent._shown)
            .. " winParent=" .. tostring(win._parent == UIParent and "UIParent" or win._parent)
            .. " winStrata=" .. win._strata .. " tipParent=" .. tostring(GameTooltip._parent == UIParent),
    }
end

local function setup(env)
    WoW.reset()
    WoW.resetLibStub()
    if env.mounted then WoW.mounted = true end
    if env.race then WoW.race = env.race end
    for k, v in pairs(env.cvars or {}) do WoW.cvars[k] = v ~= false and v or nil end
end

-- The verbs a scenario uses, for either implementation.
local function runFixture(env, scenario)
    setup(env)
    rawset(_G, "AltStable", { API = { FramesRegisteredForEvent = function(ev)
        return { GetFramesRegisteredForEvent(ev) }
    end } })
    rawset(_G, "AltStableConfig", config(env.config))
    local Cam = assert(loadfile("tests/fixtures/altstable_camera.lua"))()
    local win = newWindow("HIGH")
    Cam.sheetFrame = win
    win:SetScript("OnHide", function() Cam:Exit("sheet-hide") end)
    WoW.calls = {}
    scenario({
        enter = function() Cam:Enter() end,
        exit = function() Cam:Exit("sheet-hide") end,
        force = function() Cam:ForceRestore("test") end,
    })
    rawset(_G, "AltStable", nil)
    rawset(_G, "AltStableConfig", nil)
    return record(win)
end

local function runLibrary(env, scenario)
    setup(env)
    local lib = loadCopy(copyOf(), "AltStable")
    local win = newWindow("HIGH")
    local opts = optsFrom(config(env.config))
    opts.owner = "AltStable"
    opts.onForcedExit = function(reason) if reason == "ui-shown" then win:Hide() end end
    local SC = lib:New(opts)
    win:SetScript("OnHide", function() SC:Exit("sheet-hide") end)
    WoW.calls = {}
    scenario({
        enter = function() SC:Enter(win) end,
        exit = function() SC:Exit("sheet-hide") end,
        force = function() SC:ForceRestore("test") end,
    })
    return record(win), lib
end

local function compare(name, env, scenario)
    local a = runFixture(env, scenario)
    local b, lib = runLibrary(env, scenario)
    local function list(label, x, y)
        local n = math.max(#x, #y)
        for i = 1, n do
            if x[i] ~= y[i] then
                check(false, string.format("%s: %s #%d: AltStable %s, library %s", name, label, i,
                    tostring(x[i]), tostring(y[i])))
                return
            end
        end
        check(true, name .. ": " .. label)
    end
    check(#a.calls > 5, name .. ": the scenario made calls (" .. #a.calls .. ")")
    list("camera/CVar/UI calls", a.calls, b.calls)
    list("window calls", a.win, b.win)
    list("GameTooltip calls", a.tip, b.tip)
    eq(b.final, a.final, name .. ": end state")
    return a, b, lib
end

------------------------------------------------------------------------------
-- Scenarios
------------------------------------------------------------------------------

local function openSettleClose(v)
    v.enter(); WoW.tick(0.1, 20); v.exit(); WoW.tick(0.1, 6)
end

local a, b = compare("defaults: open, settle, close", {}, openSettleClose)
check(a.final:find("CameraKeepCharacterCentered=1", 1, true), "  (the run ends restored)")

compare("orbit off, salute on, mounted", {
    mounted = true,
    config = { worldCameraContinuousOrbit = false, enableWorldCameraSalute = true },
}, openSettleClose)

compare("UI left up, Tauren, odd and out-of-range values", {
    race = { "Tauren", "Tauren", 6 },
    config = { hideGameUIOnPresentation = false, worldCameraZoomPreset = 30, worldCameraYawDegrees = 10,
               worldCameraSavedViewSlot = 3, worldCameraEnterDuration = 0.6, worldCameraShoulderMult = 1.5,
               worldCameraYawOffset = 0.5, worldCameraExitDuration = 9, worldCameraOrbitSpeed = 0.2 },
}, openSettleClose)

compare("forced mounted with its own offset", {
    config = { worldCameraForceMountedPresentation = true, worldCameraMountedShoulderOffset = 3,
               worldCameraMountedZoomPreset = 11 },
}, openSettleClose)

compare("non-numeric config values fall back", {
    config = { worldCameraZoomPreset = "x", worldCameraYawDegrees = "y", worldCameraShoulderZoomReference = "z" },
}, openSettleClose)

compare("re-entered during the exit animation", {}, function(v)
    v.enter(); WoW.tick(0.1, 5); v.exit(); WoW.tick(0.1, 1); v.enter(); WoW.tick(0.1, 20); v.force()
end)

compare("combat mid-swing", {}, function(v)
    v.enter(); WoW.tick(0.1, 3); WoW.enterCombat(); WoW.tick(0.1, 10); WoW.leaveCombat()
end)

compare("loading screen mid-orbit", {}, function(v)
    v.enter(); WoW.tick(0.1, 20); WoW.fire("PLAYER_ENTERING_WORLD"); WoW.tick(0.1, 5)
end)

compare("Escape with the UI hidden", {}, function(v)
    v.enter(); WoW.tick(0.1, 2); SetUIVisibility(true); WoW.tick(0.1, 10)
end)

compare("a client without the centring CVars", {
    cvars = { CameraKeepCharacterCentered = false, CameraReduceUnexpectedMovement = false },
}, openSettleClose)

compare("closed mid-swing", {}, function(v)
    v.enter(); WoW.tick(0.1, 4); v.exit(); WoW.tick(0.1, 10)
end)

done("test_parity")
