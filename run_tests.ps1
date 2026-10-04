#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Run TerraLua headless smoke suites (full regression or one suite).

.EXAMPLE
  .\run_tests.ps1
  .\run_tests.ps1 -Suite dialogue_smoke
  .\run_tests.ps1 -List
  $env:GODOT_BIN = "C:\Path\To\Godot_v4.7-stable_win64.exe"; .\run_tests.ps1
  .\run_tests.ps1 -GodotBin "C:\Path\To\Godot_v4.7-stable_win64.exe"
#>
[CmdletBinding()]
param(
    [string]$Suite = "",
    [string]$GodotBin = "",
    [switch]$List
)

$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot
Set-Location $ProjectRoot

$Suites = [ordered]@{
    "autoload_init_smoke"      = "res://scripts/test/autoload_init_smoke.gd"
    "vehicle_smoke"            = "res://scripts/test/vehicle_smoke.gd"
    "journey_world_smoke"      = "res://scripts/test/journey_world_smoke.gd"
    "save_smoke"               = "res://scripts/test/save_smoke.gd"
    "inventory_crafting_smoke" = "res://scripts/test/inventory_crafting_smoke.gd"
    "dialogue_smoke"           = "res://scripts/test/dialogue_smoke.gd"
    "npc_smoke"                = "res://scripts/test/npc_smoke.gd"
    "poi_worldstate_smoke"     = "res://scripts/test/poi_worldstate_smoke.gd"
    "vertical_slice_smoke"     = "res://scripts/test/vertical_slice_smoke.gd"
}
$FullRegression = "res://scripts/test/drive_smoke.gd"

function Show-SuiteList {
    Write-Host "Available suites (also: omit -Suite for full regression via drive_smoke):"
    foreach ($name in $Suites.Keys) {
        Write-Host ("  {0,-28} {1}" -f $name, $Suites[$name])
    }
}

if ($List) {
    Show-SuiteList
    exit 0
}

function Resolve-Godot {
    param([string]$Explicit)
    if ($Explicit -and $Explicit.Trim().Length -gt 0) {
        if (-not (Test-Path -LiteralPath $Explicit)) {
            Write-Error "Godot executable not found at -GodotBin path: $Explicit"
            exit 1
        }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }
    if ($env:GODOT_BIN -and $env:GODOT_BIN.Trim().Length -gt 0) {
        if (-not (Test-Path -LiteralPath $env:GODOT_BIN)) {
            Write-Error "GODOT_BIN is set but file not found: $($env:GODOT_BIN)"
            exit 1
        }
        return (Resolve-Path -LiteralPath $env:GODOT_BIN).Path
    }
    $cmd = Get-Command godot -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        return $cmd.Source
    }
    Write-Host @"
ERROR: Godot executable not found.

Install Godot 4.7+ and either:
  1) Add `godot` to PATH, or
  2) Set `$env:GODOT_BIN` to the Godot .exe, or
  3) Pass -GodotBin `"C:\Path\To\Godot_v4.7-stable_win64.exe`"

See docs/testing.md
"@ -ForegroundColor Red
    exit 1
}

$godot = Resolve-Godot -Explicit $GodotBin

$scriptPath = $FullRegression
$label = "full regression (drive_smoke)"
if ($Suite -and $Suite.Trim().Length -gt 0) {
    $key = $Suite.Trim()
    if ($key.EndsWith(".gd")) {
        $key = [System.IO.Path]::GetFileNameWithoutExtension($key)
    }
    if ($key.StartsWith("res://")) {
        $scriptPath = $key
        $label = $key
    }
    elseif ($Suites.Contains($key)) {
        $scriptPath = $Suites[$key]
        $label = $key
    }
    else {
        Write-Host "ERROR: Unknown suite '$Suite'." -ForegroundColor Red
        Show-SuiteList
        exit 1
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot "project.godot"))) {
    Write-Error "project.godot not found in $ProjectRoot — run from the repo root."
    exit 1
}

Write-Host "run_tests: godot=$godot"
Write-Host "run_tests: project=$ProjectRoot"
Write-Host "run_tests: running $label"
Write-Host "run_tests: $godot --path . --headless -s $scriptPath"

& $godot --path $ProjectRoot --headless -s $scriptPath
$code = $LASTEXITCODE
if ($null -eq $code) { $code = 0 }
if ($code -ne 0) {
    Write-Host "run_tests: FAILED (exit=$code)" -ForegroundColor Red
    exit $code
}
Write-Host "run_tests: OK"
exit 0
