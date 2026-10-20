<#
.SYNOPSIS
    Read the A2DPWB "Copy Diagnostics" text without the GUI.

.DESCRIPTION
    The Diagnostics screen of the UI copies the text that the core builds for
    "Copy Diagnostics" (Diagnostics > Copy Diagnostics). That text is produced
    by the core itself, over its IPC pipe, so it can be read the same way from
    a script.

    The core answers on the user's named pipe
    \\.\pipe\a2dpwb-<user SID>. The exchange is the normal one: a hello frame,
    then the request, then the response - each frame a little-endian u32 length
    followed by UTF-8 JSON.

    If no core is running, one is started for the read and asked to quit
    again afterwards. A core that was already running is left alone.

.PARAMETER Masked
    Mask Bluetooth addresses in the text (the UI's default). Use -Full to get
    them unmasked.

.PARAMETER Output
    Write the text to this file instead of the console.

.PARAMETER Core
    The core executable. Defaults to the installed one.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\copy-diagnostics.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\copy-diagnostics.ps1 -Masked -Output "$env:TEMP\a2dpwb-diag.txt"
#>
[CmdletBinding()]
param(
    [switch]$Masked,
    [switch]$Full,
    [string]$Output,
    [string]$Core = "$env:LOCALAPPDATA\A2DP Windows Bridge\a2dpwb-core.exe"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Core)) {
    Write-Error "core not found: $Core"
}
if ($Masked -and $Full) {
    Write-Error "choose one of -Masked and -Full"
}

# The UI masks by default; -Full asks for the raw text.
$mask = -not $Full

$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$pipe = "a2dpwb-$sid"

function Write-Frame {
    param($Stream, [object]$Message)
    $json = [System.Text.Encoding]::UTF8.GetBytes(($Message | ConvertTo-Json -Compress -Depth 12))
    $len = [BitConverter]::GetBytes([int]$json.Length)   # u32 little-endian
    $Stream.Write($len, 0, 4)
    $Stream.Write($json, 0, $json.Length)
    $Stream.Flush()
}

function Read-Frame {
    param($Stream)
    $header = New-Object byte[] 4
    $read = 0
    while ($read -lt 4) {
        $n = $Stream.Read($header, $read, 4 - $read)
        if ($n -le 0) { return $null }
        $read += $n
    }
    $length = [BitConverter]::ToInt32($header, 0)
    if ($length -le 0 -or $length -gt 16777216) { return $null }
    $buffer = New-Object byte[] $length
    $read = 0
    while ($read -lt $length) {
        $n = $Stream.Read($buffer, $read, $length - $read)
        if ($n -le 0) { return $null }
        $read += $n
    }
    return [System.Text.Encoding]::UTF8.GetString($buffer)
}

function Get-DiagnosticsText {
    param([string]$PipeName, [bool]$Mask)

    $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
    try {
        $client.Connect(5000)
        Write-Frame $client @{ type = 'hello'; protocol = 1; client = 'a2dpwb-diagnostics/1.0' }
        # welcome, then the state snapshot the core sends right after it
        $null = Read-Frame $client
        $null = Read-Frame $client

        $request = @{ type = 'request'; id = 1; method = 'diag.info' }
        if ($null -ne $Mask) { $request['params'] = @{ mask = $Mask } }
        Write-Frame $client $request

        for ($i = 0; $i -lt 8; $i++) {
            $frame = Read-Frame $client
            if (-not $frame) { break }
            if ($frame -match '"type":"response"') {
                $obj = $frame | ConvertFrom-Json
                if ($obj.result.text) { return $obj.result.text }
            }
        }
        return $null
    } finally {
        $client.Dispose()
    }
}

# Start a core only if none is running; remember whether we own it.
$existing = Get-Process -Name 'a2dpwb-core' -ErrorAction SilentlyContinue
$started = $null
if (-not $existing) {
    $started = Start-Process -FilePath $Core -PassThru
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        if (-not (Get-Process -Id $started.Id -ErrorAction SilentlyContinue)) { break }
        if (Get-ChildItem '\\.\pipe\' -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $pipe }) { break }
    }
}

try {
    $text = Get-DiagnosticsText -PipeName $pipe -Mask $mask
    if (-not $text) { Write-Error "the core did not answer diag.info on \\.\pipe\$pipe" }
    if ($Output) {
        [System.IO.File]::WriteAllText($Output, $text, (New-Object System.Text.UTF8Encoding($false)))
        Write-Output "written: $Output"
    } else {
        Write-Output $text
    }
} finally {
    if ($started) {
        & $Core --quit 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        if (Get-Process -Id $started.Id -ErrorAction SilentlyContinue) {
            Stop-Process -Id $started.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
