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
$wxs = $wxs -replace '__APP_NAME__',         [regex]::Escape($Name).Replace('\', '')
$wxs = $wxs -replace '__APP_SLUG__',         $Slug
$wxs = $wxs -replace '__APP_EXE__',          $Exe
$wxs = $wxs -replace '__APP_MANUFACTURER__', $Manufacturer
$wxs = $wxs -replace '__APP_DESCRIPTION__',  [regex]::Escape($Description).Replace('\', '')
$wxs = $wxs -replace '__APP_GH_URL__',       [regex]::Escape($githubUrl).Replace('\', '')
$wxs = $wxs -replace '__UPGRADE_GUID__',     $upgradeGuid
$wxs = $wxs -replace '__PATH_GUID__',        $pathGuid
$wxs = $wxs -replace '__DESKTOP_GUID__',     $desktopGuid
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
