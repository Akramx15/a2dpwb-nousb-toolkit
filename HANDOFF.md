# Handoff — A2DP-Windows-Bridge on this PC, with NO external USB dongle

## Verdict

The goal is achieved on the hardware. **No USB Bluetooth dongle is needed.**
The PC's internal **Realtek RTL8852BU** (`USB\VID_0BDA&PID_4853\00E04C0000XX`) is a
plain USB HCI device and is driven directly by the project's user-mode BTstack
through the Microsoft-signed WinUSB driver. The only reason the project asks
for a "dedicated adapter" is to keep Windows' own Bluetooth alive at the same
time — not because the radio itself is special.

## Verified on this machine (evidence, not assumptions)

| Fact | Evidence |
|---|---|
| Adapter is USB, bound to WinUSB | `DEVPKEY_Device_Service = WINUSB`, `Status Started`, `ProblemCode 0` |
| WinUSB opens the adapter | `INFO USB: opened 0BDA:4853 ... (event 0x81, ACL 0x82/0x02)` |
| Controller is alive | `INFO controller: company 0x005D (Realtek), HCI version 11, LMP subversion 0xFD78` |
| Realtek firmware loads | `INFO Realtek firmware download ran (ROM LMP subversion 0x8852)` / later `Firmware already exists` |
| HCI comes up | `INFO HCI ready (took 102 ms)` |
| RF link to the real headset works | `INFO HCI ACL connection established to <HEADSET_MAC>` |
| Headphone address | `<HEADSET_MAC>` (the headset, from the old Windows pairing) |
| Zero-hardware path works | `--hci-tcp` + Bumble virtual controller: LDAC / SBC / aptX HD all reached `Streaming`, 0 dropped packets |

**The blocker that was fixed:** `failed to initialize WinUSB (error 50)`. Cause:
the Realtek firmware was missing, so BTstack could not boot the controller and
the adapter never came up. Fix: install `rtl8852bu_fw.bin` (129,733 B) and
`rtl8852bu_config.bin` (6 B) into `%APPDATA%\A2DPWB` (plus the extension-less
aliases `rtl8852bu_fw` / `rtl8852bu_config` that BTstack reads). No reboot, no
Administrator rights, no driver change were required for this.

**Remaining blocker (needs the user, 20 seconds of physical action):**
the headset still holds the **link key that Windows created** when it was
paired with the Windows Bluetooth stack. A2DPWB has no such key, so SSP
authentication fails (`signaling connection failed (0x66)` → "Authentication
failed, also after pairing again"). Fix: put the the headset into **pairing
mode** (hold the power button until the indicator flashes twice) and/or remove
it from Windows' device list, then retry.

## Done

* Toolkit repo (`work/a2dpwb-nousb`) with four PowerShell 5.1 scripts, two
  verified upstream patches, the operating manual, the build-from-source guide
  and the decision records.
* `scripts/doctor.ps1` — read-only state report + verdict.
* `scripts/fetch-realtek-fw.ps1` — validated firmware download (magic bytes) +
  extension-less aliases.
* `scripts/usb-driver.ps1` — wraps `a2dpwb-driver.exe` (assign/restore) and
  `pnputil /restart-device`; its CLI syntax was read from
  `upstream/app/src/driver/src/main.rs`, not guessed.
* `scripts/run-emulator.ps1` — hardware-free end-to-end run (LDAC/SBC/aptX HD).
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

## Next 3 concrete steps

1. Put the the headset in pairing mode, then run
   `a2dpwb-core.exe --cli -d <HEADSET_MAC> -c ldac --test-tone --duration 30`
   and confirm `Streaming` + a rising "Sent N media packets".
2. Switch from `--test-tone` to real system audio (drop `--test-tone`; the
   default capture mode is the system loopback) and set the playback format to
   96 kHz in Windows Sound settings for LDAC 990 kbps.
3. Decide the operating model: keep the adapter on WinUSB permanently (Windows
   Bluetooth off) vs. run `scripts\usb-driver.ps1 -Mode restore` when not
   streaming. Record the choice in `docs\DECISIONS.md` (D2).

## First files a successor should read

1. `HANDOFF.md` (this file).
2. `README.md` — how it fits together and the known blockers.
3. `docs/DECISIONS.md` — D1..D4, especially D2 (restore) and D4 (no build).
4. `scripts/doctor.ps1` — single source of truth for current state.
5. `docs/BUILD-FOR-SOURCE.md` — only if a build becomes necessary.
6. Upstream reference (read-only): `upstream/app/src/driver/src/main.rs`
   (helper CLI), `upstream/app/src/crates/bt-host/src/chips.rs` (chip table),
   `upstream/app/src/crates/core/src/adapter.rs` (the `chip:` log line).
