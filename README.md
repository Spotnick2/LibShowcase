# LibShowcase-1.0

A "showcase" camera presentation for World of Warcraft: Forever (Interface 16001) addons: while
your window is open, the camera swings round to face the character, zooms in, moves the
character to one side of the screen, optionally orbits slowly, and hides the game UI (Alt+Z
style) with your window lifted above it. Everything it changes is put back on close, on combat,
on logout, on a loading screen, and after a crash (on the next login).

Extracted from AltStable's `AltStableCameraPresentation` (the Narcissus-style showcase), with
PortalRoulette's camera extras as opt-in options.

Embedded with LibStub; players don't install it separately.

> **Status:** r1 implemented on `feature/r1`. Local only: not published and not tagged yet.
> See `docs/DESIGN.md`.

## Embedding

`.pkgmeta`:

```yaml
externals:
  Libs/LibShowcase-1.0:
    url: https://github.com/Spotnick2/LibShowcase
    tag: r3

ignore:
  # CurseForge's packager doesn't apply an external's own ignore list.
  - Libs/LibShowcase-1.0/tests
  - Libs/LibShowcase-1.0/docs
  - Libs/LibShowcase-1.0/Tools
  - Libs/LibShowcase-1.0/AGENTS.md
  - Libs/LibShowcase-1.0/CLAUDE.md
  - Libs/LibShowcase-1.0/README.md
```

TOC, before your own files:

```
Libs\LibShowcase-1.0\LibShowcase-1.0.xml
```

## Usage

```lua
local Showcase = LibStub("LibShowcase-1.0"):New({
    owner = "MyAddon",
    db = function() return MyAddonDB end,   -- crash self-heal lives here (a SavedVariables table)
    onForcedExit = function(reason)         -- Esc/Alt+Z ("ui-shown"), combat, logout, zoning
        if reason == "ui-shown" then MyWindow:Hide() end
    end,
    onGameUIShown = function(reason)        -- "dialog": a Blizzard dialog brought the UI back;
    end,                                    -- the presentation and your window stay
})

MyWindow:SetScript("OnShow", function(self) Showcase:Enter(self) end)   -- true, or false + reason
MyWindow:SetScript("OnHide", function() Showcase:Exit("closed") end)
```

`Enter` answers `false, "combat" | "unsupported" | "busy"`: `busy` means another addon holds the
showcase (the camera is global, so there is one owner at a time).

**Blizzard dialogs:** the library never shows or touches a StaticPopup (an addon that does taints
Blizzard's shared dialog frames, and the player's Quit or accept-invite buttons then fail:
measured on 70205). When one appears while your window has the UI hidden, the library brings the
UI back and keeps the presentation running (so do a ready check, a dungeon proposal or a loot
roll). If a dialog is already up at `Enter`, the UI simply stays up: check `IsGameUIHidden()`.
Never call `StaticPopup_Show` for your own prompts:
use your own frames. `Lift` is for your own frames only.

The full API, the options and the guarantees are in `docs/DESIGN.md`.

## License

MIT.
