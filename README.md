# rust-skeleton

Rust + egui desktop app starter for Windows. Drop-in scaffolding for every sibling app on this drive.

## What you get

- **eframe / egui** single-window app, dark-mode default, config persisted to `%APPDATA%\<AppName>\config.json`.
- **Git-tag versioning** — `build.rs` reads the latest `v*` tag and exposes it as `APP_VERSION`. Falls back to the Cargo version.
- **Self-update** — clicks the version label in the bottom bar, polls GitHub releases, compares 4-part semver, downloads the `.msi`, and launches `msiexec` elevated via PowerShell.
- **WiX MSI installer** — parameterised `wix/main.wxs` with `MajorUpgrade`, PATH component, and a Desktop shortcut.
- **Windows icon embed** via `winres`.

## Bootstrap a new app from this skeleton

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\new_app.ps1 `
    -Name "MyNewApp" `
    -Slug "mynewapp" `
    -Exe  "my-new-app" `
    -Description "Short one-line description of the app" `
    -GitHubRepo "ophiocus/MyNewApp" `
    -Target "I:\MyNewApp"
```

The script copies the skeleton, rewrites every token (`__APP_NAME__`, `__APP_SLUG__`, …), mints fresh WiX GUIDs, and leaves a compilable Rust project ready to `cargo run`.

Pass `-Overwrite` to populate a non-empty target directory.

## Layout

```
rust-skeleton/
├── Cargo.toml           # eframe/egui/reqwest/serde/rfd/dirs
├── build.rs             # git-tag version + Windows icon/version embed
├── src/
│   ├── main.rs          # APP_NAME / APP_WINDOW_TITLE / APP_GH_REPO
│   ├── app.rs           # top bar, bottom bar (version + update), central panel
│   ├── config.rs        # JSON config at %APPDATA%
│   └── git_update.rs    # GitHub API + download + elevated msiexec
├── wix/
│   ├── main.wxs         # MSI template with __APP_*__ tokens
│   └── License.rtf
├── assets/
│   └── icon.ico         # replace with your own
├── scripts/
│   ├── new_app.ps1     # bootstrap a new sibling app (stays in the skeleton)
│   └── build_msi.ps1   # one-command MSI build (inherited by every mint)
└── .github/workflows/
    └── release.yml     # CI: build + attach the .msi on every v* tag
```

## Build

```powershell
cargo build --release        # the app exe
```

### MSI installer

The MSI build needs **two** tools — `cargo-wix` (a driver) **and the WiX Toolset
v3** (the actual compiler `cargo-wix` invokes). The Toolset is the easy thing to
forget: without it, `cargo wix` cannot produce an `.msi`.

```powershell
# one command — ensures cargo-wix, checks for WiX, release-builds the .msi:
powershell -ExecutionPolicy Bypass -File .\scripts\build_msi.ps1
# add -InstallWix to auto-install the WiX Toolset via Chocolatey
```

Install the WiX Toolset once (any of):

```powershell
choco install wixtoolset
winget install WiXToolset.WiXToolset
# or wix314.exe from https://github.com/wixtoolset/wix3/releases
```

On CI, `.github/workflows/release.yml` does all of this: every `v*` tag builds the
`.msi` and attaches it to the GitHub release — which is exactly what the app's
self-update downloads. Ship with `git tag v0.1.1 && git push --tags`.
