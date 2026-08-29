#Requires -Version 5.1
<#
.SYNOPSIS
    Re-merge this skeleton's shared infrastructure into an app minted from it.

.DESCRIPTION
    An app minted from the skeleton is a *copy*, not a link, so an improvement
    made here after the mint never reaches it. Apps quietly keep whatever the
    skeleton looked like on their birthday — which is how a fleet ends up with
    several generations of build infrastructure and nobody knowing which apps
    are on which.

    This script is the other half of the retrofit protocol. The protocol says
    lessons flow *up* into the skeleton; this makes them flow back *down* into
    every app that was minted before the lesson existed.

    It syncs infrastructure only — build and release plumbing that is identical
    across every app by design:

        .github/workflows/ci.yml
        .github/workflows/release.yml
        scripts/build_msi.ps1
        scripts/bootstrap_dev.ps1

    It NEVER touches src/, Cargo.toml, wix/main.wxs, README, CHANGELOG or
    assets. Those are the app, not the scaffolding, and an app that has
    diverged there has diverged on purpose.

    release.yml is only synced into apps that actually package an MSI (they
    have wix/main.wxs). An app without one gets ci.yml alone — gates are
    universal, MSI packaging is not.

    Reports by default and changes nothing. Pass -Apply to write.

.PARAMETER App
    Path to the app to sync. Defaults to the current directory.

.PARAMETER Skeleton
    Path to the skeleton. Defaults to the repo this script lives in.

.PARAMETER Apply
    Actually write the files. Without it, this is a read-only report.

.PARAMETER Gate
    After syncing, run cargo fmt (writing), then the three gates, and report
    whether the app would survive its own new CI.

.PARAMETER Force
    Sync even when the app's working tree is dirty. Off by default: overwriting
    infrastructure underneath uncommitted work makes the diff unreadable.

.EXAMPLE
    # See what would change, from inside an app:
    powershell -ExecutionPolicy Bypass -File ..\rust-skeleton\scripts\sync_from_skeleton.ps1

.EXAMPLE
    # Apply it and check the app still passes its own gates:
    powershell -ExecutionPolicy Bypass -File ..\rust-skeleton\scripts\sync_from_skeleton.ps1 -Apply -Gate
#>
[CmdletBinding()]
param(
    [string] $App = (Get-Location).Path,
    [string] $Skeleton = (Split-Path -Parent $PSScriptRoot),
    [switch] $Apply,
    [switch] $Gate,
    [switch] $Force
)

$ErrorActionPreference = "Stop"

# Infrastructure the skeleton owns. Anything not on this list belongs to the
# app, and this script has no business touching it.
$SYNC = @(
    @{ Path = ".github/workflows/ci.yml";      Always = $true  }
    @{ Path = ".github/workflows/release.yml"; Always = $false } # MSI apps only
    @{ Path = "scripts/build_msi.ps1";         Always = $false }
    @{ Path = "scripts/bootstrap_dev.ps1";     Always = $true  }
)

function Resolve-Dir([string] $p, [string] $what) {
    if (-not (Test-Path -LiteralPath $p)) { throw "$what not found: $p" }
    (Resolve-Path -LiteralPath $p).Path
}

$App      = Resolve-Dir $App "App"
$Skeleton = Resolve-Dir $Skeleton "Skeleton"

if ($App -eq $Skeleton) { throw "App and Skeleton are the same directory - nothing to sync." }
if (-not (Test-Path (Join-Path $App "Cargo.toml"))) { throw "Not a Rust project (no Cargo.toml): $App" }

$name = (Select-String -Path (Join-Path $App "Cargo.toml") -Pattern '^name = "(.*)"' |
         Select-Object -First 1).Matches.Groups[1].Value
$packagesMsi = Test-Path (Join-Path $App "wix/main.wxs")

Write-Host ""
Write-Host "app       : $name  ($App)"
Write-Host "skeleton  : $Skeleton"
Write-Host "packages  : $(if ($packagesMsi) { 'MSI (wix/main.wxs present)' } else { 'no MSI - ci.yml only' })"
Write-Host "mode      : $(if ($Apply) { 'APPLY' } else { 'report only' })"
Write-Host ""

# A dirty tree makes the resulting diff impossible to read, and makes an
# accidental `git add -A` sweep up unrelated work.
# Localised to Continue: git writing to stderr in an unusual repo is
# information, not a reason to abort the sync.
$dirty = @()
if (Test-Path (Join-Path $App ".git")) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { $dirty = @(git -C $App status --porcelain 2>$null | Where-Object { $_ }) }
    catch { $dirty = @() }
    finally { $ErrorActionPreference = $prev }
}
if ($dirty.Count -gt 0 -and -not $Force) {
    Write-Warning "$name has $($dirty.Count) uncommitted change(s). Reporting only; pass -Force to sync anyway."
    $dirty | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" }
    $Apply = $false
}

$changed = @()
$missing = @()
$same    = @()

foreach ($item in $SYNC) {
    $rel = $item.Path
    if (-not $item.Always -and $rel -eq ".github/workflows/release.yml" -and -not $packagesMsi) { continue }
    if (-not $item.Always -and $rel -eq "scripts/build_msi.ps1" -and -not $packagesMsi) { continue }

    $src = Join-Path $Skeleton $rel
    $dst = Join-Path $App $rel
    if (-not (Test-Path $src)) { continue }

    $srcHash = (Get-FileHash $src -Algorithm SHA256).Hash
    if (Test-Path $dst) {
        $dstHash = (Get-FileHash $dst -Algorithm SHA256).Hash
        if ($srcHash -eq $dstHash) { $same += $rel; continue }
        $changed += $rel
        $state = "DIFFERS"
    }
    else {
        $missing += $rel
        $state = "MISSING"
    }

    Write-Host ("  {0,-8} {1}" -f $state, $rel)

    if ($Apply) {
        $dstDir = Split-Path -Parent $dst
        if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
}

foreach ($rel in $same) { Write-Host ("  {0,-8} {1}" -f "current", $rel) }

Write-Host ""
Write-Host ("summary: {0} differ, {1} missing, {2} already current" -f $changed.Count, $missing.Count, $same.Count)
if (-not $Apply -and ($changed.Count + $missing.Count) -gt 0) {
    Write-Host "re-run with -Apply to write them."
}

if ($Gate) {
    Write-Host ""
    Write-Host "running gates in $name ..."
    Push-Location $App
    try {
        # fmt is run in writing mode first: an app that has never been
        # formatted would otherwise fail its own new gate on the first push,
        # and that failure is noise, not a finding.
        cargo fmt 2>&1 | Out-Null
        $results = [ordered]@{}
        cargo fmt --check          2>&1 | Out-Null; $results["fmt"]    = $LASTEXITCODE
        cargo clippy --workspace --release --all-targets -- -D warnings 2>&1 | Out-Null; $results["clippy"] = $LASTEXITCODE
        cargo test --workspace --release 2>&1 | Out-Null; $results["test"]   = $LASTEXITCODE
        foreach ($k in $results.Keys) {
            Write-Host ("  {0,-8} {1}" -f $k, $(if ($results[$k] -eq 0) { "pass" } else { "FAIL ($($results[$k]))" }))
        }
        if ($results.Values -contains 0 -and -not ($results.Values | Where-Object { $_ -ne 0 })) {
            Write-Host "  -> would survive its own CI."
        }
        else {
            Write-Host "  -> would FAIL its own CI. Fix before tagging."
        }
    }
    finally { Pop-Location }
}
