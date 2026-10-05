-- Two addons, two instances: each one's options, callbacks and db are its own,
-- while the shared state (the one camera) is one table.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local lib = freshLibrary("AltStable")
local dbA, dbB = {}, {}
local gotA, gotB = {}, {}
local A = lib:New({ owner = "AltStable", zoom = 2.2, db = dbA, onForcedExit = function(r) gotA[#gotA + 1] = r end })
local B = lib:New({ owner = "PortalRoulette", zoom = 3, castAware = true, db = function() return dbB end,
                    onForcedExit = function(r) gotB[#gotB + 1] = r end })

check(A.opts ~= B.opts, "each instance has its own options table")
eq(A.Enter, B.Enter, "methods are shared (one dispatch table)")
eq(getmetatable(A), getmetatable(B), "through one metatable")
eq(#lib.instances, 2, "the library knows both instances")

-- Options are per instance.
A.opts.yawDegrees = 100
eq(B.opts.yawDegrees, 430, "changing A's options leaves B's alone")

-- A presents: its options, its db, its callback.
A:Enter(newWindow())
eq(WoW.camera.zoom, 2.2, "A presents with A's zoom")
check(dbA.LibShowcaseCapture ~= nil and dbB.LibShowcaseCapture == nil, "A's capture goes to A's db only")
check(not lib.eventFrame:IsEventRegistered("UNIT_SPELLCAST_START"), "B's castAware does not leak into A's presentation")
WoW.enterCombat()
eq(#gotA, 1, "A's onForcedExit is called")
eq(#gotB, 0, "B's is not")
WoW.leaveCombat()
eq(dbA.LibShowcaseCapture, nil, "A's db is cleared by the restore")

-- B presents.
B:Enter(newWindow())
eq(WoW.camera.zoom, 3, "B presents with B's zoom")
check(lib.eventFrame:IsEventRegistered("UNIT_SPELLCAST_START"), "and B's castAware")
check(dbB.LibShowcaseCapture ~= nil and dbA.LibShowcaseCapture == nil, "B's capture in B's db")
WoW.fire("PLAYER_LOGOUT")
eq(gotB[1], "logout", "B is told")
eq(#gotA, 1, "A is not")

-- Self-heal is per db: only the db holding a capture is restored and cleared.
dbA.LibShowcaseCapture = { CameraKeepCharacterCentered = "1" }
WoW.cvars.CameraKeepCharacterCentered = "0"
WoW.fire("PLAYER_LOGIN")
eq(WoW.cvars.CameraKeepCharacterCentered, "1", "A's leftover capture healed")
eq(dbA.LibShowcaseCapture, nil, "and cleared")

done("test_isolation")
