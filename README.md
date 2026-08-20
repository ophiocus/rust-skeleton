# rust-skeleton

Rust + egui desktop app starter for Windows. Drop-in scaffolding for every sibling app on this drive.

## What you get

- **eframe / egui** single-window app, dark-mode default, config persisted to `%APPDATA%\<AppName>\config.json`.
- **Git-tag versioning** — `build.rs` reads the latest `v*` tag and exposes it as `APP_VERSION`. Falls back to the Cargo version.
- **Self-update** — clicks the version label in the bottom bar, polls GitHub releases, compares 4-part semver, downloads the `.msi`, and launches `msiexec` elevated via PowerShell.
- **WiX MSI installer** — parameterised `wix/main.wxs` with `MajorUpgrade`, PATH component, and a Desktop shortcut.
- **Windows icon embed** via `winres`.

## Background work without stalling the UI

egui redraws on a single thread, so any blocking call (network, SSH, file IO)
made directly inside `App::update()` freezes the window until it returns. The
recommended pattern is to move the work off the UI thread and poll for its
result:

1. Spawn a `std::thread` to do the blocking work.
2. Hand the result back over a `std::sync::mpsc::channel`.
3. Store the `Receiver` on your `App`, and each frame call `try_recv()` (never
   `recv()`, which would block). While work is in flight, ask egui to keep
   painting with `ctx.request_repaint()` (or `request_repaint_after(dt)` to
   poll on an interval) so the UI stays responsive and picks the result up
   promptly.

```rust
// kick off:
let (tx, rx) = std::sync::mpsc::channel();
std::thread::spawn(move || {
    let result = do_blocking_work(); // network / SSH / file IO
    let _ = tx.send(result);
});
self.pending = Some(rx);

// each frame, in App::update():
if let Some(rx) = &self.pending {
    match rx.try_recv() {
        Ok(result) => { /* apply result */ self.pending = None; }
        Err(std::sync::mpsc::TryRecvError::Empty) => { ctx.request_repaint(); }
        Err(std::sync::mpsc::TryRecvError::Disconnected) => { self.pending = None; }
    }
}
```

The in-repo self-update check (`src/git_update.rs`) already uses this idiom —
read it for a complete, working example.

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
│   ├── new_app.ps1       # bootstrap a new sibling app (stays in the skeleton)
│   ├── bootstrap_dev.ps1 # detect/install/verify the dev toolchain (inherited)
│   └── build_msi.ps1     # one-command MSI build (inherited by every mint)
└── .github/workflows/
    └── release.yml     # CI: build + attach the .msi on every v* tag
```

## Dev setup on a bare box

A fresh Windows machine has **none** of the Rust half of this toolchain — no
rustup, no cargo, and typically no Visual Studio at all, which means no `link.exe`
for the `x86_64-pc-windows-msvc` target that both local builds and CI use. Don't
hand-install it; the protocol is a script, and it's idempotent, so running it just
to look costs nothing:

```powershell
# Report what's missing, change nothing:
powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap_dev.ps1

# Install what's needed to `cargo run`:
powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap_dev.ps1 -Install

# Also install the .msi packaging tier:
powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap_dev.ps1 -Install -IncludePackaging
```

| Tier | Gets you | Components |
| --- | --- | --- |
| **build** (default) | `cargo run` | rustup + Rust stable (MSVC) + MSVC C++ build tools |
| **package** (`-IncludePackaging`) | a shippable `.msi` | + WiX Toolset v3 + cargo-wix |

Notes worth keeping:

- **MSVC, not GNU.** CI builds `x86_64-pc-windows-msvc`; matching it locally is the
  point. The MSVC C++ build tools are the large item (~2–6 GB) — they supply the
  linker and Windows SDK that target requires.
- **winget only.** WiX is available from winget, so there's no reason to install
  Chocolatey just to obtain one package.
- **One UAC prompt.** Machine-wide installers run in a single elevated batch.
  Per-machine MSIs fail with **1925** when unelevated rather than prompting, so
  batching is deliberate, not cosmetic.
- **Never pass `--scope` blanket.** Not every package publishes a user-scope
  installer; forcing it on one that doesn't makes winget report *"No applicable
  installer found"* and install **nothing**, while other packages in the same run
  succeed — leaving a half-provisioned box that looks like a partial failure of
  something else. `Rustlang.Rustup` is exactly such a package. Scope is opt-in
  per requirement in the script for this reason.
- Installers only change `PATH` for *new* shells; the script refreshes it in-process
  and then verifies with `cargo check`, ending on an explicit READY / blocked-on-X.

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
