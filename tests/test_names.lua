-- hideWorldNames (#14): the owner's showcase turns the world name CVars off
-- and every way out puts back exactly what the player had.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

-- A mixed setup: some names on, some already off, and the pet/guardian/totem
-- flags absent (this client may not have them: never created).
local MIXED = {
    UnitNameOwn = "1", UnitNameFriendlyPlayerName = "1", UnitNameFriendlyMinionName = "0",
    UnitNameEnemyPlayerName = "1", UnitNameEnemyMinionName = "1", UnitNameNPC = "0",
    UnitNameFriendlySpecialNPCName = "1", UnitNameHostleNPC = "1", UnitNameInteractiveNPC = "0",
    UnitNameNonCombatCreatureName = "0", UnitNameFriendlyPetName = "1",
}
local ABSENT = { "UnitNameFriendlyGuardianName", "UnitNameFriendlyTotemName", "UnitNameEnemyPetName",
                 "UnitNameEnemyGuardianName", "UnitNameEnemyTotemName" }

local function setNames()
    for k, v in pairs(MIXED) do WoW.cvars[k] = v end
end

-- Every listed CVar exactly as in `want` (nil: absent).
local function namesAre(lib, want, msg)
    for _, cvar in ipairs(lib.WORLD_NAME_CVARS) do
        if WoW.cvars[cvar] ~= want[cvar] then
            check(false, msg .. ": " .. cvar .. " is " .. tostring(WoW.cvars[cvar]) .. ", expected " .. tostring(want[cvar]))
            return
        end
    end
    check(true, msg)
end

local function namesOff(lib, msg)
    for _, cvar in ipairs(lib.WORLD_NAME_CVARS) do
        local v = WoW.cvars[cvar]
        if MIXED[cvar] == nil then
            if v ~= nil then check(false, msg .. ": " .. cvar .. " was created"); return end
        elseif v ~= "0" then
            check(false, msg .. ": " .. cvar .. " is " .. tostring(v)); return
        end
    end
    check(true, msg)
end

local function nameWrites(from)
    local n = 0
    for _, c in ipairs(callsSince(from)) do
        if c:find("^SetCVar%(UnitName") then n = n + 1 end
    end
    return n
end

------------------------------------------------------------------------------
-- Off by default: an existing consumer's presentation never touches a name.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    setNames()
    local DB = {}
    local SC = lib:New({ owner = "A", db = DB })
    eq(SC.opts.hideWorldNames, false, "hideWorldNames defaults to false")
    SC:Enter(newWindow())
    SC:HideGameUI()
    eq(nameWrites(0), 0, "omitted: no name CVar written")
    eq(DB.LibShowcaseNames, nil, "  and nothing in the db")
    SC:ForceRestore()
    eq(nameWrites(0), 0, "  nor on the way out")
    check(not pcall(lib.New, lib, { owner = "B", hideWorldNames = 1 }), "hideWorldNames must be a boolean")
end

------------------------------------------------------------------------------
-- Enter, Exit: hidden while presenting (exit animation included), the exact
-- mixed settings back, nothing created; the capture is read whole first.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    setNames()
    local DB = {}
    local SC = lib:New({ owner = "A", db = DB, hideWorldNames = true })
    local realSet = SetCVar
    local dbAtFirstWrite
    rawset(_G, "SetCVar", function(name, value)
        if dbAtFirstWrite == nil and name:find("^UnitName") then
            dbAtFirstWrite = DB.LibShowcaseNames and DB.LibShowcaseNames.UnitNameOwn or false
        end
        return realSet(name, value)
    end)
    check(SC:Enter(newWindow()), "an opted-in consumer enters")
    rawset(_G, "SetCVar", realSet)
    namesOff(lib, "every name the client has is off")
    eq(dbAtFirstWrite, "1", "  the capture was in the db before the first write")
    local cap = DB.LibShowcaseNames
    eq(cap.UnitNameOwn, "1", "  the capture holds the player's values")
    eq(cap.UnitNameNPC, nil, "  and not the ones already off (never written)")
    check(DB.LibShowcaseCapture.UnitNameOwn == nil, "  the camera capture keeps its r3 shape")
    for _, cvar in ipairs(ABSENT) do check(cap[cvar] == nil, "  absent " .. cvar .. " not captured") end
    check(not hasCall("SetCVar(UnitNameNPC"), "  a name already off is not written")

    SC:Exit("closed")
    namesOff(lib, "still off during the exit animation")
    WoW.tick(0.1, 10)
    check(not SC:IsOwner(), "the exit finishes")
    namesAre(lib, MIXED, "every name exactly as the player had it")
    eq(DB.LibShowcaseNames, nil, "  and the capture is cleared")
end

------------------------------------------------------------------------------
-- Reopened: the first capture is kept, never replaced by the zeroes.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    setNames()
    local SC = lib:New({ owner = "A", hideWorldNames = true })
    SC:Enter(newWindow())
    local mark = #WoW.calls
    check(SC:Enter(newWindow()), "Enter again while presenting")
    eq(nameWrites(mark), 0, "  writes nothing")
    SC:ForceRestore()
    namesAre(lib, MIXED, "  and the restore puts the player's values back")

    -- Reopened during the exit animation: put back, then a fresh capture.
    SC:Enter(newWindow())
    SC:Exit("closed")
    check(SC:Enter(newWindow()), "re-entered during the exit")
    namesOff(lib, "  names off again")
    eq(lib.state.names.capture.UnitNameOwn, "1", "  the fresh capture holds the player's value, not 0")
    SC:ForceRestore()
    namesAre(lib, MIXED, "  restored exactly")

    -- HideGameUI, then Enter: one capture, and the db one is not healed as stale.
    local DB = {}
    SC.opts.db = DB
    check(SC:HideGameUI(), "HideGameUI hides the UI")
    namesOff(lib, "  and the names")
    local first = lib.state.names.capture
    SC:Enter(newWindow())
    eq(lib.state.names.capture, first, "then Enter: the same capture")
    namesOff(lib, "  names still off (the live capture is not healed)")
    eq(DB.LibShowcaseNames, first, "  and still in the db")
    SC:ForceRestore()
    namesAre(lib, MIXED, "  restored exactly")
    eq(DB.LibShowcaseNames, nil, "  capture cleared")
end

------------------------------------------------------------------------------
-- Escape/Alt+Z, combat, logout, a loading screen: each puts them back.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    setNames()
    local SC = lib:New({ owner = "A", hideWorldNames = true })
    SC:Enter(newWindow())
    SetUIVisibility(true)                         -- Escape
    WoW.tick(0.1, 10)
    namesAre(lib, MIXED, "Escape/Alt+Z: the names come back with the exit")

    for _, ev in ipairs({ "PLAYER_LOGOUT", "PLAYER_ENTERING_WORLD" }) do
        lib = freshLibrary()
        setNames()
        local DB = {}
        SC = lib:New({ owner = "A", db = DB, hideWorldNames = true })
        SC:Enter(newWindow())
        WoW.fire(ev)
        namesAre(lib, MIXED, ev .. ": the names come back")
        eq(DB.LibShowcaseNames, nil, "  and the capture is cleared before SavedVariables are written")
    end

    lib = freshLibrary()
    setNames()
    local got
    SC = lib:New({ owner = "A", hideWorldNames = true, onForcedExit = function(r) got = r end })
    SC:Enter(newWindow())
    local realSet = SetCVar
    local inLockdown = 0
    rawset(_G, "SetCVar", function(name, value)
        if WoW.inCombat and name:find("^UnitName") then inLockdown = inLockdown + 1 end
        return realSet(name, value)
    end)
    WoW.enterCombat()
    namesAre(lib, MIXED, "combat: the names come back at PLAYER_REGEN_DISABLED")
    eq(got, "combat", "  the owner is told")
    eq(inLockdown, 0, "  none written inside the lockdown")
    local ok, why = SC:Enter(newWindow())
    check(not ok and why == "combat", "in combat Enter refuses")
    check(not SC:HideGameUI(), "  and HideGameUI")
    eq(inLockdown, 0, "  without writing a name")
    rawset(_G, "SetCVar", realSet)
    WoW.leaveCombat()
end

------------------------------------------------------------------------------
-- A dialog revealing the UI: the presentation (and the names) go on; camera
-- OFF, the UI back means the showcase is over, so the names come back.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    setNames()
    local SC = lib:New({ owner = "A", hideWorldNames = true })
    SC:Enter(newWindow())
    local d = StaticPopup_Show("PARTY_INVITE")
    check(UIParent:IsShown() and SC:IsActive(), "a dialog reveals the UI, the presentation goes on")
    namesOff(lib, "  the names stay off with it")
    WoW.closeDialog(d)
    SC:ForceRestore()
    namesAre(lib, MIXED, "  and come back with the restore")

    -- Camera OFF: Acquire + HideGameUI.
    local DB = {}
    SC.opts.db = DB
    SC:Acquire()
    local win = newWindow()
    check(SC:HideGameUI(win), "camera OFF: HideGameUI")
    namesOff(lib, "  hides the names")
    d = StaticPopup_Show("PARTY_INVITE")
    check(UIParent:IsShown() and SC:IsOwner(), "a dialog reveals the UI, the Acquired lease stays")
    namesAre(lib, MIXED, "  and the names come back with it")
    eq(DB.LibShowcaseNames, nil, "  capture cleared")
    WoW.closeDialog(d)
    check(SC:HideGameUI(win), "hidden again")
    eq(lib.state.names.capture.UnitNameOwn, "1", "  a fresh capture of the player's values")
    check(SC:RestoreGameUI(), "RestoreGameUI")
    namesAre(lib, MIXED, "  puts them back")
    check(SC:HideGameUI(win), "hidden again")
    SC:Release()
    namesAre(lib, MIXED, "Release puts them back")
    check(not SC:IsOwner(), "  and gives the lease back")

    -- hideUI = false, or no window: names follow the presentation, not the UI.
    SC.opts.hideUI = false
    SC:Enter(newWindow())
    check(UIParent:IsShown(), "hideUI = false: the UI stays up")
    namesOff(lib, "  the names are off for the presentation")
    SC:ForceRestore()
    namesAre(lib, MIXED, "  and back after it")
end

------------------------------------------------------------------------------
-- The player's own changes during the presentation are kept.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    setNames()
    local SC = lib:New({ owner = "A", hideWorldNames = true })
    SC:Enter(newWindow())
    SetCVar("UnitNameNPC", "1")                   -- was off: the player turns it on
    SetCVar("UnitNameOwn", "1")                   -- was on, hidden: the player turns it back on
    SC:ForceRestore()
    eq(WoW.cvars.UnitNameNPC, "1", "a name the player turned on stays on")
    eq(WoW.cvars.UnitNameOwn, "1", "  and one turned back on stays on")
    local want = {}
    for k, v in pairs(MIXED) do want[k] = v end
    want.UnitNameNPC = "1"
    namesAre(lib, want, "  the rest exactly as before")
end

------------------------------------------------------------------------------
-- Review fixes: the release check never starts a capture; a db function that
-- stops answering still gets its capture cleared.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    setNames()
    local SC = lib:New({ owner = "A" })
    local win = newWindow()
    SC:Acquire()
    SC:HideGameUI()
    SC:Lift(win)
    SC.opts.hideWorldNames = true                 -- set for a later session
    local mark = #WoW.calls
    SC:Drop(win)                                  -- goes through the release check
    eq(nameWrites(mark), 0, "an unrelated Drop does not hide names mid-session")
    SC:Release()

    lib = freshLibrary()
    setNames()
    local DB = {}
    local answer = true
    SC = lib:New({ owner = "A", hideWorldNames = true, db = function() return answer and DB or nil end })
    SC:Enter(newWindow())
    check(DB.LibShowcaseNames ~= nil, "the capture is in the db")
    answer = false                                -- e.g. a profile switch
    SC:ForceRestore()
    namesAre(lib, MIXED, "the names come back")
    eq(DB.LibShowcaseNames, nil, "  and the capture is cleared from the db it was written to")
end

------------------------------------------------------------------------------
-- The lease: a refused instance writes nothing, heals nothing.
------------------------------------------------------------------------------
do
    local lib = freshLibrary()
    WoW.loggedIn = true
    setNames()
    local A = lib:New({ owner = "A" })
    A:Enter(newWindow())
    local DBB = { LibShowcaseNames = { UnitNameOwn = "1" } }
    WoW.cvars.UnitNameOwn = "0"                   -- B's last session left it hidden
    local mark = #WoW.calls
    local B = lib:New({ owner = "B", db = DBB, hideWorldNames = true })
    local ok, why = B:Enter(newWindow())
    check(not ok and why == "busy", "B is refused while A presents")
    check(not B:HideGameUI(), "  HideGameUI too")
    eq(nameWrites(mark), 0, "  no name written, B's stale capture not healed under A's lease")
    check(DBB.LibShowcaseNames ~= nil, "  the capture is kept")
    A:ForceRestore()
    eq(WoW.cvars.UnitNameOwn, "0", "A (not opted in) leaves names alone")
    check(B:HideGameUI(), "once free, B hides the UI (camera OFF)")
    eq(lib.state.names.capture.UnitNameOwn, "1", "  the stale capture healed first: the player's value captured")
    B:RestoreGameUI()
    eq(WoW.cvars.UnitNameOwn, "1", "  and put back")
end

------------------------------------------------------------------------------
-- Crash self-heal, /reload, and a full restart.
------------------------------------------------------------------------------
do
    -- /reload and a restart fire PLAYER_LOGOUT: the names are back and the
    -- db is clean before SavedVariables (and Config.wtf) are written.
    local lib = freshLibrary()
    setNames()
    local DB = {}
    lib:New({ owner = "A", db = function() return DB end, hideWorldNames = true }):Enter(newWindow())
    WoW.fire("PLAYER_LOGOUT")
    local persisted = {}
    for k, v in pairs(WoW.cvars) do persisted[k] = v end
    lib = freshLibrary()
    for k, v in pairs(persisted) do WoW.cvars[k] = v end
    lib:New({ owner = "A", db = function() return DB end, hideWorldNames = true })
    WoW.fire("PLAYER_LOGIN")
    namesAre(lib, MIXED, "after a /reload (or a restart): the player's names")

    -- A session that ended with no restore: its capture heals at login.
    lib = freshLibrary()
    setNames()
    DB = {}
    lib:New({ owner = "A", db = function() return DB end, hideWorldNames = true }):Enter(newWindow())
    local saved = {}
    for k, v in pairs(DB.LibShowcaseNames) do saved[k] = v end
    local left = {}
    for k, v in pairs(WoW.cvars) do left[k] = v end
    lib = freshLibrary()
    for k, v in pairs(left) do WoW.cvars[k] = v end
    WoW.cvars.UnitNameEnemyPlayerName = "1"       -- turned on by the player meanwhile
    local DB2 = { LibShowcaseNames = saved }
    lib:New({ owner = "A", db = function() return DB2 end })
    eq(WoW.cvars.UnitNameOwn, "0", "next session starts with the names the crash left off")
    WoW.fire("PLAYER_LOGIN")
    namesAre(lib, MIXED, "PLAYER_LOGIN puts the player's names back")
    eq(DB2.LibShowcaseNames, nil, "  and clears the capture")

    -- An r3-shaped db (camera capture only) heals as before; garbage is ignored.
    lib = freshLibrary()
    setNames()
    WoW.cvars.CameraKeepCharacterCentered = "0"
    local DB3 = { LibShowcaseCapture = { CameraKeepCharacterCentered = "1" },
                  LibShowcaseNames = { UnitNameOwn = {}, [1] = "1", UnitNameEnemyTotemName = "1",
                                       CameraReduceUnexpectedMovement = "1" } }
    lib:New({ owner = "A", db = DB3 })
    local mark = #WoW.calls
    WoW.fire("PLAYER_LOGIN")
    eq(WoW.cvars.CameraKeepCharacterCentered, "1", "the r3 capture shape still heals")
    eq(nameWrites(mark), 0, "  a malformed names capture writes nothing")
    eq(WoW.cvars.UnitNameEnemyTotemName, nil, "  nor creates a CVar this client lacks")
    eq(WoW.cvars.CameraReduceUnexpectedMovement, "0", "  nor writes a CVar outside WORLD_NAME_CVARS")
    eq(DB3.LibShowcaseNames, nil, "  and is dropped")
end

------------------------------------------------------------------------------
-- Upgrade: an r3 instance gets hideWorldNames = false and writes no name.
------------------------------------------------------------------------------
do
    WoW.reset()
    WoW.resetLibStub()
    setNames()
    local r3 = loadCopy(releasedCopy("tests/fixtures/LibShowcase-r3"), "PortalRoulette")
    local A = r3:New({ owner = "PortalRoulette" })
    eq(A.opts.hideWorldNames, nil, "an r3 instance has no hideWorldNames")
    local lib = loadCopy(copyOf(), "AltStable")
    eq(A.opts.hideWorldNames, false, "after the upgrade it is filled in, off")
    check(A:Enter(newWindow()), "the r3 instance presents on the new code")
    eq(nameWrites(0), 0, "  and touches no name")
    A:ForceRestore()
    check(lib.WORLD_NAME_CVARS ~= nil and #lib.WORLD_NAME_CVARS > 0, "WORLD_NAME_CVARS is public")
end

done("test_names")
