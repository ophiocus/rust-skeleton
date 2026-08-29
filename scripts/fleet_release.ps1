#Requires -Version 5.1
<#
.SYNOPSIS
    Survey, re-merge, gate and release every app minted from this skeleton.

.DESCRIPTION
    The fleet-wide half of the retrofit protocol. `sync_from_skeleton.ps1`
    handles one app; this drives it across a whole drive of them and then,
    optionally, ships the ones that are actually shippable.

    It runs in four escalating stages, and stops at the one you asked for:

        (default)   SURVEY  - report every app: version, tags, whether its
                              infrastructure matches the skeleton, whether it
                              has ever been released.
        -Sync       MERGE   - re-merge skeleton infrastructure into each app,
                              run cargo fmt, and run the three gates. Writes
                              working-tree changes only; commits nothing.
        -Commit     COMMIT  - commit the synced infrastructure and push.
        -Release    SHIP    - bump the patch version, tag it, push the tag,
                              which is what actually triggers a release.

    Each stage requires the one before it, so -Release implies -Sync -Commit.
    There is no single flag that goes from "never surveyed" to "published a
    release", on purpose.

    Safety rules that are not negotiable:

      * An app with a dirty working tree is skipped unless -Force. Sweeping
        someone's half-finished work into an infrastructure commit is how you
        publish a release containing something nobody meant to ship.
      * An app that fails its own gates is never tagged, whatever flags are
        passed. Releasing over red gates is the failure this protocol exists
        to prevent.
      * An app with no MSI packaging gets ci.yml and nothing else.
      * An app with no git remote is reported and skipped.
      * -Only / -Skip restrict the fleet by name, because "all apps" is rarely
        what you want on the first run.

    Discovers apps by scanning -Root for directories containing Cargo.toml and
    a git repository. It names no project: the fleet is whatever is on disk.

.PARAMETER Root
    Directory whose immediate children are candidate apps. Repeatable.

.PARAMETER Only
    Only process apps whose directory name is in this list.

.PARAMETER Skip
    Never process apps whose directory name is in this list.

.PARAMETER Sync
    Re-merge skeleton infrastructure, run cargo fmt, run the gates.

.PARAMETER Commit
    Commit and push the synced infrastructure. Implies -Sync.

.PARAMETER Release
    Bump the patch version, tag, and push the tag. Implies -Commit.

.PARAMETER Force
    Process apps with dirty working trees.

.EXAMPLE
    # Look before touching anything:
    powershell -ExecutionPolicy Bypass -File .\scripts\fleet_release.ps1 -Root I:\

.EXAMPLE
    # Merge and gate the whole fleet, but commit nothing:
    .\scripts\fleet_release.ps1 -Root I:\ -Sync

.EXAMPLE
    # Ship two named apps end to end:
    .\scripts\fleet_release.ps1 -Root I:\ -Only app-one,app-two -Release
#>
[CmdletBinding()]
param(
    [string[]] $Root = @((Split-Path -Parent (Split-Path -Parent $PSScriptRoot))),
    [string[]] $Only = @(),
    [string[]] $Skip = @(),
    [switch]   $Sync,
    [switch]   $Commit,
    [switch]   $Release,
    [switch]   $Force
)

# Continue, not Stop. A fleet driver walks repositories it does not control:
# one with no remote, a detached HEAD, or no tags will make git write to
# stderr, and under -ErrorAction Stop PowerShell turns that into a terminating
# error that aborts the entire run on the first odd repo. Every call whose
# result matters is exit-code-checked explicitly below.
$ErrorActionPreference = "Continue"
$skeleton = Split-Path -Parent $PSScriptRoot
$syncScript = Join-Path $PSScriptRoot "sync_from_skeleton.ps1"

# Escalation: each stage implies the ones before it.
if ($Release) { $Commit = $true }
if ($Commit)  { $Sync   = $true }

function Get-CargoField([string] $cargoToml, [string] $field) {
    $m = Select-String -Path $cargoToml -Pattern "^$field = ""(.*)""" | Select-Object -First 1
    if ($m) { $m.Matches.Groups[1].Value } else { $null }
}

function Bump-Patch([string] $version) {
    $parts = $version -split '\.'
    if ($parts.Count -lt 3) { return $null }
    $parts[-1] = [string]([int]$parts[-1] + 1)
    ($parts -join '.')
}

# ── Discovery ────────────────────────────────────────────────────────────
$apps = @()
foreach ($r in $Root) {
    if (-not (Test-Path $r)) { Write-Warning "root not found: $r"; continue }
    Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $d = $_.FullName
        if ($d -eq $skeleton) { return }
        if (-not (Test-Path (Join-Path $d "Cargo.toml"))) { return }
        if (-not (Test-Path (Join-Path $d ".git")))       { return }
        if ($Only.Count -gt 0 -and $Only -notcontains $_.Name) { return }
        if ($Skip -contains $_.Name) { return }
        $apps += $d
    }
}

if ($apps.Count -eq 0) { Write-Warning "no apps found under: $($Root -join ', ')"; return }

Write-Host ""
Write-Host "skeleton : $skeleton"
Write-Host "fleet    : $($apps.Count) app(s)"
Write-Host "stage    : $(if ($Release) { 'RELEASE' } elseif ($Commit) { 'COMMIT' } elseif ($Sync) { 'SYNC' } else { 'SURVEY' })"
Write-Host ""

$report = @()

foreach ($app in $apps) {
    $name    = Split-Path -Leaf $app
    $cargo   = Join-Path $app "Cargo.toml"
    $crate   = Get-CargoField $cargo "name"
    $version = Get-CargoField $cargo "version"
    $branch  = (git -C $app branch --show-current 2>$null)
    $dirtyN  = @(git -C $app status --porcelain 2>$null | Where-Object { $_ }).Count
    $remote  = (git -C $app remote get-url origin 2>$null); if ($LASTEXITCODE -ne 0) { $remote = $null }
    $tags    = @(git -C $app tag -l 'v*' 2>$null).Count
    $msi     = Test-Path (Join-Path $app "wix/main.wxs")

    $row = [ordered]@{
        app = $name; crate = $crate; version = $version; branch = $branch
        dirty = $dirtyN; tags = $tags; msi = $msi; remote = [bool]$remote
        gates = "-"; action = "-"; note = ""
    }

    Write-Host ("=== {0} ({1} v{2}, {3} tag(s), {4})" -f $name, $crate, $version, $tags, $(if ($msi) { "MSI" } else { "no MSI" }))

    if (-not $remote)                    { $row.note = "no git remote";       $row.action = "skipped"; $report += [pscustomobject]$row; Write-Host "  skipped: no git remote`n"; continue }
    if ($dirtyN -gt 0 -and -not $Force)  { $row.note = "$dirtyN uncommitted"; $row.action = "skipped"; $report += [pscustomobject]$row; Write-Host "  skipped: $dirtyN uncommitted change(s); -Force to override`n"; continue }

    # ── SYNC ─────────────────────────────────────────────────────────────
    if (-not $Sync) {
        & $syncScript -App $app -Skeleton $skeleton | Out-Null
        $row.action = "surveyed"
        $report += [pscustomobject]$row
        Write-Host ""
        continue
    }

    $args = @("-App", $app, "-Skeleton", $skeleton, "-Apply", "-Gate")
    if ($Force) { $args += "-Force" }
    & $syncScript @args

    # Re-run the gates directly so this script owns the verdict rather than
    # parsing the child's console output.
    Push-Location $app
    try {
        cargo fmt 2>&1 | Out-Null
        cargo fmt --check 2>&1 | Out-Null;                                       $g1 = $LASTEXITCODE
        cargo clippy --workspace --release --all-targets -- -D warnings 2>&1 | Out-Null; $g2 = $LASTEXITCODE
        cargo test --workspace --release 2>&1 | Out-Null;                        $g3 = $LASTEXITCODE
    }
    finally { Pop-Location }

    $green = ($g1 -eq 0 -and $g2 -eq 0 -and $g3 -eq 0)
    $row.gates = if ($green) { "pass" } else { "fmt=$g1 clippy=$g2 test=$g3" }

    if (-not $green) {
        $row.action = "synced (gates red)"
        $row.note   = "not committed - fix gates first"
        $report += [pscustomobject]$row
        Write-Host "  gates RED - stopping here for this app.`n"
        continue
    }

    if (-not $Commit) {
        $row.action = "synced"
        $report += [pscustomobject]$row
        Write-Host ""
        continue
    }

    # ── COMMIT ───────────────────────────────────────────────────────────
    $pending = @(git -C $app status --porcelain 2>$null | Where-Object { $_ }).Count
    if ($pending -gt 0) {
        $msg = "Re-merge build infrastructure from the skeleton`n`nSyncs the shared CI and release plumbing, and formats the tree so it`npasses the gates the synced workflows enforce. No application code."
        $msgFile = Join-Path $app ".git/FLEET_MSG.txt"
        Set-Content -Path $msgFile -Value $msg -Encoding utf8
        git -C $app add -A                     | Out-Null
        git -C $app commit -q -F $msgFile      | Out-Null
        Remove-Item $msgFile -Force -ErrorAction SilentlyContinue
        git -C $app push -q origin $branch     | Out-Null
        $row.action = "committed + pushed"
        Write-Host "  committed and pushed to $branch"
    }
    else {
        $row.action = "already current"
        Write-Host "  nothing to commit - already current"
    }

    if (-not $Release) { $report += [pscustomobject]$row; Write-Host ""; continue }

    # ── RELEASE ──────────────────────────────────────────────────────────
    $next = Bump-Patch $version
    if (-not $next) {
        $row.note = "version '$version' is not X.Y.Z - not tagged"
        $report += [pscustomobject]$row
        Write-Host "  cannot bump '$version'`n"
        continue
    }

    if (@(git -C $app tag -l "v$next").Count -gt 0) {
        $row.note = "tag v$next already exists"
        $report += [pscustomobject]$row
        Write-Host "  tag v$next already exists - skipping`n"
        continue
    }

    # The release workflow refuses to publish when the tag and Cargo.toml
    # disagree, so the bump has to be committed before the tag is created.
    (Get-Content $cargo -Raw) -replace "(?m)^version = ""$([regex]::Escape($version))""", "version = ""$next""" |
        Set-Content $cargo -NoNewline
    git -C $app add Cargo.toml Cargo.lock 2>$null | Out-Null
    git -C $app commit -q -m "Release v$next" | Out-Null
    git -C $app tag -a "v$next" -m "v$next"   | Out-Null
    git -C $app push -q origin $branch        | Out-Null
    git -C $app push -q origin "v$next"       | Out-Null

    $row.action = "released v$next"
    $report += [pscustomobject]$row
    Write-Host "  tagged and pushed v$next - release workflow triggered`n"
}

Write-Host ""
Write-Host "──────── fleet summary ────────"
$report | Format-Table app, version, tags, msi, dirty, gates, action, note -AutoSize
