<#
    deploy-probe.ps1 - Install the measurement probe (docs/DESIGN.md, "Open
    measurements") as the addon LibShowcaseProbe, with this checkout embedded in
    its Libs\. A brand-new addon folder needs a client restart the first time,
    /reload after that.

        pwsh Tools/deploy-probe.ps1
        pwsh Tools/deploy-probe.ps1 -AddOnsPath "D:\...\_classic_beta_\Interface\AddOns"
#>

param(
    [string]$AddOnsPath = "C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns"
)

$ErrorActionPreference = "Stop"
$src = Join-Path $PSScriptRoot "LibShowcaseProbe"
if (-not (Test-Path -LiteralPath $AddOnsPath)) { Write-Error "AddOns path not found: $AddOnsPath"; exit 1 }
$AddOnsPath = (Resolve-Path -LiteralPath $AddOnsPath).ProviderPath
$dest = Join-Path $AddOnsPath "LibShowcaseProbe"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
foreach ($f in @("LibShowcaseProbe.toc", "Probe.lua")) {
    Copy-Item -LiteralPath (Join-Path $src $f) -Destination (Join-Path $dest $f) -Force
}
& (Join-Path $PSScriptRoot "deploy.ps1") -Addon "LibShowcaseProbe" -AddOnsPath $AddOnsPath
if ($LASTEXITCODE -ne 0) { Write-Error "library deploy refused"; exit 1 }
Write-Host "Probe installed in $dest. In game: /lsprobe" -ForegroundColor Green
