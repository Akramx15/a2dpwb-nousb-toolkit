#Requires -Version 5.1
<#
.SYNOPSIS
Downloads and validates the Realtek RTL8852BU Bluetooth firmware for A2DPWB.

.DESCRIPTION
BTstack's Realtek loader (btstack_chipset_realtek.c) loads two files for the
internal Realtek RTL8852BU adapter (USB\VID_0BDA&PID_4853):

  rtl8852bu_fw.bin      firmware, must start with "Realtech" or "RTBTCore"
                        and end with the 51 04 FD 77 extension signature
  rtl8852bu_config.bin  config, empty or starting with 55 AB 23 87

A2DPWB additionally looks for the same files without the .bin extension
(rtl8852bu_fw / rtl8852bu_config), the names BTstack actually opens. This
script downloads the .bin files from linux-firmware, validates the magic the
project itself enforces, and creates the extension-less aliases (hardlink, or
a copy when hardlinks are unavailable).

The script is idempotent: valid files already in place are kept, invalid ones
are replaced. Every written file's SHA-256 is printed.

.PARAMETER ConfigDir
Destination folder. Default: $env:A2DPWB_CONFIG_DIR, else %APPDATA%\A2DPWB
(the folder A2DPWB reads).

.PARAMETER FilePrefix
File name stem, default rtl8852bu (do not change unless you use a custom
firmware stem in settings.json).

.PARAMETER BaseUrls
Download bases, tried in order. Each base gets "rtl_bt/<prefix>_fw.bin" and
"rtl_bt/<prefix>_config.bin" appended.

.PARAMETER TimeoutSec
Per-request timeout in seconds.

.PARAMETER Force
Re-download even when a valid file is already present.

.PARAMETER DryRun
Print what would be downloaded, validated and written; change nothing.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File scripts\fetch-realtek-fw.ps1 -DryRun
powershell -ExecutionPolicy Bypass -File scripts\fetch-realtek-fw.ps1

.NOTES
Exit codes: 0 success, 1 failure, 2 bad arguments.
#>
[CmdletBinding()]
param(
    [string]$ConfigDir,
    [string]$FilePrefix = 'rtl8852bu',
    [string[]]$BaseUrls = @(
        'https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/',
        'https://raw.githubusercontent.com/torvalds/linux-firmware/master/',
        'https://raw.githubusercontent.com/coolpi-george/linux-firmware/master/',
        'https://raw.githubusercontent.com/armbian/firmware/master/'
    ),
    [int]$TimeoutSec = 60,
    [switch]$Force,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$LASTEXITCODE = 0

function Resolve-ConfigDir {
    if ($ConfigDir) { return $ConfigDir }
    if ($env:A2DPWB_CONFIG_DIR) { return $env:A2DPWB_CONFIG_DIR }
    if ($env:APPDATA) { return (Join-Path $env:APPDATA 'A2DPWB') }
    throw 'No config folder: pass -ConfigDir or set A2DPWB_CONFIG_DIR / APPDATA.'
}

function Get-FirmwareState {
    param([string]$Path, [ValidateSet('fw', 'cfg')][string]$Kind)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Path = $Path; Exists = $false; Valid = $false; Reason = 'missing'; Length = 0; Sha256 = '' }
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $valid = $false
    $reason = ''
    if ($Kind -eq 'fw') {
        if ($bytes.Length -lt 16) {
            $reason = "too short ($($bytes.Length) bytes, need >= 16)"
        }
        else {
            $head = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 8)
            $tail = $bytes[($bytes.Length - 4)..($bytes.Length - 1)]
            $tailOk = ($tail[0] -eq 0x51 -and $tail[1] -eq 0x04 -and $tail[2] -eq 0xFD -and $tail[3] -eq 0x77)
            if ($head -ne 'Realtech' -and $head -ne 'RTBTCore') {
                $reason = "bad signature '$head' (expected Realtech or RTBTCore); an HTML error page?"
            }
            elseif (-not $tailOk) {
                $reason = 'missing the 51 04 FD 77 extension signature at the end'
            }
            else { $valid = $true }
        }
    }
    else {
        if ($bytes.Length -eq 0) { $valid = $true }
        elseif ($bytes.Length -ge 6 -and $bytes[0] -eq 0x55 -and $bytes[1] -eq 0xAB -and $bytes[2] -eq 0x23 -and $bytes[3] -eq 0x87) {
            $valid = $true
        }
        else {
            $reason = 'does not start with 55 AB 23 87 (and is not empty)'
        }
    }
    $sha = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return [pscustomobject]@{ Path = $Path; Exists = $true; Valid = $valid; Reason = $reason; Length = $bytes.Length; Sha256 = $sha }
}

function Get-RemoteFile {
    param([string]$Name, [ValidateSet('fw', 'cfg')][string]$Kind, [string]$ServerPath)
    $lastError = ''
    foreach ($base in $BaseUrls) {
        $url = "$base$ServerPath"
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("a2dpwb-fw-" + [System.IO.Path]::GetRandomFileName())
        if ($DryRun) {
            Write-Host "  would download $url"
            return [pscustomobject]@{ Url = $url; TempPath = $null }
        }
        try {
            Write-Host "  downloading $url"
            Invoke-WebRequest -Uri $url -OutFile $temp -UseBasicParsing -TimeoutSec $TimeoutSec
        }
        catch {
            $lastError = "$url -> $($_.Exception.Message)"
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
            continue
        }
        $state = Get-FirmwareState -Path $temp -Kind $Kind
        if ($state.Valid) {
            return [pscustomobject]@{ Url = $url; TempPath = $temp }
        }
        $lastError = "$url -> content rejected: $($state.Reason)"
        Remove-Item -LiteralPath $temp -Force
    }
    throw "could not download a valid ${Name} from any source. Last problem: $lastError"
}

function Install-File {
    param([string]$Source, [string]$Destination, [string]$Label)
    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
    Move-Item -LiteralPath $Source -Destination $Destination -Force
    $sha = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    Write-Host ("  {0}: {1} ({2} bytes) SHA-256 {3}" -f $Label, $Destination, (Get-Item -LiteralPath $Destination).Length, $sha)
    return $sha
}

function Install-Alias {
    param([string]$Target, [string]$Alias, [string]$Label)
    if (Test-Path -LiteralPath $Alias -PathType Leaf) {
        $a = (Get-FileHash -LiteralPath $Alias -Algorithm SHA256).Hash
        $t = (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash
        if ($a -eq $t) {
            Write-Host ("  {0}: {1} already up to date (SHA-256 {2})" -f $Label, $Alias, $a)
            return
        }
        if ($DryRun) {
            Write-Host ("  would replace {0} (SHA-256 {1} != {2})" -f $Alias, $a, $t)
            return
        }
        Remove-Item -LiteralPath $Alias -Force
    }
    if ($DryRun) {
        Write-Host ("  would create {0} -> {1}" -f $Alias, $Target)
        return
    }
    try {
        New-Item -ItemType HardLink -Path $Alias -Value $Target -Force | Out-Null
    }
    catch {
        Copy-Item -LiteralPath $Target -Destination $Alias -Force
    }
    $sha = (Get-FileHash -LiteralPath $Alias -Algorithm SHA256).Hash
    Write-Host ("  {0}: {1} -> {2} SHA-256 {3}" -f $Label, $Alias, $Target, $sha)
}

try {
    $dir = Resolve-ConfigDir
    Write-Host "A2DPWB config folder: $dir"
    if ($DryRun) { Write-Host 'Dry run: nothing will be downloaded or written.' }

    $fwBin = Join-Path $dir ("{0}_fw.bin" -f $FilePrefix)
    $cfgBin = Join-Path $dir ("{0}_config.bin" -f $FilePrefix)
    $fwAlias = Join-Path $dir ("{0}_fw" -f $FilePrefix)
    $cfgAlias = Join-Path $dir ("{0}_config" -f $FilePrefix)

    Write-Host 'Firmware:'
    $fwState = Get-FirmwareState -Path $fwBin -Kind fw
    if ($fwState.Exists -and $fwState.Valid -and -not $Force) {
        Write-Host ("  {0} already valid ({1} bytes) SHA-256 {2}" -f $fwBin, $fwState.Length, $fwState.Sha256)
    }
    else {
        if ($fwState.Exists) { Write-Host ("  {0} is not usable: {1}" -f $fwBin, $fwState.Reason) }
        if ($DryRun) {
            $null = Get-RemoteFile -Name $fwBin -Kind fw -ServerPath ("rtl_bt/{0}_fw.bin" -f $FilePrefix)
            Write-Host ("  would write {0}" -f $fwBin)
        }
        else {
            $remote = Get-RemoteFile -Name $fwBin -Kind fw -ServerPath ("rtl_bt/{0}_fw.bin" -f $FilePrefix)
            Install-File -Source $remote.TempPath -Destination $fwBin -Label 'firmware' | Out-Null
        }
    }

    Write-Host 'Config:'
    $cfgState = Get-FirmwareState -Path $cfgBin -Kind cfg
    if ($cfgState.Exists -and $cfgState.Valid -and -not $Force) {
        Write-Host ("  {0} already valid ({1} bytes) SHA-256 {2}" -f $cfgBin, $cfgState.Length, $cfgState.Sha256)
    }
    else {
        if ($cfgState.Exists) { Write-Host ("  {0} is not usable: {1}" -f $cfgBin, $cfgState.Reason) }
        if ($DryRun) {
            $null = Get-RemoteFile -Name $cfgBin -Kind cfg -ServerPath ("rtl_bt/{0}_config.bin" -f $FilePrefix)
            Write-Host ("  would write {0}" -f $cfgBin)
        }
        else {
            $remote = Get-RemoteFile -Name $cfgBin -Kind cfg -ServerPath ("rtl_bt/{0}_config.bin" -f $FilePrefix)
            Install-File -Source $remote.TempPath -Destination $cfgBin -Label 'config' | Out-Null
        }
    }

    Write-Host 'Extension-less aliases BTstack opens:'
    Install-Alias -Target $fwBin -Alias $fwAlias -Label 'firmware alias'
    Install-Alias -Target $cfgBin -Alias $cfgAlias -Label 'config alias'

    if (-not $DryRun) {
        Write-Host 'Result:'
        foreach ($p in @($fwBin, $cfgBin, $fwAlias, $cfgAlias)) {
            $state = Get-FirmwareState -Path $p -Kind $(if ($p -like '*_fw*') { 'fw' } else { 'cfg' })
            $verdict = if ($state.Valid) { 'OK' } else { "INVALID ($($state.Reason))" }
            Write-Host ("  {0}  {1}  {2} bytes  SHA-256 {3}" -f $verdict, $p, $state.Length, $state.Sha256)
        }
        Write-Host 'Done. Restart the adapter (scripts\usb-driver.ps1 restart) and retry A2DPWB.'
    }
    else {
        Write-Host 'Dry run complete: no changes made.'
    }
    exit 0
}
catch {
    Write-Error "fetch-realtek-fw failed: $($_.Exception.Message)"
    exit 1
}
