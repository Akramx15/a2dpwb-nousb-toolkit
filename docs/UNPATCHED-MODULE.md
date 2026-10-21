# An unpatched RTL8852BU opens the adapter but cannot stream

Date: 2026-10-20. Build: A2DP-Windows-Bridge **2.0.2-beta.1** (NSIS,
`currentUser`). Adapter: internal Realtek RTL8852BU
(`USB\VID_0BDA&PID_4853\00E04C0000XX`). Headset: the headset,
`<HEADSET_MAC>`, classic A2DP, LDAC. Paths are sanitized.

**Scope.** This is an observation on this machine, with this part and this
build — not a general claim about every Realtek controller. The mechanism
(ROM code serves HCI; firmware patches the controller) is how BTstack's Realtek
driver works, but the streaming failure below was measured here only.

> **2.0.2-beta.4 update.** The alias detail below is beta.1 behaviour.
> 2.0.2+ uses the `.bin` files and removes identical extension-less copies on a
> scan (PR #97), so the current scripts expect no aliases and restore only the
> two `.bin` files. The
> ROM-mode observation itself still holds; the current evidence is in
> `docs/UPSTREAM-2.0.2.md`.

## What happens

A real Windows reboot with all four firmware files removed from
`%APPDATA%\A2DPWB` (`rtl8852bu_fw`, `rtl8852bu_config`, and both `.bin` files),
so the module boots cold in ROM mode (`ROM LMP subversion 0x8852`):

1. **The adapter opens and HCI comes up.** The Realtek ROM code serves HCI
   without the firmware patch. This is not `error 50` and not an open failure.
2. **The app names the missing files** — two
   `WARN firmware file missing: ...` lines, one per file.
3. **The A2DP stream does not establish.** The run never reaches
   `state Streaming: Connected` and never prints a `Sent ... media packets`
   line.

Restoring only the two `.bin` files — still the same cold module, no reboot —
changed all of it:

* the app recreated the extension-less aliases BTstack opens,
* the firmware upload ran (`download ran: True`),
* the LDAC stream ran with **0 dropped** packets.

So the missing firmware is **not** an "adapter cannot open" condition. It is an
"adapter opens, streaming fails" condition.

## Evidence

Cold-boot round 2 (`-Mode Missing`, real reboot, 2.0.2-beta.1):

| Phase | `%APPDATA%\A2DPWB` in that phase | Result |
|:--|:--|:--|
| 1 | nothing | `adapter opened: True`, `open failed: False`, 2 missing-file warnings, **no stream** |
| 2 | only the two `.bin` files (no aliases) | `ROM LMP subversion: 0x8852; download ran: True; alias fw/config: True/True; adapter opened: True` |
| 3 | aliases recreated, firmware uploaded (patched) | `packets=3759 bytes=2529807 dropped=0; streaming=True` |

Phase 1 verdict and the named diagnostics (paths sanitized):

```
[PASS (note)] phase 1: the app names the missing firmware files
missing-file warnings: 2; named fw/config: True/True; adapter opened: True; open failed: False
WARN firmware file missing: %APPDATA%\A2DPWB\rtl8852bu_fw.bin
WARN firmware file missing: %APPDATA%\A2DPWB\rtl8852bu_config.bin
```

Its informational stream probe in the same phase:

```
[INFO] phase 1: stream on an unpatched module (informational)
stream on an unpatched module: failed with + FullyQualifiedErrorId : NativeCommandError ...
```

The captured detail behind that line is polluted by a PowerShell
`NativeCommandError` record, so it proves the **outcome** (no stream), not the
reason. The same boot produced both outcomes — no stream without the firmware,
a clean stream once the `.bin` files returned — so the reason is not claimed
here.

HCI came up on the cold ROM module (earlier cold run, same build):

```
INFO HCI ready (took 102 ms)
```

The app names the files because 2.0.2-beta.1 carries the chip-table fix from
PR #82: 2.0.1 printed `chip: unknown (0x4853)` and could not name them
(`docs/ROOT-CAUSE.md`).

## Reproduction

1. Close the app (no `a2dpwb-core.exe` running).
2. Back up the four files. The script restores from
   `%APPDATA%\A2DPWB-coldboot-backup` and exits 2 if that folder is missing:

   ```powershell
   $cfg = Join-Path $env:APPDATA 'A2DPWB'
   $bak = Join-Path $env:APPDATA 'A2DPWB-coldboot-backup'
   New-Item -ItemType Directory -Force -Path $bak | Out-Null
   Copy-Item -Path (Join-Path $cfg 'rtl8852bu*') -Destination $bak
   Remove-Item -Path (Join-Path $cfg 'rtl8852bu*')
   ```

3. Reboot Windows for real. A warm module keeps the uploaded firmware in RAM
   and proves nothing.
4. Run:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\cold-boot-test.ps1 -Mode Missing
   ```

5. Expected phase 1: `adapter opened: True`, two `firmware file missing`
   warnings, and the informational stream probe reports failure. Phase 1's
   verdict is the named diagnostics, not an open failure (`PASS (note)`).
6. Expected phase 2: with only the `.bin` files back, `download ran: True`, both
   aliases recreated, adapter opened.
7. Expected phase 3: the LDAC stream runs with 0 dropped packets.

The beta.1 script restored all four files from
`%APPDATA%\A2DPWB-coldboot-backup` at the end; the current scripts restore only
the `.bin` files on 2.0.2+ (`-LegacyAliases` remains for 2.0.1). Verify with
`Get-ChildItem %APPDATA%\A2DPWB\rtl8852bu*`.

## What it means for the user experience

* **"The adapter opened" is not proof that the firmware was loaded.** Both can
  be true at once: device present, HCI ready, stream dead.
* **The `firmware file missing` warning is the decisive signal.** In
  2.0.2-beta.1 it appears in the log and in the GUI's firmware banner. If the
  stream fails and those warnings are present, install the firmware; do not
  chase WinUSB, the driver, or pairing.
* **The reverse is also true:** once the warnings are gone and the upload ran,
  the same cold module streams. The fix is the files, not a driver change.
* `scripts/cold-boot-test.ps1` treats the phase-1 stream probe as
  **informational** (`INFO`, never affects the verdict), because phase 1's job
  is to check the diagnostics. The verdict for this case belongs in phase 3.

## Related

* `docs/ROOT-CAUSE.md` — why `error 50` is the WinUSB binding, not the firmware.
* `docs/UPSTREAM-BETA-TEST.md` — the 2.0.2-beta.1 test report and the warm
  module observation.
* `docs/DECISIONS.md` — D7 (independent causes) and D9 (this finding).
