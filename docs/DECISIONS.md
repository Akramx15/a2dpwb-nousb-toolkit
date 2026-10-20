# Decision records

ADR-style records for the no-USB A2DP-Windows-Bridge toolkit. Each has
Context / Decision / Consequences / Status. Dates are 2026-10-19 unless noted.

## D1 - Use the internal RTL8852BU instead of buying a dongle

**Context.** A2DPWB needs to own a Bluetooth radio through WinUSB. Upstream
recommends a dedicated dongle so Windows keeps its own Bluetooth. This PC has
one radio: an internal Realtek RTL8852BU (`USB\VID_0BDA&PID_4853\
00E04C0000XX`). BTstack already knows `0x4853` and linux-firmware ships
`rtl8852bu_fw` / `rtl8852bu_config`; the v2.0.1 app chip table lacks `0x4853`
(UI shows `chip: unknown`).

**Decision.** Use the internal adapter. Add PID `0x4853` to the app chip
table via `patches/0001-...` so the UI names `RTL8852BU` and points at the
right firmware. Accept losing Windows Bluetooth while A2DPWB runs.

**Consequences.** No hardware purchase. Windows Bluetooth, and any device
using it, is unavailable during a run. The Bluetooth USB function is bound
to WinUSB; Wi-Fi (a separate function) is unaffected. Windows cannot use the
adapter for A2DP during the run. The device record has
`reboot_required: true`.

**Status.** Accepted.

## D2 - Keep Windows Bluetooth disabled while A2DPWB runs, and how to restore

**Context.** Binding WinUSB removes the adapter from Windows' Bluetooth
class. The project ships `a2dpwb-driver.exe`, which records the previous
driver in `%APPDATA%\A2DPWB\driver\` and restores it.

**Decision.** Do not fight Windows: leave Bluetooth down during a run, and
use the helper to restore afterwards. The toolkit wraps the helper
(`scripts/usb-driver.ps1`) rather than re-implementing driver swaps.
`restore` uses the recorded `previous` driver; `restore -UseRecords` restores
every recorded adapter with one UAC prompt; `restart` uses
`pnputil /restart-device` when Windows still hides the radio after restore.

**Consequences.** Recovery is two commands and is idempotent and verifiable
(`doctor.ps1` shows `kind` from the helper). A reboot may still be required
after `assign` and occasionally after `restore`. Two causes were conflated at
first (D7, `docs/ROOT-CAUSE.md`): `failed to initialize WinUSB (error 50)` is the
binding not being live until the device is re-enumerated (the record says
`reboot_required: true`; unplug/replug is upstream's remedy), while the missing
Realtek firmware is a separate condition that leaves the module in ROM mode but
does not stop the adapter from opening.

**Status.** Accepted.

## D3 - Use the emulator for zero-hardware CI and verification

**Context.** The core has a hardware-free path: `a2dpwb-core.exe --cli
--hci-tcp host:port` talks H4 over TCP to a virtual controller; upstream ships
`tools/emu` (Bumble sink). The resident/tray path hard-codes USB
(`resident.rs:270`, `hci_tcp: None`).

**Decision.** Make the emulator the default way to verify the toolkit without
hardware or admin rights (`scripts/run-emulator.ps1`), with an isolated
`A2DPWB_CONFIG_DIR` so the user's real link keys are never touched.

**Consequences.** Verification is reproducible and safe, but emulator-only
(no radio timing, no real headphones) and CLI-only until upstream exposes
`--hci-tcp` in the resident path. The venv needs Python 3.11+ and a download
of pinned Bumble packages (test tooling only, not shipped).

**Status.** Accepted.

## D4 - Do not build from source in the happy path

**Context.** This PC has Rust 1.97 but `C:\BuildTools` lacks the MSVC C++
workload: `vswhere -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64`
returns nothing and `cl.exe` is absent, so `cargo build` of the C parts
(BTstack, codecs) fails. Installing the workload is a multi-GB, admin-rights
download. v2.0.1 binaries are already installed and sufficient.

**Decision.** The happy path uses the installed v2.0.1 binaries. Building
from source is documented separately (`docs/BUILD-FOR-SOURCE.md`) and is
optional. Only the two files in `patches/` need a rebuild if you want the UI
to name PID `0x4853`; streaming works with the stock build because BTstack's
own table has `0x4853`.

**Consequences.** No build dependency in the happy path; the UI shows
`chip: unknown (0x4853)` and cannot name the firmware files until the patch
is built. A build requires step 1 of `BUILD-FOR-SOURCE.md`, plus `corepack
enable pnpm` and PowerShell 7 for the UI.

**Status.** Accepted.

## D5 - Default capture is system loopback, so the PC speakers also play

**Context.** With no `-m`, the core captures a WASAPI loopback of the
**default output device** (on this PC `Speakers (Realtek(R) Audio)`). Loopback
taps the render mix; it does not mute the endpoint. The verified 2026-10-19
session therefore played the song from the headphones **and** the PC speakers
at the same time. That is the intended behaviour of `-m loopback`, not a bug.

**Decision.** Keep system loopback as the zero-setup default
(`scripts\stream.ps1`), and document that the speakers still play. Offer
virtual-device mode as the opt-in alternative: install a virtual cable
(e.g. VB-CABLE), then use
`scripts\stream.ps1 -Mode virtual -AudioDevice <endpoint-id>`. The CLI passes
`auto_switch: true`, so the core makes the virtual device the default output
for the session and restores the previous default when the stream stops. A
user who prefers can set `CABLE Input` as the default in Windows Sound
settings; the CLI's switch is then a no-op.

**Consequences.** The one-command path works with no extra software, at the
cost of a duplicate speaker copy. Virtual-device mode removes that copy but
needs a third-party virtual cable, and anything playing to a non-default
endpoint (or in exclusive mode) is still not captured. If the core is killed
hard while the guard is active, the virtual device can remain the default;
restore it in Sound settings.

**Status.** Accepted. Refined by D8, which makes the persistent-default variant
the documented recipe.

## D6 - Classic A2DP needs LE Audio off and the phone disconnected

**Context.** The the headset is paired with both Windows and a phone, and its
LE Audio mode was on. The first A2DPWB attempts failed with two different
L2CAP result codes, both explained by upstream/BTstack constants:

* `0x66` = `L2CAP_CONNECTION_RESPONSE_RESULT_REFUSED_SECURITY`: the headset
  still held the link key created by the Windows Bluetooth stack, so A2DPWB's
  SSP authentication was refused.
* `0x67` = `L2CAP_CONNECTION_RESPONSE_RESULT_REFUSED_RESOURCES`: the headset's
  AVDTP signaling channel was already occupied (phone connected, LE Audio on).

**Decision.** Document and use this first-pairing procedure: switch **LE Audio
OFF** on the headset, **disconnect the phone**, put the headset in **pairing
mode**, then run the stream. The link key is then persisted in
`%APPDATA%\A2DPWB\link_keys.txt` (and the device in `devices.txt`), so later
runs need neither pairing mode nor a new key.

**Consequences.** The verified path is classic A2DP, not LE Audio. Keeping LE
Audio off is required for the classic source path on this headset. Removing
the headset from Windows' pairing is not needed once A2DPWB has its own key.
If the key is ever lost, repeat the procedure (the `0x66` refusal returns).

**Status.** Accepted.

## D7 - A cold unpatched Realtek module opens; the missing firmware is not error 50

**Context.** The first write-up attributed `failed to initialize WinUSB (error
50)` to the missing Realtek firmware, because the firmware was installed and
the adapter then opened in the same sitting. A cold-boot experiment on
2026-10-20 disproved the causal link: after a real Windows reboot with all four
firmware files removed from `%APPDATA%\A2DPWB`, the unpatched 2.0.2-beta.1
module still opened the adapter and brought HCI up, with two
`firmware file missing:` warnings. Restoring only the `.bin` files made the app
recreate the aliases, upload the firmware and re-open the adapter; the stream
then ran with 0 dropped packets. Details: `docs/UPSTREAM-BETA-TEST.md`,
`docs/ROOT-CAUSE.md`.

**Decision.** Record and document the two causes as independent. Error 50 means
the WinUSB binding is not live yet: the driver record says
`"reboot_required": true` at assign time - the restart flag `DiInstallDevice`
returns (`app/src/crates/win-sys/src/driver.rs:442`, returned at `:444`) - and
upstream's remedy for an adapter that does not answer is unplug/replug
(`docs/usage.md:472`). A successful assign does not re-enumerate by itself;
`uninstall_and_reenumerate` (`driver.rs:359`) is the restore path. The missing firmware is detected **by name**
(`WARN firmware file missing: ...` in 2.0.2-beta.1), not by an open failure; it
leaves the module in ROM mode and is fixed by installing `rtl8852bu_fw.bin` /
`rtl8852bu_config.bin` into `%APPDATA%\A2DPWB`.

**Consequences.** "The adapter cannot open" must not be read as a firmware
symptom, and "the adapter opened" must not be read as proof that the firmware
was loaded. Both docs and the upstream draft state the corrected causality; the
chip-table request, the setup-guide wording request and the `0x66` / `0x67`
troubleshooting note are unaffected. Reproduce the cold case: remove all four
files from `%APPDATA%\A2DPWB`, reboot, then run
`powershell -File scripts\cold-boot-test.ps1 -Mode Missing`.

**Status.** Accepted. Supersedes the causal claim in the first HANDOFF/README
draft and in the first upstream draft.

## D8 - Headphones only: a virtual render device, not a muted default output

**Context.** System loopback taps the default output and leaves it playing
(D5); upstream says so itself in `docs/usage.md`: "System Loopback copies the
audio; it does not take it away from the default output device ... To hear it
only on the headphones, use Virtual Device mode with a device that does not
play anywhere, such as VB-CABLE." A2DPWB has no virtual output device of its
own. Muting the default output is not the documented remedy (upstream's is
Virtual Device mode), and a mute would not be visible or reversible from the
app. On this PC VB-CABLE is installed (`CABLE Input` = render,
`CABLE Output` = capture, `CABLE In 16ch` = 16-channel render), and the app's
CLI sets `auto_switch: true` for classic A2DP virtual mode
(`app/src/core/src/cli.rs:413`), which only covers the process lifetime.

**Decision.** Route the audio through a virtual render endpoint that plays
nowhere. Make it the Windows default for eConsole, eMultimedia and
eCommunications with `scripts/set-default-audio.ps1` (IPolicyConfig), and run
the app in Virtual Device mode against that endpoint's WASAPI id. Do not mute
the physical output. Keep the setting outside the app's lifetime, so the state
is explicit and visible with `-List`. Document the footgun and the revert:
while the cable is the default and nothing streams it, the PC is silent.

**Consequences.** The PC speakers stay silent even though the same audio is
streaming, and headphones-only needs no code change upstream. All apps that
play to the default output follow the cable; apps pinned to another endpoint
(or using exclusive mode) are neither redirected nor captured. VB-CABLE is
third-party donationware with its own installer and reboot; the cable is
shared-mode, so 48 kHz unless the endpoint's format is changed. Reverting is
one command and must be documented where the change is made
(`docs/HEADPHONES-ONLY.md`). Verified on this PC: `Sent 3789 media packets
(2549997 bytes), 0 dropped before the radio` with `state Streaming: Connected`
and the capture line `loopback of "CABLE Input (VB-Audio Virtual Cable)"`.

**Status.** Accepted (2026-10-20). Refines D5.

## D9 - An unpatched module opens the adapter but cannot stream

**Context.** Cold boot on 2026-10-20 with all four firmware files removed from
`%APPDATA%\A2DPWB`, build 2.0.2-beta.1, module in ROM mode (`ROM LMP
subversion 0x8852`): the adapter opened and HCI came up, and the app printed
both `firmware file missing` warnings — but the A2DP stream did not establish
(no `state Streaming: Connected`, no `Sent ...` line). Restoring only the two
`.bin` files on the same boot made the app recreate the aliases, upload the
firmware (`download ran: True`) and stream LDAC with 0 dropped
(`packets=3759 bytes=2529807 dropped=0; streaming=True`). So "the adapter
opened" is compatible with "the firmware was not loaded", and the failure mode
of an unpatched module on this part is a dead stream, not a dead adapter.

**Decision.** Never diagnose the firmware from the adapter state. Treat the
`firmware file missing: ...` warning as the decisive signal, and fix it by
installing `rtl8852bu_fw.bin` / `rtl8852bu_config.bin` into
`%APPDATA%\A2DPWB` (the app recreates the extension-less aliases). Keep the
cold-boot script's phase-1 stream probe **informational**: phase 1 checks the
named diagnostics, phase 3 checks that streaming works after recovery.

**Consequences.** "Adapter opens" and "HCI ready" are no longer read as proof
that the firmware is present, in the README, the handoff and the upstream
draft. A user whose stream fails while the adapter is fine gets one actionable
message (install the firmware) instead of chasing WinUSB, the driver or
pairing. Scope: measured on this machine with this RTL8852BU, this firmware set
and this build; the mechanism is BTstack/Realtek-general, the streaming
failure is an observation here (`docs/UNPATCHED-MODULE.md`). Reproduction:
back up the four files to `%APPDATA%\A2DPWB-coldboot-backup` (the script
restores from there and exits 2 without it), remove them, reboot, then
`powershell -File scripts\cold-boot-test.ps1 -Mode Missing`.

**Status.** Accepted (2026-10-20). Extends D7.
