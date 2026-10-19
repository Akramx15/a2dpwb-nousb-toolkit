# Decision records

ADR-style records for the no-USB A2DP-Windows-Bridge toolkit. Each has
Context / Decision / Consequences / Status. Dates are 2026-10-19.

## D1 - Use the internal RTL8852BU instead of buying a dongle

**Context.** A2DPWB needs to own a Bluetooth radio through WinUSB. Upstream
recommends a dedicated dongle so Windows keeps its own Bluetooth. This PC has
one radio: an internal Realtek RTL8852BU (`USB\VID_0BDA&PID_4853\
00E04C0000XX`). BTstack already knows `0x4853` and linux-firmware ships
`rtl8852bu_fw` / `rtl8852bu_config`; the v2.0.1 app chip table lacks `0x4853`
(UI shows `chip: unknown`).

**Decision.** Use the internal adapter. Add PID `0x4853` to the app chip
table via `patches/0001-...` so the UI names `RTL8852BU` and points at the
right firmware. Accept losing Windows Bluetooth while A2DPWB runs.

**Consequences.** No hardware purchase. Windows Bluetooth, and any device
using it, is unavailable during a run. The Bluetooth USB function is bound
to WinUSB; Wi-Fi (a separate function) is unaffected. Windows cannot use the
adapter for A2DP during the run. The device record has
`reboot_required: true`.

**Status.** Accepted.

## D2 - Keep Windows Bluetooth disabled while A2DPWB runs, and how to restore

**Context.** Binding WinUSB removes the adapter from Windows' Bluetooth
class. The project ships `a2dpwb-driver.exe`, which records the previous
driver in `%APPDATA%\A2DPWB\driver\` and restores it.

**Decision.** Do not fight Windows: leave Bluetooth down during a run, and
use the helper to restore afterwards. The toolkit wraps the helper
(`scripts/usb-driver.ps1`) rather than re-implementing driver swaps.
`restore` uses the recorded `previous` driver; `restore -UseRecords` restores
every recorded adapter with one UAC prompt; `restart` uses
`pnputil /restart-device` when Windows still hides the radio after restore.

**Consequences.** Recovery is two commands and is idempotent and verifiable
(`doctor.ps1` shows `kind` from the helper). A reboot may still be required
after `assign` (error 50) and occasionally after `restore`.

**Status.** Accepted.

## D3 - Use the emulator for zero-hardware CI and verification

**Context.** The core has a hardware-free path: `a2dpwb-core.exe --cli
--hci-tcp host:port` talks H4 over TCP to a virtual controller; upstream ships
`tools/emu` (Bumble sink). The resident/tray path hard-codes USB
(`resident.rs:270`, `hci_tcp: None`).

**Decision.** Make the emulator the default way to verify the toolkit without
hardware or admin rights (`scripts/run-emulator.ps1`), with an isolated
`A2DPWB_CONFIG_DIR` so the user's real link keys are never touched.

**Consequences.** Verification is reproducible and safe, but emulator-only
(no radio timing, no real headphones) and CLI-only until upstream exposes
`--hci-tcp` in the resident path. The venv needs Python 3.11+ and a download
of pinned Bumble packages (test tooling only, not shipped).

**Status.** Accepted.

## D4 - Do not build from source in the happy path

**Context.** This PC has Rust 1.97 but `C:\BuildTools` lacks the MSVC C++
workload: `vswhere -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64`
returns nothing and `cl.exe` is absent, so `cargo build` of the C parts
(BTstack, codecs) fails. Installing the workload is a multi-GB, admin-rights
download. v2.0.1 binaries are already installed and sufficient.

**Decision.** The happy path uses the installed v2.0.1 binaries. Building
from source is documented separately (`docs/BUILD-FOR-SOURCE.md`) and is
optional. Only the two files in `patches/` need a rebuild if you want the UI
to name PID `0x4853`; streaming works with the stock build because BTstack's
own table has `0x4853`.

**Consequences.** No build dependency in the happy path; the UI shows
`chip: unknown (0x4853)` and cannot name the firmware files until the patch
is built. A build requires step 1 of `BUILD-FOR-SOURCE.md`, plus `corepack
enable pnpm` and PowerShell 7 for the UI.

**Status.** Accepted.
