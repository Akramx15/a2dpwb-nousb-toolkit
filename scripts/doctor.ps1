#Requires -Version 5.1
<#
.SYNOPSIS
Read-only diagnosis of A2DPWB on this PC: adapter driver, firmware files,
binaries, a time-aware log summary, emulator environment, and a final verdict.

.DESCRIPTION
Changes nothing in the A2DPWB configuration. Reports:

  - the internal Bluetooth adapter's instance ID and current driver
    (WinUSB vs BTHUSB), from a2dpwb-driver.exe state and Get-PnpDevice
  - whether rtl8852bu_fw.bin / rtl8852bu_config.bin and their extension-less
    aliases exist and pass the magic checks A2DPWB enforces
  - whether a2dpwb-core.exe / a2dpwb-driver.exe / a2dpwb.exe exist
  - a LIVE PROBE (default): it runs the real installed core
    (a2dpwb-core.exe --cli --scan <seconds>) so the verdict reflects the
    adapter's state right now instead of a possibly stale log. The core logs
    to the console in --cli mode (it writes daily files only for the resident
    process), so the log alone can be hours old.
  - a "Last run summary" of the log: the adapter identity, the transport and
    HCI-ready lines (with duration), the last HCI ACL connection, the last
    pairing/authentication error and the last "Sent N media packets" line
  - a time-aware adapter verdict that compares the timestamp of the LAST
    "cannot open the HCI transport" line with the timestamp of the LAST
    successful marker ("HCI ready" or "USB: opened"). A historical failure in
    a log that accumulates the whole day does not count as the current state.
  - the resolved chip name (BTstack's table maps the PID 0x4853 to RTL8852BU)
    and why the stock UI still prints "chip: unknown"
  - the tools\emu Python virtual environment state

The verdict has four states:

  - HEALTHY      the adapter opens and HCI is ready (proven by the live probe
                 when one ran, otherwise by the log)
  - PAIRED/READY HEALTHY plus a successful A2DP "Streaming" state in the log
  - BLOCKED      the adapter does not open (the live probe failed, or the last
                 log failure is newer than the last success) or the firmware
                 files are missing/invalid
  - STALE        the adapter is not proven right now: no live probe ran and
                 the newest log contains neither a success nor a failure
                 marker, so there is no evidence either way. STALE is never
                 used to hide a real failure.

.PARAMETER ConfigDir
A2DPWB config folder. Default: $env:A2DPWB_CONFIG_DIR, else %APPDATA%\A2DPWB.

.PARAMETER VidPid
USB VID:PID of the internal adapter, default 0BDA:4853 (Realtek RTL8852BU).

.PARAMETER AppDir
Installed app folder. Default: %LOCALAPPDATA%\A2DP Windows Bridge.

.PARAMETER UpstreamDir
Upstream reference clone (for the emulator environment).
Default: discovered by walking up from this script for tools\emu\emu_sink.py.

.PARAMETER LogPath
An explicit core log to analyse. Default: the newest *.log in
<config>\logs (i.e. %APPDATA%\A2DPWB\logs). Read-only either way.

.PARAMETER Probe
Run the live probe. This is already the DEFAULT; the switch exists so the
intent can be stated explicitly. -NoProbe wins if both are given.

.PARAMETER NoProbe
Skip the live probe and derive the verdict from the log only.

.PARAMETER ProbeSeconds
Duration of the probe scan, in seconds. Default 4, clamped to 1..30.

.NOTES
The probe runs a2dpwb-core.exe --cli --scan against the REAL config folder
(%APPDATA%\A2DPWB, or $env:A2DPWB_CONFIG_DIR) because the Realtek firmware
lives there; it deliberately does NOT point the core at a temporary folder.
Opening and closing the adapter sends an HCI Reset on close, so the probe
cannot run while A2DPWB is streaming: if a2dpwb-core.exe is already running
the probe is skipped. The probe may only READ the config folder; the script
verifies that by hashing the folder before and after and reporting any diff
(the core itself may write le_audio_bonds.tlv, which is then reported as
"written by the app during the probe").

Exit codes: 0 verdict HEALTHY or PAIRED/READY, 1 verdict BLOCKED, 3 verdict
STALE, 2 the doctor itself failed.
#>
[CmdletBinding()]
param(
    [string]$ConfigDir,
    [string]$VidPid = '0BDA:4853',
    [string]$AppDir,
    [string]$UpstreamDir,
    [string]$LogPath,
    [switch]$Probe,
    [switch]$NoProbe,
    [int]$ProbeSeconds = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$LASTEXITCODE = 0

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "== $Title ==" -ForegroundColor Cyan
}

function Resolve-ConfigDir {
    if ($ConfigDir) { return $ConfigDir }
    if ($env:A2DPWB_CONFIG_DIR) { return $env:A2DPWB_CONFIG_DIR }
    if ($env:APPDATA) { return (Join-Path $env:APPDATA 'A2DPWB') }
    return $null
}

function Resolve-AppDir {
    if ($AppDir) { return $AppDir }
    if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA 'A2DP Windows Bridge') }
    return $null
}

function Find-Upstream {
    if ($UpstreamDir) { return $UpstreamDir }
    $dir = Split-Path -Parent $PSScriptRoot
    for ($i = 0; $i -lt 6 -and $dir; $i++) {
        if (Test-Path -LiteralPath (Join-Path $dir 'tools\emu\emu_sink.py') -PathType Leaf) { return $dir }
        $nested = Join-Path $dir 'upstream'
        if (Test-Path -LiteralPath (Join-Path $nested 'tools\emu\emu_sink.py') -PathType Leaf) { return $nested }
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

function Test-Firmware {
    param([string]$Path, [ValidateSet('fw', 'cfg')][string]$Kind)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Exists = $false; Valid = $false; Reason = 'missing'; Length = 0; Sha256 = '' }
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $valid = $false
    $reason = ''
    if ($Kind -eq 'fw') {
        if ($bytes.Length -lt 16) { $reason = 'too short' }
        else {
            $head = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 8)
            $tail = $bytes[($bytes.Length - 4)..($bytes.Length - 1)]
            $tailOk = ($tail[0] -eq 0x51 -and $tail[1] -eq 0x04 -and $tail[2] -eq 0xFD -and $tail[3] -eq 0x77)
            if ($head -ne 'Realtech' -and $head -ne 'RTBTCore') { $reason = "bad signature '$head'" }
            elseif (-not $tailOk) { $reason = 'bad extension signature' }
            else { $valid = $true }
        }
    }
    else {
        if ($bytes.Length -eq 0) { $valid = $true }
        elseif ($bytes.Length -ge 6 -and $bytes[0] -eq 0x55 -and $bytes[1] -eq 0xAB -and $bytes[2] -eq 0x23 -and $bytes[3] -eq 0x87) { $valid = $true }
        else { $reason = 'bad or missing 55 AB 23 87 magic' }
    }
    $sha = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return [pscustomobject]@{ Exists = $true; Valid = $valid; Reason = $reason; Length = $bytes.Length; Sha256 = $sha }
}

function Get-LogTimestamp {
    param([string]$Line)
    if ($Line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})') {
        $parsed = [datetime]::MinValue
        $ok = [datetime]::TryParseExact(
            $matches[1],
            'yyyy-MM-dd HH:mm:ss.fff',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$parsed)
        if ($ok) { return $parsed }
    }
    return $null
}

function Get-LastLogMatch {
    param([string[]]$Lines, [string]$Pattern)
    $result = $null
    foreach ($line in $Lines) {
        if ($line -match $Pattern) { $result = $line.Trim() }
    }
    if ($result) { return $result }
    return $null
}

function Get-ChipName {
    param([string]$ProductId)
    # BTstack's chipset table maps Realtek USB PID 0x4853 to the RTL8852BU.
    if ($ProductId -eq '0x4853') { return 'RTL8852BU' }
    return $null
}

function Get-ConfigSnapshot {
    param([string]$Root)
    $snap = @{}
    if (-not $Root -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return $snap }
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue) {
        $rel = $file.FullName.Substring($Root.Length).TrimStart('\')
        try { $snap[$rel] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
        catch { $snap[$rel] = 'unreadable' }
    }
    return $snap
}

function Compare-ConfigSnapshot {
    param([hashtable]$Before, [hashtable]$After)
    $added = New-Object System.Collections.Generic.List[string]
    $removed = New-Object System.Collections.Generic.List[string]
    $changed = New-Object System.Collections.Generic.List[string]
    foreach ($key in $After.Keys) {
        if (-not $Before.ContainsKey($key)) { $added.Add($key) }
        elseif ($Before[$key] -ne $After[$key]) { $changed.Add($key) }
    }
    foreach ($key in $Before.Keys) {
        if (-not $After.ContainsKey($key)) { $removed.Add($key) }
    }
    return [pscustomobject]@{
        Added   = @($added | Sort-Object)
        Removed = @($removed | Sort-Object)
        Changed = @($changed | Sort-Object)
    }
}

try {
    $config = Resolve-ConfigDir
    $app = Resolve-AppDir
    $vid = ($VidPid -split ':')[0]
    $pidValue = ($VidPid -split ':')[1]
    $blockers = New-Object System.Collections.Generic.List[string]
    $nextAction = $null
    $fwOk = $true
    $fwFixAction = $null
    $binariesFixAction = $null

    Write-Host 'A2DPWB no-USB doctor (read-only)'
    Write-Host ("Computer: {0}   Date: {1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

    # --- Adapter ---
    Write-Section "Adapter ($VidPid)"
    $instanceId = $null
    $pnp = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like "*VID_$vid&PID_$pidValue*" })
    if ($pnp.Count -eq 0) {
        Write-Host "NOT FOUND: no present device matching VID_$vid&PID_$pidValue." -ForegroundColor Red
        $blockers.Add("internal adapter $VidPid is not present")
        if (-not $nextAction) { $nextAction = 'Check that the internal Bluetooth radio is enabled in Device Manager / BIOS.' }
    }
    else {
        $device = $pnp[0]
        $instanceId = $device.InstanceId
        Write-Host ("Instance ID : {0}" -f $device.InstanceId)
        Write-Host ("Name        : {0}" -f $device.FriendlyName)
        Write-Host ("Status/Class: {0} / {1}   Problem: {2}" -f $device.Status, $device.Class, $device.Problem)
        foreach ($key in @('DEVPKEY_Device_DriverDesc', 'DEVPKEY_Device_DriverInfPath', 'DEVPKEY_Device_Service', 'DEVPKEY_Device_DriverVersion')) {
            $prop = Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName $key -ErrorAction SilentlyContinue
            if ($prop -and $prop.Data) { Write-Host ("{0,-27}: {1}" -f $key, $prop.Data) }
        }
    }

    $driverKind = $null
    $driverExe = if ($app) { Join-Path $app 'a2dpwb-driver.exe' } else { $null }
    if ($driverExe -and (Test-Path -LiteralPath $driverExe -PathType Leaf) -and $instanceId) {
        try {
            $stateJson = & $driverExe state $instanceId | Out-String
            $state = $stateJson | ConvertFrom-Json
            $driverKind = $state.state.kind
            Write-Host ("a2dpwb-driver kind       : {0} ({1}, {2})" -f $state.state.kind, $state.state.driver.service, $state.state.driver.description)
        }
        catch { Write-Warning "a2dpwb-driver state failed: $($_.Exception.Message)" }
    }

    # --- Driver record (reboot_required) ---
    $record = $null
    if ($config) {
        $recordDir = Join-Path $config 'driver'
        if (Test-Path -LiteralPath $recordDir -PathType Container) {
            foreach ($file in Get-ChildItem -LiteralPath $recordDir -Filter '*.json' -File) {
                try { $candidate = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { continue }
                if ($instanceId -and $candidate.instance_id -and ($candidate.instance_id -ieq $instanceId)) { $record = $candidate; break }
            }
        }
    }
    if ($record) {
        Write-Host ("Driver record            : {0} (reboot_required={1})" -f $record.instance_id, $record.reboot_required)
    }

    # --- Firmware ---
    Write-Section 'Firmware files'
    $stem = 'rtl8852bu'
    if ($config) {
        $settingsPath = Join-Path $config 'settings.json'
        if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
            try {
                $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
                if ($settings.bt_chip_fw_stem) { $stem = $settings.bt_chip_fw_stem }
                Write-Host ("settings.json: bt_chip_pid={0} bt_chip_fw_stem='{1}'" -f $settings.bt_chip_pid, $settings.bt_chip_fw_stem)
            }
            catch { Write-Warning "cannot parse settings.json: $($_.Exception.Message)" }
        }
        else { Write-Host "settings.json not found under $config" }
    }
    if (-not $config) {
        Write-Host 'No config folder resolved (set A2DPWB_CONFIG_DIR or APPDATA).' -ForegroundColor Red
        $blockers.Add('A2DPWB config folder unknown')
        if (-not $nextAction) { $nextAction = 'Set APPDATA (normal session) or pass -ConfigDir.' }
    }
    else {
        Write-Host "Config folder: $config"
        Write-Host "Firmware stem: $stem"
        $fwBin = Join-Path $config ("{0}_fw.bin" -f $stem)
        $cfgBin = Join-Path $config ("{0}_config.bin" -f $stem)
        $fwAlias = Join-Path $config ("{0}_fw" -f $stem)
        $cfgAlias = Join-Path $config ("{0}_config" -f $stem)
        $fwOk = $true
        foreach ($pair in @(
                @{ Path = $fwBin; Kind = 'fw'; Label = 'firmware (.bin)' },
                @{ Path = $fwAlias; Kind = 'fw'; Label = 'firmware (BTstack name)' },
                @{ Path = $cfgBin; Kind = 'cfg'; Label = 'config (.bin)' },
                @{ Path = $cfgAlias; Kind = 'cfg'; Label = 'config (BTstack name)' })) {
            $st = Test-Firmware -Path $pair.Path -Kind $pair.Kind
            if ($st.Valid) {
                Write-Host ("  OK      {0}: {1} ({2} bytes)" -f $pair.Label, $pair.Path, $st.Length) -ForegroundColor Green
            }
            else {
                Write-Host ("  MISSING {0}: {1} ({2})" -f $pair.Label, $pair.Path, $(if ($st.Exists) { $st.Reason } else { 'not found' })) -ForegroundColor Yellow
                $fwOk = $false
            }
        }
        if (-not $fwOk) {
            $fwFixAction = 'Run scripts\fetch-realtek-fw.ps1 to download and validate the Realtek firmware.'
        }
    }

    # --- Binaries ---
    Write-Section 'Installed binaries'
    if (-not $app -or -not (Test-Path -LiteralPath $app -PathType Container)) {
        Write-Host "App folder not found: $app" -ForegroundColor Red
        $blockers.Add('A2DPWB is not installed')
        if (-not $nextAction) { $nextAction = 'Install A2DP-Windows-Bridge v2.0.1 (release installer or portable zip).' }
    }
    else {
        Write-Host "App folder: $app"
        $anyMissing = $false
        foreach ($name in @('a2dpwb-core.exe', 'a2dpwb-driver.exe', 'a2dpwb.exe')) {
            $path = Join-Path $app $name
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $item = Get-Item -LiteralPath $path
                $version = $item.VersionInfo.FileVersion
                Write-Host ("  OK      {0} ({1:N0} bytes, version {2})" -f $name, $item.Length, $version) -ForegroundColor Green
            }
            else {
                Write-Host ("  MISSING {0}" -f $name) -ForegroundColor Yellow
                $anyMissing = $true
            }
        }
        if ($anyMissing) {
            $binariesFixAction = 'Reinstall A2DPWB so a2dpwb-core.exe, a2dpwb-driver.exe and a2dpwb.exe are present.'
        }
    }

    # --- Live probe ---
    Write-Section 'Live probe'
    $doProbe = -not $NoProbe
    if ($Probe -and $NoProbe) { Write-Warning '-Probe and -NoProbe both given; -NoProbe wins.' }
    $probeRan = $false
    $probeHealthy = $false
    $probeFailed = $false
    $probeLines = @()
    $probeExit = $null
    $probeSecs = [math]::Min(30, [math]::Max(1, $ProbeSeconds))
    $snapBefore = $null
    $snapAfter = $null
    $snapDiff = $null
    $coreExe = if ($app) { Join-Path $app 'a2dpwb-core.exe' } else { $null }
    $coreRunning = @(Get-Process -Name 'a2dpwb-core' -ErrorAction SilentlyContinue)
    if (-not $doProbe) {
        Write-Host 'Skipped (-NoProbe): the verdict will use the log only.' -ForegroundColor DarkGray
    }
    elseif (-not $coreExe -or -not (Test-Path -LiteralPath $coreExe -PathType Leaf)) {
        Write-Host "Cannot probe: a2dpwb-core.exe not found under $app" -ForegroundColor Yellow
        Write-Host 'Falling back to the log-only analysis below.' -ForegroundColor DarkGray
    }
    elseif ($coreRunning.Count -gt 0) {
        Write-Host ("Cannot probe: a2dpwb-core.exe is already running (PID {0}); the adapter is in use." -f $coreRunning[0].Id) -ForegroundColor Yellow
        Write-Host 'The probe opens and closes the adapter (it sends an HCI Reset on close) and must not fight for it.' -ForegroundColor DarkGray
        Write-Host 'Stop A2DPWB (tray app) and re-run, or accept the log-only result.' -ForegroundColor DarkGray
    }
    else {
        Write-Host ("Running: `"{0}`" --cli --scan {1}" -f $coreExe, $probeSecs) -ForegroundColor DarkGray
        Write-Host ("Config dir (real, read-only for the probe): {0}" -f $config)
        if ($config) { $snapBefore = Get-ConfigSnapshot -Root $config }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $oldPref = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $raw = & $coreExe --cli --scan $probeSecs 2>&1 | Out-String -Width 4096 }
        finally { $ErrorActionPreference = $oldPref }
        $probeExit = $LASTEXITCODE
        $sw.Stop()
        if ($config) { $snapAfter = Get-ConfigSnapshot -Root $config }
        $probeRan = $true
        $clean = [regex]::Replace([string]$raw, "$([char]27)\[[0-9;]*m", '')
        $probeLines = @($clean -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
        $probeReady = Get-LastLogMatch -Lines $probeLines -Pattern 'HCI ready'
        $probeOpen = Get-LastLogMatch -Lines $probeLines -Pattern 'USB: opened'
        $probeFailureLine = Get-LastLogMatch -Lines $probeLines -Pattern 'cannot open the HCI transport'
        if ($probeReady) { $probeHealthy = $true }
        elseif ($probeFailureLine) { $probeFailed = $true }
        elseif ($probeOpen) { $probeFailed = $true }
        if (-not $probeHealthy -and -not $probeFailed) {
            Write-Host 'The probe produced no decisive marker (no "HCI ready" / "USB: opened" / failure line).' -ForegroundColor Yellow
            Write-Host 'Falling back to the log-only analysis below.' -ForegroundColor DarkGray
        }
        else {
            Write-Host ("Probe exit code {0}, took {1:N1} s. Decisive lines:" -f $probeExit, $sw.Elapsed.TotalSeconds)
            $decisive = @($probeLines | Where-Object { $_ -match 'USB: opened|HCI ready|cannot open the HCI transport|controller: company' })
            $shown = @($decisive | Select-Object -First 8)
            foreach ($d in $shown) {
                Write-Host ("  {0}" -f $d) -ForegroundColor $(if ($d -match 'cannot open') { 'Red' } elseif ($d -match 'HCI ready|USB: opened|controller: company') { 'Green' } else { 'Gray' })
            }
            if ($decisive.Count -gt $shown.Count) { Write-Host ("  ... ({0} more matching lines)" -f ($decisive.Count - $shown.Count)) -ForegroundColor DarkGray }
            if ($probeHealthy) {
                Write-Host 'The adapter opened and HCI became ready DURING THIS RUN.' -ForegroundColor Green
            }
            else {
                Write-Host 'The adapter did NOT open during this run.' -ForegroundColor Red
            }
        }
        if ($snapBefore -and $snapAfter) {
            $snapDiff = Compare-ConfigSnapshot -Before $snapBefore -After $snapAfter
            $n = $snapDiff.Added.Count + $snapDiff.Removed.Count + $snapDiff.Changed.Count
            if ($n -eq 0) {
                Write-Host ("Config dir unchanged by the probe ({0} files hashed)." -f $snapBefore.Count) -ForegroundColor Green
            }
            else {
                Write-Host 'Config dir changed during the probe:' -ForegroundColor Yellow
                foreach ($a in $snapDiff.Added) { Write-Host ("  + {0} (written by the app during the probe)" -f $a) -ForegroundColor Yellow }
                foreach ($c in $snapDiff.Changed) { Write-Host ("  ~ {0} (written by the app during the probe)" -f $c) -ForegroundColor Yellow }
                foreach ($r in $snapDiff.Removed) { Write-Host ("  - {0} (removed by the app during the probe)" -f $r) -ForegroundColor Yellow }
            }
        }
    }

    # --- Core log ---
    Write-Section 'Core log'
    $lines = @()
    $logFile = $null
    $logMissing = $false
    $lastFailure = $null
    $lastFailureTs = $null
    $lastSuccessTs = $null
    $lastStreaming = $null
    $healthKnown = $true
    $adapterHealthy = $false
    $logAnalysed = $false
    if ($LogPath) {
        if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
            $logFile = Get-Item -LiteralPath $LogPath
        }
        else {
            Write-Host "Log not found: $LogPath" -ForegroundColor Red
            $logMissing = $true
        }
    }
    elseif ($config) {
        $logDir = Join-Path $config 'logs'
        if (Test-Path -LiteralPath $logDir -PathType Container) {
            $logFile = Get-ChildItem -LiteralPath $logDir -Filter '*.log' -File |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $logFile) { Write-Host 'No *.log file yet (the core has not run).' }
        }
        else { Write-Host "No logs folder under $config." }
    }
    if ($logFile) {
        Write-Host ("Log: {0} (modified {1})" -f $logFile.FullName, $logFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
        $lines = [System.IO.File]::ReadAllLines($logFile.FullName)
        $logAnalysed = $true
        Write-Host ("Lines: {0}" -f $lines.Count)

        $lastOpen = Get-LastLogMatch -Lines $lines -Pattern 'USB: opened'
        $lastFailure = Get-LastLogMatch -Lines $lines -Pattern 'cannot open the HCI transport'
        $lastReady = Get-LastLogMatch -Lines $lines -Pattern 'HCI ready'
        $lastAcl = Get-LastLogMatch -Lines $lines -Pattern 'HCI ACL connection established to'
        $lastStreaming = Get-LastLogMatch -Lines $lines -Pattern '\[Streaming\]|state Streaming'
        $lastAuthError = Get-LastLogMatch -Lines $lines -Pattern 'signaling connection failed|stream establishment failed|authentication failed'
        $lastMedia = Get-LastLogMatch -Lines $lines -Pattern 'Sent \d+ media packets'
        $chipLine = Get-LastLogMatch -Lines $lines -Pattern 'chip:'

        $lastOpenTs = if ($lastOpen) { Get-LogTimestamp -Line $lastOpen } else { $null }
        $lastFailureTs = if ($lastFailure) { Get-LogTimestamp -Line $lastFailure } else { $null }
        $lastReadyTs = if ($lastReady) { Get-LogTimestamp -Line $lastReady } else { $null }

        # Last success = the newer of the transport-open and HCI-ready markers.
        $lastSuccessTs = $null
        if ($lastOpenTs -and $lastReadyTs) { $lastSuccessTs = if ($lastOpenTs -gt $lastReadyTs) { $lastOpenTs } else { $lastReadyTs } }
        elseif ($lastOpenTs) { $lastSuccessTs = $lastOpenTs }
        elseif ($lastReadyTs) { $lastSuccessTs = $lastReadyTs }

        # Decide adapter health strictly from the timestamps (never from order alone).
        $healthKnown = $true
        $adapterHealthy = $false
        $hasSuccessMarker = [bool]($lastOpen -or $lastReady)
        if ($lastFailure) {
            if (-not $hasSuccessMarker) {
                $adapterHealthy = $false
            }
            elseif ($lastFailureTs -and $lastSuccessTs) {
                $adapterHealthy = ($lastSuccessTs -gt $lastFailureTs)
            }
            else {
                $healthKnown = $false
            }
        }
        elseif ($hasSuccessMarker) {
            $adapterHealthy = $true
        }
        else {
            # Neither a success nor a failure marker: the log proves nothing.
            $healthKnown = $false
        }

        Write-Host ''
        Write-Host 'Last run summary:' -ForegroundColor Cyan
        Write-Host ("  Adapter identity        : {0} {1}" -f $VidPid, $(if ($instanceId) { $instanceId } else { '(instance ID unknown)' }))
        Write-Host ("  Last transport open     : {0}" -f $(if ($lastOpen) { $lastOpen } else { '(none in this log)' }))
        Write-Host ("  Last HCI ready          : {0}" -f $(if ($lastReady) { $lastReady } else { '(none in this log)' }))
        Write-Host ("  Last HCI ACL link       : {0}" -f $(if ($lastAcl) { $lastAcl } else { '(none in this log)' }))
        Write-Host ("  Last pairing/auth error : {0}" -f $(if ($lastAuthError) { $lastAuthError } else { '(none in this log)' }))
        Write-Host ("  Last media packets      : {0}" -f $(if ($lastMedia) { $lastMedia } else { '(none in this log)' }))
        Write-Host ("  Last audio state        : {0}" -f $(if ($lastStreaming) { $lastStreaming } else { '(none in this log)' }))
        if ($lastFailure) {
            $when = if ($lastFailureTs) { $lastFailureTs.ToString('yyyy-MM-dd HH:mm:ss') } else { 'timestamp unparseable' }
            Write-Host ("  Last HCI open failure   : {0} ({1})" -f $lastFailure, $when) -ForegroundColor $(if ($adapterHealthy) { 'DarkGray' } else { 'Red' })
            if ($adapterHealthy) {
                Write-Host '  note: that failure is historical; a later successful open supersedes it.' -ForegroundColor DarkGray
            }
        }
        else {
            Write-Host '  Last HCI open failure   : (none in this log)' -ForegroundColor Green
        }
        if (-not $healthKnown) {
            Write-Host '  note: the log does not establish the current adapter state (no marker, or unparseable timestamps); not guessing.' -ForegroundColor Yellow
        }

        if ($chipLine) {
            Write-Host ''
            Write-Host ("Chip line from the core: {0}" -f $chipLine)
            $resolved = Get-ChipName -ProductId ("0x{0}" -f $pidValue)
            if ($resolved) {
                Write-Host ("  resolved chip           : {0} (Realtek USB PID 0x{1})" -f $resolved, $pidValue) -ForegroundColor Green
                Write-Host '  note: the stock UI prints "chip: unknown" because upstream has no' -ForegroundColor DarkGray
                Write-Host '        table entry for PID 0x4853 (see patches\0001-bt-host-name-rtl8852bu-pid-0x4853.patch).' -ForegroundColor DarkGray
            }
        }
    }
    elseif ($logMissing) {
        Write-Host 'No log to analyse (the requested -LogPath does not exist).' -ForegroundColor Red
    }

    # --- Emulator environment ---
    Write-Section 'Emulator (tools/emu)'
    $upstream = Find-Upstream
    if (-not $upstream) {
        Write-Host 'Upstream clone not found (no tools\emu\emu_sink.py above this script).' -ForegroundColor Yellow
    }
    else {
        Write-Host "Upstream: $upstream"
        $venvPython = Join-Path $upstream 'tools\emu\.venv\Scripts\python.exe'
        if (Test-Path -LiteralPath $venvPython -PathType Leaf) {
            try {
                $bumble = & $venvPython -c "import importlib.metadata as m; print(m.version('bumble'))" 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host ("  OK      venv python with Bumble {0}" -f $bumble) -ForegroundColor Green
                }
                else {
                    Write-Host '  venv exists but Bumble is not installed: run python tools\emu\setup_env.py' -ForegroundColor Yellow
                }
            }
            catch { Write-Host '  venv exists but the Bumble check failed.' -ForegroundColor Yellow }
        }
        else {
            Write-Host '  tools\emu\.venv missing: run python tools\emu\setup_env.py (see docs/BUILD-FOR-SOURCE.md).' -ForegroundColor Yellow
        }
    }

    # --- Verdict ---
    Write-Section 'Verdict'

    # Evidence priority: the live probe beats the (possibly stale) log.
    $adapterState = 'unknown'   # healthy | blocked | stale | unknown
    if ($probeHealthy) {
        $adapterState = 'healthy'
        Write-Host 'Evidence: the live probe opened the adapter and HCI became ready.' -ForegroundColor Green
    }
    elseif ($probeFailed) {
        $adapterState = 'blocked'
        Write-Host 'Evidence: the live probe could not open the adapter.' -ForegroundColor Red
    }
    else {
        if ($probeRan) { Write-Host 'The live probe produced no verdict; the adapter state comes from the log.' -ForegroundColor Yellow }
        if ($logAnalysed) {
            if ($hasSuccessMarker) {
                if (-not $lastFailure) { $adapterState = 'healthy' }
                elseif (-not $healthKnown) { $adapterState = 'unknown' }
                elseif ($adapterHealthy) { $adapterState = 'healthy' }
                else { $adapterState = 'blocked' }
            }
            elseif ($lastFailure) { $adapterState = 'blocked' }
            else { $adapterState = 'stale' }
            Write-Host ("Evidence: log only; the newest log says {0}." -f $adapterState) -ForegroundColor DarkGray
        }
        else {
            $adapterState = 'stale'
            Write-Host 'Evidence: no live probe and no log to analyse.' -ForegroundColor Yellow
        }
    }

    # Static blockers. A healthy live probe supersedes the static driver and
    # firmware checks, which describe configuration rather than the live state.
    if ($probeHealthy) {
        if ($driverKind -and $driverKind -ne 'winusb') {
            Write-Host ("note: the driver record says '{0}', but the live probe opened the adapter anyway; not a blocker." -f $driverKind) -ForegroundColor DarkGray
        }
        if (-not $fwOk) {
            Write-Host 'note: firmware files looked invalid, but the live probe booted the controller anyway; not a blocker.' -ForegroundColor DarkGray
        }
    }
    else {
        if ($driverKind -and $driverKind -ne 'winusb') {
            $blockers.Add("adapter driver is '$driverKind', not winusb")
            if (-not $nextAction) { $nextAction = 'Run scripts\usb-driver.ps1 -Mode assign -Auto (UAC), then reboot if it reports reboot_required: true.' }
        }
        if (-not $fwOk) {
            $blockers.Add('firmware files missing or invalid')
            if (-not $nextAction) { $nextAction = $fwFixAction }
        }
    }
    if ($binariesFixAction) {
        $blockers.Add('one or more A2DPWB binaries are missing')
        if (-not $nextAction) { $nextAction = $binariesFixAction }
    }
    if ($logMissing) {
        $blockers.Add("the requested log was not found: $LogPath")
        if (-not $nextAction) { $nextAction = 'Pass -LogPath with an existing core log, or let the doctor pick the newest log.' }
    }

    switch ($adapterState) {
        'blocked' {
            if ($probeFailed) {
                $blockers.Add('the live probe could not open the adapter (see the "Live probe" section)')
                if (-not $nextAction) {
                    if ($record -and $record.reboot_required) {
                        $nextAction = 'Reboot Windows (or run scripts\usb-driver.ps1 -Mode restart -Auto elevated), then rerun this doctor.'
                    }
                    else {
                        $nextAction = 'Re-read the "cannot open the HCI transport" line from the probe; check the WinUSB binding and the firmware files.'
                    }
                }
            }
            else {
                $detail = if ($lastFailureTs) { "last failure at $($lastFailureTs.ToString('yyyy-MM-dd HH:mm:ss'))" } else { 'a startup failure' }
                $blockers.Add("the adapter did not open in the newest log ($detail, newer than the last success)")
                if ($record -and $record.reboot_required) {
                    Write-Host 'note: the driver record says reboot_required=true and the adapter still fails to open.' -ForegroundColor Yellow
                }
                if (-not $nextAction) {
                    if ($record -and $record.reboot_required) {
                        $nextAction = 'Reboot Windows (or run scripts\usb-driver.ps1 -Mode restart -Auto elevated), then rerun this doctor.'
                    }
                    else {
                        $nextAction = 'Re-run the core once and inspect the "cannot open the HCI transport" line it emits.'
                    }
                }
            }
        }
        'unknown' {
            if ($logAnalysed -and -not $healthKnown) {
                $blockers.Add('cannot determine the adapter state: the log has a failure and a success with unparseable timestamps')
                if (-not $nextAction) { $nextAction = 'Re-run with a log whose lines start with "YYYY-MM-DD HH:MM:SS.mmm", or inspect it manually.' }
            }
        }
    }

    if ($blockers.Count -eq 0) {
        if ($adapterState -eq 'stale') {
            Write-Host 'STALE - the adapter is not proven right now:' -ForegroundColor Yellow
            Write-Host '  no live probe output and the newest log has neither a success nor a failure marker,' -ForegroundColor Yellow
            Write-Host '  so there is no evidence either way. This never hides a real failure.' -ForegroundColor Yellow
            Write-Host 'Next action: run scripts\doctor.ps1 (live probe on) while A2DPWB is stopped.' -ForegroundColor Yellow
            exit 3
        }
        if ($lastStreaming) {
            Write-Host 'PAIRED/READY - the adapter opens, HCI is ready and A2DP reached Streaming.' -ForegroundColor Green
            exit 0
        }
        if ($adapterState -eq 'healthy') {
            if ($probeHealthy) { Write-Host 'HEALTHY - the live probe opened the adapter and HCI is ready.' -ForegroundColor Green }
            else { Write-Host 'HEALTHY - the adapter opens and HCI is ready.' -ForegroundColor Green }
            Write-Host 'Next action: run a2dpwb-core.exe --cli -d <headphone MAC> --test-tone (or start the UI).' -ForegroundColor Green
            exit 0
        }
        # No blocker, but the adapter is not proven either: stay honest.
        Write-Host 'STALE - no failure was found, but the adapter is not proven to open right now.' -ForegroundColor Yellow
        Write-Host 'Next action: run scripts\doctor.ps1 (live probe on) while A2DPWB is stopped.' -ForegroundColor Yellow
        exit 3
    }
    Write-Host 'BLOCKED:' -ForegroundColor Red
    foreach ($b in $blockers) { Write-Host "  - $b" -ForegroundColor Red }
    Write-Host ''
    Write-Host "Next action: $nextAction" -ForegroundColor Yellow
    exit 1
}
catch {
    Write-Error "doctor failed: $($_.Exception.Message)"
    exit 2
}
