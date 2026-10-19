# Upstream issue draft

Post to: <https://github.com/SeiyaFunaokaJP/A2DP-Windows-Bridge/issues>

**Title:** Support for Realtek PID 0x4853 (RTL8852BU) + misleading "WinUSB error 50" when the Realtek firmware is missing

Copy the body below:

````markdown
### 1) Environment

- Windows 11 build 26100, x64.
- A2DP-Windows-Bridge **2.0.1**, stock release binaries (`a2dpwb.exe`, `a2dpwb-core.exe`, `a2dpwb-driver.exe`).
- Adapter: internal USB `USB\VID_0BDA&PID_4853` = Realtek **RTL8852BU**. It is a single USB function; the machine's Wi-Fi is a separate function and is unaffected.
- Headset: the headset, classic A2DP, address `<HEADSET_MAC>`, LE Audio switched **off** on the headset.
- The adapter is bound to WinUSB by `a2dpwb-driver.exe`; the Realtek firmware lives in `%APPDATA%\A2DPWB`.

### 2) What happens, and the real cause

The Adapter screen reports `chip: unknown (0x4853)`, so the setup flow cannot tell the user which firmware to fetch. The core then fails with:

```
USB: cannot claim interface 0 of 0BDA:4853: failed to initialize WinUSB (error 50)
```

`error 50` is `ERROR_NOT_SUPPORTED`, which reads like a WinUSB or driver problem. The **real cause is the missing Realtek firmware**: without it BTstack cannot boot the controller, so the HCI endpoints are never initialised and the interface claim fails.

Adding `rtl8852bu_fw.bin` and `rtl8852bu_config.bin` (plus the extension-less aliases `rtl8852bu_fw` / `rtl8852bu_config` that BTstack opens) into the config folder fixed it immediately — **no reboot and no administrator rights** were needed. The WinUSB binding itself was correct; the firmware was the only missing piece.

### 3) The specific gap: `REALTEK_CHIPS` has no entry for `0x4853`

BTstack's own table already maps this part (`extern/btstack/chipset/realtek/btstack_chipset_realtek.c:342`):

```c
{0x4853, 0x8852, "mp_rtl8852bu_fw", "rtl8852bu_fw", "rtl8852bu_config", NULL, 0, RTL8852BU}
```

but `app/src/crates/bt-host/src/chips.rs` (`REALTEK_CHIPS`) has no entry for `0x4853`. Adding one would let the app:

- say `chip: RTL8852BU (0x4853)` instead of `unknown`;
- tell the user to fetch `rtl8852bu_fw.bin` / `rtl8852bu_config.bin` (or offer the download) instead of leaving `error 50` as the only symptom;
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

So the BTstack / Realtek / WinUSB path is sound on an internal USB adapter. The two real gaps are the chip-table entry and the misleading firmware error.

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
