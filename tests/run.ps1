<#
    run.ps1 - Syntax-check the library and run every tests\test_*.lua under Lua 5.1,
    through WowTestKit's runner at the commit tests\kit.pin names (its README).

    WoW runs Lua 5.1, so the tests do too - not a newer Lua that may be first
    on PATH. LibShowcase has no TOC: the XML is the list of runtime files, so a
    new one can't go unchecked. The tests, their fixtures and the probe are
    checked too. test_probe.lua needs the ForeverProbe checkout beside this repo
    (..\ForeverProbe, or $env:FOREVERPROBE).

    Usage:
        pwsh tests/run.ps1
        pwsh tests/run.ps1 -Lua "C:\path\to\lua5.1.exe"
        pwsh tests/run.ps1 -KitDev        # the ..\WowTestKit working copy instead of the pin
#>

param(
    [string]$Lua = "C:\Program Files (x86)\Lua\5.1\lua.exe",
    [switch]$KitDev
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $PSScriptRoot "kit.ps1")
$kit = Get-WowTestKit -RepoRoot $RepoRoot -KitDev:$KitDev

$xml = (Get-Content (Join-Path $RepoRoot "LibShowcase-1.0.xml") -Raw) -replace '(?s)<!--.*?-->', ''   # listed in a comment is not loaded
$extra = @([regex]::Matches($xml, '<Script\s+file="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
$extra += @(Get-ChildItem (Join-Path $PSScriptRoot "*.lua") -Recurse | ForEach-Object { $_.FullName })
# The probe (never packaged) is checked too; test_probe.lua runs it on ForeverProbe.
$extra += @(Get-ChildItem (Join-Path $RepoRoot "Tools\LibShowcaseProbe\*.lua") | ForEach-Object { $_.FullName })
&(Join-Path $kit "scripts\run.ps1") -RepoRoot $RepoRoot -Extra $extra -Lua $Lua
exit $LASTEXITCODE
