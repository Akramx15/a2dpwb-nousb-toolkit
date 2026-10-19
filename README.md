# A2DP-Windows-Bridge without a USB dongle (internal RTL8852BU)

Operating manual for running **A2DP-Windows-Bridge v2.0.1** on this PC using
only its **internal** Bluetooth radio (`USB\VID_0BDA&PID_4853\00E04C0000XX`,
Realtek **RTL8852BU**). No external USB dongle is bought.

Toolkit layout (this repo):

| Path | What it is |
|:--|:--|
| `scripts/fetch-realtek-fw.ps1` | Downloads + validates the Realtek firmware into the A2DPWB config folder |
| `scripts/usb-driver.ps1` | Wraps `a2dpwb-driver.exe` (assign / restore) and `pnputil` (restart) |
| `scripts/run-emulator.ps1` | Zero-hardware end-to-end run against the Bumble virtual sink |
| `scripts/doctor.ps1` | Read-only diagnosis + verdict |
| `patches/` | Unified diffs that name PID `0x4853` as `RTL8852BU` in the app |
| `vendor-patches/` | The patched copies the diffs were generated from |
| `docs/` | Build-from-source guide and decisions (ADRs) |

`../upstream/` is the read-only reference clone of v2.0.1. **Never edit or
commit it.**

## 1. What A2DP-Windows-Bridge does

It streams Windows audio to Bluetooth headphones with better codecs (LDAC,
LHDC V5, aptX / aptX HD / aptX LL, AAC, SBC XQ, experimental Opus) by
replacing the Windows Bluetooth stack with **BTstack** running in user mode
over **WinUSB**. It ships as `a2dpwb.exe` (Tauri UI + tray),
`a2dpwb-core.exe` (resident core and `--cli`), and `a2dpwb-driver.exe` (the
elevated helper that switches the adapter's driver).

## 2. Why a "dedicated" adapter is normally required

To own the radio, A2DPWB binds **WinUSB** to the Bluetooth USB interface.
While that binding is active, **Windows itself loses Bluetooth**: the
adapter disappears from Device Manager's Bluetooth class, and Windows
Bluetooth settings, mice, keyboards and other devices that used it stop
working. The project therefore recommends a cheap dedicated dongle so the
built-in radio keeps serving Windows. `a2dpwb-driver.exe` records the
adapter's previous driver and can put it back (`restore`), and the UI does
this automatically when you stop.

## 3. Why the internal RTL8852BU qualifies

* BTstack's Realtek table already knows PID **`0x4853`**:
  `extern/btstack/chipset/realtek/btstack_chipset_realtek.c:342` →
  `{0x4853, 0x8852, ..., RTL8852BU}`, firmware `rtl8852bu_fw`,
  config `rtl8852bu_config`.
* The Linux `linux-firmware` project ships both files (`rtl_bt/`), so no
  vendor download portal or NDA is involved.
* It is a single USB function (`VID_0BDA&PID_4853`) with HCI endpoints. Only
  that **Bluetooth** function is bound to WinUSB; the machine's Wi-Fi is a
  separate function and is unaffected.
* The PC has exactly one Bluetooth radio, so the "give it to A2DPWB" trade
  is unambiguous: Windows Bluetooth is unavailable **only while A2DPWB
  runs**, and the driver helper can restore it.

Known limitation of v2.0.1: the app's own chip table
(`app/src/crates/bt-host/src/chips.rs`, `REALTEK_CHIPS`) lacks `0x4853`, so
the UI/log says `chip: unknown (0x4853)`. The `patches/` in this repo fix
that name so the UI advises the correct firmware files. BTstack itself does
not need the app table: it already loads `rtl8852bu_fw`.

## 4. Current state of this PC (2026-10-19)

| Item | Value |
|:--|:--|
| Adapter instance | `USB\VID_0BDA&PID_4853\00E04C0000XX` |
| Current driver | `winusb.inf` / service `WINUSB` (WinUSB Device) |
| Previous driver (recorded) | `oem197.inf`, Realtek, service `BTHUSB`, `reboot_required: true` |
| WinUSB open result | `failed to initialize WinUSB (error 50)` until reboot |
| Firmware in `%APPDATA%\A2DPWB` | **present and shape-valid** (129,733-byte firmware, 6-byte config, installed 20:20) |
| App binaries | `a2dpwb-core.exe`, `a2dpwb-driver.exe`, `a2dpwb.exe` present |
| Toolchain | Rust 1.97, Node 24; **no MSVC C++ compiler** in `C:\BuildTools`; no `pnpm`; no `pwsh` |

Error 50 (`ERROR_NOT_SUPPORTED`) on this Realtek part is expected **after**
the first WinUSB binding: Windows reports that the device needs a restart
before the WinUSB interface is usable. Reboot, then stream.

## 5. Recovery: give the adapter back to Windows

Run from this repo (PowerShell 5.1 is enough for these scripts):

```powershell
# put the adapter back on its Realtek/BTHUSB driver (UAC prompt)
powershell -ExecutionPolicy Bypass -File scripts\usb-driver.ps1 -Mode restore -Auto

# or restore every adapter the helper recorded, one UAC prompt
powershell -ExecutionPolicy Bypass -File scripts\usb-driver.ps1 -Mode restore -UseRecords

# if Windows still hides Bluetooth, restart the device (elevated shell)
powershell -ExecutionPolicy Bypass -File scripts\usb-driver.ps1 -Mode restart -Auto
```

After `restore`, Windows Bluetooth returns. If not, reboot once.

## 6. Run mode A - the real internal adapter

Prerequisite: firmware present (section 7) and the adapter on WinUSB with no
pending reboot.

```powershell
# 1. before switching: note the headphones' MAC (Windows Settings > Bluetooth),
#    or list Windows-paired devices:  a2dpwb-core.exe --cli -l
# 2. take the adapter (UAC); reboot if it reports reboot_required: true
powershell -ExecutionPolicy Bypass -File scripts\usb-driver.ps1 -Mode assign -Auto

# 3. run the UI, or the CLI directly
& "$env:LOCALAPPDATA\A2DP Windows Bridge\a2dpwb.exe"
& "$env:LOCALAPPDATA\A2DP Windows Bridge\a2dpwb-core.exe" --cli -d AA:BB:CC:DD:EE:FF
# quick smoke test without headphones:
& "$env:LOCALAPPDATA\A2DP Windows Bridge\a2dpwb-core.exe" --cli -d AA:BB:CC:DD:EE:FF --test-tone --duration 10

# 4. when done, restore (section 5)
```

With one adapter, A2DPWB opens it automatically; `-u` selects one when
several WinUSB adapters exist. Audio capture defaults to system loopback.

## 7. Firmware preparation (once)

```powershell
powershell -ExecutionPolicy Bypass -File scripts\fetch-realtek-fw.ps1 -DryRun   # preview
powershell -ExecutionPolicy Bypass -File scripts\fetch-realtek-fw.ps1           # download + validate
```

Creates, in `%APPDATA%\A2DPWB` (override with `-ConfigDir`):

* `rtl8852bu_fw.bin`, `rtl8852bu_config.bin` (validated magic) and the
  extension-less aliases `rtl8852bu_fw` / `rtl8852bu_config` BTstack opens.

Validation mirrors `chips.rs`: firmware starts with `Realtech` / `RTBTCore`
and ends with `51 04 FD 77`; config is empty or starts `55 AB 23 87`.
Valid files already present are kept (the script is idempotent), so it does
not overwrite the firmware installed at 20:20.
Download bases (tried in order): kernel.org cgit `plain/` (the canonical
source; this network currently gets an anti-bot HTML page, which validation
rejects), then raw GitHub mirrors of `linux-firmware`
(`torvalds/linux-firmware`, `coolpi-george/linux-firmware`,
`armbian/firmware`). The working mirrors produce a 74,324-byte
`rtl8852bu_fw.bin` (SHA-256
`f1e0427317f147a78606ede85f3f8977ed0ab85c41c6b525560e5bd5a51e5818`) and a
6-byte `rtl8852bu_config.bin` (SHA-256
`6c28a3f07c6a30ed208c4b64862a23f02b7d93543ea980edd24df16bab45095f`);
the currently installed firmware is a different, larger build but passes the
same magic checks.

## 8. Run mode B - emulator (no hardware)

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run-emulator.ps1 -DryRun
powershell -ExecutionPolicy Bypass -File scripts\run-emulator.ps1 -Codec ldac -Duration 10
```

The script creates `tools/emu/.venv` (Bumble), starts the virtual sink,
runs the installed `a2dpwb-core.exe --cli --hci-tcp 127.0.0.1:<port>` with
an isolated `A2DPWB_CONFIG_DIR`, then reports PASS/FAIL by finding the
`[Streaming]` state and the codec name. This works today, without admin
rights and without touching the real adapter.

Note: the resident/tray path hard-codes USB (`resident.rs:270`,
`hci_tcp: None`), so the emulator is **CLI only**.

## 9. Diagnosis

```powershell
powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1
```

Read-only. Exit code `0` = verdict OK, `1` = BLOCKED (the printed "Next
action" is the one thing to do), `2` = the doctor itself failed.

## 10. Known blockers

1. **No MSVC C++ compiler.** `C:\BuildTools` lacks the "Desktop development
   with C++" workload (`cl.exe` absent), so any `cargo build` of the C parts
   fails. The happy path uses the installed v2.0.1 binaries; see
   `docs/BUILD-FOR-SOURCE.md` before building.
2. **WinUSB error 50 until reboot.** Expected after the first `assign`; the
   record says `reboot_required: true`. Reboot (or `usb-driver.ps1 restart`
   elevated) before expecting a working stream.
3. **Firmware version.** The firmware currently installed is shape-valid but
   not the exact build the toolkit's mirrors serve; if BTstack fails to boot,
   re-run `fetch-realtek-fw.ps1 -Force` to install the mirror build, then
   restart the adapter. Without any `rtl8852bu_fw` / `rtl8852bu_config`,
   BTstack cannot boot the controller at all.
4. **`pnpm` and PowerShell 7 missing.** Needed only for the UI build and
   `build.ps1`; the core and the emulator do not need them.
5. **Resident core is USB-only.** The emulator cannot be driven from the
   tray/UI; use `--cli`.
6. **BTstack licence.** A2DPWB built with BTstack may only be used and
   redistributed for personal, non-commercial purposes regardless of
   A2DPWB's own Apache-2.0/MIT licence.
7. **Windows Bluetooth is down while A2DPWB holds the adapter.** Expected;
   restore (section 5) when finished.

## 11. Safety

* `assign` / `restore` need UAC; they are safe to re-run (the helper is
  idempotent and records the previous driver).
* `fetch-realtek-fw.ps1` is idempotent; valid files are kept, invalid ones
  replaced, and every SHA-256 is printed.
* Nothing here edits `../upstream/`. Patches are applied to a copy under
  `vendor-patches/` and verified with `git apply --check` against upstream.
