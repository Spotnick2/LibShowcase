<#
    deploy-probe.ps1 - Deploy LibShowcaseProbe, a ForeverProbe module (/fp ls),
    for the in-game measurements (docs/DESIGN.md, "Open measurements").

    In order, each step stopping the rest if it refuses:
      1. ForeverProbe, the host (..\ForeverProbe, or $env:FOREVERPROBE), with its own deploy;
      2. this LibShowcase checkout into AddOns\LibShowcaseProbe\Libs\LibShowcase-1.0 (Tools\deploy.ps1);
      3. the module's TOC and Lua. A file the module no longer ships (the old
         Probe.lua) is removed from the addon's folder.

    In game, /reload loads it, a brand-new addon folder included
    (PORTING-TBC-TO-FOREVER.md, section 5).

        pwsh Tools/deploy-probe.ps1
        pwsh Tools/deploy-probe.ps1 -AddOnsPath "D:\...\_forever_\Interface\AddOns"
#>

param(
    [string]$AddOnsPath = "C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns",
    [string]$Lua = "C:\Program Files (x86)\Lua\5.1\lua.exe"
)

$ErrorActionPreference = "Stop"
$src = Join-Path $PSScriptRoot "LibShowcaseProbe"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$ForeverProbe = if ($env:FOREVERPROBE) { $env:FOREVERPROBE } else { Join-Path (Split-Path -Parent $RepoRoot) "ForeverProbe" }
$Files = @("LibShowcaseProbe.toc", "LibShowcaseProbe.lua")

foreach ($f in $Files) {
    if (-not (Test-Path -LiteralPath (Join-Path $src $f))) { Write-Error "Missing probe file: $f"; exit 1 }
}
$luac = Join-Path (Split-Path -Parent $Lua) "luac.exe"
if (Test-Path -LiteralPath $luac) {
    & $luac -p (Join-Path $src "LibShowcaseProbe.lua")
    if ($LASTEXITCODE -ne 0) { Write-Error "luac -p failed on the probe's Lua"; exit 1 }
    Remove-Item -LiteralPath "luac.out" -ErrorAction SilentlyContinue
} else {
    Write-Host "  luac -p SKIPPED (no $luac)" -ForegroundColor Yellow
}
if (-not (Test-Path -LiteralPath $AddOnsPath)) { Write-Error "AddOns path not found: $AddOnsPath"; exit 1 }
$AddOnsPath = (Resolve-Path -LiteralPath $AddOnsPath).ProviderPath

# 1. The host.
$hostDeploy = Join-Path $ForeverProbe "Tools\deploy.ps1"
if (-not (Test-Path -LiteralPath $hostDeploy)) {
    Write-Error "ForeverProbe checkout not found at $ForeverProbe (or set `$env:FOREVERPROBE)"; exit 1
}
& pwsh -NoProfile -File $hostDeploy -AddOnsPath $AddOnsPath
if ($LASTEXITCODE -ne 0) { Write-Error "ForeverProbe deploy refused; LibShowcaseProbe was not touched"; exit 1 }

# 2. The library, from this checkout (a child process: its exit codes stay its own).
& pwsh -NoProfile -File (Join-Path $PSScriptRoot "deploy.ps1") -Addon "LibShowcaseProbe" -AddOnsPath $AddOnsPath -Lua $Lua
if ($LASTEXITCODE -ne 0) { Write-Error "LibShowcase deploy refused; LibShowcaseProbe was not copied"; exit 1 }

# 3. The module.
$dest = Join-Path $AddOnsPath "LibShowcaseProbe"
foreach ($f in $Files) { Copy-Item -LiteralPath (Join-Path $src $f) -Destination (Join-Path $dest $f) -Force }
Get-ChildItem -LiteralPath $dest -File | Where-Object { $Files -notcontains $_.Name } | ForEach-Object {
    Write-Host "  removing stale $($_.Name)" -ForegroundColor DarkYellow
    Remove-Item -LiteralPath $_.FullName -Force
}
Write-Host "LibShowcaseProbe deployed to $dest. In game: /reload, then /fp steps (the procedures) or /fp ls (the commands)." -ForegroundColor Green
