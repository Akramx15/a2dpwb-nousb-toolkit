# Handoff

## Done

* Toolkit repo (`work/a2dpwb-nousb`, branch `feature/nousb-windows-toolkit`)
  with four PowerShell 5.1 scripts, two verified upstream patches, the
  operating manual, the build-from-source guide and the decision records.
* `scripts/doctor.ps1` runs read-only and reports the real machine state.
* `scripts/run-emulator.ps1` (virtual sink, no hardware) and
  `scripts/fetch-realtek-fw.ps1` (validated firmware download) with `-DryRun`.
* `scripts/usb-driver.ps1` wraps `a2dpwb-driver.exe` (assign/restore) and
  `pnputil` (restart); its CLI syntax was read from
  `upstream/app/src/driver/src/main.rs`, not guessed.
* `patches/0001-...` and `patches/0002-...` apply cleanly to upstream
  (`git apply --check` passes). Upstream is untouched.

## Blocked

* **MSVC C++ workload missing** in `C:\BuildTools`: no `cl.exe`, so
  `cargo build` of the C parts fails. Only needed to build the chip-name
  patch into a binary; streaming with stock v2.0.1 does not need it.
* **WinUSB error 50 pending a reboot** after the earlier `assign`
  (`reboot_required: true`).
* **Firmware is installed and shape-valid** (129,733 bytes, not the 74,324-byte
  mirror build). If BTstack still fails to boot after the reboot, run
  `scripts\fetch-realtek-fw.ps1 -Force` to install the mirror build.
* `pnpm` and PowerShell 7 are absent: UI build and `build.ps1` are blocked;
  core/emulator are not.

## Next 3 concrete steps

1. **Reboot Windows**, then rerun `scripts\doctor.ps1` and verify the
   adapter opens (no `error 50`). Optionally
   `scripts\usb-driver.ps1 -Mode restart -Auto` from an elevated shell first.
2. Learn the headphones' MAC (`a2dpwb-core.exe --cli -l` before a driver
   switch, or Windows Settings) and run
   `a2dpwb-core.exe --cli -d <MAC> --test-tone --duration 10`; afterwards
   `scripts\usb-driver.ps1 -Mode restore -Auto`.
3. If BTstack still fails to boot the controller, run
   `scripts\fetch-realtek-fw.ps1 -Force` (installs the validated mirror
   firmware) and repeat step 1. Use the emulator meanwhile:
   `powershell -ExecutionPolicy Bypass -File scripts\run-emulator.ps1 -Codec ldac`.

## First files a successor should read

1. `HANDOFF.md` (this file).
2. `README.md` - how the whole thing fits together and the known blockers.
3. `docs/DECISIONS.md` - D1..D4, especially D2 (restore) and D4 (no build).
4. `scripts/doctor.ps1` - the single source of truth for current state.
5. `docs/BUILD-FOR-SOURCE.md` - only if a build becomes necessary.
6. Upstream reference (read-only): `upstream/app/src/driver/src/main.rs`
   (helper CLI), `upstream/app/src/crates/bt-host/src/chips.rs` (chip table),
   `upstream/app/src/crates/core/src/adapter.rs` (the `chip:` log line).
