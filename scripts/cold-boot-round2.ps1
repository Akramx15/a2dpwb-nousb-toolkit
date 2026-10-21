<#
.SYNOPSIS
    One-command driver for the second cold-boot round (A2DP-Windows-Bridge).

.DESCRIPTION
    This round prepares the missing-firmware case (a separate case from the
    WinUSB binding, which now re-enumerates itself in 2.0.2+). With the .bin
    firmware files absent, 2.0.2+ names them ("firmware file missing"
    warnings). A ROM-mode module still serves HCI, so the adapter may open
    anyway; the open failure is not the expectation here. The script prepares
    the next reboot:

      1. copies the firmware files that are present to a safe backup folder
         (the two .bin files are required; obsolete extension-less copies are
         backed up too when they exist);
      2. installs a self-deleting entry in the user's Startup folder;
      3. removes exactly the files it backed up from %APPDATA%\A2DPWB;
      4. schedules a reboot (shutdown /r /t 30).

    After the reboot and sign-in, the Startup entry runs:

        cold-boot-test.ps1 -Mode Missing -Core <the beta> -Headset <devices.txt> -OutputFile <output>

    and writes the output to
    %USERPROFILE%\Documents\opencode\a2db\work\cold-boot-round2.txt. The raw
    app output of each phase is written next to it as
    cold-boot-round2.txt.phase1.log, .phase2.log and .phase3.log. The test
    names the missing files, restores the .bin files, checks that 2.0.2+ uses
    the .bin files directly (no extension-less copies) and downloads the
    firmware, streams, then restores the .bin files. The Startup entry deletes
    itself after the run.

    Nothing is changed unless -Execute is given. -WhatIf (the default) only
    prints this plan. -Abort cancels a pending reboot and restores the files
    from the backup.

.PARAMETER Core
    Path to the 2.0.2+ beta a2dpwb-core.exe. Default: the portable beta next
    to this repository, when present.

.PARAMETER ConfigDir
    Firmware/config folder. Default: %APPDATA%\A2DPWB.

.PARAMETER BackupDir
    Safe copy of the firmware files. Default:
    %APPDATA%\A2DPWB-coldboot-backup. The same folder is the restore source
    for cold-boot-test.ps1 -Mode Missing.

.PARAMETER Headset
    Bluetooth address for the stream phase. Default: the first address in
    %APPDATA%\A2DPWB\devices.txt.

.PARAMETER RebootDelaySeconds
    Delay passed to shutdown /r /t. Default: 30.

.PARAMETER OutputFile
    Base path used by the Startup entry for the post-reboot test summary. The
    raw per-phase logs are written next to it as <output>.phase1.log,
    <output>.phase2.log and <output>.phase3.log. Default:
    %USERPROFILE%\Documents\opencode\a2db\work\cold-boot-round2.txt.

.PARAMETER Abort
    Cancel a pending reboot, remove the Startup entry and restore the firmware
    files present in the backup.

.PARAMETER WhatIf
    Report the plan and change nothing (this is also the default).

.PARAMETER Execute
    Actually back up, install the Startup entry, remove the files and schedule
    the reboot.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\cold-boot-round2.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\cold-boot-round2.ps1 -Execute

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\cold-boot-round2.ps1 -Abort

.NOTES
    Targets A2DP-Windows-Bridge 2.0.2-beta.4 and newer.
    Exit codes: 0 success (or plan printed), 1 a step failed, 2 precondition.
#>
[CmdletBinding()]
param(
    [string]$Core = '',
    [string]$ConfigDir = (Join-Path $env:APPDATA 'A2DPWB'),
    [string]$FirmwareDir = '',
    [string]$BackupDir = (Join-Path $env:APPDATA 'A2DPWB-coldboot-backup'),
    [string]$Headset = '',
    [int]$RebootDelaySeconds = 30,
    [string]$OutputFile = (Join-Path $env:USERPROFILE 'Documents\opencode\a2db\work\cold-boot-round2.txt'),
    [switch]$Abort,
    [switch]$WhatIf,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:FirmwareNames = @('rtl8852bu_fw', 'rtl8852bu_config', 'rtl8852bu_fw.bin', 'rtl8852bu_config.bin')
$script:BinaryNames = @('rtl8852bu_fw.bin', 'rtl8852bu_config.bin')
$script:StartupDir = [Environment]::GetFolderPath('Startup')
$script:StartupEntry = Join-Path $script:StartupDir 'a2dpwb-cold-boot-round2.cmd'
$script:TestScript = Join-Path $PSScriptRoot 'cold-boot-test.ps1'
$script:RemovedManifest = Join-Path $BackupDir 'removed-names.txt'

# 2.0.2-beta.5 moved the firmware files into the "firmware" subfolder of the
# config folder; 2.0.2-beta.4 and older kept them in the config folder itself.
if (-not $FirmwareDir) {
    $modernFwDir = Join-Path $ConfigDir 'firmware'
    if (Test-Path -LiteralPath $modernFwDir -PathType Container) { $FirmwareDir = $modernFwDir }
    else { $FirmwareDir = $ConfigDir }
}

function Write-Section { param([string]$Text) Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Step { param([string]$Text) Write-Host "   $Text" }
function Fail-Precondition { param([string]$Text) Write-Host "ERROR: $Text" -ForegroundColor Red; exit 2 }

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

function Get-PresentBins {
    param([string]$Dir)
    return @(Get-FirmwareFiles -Dir $Dir | Where-Object { $script:BinaryNames -contains (Split-Path -Leaf $_) })
}

function Copy-FirmwareToBackup {
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $copied = @()
    foreach ($n in $script:FirmwareNames) {
        $src = Join-Path $FirmwareDir $n
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $BackupDir $n) -Force
            $copied += $n
        }
    }
    return $copied
}

function Restore-FirmwareFromBackup {
    param([string[]]$Names = $script:FirmwareNames)
    $restored = @()
    foreach ($n in $Names) {
        $src = Join-Path $BackupDir $n
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

function Remove-StartupEntry {
    if (Test-Path -LiteralPath $script:StartupEntry) {
        Remove-Item -LiteralPath $script:StartupEntry -Force
        return $true
    }
    return $false
}

if ($Abort -and $Execute) { Fail-Precondition '-Abort and -Execute cannot be combined.' }
if ($WhatIf -and $Execute) { Fail-Precondition '-WhatIf and -Execute cannot be combined.' }
if ($WhatIf -and $Abort) { Fail-Precondition '-WhatIf and -Abort cannot be combined (drop -WhatIf to abort).' }

# --- abort ---------------------------------------------------------------------
if ($Abort) {
    Write-Section 'Abort - cancel the reboot and restore the firmware'
    $pendingOutput = ''
    $pendingCode = 0
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $pendingOutput = (& shutdown.exe /a 2>&1 | Out-String).Trim()
        $pendingCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($pendingCode -eq 0) {
        Write-Step 'pending reboot: cancelled'
    }
    else {
        Write-Step "pending reboot: none to cancel (shutdown /a exit $pendingCode)"
        if ($pendingOutput) { Write-Step "shutdown said: $pendingOutput" }
    }

    if (Remove-StartupEntry) { Write-Step "startup entry removed: $script:StartupEntry" }
    else { Write-Step 'startup entry: none present' }

    $restoreNames = $script:FirmwareNames
    if (Test-Path -LiteralPath $script:RemovedManifest -PathType Leaf) {
        $restoreNames = @(Get-Content -LiteralPath $script:RemovedManifest |
            Where-Object { $script:FirmwareNames -contains $_ })
    }
    $restored = Restore-FirmwareFromBackup -Names $restoreNames
    Write-Step ("firmware restored from ${BackupDir}: " + $(if ($restored.Count -gt 0) { $restored -join ', ' } else { 'nothing (backup missing or empty)' }))
    $missing = @($script:BinaryNames | Where-Object { -not (Test-Path -LiteralPath (Join-Path $FirmwareDir $_)) })
    if ($missing.Count -eq 0) {
        if (Test-Path -LiteralPath $script:RemovedManifest) { Remove-Item -LiteralPath $script:RemovedManifest -Force }
        Write-Host 'RESULT: reboot cancelled and both .bin firmware files are present (2.0.2+).' -ForegroundColor Green
        exit 0
    }
    Write-Host ("RESULT: .bin files still missing after the restore: " + ($missing -join ', ')) -ForegroundColor Red
    Write-Host "Check $BackupDir; the backup may be incomplete."
    exit 1
}

# --- preconditions -------------------------------------------------------------
Write-Section 'Preconditions'

if (-not (Test-Path -LiteralPath $script:TestScript)) {
    Fail-Precondition "cold-boot-test.ps1 not found at '$script:TestScript'."
}

if (-not $Core) {
    $betaCandidate = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\beta-2.0.2-beta.1\A2DPWB-2.0.2-beta.1\a2dpwb-core.exe'))
    $installed = Join-Path $env:LOCALAPPDATA 'A2DP Windows Bridge\a2dpwb-core.exe'
    if (Test-Path -LiteralPath $betaCandidate) { $Core = $betaCandidate; $coreSource = 'default: portable beta' }
    elseif (Test-Path -LiteralPath $installed) { $Core = $installed; $coreSource = 'default: installed release' }
    else { Fail-Precondition "no a2dpwb-core.exe found at '$betaCandidate' or '$installed'; pass -Core with the 2.0.2+ binary." }
}
else {
    $coreSource = '-Core parameter'
}
if (-not (Test-Path -LiteralPath $Core)) { Fail-Precondition "a2dpwb-core.exe not found at '$Core'." }
$Core = (Resolve-Path -LiteralPath $Core).Path
$version = Get-CoreVersion -Path $Core
if (-not (Test-BetaVersion -Version $version)) {
    Fail-Precondition "'$Core' reports version '$version'; round 2 needs the 2.0.2+ beta."
}
Write-Step "core     : $Core"
Write-Step "source   : $coreSource"
Write-Step "version  : $(if ($version) { $version } else { 'unknown' }) [beta]"

if (-not $Headset) {
    $devicesFile = Join-Path $ConfigDir 'devices.txt'
    if (Test-Path -LiteralPath $devicesFile) {
        $Headset = Get-Content -LiteralPath $devicesFile |
            ForEach-Object { ($_ -split '\|')[0].Trim() } |
            Where-Object { $_ -match '^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$' } |
            Select-Object -First 1
    }
}
if (-not $Headset) { Fail-Precondition "no headset address found; pass -Headset or add one to $(Join-Path $ConfigDir 'devices.txt')." }
if ($Headset -notmatch '^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$') { Fail-Precondition "'$Headset' is not a Bluetooth address." }
Write-Step "headset  : $Headset"

$present = @(Get-FirmwareFiles -Dir $FirmwareDir)
$presentBins = @(Get-PresentBins -Dir $FirmwareDir)
if ($presentBins.Count -ne 2) {
    Fail-Precondition ("round 2 needs both .bin firmware files, found {0}. Run -Abort first to restore them." -f $presentBins.Count)
}
$presentCopies = @($present | Where-Object { $script:BinaryNames -notcontains (Split-Path -Leaf $_) })
Write-Step 'firmware : 2 of 2 .bin files present'
if ($presentCopies.Count -gt 0) {
    Write-Step ("copies   : {0} obsolete extension-less copy/copies present; they will be backed up and removed too" -f $presentCopies.Count)
}
else {
    Write-Step 'copies   : none (2.0.2+ uses the .bin files; no copies are needed)'
}

$outputDir = Split-Path -Parent $OutputFile
if (-not $outputDir) { Fail-Precondition "OutputFile '$OutputFile' has no parent folder." }
Write-Step "output   : $OutputFile"
Write-Step "raw logs : $OutputFile.phase1.log, $OutputFile.phase2.log, $OutputFile.phase3.log"
Write-Step "backup   : $BackupDir"
Write-Step "startup  : $script:StartupEntry"

$startupContent = @(
    '@echo off',
    'rem Self-deleting A2DP-Windows-Bridge cold-boot round-2 probe.',
    ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode Missing -Core "{1}" -Headset "{2}" -FirmwareDir "{3}" -OutputFile "{4}" > "{4}" 2>&1' -f $script:TestScript, $Core, $Headset, $FirmwareDir, $OutputFile),
    'del /f /q "%~f0"'
) -join "`r`n"

if (-not $Execute) {
    Write-Section 'Plan only - nothing was changed'
    Write-Step 'The script would:'
    Write-Step "  1. copy the firmware files present (the two .bin at minimum) to $BackupDir"
    Write-Step "  2. write the self-deleting Startup entry $script:StartupEntry"
    Write-Step "  3. remove exactly the files it backed up from the firmware folder ($FirmwareDir)"
    Write-Step "  4. run: shutdown.exe /r /t $RebootDelaySeconds /c `"A2DP Windows Bridge cold-boot round 2`""
    Write-Host ''
    Write-Step 'Startup entry content:'
    foreach ($line in ($startupContent -split "`r?`n")) { Write-Step "  | $line" }
    Write-Host ''
    Write-Step 'After the reboot and sign-in the test will:'
    Write-Step '  - expect the app to name the missing .bin files; on a ROM-mode module the adapter may still open'
    Write-Step '  - restore the .bin files and expect 2.0.2+ to use them directly (no extension-less copies), download the firmware and open the adapter'
    Write-Step "  - stream for 20 s to $Headset and expect 0 dropped packets"
    Write-Step "  - restore the .bin files and write the output file; raw per-phase logs go next to it as $OutputFile.phase1.log, .phase2.log and .phase3.log"
    Write-Host ''
    Write-Step "To apply: run this script again with -Execute (the reboot is in $RebootDelaySeconds s; cancel with -Abort)."
    Write-Step 'To cancel a run that already started: -Abort (cancels the reboot and restores the files).'
    exit 0
}

# --- execute -------------------------------------------------------------------
Write-Section 'Execute - preparing the second cold-boot round'

$copied = Copy-FirmwareToBackup
Write-Step ("backup copied: " + ($copied -join ', '))
$backupBins = @(Get-PresentBins -Dir $BackupDir)
if ($backupBins.Count -ne 2) {
    Fail-Precondition ("the backup at {0} has {1} of 2 .bin files; nothing was removed." -f $BackupDir, $backupBins.Count)
}

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
[System.IO.File]::WriteAllText($script:StartupEntry, $startupContent, [System.Text.Encoding]::Default)
Write-Step "startup entry written: $script:StartupEntry"

# Verify the entry is syntactically what we expect before touching the files.
$installed = Get-Content -LiteralPath $script:StartupEntry -Raw
if ($installed -notmatch [regex]::Escape('-Mode Missing')) {
    Remove-StartupEntry | Out-Null
    Fail-Precondition 'the Startup entry did not contain the expected command; it was removed.'
}

$removed = @()
foreach ($n in $copied) {
    $p = Join-Path $FirmwareDir $n
    if (Test-Path -LiteralPath $p) {
        Remove-Item -LiteralPath $p -Force
        $removed += $n
    }
}
Write-Step ("removed from the firmware folder: " + ($removed -join ', '))
if (@(Get-FirmwareFiles -Dir $FirmwareDir).Count -ne 0) {
    Restore-FirmwareFromBackup -Names $removed | Out-Null
    Remove-StartupEntry | Out-Null
    Write-Host 'ERROR: not all firmware files could be removed; the files were restored and the Startup entry removed.' -ForegroundColor Red
    exit 1
}
[System.IO.File]::WriteAllLines($script:RemovedManifest, [string[]]$removed, [System.Text.Encoding]::UTF8)
Write-Step "removed-name manifest: $script:RemovedManifest"

$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $shutdownOutput = (& shutdown.exe /r /t "$RebootDelaySeconds" /c 'A2DP Windows Bridge cold-boot round 2' 2>&1 | Out-String).Trim()
    $shutdownCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previous
}
if ($shutdownCode -ne 0) {
    Write-Host "ERROR: shutdown /r failed (exit $shutdownCode): $shutdownOutput" -ForegroundColor Red
    $restored = Restore-FirmwareFromBackup -Names $removed
    Remove-StartupEntry | Out-Null
    Write-Host ("Rolled back: firmware restored ({0}); Startup entry removed." -f ($restored -join ', ')) -ForegroundColor Yellow
    exit 1
}

Write-Step "reboot scheduled in $RebootDelaySeconds s"
Write-Host ''
Write-Host 'WHAT TO EXPECT' -ForegroundColor Cyan
Write-Step "The PC reboots in $RebootDelaySeconds seconds. Save your work now."
Write-Step 'After you sign in, Windows runs the Startup entry automatically; it removes itself when done.'
Write-Step "The test output appears in: $OutputFile"
Write-Step "Raw per-phase app output: $OutputFile.phase1.log, .phase2.log, .phase3.log"
Write-Step 'The app should name the missing rtl8852bu_fw.bin / rtl8852bu_config.bin; on a ROM-mode module the adapter may still open.'
Write-Step 'Then it restores the .bin files, expects 2.0.2+ to use them directly (no extension-less copies) + firmware download, streams, and restores the .bin files.'
Write-Host ''
Write-Host 'TO CANCEL BEFORE THE REBOOT' -ForegroundColor Cyan
Write-Step 'Run: powershell -ExecutionPolicy Bypass -File scripts\cold-boot-round2.ps1 -Abort'
Write-Step '(or shut down the reboot with: shutdown /a). -Abort also restores the firmware files.'
Write-Host ''
Write-Host 'Round 2 is armed.' -ForegroundColor Green
exit 0
