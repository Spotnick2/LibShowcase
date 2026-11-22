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

local MAJOR, MINOR = "LibShowcase-1.0", 12
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
    -- Forever's Skyborne (#59): ChrModel 218/219 share the Blood Elf models'
    -- skeletons and camera distance (forever-chrmodel-1.60.1.70959.csv; the
    -- scale and the customization camera's z offsets differ), so the Blood
    -- Elf pairs. Both race IDs share the models. docs/DESIGN.md has the rest.
    [95] = { 0.361,  -0.1654 },  -- High Order Skyborne
    [96] = { 0.361,  -0.1654 },  -- Windshaper Skyborne
})
-- The same table's FEMALE column (#38): SHOULDER_FACTORS above is its male
-- column, and the female framing differs (a female Human sits about 0.16
-- further at a 2.1 zoom). Used when the sex is 3 (UnitSex); a race missing
-- here takes its male pair. Mounted: one pair for both.
lib.FEMALE_SHOULDER_FACTORS = fill(lib.FEMALE_SHOULDER_FACTORS or {}, {
    [0]  = { 0.361,  -0.1654 },  -- default
    [1]  = { 0.38,    0.0311 },  -- Human
    [2]  = { 0.3045, -0.0483 },  -- Orc
    [3]  = { 0.3533, -0.02   },  -- Dwarf
    [4]  = { 0.329,   0.025  },  -- Night Elf
    [5]  = { 0.3447,  0.03   },  -- Undead
    [6]  = { 0.2427, -0.1867 },  -- Tauren
    [7]  = { 0.329,  -0.012  },  -- Gnome
    [8]  = { 0.355,  -0.1317 },  -- Troll
    [10] = { 0.3177,  0.0683 },  -- Blood Elf
    [11] = { 0.3177,  0      },  -- Draenei
    [95] = { 0.3177,  0.0683 },  -- High Order Skyborne (#59)
    [96] = { 0.3177,  0.0683 },  -- Windshaper Skyborne
})
lib.MOUNTED_SHOULDER_FACTORS = fill(lib.MOUNTED_SHOULDER_FACTORS or {}, { 1.2495, -4.0 })
-- UnitRace's second return (the race file) to the IDs above.
lib.RACE_IDS = fill(lib.RACE_IDS or {}, {
    Human = 1, Orc = 2, Dwarf = 3, NightElf = 4, Scourge = 5, Undead = 5, Tauren = 6,
    Gnome = 7, Troll = 8, BloodElf = 10, Draenei = 11, Skyborne = 95,
})

-- The world name text (players, pets and minions, NPCs) hideWorldNames turns
-- off: the "show name" CVars FrameXML 70338's Names settings
-- (Blizzard_SettingsDefinitions_Frame/Nameplates.lua; "Hostle" is the
-- client's spelling) and Blizzard_Commentator's pet/guardian/totem flags.
-- Not nameplates. Only those the client has are touched. MEASURED 70338
-- (/lsprobe names): all exist, and set to "0" no name text is left in the
-- world (docs/DESIGN.md).
lib.WORLD_NAME_CVARS = fill(lib.WORLD_NAME_CVARS or {}, {
    "UnitNameOwn",
    "UnitNameFriendlyPlayerName",
    "UnitNameFriendlyMinionName",
    "UnitNameFriendlyPetName",
    "UnitNameFriendlyGuardianName",
    "UnitNameFriendlyTotemName",
    "UnitNameEnemyPlayerName",
    "UnitNameEnemyMinionName",
    "UnitNameEnemyPetName",
    "UnitNameEnemyGuardianName",
    "UnitNameEnemyTotemName",
    "UnitNameNPC",
    "UnitNameFriendlySpecialNPCName",
    "UnitNameHostleNPC",
    "UnitNameInteractiveNPC",
    "UnitNameNonCombatCreatureName",
})

-- The key a consumer's db table carries the capture under while presenting.
lib.DB_KEY = "LibShowcaseCapture"
-- And the world-name capture (hideWorldNames), apart: an older copy healing
-- LibShowcaseCapture must find the shape it knows.
lib.NAMES_DB_KEY = "LibShowcaseNames"
-- Set once the login repair of #51 has run for this db (MINOR 12).
lib.VIEW_REPAIR_DB_KEY = "LibShowcaseViewRepaired"

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
    hideWorldNames = false,
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
    hideWorldNames = "boolean",
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
        hideWorldNames = o.hideWorldNames == true,
    }
end

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

-- The lockdown itself: what blocks SetUIVisibility from addon code and a
-- protected frame's SetParent (MEASURED 70959, docs/DESIGN.md "Combat").
local function Locked()
    return type(InCombatLockdown) == "function" and InCombatLockdown() and true or false
end

-- Combat has started: the lockdown, or the client's own combat flag. MEASURED
-- 70959 (/fp steps ls combat, run #466): inside PLAYER_REGEN_DISABLED,
-- InCombatLockdown() is still false but UnitAffectingCombat("player") is
-- already true. So a consumer's handler that runs after the library's (the
-- order is not ours) is refused too (#21). It refuses new work (Enter,
-- HideGameUI, a protected Lift); the library's own restore in that handler
-- still runs, unlocked, on Locked().
local function InCombat()
    if Locked() then return true end
    -- rawget, as for every optional global: a consumer's strict mock without
    -- it must not error (#56).
    local affecting = rawget(_G, "UnitAffectingCombat")
    return type(affecting) == "function" and affecting("player") == true
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
-- Every path that ends a presentation or brings the UI back comes through
-- here, so the world names go back here too.
function I.MaybeRelease()
    I.SyncNames(true)
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
    if Locked() and IsProtectedFrame(frame) then
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
    -- A Blizzard dialog already up (an invite, a summon), or a prompt still
    -- open (a ready check, a loot roll: PROMPT_START), would vanish with the
    -- UI and nothing would bring it back: its Show already happened. Leave
    -- the UI up, as a dialog appearing later brings it back.
    if I.AnyDialogShown(false) or I.PromptOpen() then return false, "dialog" end

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
    if ok then I.SyncNames() else I.MaybeRelease() end
    return ok, why
end

-- The core restore: no lease check, no release. Clears the flag BEFORE the
-- engine call, so the SetUIVisibility hook sees a restore already under way.
-- `shown`: the UI is already back (the player's own Alt+Z or Escape, which
-- the lockdown doesn't block): only the record and the lifts follow it.
-- In a lockdown SetUIVisibility from addon code is BLOCKED (MEASURED 70959):
-- the call is not made, the UI stays marked hidden (so the lease is held)
-- and the lifts stay up (a window put back under the hidden UI would vanish),
-- and PLAYER_REGEN_ENABLED shows it (#42). Returns true when the UI is back.
function I.ShowUI(shown)
    if not st.uiHidden then return false end
    if not shown and Locked() then
        st.showOwed = true
        return false
    end
    st.uiHidden, st.showOwed = false, nil
    if not shown and type(SetUIVisibility) == "function" then pcall(SetUIVisibility, true) end
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
-- World names (hideWorldNames)
--------------------------------------------------------------------------------
-- Player, pet/minion and NPC names drawn in the world stay up with the game UI
-- hidden. With hideWorldNames, the owner's showcase turns them off: while its
-- presentation runs (exit animation included; a dialog bringing the UI back
-- does not end it), and, camera OFF, while HideGameUI has the UI hidden.
-- Whatever ends that (Exit, Escape/Alt+Z, combat, logout, loading, a restore,
-- a dialog revealing a HideGameUI-only UI) puts them back through
-- MaybeRelease. Combat restores at PLAYER_REGEN_DISABLED, still unlocked, and
-- Enter and HideGameUI refuse in combat: the CVars are never written in a
-- lockdown.
--
-- st.names = { inst, capture }: capture is cvar -> the player's value, only
-- for the CVars that exist and are not already "0" (only those are written;
-- one already off is never touched). Read whole BEFORE the first write, and
-- taken once: a second Enter, or HideGameUI then Enter, keeps the first.
-- The player's changes meanwhile: a name turned on stays on (one that was
-- off is not captured, so not written back; one that was on goes back on).
-- One turned off reads as the library's "0" and goes back to the player's
-- value from before: the CVars are booleans, and that is the only case.

-- The instance whose showcase wants the names hidden now, or nil.
function I.NamesWanted()
    local inst, cam = st.owner, st.cam
    if not inst then return nil end
    if cam.active and cam.inst == inst then
        return cam.cfg and cam.cfg.hideWorldNames and inst or nil
    end
    return st.uiHidden and inst.opts.hideWorldNames == true and inst or nil
end

-- Put a capture back (a restore, or a heal), in the list's order. Only the
-- listed name CVars, and only those this client has: a heal's capture comes
-- from SavedVariables (hand-edited, another build), and writing an absent
-- CVar would create it.
function I.RestoreNames(cap)
    if type(GetCVar) ~= "function" or type(SetCVar) ~= "function" then return end
    for _, cvar in ipairs(lib.WORLD_NAME_CVARS) do
        local value = cap[cvar]
        if (type(value) == "string" or type(value) == "number") and GetCVar(cvar) ~= nil then
            pcall(SetCVar, cvar, value)
        end
    end
end

-- A capture an earlier session left in `db`: put back and cleared.
function I.HealNames(inst, db)
    local cap = db[lib.NAMES_DB_KEY]
    if type(cap) ~= "table" then return false end
    I.RestoreNames(cap)
    db[lib.NAMES_DB_KEY] = nil
    I.Debug(inst, "restored the world names a previous session left hidden")
    return true
end

-- Only through SyncNames, which never takes a second capture.
function I.HideNames(inst)
    if type(GetCVar) ~= "function" or type(SetCVar) ~= "function" then return end
    -- A capture an earlier session left (HideGameUI does not heal) goes back
    -- first, or the zeroes it left would be read as the player's.
    local db = I.DB(inst)
    if db then I.HealNames(inst, db) end
    local cap, n = {}, 0
    for _, cvar in ipairs(lib.WORLD_NAME_CVARS) do
        local v = GetCVar(cvar)
        if v ~= nil and v ~= "0" then cap[cvar] = v; n = n + 1 end
    end
    -- The db table itself is kept: the restore clears the capture from it
    -- even if the consumer's db function no longer answers then.
    st.names = { inst = inst, capture = cap, db = db }
    if db and n > 0 then db[lib.NAMES_DB_KEY] = cap end
    for _, cvar in ipairs(lib.WORLD_NAME_CVARS) do
        if cap[cvar] then pcall(SetCVar, cvar, "0") end
    end
    I.Debug(inst, "world names hidden: " .. n .. " CVar(s)")
end

function I.ShowNames()
    local names = st.names
    if not names then return end
    st.names = nil
    I.RestoreNames(names.capture)
    local db = names.db
    if type(db) == "table" and db[lib.NAMES_DB_KEY] == names.capture then db[lib.NAMES_DB_KEY] = nil end
    I.Debug(names.inst, "world names restored")
end

-- `restoreOnly` (the release check): never starts a capture, so an unrelated
-- Drop or failed Lift cannot hide names mid-session.
function I.SyncNames(restoreOnly)
    local inst = I.NamesWanted()
    if inst and not st.names and not restoreOnly then
        I.HideNames(inst)
    elseif not inst and st.names then
        I.ShowNames()
    end
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
-- or party invite, a summon; a ready check, a loot roll: PROMPT_START below)
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
    if st.uiHidden then
        -- In a lockdown: the UI comes back at PLAYER_REGEN_ENABLED, and the
        -- owner is told then, not now (#42).
        st.revealOwed = reason
        I.Debug(inst, "game UI owed after combat: " .. tostring(reason))
        return true
    end
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
-- poll, a PvP role popup, a loot roll; and the timers drawn under UIParent:
-- a group's pull countdown and a battleground or arena start timer (#40,
-- in the 70959 dump, times in seconds). Their start events (the others in
-- the 70205 dump) bring the UI back the same way; listening to an event
-- touches nothing. A prompt stays OPEN (st.prompts: key -> GetTime() it expires)
-- until its end event, or its own time limit, or PROMPT_TIMEOUT: while one is
-- open the UI is not hidden (HideUI), as for a StaticPopup already up. The
-- role poll has no end event; its timeout ends it. A timer (the third
-- return: true) is held for its whole reported time, up to TIMER_LIMIT, the
-- client's longest countdown (PartyCountdownConstants.MaxCountdownSeconds,
-- 70959): a 120 s countdown must not be hidden after 60 s.
local PROMPT_TIMEOUT = 60
local TIMER_LIMIT = 3600

-- A payload value addon code may read, or nil. The 70959 dump marks
-- START_PLAYER_COUNTDOWN secret in a chat-messaging lockdown, and converting
-- or comparing a secret value errors in addon code; canaccessvalue is in the
-- 70959 dump (FrameScript). A client without it has no secret values.
-- Whether the event even arrives in that lockdown is not measured.
local function Plain(v)
    local can = rawget(_G, "canaccessvalue")
    if type(can) ~= "function" then return v end
    local ok, yes = pcall(can, v)
    if ok and yes then return v end
    return nil   -- one value, not none: tonumber() and tostring() need an argument
end

local PROMPT_START = {   -- event -> function(...) returning key, seconds?, timer?
    READY_CHECK         = function(_, timeLeft) return "ready", tonumber(timeLeft) end,
    LFG_PROPOSAL_SHOW   = function() return "lfg" end,
    LFG_ROLE_CHECK_SHOW = function() return "rolecheck" end,
    ROLE_POLL_BEGIN     = function() return "rolepoll" end,
    PVP_ROLE_POPUP_SHOW = function() return "pvprole" end,
    START_LOOT_ROLL     = function(rollID, rollTime)
        return "roll:" .. tostring(rollID), (tonumber(rollTime) or 0) / 1000   -- milliseconds
    end,
    START_PLAYER_COUNTDOWN = function(_, timeRemaining)
        return "countdown", tonumber(Plain(timeRemaining)), true
    end,
    START_TIMER         = function(timerType, timeRemaining)
        return "timer:" .. tostring(Plain(timerType)), tonumber(Plain(timeRemaining)), true
    end,
}
local PROMPT_END = {     -- event -> function(...) returning the key, or a key prefix ending in "*"
    READY_CHECK_FINISHED   = function() return "ready" end,
    LFG_PROPOSAL_DONE      = function() return "lfg" end,
    LFG_PROPOSAL_FAILED    = function() return "lfg" end,
    LFG_PROPOSAL_SUCCEEDED = function() return "lfg" end,
    LFG_ROLE_CHECK_HIDE    = function() return "rolecheck" end,
    LFG_ROLE_CHECK_DECLINED = function() return "rolecheck" end,
    PVP_ROLE_POPUP_HIDE    = function() return "pvprole" end,
    CANCEL_LOOT_ROLL       = function(rollID) return "roll:" .. tostring(rollID) end,
    CANCEL_ALL_LOOT_ROLLS  = function() return "roll:*" end,
    CANCEL_PLAYER_COUNTDOWN = function() return "countdown" end,
    STOP_TIMER_OF_TYPE     = function(timerType) return "timer:" .. tostring(Plain(timerType)) end,
}
local PROMPT_EVENTS = {}
for ev in pairs(PROMPT_START) do PROMPT_EVENTS[#PROMPT_EVENTS + 1] = ev end
for ev in pairs(PROMPT_END) do PROMPT_EVENTS[#PROMPT_EVENTS + 1] = ev end
table.sort(PROMPT_EVENTS)

st.prompts = st.prompts or {}

local function Now()
    return type(GetTime) == "function" and tonumber(GetTime()) or 0
end

-- A start or end event: true when it was one.
function I.OnPromptEvent(event, ...)
    local start, stop = PROMPT_START[event], PROMPT_END[event]
    if start then
        local key, seconds, timer = start(...)
        local limit = timer and TIMER_LIMIT or PROMPT_TIMEOUT
        if not seconds or seconds <= 0 then seconds = PROMPT_TIMEOUT end
        st.prompts[key] = Now() + math.min(seconds, limit) + 1
        I.RevealForDialog("dialog")
        return true
    elseif stop then
        local key = stop(...)
        if key:sub(-1) == "*" then
            local prefix = key:sub(1, -2)
            for k in pairs(st.prompts) do
                if k:sub(1, #prefix) == prefix then st.prompts[k] = nil end
            end
        else
            st.prompts[key] = nil
        end
        return true
    end
    return false
end

-- The client's own answer, for a prompt that started before the first copy
-- of the library loaded (a load-on-demand consumer: no start event seen).
-- Read-only getters, each in the 70205 dump by name only (no signature):
-- called through pcall, and any answer not of the expected shape counts as
-- "not open". The role poll and the PvP role popup have no getter.
local function Ask(name, ...)
    local f = rawget(_G, name)
    if type(f) ~= "function" then return nil end
    local ok, a = pcall(f, ...)
    if ok then return a end
end

function I.LivePromptOpen()
    if Ask("GetReadyCheckStatus", "player") == "waiting" then
        local left = Ask("GetReadyCheckTimeLeft")
        if type(left) ~= "number" or left > 0 then return true end
    end
    if Ask("GetLFGProposal") == true then return true end
    if Ask("GetLFGRoleUpdate") == true then return true end
    local ids = Ask("GetActiveLootRollIDs")
    if type(ids) == "table" then
        for _, id in ipairs(ids) do
            local left = Ask("GetLootRollTimeLeft", id)
            if type(left) == "number" and left > 0 then return true end
        end
    end
    return false
end

-- Any prompt still open: seen by its events (expired ones are dropped), or
-- reported by the client.
function I.PromptOpen()
    local now, open = Now(), false
    for k, expires in pairs(st.prompts) do
        if expires <= now then st.prompts[k] = nil else open = true end
    end
    return open or I.LivePromptOpen()
end

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
-- `sex` (optional, UnitSex's: 3 female) picks the female pair (#38);
-- anything else, or none, the male one, as before.
function I.ShoulderOffsetFor(race, zoom, mounted, sex)
    zoom = tonumber(zoom) or 0
    if mounted then
        local m = lib.MOUNTED_SHOULDER_FACTORS
        return zoom * m[1] + m[2]
    end
    local id = tonumber(race) or (race ~= nil and lib.RACE_IDS[race]) or 0
    if not lib.SHOULDER_FACTORS[id] then id = 0 end
    local f = (tonumber(sex) == 3 and lib.FEMALE_SHOULDER_FACTORS[id]) or lib.SHOULDER_FACTORS[id]
    return zoom * f[1] + f[2]
end
lib.ShoulderOffsetFor = lib.ShoulderOffsetFor
    or function(...) return lib.impl.ShoulderOffsetFor(...) end

function I.PlayerShoulderOffset(cfg, zoom)
    if I.IsMounted(cfg) then
        return cfg.mountedShoulder or I.ShoulderOffsetFor(nil, cfg.mountedZoom, true)
    end
    local race, sex
    if type(UnitRace) == "function" then
        local _, raceFile, raceID = UnitRace("player")
        race = tonumber(raceID) or raceFile
    end
    local unitSex = rawget(_G, "UnitSex")   -- rawget: optional (#56)
    if type(unitSex) == "function" then sex = unitSex("player") end
    return I.ShoulderOffsetFor(race, cfg.shoulderRef or zoom, nil, sex) * cfg.shoulderMult
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

-- Gamepad mode: Blizzard_Gamepad/Core.lua holds the centring CVars with TEMP
-- values (C_CVar.SetTempCVar: KeepCharacterCentered 1, ReduceUnexpected 0).
-- MEASURED 70959 (/fp steps ls tempcvar, runs #474 to #476; #54): under a
-- temp, GetCVar reads the temp and a SetCVar is invisible but lands on the
-- player's stored value. So a capture there would take the temp for the
-- player's value, and its restore would write it over theirs. In gamepad
-- mode the centring CVars are left alone. The same test as Blizzard's
-- InputUtil.IsGamepadUIEnabled(); both names are in the 70959 dump, and the
-- enum's Gamepad value is 1 (InputDeviceInterfaceType).
function I.GamepadMode()
    local style = rawget(_G, "C_InputInterfaceStyle")
    if type(style) ~= "table" or type(style.GetCurrentStyle) ~= "function" then return false end
    local enum = rawget(_G, "Enum")
    local types = type(enum) == "table" and enum.InputDeviceInterfaceType
    local gamepad = type(types) == "table" and types.Gamepad or 1
    local ok, current = pcall(style.GetCurrentStyle)
    return ok and current == gamepad
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
    -- The player's own view, where the exit ends (#51). Read before SetView
    -- moves it.
    if type(GetCVar) == "function" then capture.view = tonumber(GetCVar("cameraView")) end
    pcall(SaveView, capture.savedViewSlot)
    -- Crash self-heal: the capture lives in the consumer's SavedVariables
    -- until a restore clears it. Filled in as each CVar is changed.
    local db = I.DB(inst)
    if db then db[lib.DB_KEY] = capture end

    cam.active, cam.mode, cam.elapsed = true, "enter", 0
    cam.inst, cam.cfg, cam.capture, cam.anchor = inst, cfg, capture, anchor
    cam.didSalute, cam.presentationViewSaved, cam.viewDone = false, nil, nil
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
        -- In gamepad mode the reads would be the temps and the writes would
        -- land unseen on the player's stored values: nothing is captured or
        -- written (#54).
        if I.GamepadMode() then
            I.Debug(inst, "gamepad mode: the centring CVars are left alone")
        else
            for _, cvar in ipairs(lib.CENTRING_CVARS) do
                local prev = GetCVar(cvar)
                if prev ~= nil then
                    capture[cvar] = prev
                    pcall(SetCVar, cvar, "0")
                end
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
        local yawMoveSpeed = I.YawMoveSpeed()
        local dir = cfg.yawOffset < 0 and -1 or 1
        local degrees = math.abs(cfg.yawDegrees)
        local seconds = math.max(0.05, cfg.enterDuration)
        local speed = Clamp((degrees / yawMoveSpeed) / seconds, 0.10, 4.0, 1.0)
        -- The entry eases toward the orbit speed of this moment; the orbit
        -- itself reads the setting again when it starts (I.OrbitSpeed).
        cam.yawDir, cam.yawFromSpeed, cam.yawToSpeed = dir, speed, I.OrbitSpeed(cfg)
        I.StopYaw()
        I.ApplyYaw(dir * speed)
        I.Debug(inst, string.format("enter yaw: target=%d speed=%.3f yawMoveSpeed=%.1f",
            degrees, speed, yawMoveSpeed))
    end

    lib.animFrame:Show()
    if cfg.hideUI and anchor then I.HideUI(inst, anchor) end
    I.SyncNames()
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
    -- The view back now; the rest is restored when the exit ends. Recorded:
    -- an older copy's exit (to the saved slot) leaves no mark (Codex, PR #63).
    cam.viewDone = cam.capture and I.ExitView(cam.capture) or nil
    lib.animFrame:Show()
    I.Debug(inst, "exit start: " .. tostring(reason or "hide"))
    return true
end

-- Camera Following Style (cameraSmoothStyle): 0 is "Never adjust camera";
-- 1 "Only horizontal when moving", 4 "Only when moving" (the default) and 2
-- "Always adjust camera" follow while moving. Missing or unreadable: follows.
function I.CameraFollows()
    local style = type(GetCVar) == "function" and tonumber(GetCVar("cameraSmoothStyle"))
    return style ~= 0
end

-- The view to go to instead of the saved slot: 2, or 3 when a consumer saves
-- into 2 (savedViewSlot accepts 2-5; Codex, PR #63). Only the slot-5 case is
-- MEASURED to follow (view 2).
function I.FallbackView(slot)
    return tonumber(slot) == 2 and 3 or 2
end

-- The view an exit ends on: the player's own (cameraView at Enter), or the
-- fallback when that was the saved slot or isn't known (an older copy's
-- capture).
function I.OwnView(cap)
    local v = tonumber(cap.view)
    if not v or v < 1 or v > 5 or v == cap.savedViewSlot then return I.FallbackView(cap.savedViewSlot) end
    return math.floor(v)
end

-- #51. MEASURED 70959+ (/fp steps ls savedview and viewfix, runs #572 to
-- #590, on Always and on Only when moving): the camera follows on view 2,
-- also after SaveView(5); SetView(5) onto the saved view stops it, and the
-- client keeps cameraView, so every later login loads view 5 and it stays
-- stopped (ResetView(5) helps only until then). SetView back to the player's
-- view follows at once and after a /reload, at the cost of that view's
-- framing: the zoom goes back after it. Writing only the cameraView CVar
-- leaves the camera where it is and takes effect at the next login.
-- So on a style that follows, the exit ends on the player's own view; on
-- Never, it keeps the exact snap-back to the saved view, and the cameraView
-- CVar is written back at the end (RestoreCapture). True when it put the
-- player's own view and zoom back, so the end of the exit leaves them.
function I.ExitView(cap)
    if not cap.savedViewSlot or type(SetView) ~= "function" then return false end
    if I.CameraFollows() then
        pcall(SetView, I.OwnView(cap))
        if type(GetCameraZoom) == "function" then I.SetZoom(cap.zoom or 0) end
        return true
    end
    pcall(SetView, cap.savedViewSlot)
    return false
end

-- Put the camera and every CVar back as captured. Shared by every restore
-- and by the login self-heal. A nil capture entry means the CVar did not
-- exist: writing a default over it would invent a setting. `viewDone`: this
-- copy's ExitView already put the player's own view and zoom back (a second
-- SetView would snap the zoom to the view's own mid-animation). Anything
-- else, an older copy's exit to the saved slot included, isn't done.
function I.RestoreCapture(cap, viewDone)
    local follows = I.CameraFollows()
    if not (follows and viewDone == true) then
        if cap.savedViewSlot and type(SetView) == "function" then
            pcall(SetView, follows and I.OwnView(cap) or cap.savedViewSlot)
        end
        if type(GetCameraZoom) == "function" then I.SetZoom(cap.zoom or 0) end
    end
    if type(SetCVar) == "function" then
        if cap.cameraDistanceMaxZoomFactor then
            pcall(SetCVar, "cameraDistanceMaxZoomFactor", cap.cameraDistanceMaxZoomFactor)
        end
        if cap.shoulderOffset then
            I.SuppressExperimentalCVarPopup()
            pcall(SetCVar, "test_cameraOverShoulder", cap.shoulderOffset)
        end
        -- Written back whatever the input mode now: in gamepad mode the write
        -- lands on the stored value, unseen, which is where it belongs. Any
        -- capture of them (an older copy's too, even one taken under
        -- gamepad mode's temps) comes with that copy's "0" already written
        -- over the stored values, so writing the capture is never worse than
        -- leaving the "0" (#54; Codex on PR #55).
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
    -- Never: the camera stays on the saved view's framing for this session,
    -- and the next login loads the player's own view, not the saved one.
    if not follows and cap.savedViewSlot and type(SetCVar) == "function" then
        pcall(SetCVar, "cameraView", tostring(I.OwnView(cap)))
    end
end

-- Everything back, at once: UI, camera, CVars, lifts. Protected
-- frames in combat wait for PLAYER_REGEN_ENABLED (and hold the lease).
function I.Restore(inst, reason)
    local cam = st.cam
    I.ShowUI()
    I.StopYaw()
    lib.animFrame:Hide()
    if cam.capture then
        I.RestoreCapture(cam.capture, cam.mode == "exit" and cam.viewDone)
        local db = cam.inst and I.DB(cam.inst)
        if db and db[lib.DB_KEY] == cam.capture then db[lib.DB_KEY] = nil end
    end
    I.SetCastEvents(false)
    local wasActive = cam.active
    cam.active, cam.mode, cam.capture, cam.elapsed = false, nil, nil, 0
    cam.inst, cam.cfg, cam.anchor = nil, nil, nil
    cam.presentationViewSaved, cam.castResetDuration, cam.resumeAfterReset = nil, nil, nil
    cam.viewDone = nil
    -- The lifts stay while the UI is still hidden (a show owed after the
    -- lockdown, #42): PLAYER_REGEN_ENABLED drops them with it.
    if not st.uiHidden then I.DropAll() end
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

-- The player's camera turn speed (cameraYawMoveSpeed; 180 when unset or
-- not a positive number).
function I.YawMoveSpeed()
    local v = tonumber(type(GetCVar) == "function" and GetCVar("cameraYawMoveSpeed")) or 180
    if v <= 0 then v = 180 end
    return v
end

-- The orbit's MoveView*Start speed. That speed is a multiple of
-- cameraYawMoveSpeed, so the orbit is scaled like the turn: orbitSpeed is the
-- speed at the default 180, whatever the player's setting (#39). Read each
-- time the orbit starts or resumes, since the player may change the setting
-- mid-presentation (Codex, #48).
function I.OrbitSpeed(cfg)
    return cfg.orbitSpeed * (180 / I.YawMoveSpeed())
end

-- The settled presentation: a slow orbit, or still. With castAware, the
-- settled view is saved first so a cast can return to it.
function I.Settle(cam)
    I.StopYaw()
    if cam.cfg.castAware and cam.cfg.presentationViewSlot then
        cam.presentationViewSaved = pcall(SaveView, cam.cfg.presentationViewSlot) and true or false
    end
    if cam.cfg.orbit then I.ApplyOrbit((cam.yawDir or 1) * I.OrbitSpeed(cam.cfg)) end
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
    if cam.cfg.orbit then I.ApplyOrbit((cam.yawDir or 1) * I.OrbitSpeed(cam.cfg)) end
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

-- #51: r3 to r11 ended every presentation on the saved view, where the camera
-- doesn't follow, and the client loads cameraView at every login: a player
-- who ever saw one is still there. Once per consumer db, at login, on a style
-- that follows: a player found on the saved view goes back to view 2 (3 when
-- the saved slot is 2). The
-- camera has just been placed at login, so the move costs nothing. Not on
-- Never (it follows nothing anyway), so a later switch to a following style
-- still gets the repair. A player who chose that view is moved once.
function I.RepairView(inst)
    if st.cam.active or (st.owner ~= nil and st.owner ~= inst) then return false end
    local db = I.DB(inst)
    if not db or db[lib.VIEW_REPAIR_DB_KEY] then return false end
    if type(GetCVar) ~= "function" or type(SetView) ~= "function" then return false end
    if not I.CameraFollows() then return false end
    db[lib.VIEW_REPAIR_DB_KEY] = true
    local slot = I.Config(inst).savedViewSlot
    if tonumber(GetCVar("cameraView")) ~= slot then return false end
    local to = I.FallbackView(slot)
    pcall(SetView, to)
    I.Debug(inst, ("on the saved view %d at login: back to view %d (#51)"):format(slot, to))
    return true
end

-- A capture still in a db at login means the last session ended without a
-- restore (a crash, a killed client): put the player's camera back.
function I.Heal(inst)
    -- Not while the camera is someone else's: another instance's lease (a
    -- camera-OFF owner, deferred cleanup) or a presentation. The capture
    -- stays; this instance's next Enter heals it, holding the lease.
    if st.cam.active or (st.owner ~= nil and st.owner ~= inst) then return false end
    local db = I.DB(inst)
    if not db then return false end
    local healed = false
    local cap = db[lib.DB_KEY]
    if type(cap) == "table" then
        I.RestoreCapture(cap)
        db[lib.DB_KEY] = nil
        I.Debug(inst, "restored the camera a previous session left changed")
        healed = true
    end
    -- Not while this instance has the names hidden (HideGameUI, then Enter):
    -- the capture in the db is then the live one.
    if not st.names and I.HealNames(inst, db) then healed = true end
    return healed
end

function I.OnEvent(event, ...)
    if I.OnPromptEvent(event, ...) then return end
    if event == "PLAYER_LOGIN" then
        I.InstallDialogHooks()
        for _, inst in ipairs(lib.instances) do
            I.Heal(inst)
            I.RepairView(inst)
        end
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        -- Deferred drops of protected frames; a hide that outlived combat,
        -- or a show the lockdown blocked (#42), with the owner told now.
        local owner, reason = st.owner, st.revealOwed
        st.revealOwed = nil
        if st.uiHidden and I.ShowUI() and reason and owner then
            I.Debug(owner, "game UI shown: " .. tostring(reason))
            I.NotifyShown(owner, reason)
        end
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
    -- A call the lockdown blocked (an addon's) changes nothing: only a UI
    -- actually back is the player's Escape or Alt+Z.
    if UIParent and UIParent.IsShown and not UIParent:IsShown() then return end
    local inst = st.owner
    st.showOwed, st.revealOwed = nil, nil
    I.Notify(inst, "ui-shown")
    if st.owner ~= inst then return end
    if st.uiHidden then I.ShowUI(true) end
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
for _, ev in ipairs(PROMPT_EVENTS) do
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
    if type(IsLoggedIn) == "function" and IsLoggedIn() then
        I.Heal(inst)
        I.RepairView(inst)
    end
    return inst
end

-- Upgrading in place: older instances get what this copy adds, nothing else.
for _, inst in ipairs(lib.instances) do I.Migrate(inst) end

-- Test-only internals.
lib._test = { fill = fill, fillMissing = fillMissing, Clamp = Clamp }

lib.ready = MINOR
