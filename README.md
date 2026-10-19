# A2DP-Windows-Bridge without a USB dongle (internal RTL8852BU)

Operating manual for running **A2DP-Windows-Bridge v2.0.1** on this PC using
only its **internal** Bluetooth radio (`USB\VID_0BDA&PID_4853\00E04C0000XX`,
Realtek **RTL8852BU**). No external USB dongle is bought.

Toolkit layout (this repo):

| Path | What it is |
|:--|:--|
| `scripts/stream.ps1` | **Daily-use launcher**: streams to the headphones with the installed core |
| `scripts/fetch-realtek-fw.ps1` | Downloads + validates the Realtek firmware into the A2DPWB config folder |
| `scripts/usb-driver.ps1` | Wraps `a2dpwb-driver.exe` (assign / restore) and `pnputil` (restart) |
| `scripts/run-emulator.ps1` | Zero-hardware end-to-end run against the Bumble virtual sink |
| `scripts/doctor.ps1` | Read-only diagnosis + verdict |
| `patches/` | Unified diffs that name PID `0x4853` as `RTL8852BU` in the app |
| `vendor-patches/` | The patched copies the diffs were generated from |
| `docs/` | Build-from-source guide and decisions (ADRs) |

`../upstream/` is the read-only reference clone of v2.0.1. **Never edit or
commit it.**

## Verified working on this PC (2026-10-19)

Real hardware, real radio, classic A2DP over the internal RTL8852BU. This is
the current, verified result — not a plan.

| Check | Evidence |
|:--|:--|
| Device | the headset, `<HEADSET_MAC>`, classic A2DP (LE Audio switched **off** on the headset) |
| Codec discovery | `remote supports LDAC (SEID 3, [2D, 01, 00, 00, AA, 00, 3C, 07])` → `codec selected: LDAC` |
| Codec setup | `LDAC: initialized (rate=48000, ch=2, 24-bit, quality=High, transport mtu=895, bitrate=990 kbps)` |
| State | `state Streaming: Connected` |
| 40 s test tone | `Sent 7507 media packets (5052211 bytes), 0 dropped` |
| 25 s system loopback | `Sent 4701 media packets (3163773 bytes), 0 dropped` |
| User confirmation | A song played on the PC came out of the headphones **and** the PC speakers, excellent quality, no dropouts |

### Daily use: one command

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stream.ps1
```

That uses the verified defaults: device `<HEADSET_MAC>`, LDAC, quality
`hq`, system-loopback capture, until Ctrl+C. Variants:

```powershell
# 10 s test tone (1 kHz left / 1.5 kHz right) to check the link
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stream.ps1 -TestTone -Duration 10

# normal music, 990 kbps LDAC, stop with Ctrl+C
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stream.ps1 -Codec ldac -Quality hq

# start detached (prints the PID and the Stop-Process command)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stream.ps1 -Background

# the exact raw command the successful run used
& "$env:LOCALAPPDATA\A2DP Windows Bridge\a2dpwb-core.exe" --cli -d <HEADSET_MAC> -c ldac -q hq --test-tone --duration 40
```

`stream.ps1` only passes flags that exist in
`upstream/app/src/core/src/cli.rs`; run `... -File scripts\stream.ps1 -Help`
for the full parameter list.

### First-time pairing (do this once)

The headset was paired with the Windows Bluetooth stack before. Two different
L2CAP result codes explained the first failures:

| Code | BTstack constant | Meaning on this PC | Fix |
|:--|:--|:--|:--|
| `0x66` | `L2CAP_CONNECTION_RESPONSE_RESULT_REFUSED_SECURITY` | The headset still held the link key created by Windows, so A2DPWB's SSP authentication was refused | Put the headset in pairing mode so it creates a new key |
| `0x67` | `L2CAP_CONNECTION_RESPONSE_RESULT_REFUSED_RESOURCES` | The headset's AVDTP signaling channel was already occupied (phone still connected, LE Audio on) | Disconnect the phone and switch LE Audio off |

The procedure that worked:

1. Switch **LE Audio OFF** on the headset (the maker's app). This is
   what made the classic A2DP path work.
2. **Disconnect the phone** (the headset's multipoint link) so the AVDTP
   signaling channel is free.
3. Put the headset in **pairing mode** (hold the power button until the
   indicator flashes twice).
4. Run `scripts\stream.ps1` (or the raw command above).

### After the first time: no pairing mode needed

The link key is persisted, so later runs just work:

* `%APPDATA%\A2DPWB\link_keys.txt` contains
  `<HEADSET_MAC> REDACTED_LINK_KEY 4`
* `%APPDATA%\A2DPWB\devices.txt` lists `<HEADSET_MAC>|`

Turn the headset on, keep LE Audio off, and run `scripts\stream.ps1`. The
user observed exactly this: "the first time is the test, then it just works".

### Why the PC speakers play too (and how to fix it)

The default capture mode is a WASAPI **loopback of the default output device**
(`Speakers (Realtek(R) Audio)`). Loopback taps the mix; it does not mute it.
So Windows still renders the song to the speakers while A2DPWB encodes the
same audio for the headphones. That is expected, not a fault.

To hear the audio **only in the headphones**, capture a virtual render device
instead (optional, one-time setup):

1. Install a virtual cable such as [VB-CABLE](https://vb-audio.com/Cable/)
   and reboot if the installer asks.
2. Find the render endpoint ID:

   ```powershell
   Get-PnpDevice -Class AudioEndpoint -Status OK |
     Where-Object { $_.InstanceId -like 'SWD\MMDEVAPI\{0.0.0.*' } |
     Select-Object FriendlyName, @{n='AudioDeviceId';e={ $_.InstanceId -replace '^SWD\\MMDEVAPI\\','' }}
   ```

3. Run the stream against `CABLE Input`:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stream.ps1 `
     -Mode virtual -AudioDevice '{0.0.0.00000000}.{your-cable-endpoint-guid}' -Codec ldac
   ```

   The core makes that device the default output for the session
   (`auto_switch`) and restores the previous default when the stream stops.
   If you prefer to set it yourself, choose `CABLE Input` as the default in
   **Settings > System > Sound > Output** before starting.

`-Mode app -App <exe>` captures one application's process tree, but that app
still plays on the default output too; only virtual-device mode removes the
speaker copy.

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

Historical setup state; the verified streaming result is in the top section.

| Item | Value |
|:--|:--|
| Adapter instance | `USB\VID_0BDA&PID_4853\00E04C0000XX` |
| Current driver | `winusb.inf` / service `WINUSB` (WinUSB Device) |
| Previous driver (recorded) | `oem197.inf`, Realtek, service `BTHUSB`, `reboot_required: true` |
| WinUSB open result | **opens** (the former `failed to initialize WinUSB (error 50)` was cleared by the firmware install/reconnect) |
| Firmware in `%APPDATA%\A2DPWB` | **present and shape-valid** (129,733-byte firmware, 6-byte config, installed 20:20) |
| App binaries | `a2dpwb-core.exe`, `a2dpwb-driver.exe`, `a2dpwb.exe` present |
| Toolchain | Rust 1.97, Node 24; **no MSVC C++ compiler** in `C:\BuildTools`; no `pnpm`; no `pwsh` |

Error 50 (`ERROR_NOT_SUPPORTED`) is what this Realtek part reports **after**
the first WinUSB binding until Windows can restart the interface. It is no
longer the state of this PC: the adapter has opened and streamed LDAC.

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

# 3. run the UI, the launcher, or the core CLI directly
& "$env:LOCALAPPDATA\A2DP Windows Bridge\a2dpwb.exe"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stream.ps1
& "$env:LOCALAPPDATA\A2DP Windows Bridge\a2dpwb-core.exe" --cli -d AA:BB:CC:DD:EE:FF
# quick smoke test without headphones:
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stream.ps1 -TestTone -Duration 10

# 4. when done, restore (section 5)
```

With one adapter, A2DPWB opens it automatically; `-u` selects one when
several WinUSB adapters exist. Audio capture defaults to system loopback
(so the PC speakers play too — see the verified section for virtual-device
mode).

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
2. **WinUSB error 50 after a fresh `assign`.** Expected until the interface
   can restart; the record says `reboot_required: true`. Reboot (or
   `usb-driver.ps1 restart` elevated) before expecting a stream. On this PC
   the adapter is past that state and LDAC is verified.
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
