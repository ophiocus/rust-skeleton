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
└── scripts/
    └── new_app.ps1      # bootstrap a new sibling app
```

## Build

```powershell
cargo build --release
cargo wix --nocapture       # requires `cargo install cargo-wix`
```
