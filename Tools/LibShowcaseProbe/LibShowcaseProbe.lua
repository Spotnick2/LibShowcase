----------------------------------------------------------------------------
-- LibShowcaseProbe: LibShowcase's developer probe, a ForeverProbe module
-- (/fp ls). The in-game measurements docs/DESIGN.md lists as open, and the
-- ones to run again when the build changes. Its lines go to the ForeverProbe
-- console and LibShowcaseProbeDB.log, never to chat. Never shipped: it lives
-- under Tools/, which every consumer's .pkgmeta ignores.
--
-- Guided procedures (/fp steps ls <name>), each a panel of buttons that saves
-- every outcome:
--   pitch     centring cleared, then test_cameraDynamicPitch 1, a screenshot
--             after each: which write moves the view, and does it follow the zoom?
--   nudge     the shoulder offset written without, then with, Narcissus's
--             CameraZoomIn(0) nudge: does the character move at once?
--   combat    SetUIVisibility(false) then (true) once InCombatLockdown() is
--             really true (it isn't in PLAYER_REGEN_DISABLED, MEASURED 70205)
--   prompts   every return of the prompt getters the library asks before
--             hiding, with a ready check (or a loot roll) waiting, then not
--   invite    a friend's party, guild or dungeon invite while presenting: the UI comes
--             back, the camera keeps orbiting, accepting and Logout work.
--             The probe never shows a Blizzard dialog itself.
--   names     hideWorldNames in a crowded place, then the values after the
--             restore and after a /reload
--   rereg     the experimental-CVar popup with its handler left unregistered,
--             re-registered with Blizzard's own function, and with a closure;
--             the player types the /console line
--   sound     hiding the UI with a target selected: does the "target lost"
--             click play (#41)? Alt+Z first (the control), then the library's
--             own hide
--   follow    every camera CVar before a presentation, then after a normal
--             exit, Escape, combat and a /reload mid-presentation: does the
--             camera still follow the character (#51)?
--   view      back to the client's default cameraView: does the camera follow
--             again, and after a /reload (#51)?
--   tempcvar  the library's SetCVar over the gamepad's temp values on the
--             centring CVars: what does each layer read, and what is left (#51)?
--   release   the r10 release check: female framing, the orbit at another
--             turn speed, a later combat-start handler refused, a 90 s
--             countdown, a presentation in gamepad mode
--   orbitspeed one full turn timed at cameraYawMoveSpeed 90 and 360: does
--             MoveViewLeftStart's speed scale with it (#39)?
--
-- Commands (/fp ls <command>), for a one-off:
--   pitch [centring|off] | nudge 0|1 | combat | invite | show [N] | taint | prompts |
--   names [ui|list] | testcvar | rereg closure|direct|none | dialogs | focus |
--   next | restore | clear | tempback (after a stopped tempcvar run)
-- Always on: every StaticPopup_Show logs, a frame later, whether each shown
-- dialog's `which` was written securely (issecurevariable) or TAINTED, and by
-- which addon. The host's baseline logs every ADDON_ACTION_BLOCKED /
-- FORBIDDEN; this module copies each into its own log (Probe:OnBlocked).
----------------------------------------------------------------------------

local ADDON, NS = ...
local MAX_LOG = 2000
local Probe = ForeverProbe:Module("LibShowcaseProbe", { api = 1, cmd = "ls" })
local function say(msg) Probe:Say(msg) end
local function G(name) return rawget(_G, name) end

local SC
local saved = {}             -- CVar -> value before the probe touched it
local blockedSeen = {}       -- every blocked action this session, as text

local function lib() return LibStub("LibShowcase-1.0") end
local function build() return select(2, GetBuildInfo()) end

local function Save(cvar)
    if saved[cvar] == nil then saved[cvar] = GetCVar(cvar) or false end
end

local function Set(cvar, value)
    Save(cvar)
    if cvar:find("^test_") then lib().SuppressExperimentalCVarPopup() end
    SetCVar(cvar, value)
    local back = GetCVar(cvar)
    say(("  %s = %s (read back %s)"):format(cvar, tostring(value), tostring(back)))
    return back
end

local function RestoreAll()
    local n = 0
    for cvar, v in pairs(saved) do
        if v ~= false then
            if cvar:find("^test_") then lib().SuppressExperimentalCVarPopup() end
            SetCVar(cvar, v)
            n = n + 1
        end
    end
    saved = {}
    ConsoleExec("pitchlimit 88")
    say("restored every CVar the probe touched (" .. n .. ")")
    return n
end

-- The /console line for the player to type: a value that CHANGES the CVar
-- (a write that changes nothing may raise no popup, which would read as
-- "suppressed"). Typed by the player, the write is a secure one.
local function Next()
    local v = tonumber(GetCVar("test_cameraOverShoulder")) or 0
    v = v >= 0.85 and 0 or math.floor(v * 10 + 0.5) / 10 + 0.1
    local line = ("/console test_cameraOverShoulder %.1f"):format(v)
    say(("  type: %s  (now %s). Popup or not? Click Disable if it shows")
        :format(line, tostring(GetCVar("test_cameraOverShoulder"))))
    return line
end

local function ClearCentring()
    for _, cvar in ipairs(lib().CENTRING_CVARS) do
        if GetCVar(cvar) ~= nil then Set(cvar, "0") end
    end
end

-- Every blocked action since `from` (an index into blockedSeen), as one line.
local function BlockedSince(from)
    local t = {}
    for i = (from or 0) + 1, #blockedSeen do t[#t + 1] = blockedSeen[i] end
    return #t, #t > 0 and table.concat(t, "; ") or "none"
end

-- One baseline for "blocked since the check started": set by the combat arm
-- and by each procedure that reports blocked actions.
local blockedAtStart = 0
local function MarkBlocked() blockedAtStart = #blockedSeen; return blockedAtStart end

-- 1. Dynamic pitch, with the centring CVars that cancelled the shoulder offset
-- cleared. "Pitch" is the camera's up/down angle. On 70959 (2026-11-19) one
-- Write that cleared centring AND set dynamic pitch 1 raised the view once,
-- at the write (the character lower on screen, more above it in view);
-- nothing followed the movement. The procedure separated the writes (run
-- #405): dynamic pitch 1 does it, and follows the zoom; centring alone
-- moved nothing (docs/DESIGN.md, Options). `arg` "centring" clears centring only, "1" also sets dynamic
-- pitch 1, "off" puts everything back.
local PITCH_QUESTION = "Did the view change when you pressed Write (the camera angle going up or down,"
    .. " the character moving on screen)? Note how, in the Note box."
local function Pitch(arg)
    if arg == "off" then return RestoreAll() end
    local only = arg == "centring"
    say("== pitch " .. (only and "centring cleared only" or "dynamic pitch 1") .. ": build " .. build())
    ClearCentring()
    if only then return GetCVar("test_cameraDynamicPitch") end
    return Set("test_cameraDynamicPitch", "1")
end

-- 2. Is Narcissus's CameraZoomIn(0) nudge needed for the offset to apply?
local function Nudge(arg)
    say("== nudge " .. tostring(arg))
    ClearCentring()
    Set("test_cameraOverShoulder", "0")
    local want = arg == "1" and 1.5 or 1.4
    local back = Set("test_cameraOverShoulder", want)
    if arg == "1" then
        CameraZoomIn(0)
        say("  offset written, THEN CameraZoomIn(0)")
    else
        say("  offset written, no nudge")
    end
    say("  Did the character move sideways right away (without touching the mouse)?")
    return back
end

-- 3. SetUIVisibility under a real lockdown. REGEN_DISABLED itself is NOT
-- locked (measured 70205), so wait until InCombatLockdown() turns true.
-- combat.state: "armed", "waiting", "half" (hidden, not shown yet), "done".
local combat = {}
local function Combat()
    combat = { state = "armed" }
    MarkBlocked()
    say("== combat: armed. Pull something; results log when the lockdown is on")
    return "armed"
end

local function RunCombatChecks(tries)
    if not InCombatLockdown() then
        if tries > 200 then
            say("  lockdown never came on (10 s)")
            combat.state = "no lockdown"
            return
        end
        C_Timer.After(0.05, function() RunCombatChecks(tries + 1) end)
        return
    end
    say(("  InCombatLockdown() true after %d polls"):format(tries))
    local ok1, err1 = pcall(SetUIVisibility, false)
    combat.hide = ("pcall %s %s, UIParent shown %s"):format(tostring(ok1), tostring(err1), tostring(UIParent:IsShown()))
    say("  SetUIVisibility(false) in combat: " .. combat.hide)
    combat.state = "half"
    C_Timer.After(0.5, function()
        local ok2, err2 = pcall(SetUIVisibility, true)
        combat.show = ("pcall %s %s, UIParent shown %s"):format(tostring(ok2), tostring(err2), tostring(UIParent:IsShown()))
        say("  SetUIVisibility(true) in combat: " .. combat.show)
        local n, what = BlockedSince(blockedAtStart)
        combat.blockedText = n .. " blocked: " .. what
        say("  " .. combat.blockedText)
        combat.state = "done"
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
local uiShown = {}           -- the onGameUIShown reasons, in order
local forcedSeen = {}        -- reason -> true for each onForcedExit since the last trial's Open
local namesOpen              -- "show" or "ui" while a names check holds the names hidden
local function InviteReady()
    if not (SC:IsActive() and SC:IsOwner()) then
        return false, "another showcase holds the presentation: close it"
    end
    if not SC:IsGameUIHidden() then
        return false, "a dialog or prompt kept the UI up: answer or close it"
    end
    return true, "presenting, the UI hidden"
end

local function Invite()
    say("== invite: the presentation opens with the UI hidden")
    if not (window and window:IsShown()) then Show() end
    -- What the next step needs: the probe presenting with the UI hidden.
    -- The window shown is not that: another addon's showcase holding the
    -- lease (Enter -> busy, run #419), or a dialog or prompt already up
    -- (Enter starts the camera, but the UI stays visible, so no invite can
    -- bring it back).
    local ready, why = InviteReady()
    if not ready then
        -- A failed run completes the step, so the panel moves on: the way
        -- back is Back, then Open.
        say("  the presentation is NOT ready: " .. why .. ", then press Back and Open again")
        return false
    end
    say("  ask a friend for a party, guild or dungeon invite. Expect 'onGameUIShown dialog', the UI back,")
    say("  the camera still orbiting; accept it (no FORBIDDEN line), then /fp ls show to close.")
    say("  Then open the game menu and Quit/Logout: it must work (cancel the countdown).")
    return true
end

-- 5. The whole presentation. `hint`: once it closes, log the /console line
-- to type (the one-off `/fp ls show` check: it must raise no popup). The
-- procedures that open it don't want that line in the middle of their steps.
function Show(hint)
    if window and window:IsShown() then window:Hide(); return false end
    if not window then
        window = CreateFrame("Frame", "LibShowcaseProbeWindow", UIParent)
        window:SetSize(260, 120)
        window:SetPoint("RIGHT", UIParent, "RIGHT", -120, 0)
        local bg = window:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.6)
        local fs = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("CENTER")
        fs:SetText("LibShowcase probe\nEscape or /fp ls show to close")
        window:SetScript("OnShow", function(self)
            local ok, why = SC:Enter(self)
            say(("== show: Enter -> %s %s"):format(tostring(ok), tostring(why)))
        end)
        window:SetScript("OnHide", function(self)
            SC:Exit("closed"); say("  exit")
            -- Closed by Escape too: a names check on this window is over.
            if namesOpen == "show" then namesOpen = nil end
            if self.hint then C_Timer.After(1.5, Next) end   -- after the restore
        end)
        window:Hide()
    end
    window.hint = hint and true or nil
    window:Show()
    return window:IsShown()
end

local function TestCVar()
    say("== testcvar: writing test_cameraOverShoulder with nothing suppressed (from ADDON code:")
    say("  compare with a /reload control; the player's own /console write is the clean trigger)")
    SetCVar("test_cameraOverShoulder", GetCVar("test_cameraOverShoulder") or "0")
    say("  Did the experimental-feature popup appear? (yes = the library gave it back)")
end

-- 6. Does the dialog a re-registered experimental-CVar handler shows run
-- tainted? Every StaticPopup_Show is watched (a post-hook, which leaves
-- Blizzard's call secure): one frame later, each shown dialog's `which` is
-- read with issecurevariable. StaticPopup_Show writes dialog.which, so a
-- tainted write means the show ran tainted, and names the addon.
local function DialogTaint(tag)
    local lines = {}
    local function report(i, d)
        local sec, by = issecurevariable(d, "which")
        local line = ("[%s] dialog %s which=%s: %s"):format(tag, tostring(i), tostring(d.which),
            sec and "written SECURELY" or ("TAINTED by " .. tostring(by)))
        lines[#lines + 1] = line
        say("  " .. line)
    end
    for i = 1, (G("STATICPOPUP_NUMDIALOGS") or 4) do
        local d = G("StaticPopup" .. i)
        if type(d) == "table" and d.IsShown and d:IsShown() then report(i, d) end
    end
    local each = G("StaticPopup_ForEachShownDialog")
    if #lines == 0 and type(each) == "function" then
        each(function(d) report("pool", d) end)
    end
    if #lines == 0 then say(("  [%s] no shown dialog found"):format(tag)) end
    return #lines
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
    say(("  %s shown=%s: %d fields secure, tainted: %s"):format(name, tostring(f.IsShown and f:IsShown()),
        secure, #tainted > 0 and table.concat(tainted, ", ") or "none"))
    return #tainted
end

-- Any dialog, whatever shows it: 3 s after the command, the frame under the
-- mouse and its parents are named, and every field written tainted is listed.
local function Focus()
    say("== focus: put the mouse on the dialog (its Accept button); reading in 3 s")
    C_Timer.After(3, function()
        local foci = G("GetMouseFoci") and GetMouseFoci() or {}
        local f = foci[1]
        if not f then say("  nothing under the mouse"); return end
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
    say("== taint: GameTooltip, the chat edit boxes, the chat globals")
    local n = ScanFrame(GameTooltip, "GameTooltip")
    for i = 1, (G("NUM_CHAT_WINDOWS") or 10) do
        local eb = G("ChatFrame" .. i .. "EditBox")
        if eb then n = n + ScanFrame(eb, "ChatFrame" .. i .. "EditBox") end
    end
    for _, g in ipairs({ "ACTIVE_CHAT_EDIT_BOX", "LAST_ACTIVE_CHAT_EDIT_BOX" }) do
        local sec, by = issecurevariable(g)
        say(("  %s: %s"):format(g, sec and "secure" or ("TAINTED by " .. tostring(by))))
    end
    return n
end

-- 8. The prompt getters the library asks before hiding the UI (in the dump by
-- name only): log every return, so their shapes can be measured. Run it with
-- a ready check waiting for your answer, and after answering.
local function Prompts()
    say("== prompts: the client's own prompt state")
    local out = {}
    local function show(label, fn, ...)
        if type(fn) ~= "function" then
            say("  " .. label .. ": ABSENT")
            out[#out + 1] = label .. " ABSENT"
            return
        end
        local r = Probe.Pack(pcall(fn, ...))
        local vals = {}
        for i = 2, r.n do vals[#vals + 1] = type(r[i]) == "table" and Probe.Describe(r[i]) or Probe.Show(r[i]) end
        local line = ("%s -> %s%s"):format(label, r[1] and "" or "ERROR ", table.concat(vals, ", "))
        say("  " .. line)
        out[#out + 1] = line
        return r[1] and r[2]
    end
    show('GetReadyCheckStatus("player")', G("GetReadyCheckStatus"), "player")
    show("GetReadyCheckTimeLeft()", G("GetReadyCheckTimeLeft"))
    show("GetLFGProposal()", G("GetLFGProposal"))
    show("GetLFGRoleUpdate()", G("GetLFGRoleUpdate"))
    local ids = show("GetActiveLootRollIDs()", G("GetActiveLootRollIDs"))
    if type(ids) == "table" then
        for _, id in ipairs(ids) do show("GetLootRollTimeLeft(" .. tostring(id) .. ")", G("GetLootRollTimeLeft"), id) end
    end
    return table.concat(out, "; ")
end

-- 9. hideWorldNames (#14): which name CVars the client has, their values and
-- flags, then a presentation with them hidden, in a crowded place. Look at
-- player, pet/minion and NPC names, guild/title lines, regional surnames and
-- pet-owner text: which stay up? Run it again to close; the values are logged
-- once more after the restore and must match the first list.
-- `/fp ls names ui`: the same with the camera OFF (Acquire + HideGameUI).
local NAME_EXTRAS = { "UnitSurnameOwn", "UnitNamePlayerGuild", "UnitNamePlayerPVPTitle",
                      "UnitNameGuildTitle", "UnitNameForceHideMinus" }
-- Logs each name CVar and returns { [cvar] = value or false (absent) }.
local function LogNames(tag)
    local values = {}
    local function one(cvar)
        if values[cvar] ~= nil then return end
        local v = GetCVar(cvar)
        values[cvar] = v == nil and false or v
        if v == nil then say(("  [%s] %s: ABSENT"):format(tag, cvar)); return end
        local flags = ""
        local CV = G("C_CVar")
        if CV and CV.GetCVarInfo then
            local ok, _, def, _, _, locked, secure, readOnly = pcall(CV.GetCVarInfo, cvar)
            if ok then
                flags = (" default=%s locked=%s secure=%s readOnly=%s"):format(tostring(def), tostring(locked),
                    tostring(secure), tostring(readOnly))
            end
        end
        say(("  [%s] %s = %s%s"):format(tag, cvar, tostring(v), flags))
    end
    for _, cvar in ipairs(lib().WORLD_NAME_CVARS) do one(cvar) end
    for _, cvar in ipairs(NAME_EXTRAS) do one(cvar) end
    return values
end

-- Whether `now` holds the values saved before the presentation, and the
-- names that differ.
local function NamesMatch(tag)
    local before = LibShowcaseProbeDB.namesBefore
    if type(before) ~= "table" then return false, "no [before] list saved" end
    local now, diff = LogNames(tag), {}
    for cvar, v in pairs(before) do
        if now[cvar] ~= v then diff[#diff + 1] = cvar .. " " .. tostring(v) .. " -> " .. tostring(now[cvar]) end
    end
    table.sort(diff)
    return #diff == 0, #diff == 0 and "every value as before" or table.concat(diff, ", ")
end

local function NamesClose()
    if namesOpen == "ui" then SC:Release() elseif window and window:IsShown() then window:Hide() end
    namesOpen = nil
    SC.opts.hideWorldNames = false
    return true
end

-- Hides the names: `arg` "ui" with the camera OFF, else a presentation.
-- Refused while anything holds the screen (a names check, a presentation,
-- even one still ending, or another lease): the [before] list would read
-- names already hidden, and a running presentation keeps the option it
-- entered with. Returns ok, why.
local function NamesStart(arg)
    local busy = namesOpen and "a names check is open (/fp ls names closes it)"
        or (window and window:IsShown()) and "a presentation is open (/fp ls show closes it)"
        or (SC:IsActive() or SC:IsOwner()) and "the presentation is still ending: try again in a moment"
    if busy then
        say("  " .. busy)
        return false, busy
    end
    say("== names " .. (arg == "ui" and "ui (camera OFF)" or "(presentation)") .. ": build " .. build())
    LibShowcaseProbeDB.namesBefore = LogNames("before")
    SC.opts.hideWorldNames = true
    if arg == "ui" then
        local ok, why = SC:Acquire()
        if ok then ok, why = SC:HideGameUI() end
        say(("  Acquire + HideGameUI -> %s %s"):format(tostring(ok), tostring(why)))
        if not ok then
            SC:Release()
            SC.opts.hideWorldNames = false
            return false, why
        end
        namesOpen = "ui"
    else
        Show()
        -- Enter has read the option (a presentation keeps what it entered
        -- with): off again, so a later /fp ls show or Escape leaves no trace.
        SC.opts.hideWorldNames = false
        if not window:IsShown() then return false, "not shown" end
        namesOpen = "show"
    end
    LogNames("hidden")
    say("  Which names, guild/title lines, surnames or pet-owner text are still drawn? Note them, then /fp ls names")
    return true
end

-- The one-off command: hide, or (again) close and compare with [before].
local function Names(arg)
    if arg == "list" then LogNames("now"); return true end
    if namesOpen then
        NamesClose()
        C_Timer.After(1.5, function()
            local _, what = NamesMatch("after")
            say("  after the restore: " .. what .. ". Then /reload and /fp ls names list: still the same?")
        end)
        return true
    end
    return NamesStart(arg)
end

-- 10. The experimental-CVar popup with its handler re-registered from addon
-- code (MEASURED 70205: the popup then shows TAINTED by this addon).
-- test_cameraOverShoulder is set to 0 first, while unregistered, so the
-- player's /console test_cameraOverShoulder 0.5 always changes it.
local POPUP_EVENT = "EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED"
local function Rereg(how)
    say("== rereg " .. tostring(how) .. ": unregister, then register the handler this way")
    say("  " .. tostring(pcall(GameEvent.UnregisterInternalEvent, POPUP_EVENT)) .. " unregister")
    Save("test_cameraOverShoulder")
    SetCVar("test_cameraOverShoulder", "0")
    if how == "closure" then          -- what the library did (r2)
        say("  " .. tostring(pcall(GameEvent.RegisterInternalEvent, POPUP_EVENT, function(...)
            return GameEvent.HandleExperimentalCVarConfirmationNeeded(...)
        end)) .. " register a closure")
    elseif how == "direct" then       -- Blizzard's own function, no addon closure
        say("  " .. tostring(pcall(GameEvent.RegisterInternalEvent, POPUP_EVENT,
            GameEvent.HandleExperimentalCVarConfirmationNeeded)) .. " register Blizzard's function")
    else
        how = "none"
        say("  left unregistered")
    end
    say("  type: /console test_cameraOverShoulder 0.5. Popup or not? Click Disable if it shows")
    return how
end

----------------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------------

Probe:Command("pitch", function(args) Pitch(args) end, "[centring or off]: centring cleared and test_cameraDynamicPitch 1 (centring: that only); off puts it back")
Probe:Command("nudge", function(args) Nudge(args) end, "0 or 1: the shoulder offset without / with the CameraZoomIn(0) nudge")
Probe:Command("combat", function() Combat() end, "arm: SetUIVisibility off and on once the next combat's lockdown is on")
Probe:Command("invite", function() Invite() end, "open the presentation for a friend's party or guild invite")
Probe:Command("show", function(args)
    local delay = tonumber(args)
    if delay then
        say(("== show in %d s: open chat and start typing (don't send)"):format(delay))
        C_Timer.After(delay, function() Show(true) end)
    else
        Show(true)
    end
end, "[N]: the presentation on a small window (again to close); after N seconds")
Probe:Command("taint", function() Taint() end, "tainted fields of GameTooltip, the chat edit boxes, the chat globals")
Probe:Command("prompts", function() Prompts() end, "every return of the prompt getters the library asks")
Probe:Command("names", function(args) Names(args) end, "[ui or list]: hideWorldNames; again to close")
Probe:Command("testcvar", function() TestCVar() end, "write test_cameraOverShoulder from addon code")
Probe:Command("rereg", function(args) Rereg(args) end, "closure, direct or none: re-register the popup handler")
Probe:Command("dialogs", function() DialogTaint("now") end, "whether each shown dialog's `which` was written securely")
Probe:Command("focus", function() Focus() end, "3 s later: the frame under the mouse, its tainted fields")
Probe:Command("next", function() Next() end, "the /console line to type (a changing value)")
Probe:Command("restore", function() RestoreAll() end, "put back every CVar this probe touched")
Probe:Command("clear", function() Probe:ClearLog(); say("log cleared") end, "empty the saved log")

----------------------------------------------------------------------------
-- Procedures (/fp steps ls <name>)
----------------------------------------------------------------------------

-- A wait step: the exit animation is over and the lease given back. The
-- detail says which, so a completed wait doesn't read "still ending".
local function PresentationEnded()
    if not SC:IsActive() and not SC:IsOwner() then return true, "the presentation ended" end
    return false, "the presentation is still ending"
end

-- The names compared with [before]: read (and logged) once by the step's
-- run; its check gives that verdict.
local namesVerdict = { false, "not read" }
local function NamesRead(tag)
    namesVerdict = { NamesMatch(tag) }
    return namesVerdict[2]
end
local function NamesVerdict() return namesVerdict[1], namesVerdict[2] end

local function BlockedReport()
    local n, what = BlockedSince(blockedAtStart)
    say(("  blocked actions since the procedure started: %d (%s)"):format(n, what))
    return n, what
end

Probe:Steps("pitch", {
    title = "Dynamic pitch with centring cleared",
    -- One write at a time, a screenshot after each: centring cleared alone
    -- (dynamic pitch untouched), then dynamic pitch 1. Retail's dynamic pitch
    -- follows the zoom distance (unmeasured here), so step 6 zooms.
    { text = "Stand somewhere open, out of combat, at your usual zoom. Don't touch the mouse until step 6. Next takes a screenshot of the view as it is.",
      screenshot = "pitch: before" },
    { text = "Write clears the centring CVars only (dynamic pitch untouched).",
      button = "Write", screenshot = "pitch: centring cleared", run = function() return Pitch("centring") end },
    { text = PITCH_QUESTION, ask = true },
    { text = "Write sets test_cameraDynamicPitch 1, the centring still cleared.",
      button = "Write", screenshot = "pitch: dynamic pitch 1", run = function() return Pitch("1") end },
    { text = PITCH_QUESTION, ask = true },
    { text = "Zoom far out, then back in, with the mouse wheel. Does the camera angle change with the zoom more than it usually does?",
      ask = true },
    { text = "Putting every CVar the probe touched back.", auto = true, screenshot = "pitch: restored", run = RestoreAll },
    { text = "Did the view go back to how it was before step 2?", ask = true },
})

Probe:Steps("nudge", {
    title = "The CameraZoomIn(0) nudge",
    { text = "Out of combat, the camera a little zoomed out. Write sets the shoulder offset WITHOUT the nudge: don't touch the mouse.",
      button = "Write", run = function() return Nudge("0") end },
    { text = "Did the character move sideways right away, without touching the mouse?", ask = true },
    { text = "Putting the CVars back.", auto = true, run = RestoreAll },
    { text = "Write sets it again, WITH CameraZoomIn(0) after it: don't touch the mouse.",
      button = "Write", run = function() return Nudge("1") end },
    { text = "Did the character move sideways right away this time?", ask = true },
    { text = "Putting the CVars back.", auto = true, run = RestoreAll },
})

Probe:Steps("combat", {
    title = "SetUIVisibility in a real lockdown",
    { text = "Out of combat, near a mob. Arm, then pull it: once InCombatLockdown() is true the probe tries to hide the UI, then show it 0.5 s later. MEASURED 70959: both calls are blocked, so the UI is expected to stay as it is (Bugsy reports each block).",
      button = "Arm", run = Combat },
    -- "no lockdown" (the poll gave up after 10 s) ends the wait too, as a FAIL.
    { text = "Pull the mob and keep fighting. This step completes once both calls have run.", timeout = 300,
      wait = function()
          if combat.state == "done" or combat.state == "no lockdown" then
              return true, combat.state, "UnitAffectingCombat in the handler " .. tostring(combat.affecting), combat.hide, combat.show, combat.blockedText
          end
          return false, "combat check: " .. tostring(combat.state)
      end,
      check = function() return combat.state == "done", combat.state end },
    { text = "Did the UI disappear during the fight? (Expected: no, the calls are blocked.)", ask = true },
    { text = "The blocked actions the test raised.", auto = true, run = BlockedReport },
})

Probe:Steps("prompts", {
    title = "The prompt getters' shapes",
    { text = "Get one prompt up and leave it unanswered: a ready check, a loot roll, a dungeon finder proposal or a role check. Say which in the Note box, then press Next." },
    { text = "Read logs every return of the prompt getters while it waits.", button = "Read", run = Prompts },
    { text = "Answer that prompt, then press Next." },
    { text = "Reading them again, with nothing waiting.", auto = true, run = Prompts },
})

Probe:Steps("invite", {
    title = "A friend's invite while presenting",
    { text = "Out of combat, with a friend online. Open starts the presentation: the UI hides and the camera orbits.",
      button = "Open", run = function()
          MarkBlocked()
          uiShown = {}
          if window and window:IsShown() then window:Hide() end
          return Invite()
      end,
      -- Not ready (another showcase, or the UI kept up) is a FAIL here, not a
      -- step that reads "true" (run #419).
      check = InviteReady },
    { text = "Ask the friend for a party, guild or dungeon invite (say which in the Note box). This step completes when the invite brings the UI back.",
      timeout = 600, wait = function()
          for _, r in ipairs(uiShown) do if r == "dialog" then return true, "onGameUIShown dialog" end end
          return false, "waiting for the invite's dialog"
      end },
    { text = "Is the UI back, with the camera still orbiting?", ask = true, screenshot = "invite: the UI back" },
    { text = "Accept the invite. Did it work?", ask = true },
    { text = "Close ends the presentation.", button = "Close", run = function()
          if window and window:IsShown() then window:Hide() end
          return "closing"
      end },
    { text = "Waiting for the presentation to end.", timeout = 15, wait = PresentationEnded },
    { text = "Open the game menu, choose Logout, then cancel the countdown. Did the countdown start?", ask = true },
    { text = "The blocked actions since the procedure started (accepting and Logout must have raised none).",
      auto = true, run = BlockedReport, check = function() local n, what = BlockedSince(blockedAtStart); return n == 0, what end },
})

Probe:Steps("names", {
    -- rev 2 (#32): Hide, the wait and the reads changed functions only, so a
    -- run started before them is stopped at /reload instead of resumed.
    rev = 2,
    title = "hideWorldNames in a crowd",
    { text = "Go somewhere crowded (a capital, near other players and their pets), out of combat, then press Next." },
    { text = "Hide lists the name CVars, then opens the presentation with world names hidden.",
      -- A refusal (something still open or ending) is an error: logged, the
      -- step stays, and Retry tries again.
      button = "Hide", screenshot = "names hidden", run = function()
          local ok, why = NamesStart()
          if not ok then error(why, 0) end
          return ok
      end },
    { text = "Is any name still drawn: a player, pet or NPC name, a guild or title line, a surname, pet-owner text? Note which.",
      ask = true },
    { text = "Close ends the presentation; the names come back.", button = "Close", run = NamesClose },
    { text = "Waiting for the restore.", timeout = 15, wait = PresentationEnded },
    { text = "Reading the name CVars after the restore.", auto = true,
      run = function() return NamesRead("after") end, check = NamesVerdict },
    { text = "Type /reload, to see what survives it.", reload = true },
    { text = "Reading the name CVars after the /reload.", auto = true,
      run = function() return NamesRead("reload") end, check = NamesVerdict },
})

-- 11. #41: does hiding the UI with a target play the "target lost" click?
-- Forever loads the Mainline TargetFrame, whose OnHide plays
-- SOUNDKIT.INTERFACE_SOUND_LOST_TARGET_UNIT unless the target is a soft one
-- (wow-ui-source forever, Blizzard_UnitFrame/Mainline/TargetFrame.lua);
-- SetUIVisibility(false) hides it with UIParent. Unmeasured.
local function TargetState()
    local exists = G("UnitExists") and UnitExists("target")
    local loose = G("IsTargetLoose") and IsTargetLoose()
    local line = ("target exists %s, IsTargetLoose %s, UI shown %s"):format(tostring(exists), tostring(loose),
        tostring(UIParent:IsShown()))
    say("  " .. line)
    return line
end

-- What a trial needs, checked as it starts: a hard target and the UI shown.
-- A throw keeps the step (Retry), so no answer is saved for a trial that
-- didn't happen (Codex, PR #50).
local function NeedHardTarget()
    if not (G("UnitExists") and UnitExists("target")) then error("no target: click an NPC or player, then Retry", 0) end
    if G("IsTargetLoose") and IsTargetLoose() then error("a soft target: click it to make it a hard one, then Retry", 0) end
    if not UIParent:IsShown() then error("the UI is hidden: Alt+Z, then Retry", 0) end
end

-- The Alt+Z control, observed (Codex, PR #50): a post-hook on SetUIVisibility
-- (installed at load; the library's own hook sees the player's Alt+Z the
-- same way) records the hide, with whether a hard target was there at that
-- moment, then the show. Only a hide with a hard target, then a show, counts.
local soundCtl = {}
local function SoundControlHook(shown)
    if not soundCtl.armed or soundCtl.done then return end
    -- A change made while a showcase holds the lease is the library's (its
    -- hide and show), or happens inside a presentation: never the control.
    -- It also cancels a half-seen one (Codex, PR #50).
    local state = lib().state
    if type(state) == "table" and state.owner ~= nil then
        if soundCtl.hid ~= nil then say("  control: a showcase changed the UI; start the control again") end
        soundCtl.hid = nil
        return
    end
    if not shown and not UIParent:IsShown() then
        local hard = G("UnitExists") and UnitExists("target") and not (G("IsTargetLoose") and IsTargetLoose())
        soundCtl.hid = hard and true or false
        say("  control: the UI hid, hard target " .. tostring(soundCtl.hid))
    elseif shown and UIParent:IsShown() and soundCtl.hid ~= nil then
        if soundCtl.hid then
            soundCtl.done = true
            say("  control: the UI came back; the control ran")
        else
            soundCtl.hid = nil
            say("  control: no hard target when the UI hid: target one, then Alt+Z twice again")
        end
    end
end
local function SoundControlWait()
    if soundCtl.done then return true, "Alt+Z hid the UI with a hard target, then showed it" end
    if soundCtl.hid == nil then return false, "waiting for Alt+Z (the hide), with a hard target" end
    return false, "waiting for Alt+Z again (the show)"
end

Probe:Steps("sound", {
    title = "The target-lost click when the UI hides",
    { text = "Out of combat, with the game sound on. Target a nearby NPC or player (a hard target: click it), then press Ready.",
      button = "Ready", run = function() NeedHardTarget(); soundCtl = { armed = true }; return TargetState() end },
    { text = "The control: press Alt+Z (the UI hides), listen, then Alt+Z again. This step completes once both were seen.",
      timeout = 600, wait = SoundControlWait },
    -- The answer counts only for a control that ran (a timed-out wait goes on as a FAIL).
    { text = "Did you hear the target-lost click when Alt+Z hid the UI?", ask = true,
      check = function() return soundCtl.done == true, "the control ran" end },
    { text = "Open starts the presentation: the UI hides. Listen.", button = "Open", run = function()
          if window and window:IsShown() then window:Hide() end
          NeedHardTarget()
          local before = TargetState()
          Show()
          -- The engine's UI, not only the library's flag (Codex, PR #50).
          if not (SC:IsActive() and SC:IsOwner() and SC:IsGameUIHidden() and not UIParent:IsShown()) then
              if window and window:IsShown() then window:Hide() end
              error("the presentation did not hide the UI (another showcase, or a dialog up): fix it, then Retry", 0)
          end
          return true, before
      end },
    { text = "Did you hear the target-lost click when the presentation hid the UI?", ask = true },
    { text = "Close ends the presentation.", button = "Close", run = function()
          if window and window:IsShown() then window:Hide() end
          return "closing"
      end },
    { text = "Waiting for the presentation to end.", timeout = 15, wait = PresentationEnded },
    { text = "Is your target still selected?", ask = true },
    { text = "Reading the target again.", auto = true, run = TargetState },
})

-- 12. #51: after a presentation, does the camera still follow the character?
-- A player reported it didn't. Unmeasured lead: Enter saves the player's view
-- into savedViewSlot (5) and switches to view 2; every exit ends on
-- SetView(5), and cameraView is never captured. The snapshot is every camera
-- CVar the client lists (ConsoleGetAllCommands, in the 70959 dump; a fixed
-- list without it), kept in the saved variables so the /reload step compares
-- with the same "before".
local FOLLOW_CVARS = { "cameraView", "cameraSmoothStyle", "cameraSmoothTrackingStyle",
    "CameraKeepCharacterCentered", "CameraReduceUnexpectedMovement", "test_cameraOverShoulder",
    "test_cameraDynamicPitch", "cameraDistanceMaxZoomFactor", "cameraViewBlendStyle", "cameraYawMoveSpeed" }

local function CameraCVars()
    local names, seen = {}, {}
    local function add(n)
        if type(n) == "string" and not seen[n] then seen[n] = true; names[#names + 1] = n end
    end
    for _, n in ipairs(FOLLOW_CVARS) do add(n) end
    local all = G("ConsoleGetAllCommands")
    if type(all) == "function" then
        local ok, list = pcall(all)
        if ok and type(list) == "table" then
            for _, c in ipairs(list) do
                if type(c) == "table" and (c.commandType == nil or c.commandType == 0)
                    and type(c.command) == "string" and c.command:lower():find("camera") then
                    add(c.command)
                end
            end
        end
    end
    local t = {}
    for _, n in ipairs(names) do
        local ok, v = pcall(GetCVar, n)
        if ok and v ~= nil then t[n] = tostring(v) end
    end
    return t
end

local function FollowDB()
    LibShowcaseProbeDB.follow = type(LibShowcaseProbeDB.follow) == "table" and LibShowcaseProbeDB.follow or {}
    return LibShowcaseProbeDB.follow
end

local function FollowBefore()
    local snap, n = CameraCVars(), 0
    for _ in pairs(snap) do n = n + 1 end
    FollowDB().before, FollowDB().trial = snap, nil
    local line = ("before: %d camera CVars; cameraView %s, cameraSmoothStyle %s, KeepCentered %s, ReduceUnexpected %s")
        :format(n, tostring(snap.cameraView), tostring(snap.cameraSmoothStyle),
            tostring(snap.CameraKeepCharacterCentered), tostring(snap.CameraReduceUnexpectedMovement))
    say("== follow " .. line)
    return line
end

-- Every camera CVar that differs from the trial's snapshot (taken when its
-- control passed; the start's "before" if none), logged one by one; the
-- step's detail lists them.
local function FollowDiff(tag)
    local db = FollowDB()
    local before = type(db.trial) == "table" and db.trial or db.before
    if type(before) ~= "table" then return false, "no before snapshot: start the procedure again" end
    local now, changed = CameraCVars(), {}
    local names = {}
    for n in pairs(before) do names[#names + 1] = n end
    for n in pairs(now) do if before[n] == nil then names[#names + 1] = n end end
    table.sort(names)
    for _, n in ipairs(names) do
        if before[n] ~= now[n] then
            changed[#changed + 1] = ("%s %s -> %s"):format(n, tostring(before[n]), tostring(now[n]))
        end
    end
    FollowDB()[tag] = changed
    say(("== follow %s: %d changed"):format(tag, #changed))
    for _, c in ipairs(changed) do say("  " .. c) end
    return true, ("%s: %d changed%s"):format(tag, #changed, #changed > 0 and (": " .. table.concat(changed, "; ")) or "")
end

-- Starts the presentation, or throws: the step stays for Retry, so a trial
-- that never started can't be answered (Codex, PR #52).
local function OpenOrThrow()
    if window and window:IsShown() then window:Hide() end
    Show()
    if SC:IsActive() and SC:IsOwner() then return true, "presenting" end
    if window and window:IsShown() then window:Hide() end
    error("the presentation did not start: close any other showcase, then Retry", 0)
end

-- Each trial starts from a camera that follows: the control just before it
-- said yes (Codex, PR #52: run #468's control failed, and every later trial
-- then started with the symptom already there).
-- A passing control also snapshots the camera as it is then: the trial is
-- compared with the camera that followed, not with the start's, which may be
-- the one the tester had to fix (Codex, PR #52). The start's "before" stays
-- for the final cleanup.
local followOK = false
local function FollowControlLeft(outcome)
    followOK = outcome == "yes"
    FollowDB().trial = followOK and CameraCVars() or nil
end

-- The trial's Open: the presentation must start with the UI hidden (a dialog
-- or prompt up would keep it shown, and Escape could not end it). The passing
-- control is used up only once that worked, so a refused Open can be retried.
local function FollowOpen()
    if not followOK then
        error("the camera did not follow before this trial, so it can't be measured: Back to the control"
            .. " once it follows, or Stop", 0)
    end
    OpenOrThrow()
    if not SC:IsGameUIHidden() then
        if window and window:IsShown() then window:Hide() end
        error("the presentation kept the UI shown (a dialog or prompt is up): close it, then Retry", 0)
    end
    forcedSeen = {}
    followOK = false   -- one trial per control
    return true, "presenting, the UI hidden"
end

-- The trial ended the way it was meant to (onForcedExit's reason), or its
-- comparison is refused: the step stays, Back to try the trial again.
local function FollowEndedBy(reason, tag)
    if not forcedSeen[reason] then
        error(("the presentation did not end by %s: Back to the control and try the trial again"):format(tag), 0)
    end
end

-- Every camera CVar and the view back to "before", read back: a mismatch
-- throws (the step stays, Retry) instead of reporting a clean restore.
local function FollowRestore()
    local before = FollowDB().before
    if type(before) ~= "table" then error("no before snapshot: start the procedure again", 0) end
    local n, wrong = 0, {}
    for cvar, v in pairs(before) do
        if cvar ~= "cameraView" and GetCVar(cvar) ~= v then
            if cvar:find("^test_") then lib().SuppressExperimentalCVarPopup() end
            pcall(SetCVar, cvar, v)
            n = n + 1
            if GetCVar(cvar) ~= v then wrong[#wrong + 1] = ("%s %s (want %s)"):format(cvar, tostring(GetCVar(cvar)), v) end
        end
    end
    local view = tonumber(before.cameraView)
    if view and tostring(GetCVar("cameraView")) ~= tostring(before.cameraView) then
        pcall(SetView, view)
        if tostring(GetCVar("cameraView")) ~= tostring(before.cameraView) then
            wrong[#wrong + 1] = ("cameraView %s (want %s)"):format(tostring(GetCVar("cameraView")), before.cameraView)
        end
    end
    if #wrong > 0 then
        local line = "not put back: " .. table.concat(wrong, "; ")
        say("  follow: " .. line)
        error(line .. ". Retry", 0)
    end
    local line = ("%d camera CVars put back, view %s"):format(n, tostring(GetCVar("cameraView")))
    say("  follow: " .. line)
    return true, line
end

local FOLLOW_ASK = "Walk forward and turn with the keyboard (A/D or Q/E), without the mouse. Does the camera swing back behind the character as it did at the start?"
local FOLLOW_CONTROL = "The control: " .. FOLLOW_ASK .. " (It should. If not, this trial can't be measured.)"
local function Close()
    if window and window:IsShown() then window:Hide() end
    return "closing"
end

Probe:Steps("follow", {
    title = "Does the camera still follow after a presentation (#51)",
    { text = "Out of combat, somewhere open. In Options > Camera, set Camera Following Style to Smart or Always and say which in the Note box." },
    { text = "Recording every camera CVar.", auto = true, run = FollowBefore },
    { text = FOLLOW_CONTROL, ask = true, leave = FollowControlLeft },
    -- 1. A normal exit.
    { text = "Open starts the presentation.", button = "Open", run = FollowOpen },
    { text = "Close ends it normally.", button = "Close", run = Close },
    { text = "Waiting for the presentation to end.", timeout = 15, wait = PresentationEnded },
    { text = "Comparing the camera CVars with the trial's start.", auto = true, run = function() return FollowDiff("exit") end },
    { text = "After a normal exit: " .. FOLLOW_ASK, ask = true },
    -- 2. Escape, from the camera as it was.
    { text = "Reset puts every camera CVar and the view back as at the start.", button = "Reset", run = FollowRestore },
    { text = FOLLOW_CONTROL, ask = true, leave = FollowControlLeft },
    { text = "Open starts it again.", button = "Open", run = FollowOpen },
    { text = "Press Escape once: the UI comes back and the presentation ends.", timeout = 120, wait = PresentationEnded },
    { text = "Comparing.", auto = true, run = function() FollowEndedBy("ui-shown", "Escape"); return FollowDiff("escape") end },
    { text = "After Escape: " .. FOLLOW_ASK, ask = true },
    -- 3. Combat.
    { text = "Reset puts the camera back again.", button = "Reset", run = FollowRestore },
    { text = "Go next to a mob you can fight. " .. FOLLOW_CONTROL, ask = true, leave = FollowControlLeft },
    { text = "Open starts the presentation.", button = "Open", run = FollowOpen },
    { text = "Pull the mob: combat ends the presentation. Finish the fight.", timeout = 300, wait = PresentationEnded },
    { text = "Out of combat now? Comparing.", auto = true, run = function() FollowEndedBy("combat", "combat"); return FollowDiff("combat") end },
    { text = "After combat: " .. FOLLOW_ASK, ask = true },
    -- 4. A /reload mid-presentation: its PLAYER_LOGOUT restores and clears
    -- the capture, so this is the logout path, not the login heal.
    { text = "Reset puts the camera back again.", button = "Reset", run = FollowRestore },
    { text = FOLLOW_CONTROL, ask = true, leave = FollowControlLeft },
    { text = "Open starts it once more.", button = "Open", run = FollowOpen },
    { text = "While it is presenting, type /reload.", reload = true },
    { text = "Comparing (after the /reload's logout restore).", auto = true, run = function() return FollowDiff("reload") end },
    { text = "After the /reload: " .. FOLLOW_ASK, ask = true },
    { text = "Putting every camera CVar and the view back as at the start.", auto = true, run = FollowRestore },
})

-- 13. #51, the follow-up. The follow run (#468) found the camera not
-- following even before any presentation, on cameraView 5, which every
-- account's config-cache.wtf keeps as a non-default SET. Back to the
-- client's default view: does the camera follow again, and does it survive a
-- /reload? C_CVar.GetCVarDefault is in the 70959 dump.
local function ViewDefault()
    local get = G("C_CVar") and C_CVar.GetCVarDefault
    local ok, d = false, nil
    if type(get) == "function" then ok, d = pcall(get, "cameraView") end
    return ok and d or nil
end

local function ViewRead(tag)
    local line = ("%s: cameraView %s (default %s), cameraSmoothStyle %s"):format(tag, tostring(GetCVar("cameraView")),
        tostring(ViewDefault()), tostring(GetCVar("cameraSmoothStyle")))
    say("== view " .. line)
    return line
end

-- how: "cvar" writes the CVar, "setview" calls SetView with the default.
local function ViewToDefault(how)
    local d = ViewDefault()
    if d == nil then return false, "no default for cameraView (C_CVar.GetCVarDefault)" end
    local before = GetCVar("cameraView")
    local ok, err
    if how == "cvar" then
        ok, err = pcall(SetCVar, "cameraView", d)
    else
        local n = tonumber(d)
        if not n then return false, "the default " .. tostring(d) .. " is not a view number" end
        ok, err = pcall(SetView, n)
    end
    local line = ("%s to the default %s from %s: pcall %s %s, cameraView now %s"):format(how == "cvar" and "SetCVar" or "SetView",
        tostring(d), tostring(before), tostring(ok), tostring(err), tostring(GetCVar("cameraView")))
    say("  " .. line)
    return ok, line
end

Probe:Steps("view", {
    title = "Back to the default camera view (#51)",
    { text = "Out of combat, somewhere open, Camera Following Style as before. Reading the view.", auto = true,
      run = function() return ViewRead("start") end },
    { text = FOLLOW_ASK .. " (The control: in the follow run it did not.)", ask = true },
    { text = "Write sets the cameraView CVar to its default (don't touch the mouse; note whether the camera jumps).",
      button = "Write", run = function() return ViewToDefault("cvar") end },
    { text = "Did the camera move when you pressed Write? " .. FOLLOW_ASK, ask = true },
    { text = "If it already follows, press Skip. Otherwise SetView switches to the default view.",
      button = "SetView", run = function() return ViewToDefault("setview") end },
    { text = "Did the camera move? " .. FOLLOW_ASK, ask = true },
    { text = "Type /reload: does the default view stay?", reload = true },
    { text = "Reading the view after the /reload.", auto = true, run = function() return ViewRead("reload") end },
    { text = "After the /reload: " .. FOLLOW_ASK, ask = true },
})

-- 14. #51, the gamepad lead. In gamepad mode Blizzard_Gamepad/Core.lua puts
-- TEMP values on the two centring CVars (C_CVar.SetTempCVar), and the
-- library SetCVars both during a presentation and back at the end. What
-- does a plain SetCVar do to a temp value, and what is left once the temp is
-- removed? Each layer gets a value the others don't have, so every read says
-- which one it sees: the stored BASE, the gamepad's TEMP, the library's "0".
-- C_CVar.SetTempCVar / RemoveTempCVar / GetCVarInfo are in the 70959 dump.
local TEMP_CVARS = { "CameraKeepCharacterCentered", "CameraReduceUnexpectedMovement" }
local TEMP_GAMEPAD = { CameraKeepCharacterCentered = "1", CameraReduceUnexpectedMovement = "0" }
local TEMP_BASE = { CameraKeepCharacterCentered = "0", CameraReduceUnexpectedMovement = "1" }
local tempCapture = {}       -- what the library would capture: the reads under the temp

local function TempDB()
    LibShowcaseProbeDB.temp = type(LibShowcaseProbeDB.temp) == "table" and LibShowcaseProbeDB.temp or {}
    return LibShowcaseProbeDB.temp
end

local function TempApi(name)
    local c = G("C_CVar")
    return type(c) == "table" and type(c[name]) == "function" and c[name] or nil
end

local function TempRead(tag)
    local parts = {}
    for _, cvar in ipairs(TEMP_CVARS) do
        local info = TempApi("GetCVarInfo")
        local stored = ""
        if info then
            local ok, v = pcall(info, cvar)
            stored = (" (info %s)"):format(ok and tostring(v) or "error")
        end
        parts[#parts + 1] = ("%s=%s%s"):format(cvar, tostring(GetCVar(cvar)), stored)
    end
    local line = tag .. ": " .. table.concat(parts, ", ")
    say("== tempcvar " .. line)
    return line
end

-- Gamepad mode, as Blizzard's InputUtil.IsGamepadUIEnabled() tells it
-- (C_InputInterfaceStyle; Gamepad is 1). Its temps would make the start
-- values unreadable: GetCVar reads the temp, not the stored value.
local function InGamepadMode()
    local style = G("C_InputInterfaceStyle")
    if type(style) ~= "table" or type(style.GetCurrentStyle) ~= "function" then return false end
    local types = G("Enum") and Enum.InputDeviceInterfaceType
    local ok, current = pcall(style.GetCurrentStyle)
    return ok and current == (type(types) == "table" and types.Gamepad or 1)
end

local function TempStart()
    -- A temp already on would be taken for the stored value, and the Base
    -- write would replace the real one unseen (Codex, PR #52).
    if InGamepadMode() then error("gamepad mode is on: use the mouse and keyboard (move the mouse), then Retry", 0) end
    -- The start values (`pending`) stay until a verified put-back clears
    -- them: a run stopped after Base keeps the player's real ones for the
    -- next run, or for /fp ls tempback (Codex, PR #52). `orig` is the older
    -- probe's key, left behind even by a finished run: never trusted.
    local db = TempDB()
    if db.orig ~= nil then
        db.orig = nil
        say("  dropped an older probe's start values (they may be from a finished run)")
    end
    if type(db.pending) == "table" then
        say("  keeping an earlier run's start values (its put-back never ran): /fp ls tempback restores them")
    else
        db.pending = {}
        for _, cvar in ipairs(TEMP_CVARS) do db.pending[cvar] = GetCVar(cvar) end
    end
    local pad = G("C_GamePad") and C_GamePad.IsEnabled
    local okPad, enabled = false, nil
    if type(pad) == "function" then okPad, enabled = pcall(pad) end
    say(("  SetTempCVar %s, RemoveTempCVar %s, GetCVarInfo %s; C_GamePad.IsEnabled %s, GamePadEnable %s")
        :format(tostring(TempApi("SetTempCVar") ~= nil), tostring(TempApi("RemoveTempCVar") ~= nil),
            tostring(TempApi("GetCVarInfo") ~= nil), okPad and tostring(enabled) or "n/a",
            tostring(GetCVar("GamePadEnable"))))
    if not (TempApi("SetTempCVar") and TempApi("RemoveTempCVar")) then
        return false, "no C_CVar.SetTempCVar / RemoveTempCVar on this client"
    end
    return true, TempRead("start")
end

-- what: "base" stored values, "temp" the gamepad's temp values, "write" the
-- library's presentation write ("0"), "restore" the library's restore of what
-- it captured under the temp, "remove" the temp removed.
local function TempDo(what)
    -- Every write or removal checks the input mode first: switched to
    -- gamepad mid-run, a Remove would take Blizzard's own temps away. The
    -- step stays for Retry on mouse and keyboard (Codex, PR #52).
    if InGamepadMode() then error("gamepad mode is on: use the mouse and keyboard (move the mouse), then Retry", 0) end
    for _, cvar in ipairs(TEMP_CVARS) do
        if what == "base" then
            pcall(SetCVar, cvar, TEMP_BASE[cvar])
        elseif what == "temp" then
            pcall(TempApi("SetTempCVar"), cvar, TEMP_GAMEPAD[cvar])
            tempCapture[cvar] = GetCVar(cvar)
        elseif what == "write" then
            pcall(SetCVar, cvar, "0")
        elseif what == "restore" then
            pcall(SetCVar, cvar, tempCapture[cvar])
        elseif what == "remove" then
            pcall(TempApi("RemoveTempCVar"), cvar)
        end
    end
    return TempRead(what)
end

-- Everything back as it was when the procedure started, read back: a
-- mismatch throws (the step stays, Retry). Not in gamepad mode: removing the
-- temps would take Blizzard's own away (Codex, PR #52).
local function TempPutBack()
    local orig = TempDB().pending
    if type(orig) ~= "table" then error("no start values saved", 0) end
    if InGamepadMode() then error("gamepad mode is on: use the mouse and keyboard (move the mouse), then Retry", 0) end
    local wrong = {}
    for _, cvar in ipairs(TEMP_CVARS) do
        local remove = TempApi("RemoveTempCVar")
        if remove then pcall(remove, cvar) end
        if orig[cvar] ~= nil then
            pcall(SetCVar, cvar, orig[cvar])
            if GetCVar(cvar) ~= orig[cvar] then
                wrong[#wrong + 1] = ("%s %s (want %s)"):format(cvar, tostring(GetCVar(cvar)), orig[cvar])
            end
        end
    end
    local line = TempRead("put back")
    if #wrong > 0 then error("not put back: " .. table.concat(wrong, "; ") .. ". Retry", 0) end
    TempDB().pending = nil
    return true, line
end

Probe:Steps("tempcvar", {
    title = "A library write over the gamepad's temp CVars (#51)",
    { text = "Out of combat, mouse and keyboard (no controller needed). Reading the two centring CVars.", auto = true, run = TempStart },
    -- The control (run #474 left the temp values after Remove): no write
    -- between Temp and Remove.
    { text = "The control. Base writes stored values the temp won't use (KeepCentered 0, ReduceUnexpected 1).", button = "Base",
      run = function() return TempDo("base") end },
    { text = "Temp puts the gamepad's temp values on top.", button = "Temp", run = function() return TempDo("temp") end },
    { text = "Remove takes them off right away, with no write in between. Do the Base values come back?", button = "Remove",
      run = function() return TempDo("remove") end },
    { text = "Now with the library's writes. Base writes the stored values again.", button = "Base",
      run = function() return TempDo("base") end },
    { text = "Temp puts the gamepad's temp values on top (KeepCentered 1, ReduceUnexpected 0), as gamepad mode does.",
      button = "Temp", run = function() return TempDo("temp") end },
    { text = "Write does what a presentation does: SetCVar both to 0.", button = "Write", run = function() return TempDo("write") end },
    { text = "Restore does what the end of a presentation does: SetCVar both back to what it read under the temp.",
      button = "Restore", run = function() return TempDo("restore") end },
    { text = "Remove takes the temp values off, as leaving gamepad mode does. A clean layer shows the Base values again.",
      button = "Remove", run = function() return TempDo("remove") end },
    -- The same through the library itself: a real presentation over the temp.
    { text = "Base and Temp again, then Open starts a real presentation over them.", button = "Open", run = function()
          TempDo("base"); TempDo("temp")
          return OpenOrThrow()
      end },
    { text = "Close ends it.", button = "Close", run = function()
          if window and window:IsShown() then window:Hide() end
          return "closing"
      end },
    { text = "Waiting for the presentation to end.", timeout = 15, wait = PresentationEnded },
    { text = "Reading after the presentation, the temp still on.", auto = true, run = function() return TempRead("after presentation") end },
    { text = "Remove takes the temp values off.", button = "Remove", run = function() return TempDo("remove") end },
    { text = "Type /reload: what is stored?", reload = true },
    { text = "Reading after the /reload.", auto = true, run = function() return TempRead("reload") end },
    { text = "Putting both CVars back as they were at the start.", auto = true, run = TempPutBack },
})

-- After a tempcvar run that was stopped before its last step.
Probe:Command("tempback", function()
    if type(TempDB().pending) ~= "table" then say("tempback: nothing to put back"); return end
    local ok, a, b = pcall(TempPutBack)   -- ok, true, line; or false, the error
    say("tempback: " .. tostring(ok and b or a))
end, "put the centring CVars back after a stopped tempcvar run")

-- 15. The r10 release check: what changed since r4 that only the client can
-- show. The female framing (#38), the orbit at another turn speed (#39), a
-- combat start refusing a later handler's Enter (#21), a long countdown
-- holding the UI up (#40), and a presentation in gamepad mode (#54). The
-- countdown and gamepad parts need a group and a controller: Skip them
-- without.
local rel = {}

local function ReleaseFraming()
    local _, raceFile, raceID = UnitRace("player")
    local sex = G("UnitSex") and UnitSex("player")
    local line = ("race %s (%s), sex %s, shoulder offset %s"):format(tostring(raceFile), tostring(raceID),
        tostring(sex), tostring(GetCVar("test_cameraOverShoulder")))
    say("  release: " .. line)
    return true, line
end

-- A PLAYER_REGEN_DISABLED handler registered now, so after the library's:
-- what #21 refuses. Its Enter and HideGameUI must both say "combat".
local function ReleaseArmCombat()
    rel.combat = { state = "armed" }
    rel.combatFrame = rel.combatFrame or CreateFrame("Frame")
    rel.combatFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    rel.combatFrame:SetScript("OnEvent", function(self)
        self:UnregisterEvent("PLAYER_REGEN_DISABLED")
        local okEnter, whyEnter = SC:Enter()
        local okHide, whyHide = SC:HideGameUI()
        rel.combat = { state = "done", enter = tostring(okEnter) .. " " .. tostring(whyEnter),
                       hide = tostring(okHide) .. " " .. tostring(whyHide) }
        say(("  release: in a later REGEN_DISABLED handler, Enter -> %s, HideGameUI -> %s"):format(rel.combat.enter, rel.combat.hide))
        if okEnter or okHide then SC:ForceRestore("release check") end
    end)
    return "armed: pull a mob"
end

local function ReleaseCombatWait()
    local c = rel.combat or {}
    if c.state ~= "done" then return false, "waiting for combat to start" end
    return true, "Enter " .. c.enter, "HideGameUI " .. c.hide
end

local function ReleaseCombatCheck()
    local c = rel.combat or {}
    local ok = c.enter == "false combat" and c.hide == "false combat"
    return ok, ok and "both refused with combat" or ("Enter " .. tostring(c.enter) .. ", HideGameUI " .. tostring(c.hide))
end

-- The countdown: revealed as a dialog, and a HideGameUI 61 s later is still
-- refused (the old 60 s cap would have let it hide a 90 s countdown).
local function ReleaseCountdownWait()
    for _, r in ipairs(uiShown) do
        if r == "dialog" then
            rel.revealed = rel.revealed or GetTime()
            local left = 61 - (GetTime() - rel.revealed)
            if left <= 0 then return true, "61 s since the countdown brought the UI back" end
            return false, ("the UI is back; %d s to go before the hide is tried"):format(math.ceil(left))
        end
    end
    return false, "waiting for the countdown to bring the UI back"
end

local function ReleaseCountdownHide()
    local ok, why = SC:HideGameUI()
    say(("  release: HideGameUI 61 s into the countdown -> %s %s"):format(tostring(ok), tostring(why)))
    if ok then SC:RestoreGameUI() end
    rel.countdownOK = not ok and why == "dialog"
    return tostring(ok) .. " " .. tostring(why)
end

-- Gamepad mode: the presentation leaves the two centring CVars alone. The
-- stored values are read on mouse and keyboard, before and after (in gamepad
-- mode a read returns the temps); Enter's writes are counted by a SetCVar
-- post-hook, which leaves the call secure.
local function Centring()
    return tostring(GetCVar("CameraKeepCharacterCentered")) .. "/" .. tostring(GetCVar("CameraReduceUnexpectedMovement"))
end
local function IsCentring(name) return name == "CameraKeepCharacterCentered" or name == "CameraReduceUnexpectedMovement" end

local function ReleaseGamepadOpen()
    if not InGamepadMode() then error("not in gamepad mode: press a button on the controller, then Retry", 0) end
    if not rel.hooked then
        hooksecurefunc("SetCVar", function(name)
            if rel.counting and IsCentring(name) then rel.centringWrites = rel.centringWrites + 1 end
        end)
        rel.hooked = true
    end
    rel.centringWrites, rel.counting = 0, true
    local ok, err = pcall(OpenOrThrow)
    rel.counting = false
    if not ok then error(err, 0) end
    local line = ("%d centring writes by Enter in gamepad mode"):format(rel.centringWrites)
    say("  release: " .. line)
    return rel.centringWrites == 0, line
end

Probe:Steps("release", {
    title = "The r10 release check",
    { text = "Out of combat, somewhere open, on mouse and keyboard. Open starts a presentation.", button = "Open",
      screenshot = "release: framing", run = function() OpenOrThrow(); return ReleaseFraming() end },
    { text = "Is the character framed to one side and fully in view (a female character uses her own offset now)? Say the race and sex in the Note box.",
      ask = true },
    { text = "Note how fast the camera orbits, then Close.", button = "Close", run = Close },
    { text = "Waiting for the presentation to end.", timeout = 15, wait = PresentationEnded },
    { text = "Faster sets cameraYawMoveSpeed to twice its value (the probe puts it back), then opens again.", button = "Faster",
      run = function()
          local v = tonumber(GetCVar("cameraYawMoveSpeed")) or 180
          Set("cameraYawMoveSpeed", tostring(math.min(v * 2, 360)))
          return OpenOrThrow()
      end },
    { text = "Is the orbit about the same speed as before, not twice as fast?", ask = true },
    { text = "Close ends it and puts the turn speed back.", button = "Close", run = function() Close(); return RestoreAll() end },
    { text = "Waiting for the presentation to end.", timeout = 15, wait = PresentationEnded },
    -- #21
    { text = "Go next to a mob. Arm adds a combat-start handler after the library's, which tries Enter and HideGameUI.",
      button = "Arm", run = ReleaseArmCombat },
    { text = "Pull the mob.", timeout = 300, wait = ReleaseCombatWait, check = ReleaseCombatCheck },
    { text = "After the fight: did the UI stay up the whole time, with no presentation starting?", ask = true },
    -- #40 (a group)
    { text = "In a group (Skip this part if solo): Open starts a presentation.", button = "Open", run = function()
          uiShown, rel.revealed = {}, nil
          return OpenOrThrow()
      end },
    { text = "Type /countdown 90. The UI comes back; this step waits 61 s more.", timeout = 180, wait = ReleaseCountdownWait },
    { text = "Trying HideGameUI with the countdown still running: it must be refused.", auto = true, run = ReleaseCountdownHide,
      check = function() return rel.countdownOK == true, "refused with dialog" end },
    { text = "Close ends the presentation.", button = "Close", run = Close },
    { text = "Waiting for the presentation to end.", timeout = 15, wait = PresentationEnded },
    -- #54 (a controller)
    { text = "With a controller (Skip this part without one). On mouse and keyboard, Read records the centring CVars.",
      button = "Read", run = function()
          if InGamepadMode() then error("gamepad mode is on: move the mouse, then Retry", 0) end
          rel.centring = Centring()
          return "centring " .. rel.centring
      end },
    { text = "Press a controller button to switch to gamepad mode, then Open.", button = "Open", run = ReleaseGamepadOpen },
    { text = "Close ends the presentation.", button = "Close", run = Close },
    { text = "Waiting for the presentation to end.", timeout = 15, wait = PresentationEnded },
    { text = "Move the mouse (back to mouse and keyboard), then Read again: the centring CVars must be as before.",
      button = "Read", run = function()
          if InGamepadMode() then error("gamepad mode is on: move the mouse, then Retry", 0) end
          local now = Centring()
          say("  release: centring " .. now .. " (before " .. tostring(rel.centring) .. ")")
          return now == rel.centring, "centring " .. now .. ", before " .. tostring(rel.centring)
      end },
})

-- 16. #39's premise, measured: does MoveViewLeftStart's speed scale with
-- cameraYawMoveSpeed? The same MoveViewLeftStart(ORBIT_TEST_SPEED) at 90
-- and at 360; the tester presses Turned when the camera is back on the same
-- landmark, and the probe times each full turn. A ratio near 4 means it
-- scales (MINOR 7's compensation is right); near 1, it doesn't (the
-- compensation slows the orbit at a faster setting). r10's release check
-- (run #488) left it unclear.
local ORBIT_TEST_SPEED = 0.1
local orbitT = {}

local function OrbitStart(yaw)
    if window and window:IsShown() then window:Hide() end
    if SC:IsActive() or SC:IsOwner() then error("a presentation is running: wait for it to end, then Retry", 0) end
    Set("cameraYawMoveSpeed", yaw)
    if tostring(GetCVar("cameraYawMoveSpeed")) ~= yaw and tonumber(GetCVar("cameraYawMoveSpeed")) ~= tonumber(yaw) then
        error("cameraYawMoveSpeed did not take " .. yaw .. ": Retry", 0)
    end
    MoveViewLeftStop()
    MoveViewLeftStart(ORBIT_TEST_SPEED)
    orbitT[yaw] = { start = GetTime() }
    return ("turning at MoveViewLeftStart(%s) with cameraYawMoveSpeed %s"):format(ORBIT_TEST_SPEED, yaw)
end

local function OrbitTurned(yaw)
    MoveViewLeftStop()
    local t = orbitT[yaw]
    if not (t and t.start) then error("not started: Back to Start", 0) end
    t.seconds = GetTime() - t.start
    local line = ("cameraYawMoveSpeed %s: one turn in %.1f s"):format(yaw, t.seconds)
    say("  orbitspeed: " .. line)
    return line
end

local function OrbitVerdict()
    local slow, fast = orbitT["90"], orbitT["360"]
    if not (slow and slow.seconds and fast and fast.seconds and fast.seconds > 0) then
        return false, "a turn was not timed"
    end
    local ratio = slow.seconds / fast.seconds
    local verdict = ratio > 2.5 and "scales with cameraYawMoveSpeed (MINOR 7 is right)"
        or ratio < 1.6 and "does NOT scale (MINOR 7's compensation is wrong)" or "unclear: time them again"
    local line = ("90: %.1f s, 360: %.1f s, ratio %.2f: %s"):format(slow.seconds, fast.seconds, ratio, verdict)
    say("== orbitspeed " .. line)
    return ratio > 2.5 or ratio < 1.6, line
end

Probe:Steps("orbitspeed", {
    title = "Does the orbit's speed scale with cameraYawMoveSpeed (#39)",
    { text = "Out of combat, standing still, somewhere with a clear landmark (a tree, a building). Don't touch the mouse or the turn keys until the end. Start sets the turn speed to 90 and turns the camera.",
      button = "Start", run = function() return OrbitStart("90") end },
    { text = "Press Turned the moment the landmark is back where it was (one full turn).", button = "Turned",
      run = function() return OrbitTurned("90") end },
    { text = "Start again, at turn speed 360.", button = "Start", run = function() return OrbitStart("360") end },
    { text = "Press Turned when the landmark is back where it was.", button = "Turned",
      run = function() return OrbitTurned("360") end },
    { text = "Comparing the two turns, then putting the turn speed back.", auto = true,
      run = function() local ok, line = OrbitVerdict(); RestoreAll(); return ok, line end },
})

Probe:Steps("rereg", {
    title = "The experimental-CVar popup, re-registered",
    { text = "Out of combat. Unregister leaves the popup's handler unregistered (the control).",
      button = "Unregister", run = function() return Rereg("none") end },
    { text = "Type /console test_cameraOverShoulder 0.5 in chat. Did the experimental-feature popup appear?", ask = true },
    { text = "Register puts Blizzard's own handler back, from addon code.",
      button = "Register", run = function() return Rereg("direct") end },
    { text = "Type /console test_cameraOverShoulder 0.5 again. Did the popup appear? (Click Disable if it did.) The console says whether it ran TAINTED.",
      ask = true },
    { text = "Register a closure, as the library's r2 did.", button = "Register", run = function() return Rereg("closure") end },
    { text = "Type /console test_cameraOverShoulder 0.5 once more. Did the popup appear? (Click Disable if it did.)", ask = true },
    { text = "Putting the CVar back.", auto = true, run = RestoreAll },
    { text = "Type /reload: it clears the handler this procedure registered.", reload = true },
})

----------------------------------------------------------------------------
-- Load
----------------------------------------------------------------------------

Probe:OnBlocked(function(event, addon, func)
    local line = ("%s: %s %s"):format(tostring(event), Probe.Show(addon, true), Probe.Show(func, true))
    blockedSeen[#blockedSeen + 1] = line
    say("  " .. line)
end)

local ev = CreateFrame("Frame")
Probe:RegisterEvents(ev, { "ADDON_LOADED", "PLAYER_REGEN_DISABLED" })
ev:SetScript("OnEvent", function(_, event, a1)
    if event == "ADDON_LOADED" and a1 == ADDON then
        Probe:Ready()
        if type(LibShowcaseProbeDB) ~= "table" then LibShowcaseProbeDB = {} end
        if type(LibShowcaseProbeDB.log) ~= "table" then LibShowcaseProbeDB.log = {} end
        Probe:UseLog(LibShowcaseProbeDB.log, MAX_LOG)
        LibShowcaseProbeDB.loads = (LibShowcaseProbeDB.loads or 0) + 1
        local _, minor = LibStub:GetLibrary("LibShowcase-1.0", true)
        SC = lib():New({
            owner = "LibShowcaseProbe",
            db = function() return LibShowcaseProbeDB end,
            debug = function(msg) say("  [lib] " .. msg) end,
            onGameUIShown = function(reason)
                uiShown[#uiShown + 1] = tostring(reason)
                say(("  onGameUIShown %s (UI shown %s, presentation active %s, owner %s)"):format(tostring(reason),
                    tostring(UIParent:IsShown()), tostring(SC:IsActive()), tostring(SC:IsOwner())))
            end,
            onForcedExit = function(reason)
                say("  onForcedExit " .. tostring(reason))
                forcedSeen[tostring(reason)] = true
                if reason == "ui-shown" and window then window:Hide() end
            end,
        })
        -- The sound procedure's Alt+Z control; a post-hook leaves the call secure.
        hooksecurefunc("SetUIVisibility", function(shown) SoundControlHook(shown) end)
        hooksecurefunc("StaticPopup_Show", function(which)
            say("StaticPopup_Show " .. tostring(which))
            C_Timer.After(0, function() DialogTaint(tostring(which)) end)
        end)
        -- The special popups (a frame shown whole, the dungeon-invite role
        -- prompt on Retail): named, only read. The library hooks this too.
        if type(G("StaticPopupSpecial_Show")) == "function" then
            hooksecurefunc("StaticPopupSpecial_Show", function(frame)
                local name = type(frame) == "table" and frame.GetName and frame:GetName()
                say("StaticPopupSpecial_Show " .. tostring(name or frame))
            end)
        end
        say(("loaded (%d loads), LibShowcase r%s. /fp ls for the commands, /fp steps for the procedures")
            :format(LibShowcaseProbeDB.loads, tostring(minor)))
    elseif event == "PLAYER_REGEN_DISABLED" and combat.state == "armed" then
        combat.state = "waiting"
        -- #21: is the client's own combat flag already true here, where the
        -- lockdown is not yet (MEASURED 70205)? Then the library could tell
        -- "combat has started" whatever the handlers' order.
        combat.affecting = tostring(G("UnitAffectingCombat") and UnitAffectingCombat("player"))
        say(("== combat started; in the handler InCombatLockdown() = %s, UnitAffectingCombat(\"player\") = %s")
            :format(tostring(InCombatLockdown()), combat.affecting))
        RunCombatChecks(0)
    end
end)

NS._test = { Probe = Probe, combat = function() return combat end, window = function() return window end,
             instance = function() return SC end, uiShown = function() return uiShown end }
