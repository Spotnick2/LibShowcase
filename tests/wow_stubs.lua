-- wow_stubs.lua: a minimal WoW: Forever mock for LibShowcase's Lua 5.1 tests.
-- dofile("tests/wow_stubs.lua") FIRST in every test; drive it via the WoW table.
--
-- What it models, on purpose:
-- - STRICT globals: reading any global it does not define is an error. Each
--   stub is a name confirmed in the API dump (forever-api-1.60.1.70205.md);
--   defining something Forever lacks is how a missing API survives into a
--   build. UnitBuff and NUM_CHAT_WINDOWS are NOT in the dump, so they read as
--   nil (AltStable's frozen block reads them).
-- - The CAMERA and CVARS as plain state, and every global call that changes
--   them logged IN ORDER (WoW.calls), so test_parity can compare AltStable's
--   block with the library call for call.
-- - SetUIVisibility hides UIParent, and visibility walks the parent chain: a
--   frame under a hidden UIParent is not visible and its OnUpdate does not run.
-- - COMBAT: InCombatLockdown() is FALSE inside PLAYER_REGEN_DISABLED (MEASURED
--   70205) and true after it. A PROTECTED frame refuses SetParent, SetScale,
--   Show and Hide in combat (WoW.blocked records the attempt, as the client's
--   ADDON_ACTION_BLOCKED would).
-- - The experimental-CVar popup: a test_* write while the internal event is
--   registered "shows" it (WoW.popupShown).
-- - Blizzard_StaticPopup: StaticPopup_Show, StaticPopupSpecial_Show and
--   StaticPopup_ForEachShownDialog over a pool of dialog frames, fresh each
--   reset (as SetUIVisibility is), so a hook from an earlier load is gone.
-- - Every widget method called is recorded (WoW.methodsCalled) for
--   test_methods.lua, and logged per widget with its arguments (w._log).

WoW = {}
WoW.DUMP = os.getenv("LIBSHOWCASE_API_DUMP") or "C:/Projects/References/forever-api-1.60.1.70205.md"

local POPUP_EVENT = "EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED"

--------------------------------------------------------------------------------
-- Widgets
--------------------------------------------------------------------------------

local Methods = {}

local widgetMT = {
    __index = function(w, k)
        if type(k) ~= "string" or not k:match("^%u") then return nil end   -- fields read as nil
        return function(self, ...)
            WoW.methodsCalled[self._type .. ":" .. k] = true
            table.insert(self._log, { k, n = select("#", ...), ... })
            local impl = Methods[k]
            if impl then return impl(self, ...) end
            return nil
        end
    end,
}

local function newWidget(wtype, parent, name)
    local w = setmetatable({ _type = wtype, _parent = parent, _shown = true, _points = {}, _log = {},
                             _scale = 1, _strata = "MEDIUM", _level = 1, _scripts = {}, _events = {},
                             _name = name }, widgetMT)
    return w
end

local function visible(w)
    while w do
        if not w._shown then return false end
        w = w._parent
    end
    return true
end

local function blocked(w, what)
    if WoW.inCombat and w._protected then
        table.insert(WoW.blocked, what)
        error("ADDON_ACTION_BLOCKED: " .. what .. " on a protected frame in combat", 3)
    end
end

local function fire(w, script, ...)
    local fn = w._scripts[script]
    if fn then fn(w, ...) end
end

-- Visibility changes fire OnShow/OnHide on the frame and its shown children,
-- as the client does (only on an actual change).
local function setVisible(w, before)
    local now = visible(w)
    if before and not now then fire(w, "OnHide") elseif now and not before then fire(w, "OnShow") end
end

function CreateFrame(ftype, name, parent, template)
    local w = newWidget(ftype, parent, name)
    w._template = template
    table.insert(WoW.frames, w)
    if name then rawset(_G, name, w) end
    return w
end

function Methods.Show(w) blocked(w, "Show"); local b = visible(w); w._shown = true; setVisible(w, b) end
function Methods.Hide(w) blocked(w, "Hide"); local b = visible(w); w._shown = false; setVisible(w, b) end
function Methods.IsShown(w) return w._shown end
function Methods.IsVisible(w) return visible(w) end
-- Reparenting moves the frame level to just above the new parent's, as the
-- client does for a frame without a fixed level.
function Methods.SetParent(w, p)
    blocked(w, "SetParent")
    local b = visible(w)
    w._parent = p
    w._level = (p and p._level or 0) + 1
    setVisible(w, b)
end
function Methods.GetParent(w) return w._parent end
function Methods.SetScale(w, s) blocked(w, "SetScale"); w._scale = s end
function Methods.GetScale(w) return w._scale end
function Methods.GetEffectiveScale(w)
    local s, p = w._scale, w._parent
    while p do s = s * p._scale; p = p._parent end
    return s
end
function Methods.SetFrameStrata(w, s) w._strata = s end
function Methods.GetFrameStrata(w) return w._strata end
function Methods.SetFrameLevel(w, l) w._level = l end
function Methods.GetFrameLevel(w) return w._level end
function Methods.SetPoint(w, ...) table.insert(w._points, { ... }) end
function Methods.ClearAllPoints(w) w._points = {} end
function Methods.GetNumPoints(w) return #w._points end
function Methods.GetPoint(w, i) local p = w._points[i or 1]; if p then return unpack(p) end end
function Methods.IsProtected(w) return w._protected == true, false end
function Methods.SetScript(w, script, fn) w._scripts[script] = fn end
function Methods.GetScript(w, script) return w._scripts[script] end
function Methods.HookScript(w, script, fn)
    local prev = w._scripts[script]
    w._scripts[script] = function(...)
        if prev then prev(...) end
        fn(...)
    end
end
function Methods.RegisterEvent(w, ev) w._events[ev] = true end
function Methods.RegisterUnitEvent(w, ev, unit) w._events[ev] = unit or true end
function Methods.UnregisterEvent(w, ev) w._events[ev] = nil end
function Methods.IsEventRegistered(w, ev) return w._events[ev] ~= nil end
function Methods.ClearFocus(w) w._focus = false end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local function log(...)
    local parts = {}
    for i = 2, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    WoW.calls[#WoW.calls + 1] = (select(1, ...)) .. "(" .. table.concat(parts, ", ") .. ")"
end

-- The measured defaults (PortalRoulette FOREVER-PROBE.md, 70205).
WoW.DEFAULT_CVARS = {
    test_cameraOverShoulder = "0",
    test_cameraDynamicPitch = "0",
    CameraKeepCharacterCentered = "1",
    CameraReduceUnexpectedMovement = "0",
    cameraDistanceMaxZoomFactor = "1",
    cameraViewBlendStyle = "1",
    cameraYawMoveSpeed = "180",
}

function WoW.reset()
    WoW.frames = {}
    WoW.methodsCalled = {}
    WoW.calls = {}
    WoW.blocked = {}
    WoW.timers = {}
    WoW.inCombat = false
    WoW.loggedIn = false
    WoW.mounted = false
    WoW.race = { "Human", "Human", 1 }
    WoW.cvars = {}
    for k, v in pairs(WoW.DEFAULT_CVARS) do WoW.cvars[k] = v end
    WoW.camera = { zoom = 4, view = 1, savedViews = {}, yaw = nil, pitchlimit = 88 }
    WoW.internal = { [POPUP_EVENT] = "blizzard" }   -- who handles the popup event
    WoW.popupShown = 0
    WoW.eventFrames = {}                            -- GetFramesRegisteredForEvent's answer
    WoW.chatOut = {}

    UIParent = newWidget("Frame", nil, "UIParent")
    WorldFrame = newWidget("Frame", nil, "WorldFrame")
    GameTooltip = newWidget("GameTooltip", UIParent, "GameTooltip")
    GameTooltip._strata = "TOOLTIP"

    -- A fresh engine function each reset, so hooks from an earlier load don't
    -- stack up across test sections.
    SetUIVisibility = function(v)
        log("SetUIVisibility", v)
        UIParent._shown = v and true or false
    end

    -- Blizzard_StaticPopup (FrameXML, not the engine): a pool of dialogs under
    -- UIParent and the list of shown ones. StaticPopup_SetUpPosition inserts
    -- the dialog into that list BEFORE Show. The stub moves its dialogs by
    -- field, never through a method, so a dialog's _log holds only what an
    -- addon did to it. WoW.refuseDialogs: a show condition says no (nil).
    WoW.dialogs = {}          -- the pool
    WoW.shownDialogs = {}
    WoW.refuseDialogs = false
    StaticPopup_Show = function(which)
        if WoW.refuseDialogs then return nil end
        local d
        for _, x in ipairs(WoW.dialogs) do if not x._shown then d = x; break end end
        if not d then
            d = newWidget("Frame", UIParent, "StaticPopup" .. (#WoW.dialogs + 1))
            d._shown = false
            d._strata = "DIALOG"
            WoW.dialogs[#WoW.dialogs + 1] = d
        end
        d.which = which
        table.insert(WoW.shownDialogs, d)
        d._parent, d._shown = UIParent, true
        return d
    end
    StaticPopupSpecial_Show = function(d)
        d.special = true
        table.insert(WoW.shownDialogs, d)
        d._parent, d._shown = UIParent, true
    end
    StaticPopup_ForEachShownDialog = function(fn)
        for _, d in ipairs(WoW.shownDialogs) do fn(d) end
        return nil
    end
end

-- Close a dialog as Blizzard does (accept, cancel, Escape).
function WoW.closeDialog(d)
    d._shown = false
    for i, x in ipairs(WoW.shownDialogs) do
        if x == d then table.remove(WoW.shownDialogs, i); break end
    end
end

-- A fresh client: no LibStub, so the next load starts the library from scratch.
function WoW.resetLibStub()
    rawset(_G, "LibStub", nil)
end

-- Run every visible frame's OnUpdate `n` times.
function WoW.tick(dt, n)
    for _ = 1, n or 1 do
        for _, w in ipairs(WoW.frames) do
            local fn = w._scripts.OnUpdate
            if fn and visible(w) then fn(w, dt) end
        end
    end
end

-- Fire an event at every frame registered for it.
function WoW.fire(event, ...)
    local unit = ...
    for _, w in ipairs(WoW.frames) do
        local reg = w._events[event]
        if reg and (reg == true or reg == unit) then
            local fn = w._scripts.OnEvent
            if fn then fn(w, event, ...) end
        end
    end
end

-- Combat as the client runs it: REGEN_DISABLED handlers are still unlocked.
function WoW.enterCombat()
    WoW.fire("PLAYER_REGEN_DISABLED")
    WoW.inCombat = true
end
function WoW.leaveCombat()
    WoW.inCombat = false
    WoW.fire("PLAYER_REGEN_ENABLED")
end

function WoW.flushTimers()
    local t = WoW.timers
    WoW.timers = {}
    for _, fn in ipairs(t) do fn() end
end

--------------------------------------------------------------------------------
-- Globals (each confirmed in the API dump)
--------------------------------------------------------------------------------

strmatch = string.match   -- LibStub uses it

function InCombatLockdown() return WoW.inCombat end
function IsLoggedIn() return WoW.loggedIn end
function IsMounted() return WoW.mounted end
function UnitRace(unit) return WoW.race[1], WoW.race[2], WoW.race[3] end

function GetCVar(name) return WoW.cvars[name] end
function SetCVar(name, value)
    log("SetCVar", name, value)
    if name:find("^test_") and WoW.internal[POPUP_EVENT] then WoW.popupShown = WoW.popupShown + 1 end
    WoW.cvars[name] = tostring(value)
    return true
end
function ConsoleExec(cmd)
    log("ConsoleExec", cmd)
    local n = cmd:match("^pitchlimit (%d+)$")
    if n then WoW.camera.pitchlimit = tonumber(n) end
    return true
end

function GetCameraZoom() return WoW.camera.zoom end
function CameraZoomIn(d) log("CameraZoomIn", d); WoW.camera.zoom = math.max(0, WoW.camera.zoom - (d or 1)) end
function CameraZoomOut(d) log("CameraZoomOut", d); WoW.camera.zoom = WoW.camera.zoom + (d or 1) end
function SaveView(slot) log("SaveView", slot); WoW.camera.savedViews[slot] = WoW.camera.zoom end
function SetView(slot) log("SetView", slot); WoW.camera.view = slot end
function MoveViewRightStart(s) log("MoveViewRightStart", s); WoW.camera.yaw = s end
function MoveViewLeftStart(s) log("MoveViewLeftStart", s); WoW.camera.yaw = -s end
function MoveViewRightStop() log("MoveViewRightStop"); WoW.camera.yaw = nil end
function MoveViewLeftStop() log("MoveViewLeftStop"); WoW.camera.yaw = nil end
function DoEmote(e) log("DoEmote", e) end
function ChatEdit_DeactivateChat(eb) log("ChatEdit_DeactivateChat"); eb._shown = false end

-- VARARGS, never a table (AltStable forever-api-notes: the vararg shape).
function GetFramesRegisteredForEvent(event) return unpack(WoW.eventFrames[event] or {}) end

GameEvent = {
    UnregisterInternalEvent = function(ev) log("UnregisterInternalEvent", ev); WoW.internal[ev] = nil end,
    RegisterInternalEvent = function(ev, fn) log("RegisterInternalEvent", ev); WoW.internal[ev] = fn end,
    HandleExperimentalCVarConfirmationNeeded = function() WoW.popupShown = WoW.popupShown + 1 end,
}

C_Timer = { After = function(_, fn) table.insert(WoW.timers, fn) end }

DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(WoW.chatOut, m) end }

-- Post-hook, as the client does: the original runs first. Both forms.
function hooksecurefunc(a, b, c)
    local host, name, fn
    if type(a) == "table" then host, name, fn = a, b, c else host, name, fn = _G, a, b end
    local prev = host[name]
    if type(prev) ~= "function" then error("Attempt to hook a nonexistent function: " .. tostring(name), 2) end
    rawset(host, name, function(...)
        local r = { prev(...) }
        fn(...)
        return unpack(r)
    end)
end

WoW.reset()

-- Strict globals: any read of an undefined global is an error, except the
-- globals legitimately nil before first assignment or absent on this client.
local allowNil = {
    LibStub = true,                       -- the bundled file checks for an earlier copy
    UnitBuff = true, NUM_CHAT_WINDOWS = true,   -- not in the 70205 dump (AltStable's block reads them)
    AltStable = true, AltStableConfig = true,
    LIBSHOWCASE_MARK = true,              -- the synthetic newer copy's call counters
}
setmetatable(_G, { __index = function(_, k)
    if allowNil[k] or (type(k) == "string" and k:match("^ChatFrame%d+EditBox$")) then return nil end
    error("read of undefined global '" .. tostring(k) .. "' (not stubbed: is it in the API dump?)", 2)
end })
