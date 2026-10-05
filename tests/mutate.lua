-- mutate.lua: mutation-test the suite (CLAUDE.md; EMBEDDED-LIBRARIES §8).
-- Each mutation breaks one rule in a copy of LibShowcase.lua; the suite must
-- then go red. A mutation the suite survives is a rule no test enforces.
--
-- Not a test_*.lua file, so run.ps1 doesn't run it. From the repo root:
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\mutate.lua [filter]

local LUA = arg[-1]
local filter = arg[1]

local function read(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return (s:gsub("\r\n", "\n"))
end

-- { name, { { from, to }, ... } }: plain-text substitutions, each matching once.
local M = {
    -- Dispatch at call time (§5.2)
    { "hook captures an implementation", {
        { 'hooksecurefunc("SetUIVisibility", function(visible) return lib.impl.OnSetUIVisibility(visible) end)',
          'local captured = lib.impl.OnSetUIVisibility\n    hooksecurefunc("SetUIVisibility", function(visible) return captured(visible) end)' } } },
    { "OnUpdate captures an implementation", {
        { 'lib.animFrame:SetScript("OnUpdate", function(_, elapsed) return lib.impl.OnUpdate(elapsed) end)',
          'local captured = lib.impl.OnUpdate\n    lib.animFrame:SetScript("OnUpdate", function(_, elapsed) return captured(elapsed) end)' } } },
    { "OnEvent captures an implementation", {
        { 'lib.eventFrame:SetScript("OnEvent", function(_, event, ...) return lib.impl.OnEvent(event, ...) end)',
          'local captured = lib.impl.OnEvent\n    lib.eventFrame:SetScript("OnEvent", function(_, event, ...) return captured(event, ...) end)' } } },
    { "StaticPopup_Show hook captures an implementation", {
        { 'hooksecurefunc("StaticPopup_Show", function() lib.impl.OnStaticPopupShow() end)',
          'local captured = lib.impl.OnStaticPopupShow\n        hooksecurefunc("StaticPopup_Show", function() captured() end)' } } },
    { "StaticPopupSpecial_Show hook captures an implementation", {
        { 'hooksecurefunc("StaticPopupSpecial_Show", function() lib.impl.OnStaticPopupSpecialShow() end)',
          'local captured = lib.impl.OnStaticPopupSpecialShow\n        hooksecurefunc("StaticPopupSpecial_Show", function() captured() end)' } } },
    { "a method captures an implementation", {
        { "        lib.methods[name] = function(self, ...)\n            lib.impl.Check(self, name)\n            return lib.impl[name](self, ...)",
          "        local captured = lib.impl[name]\n        lib.methods[name] = function(self, ...)\n            lib.impl.Check(self, name)\n            return captured(self, ...)" } } },
    { "an older copy's timer target removed", { { "function I.UnsuppressPopup()\nend\n", "" } } },
    { "methods replaced on upgrade", { { "    if lib.methods[name] == nil then\n", "    if true then\n" } } },
    -- Reuse tables in place (§5.1)
    { "a public table replaced", { { "lib.CENTRING_CVARS = fill(lib.CENTRING_CVARS or {}, {", "lib.CENTRING_CVARS = fill({}, {" } } },
    { "the shared state replaced", { { "lib.state = lib.state or {}", "lib.state = {}" } } },
    { "the instance registry replaced", { { "lib.instances = lib.instances or {}", "lib.instances = {}" } } },
    { "the frames rebuilt", { { "if not lib.animFrame then", "if true then" } } },
    { "events registered again", { { "    if not lib.events[ev] then\n        lib.events[ev] = true\n        lib.eventFrame:RegisterEvent(ev)",
                                     "    if true then\n        lib.events[ev] = true\n        lib.eventFrame:RegisterEvent(ev)" } } },
    { "reveal events registered again", { { "    if not lib.events[ev] then\n        lib.events[ev] = true\n        pcall(",
                                            "    if true then\n        lib.events[ev] = true\n        pcall(" } } },
    { "the hook installed again", { { "if not lib.hooked.SetUIVisibility and type(hooksecurefunc)", "if type(hooksecurefunc)" } } },
    { "the dialog hook installed again", { { "if not lib.hooked.StaticPopup_Show and ", "if " } } },
    { "the special-dialog hook installed again", { { "if not lib.hooked.StaticPopupSpecial_Show and ", "if " } } },
    -- Narrow migration (§5.4), the marker (§5.6)
    { "migration overwrites options", { { "        if dst[k] == nil then\n            dst[k] = type(v)", "        if true then\n            dst[k] = type(v)" } } },
    { "the marker is not checked", { { "    if lib.ready ~= active then\n", "    if false then\n" } } },
    -- The lease
    { "the lease is always granted", { { "    if st.owner == nil then st.owner = inst end\n    return st.owner == inst",
                                         "    st.owner = inst\n    return true" } } },
    { "Enter ignores another owner", { { '    if st.owner ~= nil and st.owner ~= inst then return false, "busy" end\n    local cam = st.cam',
                                          '    local cam = st.cam' } } },
    { "an Acquired lease lapses when idle", { { "if st.owner ~= nil and not st.explicit and I.Idle() then", "if st.owner ~= nil and I.Idle() then" } } },
    { "the lease ignores lifts", { { " and #st.lifts == 0\n", "\n" } } },
    { "the lease ignores the exit animation", { { "return not st.cam.active and not st.uiHidden", "return not st.uiHidden" } } },
    { "non-owners may restore", { { "function I.ForceRestore(inst, reason)\n    if not I.IsOwner(inst) then return false end",
                                    "function I.ForceRestore(inst, reason)" } } },
    { "Release does not restore", { { '    st.explicit = false\n    I.Restore(inst, "release")', '    st.explicit = false\n    st.owner = nil' } } },
    -- Combat
    { "Enter allowed in combat", { { '    if InCombat() then return false, "combat" end\n    if not I.IsSupported()', '    if not I.IsSupported()' } } },
    { "protected frames dropped in combat", { { "    if InCombat() and IsProtectedFrame(frame) then\n        rec.deferred = true",
                                                "    if false then\n        rec.deferred = true" } } },
    { "a protected frame lifted in combat", { { "    if InCombat() and IsProtectedFrame(frame) then\n        I.MaybeRelease()",
                                                "    if false then\n        I.MaybeRelease()" } } },
    { "no drop at PLAYER_REGEN_ENABLED", { { "        I.DropDeferred()\n", "" } } },
    { "combat start does not restore", { { 'if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_LOGOUT"', 'if event == "PLAYER_LOGOUT"' } } },
    { "the owner is not told", { { "        I.Notify(inst, event == \"PLAYER_REGEN_DISABLED\" and \"combat\"", "        I.Notify(nil, event == \"PLAYER_REGEN_DISABLED\" and \"combat\"" } } },
    -- The UI and lifts
    { "the UI flag cleared after the re-show", { { "    st.uiHidden = false\n    if type(SetUIVisibility) == \"function\" then pcall(SetUIVisibility, true) end",
                                                   "    if type(SetUIVisibility) == \"function\" then pcall(SetUIVisibility, true) end\n    st.uiHidden = false" } } },
    { "no exit when the consumer ignores Escape", { { '    if st.cam.active and st.cam.mode ~= "exit" then I.Exit(inst, "ui-shown") end\n', "" } } },
    { "GameTooltip not lifted", { { '    if GameTooltip then I.Lift(inst, GameTooltip, "TOOLTIP") end\n', "" } } },
    { "a second lift saves the lifted state", { { "    if I.FindLift(frame) then return true end\n", "" } } },
    { "scale not compensated", { { '    if type(eff) == "number" then pcall(frame.SetScale, frame, eff) end\n', "" } } },
    { "level not restored", { { "    if rec.level then pcall(frame.SetFrameLevel, frame, rec.level) end\n", "" } } },
    { "the record cleared after the move", { { "    table.remove(st.lifts, i)\n    local ok = pcall(frame.SetParent, frame, rec.parent)",
                                               "    local ok = pcall(frame.SetParent, frame, rec.parent)\n    table.remove(st.lifts, i)" } } },
    -- Blizzard dialogs: never touched; a dialog over the hidden UI brings it back
    { "no StaticPopup_Show hook", { { '        hooksecurefunc("StaticPopup_Show", function() lib.impl.OnStaticPopupShow() end)\n', "" } } },
    { "no StaticPopupSpecial_Show hook", { { '        hooksecurefunc("StaticPopupSpecial_Show", function() lib.impl.OnStaticPopupSpecialShow() end)\n', "" } } },
    { "a refused dialog reveals", { { "    if st.uiHidden and I.AnyDialogShown() then", "    if st.uiHidden then" } } },
    { "the reveal acts with the UI up", { { "    if not inst or not st.uiHidden then return false end\n    I.ShowUI()", "    if not inst then return false end\n    I.ShowUI()" } } },
    { "the reveal read as Escape", { { "    I.ShowUI()\n    I.Debug(inst, \"game UI shown", "    pcall(SetUIVisibility, true)\n    I.Debug(inst, \"game UI shown" } } },
    { "the reveal ends the presentation", { { "    I.ShowUI()\n    I.Debug(inst, \"game UI shown", "    I.Restore(inst, \"dialog\")\n    I.Debug(inst, \"game UI shown" } } },
    { "onGameUIShown not called", { { "    I.NotifyShown(inst, reason)\n", "" } } },
    { "LiftPopup touches the dialog", { { '    if I.IsOwner(inst) then I.RevealForDialog("dialog") end\n',
                                          '    if I.IsOwner(inst) then I.RevealForDialog("dialog") end\n    if dialog then pcall(dialog.SetFrameStrata, dialog, "FULLSCREEN_DIALOG") end\n' } } },
    { "LiftPopup ignores the lease", { { '    if I.IsOwner(inst) then I.RevealForDialog("dialog") end\n', '    I.RevealForDialog("dialog")\n' } } },
    { "the reveal touches the dialog", { { "function I.OnStaticPopupShow()\n",
        "function I.OnStaticPopupShow()\n    StaticPopup_ForEachShownDialog(function(d) pcall(d.HookScript, d, \"OnHide\", function() end) end)\n" } } },
    -- The experimental popup
    { "no suppression before the offset write", { { "    I.SuppressExperimentalCVarPopup()\n    pcall(SetCVar, \"test_cameraOverShoulder\", desired)",
                                                    "    pcall(SetCVar, \"test_cameraOverShoulder\", desired)" } } },
    { "re-registered after a restore (taints the dialog pool)", {
        { "    I.DropAll()\n    I.MaybeRelease()\n    if wasActive",
          "    I.DropAll()\n    pcall(GameEvent.RegisterInternalEvent, POPUP_EVENT, GameEvent.HandleExperimentalCVarConfirmationNeeded)\n    I.MaybeRelease()\n    if wasActive" } } },
    { "an older copy's timer re-registers", {
        { "function I.UnsuppressPopup()\nend\n",
          "function I.UnsuppressPopup()\n    pcall(GameEvent.RegisterInternalEvent, POPUP_EVENT, function(...) return GameEvent.HandleExperimentalCVarConfirmationNeeded(...) end)\nend\n" } } },
    -- The camera
    { "the runner hangs from UIParent", { { 'CreateFrame("Frame", nil, WorldFrame)', 'CreateFrame("Frame", nil, UIParent)' } } },
    { "a missing CVar is created", { { "            if prev ~= nil then\n                capture[cvar] = prev", "            if true then\n                capture[cvar] = prev" } } },
    { "centring not restored", { { "            if cap[cvar] ~= nil then pcall(SetCVar, cvar, cap[cvar]) end\n", "" } } },
    { "the swing always turns right", { { "        local dir = cfg.yawOffset < 0 and -1 or 1\n", "        local dir = 1\n" } } },
    { "the presentation starts from view 3", { { "    pcall(SetView, 2)\n\n", "    pcall(SetView, 3)\n\n" } } },
    { "Exit does not snap the view back", { { "    if cam.capture and cam.capture.savedViewSlot then pcall(SetView, cam.capture.savedViewSlot) end\n", "" } } },
    { "re-entry during exit resumes", { { '        I.Restore(inst, "re-enter during exit")\n', '        cam.mode = "enter"\n        do return true end\n' } } },
    { "shoulder multiplier ignored", { { "    return I.ShoulderOffsetFor(race, cfg.shoulderRef or zoom) * cfg.shoulderMult", "    return I.ShoulderOffsetFor(race, cfg.shoulderRef or zoom)" } } },
    { "pitchlimit not restored", { { '    if cap.pitchLimit and type(ConsoleExec) == "function" then pcall(ConsoleExec, "pitchlimit 88") end\n', "" } } },
    { "castAware hears every unit", { { '        if unit ~= "player" then return end\n', "" } } },
    { "the cast view not saved", { { "        cam.presentationViewSaved = pcall(SaveView, cam.cfg.presentationViewSlot) and true or false\n", "" } } },
    -- Review fixes (#4)
    { "a hidden UI does not lift the anchor", {
        { "        if anchor then I.Lift(inst, anchor, strata) end\n        return true\n", "        return true\n" } } },
    { "a dialog already up is hidden with the UI", {
        { "    if I.AnyDialogShown(false) or I.PromptOpen() then", "    if I.PromptOpen() then" } } },
    { "an open prompt is hidden with the UI", {
        { "    if I.AnyDialogShown(false) or I.PromptOpen() then", "    if I.AnyDialogShown(false) then" } } },
    { "the prompt events ignored", { { "    if I.OnPromptEvent(event, ...) then return end\n", "" } } },
    { "a prompt's end event ignored", { { "    elseif stop then\n", "    elseif false then\n" } } },
    { "a prompt never expires", {
        { "        if expires <= now then st.prompts[k] = nil else open = true end", "        open = true" } } },
    { "a prompt's own time limit ignored", {
        { "        if not seconds or seconds <= 0 then seconds = PROMPT_TIMEOUT end", "        seconds = PROMPT_TIMEOUT" } } },
    { "CANCEL_ALL_LOOT_ROLLS ends one roll", { { '        if key:sub(-1) == "*" then\n', "        if false then\n" } } },
    { "the heal ignores another instance's lease", {
        { "    if st.cam.active or (st.owner ~= nil and st.owner ~= inst) then return false end",
          "    if st.cam.active then return false end" } } },
    { "the reveal events not registered", {
        { "        pcall(lib.eventFrame.RegisterEvent, lib.eventFrame, ev)\n", "" } } },
    { "a missing shoulder CVar is created", {
        { "        if shoulder ~= nil then capture.shoulderOffset", "        if true then capture.shoulderOffset" } } },
    { "a cast reset writes a missing shoulder CVar", {
        { "    if not (cam.capture and cam.capture.shoulderOffset) then return nil end\n", "" } } },
    { "a missing zoom cap is created", { { "        if cap ~= nil then\n", "        if true then\n" } } },
    { "no heal before the capture", { { "    I.Heal(inst)\n\n    local cfg = I.Config(inst)", "    local cfg = I.Config(inst)" } } },
    { "an idle lease restored on combat", { { "        if I.Idle() then return end\n", "" } } },
    -- Self-heal
    { "the capture not written to the db", { { "    if db then db[lib.DB_KEY] = capture end\n", "" } } },
    { "the capture left in the db", { { "        if db and db[lib.DB_KEY] == cam.capture then db[lib.DB_KEY] = nil end\n", "" } } },
    { "no heal at login", { { "        for _, inst in ipairs(lib.instances) do I.Heal(inst) end\n", "" } } },
}

local source = read("LibShowcase.lua")
local tests = {}
for name in io.popen('dir /b tests\\test_*.lua 2>NUL || ls tests/test_*.lua'):lines() do
    tests[#tests + 1] = "tests/" .. name:gsub("^tests[/\\]", "")
end
table.sort(tests)

local mutant = os.tmpname()
if mutant:sub(1, 1) == "\\" then mutant = (os.getenv("TEMP") or ".") .. mutant end
local survived, bad, ran = {}, {}, 0

local function suiteRed()
    for _, t in ipairs(tests) do
        local rc = os.execute(('set "LIBSHOWCASE_MUTANT=%s" && "%s" %s >NUL 2>&1'):format(mutant, LUA, t))
        if rc ~= 0 and rc ~= true then return t end
    end
end

-- Control: the unmutated source, through the same path, must be green, or a
-- "red" below proves nothing.
do
    local f = assert(io.open(mutant, "wb")); f:write(source); f:close()
    local red = suiteRed()
    if red then
        io.write("control run FAILED in " .. red .. ": fix the suite before mutating\n")
        os.exit(1)
    end
    io.write("control run: green\n")
end

for _, m in ipairs(M) do
    if not filter or m[1]:find(filter, 1, true) then
        local src, ok = source, true
        for _, r in ipairs(m[2]) do
            local i, j = src:find(r[1], 1, true)
            if not i or src:find(r[1], j + 1, true) then ok = false; break end
            src = src:sub(1, i - 1) .. r[2] .. src:sub(j + 1)
        end
        if not ok then
            bad[#bad + 1] = m[1]
        else
            ran = ran + 1
            local f = assert(io.open(mutant, "wb")); f:write(src); f:close()
            local red = suiteRed()
            io.write(("%-50s %s\n"):format(m[1], red and ("red (" .. red:match("test_[%w_]+") .. ")") or "SURVIVED"))
            if not red then survived[#survived + 1] = m[1] end
        end
    end
end
os.remove(mutant)
io.write(("\n%d mutations, %d survived, %d did not apply\n"):format(ran, #survived, #bad))
for _, b in ipairs(bad) do io.write("  did not apply (fix the mutation): " .. b .. "\n") end
os.exit((#survived == 0 and #bad == 0) and 0 or 1)
