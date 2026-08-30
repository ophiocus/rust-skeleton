#Requires -Version 5.1
<#
.SYNOPSIS
    Bootstrap a new Rust/egui app from rust-skeleton.

.DESCRIPTION
    Copies rust-skeleton to -Target, rewrites identity tokens
    (Cargo package name, APP_NAME constants, WiX product metadata),
    and mints fresh GUIDs for the WiX installer. Result is a ready-to-build
    Rust project that inherits the updater + MSI installer.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\new_app.ps1 `
        -Name "My New App" `
        -Slug "mynewapp" `
        -Exe  "my-new-app" `
        -Description "Short one-line description of the app" `
        -GitHubRepo "ophiocus/MyNewApp" `
        -Target "I:\MyNewApp"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [string] $Slug,
    [Parameter(Mandatory)] [string] $Exe,
    [Parameter(Mandatory)] [string] $Description,
    [Parameter(Mandatory)] [string] $GitHubRepo,
    [Parameter(Mandatory)] [string] $Target,
    [string] $Manufacturer = "ophiocus",
    [switch] $Overwrite
)

$ErrorActionPreference = "Stop"

# rust-skeleton root = parent directory of this script.
$SkeletonRoot = Split-Path -Parent $PSScriptRoot
Write-Host "rust-skeleton root: $SkeletonRoot"
Write-Host "Target:             $Target"

# ---- validate target ----
if (Test-Path $Target) {
    $hasContents = @(Get-ChildItem -Force -LiteralPath $Target).Count -gt 0
    if ($hasContents -and -not $Overwrite) {
        throw "Target '$Target' exists and is not empty. Pass -Overwrite to proceed."
    }
} else {
    New-Item -ItemType Directory -Path $Target | Out-Null
}

# ---- copy files ----
# Copy everything except build artefacts and VCS. scripts/ DOES ride along so
# inherited apparatus (build_msi.ps1, future build scripts) propagates to mints;
# only the bootstrap script itself is stripped from the mint afterwards.
$exclude = @("target", ".git")
Get-ChildItem -LiteralPath $SkeletonRoot -Force | ForEach-Object {
    if ($exclude -contains $_.Name) { return }
    Copy-Item -LiteralPath $_.FullName -Destination $Target -Recurse -Force
}
# The minting script must not ride into the minted app.
Remove-Item -LiteralPath (Join-Path $Target "scripts\new_app.ps1") -Force -ErrorAction SilentlyContinue

# ---- compute substitutions ----
$upgradeGuid = [System.Guid]::NewGuid().ToString().ToUpperInvariant()
$pathGuid    = [System.Guid]::NewGuid().ToString().ToUpperInvariant()
$desktopGuid = [System.Guid]::NewGuid().ToString().ToUpperInvariant()
# Each shortcut component needs its own stable GUID. Sharing one would give two
# components a single identity, and Windows Installer would treat installing
# either as having installed both.
$startMenuGuid = [System.Guid]::NewGuid().ToString().ToUpperInvariant()
$githubUrl   = "https://github.com/$GitHubRepo"

Write-Host "App name:       $Name"
Write-Host "Slug:           $Slug"
Write-Host "Exe:            $Exe"
Write-Host "GitHub:         $GitHubRepo"
Write-Host "UpgradeGUID:    $upgradeGuid"

# ---- Cargo.toml rewrite ----
$cargoPath = Join-Path $Target "Cargo.toml"
$cargo = Get-Content -LiteralPath $cargoPath -Raw
$cargo = $cargo -replace 'name = "rust-skeleton"', ('name = "{0}"' -f $Exe)
$cargo = $cargo -replace 'description = "Rust \+ egui Windows app starter"', ('description = "{0}"' -f $Description)
$cargo = $cargo -replace '"00000000-0000-0000-0000-000000000001"', ('"{0}"' -f $upgradeGuid)
$cargo = $cargo -replace '"00000000-0000-0000-0000-000000000002"', ('"{0}"' -f $pathGuid)
Set-Content -LiteralPath $cargoPath -Value $cargo -NoNewline

# ---- src/main.rs rewrite (app identity constants) ----
$mainPath = Join-Path $Target "src\main.rs"
$main = Get-Content -LiteralPath $mainPath -Raw
$main = $main -replace 'pub const APP_NAME: &str = "rust-skeleton";',         ('pub const APP_NAME: &str = "{0}";' -f $Name)
$main = $main -replace 'pub const APP_WINDOW_TITLE: &str = "rust-skeleton";', ('pub const APP_WINDOW_TITLE: &str = "{0}";' -f $Name)
$main = $main -replace 'pub const APP_GH_REPO: &str = "ophiocus/rust-skeleton";', ('pub const APP_GH_REPO: &str = "{0}";' -f $GitHubRepo)
Set-Content -LiteralPath $mainPath -Value $main -NoNewline

# ---- src/app.rs rename of the app struct ----
# Keep the struct name short and camel-cased from the slug — no spaces.
$camel = ($Slug -split '[-_ ]' | ForEach-Object {
    if ($_.Length -gt 0) { $_.Substring(0,1).ToUpper() + $_.Substring(1) } else { $_ }
}) -join ''
$appStruct = "${camel}App"

$appRsPath = Join-Path $Target "src\app.rs"
(Get-Content -LiteralPath $appRsPath -Raw) `
    -replace 'RustSkeletonApp', $appStruct |
    Set-Content -LiteralPath $appRsPath -NoNewline

(Get-Content -LiteralPath $mainPath -Raw) `
    -replace 'RustSkeletonApp', $appStruct |
    Set-Content -LiteralPath $mainPath -NoNewline

# ---- wix/main.wxs rewrite ----
$wxsPath = Join-Path $Target "wix\main.wxs"
$wxs = Get-Content -LiteralPath $wxsPath -Raw
# The .wxs holds real values rather than __TOKEN__ placeholders, because
# __UPGRADE_GUID__ is not a legal GUID and candle.exe refuses to compile it -
# which meant the skeleton could never build its own MSI or cut its own
# release. Substituting concrete literals is the same approach Cargo.toml has
# always used here.
#
# Order matters: the exe reference is rewritten before the bare slug, or
# 'rust-skeleton.exe' would first become '<slug>.exe' and the exe name would
# be lost.
$wxs = $wxs -replace 'rust-skeleton\.exe', ('{0}.exe' -f $Exe)
$wxs = $wxs -replace "Id='APPLICATIONFOLDER' Name='rust-skeleton'", ("Id='APPLICATIONFOLDER' Name='{0}'" -f $Slug)
$wxs = $wxs -replace "Value='rust-skeleton Installation'", ("Value='{0} Installation'" -f $Slug)
$wxs = $wxs -replace 'Rust Skeleton',        [regex]::Escape($Name).Replace('\', '')
$wxs = $wxs -replace 'ophiocus',             $Manufacturer
$wxs = $wxs -replace 'Rust \+ egui Windows app starter', [regex]::Escape($Description).Replace('\', '')
$wxs = $wxs -replace 'https://github\.com/[^/]+/rust-skeleton', [regex]::Escape($githubUrl).Replace('\', '')
$wxs = $wxs -replace '00000000-0000-0000-0000-000000000001', $upgradeGuid
$wxs = $wxs -replace '00000000-0000-0000-0000-000000000002', $pathGuid
$wxs = $wxs -replace '00000000-0000-0000-0000-000000000003', $desktopGuid
$wxs = $wxs -replace '00000000-0000-0000-0000-000000000004', $startMenuGuid

# Drop the comment block that documents the placeholder scheme. It is guidance
# for maintaining the skeleton, it names the skeleton, and neither belongs in a
# minted app - which is also why it must go before the check below, or its own
# example values would trip the guard.
$wxs = [regex]::Replace($wxs, '(?s)\s*<!--\s*This file is a working installer.*?-->', '')

# A placeholder that survives substitution reaches candle.exe in the minted
# app, where the cause is far less obvious than it is here. An all-zero GUID
# in particular would silently give two apps the same UpgradeCode, so
# installing one would uninstall the other.
$leftover = @()
if ($wxs -match '__[A-Z_]+__')                        { $leftover += 'a __TOKEN__ placeholder' }
if ($wxs -match '00000000-0000-0000-0000-0000000000') { $leftover += 'an all-zero placeholder GUID' }
if ($wxs -match 'rust-skeleton')                      { $leftover += "the skeleton's own name" }
if ($leftover.Count -gt 0) {
    throw "wix/main.wxs still contains $($leftover -join ', ') after substitution."
}

Set-Content -LiteralPath $wxsPath -Value $wxs -NoNewline

# ---- README.md rewrite (replace skeleton README with a fresh stub) ----
$readmePath = Join-Path $Target "README.md"
if (Test-Path $readmePath) {
    $readme = "# $Name`r`n`r`n$Description`r`n`r`nBootstrapped from rust-skeleton.`r`n"
    Set-Content -LiteralPath $readmePath -Value $readme -NoNewline
}

Write-Host ""
Write-Host "Done. New app scaffolded at: $Target"
Write-Host "  cd '$Target'"
Write-Host "  cargo run"
