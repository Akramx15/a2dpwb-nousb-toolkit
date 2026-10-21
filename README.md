# A2DP-Windows-Bridge without a USB dongle (internal RTL8852BU)

Operating manual for running **A2DP-Windows-Bridge 2.0.2-beta.5** on this PC
using only its **internal** Bluetooth radio
(`USB\VID_0BDA&PID_4853\00E04C0000XX`, Realtek **RTL8852BU**). No external USB
dongle is bought.

Toolkit layout (this repo):

| Path | What it is |
|:--|:--|
| `scripts/stream.ps1` | **Daily-use launcher**: streams to the headphones with the installed core |
| `scripts/fetch-realtek-fw.ps1` | Downloads + validates the Realtek firmware into the A2DPWB firmware folder (2.0.2-beta.5+: `%APPDATA%\A2DPWB\firmware`, auto-detected); 2.0.2+ writes only the `.bin` files (`-LegacyAliases` for 2.0.1) |
| `scripts/usb-driver.ps1` | Wraps `a2dpwb-driver.exe` (assign / restore) and `pnputil` (restart) |
| `scripts/run-emulator.ps1` | Zero-hardware end-to-end run against the Bumble virtual sink |
| `scripts/doctor.ps1` | Read-only diagnosis + verdict; reports the inspected app version and the firmware layout it implies |
| `scripts/cold-boot-test.ps1` | Three-phase cold-boot check of the Realtek firmware path (run after a Windows reboot); writes raw `<output>.phaseN.log` files |
| `scripts/cold-boot-round2.ps1` | Prepares the next reboot for the missing-firmware case, backs up/removes exactly the files it found, restores them; `-WhatIf` (default), `-Execute`, `-Abort` |
| `scripts/set-default-audio.ps1` | Lists the render endpoints and sets the Windows default output (IPolicyConfig); `-List`, `-Device`, `-Restore`, `-WhatIf` |
| `scripts/copy-diagnostics.ps1` | Reads the app's **Copy Diagnostics** text over the core's IPC pipe, without the GUI; `-Masked` (default), `-Full`, `-Output` |
| `patches/` | Unified diffs that name PID `0x4853` as `RTL8852BU` in the app — **superseded by upstream PR #82** (2.0.2-beta.1); kept for 2.0.1 source builds only |
| `vendor-patches/` | The patched copies the diffs were generated from |
| `docs/HEADPHONES-ONLY.md` | **Headphones-only routing through VB-CABLE**: the full recipe, the verified evidence and the one-command revert |
| `docs/UNPATCHED-MODULE.md` | **An unpatched module opens the adapter but cannot stream**: reproduction and what it means for the user |
| `docs/UPSTREAM-2.0.2.md` | **2.0.1 -> 2.0.2-beta.5 changes**: no error-50 path, family-wide PID resolution, named/self-fetched firmware, obsolete extension-less copies, the firmware folder, the ROM state |
| `docs/` | Build-from-source guide, decisions (ADRs), the root-cause account and the drafted upstream issue |

`../upstream/` is the read-only reference clone of v2.0.1. **Never edit or
commit it.**

## Credits & acknowledgements

This toolkit exists because of **A2DP-Windows-Bridge**, written by
**[SeiyaFunaokaJP](https://github.com/SeiyaFunaokaJP/A2DP-Windows-Bridge)**.
Thank you for building a Windows A2DP source that actually reaches LDAC and
for publishing it. The upstream project is the authoritative source: prefer
its releases, and report codec or runtime bugs upstream rather than here.

The Bluetooth work stands on **BTstack** by **BlueKitchen GmbH**, which drives
the controller in user mode over WinUSB, and on the **linux-firmware**
project, which carries the Realtek `rtl8852bu_fw` / `rtl8852bu_config` blobs
used by BTstack's Realtek chipset driver. Thanks also to the Realtek/BTstack
chipset driver work that makes an off-the-shelf RTL8852BU usable on Windows.

The findings here (why `WinUSB error 50` appears — the binding is not live until
the device is re-enumerated — the separate missing-firmware / ROM-mode case,
the chip-table gap for PID `0x4853`, and the first-pairing behaviour of
LE-Audio-capable headsets) were reported upstream:
<https://github.com/SeiyaFunaokaJP/A2DP-Windows-Bridge/issues/81>
The draft is kept in `docs/UPSTREAM-ISSUE.md`; the corrected causal account is
in `docs/ROOT-CAUSE.md`.

**Licensing:** personal, non-commercial use only — see `NOTICE.md`. A2DPWB
embeds BTstack, whose licence does not allow commercial use or redistribution
without a BlueKitchen licence.

## Verified working on this PC (2026-10-19 / 2026-10-21)

Real hardware, real radio, classic A2DP over the internal RTL8852BU. This is
the current, verified result — not a plan.

| Check | Evidence |
|:--|:--|
| Build | **2.0.2-beta.5**, official NSIS installer, `currentUser` mode (no administrator rights) |
| Device | the headset, `<HEADSET_MAC>`, classic A2DP (LE Audio switched **off** on the headset) |
| Chip | `chip: RTL8852BU (0BDA)` (2.0.1 said `chip: unknown (0x4853)`) |
| Codec discovery | `remote supports LDAC (SEID 3, [2D, 01, 00, 00, AA, 00, 3C, 07])` → `codec selected: LDAC` |
| Codec setup | `LDAC: initialized (rate=48000, ch=2, 24-bit, quality=High, transport mtu=895, bitrate=990 kbps)` |
| State | `state Streaming: Connected` |
| 40 s test tone | `Sent 7507 media packets (5052211 bytes), 0 dropped` |
| 25 s system loopback | `Sent 4701 media packets (3163773 bytes), 0 dropped` |
| Cold module, only `.bin` files (2.0.2-beta.4) | `Realtek firmware download ran (ROM LMP subversion 0x8852)`; `Sent 3765 media packets ... 0 dropped`; no extension-less copies created (`docs/UPSTREAM-2.0.2.md`) |
| Firmware files missing, warm module (2.0.2-beta.5) | `WARN firmware file missing: ...\firmware\rtl8852bu_fw.bin`; `Realtek firmware already running from an earlier session (LMP subversion 0xFD78), download skipped` - the misleading "download ran" is gone |
| User confirmation | A song played on the PC came out of the headphones **and** the PC speakers, excellent quality, no dropouts |
| Headphones-only routing | `CABLE Input` as default output + virtual capture: `Sent 3789 media packets (2549997 bytes), 0 dropped before the radio`, speakers silent — `docs/HEADPHONES-ONLY.md` |

The toolkit currently targets **2.0.2-beta.5**. The table records the beta.1
streaming runs plus the beta.4 cold-module run; beta.5 keeps the streaming
result, removes the manual re-enumeration and file-copy steps (see
`docs/UPSTREAM-2.0.2.md`).

### Daily use: one command

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stream.ps1
```

With no `-Device`, the launcher **auto-discovers** the headphones: it runs
`a2dpwb-core.exe --cli --scan <ScanSeconds>` (8 s by default), keeps the
nearby classic Bluetooth audio devices and, if there is exactly one, uses it
and prints which one it chose. If several audio devices are nearby it lists
them and refuses to guess — re-run with `-Device <MAC>`. If none is found it
explains that the headset must be powered on (and in pairing mode for the
first connection) and exits with code 2. Then it uses LDAC, quality `hq`,
system-loopback capture, until Ctrl+C. To find the address by hand, run
`a2dpwb-core.exe --cli -l` or see Windows Settings > Bluetooth > Devices.

```powershell
# 10 s test tone (1 kHz left / 1.5 kHz right) to check the link
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stream.ps1 -TestTone -Duration 10

# skip the scan and name the headset explicitly
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stream.ps1 -Device <HEADSET_MAC>

# give the discovery scan more time
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stream.ps1 -ScanSeconds 12

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

* `%APPDATA%\A2DPWB\link_keys.txt` persists the pairing in the format
  `<address> <key> <type>` (for example `<HEADSET_MAC> <link key> <type>`;
  the value is redacted here on purpose — it is a credential that can
  impersonate this PC to the headset and must never be published).
* `%APPDATA%\A2DPWB\devices.txt` lists the paired headset as
  `<HEADSET_MAC>|`.

Turn the headset on, keep LE Audio off, and run `scripts\stream.ps1`. The
user observed exactly this: "the first time is the test, then it just works".

### Why the PC speakers play too

The default capture mode is a WASAPI **loopback of the default output device**
(`Speakers (Realtek(R) Audio)`). Loopback taps the mix; it does not mute it.
So Windows still renders the song to the speakers while A2DPWB encodes the
same audio for the headphones. That is expected, not a fault, and it is
upstream's own wording (`docs/usage.md`: "System Loopback copies the audio; it
does not take it away from the default output device").

`-Mode app -App <exe>` captures one application's process tree, but that app
still plays on the default output too; only virtual-device mode removes the
speaker copy.

### Headphones only (VB-CABLE)

The verified recipe on this PC: install **VB-CABLE** (a render device that
plays nowhere), make `CABLE Input` the Windows default output through
`scripts\set-default-audio.ps1`, and run the app in **Virtual Device** mode
against that endpoint. The cable swallows the audio, A2DPWB captures it, and
the speakers stay silent.

* Full recipe, verified evidence and the one-command revert:
  **[`docs/HEADPHONES-ONLY.md`](docs/HEADPHONES-ONLY.md)**.
* The footgun: while `CABLE Input` is the default and the app is not streaming,
  the PC has **no sound at all**. The revert is at the top of that document:

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\set-default-audio.ps1 `
    -Restore -Device "Speakers (Realtek(R) Audio)"
  ```

  (`-Restore` alone exits 2 on this PC: it finds two candidates, the Realtek
  speakers and the Boom 3D wrapper, and refuses to guess.)

Related:

* **An unpatched module opens but does not stream.** Measured on a cold boot
  with the firmware files removed — the adapter and HCI come up, the app names
  the missing files, and the stream never establishes; restoring the `.bin`
  files fixes it on the same boot. The `firmware file missing` warning is the
  decisive signal, not the adapter state. Reproduction and evidence:
  **[`docs/UNPATCHED-MODULE.md`](docs/UNPATCHED-MODULE.md)**.
* **A virtual cable is not a driver trick.** It is a normal render endpoint;
  the app only needs its WASAPI id (`--audio-device`) and the Windows default
  output pointed at it.

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
not need the app table: it already loads `rtl8852bu_fw`. The installed
**2.0.2-beta.4** resolves it on this PC:
`chip: RTL8852BU (0BDA:4853 -> 0xB85B) (auto)`.

**The patches here are superseded by upstream.** PR
[SeiyaFunaokaJP/A2DP-Windows-Bridge#82](https://github.com/SeiyaFunaokaJP/A2DP-Windows-Bridge/pull/82)
resolved this properly: it derives the PID-to-family mapping from BTstack's own
firmware table at build time, so *every* PID of a known family is recognised
(RTL8852BU alone has 19), and it shipped in **2.0.2-beta.1**. The diffs in
`patches/` are kept only as a reference for building **2.0.1** from source;
do not apply them to 2.0.2 or newer.

## 4. Current state of this PC (2026-10-19, updated 2026-10-20)

Setup state; the verified streaming result is in the top section.

| Item | Value |
|:--|:--|
| Adapter instance | `USB\VID_0BDA&PID_4853\00E04C0000XX` |
| Installed app | **2.0.2-beta.5** (installed over 2.0.2-beta.4 with the official NSIS installer, `currentUser`, no admin) |
| Current driver | `winusb.inf` / service `WINUSB` (WinUSB Device) |
| Previous driver (recorded) | `oem197.inf`, Realtek, service `BTHUSB`, `reboot_required: true` |
| WinUSB open result | **opens** (the former `failed to initialize WinUSB (error 50)` was the binding not being live; it cleared once the device was re-enumerated) |
| Firmware in `%APPDATA%\A2DPWB` | **present** (129,733-byte firmware; since 2.0.2 the chip table has `config: None` for the RTL8852BU, so the app writes a 0-byte `rtl8852bu_config.bin` and BTstack uses the efuse settings — a 6-byte config streams the same) |
| Virtual cable | **VB-CABLE installed** (`CABLE Input` / `CABLE Output` / `CABLE In 16ch`); the Windows default output is currently **`Speakers (Realtek(R) Audio)`** — the headphones-only route and its one-command revert are in `docs/HEADPHONES-ONLY.md` |
| App binaries | `a2dpwb-core.exe`, `a2dpwb-driver.exe`, `a2dpwb.exe` present |
| Toolchain | Rust 1.97, Node 24; **no MSVC C++ compiler** in `C:\BuildTools`; no `pnpm`; no `pwsh` |

`failed to initialize WinUSB (error 50)` is `ERROR_NOT_SUPPORTED`, but it did
not mean the driver or the firmware was wrong: the WinUSB binding was simply
not live yet. In 2.0.1 the helper recorded `reboot_required: true` at assign
time and the device had to be re-enumerated. **2.0.2-beta.4 restarts the device
itself**: the record now says `reboot_required: false`, the adapter opens
immediately, the module goes to ROM and the app re-uploads the firmware. The
firmware remains a **separate** requirement: it patches the controller out of
ROM mode. A cold, unpatched module still opens the adapter and serves HCI from
its ROM code — so "the adapter cannot open" must never be read as "the firmware
is missing". `docs/ROOT-CAUSE.md` carries the historical evidence;
`docs/UPSTREAM-2.0.2.md` records the current behaviour.

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
# 1. the headphones' MAC is auto-discovered by stream.ps1; to see it by hand,
#    use Windows Settings > Bluetooth, or: a2dpwb-core.exe --cli -l
# 2. take the adapter (UAC); 2.0.2+ restarts it itself after the assign
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

Creates, in the firmware folder (override with `-FirmwareDir`):

* `%APPDATA%\A2DPWB\firmware` on **2.0.2-beta.5 and newer** (the app moved the
  files there on its first run and the UI has *Settings > Open Firmware
  Folder*); the script detects the folder and prints which one it uses.
* `%APPDATA%\A2DPWB` itself on **2.0.2-beta.4 and older**.

In that folder:

* `rtl8852bu_fw.bin` and `rtl8852bu_config.bin` (validated magic).
* On 2.0.1 only, `-LegacyAliases` additionally creates the extension-less
  copies `rtl8852bu_fw` / `rtl8852bu_config` that older builds open.

2.0.2+ uses the `.bin` files and removes identical extension-less copies on a
scan, so the script does not create them by default. The app can also download
the firmware itself from linux-firmware (pinned commit, SHA-256 checked); this
script remains the offline/controlled path.

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
same magic checks. Since 2.0.2 the app's **own** download writes a **0-byte**
`rtl8852bu_config.bin` instead (its chip table has `config: None` for the
RTL8852BU), and BTstack then uses the efuse settings: a 0-byte and a 6-byte
config both stream LDAC with 0 dropped packets.

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
action" is the one thing to do), `3` = STALE (no live probe and no decisive log
marker; run the doctor with the live probe while A2DPWB is stopped), `2` = the
doctor itself failed.

## 10. Known blockers

1. **No MSVC C++ compiler.** `C:\BuildTools` lacks the "Desktop development
   with C++" workload (`cl.exe` absent), so any `cargo build` of the C parts
   fails. The happy path uses the installed 2.0.2-beta.4 binaries; see
   `docs/BUILD-FOR-SOURCE.md` before building.
2. **WinUSB error 50 after a fresh `assign` (historical).** On 2.0.1 the
   binding was not live until Windows re-enumerated the device and the record
   said `reboot_required: true`. 2.0.2-beta.4 restarts the device itself after
   the assign (`reboot_required: false`), so no manual unplug/reboot is part of
   the expectation. A `true` value now points at a stale helper record. This was
   never a firmware symptom (see `docs/ROOT-CAUSE.md`,
   `docs/UPSTREAM-2.0.2.md`).
3. **Firmware files.** 2.0.2+ needs only `rtl8852bu_fw.bin` and
   `rtl8852bu_config.bin`; extension-less copies are obsolete and the app
   removes identical ones on a scan (a warm scan does not create them).
   The firmware currently installed is shape-valid but
   not the exact build the toolkit's mirrors serve; if you want the mirror
   build, re-run `fetch-realtek-fw.ps1 -Force`, then restart the adapter.
   Without the `.bin` files the module stays in ROM mode (unpatched); it still
   opens and serves HCI, so the missing files do not produce `error 50`, but
   **the A2DP stream does not establish** — the `firmware file missing` warning
   and the "Firmware not loaded" state are the decisive signals
   (`docs/UNPATCHED-MODULE.md`).
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
* `fetch-realtek-fw.ps1` is idempotent; it writes only the two `.bin` files by
  default (2.0.2+ removes identical extension-less copies on a scan), keeps
  valid files, replaces invalid ones, and prints every SHA-256. Pass
  `-LegacyAliases` only when targeting 2.0.1 or older.
* `set-default-audio.ps1` changes where **every** app plays, for the current
  user, and prints the plan first with `-WhatIf`. With `CABLE Input` as the
  default the PC is silent while nothing streams it; keep the `-Restore`
  command from `docs/HEADPHONES-ONLY.md` at hand.
* Nothing here edits `../upstream/`. Patches are applied to a copy under
  `vendor-patches/` and verified with `git apply --check` against upstream.
