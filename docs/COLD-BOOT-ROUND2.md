# Cold-boot round 2: verification on this machine

Date: 2026-10-20. Build: A2DP-Windows-Bridge **2.0.2-beta.1** (portable),
`work/beta-2.0.2-beta.1/A2DPWB-2.0.2-beta.1/a2dpwb-core.exe`, version
`2.0.2-beta.1`, beta = yes. Paths below are sanitized (`%APPDATA%`,
`%LOCALAPPDATA%`, `<repo>`); the numbers and log lines are verbatim.

This run was **warm**, so the sections below record the warm path and the
driver plan. The cold run itself was done later, after a real reboot, with all
four files removed beforehand; its result is in `docs/UPSTREAM-BETA-TEST.md`
("Round 2") and in `docs/ROOT-CAUSE.md`.

## 1. Parse check (PowerShell 5.1 parser)

```
cold-boot-test.ps1: PARSE OK
cold-boot-round2.ps1: PARSE OK
```

## 2. Dry run

```
core     : <repo>\work\beta-2.0.2-beta.1\A2DPWB-2.0.2-beta.1\a2dpwb-core.exe
source   : default: portable beta
version  : 2.0.2-beta.1
beta     : yes (2.0.2+ / beta)
firmware : 4 of 4 file(s) present in the config folder
mode     : Present (from Auto)
headset  : <HEADSET_MAC> (from devices.txt)
```

Exit code 0. `-RequireBeta` against the installed 2.0.1 correctly exits 2:

```
ERROR: -RequireBeta was given but '...\a2dpwb-core.exe' reports version '2.0.1' (not 2.0.2+).
```

## 3. Real run (`-RequireBeta`, warm, files present)

```
== Phase 1 - module cold and firmware present
   [PASS (note)] phase 1: module is cold and the firmware was uploaded
   warm module ('Firmware already exists' / download skipped): this run cannot
   prove the cold+present case. Reboot and rerun for that.

== Phase 2 (informational) - firmware files removed
   moved away: rtl8852bu_fw, rtl8852bu_config, rtl8852bu_fw.bin, rtl8852bu_config.bin
   [PASS (note)] phase 2: the app names the missing firmware files
   warm module opened although all four files were missing - EXPECTED, not a
   failure. The beta named the files. missing-file warnings: 2;
   log: WARN firmware file missing: %APPDATA%\A2DPWB\rtl8852bu_fw.bin
        WARN firmware file missing: %APPDATA%\A2DPWB\rtl8852bu_config.bin
   firmware restored after the probe: all four files

== Phase 3 - .bin files in place, aliases recreated, then stream
   [PASS] phase 3: the app recreates the extension-less aliases and opens the adapter
   alias rtl8852bu_fw: True; alias rtl8852bu_config: True; adapter opened: True

== Phase 3b - stream
   [PASS] phase 3b: the ldac stream runs with 0 dropped packets
   packets=3766 bytes=2534518 dropped=0; streaming=True

== Firmware restore check
   [PASS] restore: all four firmware files exist in the config folder

RESULT: all 5 checks behaved as expected (2 pass-with-note).
```

Exit code 0.

## 4. Missing code path (forced, warm module)

`-Mode Missing -RequireBeta -StreamSeconds 5` was run to exercise the branch
without a reboot. It moved the files to the backup, observed the beta naming
them, restored the `.bin` files, recreated the aliases, streamed with 0
dropped packets and restored all four files:

```
phase 1 NOTE  warm module: it opened although all four files were missing
phase 2 NOTE  warm module: aliases and open OK, download skipped as expected
phase 3 PASS  packets=969 bytes=652137 dropped=0; streaming=True
restore PASS  all four firmware files exist
RESULT: all 4 checks behaved as expected (2 pass-with-note).
```

Exit code 0. This proves the branch and the restore logic; it does **not**
exercise the cold path (the module was warm). The cold result after a real
reboot is in `docs/UPSTREAM-BETA-TEST.md` ("Round 2").

## 5. Round-2 driver plan (`-WhatIf`)

```
core     : ...\beta-2.0.2-beta.1\A2DPWB-2.0.2-beta.1\a2dpwb-core.exe
version  : 2.0.2-beta.1 [beta]
headset  : <HEADSET_MAC>
firmware : 4 of 4 present
output   : <repo>\work\cold-boot-round2.txt
backup   : %APPDATA%\A2DPWB-coldboot-backup
startup  : %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\a2dpwb-cold-boot-round2.cmd
   1. copy the four firmware files to the backup
   2. write the self-deleting Startup entry
   3. remove all four files from the config folder
   4. run: shutdown.exe /r /t 30 /c "A2DP Windows Bridge cold-boot round 2"
```

Exit code 0; nothing was changed.

## 6. Final machine state

All four files are back in `%APPDATA%\A2DPWB`:

| File | Bytes | SHA-256 (first 16) |
|---|---|---|
| `rtl8852bu_fw` | 129733 | `C2B0D34A4FF8A8EA` |
| `rtl8852bu_fw.bin` | 129733 | `C2B0D34A4FF8A8EA` |
| `rtl8852bu_config` | 6 | `6C28A3F07C6A30ED` |
| `rtl8852bu_config.bin` | 6 | `6C28A3F07C6A30ED` |

The test-created backup folder was removed again, and the Startup folder has
no `a2dpwb-cold-boot-round2.cmd` (only the pre-existing entries). These checks
scheduled no reboot.
