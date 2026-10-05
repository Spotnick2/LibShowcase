-- What happens when several addons embed the library: the newest copy loaded
-- wins, and it may not be yours.
--
-- r1 has no released predecessor, so the newer copy here is SYNTHETIC: this
-- checkout with MINOR + 1, a new option (and its type), a new method, a
-- changed default, and every lib.impl function wrapped to count its calls.
-- Instances, methods, the SetUIVisibility and StaticPopup hooks, the event and
-- OnUpdate scripts and pending C_Timer callbacks made by the current copy
-- must run the newer copy's code afterwards, exactly once, and the upgrade
-- must touch no frame and make no camera call. From r2 on, the released r1 is
-- frozen as tests/fixtures/LibShowcase-r1.lua and loaded under the current
-- copy as well.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local MAJOR = "LibShowcase-1.0"
local N = currentMinor()
check(N ~= nil, "LibShowcase.lua declares its MINOR")
local function activeMinor() return select(2, LibStub:GetLibrary(MAJOR)) end

local NEWER = synthetic(N + 1, [[
LIBSHOWCASE_MARK = {}
function lib.impl.Probe(inst) return "probe:" .. tostring(inst.opts.probeOpt) end
for name, f in pairs(lib.impl) do
    lib.impl[name] = function(...)
        LIBSHOWCASE_MARK[name] = (LIBSHOWCASE_MARK[name] or 0) + 1
        return f(...)
    end
end]], {
    { "    salute = false,\n})", "    salute = false,\n    probeOpt = 7,\n})" },
    { "    zoom = 2.2,\n", "    zoom = 3.3,\n" },
    { 'debug = "boolean|function",', 'debug = "boolean|function", probeOpt = "number",' },
    { '"LiftPopup", "DropPopup",\n})', '"LiftPopup", "DropPopup", "Probe",\n})' },
})
local function mark(name) return (rawget(_G, "LIBSHOWCASE_MARK") or {})[name] or 0 end

-- Every widget's call log size: an upgrade must add none.
local function logSizes(widgets)
    local t = {}
    for i, w in ipairs(widgets) do t[i] = #w._log end
    return t
end
local function allWidgets(extra)
    local t = { UIParent, WorldFrame, GameTooltip }
    for _, w in ipairs(WoW.frames) do t[#t + 1] = w end
    for _, w in ipairs(extra or {}) do t[#t + 1] = w end
    return t
end

------------------------------------------------------------------------------
-- The same version twice: the second load changes nothing.
------------------------------------------------------------------------------
do
    local lib = freshLibrary("AltStable")
    local A = lib:New({ owner = "AltStable" })
    local impl, enter, method, hook = lib.impl, lib.impl.Enter, lib.methods.Enter, SetUIVisibility
    local dialogHook, specialHook = StaticPopup_Show, StaticPopupSpecial_Show
    local frames = #WoW.frames
    loadCopy(copyOf(), "PortalRoulette")
    eq(LibStub(MAJOR), lib, "equal-after-equal keeps the library table")
    eq(lib.impl, impl, "and lib.impl")
    eq(lib.impl.Enter, enter, "and its functions")
    eq(lib.methods.Enter, method, "and the methods")
    eq(SetUIVisibility, hook, "the hook is not installed twice")
    eq(StaticPopup_Show, dialogHook, "nor the StaticPopup_Show hook")
    eq(StaticPopupSpecial_Show, specialHook, "nor the StaticPopupSpecial_Show hook")
    eq(#WoW.frames, frames, "no frame created")
    eq(#lib.instances, 1, "no instance added or lost")
    check(A:Enter(), "an instance still works")
    A:ForceRestore()
end

------------------------------------------------------------------------------
-- A newer copy over this one, mid-presentation.
------------------------------------------------------------------------------
do
    rawset(_G, "LIBSHOWCASE_MARK", nil)
    local lib = freshLibrary("AltStable")
    local A = lib:New({ owner = "AltStable", zoom = 5 })
    local B = lib:New({ owner = "Other" })
    local win = newWindow()
    check(A:Enter(win), "A presents")
    -- A pending timer from the current copy: a popup re-register queued by
    -- an earlier restore (B's Acquire/Release would be refused; use a
    -- suppression state the timer will act on).
    lib.state.popupSuppressed = "gameevent"
    local cam = lib.state.cam
    cam.active = false
    lib.impl.UnsuppressPopupSoon()
    cam.active = true
    eq(#WoW.timers, 1, "a C_Timer callback from the current copy is pending")

    local held = {
        lib = lib, impl = lib.impl, methods = lib.methods, instances = lib.instances, state = lib.state,
        cam = lib.state.cam, lifts = lib.state.lifts, CENTRING = lib.CENTRING_CVARS,
        FACTORS = lib.SHOULDER_FACTORS, human = lib.SHOULDER_FACTORS[1], RACE_IDS = lib.RACE_IDS,
        animFrame = lib.animFrame, eventFrame = lib.eventFrame, enter = A.Enter, opts = A.opts,
        hook = SetUIVisibility, suppress = lib.SuppressExperimentalCVarPopup, shoulder = lib.ShoulderOffsetFor,
        mt = lib.instanceMT, dialogHook = StaticPopup_Show, specialHook = StaticPopupSpecial_Show,
    }
    local widgets = allWidgets({ win })
    local before, calls = logSizes(widgets), #WoW.calls
    local frames = #WoW.frames

    loadCopy(NEWER, "PortalRoulette")

    eq(activeMinor(), N + 1, "the newer copy is active")
    eq(lib.ready, N + 1, "and finished loading")
    eq(LibStub(MAJOR), held.lib, "the same library table")
    for _, k in ipairs({ "impl", "methods", "instances", "state" }) do
        eq(lib[k], held[k], "lib." .. k .. " keeps its identity")
    end
    eq(lib.state.cam, held.cam, "the camera state too")
    eq(lib.state.lifts, held.lifts, "and the lift records")
    check(lib.CENTRING_CVARS == held.CENTRING and lib.SHOULDER_FACTORS == held.FACTORS
          and lib.SHOULDER_FACTORS[1] == held.human and lib.RACE_IDS == held.RACE_IDS,
          "public tables filled in place")
    eq(lib.instanceMT, held.mt, "the instance metatable too")
    eq(lib.SuppressExperimentalCVarPopup, held.suppress, "lib.SuppressExperimentalCVarPopup is the same function")
    eq(lib.ShoulderOffsetFor, held.shoulder, "lib.ShoulderOffsetFor too")
    eq(lib.animFrame, held.animFrame, "the OnUpdate frame is reused")
    eq(lib.eventFrame, held.eventFrame, "and the event frame")
    eq(#WoW.frames, frames, "no frame created")
    eq(SetUIVisibility, held.hook, "the SetUIVisibility hook is not installed again")
    check(StaticPopup_Show == held.dialogHook and StaticPopupSpecial_Show == held.specialHook,
          "nor the StaticPopup hooks")

    -- Never touches anything.
    local after = logSizes(widgets)
    local touched = 0
    for i, n in ipairs(before) do if after[i] ~= n then touched = touched + 1 end end
    eq(touched, 0, "the upgrade made no call on any widget")
    eq(#WoW.calls, calls, "and no camera, CVar or UI call")
    check(A:IsActive() and not UIParent:IsShown() and win:GetParent() == nil,
          "the running presentation is untouched")

    -- Narrow migration.
    eq(A.opts, held.opts, "opts keeps its identity")
    eq(A.opts.probeOpt, 7, "a missing option is filled")
    eq(B.opts.probeOpt, 7, "on every instance")
    eq(A.opts.zoom, 5, "an addon's own value is kept")
    eq(B.opts.zoom, 2.2, "an older default is kept, not replaced by the new one")
    local okProbe, probe = pcall(function() return A:Probe() end)
    check(okProbe and probe == "probe:7", "a new method reaches old instances: " .. tostring(probe))
    local C = lib:New({ owner = "Third", probeOpt = 1 })
    eq(C.opts.zoom, 3.3, "a new instance takes the new defaults")
    eq(C.opts.probeOpt, 1, "and the new option validates")

    -- Old closures run the new code, once each.
    eq(A.Enter, held.enter, "a method keeps its identity")
    local n0 = mark("Exit")
    -- The pending timer.
    local u0 = mark("UnsuppressPopup")
    WoW.flushTimers()
    eq(mark("UnsuppressPopup"), u0 + 1, "a C_Timer callback from the older copy runs the newer code, once")
    -- The OnUpdate script.
    local o0 = mark("OnUpdate")
    WoW.tick(0.1, 1)
    eq(mark("OnUpdate"), o0 + 1, "the OnUpdate script runs the newer code, once per frame")
    -- The event script.
    local e0 = mark("OnEvent")
    WoW.fire("PLAYER_LOGIN")                -- (heals nothing while presenting)
    eq(mark("OnEvent"), e0 + 1, "the event script runs the newer code, once")
    check(A:IsActive(), "  and leaves the presentation alone")
    -- The SetUIVisibility hook: an unchanged-state call reaches it too.
    local h0 = mark("OnSetUIVisibility")
    SetUIVisibility(false)
    eq(mark("OnSetUIVisibility"), h0 + 1, "the SetUIVisibility hook runs the newer code, once (and returns early)")
    SetUIVisibility(true)
    -- Escape: the hook once, plus once more for the library's own re-show
    -- inside it (one hook run per SetUIVisibility call, never two).
    eq(mark("OnSetUIVisibility"), h0 + 3, "  and on Escape")
    eq(mark("Exit"), n0 + 1, "  which exits through the newer copy")
    WoW.tick(0.1, 10)
    check(not A:IsOwner(), "the presentation finishes under the newer copy")
    eq(WoW.cvars.CameraKeepCharacterCentered, "1", "and restores what the older copy changed")
    -- The StaticPopup hooks the older copy installed.
    A:Enter(win)
    local s0, r0 = mark("OnStaticPopupShow"), mark("RevealForDialog")
    local d = StaticPopup_Show("PARTY_INVITE")
    eq(mark("OnStaticPopupShow"), s0 + 1, "the StaticPopup_Show hook runs the newer code, once")
    eq(mark("RevealForDialog"), r0 + 1, "  and reveals the UI through it")
    check(UIParent:IsShown() and A:IsActive(), "  the UI is back, the presentation goes on")
    eq(#d._log, 0, "  the dialog untouched")
    local sp0 = mark("OnStaticPopupSpecialShow")
    StaticPopupSpecial_Show(CreateFrame("Frame", nil, UIParent))
    eq(mark("OnStaticPopupSpecialShow"), sp0 + 1, "the StaticPopupSpecial_Show hook runs the newer code, once")
    A:ForceRestore()
end

------------------------------------------------------------------------------
-- An older copy loading second is a no-op.
------------------------------------------------------------------------------
do
    WoW.reset(); WoW.resetLibStub()
    local lib = loadCopy(NEWER, "PortalRoulette")
    local A = lib:New({ owner = "A" })
    local fns = {}
    for k, v in pairs(lib.impl) do fns[k] = v end
    local defaults = lib.defaults.opts.zoom
    loadCopy(copyOf(), "AltStable")
    eq(activeMinor(), N + 1, "the newer copy stays active")
    eq(lib.ready, N + 1, "and its marker")
    eq(lib.defaults.opts.zoom, defaults, "and its defaults")
    local same = true
    for k, v in pairs(fns) do if lib.impl[k] ~= v then same = false end end
    for k in pairs(lib.impl) do if fns[k] == nil then same = false end end
    check(same, "and every impl function")
    eq(A.opts.zoom, 3.3, "its instance untouched")
    eq(#lib.instances, 1, "no instance added")
    check(pcall(lib.New, lib, { owner = "B" }), "New still works")
end

------------------------------------------------------------------------------
-- A newer copy that throws partway: New refuses the half-loaded library.
------------------------------------------------------------------------------
do
    local lib = freshLibrary("AltStable")
    local A = lib:New({ owner = "A" })
    local BROKEN = synthetic(N + 1, nil, {
        { "lib.hooked = lib.hooked or {}", "error(\"synthetic failure mid-load\")\nlib.hooked = lib.hooked or {}" },
    })
    local ok, err = pcall(loadCopy, BROKEN, "PortalRoulette")
    check(not ok and tostring(err):find("synthetic failure mid-load", 1, true), "the broken copy threw")
    eq(activeMinor(), N + 1, "LibStub already counts it as active")
    eq(lib.ready, N, "but the marker is still the older copy's")
    local okNew, errNew = pcall(lib.New, lib, { owner = "B" })
    check(not okNew, "New fails loudly")
    check(tostring(errNew):find("did not finish loading", 1, true), "saying why: " .. tostring(errNew))
    check(A:Enter(), "an instance made earlier still presents")
    A:ForceRestore()
end

------------------------------------------------------------------------------
-- The completion marker is the last line.
------------------------------------------------------------------------------
local src = readFile("LibShowcase.lua")
check(src:gsub("\r\n", "\n"):match("\nlib%.ready = MINOR%s*$"), "lib.ready = MINOR is the last line of LibShowcase.lua")

done("test_upgrade")
