# Handoff — A2DP-Windows-Bridge on this PC, with NO external USB dongle

## Verdict

The goal is achieved on the hardware. **No USB Bluetooth dongle is needed.**
The PC's internal **Realtek RTL8852BU** (`USB\VID_0BDA&PID_4853\00E04C0000XX`) is a
plain USB HCI device and is driven directly by the project's user-mode BTstack
through the Microsoft-signed WinUSB driver. The only reason the project asks
for a "dedicated adapter" is to keep Windows' own Bluetooth alive at the same
time — not because the radio itself is special.

**Streaming to the real headset is VERIFIED** (2026-10-19): classic A2DP, LDAC
990 kbps, 0 dropped packets, heard by the user with no dropouts.

## Verified on this machine (evidence, not assumptions)

| Fact | Evidence |
|---|---|
| Adapter is USB, bound to WinUSB | `DEVPKEY_Device_Service = WINUSB`, `Status Started`, `ProblemCode 0` |
| WinUSB opens the adapter | `INFO USB: opened 0BDA:4853 ... (event 0x81, ACL 0x82/0x02)` |
| Controller is alive | `INFO controller: company 0x005D (Realtek), HCI version 11, LMP subversion 0xFD78` |
| Realtek firmware loads | `INFO Realtek firmware download ran (ROM LMP subversion 0x8852)` / later `Firmware already exists` |
| HCI comes up | `INFO HCI ready (took 102 ms)` |
| RF link to the real headset works | `INFO HCI ACL connection established to <HEADSET_MAC>` |
| Headphone address | `<HEADSET_MAC>` (the headset, from the old Windows pairing; `scripts\stream.ps1` auto-discovers it, or list it with `a2dpwb-core.exe --cli -l` / Windows Settings > Bluetooth) |
| First pairing succeeds | link key persisted in `%APPDATA%\A2DPWB\link_keys.txt` in the format `<address> <key> <type>` (value redacted here on purpose — it is a credential); `devices.txt` lists `<HEADSET_MAC>|` |
| Real LDAC stream | `remote supports LDAC (SEID 3, [2D, 01, 00, 00, AA, 00, 3C, 07])` → `codec selected: LDAC` |
| LDAC setup | `LDAC: initialized (rate=48000, ch=2, 24-bit, quality=High, transport mtu=895, bitrate=990 kbps)` |
| Stable state | `state Streaming: Connected` |
| 40 s test tone | `Sent 7507 media packets (5052211 bytes), 0 dropped` |
| 25 s system loopback | `Sent 4701 media packets (3163773 bytes), 0 dropped` |
| User confirmation | A PC song played from the headphones and the PC speakers, excellent quality, no dropouts |
| Zero-hardware path works | `--hci-tcp` + Bumble virtual controller: LDAC / SBC / aptX HD all reached `Streaming`, 0 dropped packets |

**Note on scope:** the build also produced a set of unrelated research notes
about the headset's BLE/vendor protocol, firmware mods and using the headset as
a PC microphone. They are **not** part of this toolkit, were never reviewed for
correctness, and were moved out of the published tree; the repository now
contains only the no-dongle toolkit and its documentation.

**The blocker that was fixed:** `failed to initialize WinUSB (error 50)`. Cause:
the Realtek firmware was missing, so BTstack could not boot the controller and
the adapter never came up. Fix: install `rtl8852bu_fw.bin` (129,733 B) and
`rtl8852bu_config.bin` (6 B) into `%APPDATA%\A2DPWB` (plus the extension-less
aliases `rtl8852bu_fw` / `rtl8852bu_config` that BTstack reads). No reboot, no
Administrator rights, no driver change were required for this.

**First pairing: resolved.** Two L2CAP codes came from upstream/BTstack
constants, not from a toolkit bug:

* `0x66` = `L2CAP_CONNECTION_RESPONSE_RESULT_REFUSED_SECURITY`: the headset
  still held the **link key created by the Windows Bluetooth stack**. A2DPWB
  had no such key, so SSP authentication was refused.
* `0x67` = `L2CAP_CONNECTION_RESPONSE_RESULT_REFUSED_RESOURCES`: the headset's
  **AVDTP signaling channel was already occupied** — it was still connected to
  the phone and LE Audio was on.

The fix that worked: switch **LE Audio OFF** on the headset, **disconnect the
phone**, put the the headset into **pairing mode** (hold the power button until
the indicator flashes twice), then run the stream. The key is now persisted,
so **no pairing mode is needed on later runs** — the user observed exactly
this ("the first time is the test, then it just works").

## Done

* Toolkit repo (`work/a2dpwb-nousb`) with five PowerShell 5.1 scripts, two
  verified upstream patches, the operating manual, the build-from-source guide
  and the decision records.
* `scripts/doctor.ps1` — read-only state report + verdict.
* `scripts/fetch-realtek-fw.ps1` — validated firmware download (magic bytes) +
  extension-less aliases.
* `scripts/usb-driver.ps1` — wraps `a2dpwb-driver.exe` (assign/restore) and
  `pnputil /restart-device`; its CLI syntax was read from
  `upstream/app/src/driver/src/main.rs`, not guessed.
* `scripts/run-emulator.ps1` — hardware-free end-to-end run (LDAC/SBC/aptX HD).
* `scripts/stream.ps1` — daily-use launcher for the installed core (device,
  codec, quality, ABR, rate, mode, test tone, duration, background). Every
  flag was cross-checked against `upstream/app/src/core/src/cli.rs`.
* Real-hardware streaming verified: the headset, LDAC 990 kbps, 0 dropped
  packets, confirmed by ear.
* `patches/0001-...` and `patches/0002-...` apply cleanly to upstream
  (`git apply --check` passes). Upstream is untouched
  (`git -C upstream status --porcelain` → empty).

## Blocked

* **MSVC C++ workload missing** in `C:\BuildTools` (no `cl.exe`), so
  `cargo build` of the C parts fails. Only needed to bake the chip-name patch
  into a binary; stock v2.0.1 works without it.
* `pnpm` and PowerShell 7 are absent → the Tauri UI and `build.ps1` cannot be
  built. The core, the driver and the emulator are unaffected.
* Windows' own Bluetooth is **not** available while the adapter is on WinUSB.
  Mouse/keyboard stay usable only if they are wired. Restore with
  `scripts\usb-driver.ps1 -Mode restore`.

## Remaining OPTIONAL work

The goal is met. These are improvements, not blockers:

1. **96 kHz LDAC at 990 kbps.** Set the Windows playback format for the
   output device to 96 kHz (Settings > System > Sound > device > Format), then
   run `scripts\stream.ps1 -Rate 96000 -Codec ldac -Quality hq`. The verified
   run was 48 kHz.
2. **ABR.** Try `scripts\stream.ps1 -Abr` when the RF conditions vary; it maps
   to `-a` (LDAC / LHDC V5).
3. **Virtual-device-only audio.** Install VB-CABLE and use
   `scripts\stream.ps1 -Mode virtual -AudioDevice <id>` so the PC speakers no
   longer play the same song. See README's verified section for the exact
   device-ID command and the auto-switch behaviour.
4. **GUI/tray app for daily use.** `a2dpwb.exe` exposes the same core with a
   UI; use it when a tray icon is preferable to a PowerShell window. The
   resident path is USB-only, so the emulator still needs `--cli`.
5. **Restore the Windows Bluetooth driver when not streaming.** Keep the
   adapter on WinUSB for frequent use, or run
   `scripts\usb-driver.ps1 -Mode restore` afterwards (D2). Windows Bluetooth
   (and any device using it) stays unavailable while A2DPWB owns the radio.

## First files a successor should read

1. `HANDOFF.md` (this file).
2. `README.md` — the verified section, the pairing procedure, the operating
   manual and the known blockers.
3. `scripts\stream.ps1` — the daily path; every flag maps to
   `upstream/app/src/core/src/cli.rs`.
4. `docs/DECISIONS.md` — D1..D6, especially D2 (restore), D5 (loopback vs
   virtual) and D6 (LE Audio off / phone disconnected).
5. `scripts/doctor.ps1` — single source of truth for current state.
6. `docs/BUILD-FOR-SOURCE.md` — only if a build becomes necessary.
7. Upstream reference (read-only): `upstream/app/src/core/src/cli.rs` (every
   flag the launcher uses), `upstream/app/src/driver/src/main.rs` (helper CLI),
   `upstream/app/src/crates/bt-host/src/chips.rs` (chip table),
   `upstream/app/src/crates/core/src/adapter.rs` (the `chip:` log line).
