-- Every widget method the library calls must exist on this client.
--
-- A method the pinned build lacks on one widget type can still answer on the
-- stub (an implementation another type uses), so a call to it would
-- otherwise pass silently. This exercises the library, then checks each
-- recorded "Type:Method" against the build's widget methods with WowTestKit's
-- Kit.checkMethods. Only the library's calls are kept: the test's own setup
-- calls are cleared first.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local lib = freshLibrary()
local SC = lib:New({ owner = "A", castAware = true, dynamicPitch = true, pitchLimit = 1, viewBlendStyle = 2 })
local win = newWindow()
local popup = CreateFrame("Frame", nil, UIParent)
local eb = CreateFrame("EditBox", "ChatFrame1EditBox", UIParent)
eb:SetFocus()                                   -- the chat box is open
rawset(_G, "ChatEdit_DeactivateChat", false)    -- the fallback path: ClearFocus/Hide
WoW.methodsCalled = {}
SC:Enter(win)
StaticPopup_Show("PARTY_INVITE")              -- the reveal path
SC:HideGameUI(win)
SC:LiftPopup(popup)
ticks(0.1, 16)
WoW.fire("UNIT_SPELLCAST_START", "player")
WoW.fire("UNIT_SPELLCAST_STOP", "player")
SC:Lift(newWindow())
SC:Exit("closed")
ticks(0.1, 10)
SC:Acquire(); SC:HideGameUI(win); SC:Release()
check(not eb:HasFocus() and not eb:IsShown(), "the chat box fallback ran")
WoW.methodsCalled["EditBox:HasFocus"] = nil     -- the test's read, not the library's

local recorded = Kit.checkMethods()
check(recorded >= 25, "the exercise reached the lifts, the dialogs and the chat box (" .. recorded .. " recorded)")
done("test_methods")
