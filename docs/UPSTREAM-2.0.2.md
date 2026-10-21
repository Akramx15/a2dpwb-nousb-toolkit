# Upstream 2.0.1 -> 2.0.2-beta.5: what changed for this toolkit

Date: 2026-10-21. Target build: **A2DP-Windows-Bridge 2.0.2-beta.4** on the
internal Realtek RTL8852BU (`USB\VID_0BDA&PID_4853`). This note records the
changes the scripts and the documented expectations depend on; the historical
2.0.1/beta.1 evidence stays in `docs/ROOT-CAUSE.md` and
`docs/UPSTREAM-BETA-TEST.md`.

## Summary

| Area | 2.0.1 | 2.0.2-beta.4 |
|:--|:--|:--|
| WinUSB `error 50` | binding not live until Windows re-enumerated the device; the record said `reboot_required: true` | **retired**: the app restarts the device itself after the assign (`reboot_required: false`) |
| Chip naming | `chip: unknown (0x4853)` | every PID of a known Realtek family resolves from BTstack's firmware table |
| Missing firmware | not named; the user saw only an open failure | named per file, plus the **Firmware not loaded** state and "the adapter is running without its Realtek firmware" |
| Firmware install | manual download | the app can download from linux-firmware itself (pinned commit, SHA-256 checked) |
| ROM code | not detected | detected (`ROM LMP subversion`) and reported |
| File names | BTstack opened extension-less copies (`rtl8852bu_fw`, `rtl8852bu_config`) | the `.bin` files are used; extension-less copies are obsolete and identical ones are removed on a scan |

Upstream references: PR #82 (every PID of a family), #88 (device restart after
the WinUSB assign, `reboot_required: false`, "Firmware not loaded"), #92
(app-side firmware download from linux-firmware, pinned commit + SHA-256), #94
(ROM-code detection and the new messages), #97 (extension-less copies
obsolete).

## 1. The `error 50` path is gone

`failed to initialize WinUSB (error 50)` was never a firmware symptom: it meant
the WinUSB binding was not live until the device was re-enumerated. 2.0.2+
performs that re-enumeration itself after the assign. The driver record now
reports:

```
reboot_required: false
```

Verified on this machine: the adapter opened immediately after the assign, the
module went to ROM, and the app re-uploaded the firmware in the same run. No
manual unplug/replug or reboot is part of the expectation any more. The
historical account and the reason the two conditions were once confused remain
in `docs/ROOT-CAUSE.md`.

## 2. Every PID of a known family resolves

`REALTEK_CHIPS` is no longer a hand-maintained short list. The mapping is
derived from BTstack's own firmware table at build time, so every PID of a
known family is recognised. On this adapter the log line is now:

```
chip: RTL8852BU (0BDA:4853 -> 0xB85B) (auto)
```

The patches in `patches/` remain only as a reference for building 2.0.1 from
source and must not be applied to 2.0.2 or newer.

## 3. Missing firmware is named and surfaced

With the files absent, the app prints one warning per missing file:

```
WARN firmware file missing: %APPDATA%\A2DPWB\rtl8852bu_fw.bin
WARN firmware file missing: %APPDATA%\A2DPWB\rtl8852bu_config.bin
```

and the UI/log exposes the **Firmware not loaded** state, including "the
adapter is running without its Realtek firmware". The Realtek ROM code still
serves HCI, so the adapter can open and HCI can become ready while the module
is unpatched. On a cold module the A2DP stream does not establish until the
firmware is uploaded.

## 4. The app can fetch the firmware itself

2.0.2+ can download the Realtek firmware from `linux-firmware` at a pinned
commit and verifies the SHA-256 before using it. `scripts\fetch-realtek-fw.ps1`
remains useful for offline/controlled installs and for validating the magic
bytes, but it is no longer the only way to obtain the files.

## 5. ROM-code detection

The core reports the ROM LMP subversion (`0x8852` for this family) and whether
the firmware download ran. That is the marker the cold-boot scripts use to
separate "cold module, firmware uploaded" from "warm module, download skipped".

## 6. Extension-less copies are obsolete (PR #97)

2.0.1 relied on `rtl8852bu_fw` / `rtl8852bu_config` (no extension). 2.0.2+
uses the `.bin` files and does not need those copies; the app removes identical
copies on a scan.

Observed twice on this machine: with four files present (two `.bin` plus two
copies), one `a2dpwb-core.exe --cli --scan` left only the two `.bin` files,
with their original timestamps. Recreating the copies with
`fetch-realtek-fw.ps1 -LegacyAliases` and scanning again removed them again.
BTstack still logs the extension-less stem path during firmware setup even when
the copies are absent; that line is the configured name, not proof that the
file exists. A separate config folder holding only the two `.bin` files opened
the adapter and created no copies.

Observed on a cold module after a Windows reboot, with the files removed: the
app named both missing `.bin` files, the adapter still opened (HCI ready) and
the A2DP stream did not establish. After restoring **only** the two `.bin`
files, the same cold module uploaded the firmware (`Realtek firmware download
ran (ROM LMP subversion 0x8852)`), opened the adapter and ran the LDAC stream
with 0 dropped packets (3,765 packets). **No extension-less copies were created
and none are needed.**

## 7. Toolkit consequences

* `scripts\fetch-realtek-fw.ps1` writes only the two `.bin` files by default.
  `-LegacyAliases` is opt-in for 2.0.1 and older; it creates the
  extension-less copies they still open.
* `scripts\cold-boot-test.ps1` and `scripts\cold-boot-round2.ps1` adapt to the
  installed version. On 2.0.2+ the correct result is: the `.bin` files are
  sufficient, extension-less copies **absent**, firmware downloaded, adapter
  opened. "No copies created" is a pass, not a failure. On 2.0.1 the legacy
  copies are the expectation.
* Both cold-boot scripts write the raw app output of every phase to
  `<output>.phase1.log`, `<output>.phase2.log` and `<output>.phase3.log`, so
  decisive lines are never lost to summarising. `cold-boot-round2.ps1` also
  redirects the post-reboot summary to `<output>`.
* `scripts\cold-boot-round2.ps1` requires only the two `.bin` files, backs up
  and removes exactly the files it found, and restores exactly those.
* `scripts\doctor.ps1` reports the inspected app version (for example
  `2.0.2-beta.4`), treats the `.bin` files as required on 2.0.2+ and reports
  the extension-less copies as optional/obsolete.

## 8. Residual notes

* This toolkit targets **2.0.2-beta.5**; 2.0.1 remains supported only through
  the `-LegacyAliases` path and the legacy expectations in the cold-boot
  scripts.
* The `reboot_required` field can still read `true` in an old driver record
  written by an earlier helper. With 2.0.2+ that indicates a stale record, not
  a required reboot.

## 9. 2.0.2-beta.5 (what changed since beta.4)

Pre-release, published 2026-10-21. It becomes **2.0.2** once the author
confirms it on real hardware.

### The firmware moved to its own folder

```
INFO firmware file ...\A2DPWB\rtl8852bu_fw.bin moved to ...\A2DPWB\firmware\rtl8852bu_fw.bin
INFO firmware file ...\A2DPWB\rtl8852bu_config.bin moved to ...\A2DPWB\firmware\rtl8852bu_config.bin
INFO bt_host::app: Realtek adapter PID 0xB85B, firmware folder ...\A2DPWB\firmware
```

The loose files in the config folder are moved **once**, on the first run of
the new build. The UI gained **Settings > Open Firmware Folder**. Downloads are
cached in `%TEMP%\A2DPWB_cache`. The toolkit now resolves the firmware folder
automatically (the `firmware` subfolder when it exists, the config folder
otherwise), and `-FirmwareDir` overrides it.

### The ROM state is reported instead of a misleading "download ran"

This was reported on
[issue #81](https://github.com/SeiyaFunaokaJP/A2DP-Windows-Bridge/issues/81)
and landed as **PR #113**. On beta.4 a cold module with the firmware files
missing printed

```
INFO Realtek firmware download ran (ROM LMP subversion 0x8852); not verified
```

although no download was possible. On beta.5 the same situation prints the
file-based warning and a truthful state:

```
WARN firmware file missing: ...\A2DPWB\firmware\rtl8852bu_fw.bin
WARN firmware file missing: ...\A2DPWB\firmware\rtl8852bu_config.bin
INFO Realtek firmware already running from an earlier session (LMP subversion 0xFD78), download skipped
```

`download ran` is gone, and the Adapter screen and the Home bar now carry the
ROM state (`Realtek firmware NOT loaded (... rtl8852bu_fw.bin missing in ...)`).

### Other changes worth knowing

* The version read right after a download is retried for up to 2 s.
* `rtl8852bu_config.bin` is unchanged: **linux-firmware has no config file for
  the RTL8852BU**, so the 0-byte file the app writes is correct and BTstack
  falls back to the efuse settings. The toolkit documents this.
* Fixes for the core crash on a stream right after another (#130), the black
  window with RivaTuner (#126), "headphones turned off" (#117, #123, #128), the
  repeated "put the device into pairing mode" (#120), occasional crackles
  (#122), AAC as LATM (#112) and the profile card offering "Connect" again
  after an error (#118).
* A diagnostic bundle can be written from **Diagnostics > Report a problem >
  Save**; the core also writes one itself when it stops.

### How to look at the firmware folder

```
Settings > Open Firmware Folder
```

or, from a shell:

```powershell
Get-ChildItem "$env:APPDATA\A2DPWB\firmware"
```
