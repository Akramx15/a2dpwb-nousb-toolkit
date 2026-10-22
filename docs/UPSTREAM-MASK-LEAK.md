# The diagnostics mask leak (upstream issue #81)

**Short version:** the "Report a problem > Save" bundle of upstream 2.0.2-beta.5
wrote the headset's full Bluetooth address and the adapter's USB serial into
the archive even with the mask on. Upstream fixed most of it in commit
`a4ce19d` (PR #134) after the report on #81 - but the two lines that actually
leaked in the bundle of #81 still leak with that fix. This document is the
analysis, the reproduction and a verified one-guard patch.

## Timeline

| When (UTC) | What |
|---|---|
| 2026-10-21 21:40 | our correction comment on #81 (`issuecomment-6327168792`): the published bundle still held the headset's full address in two log lines and the adapter's USB serial in 19 lines |
| 2026-10-21 23:32 | upstream commit `a4ce19d` - "Mask USB serial numbers and more address forms in diagnostics", PR #134 |
| 2026-10-22 00:05 | the maintainer replies: "I apologize for the issue regarding the mask leakage ... I will check it thoroughly once I get home from work" |

`a4ce19d` is on `develop-v2.x`. **No release contains it yet** - the newest
release is `v2.0.2-beta.5` (2026-10-21 17:27), which predates the fix.

## Where the leak was (upstream, not in this toolkit)

`app/src/core/src/bundle.rs` builds the archive of **Diagnostics > Report a
problem > Save** and runs every text file through the mask:

```rust
let text = |s: String| if mask { mask_addresses(&s) } else { s };
```

`mask_addresses` (`app/src/crates/core/src/diag.rs`) only knew one shape,
`AA:BB:CC:DD:EE:FF`, and refused an address that was part of a longer run.
Two things slipped through it:

1. **The headset's address, followed by a colon.** The two lines of the
   bundle are the LE Audio pairing lines:

   ```
   2026-10-19 22:40:59.133  INFO bt_host::le::core: LE Audio: 46:62:99:xx:xx:xx: pairing (Just Works)
   2026-10-19 22:41:05.586  WARN bt_host::le::core: LE Audio: 46:62:99:xx:xx:xx: pairing failed (0x13, reason 0x00), trying again
   ```

   The address is followed by `:`, so the guard that protects longer runs
   refused to mask it.

2. **The adapter's USB serial** `00E04C0000XX`. It is a 12-hex-digit word,
   not an address, so the old mask never touched it. It appears in the
   device path `USB\VID_0BDA&PID_4853\00E04C0000XX` and in the 19 log lines
   that mention the adapter.

## What `a4ce19d` fixes

The new `mask_identifiers` (core) / `maskIdentifiers` (UI) also mask:

- addresses with `-` and addresses that follow a letter (Windows' LE device ids)
- 12-hex-digit words (BTHENUM / BTHLE ids, serials that are an address)
- USB serial numbers in instance ids, device paths and driver record names
  (including the archive's `config/driver/` entry names)

Verified against the pre-scrub bundle of #81: the adapter's serial is masked
(`00E04Cxxxxxx`), and the `USB\VID_04E8&PID_6860&ADB\6&XXXXXXXX&2&0001` id of
an unrelated ADB device stays - that is upstream's deliberate choice ("IDs
Windows generates stay"), not a leak of the phone's serial.

## What `a4ce19d` still misses

The two lines of #81. The guard in `mask_separated_addresses` is

```rust
&& b.get(i + LEN).is_none_or(|&c| c != sep && !c.is_ascii_hexdigit());
```

It refuses **any** address that is followed by the separator - also when the
separator starts a word (`...4F: pairing`). Reproduced with upstream's own
code: the pre-scrub bundle of #81 comes out with the headset's full address
**twice**.

## The patch

`patches/0003-diag-mask-address-before-colon.patch` - one guard plus a
regression test, against upstream `a4ce19d`:

```rust
&& b.get(i + LEN).is_none_or(|&c| {
    // A separator after the address only continues the run when two
    // more hex digits follow it ("00:11:22:33:44:55:66"); a colon
    // that starts a word ("46:62:99:xx:xx:xx: pairing") is punctuation.
    (c != sep && !c.is_ascii_hexdigit())
        || (c == sep
            && !b.get(i + LEN + 1..i + LEN + 3)
                .is_some_and(|h| h.iter().all(u8::is_ascii_hexdigit)))
});
```

A run that really continues (`00:11:22:33:44:55:66`) is still left alone,
because two more hex digits follow the separator.

## How it was verified

The masking functions were taken out of upstream's `diag.rs` at `a4ce19d`
and compiled as they are, with `rustc` (the `stable-x86_64-pc-windows-gnu`
toolchain), and run against the **pre-scrub** archive of #81 (the blob
`a6817bc` of this repository's history, the file before the re-scrub).

| Check | upstream `a4ce19d` | with the patch |
|---|---|---|
| `logs/a2dpwb-core.2026-10-19.log` - full headset address | **2** | **0** |
| every other file of the archive | 0 | 0 |
| upstream's own tests `masks_addresses`, `masks_bare_addresses`, `masks_usb_serials` | pass | pass |
| the new test `masks_an_address_before_a_colon` | - | pass |
| `git apply` on upstream's file at `a4ce19d` | - | clean |

The masked line reads:

```
2026-10-19 22:40:59.133  INFO bt_host::le::core: LE Audio: 46:62:99:xx:xx:xx: pairing (Just Works)
```

## What this toolkit does about it

`scripts/scrub-diagnostics.ps1` scrubs the archive before it is published -
it masks the addresses, the USB serial and the other instance ids, and it
refuses to write an archive in which any identifier survives. The bug above
is upstream's, and it is why the script exists.
