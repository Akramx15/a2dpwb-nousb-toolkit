#Requires -Version 5.1
<#
.SYNOPSIS
Read-only diagnosis of A2DPWB on this PC: adapter driver, firmware files,
binaries, newest log errors, emulator environment, and a final verdict.

.DESCRIPTION
Changes nothing. Reports:

  - the internal Bluetooth adapter's instance ID and current driver
    (WinUSB vs BTHUSB), from a2dpwb-driver.exe state and Get-PnpDevice
  - whether rtl8852bu_fw.bin / rtl8852bu_config.bin and their extension-less
    aliases exist and pass the magic checks A2DPWB enforces
  - whether a2dpwb-core.exe / a2dpwb-driver.exe / a2dpwb.exe exist
  - the newest core log's decisive lines (last "cannot open the HCI
    transport", last "Streaming", the chip line) and the driver record
  - the tools\emu Python virtual environment state
  - a verdict: OK or BLOCKED, with the single next action

.PARAMETER ConfigDir
A2DPWB config folder. Default: $env:A2DPWB_CONFIG_DIR, else %APPDATA%\A2DPWB.

.PARAMETER VidPid
USB VID:PID of the internal adapter, default 0BDA:4853 (Realtek RTL8852BU).

.PARAMETER AppDir
Installed app folder. Default: %LOCALAPPDATA%\A2DP Windows Bridge.

.PARAMETER UpstreamDir
Upstream reference clone (for the emulator environment).
Default: discovered by walking up from this script for tools\emu\emu_sink.py.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1

.NOTES
Exit codes: 0 verdict OK, 1 verdict BLOCKED, 2 the doctor itself failed.
#>
[CmdletBinding()]
param(
    [string]$ConfigDir,
    [string]$VidPid = '0BDA:4853',
    [string]$AppDir,
    [string]$UpstreamDir
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

try {
    $config = Resolve-ConfigDir
    $app = Resolve-AppDir
    $vid = ($VidPid -split ':')[0]
    $pidValue = ($VidPid -split ':')[1]
    $blockers = New-Object System.Collections.Generic.List[string]
    $nextAction = $null

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
            $blockers.Add('firmware files missing or invalid')
            if (-not $nextAction) { $nextAction = 'Run scripts\fetch-realtek-fw.ps1 to download and validate the Realtek firmware.' }
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
            $blockers.Add('one or more A2DPWB binaries are missing')
            if (-not $nextAction) { $nextAction = 'Reinstall A2DPWB so a2dpwb-core.exe, a2dpwb-driver.exe and a2dpwb.exe are present.' }
        }
    }

    # --- Newest log ---
    Write-Section 'Newest core log'
    $logTail = @()
    if ($config) {
        $logDir = Join-Path $config 'logs'
        if (Test-Path -LiteralPath $logDir -PathType Container) {
            $log = Get-ChildItem -LiteralPath $logDir -Filter '*.log' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($log) {
                Write-Host ("Log: {0} (modified {1})" -f $log.FullName, $log.LastWriteTime)
                $lines = [System.IO.File]::ReadAllLines($log.FullName)
                $logTail = $lines
                foreach ($pattern in @('cannot open the HCI transport', '\[Streaming\]', 'chip:', 'reboot')) {
                    $match = $lines | Select-String -Pattern $pattern | Select-Object -Last 1
                    if ($match) { Write-Host ("  {0,-32}: {1}" -f $pattern, $match.Line.Trim()) }
                }
                $error50 = $lines | Select-String -Pattern 'error 50' | Select-Object -Last 1
                if ($error50) { Write-Host '  note: WinUSB error 50 present in the log (WinUSB needs a reboot after the driver switch).' -ForegroundColor Yellow }
            }
            else { Write-Host 'No *.log file yet (the core has not run).' }
        }
        else { Write-Host "No logs folder under $config." }
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
    if ($driverKind -and $driverKind -ne 'winusb') {
        $blockers.Add("adapter driver is '$driverKind', not winusb")
        if (-not $nextAction) { $nextAction = 'Run scripts\usb-driver.ps1 -Mode assign -Auto (UAC), then reboot if it reports reboot_required: true.' }
    }
    $rebootNeeded = ($record -and $record.reboot_required) -or ($logTail | Select-String -Pattern 'error 50' -Quiet)
    if ($blockers.Count -eq 0 -and $rebootNeeded) {
        $blockers.Add('WinUSB was bound but a reboot is still pending (error 50)')
        if (-not $nextAction) { $nextAction = 'Reboot Windows (or run scripts\usb-driver.ps1 -Mode restart -Auto elevated), then rerun this doctor.' }
    }
    if ($blockers.Count -eq 0) {
        Write-Host 'OK - the real-adapter path looks ready.' -ForegroundColor Green
        Write-Host 'Next action: run a2dpwb-core.exe --cli -d <headphone MAC> --test-tone (or start the UI).' -ForegroundColor Green
        exit 0
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
