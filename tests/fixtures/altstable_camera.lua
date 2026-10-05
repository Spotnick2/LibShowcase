-- FROZEN FIXTURE: AltStable's original camera presentation, verbatim.
-- Source: AltStable SheetUI.lua lines 196-911 @ 5297196 (main, 2026-10-04),
-- before the LibShowcase migration. tests/test_parity.lua runs it beside the
-- library and compares every camera, CVar and UI call. Never edit the code
-- below: it is the reference the library is held to.
--
-- It expects the globals AltStable (with API.FramesRegisteredForEvent) and
-- AltStableConfig; the test provides them.
local AltStableCameraPresentation = {
    active = false,
    mode = nil,
    capture = nil,
    elapsed = 0,
}
AltStable.AltStableCameraPresentation = AltStableCameraPresentation

do
    -- Minimal Narcissus-style camera presentation port for Classic/BCC.
    --
    -- Design notes:
    --   * We use `test_cameraOverShoulder` for Narcissus-style lateral
    --     framing, but unregister Blizzard's experimental-CVar popup event
    --     before writing it and always restore the captured value on close.
    --   * We only use stable, non-experimental camera APIs:
    --       SaveView / SetView          -- exact view restore
    --       GetCameraZoom / CameraZoomIn / CameraZoomOut
    --       MoveViewRightStart / MoveViewRightStop  (and Left*) for orbit
    --   * Every API call is feature-detected and pcall-guarded; missing APIs
    --     fail silently.
    --   * Combat / logout / reload / errors funnel through ForceRestore so
    --     no camera state can leak past close.

    local function CameraDebug(msg)
        if not (AltStableConfig and AltStableConfig.worldCameraPresentationDebug) then
            return
        end
        if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[AltStable Camera]|r " .. tostring(msg or ""))
        end
    end

    local function InOutSine(t, b, e, d)
        return -(e - b) / 2 * (math.cos(math.pi * t / d) - 1) + b
    end

    function AltStableCameraPresentation:_Clamp(v, minV, maxV, fallback)
        v = tonumber(v)
        if not v then
            return fallback
        end
        if v < minV then
            return minV
        end
        if v > maxV then
            return maxV
        end
        return v
    end

    function AltStableCameraPresentation:_GetConfig()
        AltStableConfig = AltStableConfig or {}
        if AltStable.EnsureConfigDefaults then
            AltStable.EnsureConfigDefaults()
        end
        return {
            enabled       = AltStableConfig.enableWorldCameraPresentation ~= false,
            enterDuration = self:_Clamp(AltStableConfig.worldCameraEnterDuration, 0.35, 1.50, 1.50),
            exitDuration  = self:_Clamp(AltStableConfig.worldCameraExitDuration,  0.25, 1.20, 0.45),
            zoomPreset    = self:_Clamp(AltStableConfig.worldCameraZoomPreset,    1.20, 18.0, 2.2),
            shoulderZoomReference = self:_Clamp(AltStableConfig.worldCameraShoulderZoomReference, 1.20, 18.0, 6.2),
            mountedZoomPreset = self:_Clamp(AltStableConfig.worldCameraMountedZoomPreset, 1.20, 18.0, 8.0),
            mountedShoulderOffset = self:_Clamp(AltStableConfig.worldCameraMountedShoulderOffset, 0.0, 12.0, 8.0),
            forceMountedPresentation = AltStableConfig.worldCameraForceMountedPresentation == true,
            yawOffset     = self:_Clamp(AltStableConfig.worldCameraYawOffset,    -1.2,  1.2, -0.22),
            yawDegrees    = self:_Clamp(AltStableConfig.worldCameraYawDegrees,    20,   540, 430),
            savedViewSlot = math.floor(self:_Clamp(AltStableConfig.worldCameraSavedViewSlot, 2, 5, 5)),
            continuousOrbit = AltStableConfig.worldCameraContinuousOrbit == true,
            orbitSpeed    = self:_Clamp(AltStableConfig.worldCameraOrbitSpeed, 0.001, 0.05, 0.005),
            hideGameUI    = AltStableConfig.hideGameUIOnPresentation ~= false,   -- Alt+Z-style clean showcase (default on)
        }
    end

    function AltStableCameraPresentation:IsSupported()
        -- Only require the stable APIs we actually call. test_cameraOverShoulder
        -- intentionally NOT in this set.
        return type(SaveView)       == "function"
           and type(SetView)        == "function"
           and type(GetCameraZoom)  == "function"
           and type(CameraZoomIn)   == "function"
           and type(CameraZoomOut)  == "function"
    end

    function AltStableCameraPresentation:CaptureCurrentCameraState()
        if not self:IsSupported() then
            return false
        end

        local config = self:_GetConfig()
        self.config  = config
        self.capture = {
            savedViewSlot = config.savedViewSlot,
            zoom          = tonumber(GetCameraZoom()) or 0,
        }
        pcall(SaveView, self.capture.savedViewSlot)
        return true
    end

    function AltStableCameraPresentation:_SetZoom(goal)
        local current = tonumber(GetCameraZoom()) or goal
        local delta = (tonumber(goal) or current) - current
        if math.abs(delta) < 0.001 then
            return
        end
        if delta > 0 then
            pcall(CameraZoomOut, delta)
        else
            pcall(CameraZoomIn, -delta)
        end
    end

    function AltStableCameraPresentation:_StopYaw()
        if type(MoveViewRightStop) == "function" then
            pcall(MoveViewRightStop)
        end
        if type(MoveViewLeftStop) == "function" then
            pcall(MoveViewLeftStop)
        end
    end

    -- Lateral character placement via test_cameraOverShoulder. This is
    -- the "experimental" CVar that triggers WoW's confirmation popup —
    -- but we silence that popup immediately before each of our SetCVar
    -- calls fires (see SuppressExperimentalCVarPopup at the end of this
    -- block; every test_* write in the addon goes through it). Narcissus
    -- uses the same approach.
    --
    -- Per-race shoulder factor table copied from Narcissus Classic
    -- ZoomValuebyRaceID. Format: { factor1, factor2 } — used as
    --   offset = zoom * factor1 + factor2
    -- which matches each race's body width / pivot offset so the character
    -- ends up framed in roughly the same on-screen position regardless of
    -- which character is logged in.
    local SHOULDER_FACTORS = {
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
    }
    local MOUNTED_SHOULDER_FACTORS = { 1.2495, -4.0 }

    function AltStableCameraPresentation:_IsPlayerMounted()
        if self.config and self.config.forceMountedPresentation then
            return true
        end
        if type(IsMounted) == "function" and IsMounted() then
            return true
        end
        if type(UnitBuff) == "function" then
            for i = 1, 40 do
                local name, _, icon = UnitBuff("player", i)
                if not name then
                    break
                end
                icon = tostring(icon or ""):lower()
                if icon:find("mount", 1, true) or icon:find("ability_druid_travelform", 1, true) then
                    return true
                end
            end
        end
        return false
    end

    function AltStableCameraPresentation:_GetTargetZoom()
        if self:_IsPlayerMounted() and self.config then
            return self.config.mountedZoomPreset or 8.0
        end
        return (self.config and self.config.zoomPreset) or 2.2
    end

    function AltStableCameraPresentation:_ComputeShoulderOffset(zoom)
        local raceID = 0
        local factors
        if self:_IsPlayerMounted() then
            return (self.config and self.config.mountedShoulderOffset) or 8.0
        elseif type(UnitRace) == "function" then
            local _, _, rid = UnitRace("player")
            raceID = tonumber(rid) or 0
            factors = SHOULDER_FACTORS[raceID] or SHOULDER_FACTORS[0]
        end
        factors = factors or SHOULDER_FACTORS[0]
        -- Sign convention in WoW: POSITIVE shoulder offset shifts the
        -- character to the LEFT on screen (camera goes right of player).
        -- That's exactly what the user wants (room for the addon on the
        -- right, character visible on the left).
        local placementZoom = (self.config and self.config.shoulderZoomReference) or zoom
        local raw = placementZoom * factors[1] + factors[2]
        -- Allow a global multiplier so users can dial it in. >1.0 pushes
        -- the character further left.
        local mult = tonumber(AltStableConfig and AltStableConfig.worldCameraShoulderMult) or 1.0
        return raw * mult
    end

    function AltStableCameraPresentation:_StartYaw(speed)
        speed = tonumber(speed) or 0
        if math.abs(speed) <= 0.001 then
            return
        end
        self:_StopYaw()
        self:_ApplyYaw(speed)
    end

    function AltStableCameraPresentation:_ApplyYaw(speed)
        speed = tonumber(speed) or 0
        if math.abs(speed) <= 0.001 then
            return
        end
        if speed > 0 and type(MoveViewRightStart) == "function" then
            pcall(MoveViewRightStart, speed)
        elseif speed < 0 and type(MoveViewLeftStart) == "function" then
            pcall(MoveViewLeftStart, -speed)
        elseif speed < 0 and type(MoveViewRightStart) == "function" then
            pcall(MoveViewRightStart, -speed)
        end
    end

    -- Slow continuous orbit (Narcissus-style). Uses the same MoveView API
    -- as the swing but bypasses the swing-speed clamp because orbit speeds
    -- are an order of magnitude smaller (e.g. 0.005 vs 0.55).
    function AltStableCameraPresentation:_StartOrbit(speed)
        speed = tonumber(speed) or 0
        if math.abs(speed) <= 0.0001 then
            return
        end
        self:_StopYaw()
        if speed > 0 and type(MoveViewRightStart) == "function" then
            pcall(MoveViewRightStart, speed)
        elseif speed < 0 and type(MoveViewLeftStart) == "function" then
            pcall(MoveViewLeftStart, -speed)
        end
    end

    function AltStableCameraPresentation:_MaybeSalute()
        if self.didSalute then
            return
        end
        self.didSalute = true
        if not (AltStableConfig and AltStableConfig.enableWorldCameraSalute) then
            return
        end
        if InCombatLockdown and InCombatLockdown() then
            return
        end
        if type(DoEmote) == "function" then
            pcall(DoEmote, "SALUTE")
        end
    end

    function AltStableCameraPresentation:UpdateAnimation(elapsed)
        if not self.mode then
            if self.animFrame then
                self.animFrame:Hide()
            end
            return
        end

        self.elapsed = (self.elapsed or 0) + (elapsed or 0)

        if self.mode == "enter" then
            -- The zoom is fired once in Enter() (the engine handles the
            -- smooth animation natively). All we do here is wait for the
            -- swing duration to elapse, then hand the yaw off to the slow
            -- continuous orbit.
            local duration = math.max(0.01, self.config and self.config.enterDuration or 1.50)
            if self.config and self.yawDir and self.yawFromSpeed and self.yawToSpeed then
                local t = math.min(self.elapsed, duration)
                local speed = InOutSine(t, self.yawFromSpeed, self.yawToSpeed, duration)
                self:_ApplyYaw(self.yawDir * speed)
            end
            if self.elapsed >= duration then
                if self.config and self.config.continuousOrbit then
                    local dir = self.yawDir or 1
                    self:_StartOrbit(dir * (self.config.orbitSpeed or 0.005))
                else
                    self:_StopYaw()
                end
                self:_MaybeSalute()
                self.mode = nil
                if self.animFrame then
                    self.animFrame:Hide()
                end
                CameraDebug("enter complete")
            end
            return
        end

        if self.mode == "exit" then
            -- SetView already snapped the camera back instantly in Exit();
            -- we just wait out the exit duration so the OnUpdate loop has a
            -- chance to be torn down cleanly.
            local duration = math.max(0.01, self.config and self.config.exitDuration or 0.45)
            if self.elapsed >= duration then
                self:ForceRestore("exit-complete")
            end
        end
    end

    -- NOTE: We deliberately do NOT touch the AltStable frame's size or
    -- anchor during the camera presentation. Earlier iterations moved the
    -- addon off to a corner so the screen-centered character would be
    -- visible — but the user's correct insight is that this is purely a
    -- camera concern. We now use test_cameraOverShoulder to push the
    -- character laterally on screen (Narcissus-style), which leaves the
    -- addon sitting where the user placed it.

    -- Camera CVars that CANCEL a shoulder offset, added in the 11.0.x client
    -- this codebase comes from. Captured on entry, restored on exit, and set to
    -- "0" in between. Named here so the restore loop cannot drift from the
    -- write loop.
    local CENTRING_CVARS = {
        "CameraKeepCharacterCentered",
        "CameraReduceUnexpectedMovement",
    }
    AltStable._test = AltStable._test or {}
    AltStable._test.CENTRING_CVARS = CENTRING_CVARS
    AltStable._test.CameraPresentation = AltStableCameraPresentation

    function AltStableCameraPresentation:Enter()
        if self.active then
            -- Unless we are on the way OUT. Exit() leaves active set and clears
            -- it only when the animation completes, so reopening the sheet
            -- inside that window used to no-op here - and the pending
            -- ForceRestore then fired with the sheet OPEN, putting
            -- CameraKeepCharacterCentered back to 1 and re-centring the
            -- character. The bug this feature exists to prevent, half a second
            -- late.
            --
            -- Finish the exit properly and enter afresh, rather than flipping
            -- the mode back. Exit() has ALREADY restored the game UI, stopped
            -- the yaw and put the saved view back, so simply resuming leaves a
            -- presentation that is missing everything Exit undid - a reopened
            -- sheet with no showcase at all, which is its own bug.
            if self.mode ~= "exit" then return end
            self:ForceRestore("re-enter during exit")
            CameraDebug("re-entered during exit; restarting the presentation")
        end
        if InCombatLockdown and InCombatLockdown() then
            return
        end
        self.config = self:_GetConfig()
        if not (self.config and self.config.enabled) then
            return
        end
        if not self:CaptureCurrentCameraState() then
            return
        end

        self.active        = true
        self.mode          = "enter"
        self.elapsed       = 0
        self.didSalute     = false
        self.enterFromZoom = self.capture.zoom
        self.enterToZoom   = self:_GetTargetZoom()

        -- Narcissus starts from camera view 2 before its entry yaw. We save
        -- the user's current view first, so Exit/ForceRestore still returns
        -- exactly to the pre-AltStable camera.
        if type(SetView) == "function" then
            pcall(SetView, 2)
        end

        -- Raise cameraDistanceMaxZoomFactor temporarily. On Classic/BCC this
        -- is a stable (non-experimental) CVar with a max of 2.6. The default
        -- of 1.0 caps the engine's zoom-out around ~15 yards; lifting it lets
        -- our preset of 8+ actually reach its target instead of clamping
        -- silently. Captured on entry, restored on exit.
        if type(GetCVar) == "function" and type(SetCVar) == "function" then
            self.capture.cameraDistanceMaxZoomFactor =
                tonumber(GetCVar("cameraDistanceMaxZoomFactor")) or 1.0
            if self.capture.cameraDistanceMaxZoomFactor < 2.0 then
                pcall(SetCVar, "cameraDistanceMaxZoomFactor", 2.0)
            end
        end

        -- Fire the zoom once and let the engine animate it natively. Doing
        -- this incrementally per-frame in OnUpdate (the previous approach)
        -- causes CameraZoomOut calls to queue up and overshoot, leaving the
        -- camera essentially stuck close to the player.
        self:_SetZoom(self.enterToZoom)

        -- Lateral character shift via test_cameraOverShoulder. This is
        -- exactly what Narcissus does — the only reason it's "experimental"
        -- in BCC is the popup gate, which we suppress by unregistering
        -- EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED right before the write (see
        -- SuppressExperimentalCVarPopup at the bottom of this `do` block).
        -- Capture before we touch it; restore on exit.
        if type(GetCVar) == "function" and type(SetCVar) == "function" then
            -- The offset alone is not enough on this codebase. An 11.0.x client
            -- added CameraKeepCharacterCentered, which does exactly what it
            -- says: it re-centres the character and cancels the shoulder offset
            -- we just wrote. So the offset was applied and then quietly undone,
            -- which is why this looked correct in the source and wrong on
            -- screen (#25). CameraReduceUnexpectedMovement is the same vintage
            -- and smooths our move away.
            --
            -- Evidence: DialogueUI 1.0.5-f works on Forever and sets both,
            -- commented "11.0.2 Fix", alongside the same
            -- test_cameraOverShoulder we use.
            --
            -- Neither is a test_ CVar, so neither needs the experimental-popup
            -- suppression that the offset write goes through.
            for _, cvar in ipairs(CENTRING_CVARS) do
                -- Only touch what the client actually has. Writing to a CVar
                -- that does not exist CREATES it, so an older build would come
                -- out of this with a setting it never had and no way back -
                -- the restore cannot undo what it never captured.
                local prev = GetCVar(cvar)
                if prev ~= nil then
                    self.capture[cvar] = prev
                    pcall(SetCVar, cvar, "0")
                end
            end

            self.capture.shoulderOffset = tonumber(GetCVar("test_cameraOverShoulder")) or 0
            local desired = self:_ComputeShoulderOffset(self.enterToZoom)
            if AltStable.SuppressExperimentalCVarPopup then
                AltStable.SuppressExperimentalCVarPopup()
            end
            pcall(SetCVar, "test_cameraOverShoulder", desired)
            -- Report what each CVar is NOW, not what it was. The first version
            -- printed the captured value under a label that reads as current
            -- state, so on a client where centring had been on it logged
            -- "centred=1" immediately after setting it to 0 - which anyone
            -- debugging a recurrence would read as "the fix did not run".
            local after = {}
            for _, cvar in ipairs(CENTRING_CVARS) do
                after[#after + 1] = cvar:gsub("^Camera", "") .. "="
                    .. tostring(GetCVar(cvar)) .. " (was "
                    .. tostring(self.capture[cvar]) .. ")"
            end
            CameraDebug(string.format("shoulder: from=%.3f to=%.3f  %s",
                self.capture.shoulderOffset, desired, table.concat(after, " ")))
        end

        do
            local yawMoveSpeed = tonumber(GetCVar and GetCVar("cameraYawMoveSpeed")) or 180
            if yawMoveSpeed <= 0 then yawMoveSpeed = 180 end
            local dir     = (self.config.yawOffset or -1) < 0 and -1 or 1
            local degrees = math.abs(tonumber(self.config.yawDegrees) or 430)
            local seconds = math.max(0.05, tonumber(self.config.enterDuration) or 1.50)
            local speed   = (degrees / yawMoveSpeed) / seconds
            speed = self:_Clamp(speed, 0.10, 4.0, 1.0)
            self.yawDir = dir
            self.yawFromSpeed = speed
            self.yawToSpeed = self.config.orbitSpeed or 0.005
            self:_StartYaw(dir * speed)
            CameraDebug(string.format("enter yaw: target=%d speed=%.3f yawMoveSpeed=%.1f",
                degrees, speed, yawMoveSpeed))
        end

        if self.animFrame then
            self.animFrame:Show()
        end
        self:HideGameUI()
        CameraDebug("enter start")
    end

    function AltStableCameraPresentation:Exit(reason)
        if not self.active or self.mode == "exit" then
            return
        end
        self:RestoreGameUI()
        self:_StopYaw()

        self.mode         = "exit"
        self.elapsed      = 0
        self.exitFromZoom = tonumber(GetCameraZoom()) or (self.capture and self.capture.zoom) or 0
        self.exitToZoom   = (self.capture and self.capture.zoom) or self.exitFromZoom

        -- Snap the saved view back immediately; the zoom lerp on top makes the
        -- handoff look smooth even though the underlying view restore is instant.
        if self.capture and self.capture.savedViewSlot and type(SetView) == "function" then
            pcall(SetView, self.capture.savedViewSlot)
        end

        if self.animFrame then
            self.animFrame:Show()
        end
        CameraDebug("exit start: " .. tostring(reason or "hide"))
    end

    function AltStableCameraPresentation:ForceRestore(reason)
        self:RestoreGameUI()
        self:_StopYaw()
        if self.animFrame then
            self.animFrame:Hide()
        end

        if self.capture then
            if self.capture.savedViewSlot and type(SetView) == "function" then
                pcall(SetView, self.capture.savedViewSlot)
            end
            self:_SetZoom(self.capture.zoom or 0)
            -- Restore CVars exactly as captured. We restore unconditionally
            -- (even if we didn't bump them) so any path through this function
            -- leaves no trace of our CVar changes.
            if type(SetCVar) == "function" then
                if self.capture.cameraDistanceMaxZoomFactor then
                    pcall(SetCVar, "cameraDistanceMaxZoomFactor",
                          self.capture.cameraDistanceMaxZoomFactor)
                end
                if self.capture.shoulderOffset then
                    if AltStable.SuppressExperimentalCVarPopup then
                        AltStable.SuppressExperimentalCVarPopup()
                    end
                    pcall(SetCVar, "test_cameraOverShoulder",
                          self.capture.shoulderOffset)
                end
                -- Put the centring CVars back exactly as found. A nil capture
                -- means the CVar did not exist on this client, and writing a
                -- default over it would be inventing a setting the player never
                -- had.
                for _, cvar in ipairs(CENTRING_CVARS) do
                    if self.capture[cvar] ~= nil then
                        pcall(SetCVar, cvar, self.capture[cvar])
                    end
                end
            end
        end

        self.active  = false
        self.mode    = nil
        self.capture = nil
        self.elapsed = 0
        CameraDebug("restored: " .. tostring(reason or "force"))
    end

    -- ── Optional game-UI hide (Narcissus-style clean showcase) ──────────────
    -- Uses the engine's own SetUIVisibility(false) — the same call Alt+Z makes —
    -- to hide the ENTIRE UI (Blizzard frames, unit frames, and driver-controlled
    -- addon windows like Details! that a per-frame :Hide() can't suppress, since
    -- they re-show themselves). The 3D character (WorldFrame) stays visible.
    --
    -- SetUIVisibility hides everything under UIParent, so we first lift the sheet
    -- AND GameTooltip out from under UIParent (SetParent(nil)) — exactly what
    -- Narcissus's TakeOutFromUIParent does. Reparented frames are siblings of
    -- UIParent, untouched by the engine hide, so the sheet stays up. Lifting
    -- GameTooltip too (not just the sheet) is what makes the ~100 existing
    -- GameTooltip:SetOwner/AddLine callsites keep working — an earlier attempt
    -- moved only the sheet, leaving GameTooltip stranded in the hidden UIParent
    -- so its tooltips vanished. Strata is set so GameTooltip (TOOLTIP) draws
    -- above the sheet (DIALOG).
    --
    -- Combat-safe: SetUIVisibility is what Alt+Z uses and is callable in combat;
    -- SetParent/SetScale on our NON-secure sheet + GameTooltip is allowed in
    -- combat. HideGameUI bails on entry in combat (Enter does too); every restore
    -- path (Exit + ForceRestore on combat/logout/reload) calls RestoreGameUI, so
    -- the UI can never stay stuck hidden.

    -- Lift a frame out from under UIParent (state=true) or put it back (false),
    -- compensating scale so its on-screen size is unchanged either way.
    -- Idempotent in BOTH directions, and that is load-bearing rather than
    -- tidiness. Lifting an already-lifted frame used to overwrite the saved
    -- scale and strata with the LIFTED ones - so the restore afterwards put the
    -- frame back at FULLSCREEN_DIALOG, permanently raised, and the only symptom
    -- was somebody else's dialog appearing in the wrong place. The two callers
    -- that existed happened to guard at their own end (HideGameUI bails on
    -- self.uiHidden, LiftPopup on _altstableLifted), which meant the trap sat
    -- one careless caller away from firing. The flag lives on the frame, so it
    -- covers callers that have no state of their own.
    function AltStableCameraPresentation:_TakeOut(frame, strata, state)
        if not frame then return end
        state = state and true or false
        if (frame._atLifted or false) == state then return end
        frame._atLifted = state
        if state then
            frame._atSavedStrata = frame:GetFrameStrata()
            frame._atSavedScale  = frame:GetScale()
            local eff = frame:GetEffectiveScale()          -- capture while still parented
            pcall(frame.SetParent, frame, nil)
            if strata then pcall(frame.SetFrameStrata, frame, strata) end
            pcall(frame.SetScale, frame, eff)              -- keep the same apparent size
        else
            pcall(frame.SetParent, frame, UIParent)
            pcall(frame.SetScale, frame, frame._atSavedScale or 1)
            if frame._atSavedStrata then pcall(frame.SetFrameStrata, frame, frame._atSavedStrata) end
            frame._atSavedStrata, frame._atSavedScale = nil, nil
        end
    end

    -- Anything that must stay visible while the showcase has the game UI hidden
    -- has to be lifted out from under UIParent - no strata makes a child of a
    -- hidden parent draw. The sheet and GameTooltip are lifted below; this is
    -- the same door for everything else, so the next thing that needs it does
    -- not rediscover the problem.
    function AltStable.IsGameUIHidden()
        return AltStableCameraPresentation.uiHidden == true
    end

    function AltStable.LiftAboveHiddenUI(frame, state)
        if not frame then return end
        AltStableCameraPresentation:_TakeOut(frame, state and "FULLSCREEN_DIALOG" or nil, state)
    end

    function AltStableCameraPresentation:HideGameUI()
        if self.uiHidden then return end
        if not (self.config and self.config.hideGameUI) then return end
        local sheet = self.sheetFrame
        if not sheet then return end
        if InCombatLockdown and InCombatLockdown() then return end
        if type(SetUIVisibility) ~= "function" then return end   -- no engine support: skip cleanly

        -- Close any open chat edit box first. If we were opened by typing "/alts"
        -- in chat, its edit box is still mid-input; hiding the UI in that state
        -- and restoring it later resurrects a half-focused, un-closable /say box.
        -- Deactivating it now means restore brings nothing back.
        for i = 1, (NUM_CHAT_WINDOWS or 10) do
            local eb = _G["ChatFrame" .. i .. "EditBox"]
            if eb and eb.IsShown and eb:IsShown() then
                if type(ChatEdit_DeactivateChat) == "function" then
                    pcall(ChatEdit_DeactivateChat, eb)
                else
                    if eb.ClearFocus then pcall(eb.ClearFocus, eb) end
                    if eb.Hide then pcall(eb.Hide, eb) end
                end
            end
        end

        self:_TakeOut(sheet, "DIALOG", true)
        self:_TakeOut(GameTooltip, "TOOLTIP", true)
        pcall(SetUIVisibility, false)
        self.uiHidden = true
    end

    function AltStableCameraPresentation:RestoreGameUI()
        if not self.uiHidden then return end
        -- Clear the flag BEFORE re-showing the UI so the SetUIVisibility hook
        -- below sees us as already-restoring and doesn't recursively close.
        self.uiHidden = false
        if type(SetUIVisibility) == "function" then pcall(SetUIVisibility, true) end
        self:_TakeOut(self.sheetFrame, nil, false)
        self:_TakeOut(GameTooltip, nil, false)
    end

    AltStableCameraPresentation.animFrame = CreateFrame("Frame")
    AltStableCameraPresentation.animFrame:Hide()
    AltStableCameraPresentation.animFrame:SetScript("OnUpdate", function(_, elapsed)
        AltStableCameraPresentation:UpdateAnimation(elapsed)
    end)

    AltStableCameraPresentation.eventFrame = CreateFrame("Frame")
    AltStableCameraPresentation.eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    AltStableCameraPresentation.eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    AltStableCameraPresentation.eventFrame:RegisterEvent("PLAYER_LOGOUT")
    AltStableCameraPresentation.eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    AltStableCameraPresentation.eventFrame:SetScript("OnEvent", function(_, event)
        local p = AltStableCameraPresentation
        if event == "PLAYER_REGEN_ENABLED" then
            -- Combat ended: nothing to retry (combat START ForceRestores the
            -- showcase, so uiHidden is already false by now). Guarded restore
            -- is a cheap belt-and-suspenders in case a hide outlived combat.
            if p.uiHidden then p:RestoreGameUI() end
            return
        end
        if p.active then
            p:ForceRestore(event)
        end
    end)

    -- ESC (or Alt+Z) while our showcase is up: the engine un-hides the UI by
    -- calling SetUIVisibility(true). That's the same "two-ESC" hazard whole-UI
    -- hiding always had — first press un-hides, the sheet stays open. Catch that
    -- re-show here and close the sheet so a single ESC does the whole thing. Our
    -- own RestoreGameUI clears uiHidden BEFORE it re-shows, so this no-ops on the
    -- normal-close path (Narcissus hooks SetUIVisibility the same way).
    if type(hooksecurefunc) == "function" and type(SetUIVisibility) == "function" then
        hooksecurefunc("SetUIVisibility", function(state)
            local p = AltStableCameraPresentation
            if state and p.uiHidden and p.sheetFrame and p.sheetFrame:IsShown() then
                p.sheetFrame:Hide()   -- OnHide -> Exit -> RestoreGameUI (full restore)
            end
        end)
    end

    -- Suppress the engine-level "Are you sure you want to enable this
    -- experimental feature?" popup, which fires whenever a script writes a
    -- test_* CVar. There is no per-CVar opt-in; you get the popup for all of
    -- them or none. Narcissus takes the same approach.
    --
    -- On Classic the handler lived on UIParent, so unregistering there was
    -- enough. On this client it does not, which is why the popup reappeared on
    -- every window close and "Accept" never stuck - accepting does not stop
    -- the next write from asking again.
    --
    -- So find the actual owner rather than assuming one, and call this
    -- immediately before each of our own test_* writes rather than once at
    -- file load. Two reasons: the owning frame may not exist yet at load, and
    -- unregistering the event takes the confirmation gate away from Blizzard's
    -- own handler for the rest of the session - so we only pay that cost for
    -- users who actually touch a feature that writes one of these CVars.
    AltStable.SuppressExperimentalCVarPopup = function()
        local ev = "EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED"
        local n = 0
        -- The adapter hands back a fresh list (the raw API returns varargs,
        -- not a table - see Compat.lua), so there is nothing live to iterate
        -- and unregistering as we go is safe.
        for _, f in ipairs(AltStable.API.FramesRegisteredForEvent(ev)) do
            if type(f) == "table" and type(f.UnregisterEvent) == "function" then
                if pcall(f.UnregisterEvent, f, ev) then n = n + 1 end
            end
        end
        -- Belt and braces for a client where the lookup is unavailable.
        if n == 0 and UIParent and type(UIParent.UnregisterEvent) == "function" then
            pcall(UIParent.UnregisterEvent, UIParent, ev)
        end
        return n
    end
end

return AltStableCameraPresentation
