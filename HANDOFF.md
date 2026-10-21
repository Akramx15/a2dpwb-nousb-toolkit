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

**Current machine state (2026-10-21).** The installed app is
**2.0.2-beta.5** (official NSIS installer, `currentUser`, installed over
2.0.2-beta.4), and the chip now resolves as `chip: RTL8852BU (0xBDA:4853 ->
0xB85B)`. The Realtek firmware files live in **`%APPDATA%\A2DPWB\firmware`**
since beta.5 moved them there (the UI has *Settings > Open Firmware Folder*);
the toolkit scripts detect that folder automatically.
**VB-CABLE is installed** (`CABLE Input` / `CABLE Output` / `CABLE In 16ch`).
The Windows default output is currently **`Speakers (Realtek(R) Audio)`** — the
headphones-only route is a recipe, not the default state. Both directions:

```powershell
# to the headphones-only route
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\set-default-audio.ps1 `
  -Device "CABLE Input (VB-Audio Virtual Cable)"

# and back
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\set-default-audio.ps1 `
  -Restore -Device "Speakers (Realtek(R) Audio)"
```

`-Restore` alone exits 2 here (two physical candidates: Realtek and the Boom 3D
wrapper). While `CABLE Input` is the default and nothing streams it, **the PC
has no sound at all** — that is the known footgun, documented at the top of
`docs/HEADPHONES-ONLY.md`.

### Upstream thread state (issue #81, recorded 2026-10-20 under beta.1)

`https://github.com/SeiyaFunaokaJP/A2DP-Windows-Bridge/issues/81` — open, 5
comments (1 from the maintainer, 4 from this account). Since then
**2.0.2-beta.4** shipped with #88 (self restart after assign), #92 (app-side
firmware download), #94 (ROM detection) and #97 (extension-less copies
obsolete); the beta.1 account below is kept as history, and the current
behaviour is in `docs/UPSTREAM-2.0.2.md`.

| What | State |
|---|---|
| PR #82 (chip families) | merged 03:43, shipped in v2.0.2-beta.1 |
| v2.0.2 final | **not released yet** — latest is still v2.0.1, beta is a pre-release |
| Issue title | corrected: no longer claims the firmware caused `error 50` |
| Issue body | carries a correction banner; the build number was corrected to 26200.9711 |
| Comments 2 and 4 | beta test report, and the cold/unpatched-module finding |
| Comment 3 | the causal correction; its code pointer was later corrected in place |
| Comment 5 | the Diagnostics text (asked for by the maintainer), the build correction, and a concrete proposal for a "running ROM firmware" warning |

Two corrections are recorded in the public thread, both mine and both of the
same kind: a fact taken from a **grep hit or from memory** instead of from the
source. `driver.rs:359` is the **restore** path, not the assign path, and the
machine is Windows build **26200.9711 (25H2)**, not 26100. The rule that
follows: every claim about another codebase names a `file:line` that was
opened, not one that a search returned.

The maintainer's open request — the Diagnostics text — is answered in comment 5.
`scripts/copy-diagnostics.ps1` produces the same text without the GUI, over
the core's named pipe.

## Verified on this machine (evidence, not assumptions)

| Fact | Evidence |
|---|---|
| Installed build | `2.0.2-beta.4` (NSIS, `currentUser`); `chip: RTL8852BU (0BDA) (auto)` |
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
| Headphones-only routing | `CABLE Input` default + virtual capture: `Sent 3789 media packets (2549997 bytes), 0 dropped before the radio`; speakers silent (`docs/HEADPHONES-ONLY.md`) |
| User confirmation | A PC song played from the headphones and the PC speakers, excellent quality, no dropouts |
| Zero-hardware path works | `--hci-tcp` + Bumble virtual controller: LDAC / SBC / aptX HD all reached `Streaming`, 0 dropped packets |

**Note on scope:** the build also produced a set of unrelated research notes
about the headset's BLE/vendor protocol, firmware mods and using the headset as
a PC microphone. They are **not** part of this toolkit, were never reviewed for
correctness, and were moved out of the published tree; the repository now
contains only the no-dongle toolkit and its documentation.

**The blocker that was fixed:** `failed to initialize WinUSB (error 50)`. There
were **two independent causes**, not one — full account in `docs/ROOT-CAUSE.md`.

* **Error 50 was the WinUSB binding not being live yet.** The helper flagged it
  at assign time (the driver record said `"reboot_required": true` — the restart
  flag `DiInstallDevice` returns, `app/src/crates/win-sys/src/driver.rs:442`),
  so the binding was not live on the running device node until Windows
  re-enumerated it; `uninstall_and_reenumerate` (`driver.rs:359`) is the restore
  path, not the assign path. On beta.1 the first scan 7 s after the assign failed
  with error 50 and the same adapter opened as soon as the device was
  re-enumerated. **Since 2.0.2 the helper restarts the device itself**
  (`reboot_required: false`) and error 50 is retired; `usb-driver.ps1` now says
  so. Historical detail: `docs/ROOT-CAUSE.md`.
* **The missing Realtek firmware was a separate, second issue.** Without it the
  module stays in ROM mode — the chip is not patched — but the adapter still
  opens and serves HCI from ROM (measured on a cold module after a real reboot,
  D7). The app could not *name* the files because of the chip-table gap for PID
  `0x4853`; upstream fixed that with PR #82 / 2.0.2-beta.1, whose
  `firmware file missing: ...` warnings are the right signal for this case.
   Install `rtl8852bu_fw.bin` (129,733 B) and `rtl8852bu_config.bin` into
   `%APPDATA%\A2DPWB`; no reboot, no Administrator rights and no driver change
  are needed for that. 2.0.2+ uses the `.bin` files and does not need the
  extension-less copies (`-LegacyAliases` exists only for 2.0.1); the app
  removes identical copies on a scan. Cold-boot round 2 added the decisive
  detail: on the unpatched module the
  **A2DP stream does not establish** (no `state Streaming: Connected`, no
  `Sent ...` line) even though the adapter opened; restoring only the `.bin`
  files made the same cold module upload the firmware and stream with 0
  dropped. So the warning — not the adapter state — is the signal (D9,
  `docs/UNPATCHED-MODULE.md`).

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

* Toolkit repo (`work/a2dpwb-nousb`) with nine PowerShell 5.1 scripts, two
  verified upstream patches, the operating manual, the build-from-source guide
  and the decision records.
* `scripts/doctor.ps1` — read-only state report + verdict; reports the
  inspected app version and treats `.bin` as required, copies as optional on
  2.0.2+.
* `scripts/fetch-realtek-fw.ps1` — validated firmware download (magic bytes);
  writes only the two `.bin` files unless `-LegacyAliases` is passed for 2.0.1.
* `scripts/cold-boot-test.ps1` / `scripts/cold-boot-round2.ps1` — cold-module
  checks with adaptive 2.0.1/2.0.2 expectations, exact backup/restore and raw
  per-phase logs.
* `scripts/usb-driver.ps1` — wraps `a2dpwb-driver.exe` (assign/restore) and
  `pnputil /restart-device`; its CLI syntax was read from
  `upstream/app/src/driver/src/main.rs`, not guessed.
* `scripts/run-emulator.ps1` — hardware-free end-to-end run (LDAC/SBC/aptX HD).
* `scripts/stream.ps1` — daily-use launcher for the installed core (device,
  codec, quality, ABR, rate, mode, test tone, duration, background). Every
  flag was cross-checked against `upstream/app/src/core/src/cli.rs`.
* `scripts/set-default-audio.ps1` — read/modify the Windows default render
  endpoint (IPolicyConfig, all three roles); `-List`, `-Device`, `-Restore`,
  `-WhatIf`. Used for headphones-only routing.
* `docs/HEADPHONES-ONLY.md` — the reproducible VB-CABLE recipe (official
  SHA-256, endpoint discovery, GUI + CLI, verified log lines, revert).
* `docs/UNPATCHED-MODULE.md` — cold-boot finding: an unpatched module opens
  the adapter but cannot stream; the missing-firmware warning is the signal.
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

The goal is met. These are improvements, not blockers. (The former item
"virtual-device-only audio" is **done**: VB-CABLE is installed — see
`docs/HEADPHONES-ONLY.md` and D8.)

1. **96 kHz LDAC at 990 kbps.** Set the Windows playback format for the
   output device to 96 kHz (Settings > System > Sound > device > Format), then
   run `scripts\stream.ps1 -Rate 96000 -Codec ldac -Quality hq`. The verified
   run was 48 kHz.
2. **ABR.** Try `scripts\stream.ps1 -Abr` when the RF conditions vary; it maps
   to `-a` (LDAC / LHDC V5).
3. **GUI/tray app for daily use.** `a2dpwb.exe` exposes the same core with a
   UI; use it when a tray icon is preferable to a PowerShell window. The
   resident path is USB-only, so the emulator still needs `--cli`.
4. **Restore the Windows Bluetooth driver when not streaming.** Keep the
   adapter on WinUSB for frequent use, or run
   `scripts\usb-driver.ps1 -Mode restore` afterwards (D2). Windows Bluetooth
   (and any device using it) stays unavailable while A2DPWB owns the radio.

## First files a successor should read

1. `HANDOFF.md` (this file).
2. `README.md` — the verified section, the pairing procedure, the operating
   manual and the known blockers.
3. `scripts\stream.ps1` — the daily path; every flag maps to
   `upstream/app/src/core/src/cli.rs`.
4. `docs/DECISIONS.md` — D1..D9, especially D2 (restore), D5 (loopback vs
   virtual), D6 (LE Audio off / phone disconnected), D7 (error 50 is the
   WinUSB binding, not the firmware), D8 (headphones-only through a virtual
   render device) and D9 (an unpatched module opens but cannot stream).
5. `docs/HEADPHONES-ONLY.md` — the VB-CABLE recipe, verified evidence and the
   revert command (also the current state of this PC's default output).
6. `docs/UNPATCHED-MODULE.md` — the cold-boot finding and its reproduction.
7. `docs/ROOT-CAUSE.md` — the two independent causes with their evidence.
8. `docs/UPSTREAM-2.0.2.md` — what changed in 2.0.2-beta.4 and the measured
   firmware behaviour.
9. `scripts/doctor.ps1` — single source of truth for current state.
10. `docs/BUILD-FOR-SOURCE.md` — only if a build becomes necessary.
11. Upstream reference (read-only): `upstream/app/src/core/src/cli.rs` (every
    flag the launcher uses), `upstream/app/src/driver/src/main.rs` (helper CLI),
    `upstream/app/src/crates/bt-host/src/chips.rs` (chip table),
    `upstream/app/src/crates/core/src/adapter.rs` (the `chip:` log line).
