#Requires -Version 5.1
<#
.SYNOPSIS
    Add a Start menu shortcut to an app's wix/main.wxs without touching its
    installer identity.

.DESCRIPTION
    wix/main.wxs is deliberately excluded from sync_from_skeleton.ps1, and must
    stay excluded: it carries the app's installer IDENTITY - UpgradeCode,
    component GUIDs, product name. Copying the skeleton's wxs over an app's
    would give every app the same UpgradeCode, and Windows Installer treats
    apps sharing an UpgradeCode as the same product: installing one would
    uninstall the others, and every existing install would lose its upgrade
    path. That is the failure mode this script exists to avoid while still
    letting a structural improvement reach the fleet.

    So instead of copying anything, this PATCHES: it reads the app's own
    DesktopShortcut component - which already carries the app's identity
    (display name, exe, description, icon, registry key) - and inserts a
    StartMenuShortcut component cloned from those values, with a freshly
    minted GUID, plus the ProgramMenuFolder directory and the ComponentRef.
    Nothing that existed in the file is modified; three insertions only.

    Why it matters: the skeleton's installer used to create only a Desktop
    shortcut and a PATH entry. Neither puts anything in the Start Menu
    Programs folder, so installed apps never appeared under Start > All apps
    and could not be pinned from there.

    Safety posture:
      * Idempotent - a wxs that already mentions ProgramMenuFolder is
        reported as current and left alone.
      * Shape-checked - a wxs without the skeleton's DesktopShortcut
        structure (older mints predate shortcuts entirely) is refused with
        NONSTANDARD, never guessed at. Those files need a deliberate
        modernization by a person, not a regex.
      * Identity-preserving - every value in the inserted component comes
        from the app's own file; only the GUID is new, and each app gets its
        own so no two apps ever share a component identity.
      * Validating - if candle.exe (WiX) is on PATH, the patched file is
        compiled with stub defines before being written back; a file that
        does not compile is not written.
      * Report-only by default; -Apply writes.

.PARAMETER App
    Path to the app to patch. Defaults to the current directory.

.PARAMETER Apply
    Write the patched file. Without it, report what would happen.

.EXAMPLE
    powershell -File I:\rust-skeleton\scripts\retrofit_wxs_startmenu.ps1 -App I:\SomeApp -Apply
#>
[CmdletBinding()]
param(
    [string] $App = (Get-Location).Path,
    [switch] $Apply
)

$ErrorActionPreference = "Stop"

$wxsPath = Join-Path $App "wix\main.wxs"
$name = Split-Path -Leaf $App
if (-not (Test-Path $wxsPath)) { Write-Host "$name : NO-WXS (nothing to patch)"; exit 0 }

$wxs = Get-Content -LiteralPath $wxsPath -Raw

# Idempotence: already has a Start menu presence in any form.
if ($wxs -match 'ProgramMenuFolder') {
    Write-Host "$name : current (ProgramMenuFolder already present)"
    exit 0
}

# Shape check. We clone the app's own DesktopShortcut; without one there is
# nothing safe to clone from and this file predates the shortcut generation.
$blockRx = "(?s)([ \t]*)<Component Id='DesktopShortcut'.*?</Component>"
$m = [regex]::Match($wxs, $blockRx)
if (-not $m.Success) {
    Write-Host "$name : NONSTANDARD (no DesktopShortcut component) - refusing to guess; modernize this wxs deliberately"
    exit 2
}
$desktopBlock = $m.Value
$indent = $m.Groups[1].Value

function Get-Attr([string] $block, [string] $attr) {
    $am = [regex]::Match($block, "$attr='([^']*)'")
    if (-not $am.Success) { throw "$name : DesktopShortcut block has no $attr= attribute - refusing to patch" }
    $am.Groups[1].Value
}

$appName  = Get-Attr $desktopBlock 'Name'         # first Name= is the Shortcut's
$desc     = Get-Attr $desktopBlock 'Description'
$target   = Get-Attr $desktopBlock 'Target'
$workdir  = Get-Attr $desktopBlock 'WorkingDirectory'
$icon     = Get-Attr $desktopBlock 'Icon'
$regKey   = Get-Attr $desktopBlock 'Key'

# Fresh GUID: shortcut components must never share identity across apps or
# with each other.
$guid = [System.Guid]::NewGuid().ToString().ToUpperInvariant()

$newComponent = @"
$indent<!--
$indent  The Start menu shortcut is what puts the app into Start > All apps,
$indent  where it can be pinned and where people look for installed software.
$indent  A Desktop shortcut and a PATH entry place nothing there.
$indent  (Retrofitted from rust-skeleton; identity values cloned from this
$indent  file's own DesktopShortcut, GUID minted fresh for this app.)
$indent-->
$indent<Component Id='StartMenuShortcut' Guid='$guid'>
$indent    <Shortcut Id='StartMenuShortcut'
$indent        Name='$appName'
$indent        Description='$desc'
$indent        Directory='ProgramMenuFolder'
$indent        Target='$target'
$indent        WorkingDirectory='$workdir'
$indent        Icon='$icon' />
$indent    <!-- ICE43: a non-advertised shortcut needs an HKCU keypath. -->
$indent    <RegistryValue Root='HKCU'
$indent        Key='$regKey'
$indent        Name='StartMenuShortcut'
$indent        Type='integer'
$indent        Value='1'
$indent        KeyPath='yes' />
$indent</Component>

"@

# Three insertions, all anchored on lines that the shape check guarantees.
$patched = $wxs

# 1. The component itself, immediately before DesktopShortcut's component.
$patched = $patched.Insert($m.Index, $newComponent)

# 2. The ProgramMenuFolder directory, before the DesktopFolder directory.
$dirM = [regex]::Match($patched, "([ \t]*)<Directory Id='DesktopFolder'")
if (-not $dirM.Success) { throw "$name : no DesktopFolder directory line - refusing to patch" }
$patched = $patched.Insert($dirM.Index, "$($dirM.Groups[1].Value)<Directory Id='ProgramMenuFolder' Name='Programs' />`r`n")

# 3. The feature reference, before DesktopShortcut's.
$refM = [regex]::Match($patched, "([ \t]*)<ComponentRef Id='DesktopShortcut'/>")
if (-not $refM.Success) { throw "$name : no DesktopShortcut ComponentRef - refusing to patch" }
$patched = $patched.Insert($refM.Index, "$($refM.Groups[1].Value)<ComponentRef Id='StartMenuShortcut'/>`r`n")

if (-not $Apply) {
    Write-Host "$name : WOULD PATCH (Start menu shortcut for '$appName', target $target)"
    exit 0
}

# Validate with candle before writing, when WiX is available. Stub defines
# stand in for what cargo-wix passes; candle resolves File/@Source at link
# time, so the stubs are enough for a structural compile.
$candle = Get-Command candle.exe -ErrorAction SilentlyContinue
if ($candle) {
    $tmpWxs = Join-Path $env:TEMP "retrofit_$([System.Guid]::NewGuid().ToString('N')).wxs"
    $tmpObj = "$tmpWxs.wixobj"
    Set-Content -LiteralPath $tmpWxs -Value $patched -NoNewline
    # Each define quoted as a single token: unquoted, PowerShell's native
    # argument passing splits '-dVersion=0.0.1' and candle reads '.0.1' as a
    # source file (CNDL0103).
    & $candle.Source -nologo -arch x64 '-dVersion=0.0.1' '-dCargoTargetBinDir=.' '-dPlatform=x64' -out $tmpObj $tmpWxs 2>&1 | Out-Null
    $ok = ($LASTEXITCODE -eq 0)
    Remove-Item $tmpWxs, $tmpObj -Force -ErrorAction SilentlyContinue
    if (-not $ok) { throw "$name : patched wxs does not compile under candle - NOT written" }
    $validated = "candle-validated"
}
else {
    $validated = "candle not on PATH - written unvalidated"
}

Set-Content -LiteralPath $wxsPath -Value $patched -NoNewline
Write-Host "$name : PATCHED ($validated, GUID $guid)"
exit 0
