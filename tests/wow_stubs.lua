-- wow_stubs.lua: LibShowcase's part of the WoW: Forever mock for its Lua 5.1
-- tests. dofile("tests/wow_stubs.lua") FIRST in every test; drive it via the
-- WoW table.
--
-- The mechanics are WowTestKit's core (tests/kit.lua loads it at the commit
-- and build tests/kit.pin names; its README is the reference): strict
-- globals, CreateFrame and the widget method recorder (WoW.methodsCalled,
-- checked by Kit.checkMethods) with each widget's call log (w._log), events
-- checked against the build, OnShow / OnHide, OnUpdate ticks, timers,
-- hooksecurefunc, print, combat lockdown (WoW.combat) and protected frames
-- refusing calls in combat (WoW.blocked). This file adds only what the
-- library and its tests use beyond them, each global confirmed in the API
-- dump. UnitBuff and NUM_CHAT_WINDOWS are NOT in the dump, so they read as
-- nil (AltStable's frozen block reads them).
--
-- What it models, on purpose:
-- - The CAMERA and CVARS as plain state, and every global call that changes
--   them logged IN ORDER (WoW.calls), so test_parity can compare AltStable's
--   block with the library call for call.
-- - SetUIVisibility hides UIParent, and visibility walks the parent chain: a
--   frame under a hidden UIParent is not visible and its OnUpdate does not run.
-- - COMBAT: InCombatLockdown() is FALSE inside PLAYER_REGEN_DISABLED (MEASURED
--   70205) and true after it (WoW.enterCombat / WoW.leaveCombat). A PROTECTED
--   frame refuses SetParent too, besides the kit's WoW.PROTECTED methods.
-- - The experimental-CVar popup: a test_* write while the internal event is
--   registered "shows" it (WoW.popupShown).
-- - Blizzard_StaticPopup: StaticPopup_Show, StaticPopupSpecial_Show and
--   StaticPopup_ForEachShownDialog over a pool of dialog frames, fresh each
--   reset (as SetUIVisibility is), so a hook from an earlier load is gone.

dofile("tests/kit.lua")
local Methods = WoW.Methods

local POPUP_EVENT = "EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED"

--------------------------------------------------------------------------------
-- Widgets: what differs from the kit's core
--------------------------------------------------------------------------------

-- The library lifts frames with SetParent(nil) and never reparents a
-- protected one in combat: the old stub refused it, and so does this one.
WoW.PROTECTED.SetParent = true

-- The core's SetParent is the client's, measured on 70959 (WowTestKit #99):
-- OnShow / OnHide where the move changes visibility, and the level just above
-- the new parent's (0 with none). test_lease's re-entrant drop and the
-- mutation "level not restored" rely on both.

-- A subtree's visibility taken as reported, without its scripts: what
-- SetUIVisibility does to UIParent here, as the old stub did.
local function quiet(w)
    w._vis = Methods.IsVisible(w)
    for _, c in ipairs(w._children or {}) do quiet(c) end
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local playerCall = false   -- WoW.playerSetUIVisibility's call under way

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

table.insert(WoW.onReset, function()
    WoW.calls = {}
    WoW.loggedIn = false
    WoW.mounted = false
    WoW.race = { "Human", "Human", 1 }
    WoW.sex = 2
    WoW.affecting = false
    WoW.tempCVars, WoW.inputStyle = {}, 0
    WoW.cvars = {}
    for k, v in pairs(WoW.DEFAULT_CVARS) do WoW.cvars[k] = v end
    WoW.camera = { zoom = 4, view = 1, savedViews = {}, yaw = nil, pitchlimit = 88 }
    WoW.internal = { [POPUP_EVENT] = "blizzard" }   -- who handles the popup event
    WoW.popupShown = 0
    WoW.eventFrames = {}                            -- GetFramesRegisteredForEvent's answer
    WoW.now = 1000                                  -- GetTime(); WoW.tick and WoW.advance move it
    -- Prompts the client reports open, whatever events the library saw:
    -- readyCheck = { status = "waiting", left = 30 }; lootRolls = { [rollID] = ms left }.
    WoW.readyCheck, WoW.lfgProposal, WoW.roleCheck, WoW.lootRolls = nil, false, false, {}

    -- A fresh UIParent each reset, as the old stub had: an earlier section's
    -- hidden UI or lifted frames don't carry over.
    UIParent = WoW.newWidget("Frame", nil, "UIParent")
    UIParent._level = 0
    WorldFrame = WoW.newWidget("Frame", nil, "WorldFrame")
    GameTooltip = WoW.newWidget("GameTooltip", UIParent, "GameTooltip")
    GameTooltip._strata = "TOOLTIP"

    -- A fresh engine function each reset, so hooks from an earlier load don't
    -- stack up across test sections.
    -- From addon code it is BLOCKED in a lockdown (MEASURED 70959,
    -- docs/DESIGN.md "Combat"): the call is logged, recorded in WoW.blocked
    -- and changes nothing; a post-hook still runs, as on the client. The
    -- player's own Alt+Z or Escape is secure: WoW.playerSetUIVisibility.
    SetUIVisibility = function(v)
        log("SetUIVisibility", v)
        if WoW.combat and not playerCall then
            table.insert(WoW.blocked, "SetUIVisibility")
            return
        end
        UIParent._shown = v and true or false
        quiet(UIParent)
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
            d = WoW.newWidget("Frame", UIParent, "StaticPopup" .. (#WoW.dialogs + 1))
            d._shown = false
            d._strata = "DIALOG"
            WoW.dialogs[#WoW.dialogs + 1] = d
        end
        d.which = which
        table.insert(WoW.shownDialogs, d)
        d._parent, d._shown = UIParent, true
        d._vis = Methods.IsVisible(d)
        return d
    end
    StaticPopupSpecial_Show = function(d)
        d.special = true
        table.insert(WoW.shownDialogs, d)
        d._parent, d._shown = UIParent, true
        d._vis = Methods.IsVisible(d)
    end
    StaticPopup_ForEachShownDialog = function(fn)
        for _, d in ipairs(WoW.shownDialogs) do fn(d) end
        return nil
    end
end)

-- The player's own Alt+Z or Escape: the engine's secure call, which the
-- lockdown doesn't block. Through the global, so hooks on it run.
function WoW.playerSetUIVisibility(v)
    playerCall = true
    local ok, err = pcall(SetUIVisibility, v)
    playerCall = false
    if not ok then error(err, 2) end
end

-- Close a dialog as Blizzard does (accept, cancel, Escape).
function WoW.closeDialog(d)
    d._shown, d._vis = false, false
    for i, x in ipairs(WoW.shownDialogs) do
        if x == d then table.remove(WoW.shownDialogs, i); break end
    end
end

-- A fresh client: no LibStub, so the next load starts the library from scratch.
function WoW.resetLibStub()
    rawset(_G, "LibStub", nil)
end

-- Combat as the client runs it: REGEN_DISABLED handlers are still unlocked,
-- but the player's combat flag is already up (MEASURED 70959, run #466:
-- UnitAffectingCombat("player") true inside the handler; #21).
function WoW.enterCombat()
    WoW.affecting = true
    WoW.fire("PLAYER_REGEN_DISABLED")
    WoW.combat = true
end
function WoW.leaveCombat()
    WoW.combat, WoW.affecting = false, false
    WoW.fire("PLAYER_REGEN_ENABLED")
end
function UnitAffectingCombat(unit) return unit == "player" and WoW.affecting == true end

--------------------------------------------------------------------------------
-- Globals (each confirmed in the API dump)
--------------------------------------------------------------------------------

-- Prompt getters: in the dump by NAME only (the _G walk), no signature. The
-- shapes are Retail's. MEASURED on 70959 (/fp steps ls prompts; docs/DESIGN.md):
-- the ready check, a loot roll (GetLootRollTimeLeft in milliseconds), and the
-- getters with nothing pending. Forever has no dungeon finder: the LFG getters
-- never report a pending proposal or role check there.
function GetReadyCheckStatus(unit)
    return unit == "player" and WoW.readyCheck and WoW.readyCheck.status or nil
end
function GetReadyCheckTimeLeft() return WoW.readyCheck and WoW.readyCheck.left or 0 end
function GetLFGProposal() return WoW.lfgProposal end
function GetLFGRoleUpdate() return WoW.roleCheck end
function GetActiveLootRollIDs()
    local t = {}
    for id in pairs(WoW.lootRolls) do t[#t + 1] = id end
    table.sort(t)
    return t
end
function GetLootRollTimeLeft(id) return WoW.lootRolls[id] or 0 end
function IsLoggedIn() return WoW.loggedIn end
function IsMounted() return WoW.mounted end
function UnitRace(unit) return WoW.race[1], WoW.race[2], WoW.race[3] end
function UnitSex(unit) return WoW.sex end   -- 2 male, 3 female (the dump: optional sex:number)

-- A temp CVar (C_CVar.SetTempCVar; gamepad mode puts them on the centring
-- CVars): a read returns the temp, and a SetCVar is invisible but lands on
-- the stored value underneath (MEASURED 70959, #54). WoW.gamepadMode(on)
-- switches the input style and the temps as Blizzard_Gamepad/Core.lua does.
function GetCVar(name)
    local temp = WoW.tempCVars[name]
    if temp ~= nil then return temp end
    return WoW.cvars[name]
end
-- C_InputInterfaceStyle.GetCurrentStyle (70959 dump); Mkb 0, Gamepad 1.
C_InputInterfaceStyle = { GetCurrentStyle = function() return WoW.inputStyle end }
function WoW.gamepadMode(on)
    WoW.inputStyle = on and 1 or 0
    if on then
        WoW.tempCVars.CameraKeepCharacterCentered, WoW.tempCVars.CameraReduceUnexpectedMovement = "1", "0"
    else
        WoW.tempCVars = {}
    end
end
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
-- SetView moves cameraView too (MEASURED 70959, follow run #468: 5 -> 2
-- while presenting).
function SetView(slot)
    log("SetView", slot)
    WoW.camera.view = slot
    if WoW.cvars.cameraView ~= nil then WoW.cvars.cameraView = tostring(slot) end
end
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

-- The default chat frame prints, as print does on the client (the kit's print
-- checks every line for a stray "|").
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) print(m) end }

WoW.reset()

-- Strict globals: any read of an undefined global is an error, except the
-- globals legitimately nil before first assignment or absent on this client.
local allowNil = {
    LibStub = true,                       -- the bundled file checks for an earlier copy
    UnitBuff = true, NUM_CHAT_WINDOWS = true,   -- not in the 70205 dump (AltStable's block reads them)
    AltStable = true, AltStableConfig = true,
    LIBSHOWCASE_MARK = true,              -- the synthetic newer copy's call counters
    LibShowcaseProbeDB = true,            -- the probe's SavedVariables, before its ADDON_LOADED
}
-- AltStable's block reads the chat edit boxes by name, up to NUM_CHAT_WINDOWS
-- or 10; a test makes the ones it needs.
for i = 1, 10 do allowNil["ChatFrame" .. i .. "EditBox"] = true end
Kit.strict(allowNil)
