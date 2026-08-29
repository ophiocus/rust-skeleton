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

    Run it where your git remotes actually resolve. If a remote uses an SSH
    host alias (git@some-alias:owner/repo.git) defined in an ssh config that
    this shell does not read - a WSL-only ~/.ssh/config being the usual case -
    the commit will succeed and the push will fail. Every push here is
    exit-code checked and then re-verified against `git status -sb`, so that
    shows up as "PUSH FAILED" rather than as a green report over unpushed
    work, but the fix is to run from the environment that can reach the
    remote.

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
    # Dirtiness that matters is dirtiness the protocol did not cause. An
    # earlier -Sync run leaves synced workflows and cargo fmt output behind;
    # counting those as "someone's uncommitted work" means the stages refuse
    # to compose, and a -Sync run can never be followed by a -Commit run.
    # --untracked-files=all matters: with the default, git collapses a wholly
    # untracked directory to a single `?? .github/` line, so a newly created
    # workflow directory does not match the owned-paths pattern below and the
    # app looks like it has unfinished work in it.
    $allDirty = @(git -C $app status --porcelain --untracked-files=all 2>$null | Where-Object { $_ })
    $ownedRx  = '(\.github/workflows/(ci|release)\.yml|scripts/(build_msi|bootstrap_dev)\.ps1)'
    $dirtyN   = @($allDirty | Where-Object { $_ -notmatch $ownedRx }).Count
    $remote  = (git -C $app remote get-url origin 2>$null); if ($LASTEXITCODE -ne 0) { $remote = $null }
    $tags    = @(git -C $app tag -l 'v*' 2>$null).Count
    $msi     = Test-Path (Join-Path $app "wix/main.wxs")
    $foldIn  = $false

    $row = [ordered]@{
        app = $name; crate = $crate; version = $version; branch = $branch
        dirty = $dirtyN; tags = $tags; msi = $msi; remote = [bool]$remote
        gates = "-"; action = "-"; note = ""
    }

    Write-Host ("=== {0} ({1} v{2}, {3} tag(s), {4})" -f $name, $crate, $version, $tags, $(if ($msi) { "MSI" } else { "no MSI" }))

    if (-not $remote)                    { $row.note = "no git remote";       $row.action = "skipped"; $report += [pscustomobject]$row; Write-Host "  skipped: no git remote`n"; continue }
    if ($dirtyN -gt 0 -and -not $Force) {
        # One exception. If the tree is already fmt-clean and every remaining
        # change is a .rs file, the diff is this protocol's own earlier
        # `cargo fmt` rather than unfinished work, and it is safe to fold in.
        Push-Location $app
        try { cargo fmt --check 2>&1 | Out-Null; $fmtClean = ($LASTEXITCODE -eq 0) } finally { Pop-Location }
        $nonRust = @($allDirty | Where-Object { $_ -notmatch $ownedRx -and $_ -notmatch '\.rs$' })
        if (-not ($fmtClean -and $nonRust.Count -eq 0)) {
            $row.note = "$dirtyN uncommitted"; $row.action = "skipped"; $report += [pscustomobject]$row
            Write-Host "  skipped: $dirtyN uncommitted change(s); -Force to override`n"; continue
        }
        Write-Host "  note: $dirtyN changed file(s) are formatting from an earlier run - folding in"
        # The child runs the same dirty check independently and would refuse
        # on its own. Once the parent has judged the diff to be ours, it has
        # to say so, or the sync silently degrades to a report.
        $foldIn = $true
    }

    # ── SYNC ─────────────────────────────────────────────────────────────
    if (-not $Sync) {
        & $syncScript -App $app -Skeleton $skeleton | Out-Null
        $row.action = "surveyed"
        $report += [pscustomobject]$row
        Write-Host ""
        continue
    }

    # NOT $args: that is a PowerShell automatic variable holding this script's
    # own arguments. Assigning to it does not error, and splatting @args then
    # passes the wrong array - the child runs without -Apply and silently
    # syncs nothing while still reporting success.
    # Always -Force the child. Its own dirty-tree guard exists for someone
    # running it by hand against one app; by this point the parent has already
    # made that decision for the whole fleet, and letting the child re-derive
    # it means a sync can silently degrade to a report while still being
    # counted as applied.
    $syncArgs = @{ App = $app; Skeleton = $skeleton; Apply = $true; Force = $true }
    & $syncScript @syncArgs

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
        git -C $app add -A                | Out-Null
        git -C $app commit -q -F $msgFile | Out-Null
        $commitCode = $LASTEXITCODE
        Remove-Item $msgFile -Force -ErrorAction SilentlyContinue
        if ($commitCode -ne 0) {
            $row.action = "commit FAILED"; $row.note = "git commit exit $commitCode"
            $report += [pscustomobject]$row
            Write-Host "  commit FAILED (exit $commitCode)`n"; continue
        }

        # Check the push. Never report "pushed" on the strength of having run
        # the command: a remote using an SSH host alias defined only inside
        # WSL cannot be resolved by git running under Windows, and the push
        # fails while the commit succeeds. Claiming success there leaves the
        # work sitting unpushed behind a green-looking report.
        $pushOut = git -C $app push origin $branch 2>&1
        if ($LASTEXITCODE -ne 0) {
            $row.action = "committed, PUSH FAILED"
            $row.note   = "push failed - commit is local only"
            $report += [pscustomobject]$row
            Write-Host "  committed, but PUSH FAILED:"
            $pushOut | Select-Object -First 4 | ForEach-Object { Write-Host "    $_" }
            Write-Host "  (an SSH host alias defined only in WSL will not resolve from Windows)`n"
            continue
        }

        # Trust the remote, not the command. `git status -sb` still reporting
        # "ahead" means the push did not actually land.
        $ahead = (git -C $app status -sb 2>$null | Select-Object -First 1) -match 'ahead'
        if ($ahead) {
            $row.action = "committed, PUSH DID NOT LAND"
            $row.note   = "still ahead of origin/$branch"
            $report += [pscustomobject]$row
            Write-Host "  push reported success but the branch is still ahead of origin/$branch`n"
            continue
        }

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

    # Push the branch first, and only tag-push if it landed. A tag whose
    # commit is not on the remote produces a release built from something
    # nobody else can see.
    git -C $app push origin $branch 2>&1 | Out-Null
    $branchOk = ($LASTEXITCODE -eq 0) -and
                -not ((git -C $app status -sb 2>$null | Select-Object -First 1) -match 'ahead')
    if (-not $branchOk) {
        $row.action = "bumped, PUSH FAILED"
        $row.note   = "v$next tagged locally only - branch never reached origin"
        $report += [pscustomobject]$row
        Write-Host "  branch push failed - NOT pushing tag v$next`n"
        continue
    }

    git -C $app push origin "v$next" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $row.action = "pushed, TAG PUSH FAILED"
        $row.note   = "v$next exists locally; no release triggered"
        $report += [pscustomobject]$row
        Write-Host "  tag push failed - no release triggered`n"
        continue
    }

    $row.action = "released v$next"
    $report += [pscustomobject]$row
    Write-Host "  tagged and pushed v$next - release workflow triggered`n"
}

Write-Host ""
Write-Host "──────── fleet summary ────────"
$report | Format-Table app, version, tags, msi, dirty, gates, action, note -AutoSize
