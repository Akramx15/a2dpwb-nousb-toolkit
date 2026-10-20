# Upstream issue draft

Post to: <https://github.com/SeiyaFunaokaJP/A2DP-Windows-Bridge/issues>

**Title:** Support for Realtek PID 0x4853 (RTL8852BU) + a log hint when the Realtek firmware is missing

Copy the body below:

````markdown
### 1) Environment

- Windows 11 build 26100, x64.
- A2DP-Windows-Bridge **2.0.1**, stock release binaries (`a2dpwb.exe`, `a2dpwb-core.exe`, `a2dpwb-driver.exe`).
- Adapter: internal USB `USB\VID_0BDA&PID_4853` = Realtek **RTL8852BU**. It is a single USB function; the machine's Wi-Fi is a separate function and is unaffected.
- Headset: the headset, classic A2DP, address `<HEADSET_MAC>`, LE Audio switched **off** on the headset.
- The adapter is bound to WinUSB by `a2dpwb-driver.exe`; the Realtek firmware lives in `%APPDATA%\A2DPWB`.

### 2) What happens, and the corrected cause

The Adapter screen reports `chip: unknown (0x4853)`, so the setup flow cannot
tell the user which firmware to fetch. The core then failed with:

```
USB: cannot claim interface 0 of 0BDA:4853: failed to initialize WinUSB (error 50)
```

`error 50` is `ERROR_NOT_SUPPORTED`, which reads like a WinUSB or driver
problem. It is neither that nor the firmware: it means the **WinUSB binding is
not live yet**. The helper flags that at assign time — its driver record says
`"reboot_required": true`, the restart flag `DiInstallDevice` returns
(`app/src/crates/win-sys/src/driver.rs:442`, returned at `:444`) — so the new
driver is not bound to the running device node until Windows re-enumerates it.
The first scan 7 seconds after the assign failed with error 50; the same adapter
opened as soon as it was re-enumerated, with no other change. Your own remedy
for an adapter that does not answer is "Unplug the adapter, plug it back in and
try again" (`docs/usage.md`).

The missing Realtek firmware is a **separate** issue and does not produce error
50. Cold-boot test (a real Windows reboot, all four firmware files removed from
`%APPDATA%\A2DPWB` beforehand, build 2.0.2-beta.1):

- with no firmware on disk the adapter opened and HCI came up:
  `INFO USB: opened 0BDA:4853 ... (event 0x81, ACL 0x82/0x02)` /
  `INFO HCI ready (took 102 ms)`, alongside
  `WARN firmware file missing: %APPDATA%\A2DPWB\rtl8852bu_fw.bin` and
  `WARN firmware file missing: %APPDATA%\A2DPWB\rtl8852bu_config.bin`;
- after restoring only the `.bin` files, the app recreated the extension-less
  aliases, uploaded the firmware and re-opened the adapter:
  `ROM LMP subversion: 0x8852; download ran: True` and
  `alias rtl8852bu_fw: True; alias rtl8852bu_config: True`.

The Realtek ROM code therefore serves HCI well enough for the adapter to open.
The missing firmware means the module stays in **ROM mode** — the chip is not
patched — not that the adapter cannot open. What 2.0.1 could not do is *name*
the files, because of the chip-table gap in section 3; the
`firmware file missing` warning in 2.0.2-beta.1 is exactly the signal that case
needs.

### 3) The specific gap: `REALTEK_CHIPS` has no entry for `0x4853`

BTstack's own table already maps this part (`extern/btstack/chipset/realtek/btstack_chipset_realtek.c:342`):

```c
{0x4853, 0x8852, "mp_rtl8852bu_fw", "rtl8852bu_fw", "rtl8852bu_config", NULL, 0, RTL8852BU}
```

but `app/src/crates/bt-host/src/chips.rs` (`REALTEK_CHIPS`) has no entry for `0x4853`. Adding one would let the app:

- say `chip: RTL8852BU (0x4853)` instead of `unknown`;
- tell the user to fetch `rtl8852bu_fw.bin` / `rtl8852bu_config.bin` (or offer the download) instead of leaving the missing firmware unnamed;
- list this chip as verified on the Adapter screen.

BTstack itself does not need the app table — it already loads `rtl8852bu_fw` — but the UI and the setup guidance do.

### 4) Setup-guide wording: internal adapters are fine

The setup guide says *never assign WinUSB to the PC's built-in Bluetooth adapter*. On this machine the built-in radio is a USB Realtek RTL8852BU and it works fine, including LDAC. The real consequence is narrower: while A2DPWB holds the adapter, **Windows' own Bluetooth stops working** (Bluetooth settings, mice, keyboards, other audio devices). Suggest wording such as *"expect to lose Windows Bluetooth until you stop A2DPWB and restore the driver"*, instead of a blanket prohibition. A single-radio laptop is a legitimate target.

### 5) First connection on LE-Audio-capable headsets (troubleshooting note)

For a headset that also implements LE Audio (the headset), the classic A2DP source path failed twice, with two different L2CAP result codes:

- `signaling connection failed (0x66)` = `L2CAP_CONNECTION_RESPONSE_RESULT_REFUSED_SECURITY`: the headset still held the link key created by Windows' Bluetooth stack, so A2DPWB's SSP authentication was refused.
- `0x67` = `L2CAP_CONNECTION_RESPONSE_RESULT_REFUSED_RESOURCES`: the headset's AVDTP channel was already occupied because it was still connected to another device (phone) with LE Audio on.

The sequence that worked: disable **LE Audio** on the headset, **disconnect the phone** (and any other device), then put the headset in **pairing mode** and connect once. After that the stored link key makes reconnects automatic — no pairing mode is needed on later runs. A short note in the setup guide — *"the first connection needs pairing mode; later ones do not"* — would save users from reading `0x66` / `0x67` as an A2DPWB bug.

### 6) Confirmation that it works

With the firmware in place, the same stock binaries stream over the internal adapter with no dongle:

- LDAC, 990 kbps, 48 kHz, 24-bit;
- 56,285 media packets, 0 dropped over a 5-minute session;
- stable `state Streaming: Connected`, confirmed by ear.

So the BTstack / Realtek / WinUSB path is sound on an internal USB adapter. The two real gaps are the chip-table entry and a nameable missing-firmware warning.

Thanks for A2DPWB — it is the only Windows A2DP source I found that actually reaches LDAC over a user-mode BTstack controller. The report above is meant to make that path easier to reach for the next person; I am happy to test a patch or provide logs.
````

## How this was produced

The report comes from a real session on the machine described above (stock
A2DPWB 2.0.1 binaries, the internal RTL8852BU, the the headset). Every log line
quoted was observed during that session; the packet count is the core's own
end-of-run summary. The headset address is redacted as `<HEADSET_MAC>`, the
link key is not included, and there are no personal paths.

The companion toolkit used for the checks, the firmware fetch and the
reproducible procedure is at <https://github.com/Akramx15/a2dpwb-nousb-toolkit>.
