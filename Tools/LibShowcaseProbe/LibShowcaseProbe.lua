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
--
-- Commands (/fp ls <command>), for a one-off:
--   pitch [centring|off] | nudge 0|1 | combat | invite | show [N] | taint | prompts |
--   names [ui|list] | testcvar | rereg closure|direct|none | dialogs | focus |
--   next | restore | clear
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
local namesOpen              -- "show" or "ui" while a names check holds the names hidden
local function Invite()
    say("== invite: the presentation opens with the UI hidden")
    if not (window and window:IsShown()) then Show() end
    -- The window shown is not the presentation running: another addon's
    -- showcase holding the lease (Enter -> busy), or the UI already hidden
    -- (the window shown under it, so its OnShow and Enter wait), leaves none.
    local running = SC:IsActive() and SC:IsOwner()
    if not running then
        say("  the presentation did NOT start (owner " .. tostring(SC:IsOwner()) .. "): close any other showcase, then Retry")
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
    { text = "Out of combat, near a mob. Arm, then pull it: once InCombatLockdown() is true the probe hides the UI and shows it again 0.5 s later.",
      button = "Arm", run = Combat },
    -- "no lockdown" (the poll gave up after 10 s) ends the wait too, as a FAIL.
    { text = "Pull the mob and keep fighting. This step completes once both calls have run.", timeout = 300,
      wait = function()
          if combat.state == "done" or combat.state == "no lockdown" then
              return true, combat.state, combat.hide, combat.show, combat.blockedText
          end
          return false, "combat check: " .. tostring(combat.state)
      end,
      check = function() return combat.state == "done", combat.state end },
    { text = "Did the UI disappear and come back during the fight?", ask = true },
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
      -- A refused Enter is a FAIL here, not a step that reads "true" (run #419:
      -- another addon's showcase held the lease).
      check = function() return SC:IsActive() and SC:IsOwner(), "presentation running" end },
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
                if reason == "ui-shown" and window then window:Hide() end
            end,
        })
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
        say(("== combat started; InCombatLockdown() in the handler = %s"):format(tostring(InCombatLockdown())))
        RunCombatChecks(0)
    end
end)

NS._test = { Probe = Probe, combat = function() return combat end, window = function() return window end,
             instance = function() return SC end, uiShown = function() return uiShown end }
