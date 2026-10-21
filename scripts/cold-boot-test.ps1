<#
.SYNOPSIS
    Cold-boot verification of the Realtek firmware path (A2DP-Windows-Bridge).

.DESCRIPTION
    Two independent conditions are often confused, and this script keeps them
    apart:

      * "failed to initialize WinUSB (error 50)" means the WinUSB binding is
        not live yet. It clears only after the device is re-enumerated (unplug
        and replug the adapter, or reboot). It is NOT caused by missing
        Realtek firmware.
      * Missing Realtek firmware is a separate case: the module stays in ROM
        mode (ROM LMP 0x8852). The Realtek ROM code still serves HCI, so an
        unpatched module can still open the adapter and bring HCI up; the
        2.0.2+ beta then names the missing files with "firmware file missing"
        warnings.

    The script adapts to the state it finds and always restores the firmware:

      Mode Missing (files absent at start, normally run right after a reboot)
        phase 1  Expect the app to name the missing .bin files
                 ("firmware file missing" warnings); that is the requirement.
                 If the adapter still opens, report it as a NOTE: a ROM-mode
                 module serves HCI. An open failure is recorded as an
                 additional finding (normally the WinUSB binding is not live),
                 never as a requirement. -StreamInPhase1 (on by default) then
                 records, informationally, whether an unpatched ROM-mode
                 module can stream A2DP.
        phase 2  Restore the .bin files: on 2.0.2+ expect them to be used
                 directly, the extension-less copies to stay absent and the
                 firmware to be downloaded (ROM LMP subversion); on 2.0.1 the
                 extension-less copies are the legacy requirement. The adapter
                 must open either way.
        phase 3  Stream to the headset (0 dropped packets expected).

      Mode Present (cold + files present at start)
        phase 1  Expect the module to be cold and the firmware uploaded
                 (ROM LMP subversion + "Realtek firmware download ran"). A
                 warm module is reported as PASS-with-note, because this run
                 cannot prove the cold case.
        phase 2  Informational probe: remove all present firmware files and expect the
                 app to name them. A module that still has the firmware in RAM
                 may still open; that is EXPECTED and reported as
                 PASS-with-note, not as a failure.
        phase 3  2.0.2+: the .bin files stay, the app does not need
                 extension-less copies (identical ones are removed on a scan),
                 uses the .bin files and opens the adapter.
                 2.0.1: the extension-less copies are the legacy requirement.
                Then stream.

    Mode Auto (default) picks Missing when no .bin file is present and Present
    when both .bin files are present. A partial .bin set is a precondition
    error. The extension-less copies are optional on 2.0.2+ (not needed; a scan
    removes identical ones) and required on 2.0.1.

    Beta-only checks (the "firmware file missing:" warning) are marked
    "SKIPPED (needs 2.0.2+)" on 2.0.1 instead of failing. Use -RequireBeta to
    make a non-beta binary a precondition error. The script prints which copy
    expectation applies before it runs.

.PARAMETER Core
    Path to a2dpwb-core.exe. Default: the installed release under
    %LOCALAPPDATA%\A2DP Windows Bridge (the portable beta next to this
    repository is used when present).

.PARAMETER Mode
    Auto (default), Present or Missing. See the description.

.PARAMETER RequireBeta
    Fail with exit code 2 unless the binary reports 2.0.2+ / beta.

.PARAMETER ScanSeconds
    Duration of each scan used as a probe.

.PARAMETER ConfigDir
    Firmware/config folder. Default: %APPDATA%\A2DPWB.

.PARAMETER BackupDir
    Safe copy of the firmware files, used by cold-boot-round2.ps1 and as the
    restore source in Mode Missing. Default: %APPDATA%\A2DPWB-coldboot-backup.

.PARAMETER OutputFile
    Base path for the raw per-phase app logs. The raw output of each phase is
    written as <output>.phase1.log, <output>.phase2.log and
    <output>.phase3.log; the summary itself goes to the console (the Startup
    entry written by cold-boot-round2.ps1 redirects it to <output>). Default:
    %USERPROFILE%\Documents\opencode\a2db\work\cold-boot-test.txt.

.PARAMETER Headset
    Bluetooth address to stream to. Optional: with no address, the last phase
    only verifies that the adapter opens again.

.PARAMETER Codec
    Codec for the stream phase. Default: ldac.

.PARAMETER StreamSeconds
    Duration of the stream phase.

.PARAMETER StreamInPhase1
    On by default in -Mode Missing: after the missing-file probe, attempt a
    short stream (at least 10 s) to record whether an unpatched, ROM-mode
    module can stream A2DP. The outcome is informational and never affects the
    phase verdict. Pass -StreamInPhase1:$false to disable it.

.PARAMETER DryRun
    Report the resolved core, the mode and the phases, and change nothing.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\cold-boot-test.ps1 -DryRun

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\cold-boot-test.ps1 -RequireBeta

.NOTES
    Targets A2DP-Windows-Bridge 2.0.2-beta.4 and newer; 2.0.1 runs with the
    legacy copy expectation.
    Exit codes: 0 all expectations met (notes and version skips allowed),
    1 at least one expectation failed, 2 precondition error.
#>
[CmdletBinding()]
param(
    [string]$Core = '',
    [ValidateSet('Auto', 'Present', 'Missing')]
    [string]$Mode = 'Auto',
    [switch]$RequireBeta,
    [int]$ScanSeconds = 6,
    [string]$ConfigDir = (Join-Path $env:APPDATA 'A2DPWB'),
    [string]$FirmwareDir = '',
    [string]$BackupDir = (Join-Path $env:APPDATA 'A2DPWB-coldboot-backup'),
    [string]$OutputFile = (Join-Path $env:USERPROFILE 'Documents\opencode\a2db\work\cold-boot-test.txt'),
    [string]$Headset = '',
    [string]$Codec = 'ldac',
    [int]$StreamSeconds = 20,
    [switch]$StreamInPhase1 = $true,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:FirmwareNames = @('rtl8852bu_fw', 'rtl8852bu_config', 'rtl8852bu_fw.bin', 'rtl8852bu_config.bin')
$script:AliasNames = @('rtl8852bu_fw', 'rtl8852bu_config')
$script:BinaryNames = @('rtl8852bu_fw.bin', 'rtl8852bu_config.bin')
$script:Results = New-Object System.Collections.Generic.List[object]
$script:ProbeDir = $null
$script:PhaseLogs = @()

# 2.0.2-beta.5 moved the firmware files into the "firmware" subfolder of the
# config folder; 2.0.2-beta.4 and older kept them in the config folder itself.
if (-not $FirmwareDir) {
    $modernFwDir = Join-Path $ConfigDir 'firmware'
    if (Test-Path -LiteralPath $modernFwDir -PathType Container) { $FirmwareDir = $modernFwDir }
    else { $FirmwareDir = $ConfigDir }
}

function Write-Section { param([string]$Text) Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Step { param([string]$Text) Write-Host "   $Text" }

function Add-Result {
    param(
        [string]$Phase,
        [string]$Expectation,
        [ValidateSet('PASS', 'NOTE', 'FAIL', 'SKIP', 'INFO')]
        [string]$Status,
        [string]$Evidence = ''
    )
    $script:Results.Add([pscustomobject]@{ Phase = $Phase; Status = $Status; Expectation = $Expectation; Evidence = $Evidence })
    $label = switch ($Status) {
        'PASS' { 'PASS' }
        'NOTE' { 'PASS (note)' }
        'FAIL' { 'FAIL' }
        'SKIP' { 'SKIPPED' }
        'INFO' { 'INFO' }
    }
    $color = switch ($Status) {
        'PASS' { 'Green' }
        'NOTE' { 'Cyan' }
        'FAIL' { 'Red' }
        'SKIP' { 'DarkGray' }
        'INFO' { 'Gray' }
    }
    Write-Host ("   [{0}] {1}: {2}" -f $label, $Phase, $Expectation) -ForegroundColor $color
    if ($Evidence) { Write-Step $Evidence }
}

function Remove-Ansi {
    param([string]$Text)
    return [regex]::Replace($Text, '\x1B\[[0-9;]*[A-Za-z]', '')
}

function Save-PhaseLog {
    param([int]$Phase, [string]$Text, [switch]$Append)
    if (-not $OutputFile) { return }
    $dir = Split-Path -Parent $OutputFile
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $path = "$OutputFile.phase$Phase.log"
    if ($Append -and (Test-Path -LiteralPath $path -PathType Leaf)) {
        [System.IO.File]::AppendAllText($path, $Text, [System.Text.Encoding]::UTF8)
    }
    else {
        [System.IO.File]::WriteAllText($path, $Text, [System.Text.Encoding]::UTF8)
    }
    if (-not ($script:PhaseLogs -contains $path)) { $script:PhaseLogs += $path }
    Write-Step "raw phase $Phase log: $path"
}

function Invoke-Core {
    param([string[]]$Arguments)
    # The core logs to stderr; with $ErrorActionPreference = 'Stop' that would
    # abort the script on the first log line, so relax it for the call only.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Core @Arguments 2>&1 | Out-String -Width 300
        return (Remove-Ansi $out)
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

function Get-CoreVersion {
    param([string]$Path)
    $vi = (Get-Item -LiteralPath $Path).VersionInfo
    $version = [string]$vi.FileVersion
    if (-not $version) { $version = [string]$vi.ProductVersion }
    return $version
}

function Test-BetaVersion {
    param([string]$Version)
    if (-not $Version) { return $false }
    if ($Version -match '(?i)beta') { return $true }
    $m = [regex]::Match($Version, '(\d+)\.(\d+)\.(\d+)')
    if (-not $m.Success) { return $false }
    $v = [version]('{0}.{1}.{2}' -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value)
    return ($v -ge [version]'2.0.2')
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

function Restore-FirmwareFiles {
    param([string]$FromDir, [string[]]$Names)
    $restored = @()
    foreach ($n in $Names) {
        $src = Join-Path $FromDir $n
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dst = Join-Path $FirmwareDir $n
        $done = $false
        for ($i = 0; $i -lt 10 -and -not $done; $i++) {
            try {
                if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force }
                Copy-Item -LiteralPath $src -Destination $dst -Force
                $done = $true
            }
            catch {
                Start-Sleep -Milliseconds 200
            }
        }
        if ($done) { $restored += $n }
    }
    return $restored
}

function Get-WarningLines {
    param([string]$Log)
    return @(($Log -split "`r?`n") | Where-Object { $_ -match 'firmware file missing:' } | ForEach-Object { $_.Trim() })
}

function Get-DecisiveLines {
    param([string]$Log)
    return @(($Log -split "`r?`n") | Where-Object { $_ -match 'ERROR|WARN|failed|cannot open|refused|not found|missing' } |
        Select-Object -First 6 | ForEach-Object { $_.Trim() })
}

function Test-WarmLog {
    param([string]$Log)
    return (($Log -match 'Firmware already exists') -or ($Log -match 'already running from an earlier session'))
}

# --- preconditions -------------------------------------------------------------
Write-Section 'Preconditions'

if (-not $Core) {
    $betaCandidate = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\beta-2.0.2-beta.1\A2DPWB-2.0.2-beta.1\a2dpwb-core.exe'))
    $installed = Join-Path $env:LOCALAPPDATA 'A2DP Windows Bridge\a2dpwb-core.exe'
    if (Test-Path -LiteralPath $betaCandidate) {
        $Core = $betaCandidate
        $coreSource = 'default: portable beta'
    }
    else {
        $Core = $installed
        $coreSource = 'default: installed stable (beta not found)'
    }
}
else {
    $coreSource = '-Core parameter'
}

if (-not (Test-Path -LiteralPath $Core)) {
    Write-Host "ERROR: a2dpwb-core.exe not found at '$Core'." -ForegroundColor Red
    Write-Host 'Pass -Core with the path to the binary (a portable build works too).'
    exit 2
}
$Core = (Resolve-Path -LiteralPath $Core).Path

$version = Get-CoreVersion -Path $Core
$isBeta = Test-BetaVersion -Version $version
Write-Step "core     : $Core"
Write-Step "source   : $coreSource"
Write-Step "version  : $(if ($version) { $version } else { 'unknown' })"
Write-Step "beta     : $(if ($isBeta) { 'yes (2.0.2+ / beta)' } else { 'no' })"
if ($isBeta) {
    $copyExpectation = '2.0.2+: the app uses the .bin files and removes identical extension-less copies on a scan (PR #97); copies absent is correct'
}
else {
    $copyExpectation = '2.0.1: the extension-less copies rtl8852bu_fw / rtl8852bu_config are required (BTstack opens those names); supply them with fetch-realtek-fw.ps1 -LegacyAliases'
}
Write-Step "copies   : $copyExpectation"

if ($RequireBeta -and -not $isBeta) {
    Write-Host "ERROR: -RequireBeta was given but '$Core' reports version '$version' (not 2.0.2+)." -ForegroundColor Red
    Write-Host 'Point -Core at the 2.0.2-beta.1 portable build, or drop -RequireBeta.'
    exit 2
}

$adapter = Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match 'VID_0BDA&PID_4853' } | Select-Object -First 1
if ($adapter) {
    $service = (Get-PnpDeviceProperty -InstanceId $adapter.InstanceId -KeyName 'DEVPKEY_Device_Service' -ErrorAction SilentlyContinue).Data
    Write-Step "adapter  : $($adapter.InstanceId) [$($adapter.Status)] service=$service"
    if ($service -ne 'WINUSB') {
        Write-Warning "The adapter is not on WinUSB (service=$service). Assign it first, or the run cannot open it."
    }
}
else {
    Write-Warning 'No Realtek 0BDA:4853 adapter found in the PnP tree.'
}

Write-Step "config   : $ConfigDir"
Write-Step "firmware : $FirmwareDir ($(if ($FirmwareDir -eq $ConfigDir) { 'the config folder itself - 2.0.2-beta.4 or older' } else { 'the firmware subfolder - 2.0.2-beta.5 or newer' }))"
Write-Step "scan     : ${ScanSeconds}s"
Write-Step "output   : $OutputFile"
Write-Step "raw logs : $OutputFile.phase1.log, $OutputFile.phase2.log, $OutputFile.phase3.log"

$present = @(Get-FirmwareFiles -Dir $FirmwareDir)
$presentBins = @($present | Where-Object { $script:BinaryNames -contains (Split-Path -Leaf $_) })
$presentCopies = @($present | Where-Object { $script:AliasNames -contains (Split-Path -Leaf $_) })
Write-Step ("firmware : {0} of 2 .bin file(s), {1} extension-less copy/copies present" -f $presentBins.Count, $presentCopies.Count)

$effectiveMode = $Mode
if ($Mode -eq 'Auto') {
    if ($presentBins.Count -eq 0) { $effectiveMode = 'Missing' }
    elseif ($presentBins.Count -eq 2) { $effectiveMode = 'Present' }
    else {
        Write-Host "ERROR: only $($presentBins.Count) of the two .bin firmware files are present; the state is inconsistent." -ForegroundColor Red
        Write-Host "Present: $((@($present | ForEach-Object { Split-Path -Leaf $_ })) -join ', ')"
        Write-Host 'Restore them (cold-boot-round2.ps1 -Abort) or pass -Mode explicitly.'
        exit 2
    }
}
elseif ($Mode -eq 'Present' -and $presentBins.Count -ne 2) {
    Write-Host "ERROR: -Mode Present requires both .bin firmware files, found $($presentBins.Count)." -ForegroundColor Red
    Write-Host 'Use -Mode Missing (right after a reboot) or restore the .bin files first.'
    exit 2
}
Write-Step "mode     : $effectiveMode (from $(if ($Mode -eq 'Auto') { 'Auto' } else { "-Mode $Mode" }))"

if (-not $Headset) {
    # The app keeps the known devices in devices.txt: "AA:BB:CC:DD:EE:FF|"
    $devicesFile = Join-Path $ConfigDir 'devices.txt'
    if (Test-Path -LiteralPath $devicesFile) {
        $known = Get-Content -LiteralPath $devicesFile |
            ForEach-Object { ($_ -split '\|')[0].Trim() } |
            Where-Object { $_ -match '^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$' } |
            Select-Object -First 1
        if ($known) {
            $Headset = $known
            Write-Step "headset  : $Headset (from devices.txt)"
        }
    }
}
if ($Headset) {
    if ($Headset -notmatch '^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$') {
        Write-Host "ERROR: '$Headset' is not a Bluetooth address." -ForegroundColor Red
        exit 2
    }
    Write-Step "stream to: $Headset"
}
else {
    Write-Step 'stream to: none found (the stream phase will be skipped)'
}

# --- dry run -------------------------------------------------------------------
if ($DryRun) {
    Write-Section 'Dry run - nothing was changed'
    Write-Step "copy expectation: $copyExpectation"
    if ($effectiveMode -eq 'Missing') {
        Write-Step 'Mode Missing: the .bin files are (or will be made) absent before the reboot.'
        Write-Step "  1. expect the app to name rtl8852bu_fw.bin / rtl8852bu_config.bin (scan ${ScanSeconds}s)"
        Write-Step '     an open on a ROM-mode module is a note, not a failure; an open failure is an additional finding'
        if ($StreamInPhase1 -and $Headset) {
            $p1Seconds = [Math]::Max($StreamSeconds, 10)
            Write-Step "  1b. informational: stream to '$Headset' for ${p1Seconds}s on the unpatched module"
        }
        if ($isBeta) {
            Write-Step "  2. restore the .bin files from $BackupDir, expect the .bin files used directly, no copies and a firmware download (scan ${ScanSeconds}s)"
        }
        else {
            Write-Step "  2. restore the .bin files from $BackupDir, expect the legacy extension-less copies and open (scan ${ScanSeconds}s)"
        }
        if ($Headset) {
            Write-Step "  3. stream to '$Headset' for ${StreamSeconds}s (0 dropped packets expected)"
        }
        else {
            Write-Step '  3. stream: skipped (no headset found)'
        }
        if (-not (Test-Path -LiteralPath $BackupDir)) {
            Write-Step "NOTE: $BackupDir does not exist yet; a real Missing run would exit 2."
        }
    }
    else {
        Write-Step 'Mode Present: the module is expected cold and the .bin files present.'
        Write-Step "  1. scan: expect ROM LMP subversion + 'Realtek firmware download ran' ($ScanSeconds s)"
        Write-Step "  2. informational: remove all present firmware files, expect the app to name them ($ScanSeconds s); a warm open is a note"
        if ($isBeta) {
            Write-Step "  3. drop any extension-less copies, expect the .bin files used directly and the copies to stay absent + open ($ScanSeconds s)"
        }
        else {
            Write-Step '  3. expect the legacy extension-less copies to remain present + open (2.0.1)'
        }
        if ($Headset) {
            Write-Step "  4. stream to '$Headset' for ${StreamSeconds}s (0 dropped packets expected)"
        }
        else {
            Write-Step '  4. stream: skipped (no headset found)'
        }
    }
    Write-Step "raw logs : <output>.phase1.log, <output>.phase2.log, <output>.phase3.log under $(Split-Path -Parent $OutputFile)"
    $finalNames = if ($isBeta) { 'the two .bin files' } else { 'the four legacy files' }
    Write-Step "finally  : restore $finalNames to $ConfigDir"
    Write-Step 'exit code: 0 (dry run)'
    exit 0
}

# --- run -----------------------------------------------------------------------
$exitCode = 0
try {
    if ($effectiveMode -eq 'Missing') {
        # Make the missing state real even if -Mode Missing was forced.
        if ($present.Count -gt 0) {
            New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
            foreach ($n in $script:FirmwareNames) {
                $p = Join-Path $FirmwareDir $n
                if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination (Join-Path $BackupDir $n) -Force }
            }
            $backupBins = @(Get-FirmwareFiles -Dir $BackupDir | Where-Object { $script:BinaryNames -contains (Split-Path -Leaf $_) })
            if ($backupBins.Count -ne 2) {
                Write-Host "ERROR: cannot build a backup with both .bin files in $BackupDir; nothing was removed." -ForegroundColor Red
                exit 2
            }
            foreach ($n in $script:FirmwareNames) {
                $p = Join-Path $FirmwareDir $n
                if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
            }
            Write-Step 'forced Missing: the present files were moved to the backup (the module may be warm)'
        }
        else {
            Write-Step "files already absent; restore source: $BackupDir"
        }

        $restoreBins = @(Get-FirmwareFiles -Dir $BackupDir | Where-Object { $script:BinaryNames -contains (Split-Path -Leaf $_) })
        if ($restoreBins.Count -ne 2) {
            Write-Host "ERROR: $BackupDir does not contain both .bin firmware files, so they could not be restored." -ForegroundColor Red
            Write-Host 'Run cold-boot-round2.ps1 -Abort on the machine that made the backup, or restore them manually.'
            exit 2
        }

        # --- phase 1: missing files -------------------------------------------
        Write-Section 'Phase 1 - firmware files missing'
        $missingWarm = $false
        if (-not $isBeta) {
            Add-Result -Phase 'phase 1' -Expectation 'the app names the missing firmware files' `
                -Status 'SKIP' -Evidence 'SKIPPED (needs 2.0.2+): 2.0.1 has no missing-firmware warning; it only reports the WinUSB error.'
        }
        else {
            $log1 = Invoke-Core -Arguments @('--cli', '--scan', "$ScanSeconds")
            Save-PhaseLog -Phase 1 -Text $log1
            $warnings = @(Get-WarningLines -Log $log1)
            $warned = $warnings.Count -gt 0
            $namedFw = $warned -and ($log1 -match 'rtl8852bu_fw(\.bin)?')
            $namedCfg = $warned -and ($log1 -match 'rtl8852bu_config(\.bin)?')
            $explains = ($log1 -match '(?i)realtek') -and ($log1 -match '(?i)firmware')
            $opened = $log1 -match 'USB: opened'
            $failedOpen = ($log1 -match 'cannot open the HCI transport') -or ($log1 -match 'failed to initialize WinUSB') -or ($log1 -match 'error 50')
            $missingWarm = $opened
            $evidence = "missing-file warnings: $($warnings.Count); named fw/config: $namedFw/$namedCfg; adapter opened: $opened; open failed: $failedOpen; Realtek firmware hint: $explains"
            if ($warnings.Count -gt 0) { $evidence += "; log: $($warnings -join ' | ')" }

            if (-not ($namedFw -and $namedCfg)) {
                Add-Result -Phase 'phase 1' -Expectation 'the app names the missing firmware files' -Status 'FAIL' -Evidence $evidence
            }
            elseif ($opened) {
                Add-Result -Phase 'phase 1' -Expectation 'the app names the missing firmware files' -Status 'NOTE' `
                    -Evidence ("the adapter still opened: a ROM-mode module serves HCI, so this is expected and not a failure; the verdict is the named diagnostics. $evidence")
            }
            elseif ($failedOpen) {
                Add-Result -Phase 'phase 1' -Expectation 'the app names the missing firmware files' -Status 'PASS' `
                    -Evidence ("additional finding: the adapter also failed to open (usually the WinUSB binding is not live; re-enumerate the device or reboot). $evidence")
            }
            else {
                Add-Result -Phase 'phase 1' -Expectation 'the app names the missing firmware files' -Status 'PASS' `
                    -Evidence ("the files were named; no open attempt was observed. $evidence")
            }

            # --- informational: can an unpatched, ROM-mode module stream? --------
            if ($StreamInPhase1) {
                if (-not $Headset) {
                    Add-Result -Phase 'phase 1' -Expectation 'stream on an unpatched module (informational)' -Status 'SKIP' `
                        -Evidence 'no headset address: the phase 1 stream probe was skipped.'
                }
                else {
                    $p1Seconds = [Math]::Max($StreamSeconds, 10)
                    Write-Section "Phase 1 (informational) - stream on the unpatched module for ${p1Seconds}s"
                    $logP1 = Invoke-Core -Arguments @('--cli', '-d', $Headset, '-c', $Codec, '--duration', "$p1Seconds")
                    Save-PhaseLog -Phase 1 -Text "`r`n===== informational stream probe =====`r`n$logP1" -Append
                    $streamingP1 = $logP1 -match 'state Streaming: Connected'
                    $sentP1 = [regex]::Match($logP1, 'Sent (\d+) media packets \((\d+) bytes\), (\d+) dropped')
                    if ($streamingP1 -and $sentP1.Success) {
                        $info = "packets=$($sentP1.Groups[1].Value) bytes=$($sentP1.Groups[2].Value) dropped=$($sentP1.Groups[3].Value)"
                        Add-Result -Phase 'phase 1' -Expectation 'stream on an unpatched module (informational)' -Status 'INFO' `
                            -Evidence "stream on an unpatched module: worked ($info); this does not affect the phase 1 verdict."
                    }
                    else {
                        $errorsP1 = @(($logP1 -split "`r?`n") | Where-Object { $_ -match '(?i)error|warn|failed|cannot|refused|codec|l2cap|not found' } |
                            Select-Object -First 4 | ForEach-Object { $_.Trim() })
                        $detail = if ($errorsP1.Count -gt 0) { $errorsP1 -join ' | ' } else { 'no decisive error line' }
                        Add-Result -Phase 'phase 1' -Expectation 'stream on an unpatched module (informational)' -Status 'INFO' `
                            -Evidence "stream on an unpatched module: failed with $detail; this does not affect the phase 1 verdict."
                    }
                }
            }
        }

        # --- phase 2: restore .bin, recover -----------------------------------
        Write-Section 'Phase 2 - .bin files restored, expect recovery'
        Write-Step "copy expectation: $copyExpectation"
        $restoredBins = Restore-FirmwareFiles -FromDir $BackupDir -Names $script:BinaryNames
        Write-Step ("restored: " + $(if ($restoredBins.Count -gt 0) { $restoredBins -join ', ' } else { 'none' }))
        $phase2Expectation = if ($isBeta) {
            'the .bin files are used directly, no extension-less copies are created, the firmware is downloaded and the adapter opens'
        }
        else {
            'the legacy extension-less copies are present and the adapter opens (2.0.1)'
        }
        if ($restoredBins.Count -ne 2) {
            Add-Result -Phase 'phase 2' -Expectation $phase2Expectation `
                -Status 'FAIL' -Evidence "could not restore both .bin files from $BackupDir"
        }
        elseif ($isBeta) {
            $log2 = Invoke-Core -Arguments @('--cli', '--scan', "$ScanSeconds")
            Save-PhaseLog -Phase 2 -Text $log2
            $rom = [regex]::Match($log2, 'ROM LMP subversion ([0-9A-Fa-fx]+)')
            $download = $log2 -match 'Realtek firmware download ran'
            $aliasFw = Test-Path -LiteralPath (Join-Path $ConfigDir 'rtl8852bu_fw')
            $aliasCfg = Test-Path -LiteralPath (Join-Path $ConfigDir 'rtl8852bu_config')
            $copiesAbsent = (-not $aliasFw) -and (-not $aliasCfg)
            $opened2 = $log2 -match 'USB: opened'
            $romText = if ($rom.Success) { $rom.Groups[1].Value } else { 'n/a' }
            $evidence = "ROM LMP subversion: $romText; download ran: $download; copies absent: $copiesAbsent (fw=$aliasFw, config=$aliasCfg); adapter opened: $opened2"
            if ($copiesAbsent -and $opened2 -and $download) {
                Add-Result -Phase 'phase 2' -Expectation $phase2Expectation -Status 'PASS' -Evidence $evidence
            }
            elseif ($copiesAbsent -and $opened2 -and $missingWarm) {
                Add-Result -Phase 'phase 2' -Expectation $phase2Expectation `
                    -Status 'NOTE' -Evidence ("warm module: .bin files used and open OK, download skipped as expected; this does not exercise the cold recovery. $evidence")
            }
            else {
                $why = if (-not $copiesAbsent) { 'the app created extension-less copies although 2.0.2+ must not' } elseif (-not $opened2) { 'the adapter did not open' } else { 'no firmware download was observed' }
                Add-Result -Phase 'phase 2' -Expectation $phase2Expectation -Status 'FAIL' -Evidence ("$why. $evidence")
            }
        }
        else {
            $log2 = Invoke-Core -Arguments @('--cli', '--scan', "$ScanSeconds")
            Save-PhaseLog -Phase 2 -Text $log2
            $aliasFw = Test-Path -LiteralPath (Join-Path $ConfigDir 'rtl8852bu_fw')
            $aliasCfg = Test-Path -LiteralPath (Join-Path $ConfigDir 'rtl8852bu_config')
            $opened2 = $log2 -match 'USB: opened'
            $evidence = "legacy copies present: fw=$aliasFw, config=$aliasCfg; adapter opened: $opened2"
            if (-not ($aliasFw -and $aliasCfg)) {
                Add-Result -Phase 'phase 2' -Expectation $phase2Expectation -Status 'SKIP' `
                    -Evidence ("2.0.1 legacy copies are absent; supply them with fetch-realtek-fw.ps1 -LegacyAliases. $evidence")
            }
            elseif ($opened2) {
                Add-Result -Phase 'phase 2' -Expectation $phase2Expectation -Status 'PASS' -Evidence $evidence
            }
            else {
                Add-Result -Phase 'phase 2' -Expectation $phase2Expectation -Status 'FAIL' -Evidence $evidence
            }
        }

        # --- phase 3: stream --------------------------------------------------
        Write-Section 'Phase 3 - stream after recovery'
        if (-not $Headset) {
            Add-Result -Phase 'phase 3' -Expectation "the $Codec stream runs with 0 dropped packets" -Status 'SKIP' `
                -Evidence 'no headset address: the stream phase was skipped'
        }
        else {
            $log3 = Invoke-Core -Arguments @('--cli', '-d', $Headset, '-c', $Codec, '--duration', "$StreamSeconds")
            Save-PhaseLog -Phase 3 -Text $log3
            $streaming = $log3 -match 'state Streaming: Connected'
            $sent = [regex]::Match($log3, 'Sent (\d+) media packets \((\d+) bytes\), (\d+) dropped')
            $errors = @(Get-DecisiveLines -Log $log3)
            $ok = $streaming -and $sent.Success -and ([int]$sent.Groups[3].Value -eq 0)
            $evidence = if ($sent.Success) {
                "packets=$($sent.Groups[1].Value) bytes=$($sent.Groups[2].Value) dropped=$($sent.Groups[3].Value); streaming=$streaming"
            }
            else {
                "no packet summary; streaming=$streaming"
            }
            if (-not $ok -and $errors.Count -gt 0) { $evidence += "; log: $($errors -join ' | ')" }
            Add-Result -Phase 'phase 3' -Expectation "the $Codec stream runs with 0 dropped packets" `
                -Status $(if ($ok) { 'PASS' } else { 'FAIL' }) -Evidence $evidence
        }
    }
    else {
        # --- Present: phase 1 cold verification -------------------------------
        Write-Section 'Phase 1 - module cold and firmware present'
        $log1 = Invoke-Core -Arguments @('--cli', '--scan', "$ScanSeconds")
        Save-PhaseLog -Phase 1 -Text $log1
        $rom = [regex]::Match($log1, 'ROM LMP subversion ([0-9A-Fa-fx]+)')
        $download = $log1 -match 'Realtek firmware download ran'
        $warm = Test-WarmLog -Log $log1
        $opened1 = $log1 -match 'USB: opened'
        $romText = if ($rom.Success) { $rom.Groups[1].Value } else { 'n/a' }
        if ($download -and -not $warm) {
            Add-Result -Phase 'phase 1' -Expectation 'module is cold and the firmware was uploaded' -Status 'PASS' `
                -Evidence "ROM LMP subversion: $romText; download ran: $download; warm: $warm; adapter opened: $opened1"
        }
        elseif ($warm) {
            Add-Result -Phase 'phase 1' -Expectation 'module is cold and the firmware was uploaded' -Status 'NOTE' `
                -Evidence "warm module ('Firmware already exists' / download skipped): this run cannot prove the cold+present case. Reboot and rerun for that. ROM LMP subversion: $romText; adapter opened: $opened1"
        }
        else {
            Add-Result -Phase 'phase 1' -Expectation 'module is cold and the firmware was uploaded' -Status 'FAIL' `
                -Evidence "no 'Realtek firmware download ran' and no warm marker; ROM LMP subversion: $romText; adapter opened: $opened1"
        }

        # --- Present: phase 2 informational missing-files probe ---------------
        Write-Section 'Phase 2 (informational) - firmware files removed'
        if (-not $isBeta) {
            Add-Result -Phase 'phase 2' -Expectation 'the app names the missing firmware files' -Status 'SKIP' `
                -Evidence 'SKIPPED (needs 2.0.2+): 2.0.1 only reports the WinUSB error.'
        }
        else {
            $script:ProbeDir = Join-Path ([System.IO.Path]::GetTempPath()) ('a2dpwb-coldboot-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Force -Path $script:ProbeDir | Out-Null
            $moved = @()
            try {
                foreach ($n in $script:FirmwareNames) {
                    $p = Join-Path $FirmwareDir $n
                    if (Test-Path -LiteralPath $p) {
                        Move-Item -LiteralPath $p -Destination (Join-Path $script:ProbeDir $n) -Force
                        $moved += $n
                    }
                }
                Write-Step ("moved away: " + ($moved -join ', '))

                $log2 = Invoke-Core -Arguments @('--cli', '--scan', "$ScanSeconds")
                Save-PhaseLog -Phase 2 -Text $log2
                $warnings = @(Get-WarningLines -Log $log2)
                $warned = $warnings.Count -gt 0
                $namedFw = $warned -and ($log2 -match 'rtl8852bu_fw(\.bin)?')
                $namedCfg = $warned -and ($log2 -match 'rtl8852bu_config(\.bin)?')
                $opened2 = $log2 -match 'USB: opened'
                $failed2 = ($log2 -match 'cannot open the HCI transport') -or ($log2 -match 'failed to initialize WinUSB') -or ($log2 -match 'error 50')
                $evidence = "missing-file warnings: $($warnings.Count); named fw/config: $namedFw/$namedCfg; adapter opened: $opened2; open failed: $failed2"
                if ($warnings.Count -gt 0) { $evidence += "; log: $($warnings -join ' | ')" }

                if (-not ($namedFw -and $namedCfg)) {
                    Add-Result -Phase 'phase 2' -Expectation 'the app names the missing firmware files' -Status 'FAIL' -Evidence $evidence
                }
                elseif ($opened2) {
                    Add-Result -Phase 'phase 2' -Expectation 'the app names the missing firmware files' -Status 'NOTE' `
                        -Evidence ("the adapter still opened although the firmware files were missing - EXPECTED, not a failure (a ROM-mode module serves HCI; a module with the firmware in RAM also keeps it). The app named the files. $evidence")
                }
                elseif ($failed2) {
                    Add-Result -Phase 'phase 2' -Expectation 'the app names the missing firmware files' -Status 'PASS' `
                        -Evidence ("additional finding: the adapter also failed to open (usually the WinUSB binding is not live). $evidence")
                }
                else {
                    Add-Result -Phase 'phase 2' -Expectation 'the app names the missing firmware files' -Status 'PASS' `
                        -Evidence ("the files were named; no open attempt was observed. $evidence")
                }
            }
            finally {
                $restored = Restore-FirmwareFiles -FromDir $script:ProbeDir -Names $script:FirmwareNames
                Write-Step ("firmware restored after the probe: " + $(if ($restored.Count -gt 0) { $restored -join ', ' } else { 'none' }))
            }
        }

        # --- Present: phase 3 adaptive copy check + stream --------------------
        Write-Section 'Phase 3 - .bin files in place, copy expectation, then stream'
        Write-Step "copy expectation: $copyExpectation"
        if ($isBeta) {
            # 2.0.2+ uses the .bin files; identical extension-less copies are obsolete.
            foreach ($n in $script:AliasNames) {
                $p = Join-Path $FirmwareDir $n
                if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
            }
            $log3 = Invoke-Core -Arguments @('--cli', '--scan', "$ScanSeconds")
            Save-PhaseLog -Phase 3 -Text $log3
            $aliasFw = Test-Path -LiteralPath (Join-Path $FirmwareDir 'rtl8852bu_fw')
            $aliasCfg = Test-Path -LiteralPath (Join-Path $FirmwareDir 'rtl8852bu_config')
            $copiesAbsent = (-not $aliasFw) -and (-not $aliasCfg)
            $opened3 = $log3 -match 'USB: opened'
            $expectation = 'the .bin files are used directly, no extension-less copies exist, and the adapter opens'
            if ($copiesAbsent -and $opened3) {
                Add-Result -Phase 'phase 3' -Expectation $expectation -Status 'PASS' `
                    -Evidence "copies absent: $copiesAbsent (fw=$aliasFw, config=$aliasCfg); adapter opened: $opened3"
            }
            else {
                $why = if (-not $copiesAbsent) { 'the app created extension-less copies although 2.0.2+ must not (PR #97)' } else { 'the adapter did not open' }
                Add-Result -Phase 'phase 3' -Expectation $expectation -Status 'FAIL' `
                    -Evidence "$why. copies absent: $copiesAbsent (fw=$aliasFw, config=$aliasCfg); adapter opened: $opened3"
            }
        }
        else {
            $log3 = Invoke-Core -Arguments @('--cli', '--scan', "$ScanSeconds")
            Save-PhaseLog -Phase 3 -Text $log3
            $aliasFw = Test-Path -LiteralPath (Join-Path $ConfigDir 'rtl8852bu_fw')
            $aliasCfg = Test-Path -LiteralPath (Join-Path $ConfigDir 'rtl8852bu_config')
            $opened3 = $log3 -match 'USB: opened'
            $expectation = 'the legacy extension-less copies are present and the adapter opens (2.0.1)'
            if (-not ($aliasFw -and $aliasCfg)) {
                Add-Result -Phase 'phase 3' -Expectation $expectation -Status 'SKIP' `
                    -Evidence ("legacy copies are absent; supply them with fetch-realtek-fw.ps1 -LegacyAliases. fw=$aliasFw, config=$aliasCfg; adapter opened: $opened3")
            }
            else {
                Add-Result -Phase 'phase 3' -Expectation $expectation `
                    -Status $(if ($opened3) { 'PASS' } else { 'FAIL' }) `
                    -Evidence "legacy copies present: fw=$aliasFw, config=$aliasCfg; adapter opened: $opened3"
            }
        }

        Write-Section 'Phase 3b - stream'
        if (-not $Headset) {
            Add-Result -Phase 'phase 3b' -Expectation "the $Codec stream runs with 0 dropped packets" -Status 'SKIP' `
                -Evidence 'no headset address: the stream phase was skipped'
        }
        else {
            $log4 = Invoke-Core -Arguments @('--cli', '-d', $Headset, '-c', $Codec, '--duration', "$StreamSeconds")
            Save-PhaseLog -Phase 3 -Text "`r`n===== stream phase =====`r`n$log4" -Append
            $streaming = $log4 -match 'state Streaming: Connected'
            $sent = [regex]::Match($log4, 'Sent (\d+) media packets \((\d+) bytes\), (\d+) dropped')
            $errors = @(Get-DecisiveLines -Log $log4)
            $ok = $streaming -and $sent.Success -and ([int]$sent.Groups[3].Value -eq 0)
            $evidence = if ($sent.Success) {
                "packets=$($sent.Groups[1].Value) bytes=$($sent.Groups[2].Value) dropped=$($sent.Groups[3].Value); streaming=$streaming"
            }
            else {
                "no packet summary; streaming=$streaming"
            }
            if (-not $ok -and $errors.Count -gt 0) { $evidence += "; log: $($errors -join ' | ')" }
            Add-Result -Phase 'phase 3b' -Expectation "the $Codec stream runs with 0 dropped packets" `
                -Status $(if ($ok) { 'PASS' } else { 'FAIL' }) -Evidence $evidence
        }
    }
}
finally {
    $source = if ($effectiveMode -eq 'Missing') { $BackupDir } else { $script:ProbeDir }
    $restoreNames = if ($isBeta) { $script:BinaryNames } else { $script:FirmwareNames }
    if ($source -and (Test-Path -LiteralPath $source)) {
        $restored = Restore-FirmwareFiles -FromDir $source -Names $restoreNames
        Write-Section 'Restore (finally)'
        Write-Step ("restored from ${source}: " + $(if ($restored.Count -gt 0) { $restored -join ', ' } else { 'none' }))
        if ($isBeta) {
            Write-Step '2.0.2+: only the .bin files are restored; extension-less copies are obsolete and were not put back'
        }
        if ($effectiveMode -eq 'Present') {
            Remove-Item -LiteralPath $source -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- post-run verification -----------------------------------------------------
Write-Section 'Firmware restore check'
$final = @(Get-FirmwareFiles -Dir $FirmwareDir)
$requiredNames = if ($isBeta) { $script:BinaryNames } else { $script:FirmwareNames }
$missingFiles = @($requiredNames | Where-Object { -not (Test-Path -LiteralPath (Join-Path $FirmwareDir $_)) })
$restoreExpectation = if ($isBeta) {
    'both .bin firmware files exist in the firmware folder (2.0.2+; copies optional/obsolete)'
}
else {
    'all four legacy firmware files exist in the config folder (2.0.1)'
}
if ($missingFiles.Count -eq 0) {
    $evidence = (($final | ForEach-Object { Split-Path -Leaf $_ }) -join ', ')
    if ($isBeta) {
        $leftCopies = @($script:AliasNames | Where-Object { Test-Path -LiteralPath (Join-Path $FirmwareDir $_) })
        if ($leftCopies.Count -eq 0) { $evidence += '; no extension-less copies (expected)' }
        else { $evidence += "; obsolete copies remain: $($leftCopies -join ', ')" }
    }
    Add-Result -Phase 'restore' -Expectation $restoreExpectation -Status 'PASS' -Evidence $evidence
}
else {
    Add-Result -Phase 'restore' -Expectation $restoreExpectation -Status 'FAIL' `
        -Evidence ("missing: " + ($missingFiles -join ', '))
}

# --- summary -------------------------------------------------------------------
Write-Section 'Summary'
if ($script:PhaseLogs.Count -gt 0) {
    Write-Step ("raw per-phase app output: " + ($script:PhaseLogs -join ', '))
}
else {
    Write-Step "raw per-phase app output was not written (no core invocation reached a phase log; base: $OutputFile)"
}
$script:Results | Format-Table -AutoSize Phase, Status, Expectation | Out-String | Write-Host
$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
$skipped = @($script:Results | Where-Object { $_.Status -eq 'SKIP' })
$notes = @($script:Results | Where-Object { $_.Status -eq 'NOTE' })
$infos = @($script:Results | Where-Object { $_.Status -eq 'INFO' })
if ($failed.Count -gt 0) {
    Write-Host "RESULT: $($failed.Count) of $($script:Results.Count) checks failed." -ForegroundColor Red
    $exitCode = 1
}
else {
    $extra = @()
    if ($notes.Count -gt 0) { $extra += "$($notes.Count) pass-with-note" }
    if ($skipped.Count -gt 0) { $extra += "$($skipped.Count) skipped" }
    if ($infos.Count -gt 0) { $extra += "$($infos.Count) informational" }
    $suffix = if ($extra.Count -gt 0) { ' (' + ($extra -join ', ') + ')' } else { '' }
    Write-Host "RESULT: all $($script:Results.Count) checks behaved as expected$suffix." -ForegroundColor Green
    $exitCode = 0
}
exit $exitCode
