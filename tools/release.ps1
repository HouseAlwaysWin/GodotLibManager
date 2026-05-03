#Requires -Version 5.1
<#
.SYNOPSIS
  Build a Godot-ready addon zip for GitHub Releases (paths: addons/godot_lib_manager/...).

.PARAMETER Version
  Override version string (default: read from addons/godot_lib_manager/plugin.cfg).

.PARAMETER OutDir
  Output folder relative to repo root (default: dist).

.EXAMPLE
  .\tools\release.ps1
  .\tools\release.ps1 1.0.0
  .\tools\release.ps1 v1.0.0
  .\tools\release.ps1 -Version 1.0.0
#>
param(
    [Parameter(Position = 0)]
    [string]$Version = "",
    [string]$OutDir = "dist"
)

$ErrorActionPreference = "Stop"

function Normalize-VersionString {
    param([string]$s)
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $s = $s.Trim()
    if ($s.Length -ge 1 -and ($s[0] -eq 'v' -or $s[0] -eq 'V')) {
        $s = $s.Substring(1).Trim()
    }
    return $s
}

function Read-PluginVersion {
    param([string]$CfgPath)
    foreach ($line in Get-Content -LiteralPath $CfgPath -Encoding UTF8) {
        $t = $line.Trim()
        if ($t -match '^\s*version\s*=\s*"([^"]*)"') {
            return $Matches[1]
        }
    }
    return ""
}

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$AddonSrc = Join-Path $RepoRoot "addons\godot_lib_manager"
$CfgPath = Join-Path $AddonSrc "plugin.cfg"

if (-not (Test-Path -LiteralPath $AddonSrc)) {
    throw "Addon folder not found: $AddonSrc"
}
if (-not (Test-Path -LiteralPath $CfgPath)) {
    throw "plugin.cfg not found: $CfgPath"
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = Read-PluginVersion $CfgPath
}
$Version = Normalize-VersionString $Version
if ([string]::IsNullOrWhiteSpace($Version)) {
    throw "No version: set it in plugin.cfg, or run: .\tools\release.ps1 1.0.0  (v1.0.0 is OK)"
}

$ZipName = "GodotLibManager_v$Version.zip"
$OutRoot = Join-Path $RepoRoot $OutDir
if (-not (Test-Path -LiteralPath $OutRoot)) {
    New-Item -ItemType Directory -Path $OutRoot | Out-Null
}
$ZipPath = Join-Path $OutRoot $ZipName

$Stage = Join-Path ([System.IO.Path]::GetTempPath()) ("gdlm_release_" + [Guid]::NewGuid().ToString("N"))
$StageAddon = Join-Path $Stage "addons\godot_lib_manager"

try {
    New-Item -ItemType Directory -Path $StageAddon -Force | Out-Null
    robocopy $AddonSrc $StageAddon /MIR /XD .git /NFL /NDL /NJH /NJS | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 8) {
        throw "robocopy failed with exit code $rc"
    }

    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }

    $addonsFolder = Join-Path $Stage "addons"
    Compress-Archive -LiteralPath $addonsFolder -DestinationPath $ZipPath -CompressionLevel Optimal -Force

    $len = (Get-Item -LiteralPath $ZipPath).Length
    Write-Host ""
    Write-Host "Created: $ZipPath"
    Write-Host ("Size: {0:N0} bytes" -f $len)
    Write-Host ""
    Write-Host "Upload this zip as a GitHub Release asset. It contains addons/godot_lib_manager/ so Lib Manager's installer can extract under res://addons/."
    Write-Host "Optional (GitHub CLI): gh release create v$Version $ZipPath --title ""Godot Lib Manager $Version"" --notes ""See README."""
}
finally {
    if (Test-Path -LiteralPath $Stage) {
        Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
