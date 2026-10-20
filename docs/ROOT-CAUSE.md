# Root cause: two independent conditions, not one

Date: 2026-10-20. Scope: `failed to initialize WinUSB (error 50)` and the
missing Realtek firmware on the internal RTL8852BU
(`USB\VID_0BDA&PID_4853`).

The first write-up said the missing Realtek firmware was the root cause of
error 50. A cold-boot experiment disproved that. The two conditions are
independent, they were observed minutes apart, and the firmware got the credit
for a re-enumeration that happened at the same time.

## Cause 1 - error 50 is the WinUSB binding not being live yet

`error 50` is `ERROR_NOT_SUPPORTED`. It is not a driver fault and not a
firmware fault: the binding the helper just wrote is not active until Windows
has re-enumerated the device.

Evidence:

* the helper's own record for the assign says `"reboot_required": Bool(true)`;
* upstream re-enumerates the device at that point
  (`uninstall_and_reenumerate(...)` in
  `app/src/crates/win-sys/src/driver.rs:359`);
* the first scan 7 s after the assign failed with
  `failed to initialize WinUSB (error 50)`; the same adapter opened as soon as
  the device was re-enumerated, with no other change;
* upstream's own remedy for an adapter that does not answer is "Unplug the
  adapter, plug it back in and try again" (`docs/usage.md:472`).

Reproduce: `assign` the adapter and try to open it before Windows has
re-enumerated it.

Fix: let the re-enumeration happen - unplug/replug,
`scripts\usb-driver.ps1 -Mode restart`, or a reboot.

## Cause 2 - the missing firmware leaves the module in ROM mode

This is real, but it is not an open failure. Cold-boot round 2 (real Windows
reboot, all four firmware files removed from `%APPDATA%\A2DPWB` beforehand,
build 2.0.2-beta.1):

| Phase | `%APPDATA%\A2DPWB` | Result |
|---|---|---|
| 1 | nothing | the adapter **opened** and HCI came up, with both `firmware file missing` warnings |
| 2 | only the `.bin` files | the app recreated the extension-less aliases, uploaded the firmware and re-opened the adapter |
| 3 | patched module | LDAC, 3,783 packets, 0 dropped |

Phase 1:

```
INFO USB: opened 0BDA:4853 ... (event 0x81, ACL 0x82/0x02)
INFO HCI ready (took 102 ms)
WARN firmware file missing: %APPDATA%\A2DPWB\rtl8852bu_fw.bin
WARN firmware file missing: %APPDATA%\A2DPWB\rtl8852bu_config.bin
```

Phase 2:

```
ROM LMP subversion: 0x8852; download ran: True
alias rtl8852bu_fw: True; alias rtl8852bu_config: True
```

The Realtek ROM code serves HCI well enough for the adapter to open and for
HCI to become ready. Without the firmware the chip simply stays in ROM mode:
not patched. Full transcript: `docs/UPSTREAM-BETA-TEST.md`.

What 2.0.1 could not do was *name* the files, because `REALTEK_CHIPS` in
`app/src/crates/bt-host/src/chips.rs` has no entry for PID `0x4853` (issue #81).
PR #82 / 2.0.2-beta.1 adds the entry and prints
`WARN firmware file missing: ...`, which is the right signal for this case.

Reproduce: remove all four files (`rtl8852bu_fw`, `rtl8852bu_config`, both
`.bin`) from `%APPDATA%\A2DPWB`, reboot, then run:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\cold-boot-test.ps1 -Mode Missing
```

Phase 1 is expected to open the adapter and print the two warnings. Phase 2
restores the `.bin` files and expects the app to recreate the aliases and
upload the firmware; the script restores all four files at the end.

## Why the wrong cause was believable

The firmware install and the successful open happened in the same sitting. The
install triggered a re-enumeration, the adapter opened after it, and the
firmware looked causal. Nothing in the logs separated the two events, and the
warm module keeps firmware in RAM, so a later run with the files deleted still
opened - which was then explained away as "the firmware is only needed on a
cold module". The cold boot disproved that explanation.

## Lesson

Do not infer a cause from a correlation observed minutes apart, especially when
two changes happen in the same window. Separate the variables: one run with
the firmware missing and a cold module (cause 2 isolated), one run with the
binding not yet live and the firmware present (cause 1 isolated).
