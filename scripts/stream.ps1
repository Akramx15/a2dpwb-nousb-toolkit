<#
.SYNOPSIS
Daily-use launcher for A2DP-Windows-Bridge: streams Windows audio to the
headphones with the installed a2dpwb-core.exe.

.DESCRIPTION
Locates the installed core at
  $env:LOCALAPPDATA\A2DP Windows Bridge\a2dpwb-core.exe
prints the exact command line, then runs it in the foreground (Ctrl+C stops)
or in the background (-Background).

Capture modes (-Mode):
  loopback  WASAPI loopback of the default output device (the default). The
            PC speakers still play the audio: loopback taps the mix, it does
            not mute it.
  virtual   capture a render device, e.g. VB-CABLE. The core makes it the
            default output for the session (auto_switch) and restores the
            previous default when the stream stops. Audio is then heard only
            in the headphones.
  app       capture one application's process tree (--app). Its audio still
            plays on the default output as well.

The flags map one-to-one to upstream app/src/core/src/cli.rs; nothing is
invented. Only the options selected here are passed.

.PARAMETER Device
Bluetooth address of the headphones. Default <HEADSET_MAC>
(the headset). Maps to -d.

.PARAMETER Codec
ldac (default), aptxhd, aptxll, aptx, sbcxq, sbc, aac, lhdcv5, opus,
opus05, faststream or auto. Maps to -c.

.PARAMETER Quality
hq (default), sq, mq, or mhq (LHDC V5 only). Maps to -q.

.PARAMETER Abr
Adaptive bit rate (LDAC, LHDC V5). Maps to -a.

.PARAMETER Rate
Capture sample rate in Hz. 0 (default) leaves --rate out, so the device's
rate is used. 96000 passes --rate 96000.

.PARAMETER Mode
loopback (default), virtual or app. Maps to -m.

.PARAMETER AudioDevice
Render device ID for -Mode virtual, e.g.
'{0.0.0.00000000}.{...}'. Maps to --audio-device.

.PARAMETER App
Executable for -Mode app, e.g. Spotify.exe. Maps to --app.

.PARAMETER TestTone
Stream a 1 kHz left / 1.5 kHz right test tone at 48 kHz instead of capture.
Maps to --test-tone.

.PARAMETER Duration
Seconds to stream; 0 (default) streams until Ctrl+C. Maps to --duration.

.PARAMETER Background
Start the core detached, print its PID, log files and the stop command, and
return immediately.

.PARAMETER Help
Print this comment-based help and exit.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stream.ps1

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stream.ps1 -Codec ldac -Quality hq -TestTone -Duration 10

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stream.ps1 -Mode virtual -AudioDevice '{0.0.0.00000000}.{your-cable-endpoint-guid}'

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stream.ps1 -Background

.NOTES
Exit codes: 0 the core finished successfully (or a background run started),
1 the core failed, 2 bad arguments or a2dpwb-core.exe is missing.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Device = '<HEADSET_MAC>',
    [ValidateSet('ldac', 'aptxhd', 'aptxll', 'aptx', 'sbcxq', 'sbc', 'aac', 'lhdcv5', 'opus', 'opus05', 'faststream', 'auto')]
    [string]$Codec = 'ldac',
    [ValidateSet('hq', 'sq', 'mq', 'mhq')]
    [string]$Quality = 'hq',
    [switch]$Abr,
    [ValidateRange(0, 789000)]
    [int]$Rate = 0,
    [ValidateSet('loopback', 'virtual', 'app')]
    [string]$Mode = 'loopback',
    [string]$AudioDevice,
    [string]$App,
    [switch]$TestTone,
    [ValidateRange(0, 86400)]
    [int]$Duration = 0,
    [switch]$Background,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$LASTEXITCODE = 0

if ($Help) {
    Get-Help -Name $PSCommandPath -Full
    exit 0
}

function Quote-Argument {
    param([string]$Value)
    if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
    return $Value
}

function Test-BluetoothAddress {
    param([string]$Value)
    $Value = $Value.Trim()
    if ($Value -match '^[0-9A-Fa-f]{12}$') { return $true }
    return $Value -match '^([0-9A-Fa-f]{2}[:.\- ]){5}[0-9A-Fa-f]{2}$'
}

function Fail {
    param([string]$Message, [int]$Code)
    [Console]::Error.WriteLine($Message)
    exit $Code
}

if (-not (Test-BluetoothAddress -Value $Device)) {
    Fail "Invalid Bluetooth address '$Device' (-Device). Use 12 hex digits, e.g. <HEADSET_MAC>." 2
}

if ($Mode -eq 'virtual' -and [string]::IsNullOrWhiteSpace($AudioDevice)) {
    Fail '-Mode virtual needs -AudioDevice <render device id>. List the IDs with: Get-PnpDevice -Class AudioEndpoint -Status OK | Where-Object { $_.InstanceId -like ''SWD\MMDEVAPI\{0.0.0.*'' } | Select-Object FriendlyName, @{n=''AudioDeviceId'';e={ $_.InstanceId -replace ''^SWD\\MMDEVAPI\\'','''' }}' 2
}
if ($Mode -eq 'app' -and [string]::IsNullOrWhiteSpace($App)) {
    Fail '-Mode app needs -App <executable>, e.g. -App Spotify.exe.' 2
}
if ($Mode -ne 'virtual' -and -not [string]::IsNullOrWhiteSpace($AudioDevice)) {
    Write-Warning "-AudioDevice is only used with -Mode virtual; ignoring it for -Mode $Mode."
}
if ($Mode -ne 'app' -and -not [string]::IsNullOrWhiteSpace($App)) {
    Write-Warning "-App is only used with -Mode app; ignoring it for -Mode $Mode."
}

$CoreExe = Join-Path $env:LOCALAPPDATA 'A2DP Windows Bridge\a2dpwb-core.exe'
if (-not (Test-Path -LiteralPath $CoreExe -PathType Leaf)) {
    Fail "a2dpwb-core.exe not found at:`n  $CoreExe`nInstall A2DP-Windows-Bridge v2.0.1 (see README section 6); the launcher always uses the installed core." 2
}

$CoreArgs = @('--cli', '-d', $Device, '-c', $Codec, '-q', $Quality)
if ($Abr) { $CoreArgs += '-a' }
$CoreArgs += @('-m', $Mode)
if ($Mode -eq 'virtual') { $CoreArgs += @('--audio-device', $AudioDevice) }
if ($Mode -eq 'app') { $CoreArgs += @('--app', $App) }
if ($Rate -gt 0) { $CoreArgs += @('--rate', "$Rate") }
if ($TestTone) { $CoreArgs += '--test-tone' }
if ($Duration -gt 0) { $CoreArgs += @('--duration', "$Duration") }

$Display = (@($CoreExe) + $CoreArgs) | ForEach-Object { Quote-Argument $_ }
Write-Host 'A2DP-Windows-Bridge stream launcher'
Write-Host "Core  : $CoreExe"
Write-Host "Mode  : $Mode   Codec: $Codec   Quality: $Quality"
if ($Rate -gt 0) { Write-Host "Rate  : $Rate Hz" } else { Write-Host 'Rate  : device default' }
if ($TestTone) { Write-Host 'Source: test tone (1 kHz left / 1.5 kHz right)' }
if ($Duration -gt 0) { Write-Host "Length: $Duration s" } else { Write-Host 'Length: until Ctrl+C' }
Write-Host ''
Write-Host ('Command: ' + ($Display -join ' '))
Write-Host ''

if ($Background) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $Artifacts = Join-Path $RepoRoot 'artifacts'
    if (-not (Test-Path -LiteralPath $Artifacts -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $Artifacts | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outLog = Join-Path $Artifacts "stream-$stamp.out.log"
    $errLog = Join-Path $Artifacts "stream-$stamp.err.log"
    try {
        $proc = Start-Process -FilePath $CoreExe -ArgumentList ($CoreArgs | ForEach-Object { Quote-Argument $_ }) `
            -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru -WindowStyle Hidden
    }
    catch {
        Fail "Could not start a2dpwb-core.exe: $($_.Exception.Message)" 1
    }
    Write-Host "Started in the background: PID $($proc.Id)"
    Write-Host "Output : $outLog"
    Write-Host "Errors : $errLog"
    Write-Host "Stop   : Stop-Process -Id $($proc.Id)"
    exit 0
}

& $CoreExe @CoreArgs
$code = $LASTEXITCODE
Write-Host ''
Write-Host "a2dpwb-core.exe exited with code $code."
exit $code
