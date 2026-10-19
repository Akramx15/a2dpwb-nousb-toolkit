#Requires -Version 5.1
<#
.SYNOPSIS
Controls the WinUSB driver of a Bluetooth adapter through the installed
A2DPWB driver helper (a2dpwb-driver.exe).

.DESCRIPTION
A2DPWB takes a USB Bluetooth adapter away from Windows by binding WinUSB to
it. This script wraps the project's own elevated helper instead of
re-implementing the driver switch:

  list     the adapters the helper sees (no elevation)
  state    the current driver of one adapter (no elevation)
  assign   bind WinUSB to one adapter (UAC via the helper, elevated)
  restore  give one adapter (or every recorded one) back to Windows
  restart  pnputil /restart-device on one adapter (needs elevation)

`assign` and `restore` are run elevated with Start-Process -Verb RunAs; the
helper accepts --out <file> so the JSON result survives the UAC boundary.
`list`, `state` and `restart` never change the driver records.

.PARAMETER Mode
list, state, assign, restore or restart.

.PARAMETER InstanceId
Device instance ID, e.g. USB\VID_0BDA&PID_4853\00E04C0000XX. Required for
state, restart, and for assign/restore unless -Auto or -UseRecords is given.

.PARAMETER Auto
Pick the first adapter that looks like the internal Realtek RTL8852BU
(a display name containing RTL8852BU, or a VID_0BDA&PID_4853 instance ID).

.PARAMETER PreviousFile
For restore: a JSON file holding the driver record (the "previous" object
from an assign result, or a whole assign result). Default: the record under
the config folder's driver\ directory, matched by instance ID.

.PARAMETER UseRecords
For restore: ask the helper to restore every recorded adapter
(a2dpwb-driver restore --records <dir>): one UAC prompt for all.

.PARAMETER RecordsDir
Folder the helper keeps assignment records in. Default:
%APPDATA%\A2DPWB\driver (or A2DPWB_CONFIG_DIR\driver).

.PARAMETER All
For list: include USB devices that do not look like Bluetooth adapters.

.PARAMETER DriverExe
Path to a2dpwb-driver.exe. Default: the installed app folder.

.PARAMETER DryRun
Print the helper command line without running it (no UAC, no changes).

.EXAMPLE
powershell -ExecutionPolicy Bypass -File scripts\usb-driver.ps1 -Mode state -InstanceId 'USB\VID_0BDA&PID_4853\00E04C0000XX'
powershell -ExecutionPolicy Bypass -File scripts\usb-driver.ps1 -Mode assign -Auto
powershell -ExecutionPolicy Bypass -File scripts\usb-driver.ps1 -Mode restore -Auto
powershell -ExecutionPolicy Bypass -File scripts\usb-driver.ps1 -Mode restart -Auto

.NOTES
Exit codes: 0 success, 1 failure, 2 bad arguments, 3 elevation required or
denied, 4 helper or record not found.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('list', 'state', 'assign', 'restore', 'restart')]
    [string]$Mode,
    [string]$InstanceId,
    [switch]$Auto,
    [string]$PreviousFile,
    [switch]$UseRecords,
    [string]$RecordsDir,
    [switch]$All,
    [string]$DriverExe,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$LASTEXITCODE = 0

function Get-ConfigDir {
    if ($env:A2DPWB_CONFIG_DIR) { return $env:A2DPWB_CONFIG_DIR }
    if ($env:APPDATA) { return (Join-Path $env:APPDATA 'A2DPWB') }
    throw 'No config folder: set A2DPWB_CONFIG_DIR or APPDATA.'
}

function Get-DriverExe {
    if ($DriverExe) { return $DriverExe }
    if ($env:LOCALAPPDATA) {
        $candidate = Join-Path $env:LOCALAPPDATA 'A2DP Windows Bridge\a2dpwb-driver.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw "a2dpwb-driver.exe not found: pass -DriverExe or install A2DPWB (default folder: %LOCALAPPDATA%\A2DP Windows Bridge)."
}

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-Argument {
    param([string]$Value)
    if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
    return $Value
}

function Invoke-DriverHelper {
    param([string[]]$Arguments, [switch]$NoElevateRequired)
    $exe = Get-DriverExe
    $outFile = Join-Path ([System.IO.Path]::GetTempPath()) ("a2dpwb-driver-" + [System.IO.Path]::GetRandomFileName())
    $full = @($Arguments) + @('--out', $outFile)
    $display = ($full | ForEach-Object { Quote-Argument $_ }) -join ' '
    if ($DryRun) {
        $prefix = if ($NoElevateRequired -or (Test-Elevated)) { '' } else { 'runas ' }
        Write-Host "DRY RUN: $prefix`"$exe`" $display"
        return 0
    }
    $elevated = Test-Elevated
    if ($elevated -or $NoElevateRequired) {
        & $exe @full
        $code = $LASTEXITCODE
    }
    else {
        Write-Host "Requesting administrator rights ($Mode)..."
        try {
            $quoted = ($full | ForEach-Object { Quote-Argument $_ }) -join ' '
            $proc = Start-Process -FilePath $exe -ArgumentList $quoted -Verb RunAs -Wait -PassThru
            $code = $proc.ExitCode
        }
        catch {
            Write-Error "elevation was denied or failed: $($_.Exception.Message)"
            exit 3
        }
    }
    if (Test-Path -LiteralPath $outFile -PathType Leaf) {
        Write-Host (Get-Content -LiteralPath $outFile -Raw)
        Remove-Item -LiteralPath $outFile -Force
    }
    else {
        Write-Warning "the helper wrote no result file; its JSON went to stdout/stderr above"
    }
    return $code
}

function Resolve-InstanceId {
    if ($InstanceId) { return $InstanceId }
    if (-not $Auto) {
        throw "pass -InstanceId or -Auto (mode $Mode needs a device)."
    }
    $exe = Get-DriverExe
    $json = & $exe list | Out-String
    if ($LASTEXITCODE -ne 0) { throw "a2dpwb-driver list failed (exit $LASTEXITCODE)." }
    $parsed = $json | ConvertFrom-Json
    $adapter = $parsed.adapters |
        Where-Object { $_.instance_id -match 'VID_0BDA&PID_4853' -or $_.id -match '0BDA:4853' -or $_.name -match 'RTL8852BU' } |
        Select-Object -First 1
    if (-not $adapter) { throw 'no RTL8852BU adapter found by -Auto; run -Mode list to see what the helper sees.' }
    Write-Host "Selected adapter: $($adapter.name) ($($adapter.instance_id))"
    return $adapter.instance_id
}

function Find-RecordFile {
    param([string]$Id)
    $dir = if ($RecordsDir) { $RecordsDir } else { Join-Path (Get-ConfigDir) 'driver' }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $null }
    foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File) {
        try {
            $record = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        }
        catch { continue }
        if ($record.instance_id -and ($record.instance_id -ieq $Id)) { return $file.FullName }
    }
    return $null
}

try {
    switch ($Mode) {
        'list' {
            $helperArgs = @('list')
            if ($All) { $helperArgs += '--all' }
            $code = Invoke-DriverHelper -Arguments $helperArgs -NoElevateRequired
            exit $code
        }
        'state' {
            if (-not $InstanceId) { throw 'state needs -InstanceId.' }
            $code = Invoke-DriverHelper -Arguments @('state', $InstanceId) -NoElevateRequired
            exit $code
        }
        'assign' {
            $id = Resolve-InstanceId
            if ($DryRun) {
                $null = Invoke-DriverHelper -Arguments @('assign', $id)
                exit 0
            }
            $code = Invoke-DriverHelper -Arguments @('assign', $id)
            if ($code -eq 0) {
                Write-Host 'Adapter is on WinUSB. If the helper reported "reboot_required": true, reboot before streaming (WinUSB error 50 until then).'
            }
            exit $code
        }
        'restore' {
            if ($UseRecords) {
                $dir = if ($RecordsDir) { $RecordsDir } else { Join-Path (Get-ConfigDir) 'driver' }
                if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                    throw "no driver records in ${dir}: nothing to restore."
                }
                if ($DryRun) {
                    $null = Invoke-DriverHelper -Arguments @('restore', '--records', $dir)
                    exit 0
                }
                exit (Invoke-DriverHelper -Arguments @('restore', '--records', $dir))
            }
            $id = Resolve-InstanceId
            $previous = $PreviousFile
            if (-not $previous) {
                $previous = Find-RecordFile -Id $id
                if (-not $previous) {
                    Write-Error "no driver record for $id; pass -PreviousFile (the 'previous' object saved from assign) or -UseRecords."
                    exit 4
                }
                Write-Host "Using driver record: $previous"
            }
            if ($DryRun) {
                $null = Invoke-DriverHelper -Arguments @('restore', $id, '--previous', "@$previous")
                exit 0
            }
            $code = Invoke-DriverHelper -Arguments @('restore', $id, '--previous', "@$previous")
            if ($code -eq 0) { Write-Host 'Adapter restored to its Windows driver. If Windows still hides Bluetooth, reboot.' }
            exit $code
        }
        'restart' {
            $id = Resolve-InstanceId
            if ($DryRun) {
                Write-Host "DRY RUN: pnputil /restart-device `"$id`" (must run elevated)"
                exit 0
            }
            if (-not (Test-Elevated)) {
                Write-Error "restart needs an elevated PowerShell: right-click PowerShell, 'Run as administrator', then rerun: pnputil /restart-device `"$id`""
                exit 3
            }
            Write-Host "Restarting device $id ..."
            & pnputil /restart-device "$id"
            $code = $LASTEXITCODE
            if ($code -ne 0) { Write-Error "pnputil /restart-device failed (exit $code)." }
            exit $code
        }
    }
}
catch {
    Write-Error "usb-driver failed: $($_.Exception.Message)"
    exit 1
}
