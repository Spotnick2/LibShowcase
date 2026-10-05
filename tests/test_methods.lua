-- Every widget method the library calls must exist on this client.
--
-- The stub answers any method call, so a call to a method Forever lacks would
-- otherwise pass silently. This checks each recorded "Type:Method" against
-- the API dump's widget-method walk (GameTooltip falls back to Frame, which
-- it inherits from).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local f = io.open(WoW.DUMP, "r")
if not f then
    io.write("test_methods: SKIPPED (no API dump at " .. WoW.DUMP .. ")\n")
    os.exit(0)
end
local widget = {}
for line in f:lines() do
    local wm = line:match("^(%a+:%a+)%s*$")
    if wm then widget[wm] = true end
end
f:close()

-- Exercise everything, so every method is recorded. Only the library's
-- calls are kept: the stub's own setup calls are cleared first.
local lib = freshLibrary()
local SC = lib:New({ owner = "A", castAware = true, dynamicPitch = true, pitchLimit = 1, viewBlendStyle = 2 })
local win = newWindow()
local popup = CreateFrame("Frame", nil, UIParent)
local eb = CreateFrame("EditBox", "ChatFrame1EditBox", UIParent)
rawset(_G, "ChatEdit_DeactivateChat", false)    -- the fallback path: ClearFocus/Hide
WoW.methodsCalled = {}
SC:Enter(win)
StaticPopup_Show("PARTY_INVITE")              -- the reveal path
SC:HideGameUI(win)
SC:LiftPopup(popup)
WoW.tick(0.1, 16)
WoW.fire("UNIT_SPELLCAST_START", "player")
WoW.fire("UNIT_SPELLCAST_STOP", "player")
SC:Lift(newWindow())
SC:Exit("closed")
WoW.tick(0.1, 10)
SC:Acquire(); SC:HideGameUI(win); SC:Release()
check(eb._focus == false, "the chat box fallback ran")

local n = 0
for name in pairs(WoW.methodsCalled) do
    n = n + 1
    local wtype, method = name:match("^(%a+):(%a+)$")
    check(widget[name] or widget["Frame:" .. method], "method exists on Forever: " .. name)
end
check(n >= 15, "recorded a realistic number of methods (" .. n .. ")")
done("test_methods")
