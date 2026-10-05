-- LibShowcase-1.0: a "showcase" camera presentation, as an embedded LibStub
-- library.
--
-- Lifted from AltStable's AltStableCameraPresentation (SheetUI.lua:196-911 @
-- 5297196; behaviour kept, proven by tests/test_parity.lua), with
-- PortalRoulette's camera extras (Camera/CameraMode.lua) as opt-in options.
-- The design, the guarantees and the measured facts: docs/DESIGN.md.
--
--   local SC = LibStub("LibShowcase-1.0"):New({ owner = "MyAddon", ... })
--   SC:Enter(myWindow)        -- true, or false + "combat" | "unsupported" | "busy"
--   SC:Exit("closed")
--
-- ONE OWNER. The camera, the CVars and the game UI's visibility are global,
-- so lib.state holds a single lease. Every mutation (hiding the UI, lifting a
-- frame, the camera, GameTooltip) needs it, and another instance's calls are
-- refused. Enter, HideGameUI and Lift take the lease when it is free and
-- give it back when everything they changed is restored; Acquire holds it
-- until Release. Ownership lasts until deferred cleanup is done (an exit
-- animation, a protected frame waiting for combat to end).
--
-- BLIZZARD DIALOGS ARE NEVER TOUCHED. No StaticPopup_Show, and no SetParent,
-- SetFrameStrata or HookScript on a StaticPopup frame: they are a pool shared
-- with Blizzard's secure code, and an addon that touches one taints it
-- (MEASURED 70205: the player's Quit dialog then failed with
-- ADDON_ACTION_FORBIDDEN ForceQuit()). A dialog shown while the library has
-- the UI hidden brings the UI back instead; the presentation goes on.
--
-- Several addons embed copies and the newest one loaded wins (LibStub), so an
-- instance made by an older copy must run this copy's code. Hence the rules:
-- - Instance methods live in lib.methods, the instances' shared __index (a
--   plain table), as thin closures that look up lib.impl.<name> WHEN THEY RUN.
--   The SetUIVisibility and StaticPopup hooks, event/OnUpdate scripts and
--   C_Timer callbacks do the same. Never capture an implementation function.
-- - lib.impl, lib.methods, lib.instances, lib.state, the frames and every
--   public table keep their identity across upgrades (X = X or {}).
-- - An upgrade fills only missing option keys and adds missing methods; it
--   never touches a frame or the camera.
-- - lib.ready = MINOR is the last line: New refuses a half-loaded copy.

local MAJOR, MINOR = "LibShowcase-1.0", 3
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end   -- an equal or newer copy is already loaded

lib.impl = lib.impl or {}
lib.methods = lib.methods or {}
lib.instances = lib.instances or {}
lib.instanceMT = lib.instanceMT or {}
lib.instanceMT.__index = lib.methods
lib.hooked = lib.hooked or {}
lib.events = lib.events or {}
lib.defaults = lib.defaults or {}

-- The shared state. One table for every instance: there is one camera.
lib.state = lib.state or {}
local st = lib.state
st.lifts = st.lifts or {}          -- ordered: { frame, parent, strata, scale, level, points, inst }
st.cam = st.cam or {}              -- the camera presentation (active, mode, inst, cfg, capture, ...)

local I = lib.impl   -- the same table across upgrades; looked up at call time

-- Copy `src` into `dst` in place, so a table a consumer holds stays current.
local function fill(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            fill(dst[k], v)
        else
            dst[k] = v
        end
    end
    return dst
end

-- Copy only the keys `dst` lacks: an upgrade must keep an instance's options.
local function fillMissing(dst, src)
    for k, v in pairs(src) do
        if dst[k] == nil then
            dst[k] = type(v) == "table" and fill({}, v) or v
        end
    end
    return dst
end

--------------------------------------------------------------------------------
-- Public, shared data (filled in place)
--------------------------------------------------------------------------------

-- Camera CVars that CANCEL a shoulder offset on this Mainline-based client:
-- captured on entry, set to "0" in between, restored on exit. Only touched
-- when the client has them (writing a CVar that doesn't exist creates it).
-- PORTING-TBC-TO-FOREVER.md: "A CVar that does nothing may be obeyed and then
-- overruled". Measured defaults on 70205: CameraKeepCharacterCentered 1,
-- CameraReduceUnexpectedMovement 0.
lib.CENTRING_CVARS = fill(lib.CENTRING_CVARS or {}, {
    "CameraKeepCharacterCentered",
    "CameraReduceUnexpectedMovement",
})

-- Narcissus Classic's ZoomValuebyRaceID shoulder columns, by race ID:
--   offset = zoom * factor1 + factor2
-- Positive offsets push the character LEFT on screen.
lib.SHOULDER_FACTORS = fill(lib.SHOULDER_FACTORS or {}, {
    [0]  = { 0.361,  -0.1654 },  -- default
    [1]  = { 0.3283, -0.02   },  -- Human
    [2]  = { 0.2667, -0.1233 },  -- Orc
    [3]  = { 0.2667, -0.0267 },  -- Dwarf
    [4]  = { 0.30,   -0.0404 },  -- Night Elf
    [5]  = { 0.3537, -0.15   },  -- Undead
    [6]  = { 0.2027, -0.18   },  -- Tauren
    [7]  = { 0.329,   0.0517 },  -- Gnome
    [8]  = { 0.2787,  0.04   },  -- Troll
    [10] = { 0.361,  -0.1654 },  -- Blood Elf
    [11] = { 0.248,  -0.02   },  -- Draenei
})
lib.MOUNTED_SHOULDER_FACTORS = fill(lib.MOUNTED_SHOULDER_FACTORS or {}, { 1.2495, -4.0 })
-- UnitRace's second return (the race file) to the IDs above.
lib.RACE_IDS = fill(lib.RACE_IDS or {}, {
    Human = 1, Orc = 2, Dwarf = 3, NightElf = 4, Scourge = 5, Undead = 5, Tauren = 6,
    Gnome = 7, Troll = 8, BloodElf = 10, Draenei = 11,
})

-- The key a consumer's db table carries the capture under while presenting.
lib.DB_KEY = "LibShowcaseCapture"

local POPUP_EVENT = "EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED"
local CAST_RESET_YAW_SPEED = 0.78       -- PortalRoulette CameraMode.lua
local CAST_RESET_YAW_DURATION = 0.42
local CAST_EVENTS = {
    "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_STOP",
    "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED",
}

--------------------------------------------------------------------------------
-- Options
--------------------------------------------------------------------------------

-- Defaults are AltStable's (Config.lua's camera defaults). nil-default options
-- (shoulderRef, mountedShoulder, pitchLimit, viewBlendStyle, db, onForcedExit,
-- onGameUIShown, debug) are off until a consumer sets them.
lib.defaults.opts = fill(lib.defaults.opts or {}, {
    zoom = 2.2,
    mountedZoom = 8.0,
    shoulderMult = 1.0,
    forceMounted = false,
    yawDegrees = 430,
    yawOffset = -0.22,
    enterDuration = 1.50,
    exitDuration = 0.45,
    orbit = true,
    orbitSpeed = 0.005,
    savedViewSlot = 5,
    presentationViewSlot = 4,
    hideUI = true,
    anchorStrata = "DIALOG",
    castAware = false,
    dynamicPitch = false,
    salute = false,
})

-- Every option New accepts, and its type(s).
lib.defaults.types = fill(lib.defaults.types or {}, {
    owner = "string", db = "table|function", zoom = "number", mountedZoom = "number",
    shoulderRef = "number", shoulderMult = "number", mountedShoulder = "number",
    forceMounted = "boolean", yawDegrees = "number", yawOffset = "number",
    enterDuration = "number", exitDuration = "number", orbit = "boolean", orbitSpeed = "number",
    savedViewSlot = "number", presentationViewSlot = "number", hideUI = "boolean",
    anchorStrata = "string", castAware = "boolean", dynamicPitch = "boolean",
    pitchLimit = "number", viewBlendStyle = "number", salute = "boolean",
    onForcedExit = "function", onGameUIShown = "function", debug = "boolean|function",
})

local function Clamp(v, minV, maxV, fallback)
    v = tonumber(v)
    if not v then return fallback end
    if v < minV then return minV end
    if v > maxV then return maxV end
    return v
end

-- A snapshot of an instance's options, clamped to AltStable's ranges. Taken
-- at Enter: a presentation runs with the values it started with.
function I.Config(inst)
    local o = inst.opts
    local zoom = Clamp(o.zoom, 1.20, 18.0, 2.2)
    local saved = math.floor(Clamp(o.savedViewSlot, 2, 5, 5))
    local pres = math.floor(Clamp(o.presentationViewSlot, 2, 5, 4))
    return {
        enterDuration = Clamp(o.enterDuration, 0.35, 1.50, 1.50),
        exitDuration  = Clamp(o.exitDuration, 0.25, 1.20, 0.45),
        zoom          = zoom,
        shoulderRef   = o.shoulderRef ~= nil and Clamp(o.shoulderRef, 1.20, 18.0, zoom) or nil,
        shoulderMult  = tonumber(o.shoulderMult) or 1.0,
        mountedZoom   = Clamp(o.mountedZoom, 1.20, 18.0, 8.0),
        mountedShoulder = o.mountedShoulder ~= nil and Clamp(o.mountedShoulder, 0.0, 12.0, 8.0) or nil,
        forceMounted  = o.forceMounted == true,
        yawOffset     = Clamp(o.yawOffset, -1.2, 1.2, -0.22),
        yawDegrees    = Clamp(o.yawDegrees, 20, 540, 430),
        savedViewSlot = saved,
        -- The cast-aware view must not overwrite the player's own saved view.
        presentationViewSlot = pres ~= saved and pres or nil,
        orbit         = o.orbit == true,
        orbitSpeed    = Clamp(o.orbitSpeed, 0.001, 0.05, 0.005),
        hideUI        = o.hideUI ~= false,
        anchorStrata  = type(o.anchorStrata) == "string" and o.anchorStrata or "DIALOG",
        castAware     = o.castAware == true,
        dynamicPitch  = o.dynamicPitch == true,
        pitchLimit    = o.pitchLimit ~= nil and math.floor(Clamp(o.pitchLimit, 1, 88, 88)) or nil,
        viewBlendStyle = o.viewBlendStyle ~= nil and math.floor(Clamp(o.viewBlendStyle, 0, 2, 1)) or nil,
        salute        = o.salute == true,
    }
end

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function InCombat()
    return type(InCombatLockdown) == "function" and InCombatLockdown() and true or false
end

local function IsProtectedFrame(f)
    if type(f) ~= "table" or type(f.IsProtected) ~= "function" then return false end
    local ok, p = pcall(f.IsProtected, f)
    return ok and p == true
end

function I.Debug(inst, msg)
    local d = inst and inst.opts and inst.opts.debug
    if type(d) == "function" then
        pcall(d, tostring(msg or ""))
    elseif d == true and DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[LibShowcase:" .. tostring(inst.owner) .. "]|r " .. tostring(msg or ""))
    end
end

-- The consumer's db table (a table, or a function returning one: a
-- SavedVariables table is replaced at ADDON_LOADED, after New ran).
function I.DB(inst)
    local db = inst.opts and inst.opts.db
    if type(db) == "function" then
        local ok, t = pcall(db)
        db = ok and t or nil
    end
    return type(db) == "table" and db or nil
end

local function Call(f, reason)
    if type(f) ~= "function" then return end
    local ok, err = pcall(f, reason)
    if not ok then
        local handler = rawget(_G, "geterrorhandler")
        if type(handler) == "function" then pcall(handler(), err) end
    end
end

function I.Notify(inst, reason)
    Call(inst and inst.opts and inst.opts.onForcedExit, reason)
end

-- The game UI came back while the presentation goes on (a dialog appeared).
function I.NotifyShown(inst, reason)
    Call(inst and inst.opts and inst.opts.onGameUIShown, reason)
end

-- Dot-calling an instance method lands the first argument in `inst`.
function I.Check(inst, name)
    if type(inst) ~= "table" or getmetatable(inst) ~= lib.instanceMT then
        error(MAJOR .. ": call it as instance:" .. tostring(name) .. "(...), with a colon", 3)
    end
end

--------------------------------------------------------------------------------
-- The lease
--------------------------------------------------------------------------------

-- Take the lease if it is free; true when `inst` holds it.
function I.Claim(inst)
    if st.owner == nil then st.owner = inst end
    return st.owner == inst
end

function I.Idle()
    return not st.cam.active and not st.uiHidden and #st.lifts == 0
end

-- Give the lease back once nothing is left to restore and nobody Acquired it.
function I.MaybeRelease()
    if st.owner ~= nil and not st.explicit and I.Idle() then
        st.owner = nil
    end
end

function I.IsOwner(inst) return st.owner ~= nil and st.owner == inst end

function I.Acquire(inst)
    if st.owner ~= nil and st.owner ~= inst then return false, "busy" end
    st.owner = inst
    st.explicit = true
    return true
end

-- Restore everything and give the lease back (after deferred cleanup, if any).
function I.Release(inst)
    if not I.IsOwner(inst) then return false end
    st.explicit = false
    I.Restore(inst, "release")
    return true
end

--------------------------------------------------------------------------------
-- Lifting frames out from under UIParent
--------------------------------------------------------------------------------
-- SetUIVisibility(false) hides everything under UIParent; a frame lifted out
-- (SetParent(nil)) is a sibling of UIParent and stays up. Scale is compensated
-- so the frame keeps its on-screen size. Idempotent in both directions: a
-- second lift must not save the lifted strata and scale as "the old ones".

function I.FindLift(frame)
    for i, rec in ipairs(st.lifts) do
        if rec.frame == frame then return rec, i end
    end
end

function I.IsLifted(inst, frame)
    return I.FindLift(frame) ~= nil
end

function I.Lift(inst, frame, strata)
    if type(frame) ~= "table" then return false end
    if not I.Claim(inst) then return false, "busy" end
    if I.FindLift(frame) then return true end
    -- A protected frame can't be reparented in combat.
    if InCombat() and IsProtectedFrame(frame) then
        I.MaybeRelease()
        return false, "combat"
    end
    local rec = { frame = frame, inst = inst }
    if frame.GetParent then rec.parent = frame:GetParent() end
    if frame.GetFrameStrata then rec.strata = frame:GetFrameStrata() end
    if frame.GetScale then rec.scale = frame:GetScale() end
    if frame.GetFrameLevel then rec.level = frame:GetFrameLevel() end
    -- Recorded for diagnosis, not re-applied: SetParent keeps anchors, and
    -- re-applying them would undo a drag made while lifted.
    local n = frame.GetNumPoints and frame:GetNumPoints()
    if type(n) == "number" and n > 0 and frame.GetPoint then
        rec.points = {}
        for i = 1, n do rec.points[i] = { frame:GetPoint(i) } end
    end
    local eff = frame.GetEffectiveScale and frame:GetEffectiveScale()   -- while still parented
    st.lifts[#st.lifts + 1] = rec
    pcall(frame.SetParent, frame, nil)
    if strata then pcall(frame.SetFrameStrata, frame, strata) end
    if type(eff) == "number" then pcall(frame.SetScale, frame, eff) end
    return true
end

-- Put one record back. A protected frame in combat KEEPS its record and is
-- put back at PLAYER_REGEN_ENABLED; a record is cleared only after the
-- reparent succeeded. Taken out of the list BEFORE anything moves: putting a
-- frame back under a hidden UIParent can fire its OnHide, which may call
-- back in here.
function I.DropRecord(rec)
    local frame = rec.frame
    if InCombat() and IsProtectedFrame(frame) then
        rec.deferred = true
        return false
    end
    local _, i = I.FindLift(frame)
    if not i then return true end
    table.remove(st.lifts, i)
    local ok = pcall(frame.SetParent, frame, rec.parent)
    if not ok then
        table.insert(st.lifts, i, rec)
        rec.deferred = true
        return false
    end
    pcall(frame.SetScale, frame, rec.scale or 1)
    if rec.strata then pcall(frame.SetFrameStrata, frame, rec.strata) end
    if rec.level then pcall(frame.SetFrameLevel, frame, rec.level) end
    return true
end

function I.Drop(inst, frame)
    local rec = I.FindLift(frame)
    if not rec then return true end
    if not I.IsOwner(inst) then return false end
    local ok = I.DropRecord(rec)
    I.MaybeRelease()
    return ok
end

-- Every lift, in the order they were made.
function I.DropAll()
    local all = {}
    for i, rec in ipairs(st.lifts) do all[i] = rec end
    local done = true
    for _, rec in ipairs(all) do
        if not I.DropRecord(rec) then done = false end
    end
    return done
end

-- The records a restore could not put back (protected, in combat).
function I.DropDeferred()
    local all = {}
    for _, rec in ipairs(st.lifts) do
        if rec.deferred then all[#all + 1] = rec end
    end
    for _, rec in ipairs(all) do I.DropRecord(rec) end
end

--------------------------------------------------------------------------------
-- The game UI (Alt+Z style)
--------------------------------------------------------------------------------
-- SetUIVisibility(false) is the engine's own call (the one Alt+Z makes): it
-- hides everything under UIParent, driver-shown addon windows included, and
-- is not protected. Bails in combat; every restore path brings it back.

function I.HideUI(inst, anchor)
    local strata = (st.cam.cfg and st.cam.cfg.anchorStrata) or inst.opts.anchorStrata or "DIALOG"
    if st.uiHidden then
        -- Already hidden (HideGameUI, then Enter(window)): the window still
        -- has to come up above it.
        if anchor then I.Lift(inst, anchor, strata) end
        return true
    end
    if InCombat() then return false, "combat" end
    if type(SetUIVisibility) ~= "function" then return false, "unsupported" end
    -- A Blizzard dialog already up (an invite, a summon) would vanish with the
    -- UI and nothing would bring it back: its Show already happened. Leave
    -- the UI up, as a dialog appearing later brings it back.
    if I.AnyDialogShown(false) then return false, "dialog" end

    -- Close an open chat edit box: hidden mid-input and shown again, it comes
    -- back half-focused and un-closable.
    for i = 1, (rawget(_G, "NUM_CHAT_WINDOWS") or 10) do
        local eb = rawget(_G, "ChatFrame" .. i .. "EditBox")
        if type(eb) == "table" and eb.IsShown and eb:IsShown() then
            if type(ChatEdit_DeactivateChat) == "function" then
                pcall(ChatEdit_DeactivateChat, eb)
            else
                if eb.ClearFocus then pcall(eb.ClearFocus, eb) end
                if eb.Hide then pcall(eb.Hide, eb) end
            end
        end
    end

    if anchor then I.Lift(inst, anchor, strata) end
    -- GameTooltip too, so every SetOwner/AddLine keeps working; TOOLTIP draws
    -- above the window.
    if GameTooltip then I.Lift(inst, GameTooltip, "TOOLTIP") end
    pcall(SetUIVisibility, false)
    st.uiHidden = true
    return true
end

function I.HideGameUI(inst, anchor)
    if not I.Claim(inst) then return false, "busy" end
    local ok, why = I.HideUI(inst, anchor)
    if not ok then I.MaybeRelease() end
    return ok, why
end

-- The core restore: no lease check, no release. Clears the flag BEFORE the
-- engine call, so the SetUIVisibility hook sees a restore already under way.
function I.ShowUI()
    if not st.uiHidden then return false end
    st.uiHidden = false
    if type(SetUIVisibility) == "function" then pcall(SetUIVisibility, true) end
    I.DropAll()
    return true
end

function I.RestoreGameUI(inst)
    if not I.IsOwner(inst) then return false end
    local done = I.ShowUI()
    I.MaybeRelease()
    return done
end

function I.IsGameUIHidden(inst)
    return st.uiHidden == true
end

--------------------------------------------------------------------------------
-- Blizzard dialogs: never touched
--------------------------------------------------------------------------------
-- StaticPopup frames are a pool Blizzard's secure code shares with every
-- addon. Showing one from addon code (StaticPopup_Show), or modifying or
-- hooking one of the frames (SetParent, SetFrameStrata, HookScript), taints
-- it, and a protected action a later dialog runs from it is forbidden.
-- MEASURED 70205: after the probe's StaticPopup_Show + LiftPopup (SetParent,
-- SetFrameStrata, HookScript("OnHide") on the dialog), the player's Quit
-- dialog failed: ADDON_ACTION_FORBIDDEN, ForceQuit() from StaticPopup_OnClick.
--
-- So a dialog that appears while the library has the game UI hidden (a guild
-- or party invite, a summon; a ready check, a loot roll: REVEAL_EVENTS below)
-- brings the UI back, and the dialog shows where Blizzard put it, untouched.
-- The presentation goes on: camera, lease, the consumer's window (back under
-- the shown UIParent). Post-hooks (hooksecurefunc) on StaticPopup_Show and
-- StaticPopupSpecial_Show notice it; a post-hook leaves Blizzard's own call
-- secure. A StaticPopup already up keeps the UI from being hidden (HideUI).

-- StaticPopup_Show returns nil when it refuses (a show condition), and a hook
-- does not see the return: ask the shown list instead (Blizzard_StaticPopup's
-- StaticPopup_SetUpPosition inserts the dialog there before it calls Show).
-- `unknown` is the answer when the client has no such list (default true:
-- the hook then trusts the Show it just saw). Only reads.
function I.AnyDialogShown(unknown)
    local each = rawget(_G, "StaticPopup_ForEachShownDialog")
    if type(each) ~= "function" then return unknown ~= false end
    local any = false
    pcall(each, function() any = true end)
    return any
end

-- Bring the game UI back and keep the presentation. Through ShowUI, which
-- clears uiHidden before SetUIVisibility(true), so the SetUIVisibility hook
-- does not read it as Escape/Alt+Z. Acts only while a lease holds the UI
-- hidden (the player's own Alt+Z is the player's business).
function I.RevealForDialog(reason)
    local inst = st.owner
    if not inst or not st.uiHidden then return false end
    I.ShowUI()
    I.Debug(inst, "game UI shown: " .. tostring(reason))
    I.NotifyShown(inst, reason)
    I.MaybeRelease()
    return true
end

function I.OnStaticPopupShow()
    if st.uiHidden and I.AnyDialogShown() then I.RevealForDialog("dialog") end
end

function I.OnStaticPopupSpecialShow()
    I.RevealForDialog("dialog")
end

-- Prompts Blizzard shows WITHOUT StaticPopup_Show, each its own frame under
-- UIParent: a ready check, a dungeon-finder proposal or role check, a role
-- poll, a PvP role popup, a loot roll. Their events (all in the 70205 dump)
-- bring the UI back the same way; listening to an event touches nothing.
local REVEAL_EVENTS = {
    "READY_CHECK", "LFG_PROPOSAL_SHOW", "LFG_ROLE_CHECK_SHOW", "ROLE_POLL_BEGIN",
    "PVP_ROLE_POPUP_SHOW", "START_LOOT_ROLL",
}
local IS_REVEAL_EVENT = {}
for _, ev in ipairs(REVEAL_EVENTS) do IS_REVEAL_EVENT[ev] = true end

-- "Reveal for a dialog": brings the game UI back (as above) and hands the
-- dialog back UNTOUCHED. Does nothing when the UI is up or the caller does
-- not hold the lease. (Consumers must not show StaticPopups of their own.)
function I.LiftPopup(inst, dialog)
    if I.IsOwner(inst) then I.RevealForDialog("dialog") end
    return dialog
end

-- Kept for API stability: LiftPopup changes nothing on the dialog to put back.
function I.DropPopup(inst, dialog)
end

-- Installed once each, when Blizzard_StaticPopup is loaded: at load, or at
-- PLAYER_LOGIN if it came later.
function I.InstallDialogHooks()
    if type(hooksecurefunc) ~= "function" then return end
    if not lib.hooked.StaticPopup_Show and type(rawget(_G, "StaticPopup_Show")) == "function" then
        lib.hooked.StaticPopup_Show = true
        hooksecurefunc("StaticPopup_Show", function() lib.impl.OnStaticPopupShow() end)
    end
    if not lib.hooked.StaticPopupSpecial_Show and type(rawget(_G, "StaticPopupSpecial_Show")) == "function" then
        lib.hooked.StaticPopupSpecial_Show = true
        hooksecurefunc("StaticPopupSpecial_Show", function() lib.impl.OnStaticPopupSpecialShow() end)
    end
end

--------------------------------------------------------------------------------
-- The experimental-CVar popup
--------------------------------------------------------------------------------
-- Writing a test_* CVar raises "Are you sure you want to enable this
-- experimental feature?". On this Mainline-based client it is an INTERNAL
-- event: GameEvent.UnregisterInternalEvent suppresses it (MEASURED 70205,
-- PortalRoulette FOREVER-PROBE.md: callable, no ADDON_ACTION_BLOCKED, no
-- popup). NEVER re-registered (see UnsuppressPopup). Only where GameEvent is
-- absent, AltStable's fallback: unregister every frame registered for the
-- event (GetFramesRegisteredForEvent returns VARARGS, not a table).

function I.SuppressExperimentalCVarPopup()
    local GE = rawget(_G, "GameEvent")
    if type(GE) == "table" and type(GE.UnregisterInternalEvent) == "function" then
        if pcall(GE.UnregisterInternalEvent, POPUP_EVENT) then
            st.popupSuppressed = "gameevent"
            return 1
        end
        return 0
    end
    local n = 0
    if type(GetFramesRegisteredForEvent) == "function" then
        local function collect(ok, ...)
            local frames = {}
            if ok then
                for i = 1, select("#", ...) do
                    local f = select(i, ...)
                    if f ~= nil then frames[#frames + 1] = f end
                end
            end
            return frames
        end
        for _, f in ipairs(collect(pcall(GetFramesRegisteredForEvent, POPUP_EVENT))) do
            if type(f) == "table" and type(f.UnregisterEvent) == "function" then
                if pcall(f.UnregisterEvent, f, POPUP_EVENT) then n = n + 1 end
            end
        end
    end
    if n == 0 and UIParent and type(UIParent.UnregisterEvent) == "function" then
        pcall(UIParent.UnregisterEvent, UIParent, POPUP_EVENT)
    end
    return n
end

-- Handed out as lib.SuppressExperimentalCVarPopup: dispatches at call time.
lib.SuppressExperimentalCVarPopup = lib.SuppressExperimentalCVarPopup
    or function(...) return lib.impl.SuppressExperimentalCVarPopup(...) end

-- The popup is never given back: it stays off until the next /reload (as with
-- AltStable's frame walk), so a later test_* write applies without asking.
-- Re-registering taints the dialog pool. MEASURED 70205 (/lsprobe rereg):
-- after UnregisterInternalEvent + RegisterInternalEvent from addon code, the
-- player's own "/console test_cameraOverShoulder" brought the popup back, and
-- issecurevariable(dialog, "which") read TAINTED by the registering addon,
-- with an addon closure (r2's way) and with
-- GameEvent.HandleExperimentalCVarConfirmationNeeded passed itself alike.
-- Blizzard's own registration showed it securely. A tainted StaticPopup is
-- what broke Quit (see "Blizzard dialogs").
-- Kept as a no-op: an r2 copy's pending C_Timer callback calls it by name.
function I.UnsuppressPopup()
end

--------------------------------------------------------------------------------
-- The camera
--------------------------------------------------------------------------------

local function InOutSine(t, b, e, d)
    return -(e - b) / 2 * (math.cos(math.pi * t / d) - 1) + b
end

function I.IsSupported()
    return type(SaveView) == "function"
       and type(SetView) == "function"
       and type(GetCameraZoom) == "function"
       and type(CameraZoomIn) == "function"
       and type(CameraZoomOut) == "function"
end

function I.SetZoom(goal)
    local current = tonumber(GetCameraZoom()) or goal
    local delta = (tonumber(goal) or current) - current
    if math.abs(delta) < 0.001 then return end
    if delta > 0 then
        pcall(CameraZoomOut, delta)
    else
        pcall(CameraZoomIn, -delta)
    end
end

function I.StopYaw()
    if type(MoveViewRightStop) == "function" then pcall(MoveViewRightStop) end
    if type(MoveViewLeftStop) == "function" then pcall(MoveViewLeftStop) end
end

function I.ApplyYaw(speed)
    speed = tonumber(speed) or 0
    if math.abs(speed) <= 0.001 then return end
    if speed > 0 and type(MoveViewRightStart) == "function" then
        pcall(MoveViewRightStart, speed)
    elseif speed < 0 and type(MoveViewLeftStart) == "function" then
        pcall(MoveViewLeftStart, -speed)
    elseif speed < 0 and type(MoveViewRightStart) == "function" then
        pcall(MoveViewRightStart, -speed)
    end
end

-- Orbit speeds are an order of magnitude below the swing's (0.005 vs 0.5).
function I.ApplyOrbit(speed)
    speed = tonumber(speed) or 0
    if math.abs(speed) <= 0.0001 then return end
    if speed > 0 and type(MoveViewRightStart) == "function" then
        pcall(MoveViewRightStart, speed)
    elseif speed < 0 and type(MoveViewLeftStart) == "function" then
        pcall(MoveViewLeftStart, -speed)
    end
end

function I.IsMounted(cfg)
    if cfg and cfg.forceMounted then return true end
    return type(IsMounted) == "function" and IsMounted() and true or false
end

function I.TargetZoom(cfg)
    if I.IsMounted(cfg) then return cfg.mountedZoom end
    return cfg.zoom
end

-- The shoulder offset for a race (UnitRace's race file or race ID) at a zoom.
function I.ShoulderOffsetFor(race, zoom, mounted)
    zoom = tonumber(zoom) or 0
    if mounted then
        local m = lib.MOUNTED_SHOULDER_FACTORS
        return zoom * m[1] + m[2]
    end
    local id = tonumber(race) or (race ~= nil and lib.RACE_IDS[race]) or 0
    local f = lib.SHOULDER_FACTORS[id] or lib.SHOULDER_FACTORS[0]
    return zoom * f[1] + f[2]
end
lib.ShoulderOffsetFor = lib.ShoulderOffsetFor
    or function(...) return lib.impl.ShoulderOffsetFor(...) end

function I.PlayerShoulderOffset(cfg, zoom)
    if I.IsMounted(cfg) then
        return cfg.mountedShoulder or I.ShoulderOffsetFor(nil, cfg.mountedZoom, true)
    end
    local race
    if type(UnitRace) == "function" then
        local _, raceFile, raceID = UnitRace("player")
        race = tonumber(raceID) or raceFile
    end
    return I.ShoulderOffsetFor(race, cfg.shoulderRef or zoom) * cfg.shoulderMult
end

-- Write the presentation's CVars (Enter, and again after a cast reset).
-- Nothing when the client lacks the CVar (no shoulderOffset was captured).
function I.WriteShoulder(cam)
    if not (cam.capture and cam.capture.shoulderOffset) then return nil end
    local desired = I.PlayerShoulderOffset(cam.cfg, cam.enterToZoom)
    I.SuppressExperimentalCVarPopup()
    pcall(SetCVar, "test_cameraOverShoulder", desired)
    return desired
end

function I.WriteExtras(cam)
    local cfg, cap = cam.cfg, cam.capture
    if cfg.viewBlendStyle and cap.viewBlendStyle ~= nil then
        pcall(SetCVar, "cameraViewBlendStyle", cfg.viewBlendStyle)
    end
    if cfg.dynamicPitch and cap.dynamicPitch ~= nil then
        I.SuppressExperimentalCVarPopup()
        pcall(SetCVar, "test_cameraDynamicPitch", "1")
    end
end

function I.Enter(inst, anchor)
    if st.owner ~= nil and st.owner ~= inst then return false, "busy" end
    local cam = st.cam
    if cam.active then
        -- On the way OUT: Exit already restored the UI, stopped the yaw and
        -- put the view back, so finish the exit properly and enter afresh.
        -- (Resuming would leave a window with no showcase; doing nothing would
        -- let the pending restore fire with the window open.)
        if cam.mode ~= "exit" then return true end
        I.Restore(inst, "re-enter during exit")
        I.Debug(inst, "re-entered during exit; restarting the presentation")
    end
    if InCombat() then return false, "combat" end
    if not I.IsSupported() then return false, "unsupported" end
    if not I.Claim(inst) then return false, "busy" end

    -- A capture an earlier session left in this db (not healed at New: another
    -- instance was presenting then) goes back first; otherwise the capture
    -- below would take that session's changed camera for the player's.
    I.Heal(inst)

    local cfg = I.Config(inst)
    local capture = { savedViewSlot = cfg.savedViewSlot, zoom = tonumber(GetCameraZoom()) or 0 }
    pcall(SaveView, capture.savedViewSlot)
    -- Crash self-heal: the capture lives in the consumer's SavedVariables
    -- until a restore clears it. Filled in as each CVar is changed.
    local db = I.DB(inst)
    if db then db[lib.DB_KEY] = capture end

    cam.active, cam.mode, cam.elapsed = true, "enter", 0
    cam.inst, cam.cfg, cam.capture, cam.anchor = inst, cfg, capture, anchor
    cam.didSalute, cam.presentationViewSaved = false, nil
    cam.castResetDuration, cam.resumeAfterReset = nil, nil
    cam.enterToZoom = I.TargetZoom(cfg)

    -- Narcissus starts from camera view 2; the player's own view is saved.
    pcall(SetView, 2)

    if type(GetCVar) == "function" and type(SetCVar) == "function" then
        -- Lift the zoom-out cap so a mounted preset can reach its target.
        -- (nil: the client lacks the CVar; writing it would create it.)
        local cap = GetCVar("cameraDistanceMaxZoomFactor")
        if cap ~= nil then
            capture.cameraDistanceMaxZoomFactor = tonumber(cap) or 1.0
            if capture.cameraDistanceMaxZoomFactor < 2.0 then
                pcall(SetCVar, "cameraDistanceMaxZoomFactor", 2.0)
            end
        end
    end

    -- Fired once; the engine animates it. Per-frame zoom calls queue and
    -- overshoot.
    I.SetZoom(cam.enterToZoom)

    if type(GetCVar) == "function" and type(SetCVar) == "function" then
        for _, cvar in ipairs(lib.CENTRING_CVARS) do
            local prev = GetCVar(cvar)
            if prev ~= nil then
                capture[cvar] = prev
                pcall(SetCVar, cvar, "0")
            end
        end
        local shoulder = GetCVar("test_cameraOverShoulder")
        if shoulder ~= nil then capture.shoulderOffset = tonumber(shoulder) or 0 end
        local desired = I.WriteShoulder(cam)

        if cfg.viewBlendStyle then capture.viewBlendStyle = GetCVar("cameraViewBlendStyle") end
        if cfg.dynamicPitch then capture.dynamicPitch = GetCVar("test_cameraDynamicPitch") end
        I.WriteExtras(cam)

        local after = {}
        for _, cvar in ipairs(lib.CENTRING_CVARS) do
            after[#after + 1] = cvar:gsub("^Camera", "") .. "=" .. tostring(GetCVar(cvar))
                .. " (was " .. tostring(capture[cvar]) .. ")"
        end
        local function n(v) return v and string.format("%.3f", v) or "absent" end
        I.Debug(inst, string.format("shoulder: from=%s to=%s  %s",
            n(capture.shoulderOffset), n(desired), table.concat(after, " ")))
    end
    if cfg.pitchLimit and type(ConsoleExec) == "function" then
        capture.pitchLimit = true
        pcall(ConsoleExec, "pitchlimit " .. cfg.pitchLimit)
    end

    do
        local yawMoveSpeed = tonumber(type(GetCVar) == "function" and GetCVar("cameraYawMoveSpeed")) or 180
        if yawMoveSpeed <= 0 then yawMoveSpeed = 180 end
        local dir = cfg.yawOffset < 0 and -1 or 1
        local degrees = math.abs(cfg.yawDegrees)
        local seconds = math.max(0.05, cfg.enterDuration)
        local speed = Clamp((degrees / yawMoveSpeed) / seconds, 0.10, 4.0, 1.0)
        cam.yawDir, cam.yawFromSpeed, cam.yawToSpeed = dir, speed, cfg.orbitSpeed
        I.StopYaw()
        I.ApplyYaw(dir * speed)
        I.Debug(inst, string.format("enter yaw: target=%d speed=%.3f yawMoveSpeed=%.1f",
            degrees, speed, yawMoveSpeed))
    end

    lib.animFrame:Show()
    if cfg.hideUI and anchor then I.HideUI(inst, anchor) end
    if cfg.castAware then I.SetCastEvents(true) end
    I.Debug(inst, "enter start")
    return true
end

function I.Exit(inst, reason)
    if not I.IsOwner(inst) then return false end
    local cam = st.cam
    if not cam.active or cam.mode == "exit" then return false end
    I.ShowUI()
    I.StopYaw()
    cam.mode, cam.elapsed = "exit", 0
    -- Snap the saved view back now; the rest is restored when the exit ends.
    if cam.capture and cam.capture.savedViewSlot then pcall(SetView, cam.capture.savedViewSlot) end
    lib.animFrame:Show()
    I.Debug(inst, "exit start: " .. tostring(reason or "hide"))
    return true
end

-- Put the camera and every CVar back exactly as captured. Shared by every
-- restore and by the login self-heal. A nil capture entry means the CVar did
-- not exist: writing a default over it would invent a setting.
function I.RestoreCapture(cap)
    if cap.savedViewSlot and type(SetView) == "function" then pcall(SetView, cap.savedViewSlot) end
    if type(GetCameraZoom) == "function" then I.SetZoom(cap.zoom or 0) end
    if type(SetCVar) == "function" then
        if cap.cameraDistanceMaxZoomFactor then
            pcall(SetCVar, "cameraDistanceMaxZoomFactor", cap.cameraDistanceMaxZoomFactor)
        end
        if cap.shoulderOffset then
            I.SuppressExperimentalCVarPopup()
            pcall(SetCVar, "test_cameraOverShoulder", cap.shoulderOffset)
        end
        for _, cvar in ipairs(lib.CENTRING_CVARS) do
            if cap[cvar] ~= nil then pcall(SetCVar, cvar, cap[cvar]) end
        end
        if cap.dynamicPitch ~= nil then
            I.SuppressExperimentalCVarPopup()
            pcall(SetCVar, "test_cameraDynamicPitch", cap.dynamicPitch)
        end
        if cap.viewBlendStyle ~= nil then pcall(SetCVar, "cameraViewBlendStyle", cap.viewBlendStyle) end
    end
    if cap.pitchLimit and type(ConsoleExec) == "function" then pcall(ConsoleExec, "pitchlimit 88") end
end

-- Everything back, at once: UI, camera, CVars, lifts. Protected
-- frames in combat wait for PLAYER_REGEN_ENABLED (and hold the lease).
function I.Restore(inst, reason)
    local cam = st.cam
    I.ShowUI()
    I.StopYaw()
    lib.animFrame:Hide()
    if cam.capture then
        I.RestoreCapture(cam.capture)
        local db = cam.inst and I.DB(cam.inst)
        if db and db[lib.DB_KEY] == cam.capture then db[lib.DB_KEY] = nil end
    end
    I.SetCastEvents(false)
    local wasActive = cam.active
    cam.active, cam.mode, cam.capture, cam.elapsed = false, nil, nil, 0
    cam.inst, cam.cfg, cam.anchor = nil, nil, nil
    cam.presentationViewSaved, cam.castResetDuration, cam.resumeAfterReset = nil, nil, nil
    I.DropAll()
    I.MaybeRelease()
    if wasActive then I.Debug(inst, "restored: " .. tostring(reason or "force")) end
end

function I.ForceRestore(inst, reason)
    if not I.IsOwner(inst) then return false end
    I.Restore(inst, reason)
    return true
end

function I.IsActive(inst)
    return I.IsOwner(inst) and st.cam.active == true
end

function I.MaybeSalute(cam)
    if cam.didSalute then return end
    cam.didSalute = true
    if not cam.cfg.salute then return end
    if InCombat() then return end
    if type(DoEmote) == "function" then pcall(DoEmote, "SALUTE") end
end

-- The settled presentation: a slow orbit, or still. With castAware, the
-- settled view is saved first so a cast can return to it.
function I.Settle(cam)
    I.StopYaw()
    if cam.cfg.castAware and cam.cfg.presentationViewSlot then
        cam.presentationViewSaved = pcall(SaveView, cam.cfg.presentationViewSlot) and true or false
    end
    if cam.cfg.orbit then I.ApplyOrbit((cam.yawDir or 1) * cam.cfg.orbitSpeed) end
end

function I.OnUpdate(elapsed)
    local cam = st.cam
    if not cam.mode then
        lib.animFrame:Hide()
        return
    end
    cam.elapsed = (cam.elapsed or 0) + (elapsed or 0)

    if cam.mode == "enter" then
        local duration = math.max(0.01, cam.cfg.enterDuration)
        if cam.yawDir and cam.yawFromSpeed and cam.yawToSpeed then
            local t = math.min(cam.elapsed, duration)
            I.ApplyYaw(cam.yawDir * InOutSine(t, cam.yawFromSpeed, cam.yawToSpeed, duration))
        end
        if cam.elapsed >= duration then
            I.Settle(cam)
            I.MaybeSalute(cam)
            cam.mode = nil
            lib.animFrame:Hide()
            I.Debug(cam.inst, "enter complete")
        end
        return
    end

    if cam.mode == "castReset" then
        if cam.elapsed >= math.max(0.01, cam.castResetDuration or CAST_RESET_YAW_DURATION) then
            I.StopYaw()
            cam.mode, cam.castResetDuration = "castHold", nil
            if cam.resumeAfterReset then
                I.ResumeOrbitAfterCast()
            else
                lib.animFrame:Hide()
            end
        end
        return
    end

    if cam.mode == "castHold" then
        lib.animFrame:Hide()
        return
    end

    if cam.mode == "exit" then
        if cam.elapsed >= math.max(0.01, cam.cfg.exitDuration) then
            I.Restore(cam.inst, "exit-complete")
        end
    end
end

-- castAware (PortalRoulette): a cast puts the presentation view back and
-- holds still, so the spell's animation plays to a steady camera; the end of
-- the cast resumes the orbit.
function I.ResetOrbitForCast()
    local cam = st.cam
    if not cam.active or cam.mode == "exit" then return end
    I.StopYaw()
    local restored = false
    if cam.presentationViewSaved and cam.cfg.presentationViewSlot then
        restored = pcall(SetView, cam.cfg.presentationViewSlot) and true or false
    end
    if not restored then pcall(SetView, 2) end
    I.SetZoom(cam.enterToZoom)
    I.WriteShoulder(cam)
    I.WriteExtras(cam)
    cam.elapsed, cam.resumeAfterReset = 0, nil
    if restored then
        cam.castResetDuration, cam.mode = nil, "castHold"
        lib.animFrame:Hide()
    else
        cam.castResetDuration, cam.mode = CAST_RESET_YAW_DURATION, "castReset"
        I.ApplyYaw((cam.yawDir or 1) * CAST_RESET_YAW_SPEED)
        lib.animFrame:Show()
    end
end

function I.ResumeOrbitAfterCast()
    local cam = st.cam
    if not cam.active or cam.mode == "exit" then return end
    if cam.mode == "castReset" then
        cam.resumeAfterReset = true
        return
    end
    if cam.mode ~= "castHold" then return end
    I.StopYaw()
    if cam.cfg.orbit then I.ApplyOrbit((cam.yawDir or 1) * cam.cfg.orbitSpeed) end
    cam.mode, cam.elapsed, cam.castResetDuration, cam.resumeAfterReset = nil, 0, nil, nil
    lib.animFrame:Hide()
end

function I.SetCastEvents(on)
    local f = lib.eventFrame
    if (st.castEvents and true or false) == (on and true or false) then return end
    st.castEvents = on and true or nil
    for _, ev in ipairs(CAST_EVENTS) do
        if on then
            if type(f.RegisterUnitEvent) == "function" then
                pcall(f.RegisterUnitEvent, f, ev, "player")
            else
                pcall(f.RegisterEvent, f, ev)
            end
        else
            pcall(f.UnregisterEvent, f, ev)
        end
    end
end

--------------------------------------------------------------------------------
-- Events and hooks (installed once, dispatched through lib.impl)
--------------------------------------------------------------------------------

-- A capture still in a db at login means the last session ended without a
-- restore (a crash, a killed client): put the player's camera back.
function I.Heal(inst)
    if st.cam.active then return false end
    local db = I.DB(inst)
    local cap = db and db[lib.DB_KEY]
    if type(cap) ~= "table" then return false end
    I.RestoreCapture(cap)
    db[lib.DB_KEY] = nil
    I.Debug(inst, "restored the camera a previous session left changed")
    return true
end

function I.OnEvent(event, ...)
    if IS_REVEAL_EVENT[event] then
        I.RevealForDialog("dialog")
        return
    end
    if event == "PLAYER_LOGIN" then
        I.InstallDialogHooks()
        for _, inst in ipairs(lib.instances) do I.Heal(inst) end
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        -- Deferred drops of protected frames; a hide that outlived combat.
        if st.uiHidden then I.ShowUI() end
        I.DropDeferred()
        I.MaybeRelease()
        return
    end
    if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_LOGOUT" or event == "PLAYER_ENTERING_WORLD" then
        -- PLAYER_REGEN_DISABLED runs BEFORE the lockdown (MEASURED 70205:
        -- InCombatLockdown() is false inside it), so this is the last unlocked
        -- moment: restore synchronously, here.
        local inst = st.owner
        if not inst then return end
        -- An idle Acquire lease: nothing to put back, no exit to report.
        if I.Idle() then return end
        I.Restore(inst, event)
        I.Notify(inst, event == "PLAYER_REGEN_DISABLED" and "combat"
            or event == "PLAYER_LOGOUT" and "logout" or "loading")
        return
    end
    local cam = st.cam
    if cam.active and cam.cfg and cam.cfg.castAware then
        local unit = ...
        if unit ~= "player" then return end
        if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
            I.ResetOrbitForCast()
        elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP"
            or event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
            I.ResumeOrbitAfterCast()
        end
    end
end

-- Escape or Alt+Z while the showcase has the UI hidden: the engine shows it
-- again through SetUIVisibility(true). Tell the owner (its window closes, its
-- OnHide exits); then make sure nothing is left half-shown. Our own restore
-- clears uiHidden first, so it never lands here.
function I.OnSetUIVisibility(visible)
    if not visible or not st.uiHidden or not st.owner then return end
    local inst = st.owner
    I.Notify(inst, "ui-shown")
    if st.owner ~= inst then return end
    if st.uiHidden then I.ShowUI() end
    if st.cam.active and st.cam.mode ~= "exit" then I.Exit(inst, "ui-shown") end
    I.MaybeRelease()
end

-- The OnUpdate runner hangs from WorldFrame: SetUIVisibility(false) hides
-- UIParent's children, and a hidden frame's OnUpdate stops.
if not lib.animFrame then
    lib.animFrame = CreateFrame("Frame", nil, WorldFrame)
    lib.animFrame:Hide()
    lib.animFrame:SetScript("OnUpdate", function(_, elapsed) return lib.impl.OnUpdate(elapsed) end)
end
if not lib.eventFrame then
    lib.eventFrame = CreateFrame("Frame")
    lib.eventFrame:SetScript("OnEvent", function(_, event, ...) return lib.impl.OnEvent(event, ...) end)
end
for _, ev in ipairs({ "PLAYER_LOGIN", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
                      "PLAYER_LOGOUT", "PLAYER_ENTERING_WORLD" }) do
    if not lib.events[ev] then
        lib.events[ev] = true
        lib.eventFrame:RegisterEvent(ev)
    end
end
-- pcall: a client without one of these events must not stop the load.
for _, ev in ipairs(REVEAL_EVENTS) do
    if not lib.events[ev] then
        lib.events[ev] = true
        pcall(lib.eventFrame.RegisterEvent, lib.eventFrame, ev)
    end
end
if not lib.hooked.SetUIVisibility and type(hooksecurefunc) == "function" and type(SetUIVisibility) == "function" then
    lib.hooked.SetUIVisibility = true
    hooksecurefunc("SetUIVisibility", function(visible) return lib.impl.OnSetUIVisibility(visible) end)
end
I.InstallDialogHooks()

--------------------------------------------------------------------------------
-- Instances
--------------------------------------------------------------------------------

-- The instance methods, colon-called, each dispatched to lib.impl[name].
lib.FUNCTIONS = fill(lib.FUNCTIONS or {}, {
    "Enter", "Exit", "ForceRestore", "IsActive", "IsOwner", "Acquire", "Release",
    "HideGameUI", "RestoreGameUI", "IsGameUIHidden", "Lift", "Drop", "IsLifted",
    "LiftPopup", "DropPopup",
})
for _, name in ipairs(lib.FUNCTIONS) do
    if lib.methods[name] == nil then
        lib.methods[name] = function(self, ...)
            lib.impl.Check(self, name)
            return lib.impl[name](self, ...)
        end
    end
end

-- Give `inst` whatever this copy defines and it lacks. Never overwrites.
function I.Migrate(inst)
    inst.opts = fillMissing(inst.opts or {}, lib.defaults.opts)
    setmetatable(inst, lib.instanceMT)
    return inst
end

function lib:New(opts)
    if self ~= lib then
        error(MAJOR .. ': call it as LibStub("LibShowcase-1.0"):New(opts), with a colon', 2)
    end
    local _, active = LibStub:GetLibrary(MAJOR)
    if lib.ready ~= active then
        error(MAJOR .. ": the loaded copy (MINOR " .. tostring(active) .. ") did not finish loading"
            .. " (ready = " .. tostring(lib.ready) .. "); see the first error this session", 2)
    end
    if type(opts) ~= "table" or type(opts.owner) ~= "string" or opts.owner == "" then
        error(MAJOR .. ": New needs opts.owner, the addon's name", 2)
    end
    for k, v in pairs(opts) do
        local want = lib.defaults.types[k]
        if not want then error(MAJOR .. ": unknown option " .. tostring(k), 2) end
        if not ("|" .. want .. "|"):find("|" .. type(v) .. "|", 1, true) then
            error(MAJOR .. ": option " .. k .. " must be " .. want .. ", not " .. type(v), 2)
        end
    end
    local inst = { owner = opts.owner, opts = {} }
    for k, v in pairs(opts) do inst.opts[k] = v end
    I.Migrate(inst)
    table.insert(lib.instances, inst)
    -- Created after login (a load-on-demand addon): heal now, not at a
    -- PLAYER_LOGIN that already happened.
    if type(IsLoggedIn) == "function" and IsLoggedIn() then I.Heal(inst) end
    return inst
end

-- Upgrading in place: older instances get what this copy adds, nothing else.
for _, inst in ipairs(lib.instances) do I.Migrate(inst) end

-- Test-only internals.
lib._test = { fill = fill, fillMissing = fillMissing, Clamp = Clamp }

lib.ready = MINOR
