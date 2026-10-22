# Evidence

## `a2dpwb-diag-2.0.2-beta.5-rtl8852bu-scrubbed.zip`

The diagnostic bundle of the 2.0.2-beta.5 run on the internal Realtek
RTL8852BU, written by **Diagnostics > Report a problem > Save** in the app.

Scrubbed before publishing by `scripts/scrub-diagnostics.ps1` (reproducible,
not hand-made). What it removes:

| what | how |
|---|---|
| the user profile path (`C:\Users\<name>\`) | replaced with `%USERPROFILE%` (436 places) |
| every MAC-like address | replaced with `00:00:00:00:00:00` (2 places) |
| the adapter's USB serial `00E04C0000XX` | masked in the device path and in the 19 log lines that mention it |
| the USB instance id of an unrelated attached device | the whole id, including its serial tail |
| the raw address bytes in the HCI capture | zeroed (both byte orders) |

The script **refuses to write** an archive in which any identifier survives,
and the result was checked a second time with an independent scan: no
headset address, no adapter address, no user path, no serial - in any file,
text or binary.

The first version of this file was published before that check, and it still
held the headset's full address in two log lines, the adapter's USB serial in
19 lines and the instance id of an unrelated device. That was corrected on
#81; the file in this directory is the corrected one. The upstream bug behind
it is analysed in `docs/UPSTREAM-MASK-LEAK.md`.

What it contains: the app's own diagnostic text, the Windows/USB/audio
inventory, the core and UI logs of 2026-10-19 to 2026-10-21, the app
configuration (settings, profiles, known devices - **no link keys**), and the
HCI flight recorder.

The core log of 2026-10-21 holds the whole day, so the beta.4 behaviour and
the beta.5 behaviour sit next to each other:

```
12:24:48 INFO bt_host::app: Realtek firmware download ran (ROM LMP subversion 0x8852); not verified   <- beta.4
00:02:07 INFO bt_host::app: Realtek firmware loaded (LMP subversion 0x8852 -> 0xFD78)                  <- beta.5
```

See `docs/BETA5-VERIFICATION.md` for the full test.
