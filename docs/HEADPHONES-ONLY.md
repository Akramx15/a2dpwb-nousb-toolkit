# Headphones only: route PC audio through VB-CABLE

Date: 2026-10-20. Build: A2DP-Windows-Bridge **2.0.2-beta.1** (official NSIS
installer, `currentUser` mode). Adapter: internal Realtek RTL8852BU. Headset:
the headset, `<HEADSET_MAC>`, classic A2DP. Paths are sanitized
(`%APPDATA%`, `%LOCALAPPDATA%`); endpoint ids are placeholders — read yours
with `-List` (step 2). This is the recipe that was actually run on this PC.

## Revert first — the footgun

With `CABLE Input` as the Windows default output, **the PC has no sound at all
while the app is not streaming**. The cable plays nowhere and nothing captures
it. Put the physical output back before you walk away:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\set-default-audio.ps1 `
  -Restore -Device "Speakers (Realtek(R) Audio)"
```

`-Restore` alone is the intended revert, but on this PC it exits 2: two
candidates are active (`Speakers (Realtek(R) Audio)` and the Boom 3D wrapper
`Speakers (Boom Audio)`) and the script refuses to guess. Naming the physical
endpoint is one command and deterministic. Add `-WhatIf` to see the plan
without changing anything.

## Why the PC speakers play at all

The default capture mode is a WASAPI **loopback of the default output device**.
Upstream states the consequence in `docs/usage.md` (line 190):

> System Loopback copies the audio; it does not take it away from the default
> output device. The audio keeps playing on that device (speakers, an HDMI TV,
> ...) as well as on the Bluetooth headphones. To hear it only on the
> headphones, use Virtual Device mode with a device that does not play
> anywhere, such as VB-CABLE.

Loopback taps the render mix; a tap is not a mute. The same text also describes
the mechanism that removes the speaker copy: capture a device whose output goes
nowhere.

## What upstream says to use

* **Virtual Device** mode, with a render device that does not play anywhere
  (`docs/usage.md`, Capture Modes).
* **Auto-switch default device** makes the selected device the Windows default
  output while streaming and switches back when streaming stops
  (`docs/usage.md`). The CLI sets this for classic A2DP
  (`app/src/core/src/cli.rs:413`, `auto_switch: true`).
* The profile editor's **Audio Device** list shows only the devices A2DPWB
  detects as virtual; without one it offers **Download VB-Cable**
  (`docs/usage.md`).

A virtual cable is the supported answer because the app has no virtual output
device of its own (`docs/usage.md`, "Why A2DPWB has no virtual output device of
its own").

## Step 1 — install VB-CABLE (once)

1. Get the official package from VB-Audio: <https://vb-audio.com/Cable/>,
   file `VBCABLE_Driver_Pack45.zip` (host `download.vb-audio.com`).
   VB-CABLE is donationware — read its licence before commercial use.
2. Verify the download **before** running it:

   ```powershell
   Get-FileHash -Algorithm SHA256 -LiteralPath .\VBCABLE_Driver_Pack45.zip
   ```

   Expected on this machine:
   `B950E39F01AF1D04EA623C8F6D8EB9B6EA5C477C637295FABF20631C85116BFB`.
   A different hash means a different or damaged package; do not install it.
3. Unzip, run `VBCABLE_Setup_x64.exe` **as administrator**, then **reboot**.
   The package's own `readme.txt` says: "To finalize installation, you must
   reboot your computer." The endpoints do not exist before that reboot.

After the reboot Windows has these endpoints:

| Endpoint | Direction | Use |
|:--|:--|:--|
| `CABLE Input (VB-Audio Virtual Cable)` | render / playback | what apps play into; A2DPWB captures this |
| `CABLE Output (VB-Audio Virtual Cable)` | capture / recording | the other end of the cable; not used here |
| `CABLE In 16ch (VB-Audio Virtual Cable)` | render / playback | the 16-channel variant; not used here |

## Step 2 — find the endpoint id

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\set-default-audio.ps1 -List
```

Output on this PC (ids replaced by placeholders):

```
CABLE Input (VB-Audio Virtual Cable) | <CABLE_INPUT_ID> | default
Speakers (Realtek(R) Audio) | <SPEAKERS_ID> | no
CABLE In 16ch (VB-Audio Virtual Cable) | <CABLE_16CH_ID> | no
Speakers (Boom Audio) | <BOOM_ID> | no
```

The second column is the WASAPI endpoint id (`{0.0.0.00000000}.{...}`), the
same string `a2dpwb-core.exe` takes for `--audio-device`. Write it down; it is
`<CABLE_INPUT_ID>` below. The `default` column is the current eConsole default.

## Step 3 — make the cable the default output

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\set-default-audio.ps1 -Device "CABLE Input"
```

The script matches the friendly name (or the exact id), then sets it for
**eConsole, eMultimedia and eCommunications** through IPolicyConfig — the same
change as Settings > System > Sound > Output — and reads the default back to
verify it. `-WhatIf` prints the plan (`Virtual : True`) and changes nothing;
without it the script applies the change and verifies it.

`-Device "CABLE Input"` is unambiguous: it does not match `CABLE In 16ch`.

From this moment every app that plays to the default output sends its audio
into the cable, and the speakers are silent. That is intended — but see the
footgun at the top.

## Step 4 — start the app in virtual-device mode

The app must capture the cable endpoint itself, not a loopback of the
speakers.

**GUI.** Edit the profile: **Capture Source** = **Virtual Device**, then pick
`CABLE Input (VB-Audio Virtual Cable)` in the **Audio Device** list (it shows
only virtual devices). **Auto-switch default device** can stay on; with the
cable already the default it is a no-op. **Connect**.

**CLI** (equivalent command):

```powershell
& "$env:LOCALAPPDATA\A2DP Windows Bridge\a2dpwb-core.exe" `
  --cli -d <HEADSET_MAC> -m virtual --audio-device "<CABLE_INPUT_ID>"
```

Or through the launcher (it auto-discovers the headset):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stream.ps1 `
  -Mode virtual -AudioDevice "<CABLE_INPUT_ID>" -Codec ldac -Quality hq
```

Without step 3, the CLI's `auto_switch` makes the cable the default only for
the duration of the stream and restores the previous default afterwards. With
step 3 the switch is already in place and the setting is independent of the
process lifetime. This machine uses step 3, so the state is explicit and
visible in `-List`.

## Step 5 — verified evidence

From the verified run on this machine, 2026-10-20 (timestamps stripped):

```
INFO chip: RTL8852BU (0xB85B) (auto)
INFO state Streaming: Connected
INFO audio capture: loopback of "CABLE Input (VB-Audio Virtual Cable)": mix 48000 Hz 2 ch 32 bit, capturing 48000 Hz F32
Sent 3789 media packets (2549997 bytes), 0 dropped before the radio
```

* The app calls the capture "loopback of ..." even in virtual mode; that is its
  wording. The captured device is the cable, not the speakers.
* `0 dropped` and `state Streaming: Connected`: the stream ran.
* With the cable as the default output and nothing playing to it, the PC
  speakers stayed silent, because the cable's output goes nowhere. That is the
  point of the setup and was verified on this machine.

## What this does not do

* Only the **default** output is redirected. An app pinned to another endpoint
  (per-app output, exclusive mode) still plays there, and A2DPWB does not
  capture it.
* `CABLE Output` is the recording side. Do not select it as the capture device.
* The cable is shared-mode WASAPI, so the capture rate is the endpoint's format
  (48 kHz here). For 96 kHz LDAC, change that endpoint's format first
  (`docs/usage.md`).
* VB-CABLE is third-party software with its own licence and installer; the
  toolkit only calls the Windows API to pick the endpoint.

## Reverting

```powershell
# the reliable revert on this PC
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\set-default-audio.ps1 `
  -Restore -Device "Speakers (Realtek(R) Audio)"

# the intended automatic form; exits 2 here because two candidates are active
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\set-default-audio.ps1 -Restore
```

Stopping the stream alone does **not** bring the speakers back: the default
output is a Windows setting, set in step 3, and stays on the cable until it is
changed. Uninstalling VB-CABLE is not required to revert; it only removes the
option.
