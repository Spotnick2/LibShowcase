----------------------------------------------------------------------------
-- LibShowcase Probe: the in-game measurements docs/DESIGN.md still lists as
-- OPEN. Everything goes to a log in SavedVariables (written on /reload and on
-- logout): WTF\Account\<ACCOUNT>\SavedVariables\LibShowcaseProbe.lua.
--
--   /lsprobe pitch [off]   test_cameraDynamicPitch with centring cleared:
--                          walk forward/backward and watch for a pitch tilt
--   /lsprobe nudge [0|1]   the shoulder offset written without (0) and with
--                          (1) Narcissus's CameraZoomIn(0) nudge: does the
--                          character move without the nudge?
--   /lsprobe combat        arm: on the next combat, waits (C_Timer polling)
--                          until InCombatLockdown() is TRUE, then calls
--                          SetUIVisibility(false) and (true) and logs what
--                          happened (and any ADDON_ACTION_BLOCKED)
--   /lsprobe invite        opens the presentation (UI hidden); a friend sends
--                          a party/guild invite: does the UI come back with
--                          the camera still running, and does accepting work
--                          (no ADDON_ACTION_FORBIDDEN)? The probe never shows
--                          a Blizzard dialog itself.
--   /lsprobe show          the full presentation on a small probe window
--                          (Escape or /lsprobe show again to close); after it
--                          closes, the /console line printed must raise NO
--                          popup (r3 never gives it back: re-registering taints)
--   /lsprobe testcvar      writes test_cameraOverShoulder from ADDON code
--                          (not a clean trigger: prefer the /console line)
--   /lsprobe rereg closure|direct|none
--                          re-registers the experimental-CVar handler as the
--                          library does (closure), with Blizzard's function
--                          itself (direct), or not at all; then the player
--                          types /console test_cameraOverShoulder 0.1
--   (always on)            every StaticPopup_Show logs, a frame later, whether
--                          each shown dialog's `which` was written securely
--                          (issecurevariable) or TAINTED, and by which addon
--   /lsprobe dialogs       that read, now
--   /lsprobe focus         3 s later: the frame under the mouse and its
--                          parents, with every field written tainted (for a
--                          dialog that does not come from StaticPopup_Show)
--   /lsprobe show N        the presentation after N seconds (open chat and
--                          type meanwhile: Enter closes the edit box)
--   /lsprobe taint         tainted fields of GameTooltip and the chat edit
--                          boxes, and the chat globals: before and after one
--   /lsprobe next          prints the /console line to type (a changing value)
--   /lsprobe restore       puts every CVar this probe touched back
--   /lsprobe log | clear
----------------------------------------------------------------------------

local db
local SC
local saved = {}             -- CVar -> value before the probe touched it

local function Log(text)
    local line = ("%s %s"):format(date("%H:%M:%S"), text)
    if db then
        db.log = db.log or {}
        table.insert(db.log, line)
        while #db.log > 2000 do table.remove(db.log, 1) end
    end
    print("|cff88ccffLSProbe|r " .. text)
end

local function Save(cvar)
    if saved[cvar] == nil then saved[cvar] = GetCVar(cvar) or false end
end

local function Set(cvar, value)
    Save(cvar)
    if cvar:find("^test_") then LibStub("LibShowcase-1.0").SuppressExperimentalCVarPopup() end
    SetCVar(cvar, value)
    Log(("  %s = %s (read back %s)"):format(cvar, tostring(value), tostring(GetCVar(cvar))))
end

local function RestoreAll()
    for cvar, v in pairs(saved) do
        if v ~= false then
            if cvar:find("^test_") then LibStub("LibShowcase-1.0").SuppressExperimentalCVarPopup() end
            SetCVar(cvar, v)
        end
    end
    saved = {}
    ConsoleExec("pitchlimit 88")
    Log("restored every CVar the probe touched")
end

-- The /console line for the player to type: a value that CHANGES the CVar
-- (a write that changes nothing may raise no popup, which would read as
-- "suppressed"). Typed by the player, the write is a secure one.
local function Next()
    local v = tonumber(GetCVar("test_cameraOverShoulder")) or 0
    v = v >= 0.85 and 0 or math.floor(v * 10 + 0.5) / 10 + 0.1
    Log(("  type: /console test_cameraOverShoulder %.1f  (now %s). Popup or not? Click Disable if it shows")
        :format(v, tostring(GetCVar("test_cameraOverShoulder"))))
end

local function ClearCentring()
    for _, cvar in ipairs(LibStub("LibShowcase-1.0").CENTRING_CVARS) do
        if GetCVar(cvar) ~= nil then Set(cvar, "0") end
    end
end

-- 1. Dynamic pitch, with the centring CVars that cancelled the shoulder offset cleared.
local function Pitch(arg)
    if arg == "off" then RestoreAll(); return end
    Log("== pitch: build " .. select(2, GetBuildInfo()))
    ClearCentring()
    Set("test_cameraDynamicPitch", "1")
    Log("  now walk forward and backward. Does the camera tilt (pitch) with movement? Note it, then /lsprobe pitch off")
end

-- 2. Is Narcissus's CameraZoomIn(0) nudge needed for the offset to apply?
local function Nudge(arg)
    Log("== nudge " .. tostring(arg))
    ClearCentring()
    Set("test_cameraOverShoulder", "0")
    local want = arg == "1" and 1.5 or 1.4
    Set("test_cameraOverShoulder", want)
    if arg == "1" then
        CameraZoomIn(0)
        Log("  offset written, THEN CameraZoomIn(0)")
    else
        Log("  offset written, no nudge")
    end
    Log("  Did the character move sideways right away (without touching the mouse)? Then /lsprobe restore")
end

-- 3. SetUIVisibility under a real lockdown. REGEN_DISABLED itself is NOT
-- locked (measured 70205), so wait until InCombatLockdown() turns true.
local armed
local function Combat()
    armed = true
    Log("== combat: armed. Pull something; results log when the lockdown is on")
end

local function RunCombatChecks(tries)
    if not InCombatLockdown() then
        if tries > 200 then Log("  lockdown never came on (10 s)"); return end
        C_Timer.After(0.05, function() RunCombatChecks(tries + 1) end)
        return
    end
    Log(("  InCombatLockdown() true after %d polls"):format(tries))
    local ok1, err1 = pcall(SetUIVisibility, false)
    Log(("  SetUIVisibility(false) in combat: pcall %s %s; UIParent:IsShown() = %s")
        :format(tostring(ok1), tostring(err1), tostring(UIParent:IsShown())))
    C_Timer.After(0.5, function()
        local ok2, err2 = pcall(SetUIVisibility, true)
        Log(("  SetUIVisibility(true) in combat: pcall %s %s; UIParent:IsShown() = %s")
            :format(tostring(ok2), tostring(err2), tostring(UIParent:IsShown())))
        Log("  (an ADDON_ACTION_BLOCKED line above or below would mean it is protected)")
    end)
end

-- 4. A Blizzard dialog while the library has the UI hidden. The probe never
-- creates one itself (StaticPopup_Show from addon code taints the pool:
-- MEASURED 70205, the Quit dialog then failed with ADDON_ACTION_FORBIDDEN);
-- a friend sends a real invite. The library's hook should bring the UI back
-- (onGameUIShown logs it) with the presentation still running; accepting
-- must not log ADDON_ACTION_FORBIDDEN/BLOCKED.
local window
local Show
local function Invite()
    Log("== invite: the presentation opens with the UI hidden")
    if not (window and window:IsShown()) then Show() end
    Log("  ask a friend for a party or guild invite. Expect 'onGameUIShown dialog', the UI back,")
    Log("  the camera still orbiting; accept it (no FORBIDDEN line), then /lsprobe show to close.")
    Log("  Then open the game menu and Quit/Logout: it must work (cancel the countdown).")
end

-- 5. The whole presentation.
function Show()
    if window and window:IsShown() then window:Hide(); return end
    if not window then
        window = CreateFrame("Frame", "LibShowcaseProbeWindow", UIParent)
        window:SetSize(260, 120)
        window:SetPoint("RIGHT", UIParent, "RIGHT", -120, 0)
        local bg = window:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.6)
        local fs = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("CENTER")
        fs:SetText("LibShowcase probe\nEscape or /lsprobe show to close")
        window:SetScript("OnShow", function(self)
            local ok, why = SC:Enter(self)
            Log(("== show: Enter -> %s %s"):format(tostring(ok), tostring(why)))
        end)
        window:SetScript("OnHide", function()
            SC:Exit("closed"); Log("  exit")
            C_Timer.After(1.5, Next)   -- after the restore and the re-register
        end)
        window:Hide()
    end
    window:Show()
end

local function TestCVar()
    Log("== testcvar: writing test_cameraOverShoulder 0 with nothing suppressed (from ADDON code:")
    Log("  compare with a /reload control; the player's own /console write is the clean trigger)")
    SetCVar("test_cameraOverShoulder", GetCVar("test_cameraOverShoulder") or "0")
    Log("  Did the experimental-feature popup appear? (yes = the library gave it back)")
end

-- 6. Does the dialog a re-registered experimental-CVar handler shows run
-- tainted? Every StaticPopup_Show is watched (a post-hook, which leaves
-- Blizzard's call secure): one frame later, each shown dialog's `which` is
-- read with issecurevariable. StaticPopup_Show writes dialog.which, so a
-- tainted write means the show ran tainted, and names the addon.
local function DialogTaint(tag)
    local function report(i, d)
        local sec, by = issecurevariable(d, "which")
        Log(("  [%s] dialog %s which=%s: %s"):format(tag, tostring(i), tostring(d.which),
            sec and "written SECURELY" or ("TAINTED by " .. tostring(by))))
    end
    local n = 0
    for i = 1, (STATICPOPUP_NUMDIALOGS or 4) do
        local d = _G["StaticPopup" .. i]
        if type(d) == "table" and d.IsShown and d:IsShown() then n = n + 1; report(i, d) end
    end
    if n == 0 and type(StaticPopup_ForEachShownDialog) == "function" then
        StaticPopup_ForEachShownDialog(function(d) n = n + 1; report("pool", d) end)
    end
    if n == 0 then Log(("  [%s] no shown dialog found"):format(tag)) end
end

-- Every field of a frame written tainted, and by which addon. Only reads.
local function ScanFrame(f, label)
    local name = label or (f.GetDebugName and f:GetDebugName()) or (f.GetName and f:GetName()) or tostring(f)
    local secure, tainted = 0, {}
    for k in pairs(f) do
        local ok, sec, by = pcall(issecurevariable, f, k)
        if ok and sec then secure = secure + 1
        elseif ok then tainted[#tainted + 1] = tostring(k) .. " (" .. tostring(by) .. ")" end
    end
    Log(("  %s shown=%s: %d fields secure, tainted: %s"):format(name, tostring(f.IsShown and f:IsShown()),
        secure, #tainted > 0 and table.concat(tainted, ", ") or "none"))
end

-- Any dialog, whatever shows it: 3 s after the command, the frame under the
-- mouse and its parents are named, and every field written tainted is listed.
local function Focus()
    Log("== focus: put the mouse on the dialog (its Accept button); reading in 3 s")
    C_Timer.After(3, function()
        local foci = GetMouseFoci and GetMouseFoci() or {}
        local f = foci[1]
        if not f then Log("  nothing under the mouse"); return end
        while f and f ~= UIParent do
            ScanFrame(f)
            f = f.GetParent and f:GetParent()
        end
    end)
end

-- 7. What a presentation leaves tainted (#4 review): the library lifts
-- GameTooltip (SetParent/SetFrameStrata/SetScale) and closes an open chat
-- edit box (ChatEdit_DeactivateChat). Read before and after a presentation.
local function Taint()
    Log("== taint: GameTooltip, the chat edit boxes, the chat globals")
    ScanFrame(GameTooltip, "GameTooltip")
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local eb = _G["ChatFrame" .. i .. "EditBox"]
        if eb then ScanFrame(eb, "ChatFrame" .. i .. "EditBox") end
    end
    for _, g in ipairs({ "ACTIVE_CHAT_EDIT_BOX", "LAST_ACTIVE_CHAT_EDIT_BOX" }) do
        local sec, by = issecurevariable(g)
        Log(("  %s: %s"):format(g, sec and "secure" or ("TAINTED by " .. tostring(by))))
    end
end

local POPUP_EVENT = "EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED"
local function Rereg(how)
    Log("== rereg " .. tostring(how) .. ": unregister, then register the handler this way")
    Log("  " .. tostring(pcall(GameEvent.UnregisterInternalEvent, POPUP_EVENT)) .. " unregister")
    if how == "closure" then          -- what the library does (r2)
        Log("  " .. tostring(pcall(GameEvent.RegisterInternalEvent, POPUP_EVENT, function(...)
            return GameEvent.HandleExperimentalCVarConfirmationNeeded(...)
        end)) .. " register a closure")
    elseif how == "direct" then       -- Blizzard's own function, no addon closure
        Log("  " .. tostring(pcall(GameEvent.RegisterInternalEvent, POPUP_EVENT,
            GameEvent.HandleExperimentalCVarConfirmationNeeded)) .. " register Blizzard's function")
    else
        Log("  left unregistered")
    end
    Next()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("ADDON_ACTION_BLOCKED")
ev:RegisterEvent("ADDON_ACTION_FORBIDDEN")
ev:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "ADDON_LOADED" and a1 == "LibShowcaseProbe" then
        LibShowcaseProbeDB = LibShowcaseProbeDB or {}
        db = LibShowcaseProbeDB
        SC = LibStub("LibShowcase-1.0"):New({
            owner = "LibShowcaseProbe",
            db = function() return LibShowcaseProbeDB end,
            debug = function(msg) Log("  [lib] " .. msg) end,
            onGameUIShown = function(reason)
                Log(("  onGameUIShown %s (UI shown %s, presentation active %s, owner %s)"):format(tostring(reason),
                    tostring(UIParent:IsShown()), tostring(SC:IsActive()), tostring(SC:IsOwner())))
            end,
            onForcedExit = function(reason)
                Log("  onForcedExit " .. tostring(reason))
                if reason == "ui-shown" and window then window:Hide() end
            end,
        })
        hooksecurefunc("StaticPopup_Show", function(which)
            Log("StaticPopup_Show " .. tostring(which))
            C_Timer.After(0, function() DialogTaint(tostring(which)) end)
        end)
    elseif event == "PLAYER_REGEN_DISABLED" and armed then
        armed = false
        Log(("== combat started; InCombatLockdown() in the handler = %s"):format(tostring(InCombatLockdown())))
        RunCombatChecks(0)
    elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        Log(("  %s: %s %s"):format(event, tostring(a1), tostring(a2)))
    end
end)

SLASH_LSPROBE1 = "/lsprobe"
SlashCmdList.LSPROBE = function(msg)
    local cmd, arg = (msg or ""):match("^(%S*)%s*(.-)$")
    if cmd == "pitch" then Pitch(arg)
    elseif cmd == "nudge" then Nudge(arg)
    elseif cmd == "combat" then Combat()
    elseif cmd == "invite" then Invite()
    elseif cmd == "show" then
        local delay = tonumber(arg)
        if delay then
            Log(("== show in %d s: open chat and start typing (don't send)"):format(delay))
            C_Timer.After(delay, Show)
        else
            Show()
        end
    elseif cmd == "taint" then Taint()
    elseif cmd == "testcvar" then TestCVar()
    elseif cmd == "rereg" then Rereg(arg)
    elseif cmd == "dialogs" then DialogTaint("now")
    elseif cmd == "focus" then Focus()
    elseif cmd == "next" then Next()
    elseif cmd == "restore" then RestoreAll()
    elseif cmd == "log" then for _, l in ipairs(db and db.log or {}) do print(l) end
    elseif cmd == "clear" then if db then db.log = {} end; Log("log cleared")
    else
        print("/lsprobe pitch [off] | nudge [0|1] | combat | invite | show [N] | taint | testcvar | rereg closure|direct|none | dialogs | focus | next | restore | log | clear")
    end
end
