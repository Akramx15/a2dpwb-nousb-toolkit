<#
.SYNOPSIS
    Cold-boot verification of the Realtek firmware path (A2DP-Windows-Bridge).

.DESCRIPTION
    The one case a USB device restart cannot reproduce: the Realtek module
    keeps the uploaded firmware in RAM, so a warm module boots even with no
    firmware on disk. Only a power cycle (a Windows reboot on a laptop with an
    internal module) makes it cold again, and only then does the original
    "failed to initialize WinUSB (error 50)" reproduce.

    Run this right after a Windows reboot. It performs three phases and always
    restores the firmware files, even if a phase fails:

      Phase 1 - cold module, firmware present
                Expect: "ROM LMP subversion" and "Realtek firmware download ran".
                This proves the module was cold and the firmware was uploaded.

      Phase 2 - cold module, firmware files removed
                Expect: "firmware file missing" warnings and the adapter
                failing to open. This is the scenario the upstream fix targets:
                the app must name the missing files instead of only showing
                "error 50".

      Phase 3 - .bin files restored, then stream
                Expect: the app recreates the extension-less aliases itself and
                the stream comes up with 0 dropped packets.

.PARAMETER Core
    Path to a2dpwb-core.exe. Default: the installed release.

.PARAMETER ScanSeconds
    Duration of the scan used as a probe.

.PARAMETER Headset
    Bluetooth address to stream to. Optional: with no address, phase 3 only
    verifies that the adapter opens again.

.PARAMETER Codec
    Codec for phase 3. Default ldac.

.PARAMETER StreamSeconds
    Duration of the phase 3 stream.

.PARAMETER DryRun
    Report what would be done and change nothing.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\cold-boot-test.ps1
    powershell -ExecutionPolicy Bypass -File scripts\cold-boot-test.ps1 -Headset AA:BB:CC:DD:EE:FF
#>
[CmdletBinding()]
param(
    [string]$Core = (Join-Path $env:LOCALAPPDATA 'A2DP Windows Bridge\a2dpwb-core.exe'),
    [int]$ScanSeconds = 6,
    [string]$ConfigDir = (Join-Path $env:APPDATA 'A2DPWB'),
    [string]$Headset = '',
    [string]$Codec = 'ldac',
    [int]$StreamSeconds = 20,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:FirmwareNames = @('rtl8852bu_fw', 'rtl8852bu_config', 'rtl8852bu_fw.bin', 'rtl8852bu_config.bin')
$script:BackupDir = Join-Path ([System.IO.Path]::GetTempPath()) ('a2dpwb-coldboot-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:Results = [System.Collections.Generic.List[object]]::new()

function Write-Section { param([string]$Text) Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Step   { param([string]$Text) Write-Host "   $Text" }

function Add-Result {
    param([string]$Phase, [string]$Expectation, [bool]$Ok, [string]$Evidence)
    $script:Results.Add([pscustomobject]@{ Phase = $Phase; Expectation = $Expectation; Ok = $Ok; Evidence = $Evidence })
    $mark = if ($Ok) { 'PASS' } else { 'FAIL' }
    $color = if ($Ok) { 'Green' } else { 'Yellow' }
    Write-Host ("   [{0}] {1}: {2}" -f $mark, $Phase, $Expectation) -ForegroundColor $color
    if ($Evidence) { Write-Step $Evidence }
}

function Invoke-Core {
    param([string[]]$Arguments)
    $out = & $Core @Arguments 2>&1 | Out-String
    return $out
}

function Get-FirmwareFiles {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return @() }
    $found = @()
    foreach ($n in $script:FirmwareNames) {
        $p = Join-Path $Dir $n
        if (Test-Path -LiteralPath $p) { $found += $p }
    }
    return $found
}

# --- preconditions -------------------------------------------------------------
Write-Section 'Preconditions'
if (-not (Test-Path -LiteralPath $Core)) {
    Write-Error "a2dpwb-core.exe not found at '$Core'. Pass -Core with the path to the binary (a portable build works too)."
    exit 2
}
Write-Step "core     : $Core"
Write-Step "config   : $ConfigDir"
Write-Step "scan     : ${ScanSeconds}s"

$adapter = Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match 'VID_0BDA&PID_4853' } | Select-Object -First 1
if ($adapter) {
    $service = (Get-PnpDeviceProperty -InstanceId $adapter.InstanceId -KeyName 'DEVPKEY_Device_Service' -ErrorAction SilentlyContinue).Data
    Write-Step "adapter  : $($adapter.InstanceId) [$($adapter.Status)] service=$service"
    if ($service -ne 'WINUSB') {
        Write-Warning "The adapter is not on WinUSB (service=$service). Assign it first, or the run cannot open it."
    }
} else {
    Write-Warning 'No Realtek 0BDA:4853 adapter found in the PnP tree.'
}

$before = Get-FirmwareFiles -Dir $ConfigDir
Write-Step ("firmware : {0} file(s) present in the config folder" -f $before.Count)

if ($DryRun) {
    Write-Section 'Dry run - nothing was changed'
    Write-Step 'Phases that would run:'
    Write-Step "  1. cold module, firmware present   (scan $ScanSeconds s)"
    Write-Step '  2. firmware moved away             (scan)'
    Write-Step "  3. .bin restored, stream to '$Headset' (${StreamSeconds}s)"
    Write-Step "backup dir would be: $script:BackupDir"
    exit 0
}

# --- phase 1: cold module with the firmware present ----------------------------
Write-Section 'Phase 1 - cold module, firmware present'
$log1 = Invoke-Core -Arguments @('--cli', '--scan', "$ScanSeconds")
$rom = [regex]::Match($log1, 'ROM LMP subversion ([0-9a-fA-Fx]+)')
$dl = $log1 -match 'Realtek firmware download ran'
$warm = $log1 -match 'Firmware already exists'
Add-Result -Phase 'phase 1' -Expectation 'module is cold and the firmware was uploaded' `
    -Ok ($dl -and -not $warm) -Evidence ("ROM LMP subversion: " + $(if ($rom.Success) { $rom.Groups[1].Value } else { 'n/a' }) + "; download ran: $dl; warm module: $warm")

# --- phase 2: firmware removed --------------------------------------------------
Write-Section 'Phase 2 - cold module, firmware files removed'
New-Item -ItemType Directory -Force -Path $script:BackupDir | Out-Null
$moved = @()
try {
    foreach ($n in $script:FirmwareNames) {
        $p = Join-Path $ConfigDir $n
        if (Test-Path -LiteralPath $p) {
            Move-Item -LiteralPath $p -Destination $script:BackupDir -Force
            $moved += $n
        }
    }
    Write-Step ("moved away: " + ($moved -join ', '))
    $log2 = Invoke-Core -Arguments @('--cli', '--scan', "$ScanSeconds")
    $warned = $log2 -match 'firmware file missing'
    $failed = $log2 -match 'cannot open the HCI transport'
    $hint = ($log2 -split "`n" | Where-Object { $_ -match 'firmware' } | Select-Object -First 3) -join ' | '
    Add-Result -Phase 'phase 2' -Expectation 'the app names the missing firmware and explains the failure' `
        -Ok ($warned -and $failed) -Evidence ("missing-file warning: $warned; adapter open failed: $failed; log: $hint")
}
finally {
    foreach ($n in $script:FirmwareNames) {
        $src = Join-Path $script:BackupDir $n
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $ConfigDir $n) -Force
        }
    }
    Write-Step 'firmware files restored'
    Remove-Item -LiteralPath $script:BackupDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- phase 3: .bin files back, then stream --------------------------------------
Write-Section 'Phase 3 - .bin files restored, then stream'
# only the .bin files stay; the extension-less copies are made by the app
foreach ($n in @('rtl8852bu_fw', 'rtl8852bu_config')) {
    $p = Join-Path $ConfigDir $n
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}
$log3 = Invoke-Core -Arguments @('--cli', '--scan', "$ScanSeconds")
$aliasFw = Test-Path -LiteralPath (Join-Path $ConfigDir 'rtl8852bu_fw')
$aliasCfg = Test-Path -LiteralPath (Join-Path $ConfigDir 'rtl8852bu_config')
$opened = $log3 -match 'USB: opened'
Add-Result -Phase 'phase 3a' -Expectation 'the app recreates the extension-less aliases and opens the adapter' `
    -Ok ($aliasFw -and $aliasCfg -and $opened) -Evidence ("alias rtl8852bu_fw: $aliasFw; alias rtl8852bu_config: $aliasCfg; adapter opened: $opened")

if ($Headset) {
    $log4 = Invoke-Core -Arguments @('--cli', '-d', $Headset, '-c', $Codec, '--duration', "$StreamSeconds")
    $streaming = $log4 -match 'state Streaming: Connected'
    $sent = [regex]::Match($log4, 'Sent (\d+) media packets \((\d+) bytes\), (\d+) dropped')
    Add-Result -Phase 'phase 3b' -Expectation "the $Codec stream runs with 0 dropped packets" `
        -Ok ($streaming -and $sent.Success -and ([int]$sent.Groups[3].Value -eq 0)) `
        -Evidence $(if ($sent.Success) { "packets=$($sent.Groups[1].Value) bytes=$($sent.Groups[2].Value) dropped=$($sent.Groups[3].Value)" } else { 'no packet summary' })
} else {
    Write-Step 'no -Headset given: the stream phase was skipped'
}

# --- summary --------------------------------------------------------------------
Write-Section 'Summary'
$script:Results | Format-Table -AutoSize | Out-String | Write-Host
$failed = @($script:Results | Where-Object { -not $_.Ok })
if ($failed.Count -gt 0) {
    Write-Host "RESULT: $($failed.Count) of $($script:Results.Count) phases did not meet the expectation." -ForegroundColor Yellow
    exit 1
}
Write-Host "RESULT: all $($script:Results.Count) phases behaved as expected." -ForegroundColor Green
exit 0
