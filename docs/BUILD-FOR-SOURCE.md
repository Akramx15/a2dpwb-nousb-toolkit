# Building A2DP-Windows-Bridge v2.0.1 from source on this PC

This machine can run the **toolkit scripts** (PowerShell 5.1) without any of
the steps below. Do these only if you must build the Rust binaries yourself.
The happy path uses the installed v2.0.1 binaries (`%LOCALAPPDATA%\A2DP
Windows Bridge`).

Verified starting state (2026-10-19):

| Tool | State |
|:--|:--|
| Rust | 1.97 (`cargo`, `rustup` on PATH) |
| Node.js | 24.19.0 (`corepack 0.35.0` present; `pnpm` absent) |
| Git | 2.55.0.windows.3 |
| Visual Studio Build Tools | `C:\BuildTools`, **without** the C++ workload: `vswhere -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64` returns nothing and `cl.exe` is absent |
| PowerShell 7 (`pwsh`) | absent (only Windows PowerShell 5.1) |

## 1. Install the MSVC C++ workload into `C:\BuildTools`

Detect first (returns nothing today):

```powershell
& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" `
    -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
```

Download the Build Tools bootstrapper and add the workload. `--installPath
C:\BuildTools` keeps the existing installation; `--includeRecommended`
brings the MSVC toolset, the Windows SDK and CMake with it.

```powershell
$vs = Join-Path $env:TEMP 'vs_BuildTools.exe'
Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_BuildTools.exe' -OutFile $vs
Start-Process -FilePath $vs -Wait -ArgumentList @(
    '--quiet','--wait','--norestart','--nocache',
    '--installPath','C:\BuildTools',
    '--add','Microsoft.VisualStudio.Workload.VCTools',
    '--includeRecommended'
)
# If C:\BuildTools was created by a different VS product, add instead:
#   --productId Microsoft.VisualStudio.Product.BuildTools
# (a mismatch shows up as error 0x80131500 / "install path is in use").
```

Verify (must print `cl.exe` paths and the install path):

```powershell
& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" `
    -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -find 'VC\Tools\MSVC\**\bin\Hostx64\x64\cl.exe'
```

If cargo cannot find the linker, run a build from a developer prompt for one
diagnostic build:

```cmd
call C:\BuildTools\VC\Auxiliary\Build\vcvars64.bat && cargo build --release -p a2dpwb-driver
```

## 2. Install pnpm (via corepack) and PowerShell 7

```powershell
corepack enable pnpm
corepack prepare pnpm@latest --activate
pnpm --version          # expect 10.x

winget install --id Microsoft.PowerShell --source winget --accept-source-agreements --accept-package-agreements
pwsh -NoProfile -Command '$PSVersionTable.PSVersion'
```

`pnpm` and `pwsh` are needed only for the UI and for the repo's `build.ps1`.
The core and driver do **not** need them.

## 3. Prepare the submodules (the Opus tag caveat)

`extern/` submodules are populated in the reference clone, but `extern/opus`
has no tags locally, and `opus-sys/build.rs` reads the version with
`git describe` (falling back to `package_version`). Fetch the tags:

```powershell
git -C <path-to-upstream>\extern\opus fetch --depth 1 --tags origin
git -C <path-to-upstream>\extern\opus describe --tags --always    # expect v1.5.2-... or a tag
```

If the other submodules are ever empty: `git submodule update --init
--recursive`.

## 4. Build

Core + driver (no Node/pnpm needed):

```powershell
Set-Location <path-to-upstream>
cargo build --release -p a2dpwb-core-exe -p a2dpwb-driver
# -> target\release\a2dpwb-core.exe, target\release\a2dpwb-driver.exe
```

UI (`a2dpwb.exe` embeds the built frontend, so build the page first):

```powershell
Set-Location <path-to-upstream>\app\src\ui
pnpm install --frozen-lockfile
pnpm build
Set-Location <path-to-upstream>
cargo build --release -p a2dpwb-ui
# -> target\release\a2dpwb.exe
```

Or, once `pwsh` and `pnpm` exist, `pwsh ./build.ps1` does all of the above.
The upstream guide is `upstream/docs/building.md`.

## 5. Use the freshly built binaries with the toolkit

```powershell
# doctor picks the installed app by default; point the emulator at the build:
powershell -ExecutionPolicy Bypass -File scripts\run-emulator.ps1 `
    -CoreExe <path-to-upstream>\target\release\a2dpwb-core.exe
```

`a2dpwb-driver.exe` may be run from `target\release` directly; pass it to
`scripts\usb-driver.ps1 -DriverExe`.

## 6. Why the happy path does not build

The v2.0.1 C libraries (BTstack, the codecs) are compiled with MSVC. Without
step 1, `cargo build` fails in `build.rs`/the linker (`link.exe` or `cl.exe`
not found). Step 1 requires a multi-GB download and admin rights, so the
toolkit deliberately relies on the installed binaries. See
`docs/DECISIONS.md` (D4).
