#Requires -Version 5.1
<#
.SYNOPSIS
  Build addons/godot_lib_manager as a GitHub-Ready zip (addons/… layout).

.DESCRIPTION
  • .\release.ps1
      Zip only; version read from plugin.cfg → dist\GodotLibManager_v….zip

  • .\release.ps1 1.0.0   OR   .\release.ps1 v1.0.0
      One-shot publish: writes plugin.cfg, builds zip, commits (if needed),
      tags v1.0.0, pushes branch + tag → GitHub Actions publishes the Release.

  • .\release.ps1 1.0.0 -ZipOnly
      Build zip for that version and bump plugin.cfg on disk, but no git push.

.PARAMETER ZipOnly
  Never run git (even when a version argument is given).

.EXAMPLE
  .\tools\release.ps1
  .\tools\release.ps1 v1.1.0
  .\tools\release.ps1 2.0.0 -ZipOnly
#>
param(
    [Parameter(Position = 0)]
    [string]$Version = "",
    [string]$OutDir = "dist",
    [switch]$ZipOnly
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

function Set-PluginCfgVersion {
    param(
        [string]$Path,
        [string]$Ver
    )
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $pattern = '(?m)^(\s*version\s*=\s*")[^"]*(")'
    if ($raw -notmatch $pattern) {
        throw "Could not find version=""..."" line in plugin.cfg"
    }
    $newRaw = [regex]::Replace($raw, $pattern, "`${1}$Ver`${2}", 1)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText((Resolve-Path $Path).Path, $newRaw, $utf8NoBom)
}

function Assert-GitWorkspaceCleanExcept {
    param(
        [string]$GitRoot,
        [string]$CfgRepoRelative
    )
    $lines = @(git -C $GitRoot status --porcelain)
    foreach ($l in $lines) {
        if ($l.Length -lt 4) { continue }
        $pathPart = $l.Substring(3).Trim()
        $first = ($pathPart -split "`t")[0].Trim()
        if ($first -ne $CfgRepoRelative -and $first -notlike "$CfgRepoRelative *") {
            throw "Working tree is not clean (commit or stash everything except plugin.cfg first):`n$($lines -join "`n")"
        }
    }
}

function Remove-GitTagIfExists {
    param(
        [string]$Root,
        [string]$TagName
    )
    git -C $Root rev-parse -q --verify "refs/tags/$TagName" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Removing local tag $TagName..."
        git -C $Root tag -d $TagName
        if ($LASTEXITCODE -ne 0) {
            throw "Could not delete local tag $TagName"
        }
    }

    $ref = "refs/tags/$TagName"
    $remoteLine = git -C $Root ls-remote origin $ref 2>$null
    if (-not [string]::IsNullOrWhiteSpace($remoteLine) -and $remoteLine -match '^\S+\s+refs/tags/') {
        Write-Host "Removing remote tag origin/$TagName..."
        git -C $Root push origin --delete $TagName
        if ($LASTEXITCODE -ne 0) {
            throw "Could not delete remote tag $TagName (permissions, protected tag, or delete the GitHub Release first)."
        }
    }
}

function Invoke-GitPublish {
    param(
        [string]$Root,
        [string]$Ver
    )
    Push-Location $Root
    try {
        git rev-parse --git-dir 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Not a git repository: $Root"
        }
        $remoteOk = git remote get-url origin 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remoteOk)) {
            throw "Git remote ""origin"" is not configured. Add it before publishing."
        }

        $tagName = "v$Ver"
        $cfgRel = "addons/godot_lib_manager/plugin.cfg"

        Remove-GitTagIfExists -Root $Root -TagName $tagName

        Assert-GitWorkspaceCleanExcept -GitRoot $Root -CfgRepoRelative $cfgRel

        git add -- $cfgRel
        git diff --cached --quiet
        if ($LASTEXITCODE -ne 0) {
            git commit -m "Release $tagName"
            if ($LASTEXITCODE -ne 0) { throw "git commit failed" }
        }

        git tag -a $tagName -m $tagName
        if ($LASTEXITCODE -ne 0) { throw "git tag failed" }

        $branch = git rev-parse --abbrev-ref HEAD
        if ($LASTEXITCODE -ne 0 -or $branch -eq "HEAD") {
            throw "Detached HEAD — checkout a branch (e.g. main) before publishing."
        }

        git push origin $branch
        if ($LASTEXITCODE -ne 0) { throw "git push origin $branch failed" }

        git push origin $tagName
        if ($LASTEXITCODE -ne 0) { throw "git push origin $tagName failed" }

        Write-Host ""
        Write-Host "Pushed $tagName — GitHub Actions will build the zip and attach it to the Release."
        Write-Host "Repo: $(git remote get-url origin)"
    }
    finally {
        Pop-Location
    }
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

$explicitVersion = $PSBoundParameters.ContainsKey("Version")
$publish = $explicitVersion -and (-not $ZipOnly)
if ($explicitVersion -and [string]::IsNullOrWhiteSpace($Version)) {
    throw "Version argument is empty."
}

if (-not $explicitVersion) {
    $Version = Read-PluginVersion $CfgPath
}
$Version = Normalize-VersionString $Version
if ([string]::IsNullOrWhiteSpace($Version)) {
    throw "No version: set plugin.cfg or run: .\tools\release.ps1 1.0.0"
}

if ($publish -or $ZipOnly) {
    Set-PluginCfgVersion -Path $CfgPath -Ver $Version
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

    if ($publish) {
        Invoke-GitPublish -Root $RepoRoot -Ver $Version
    }
    else {
        Write-Host "Upload this zip as a GitHub Release asset (or push tag v$Version to trigger CI)."
        Write-Host "Optional (GitHub CLI): gh release create v$Version $ZipPath --title ""Godot Lib Manager $Version"""
    }
}
finally {
    if (Test-Path -LiteralPath $Stage) {
        Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
