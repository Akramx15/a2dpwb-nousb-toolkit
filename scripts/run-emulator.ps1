#Requires -Version 5.1
<#
.SYNOPSIS
Runs the A2DPWB emulator end-to-end: a Bumble virtual Bluetooth sink in
tools/emu, then a2dpwb-core.exe --cli over H4/TCP (no Bluetooth hardware).

.DESCRIPTION
Zero-hardware verification. Steps:

  1. create/refresh the tools/emu Python virtual environment (setup_env.py)
  2. start emu_sink.py on a free loopback port (default 00:A2:D0:00:00:02)
  3. run a2dpwb-core.exe --cli --hci-tcp 127.0.0.1:<port> -d 00:A2:D0:00:00:02
     -c <codec> --test-tone --duration <n> with an isolated A2DPWB_CONFIG_DIR
  4. stop the sink and report PASS/FAIL from the core log: the [Streaming]
     state and the negotiated codec name must both appear

The sink is always stopped in a finally block. Logs go to artifacts\.

.PARAMETER Codec
Codec to stream. Default ldac (no decoder needed for a basic pass).

.PARAMETER Duration
Seconds of streaming once connected. Default 10.

.PARAMETER Port
TCP port for the virtual controller. Default 0 = pick a free port.

.PARAMETER CoreExe
a2dpwb-core.exe to test. Default: the installed app, else
<upstream>\target\release\a2dpwb-core.exe.

.PARAMETER UpstreamDir
Upstream clone with tools\emu. Default: discovered above this repo.

.PARAMETER ConfigDir
Isolated A2DPWB config folder. Default: <repo>\.emu-config (gitignored).

.PARAMETER Python
Python 3.11+ used to create the venv. Default: python.

.PARAMETER SkipSetup
Do not run setup_env.py (fail if the venv is missing).

.PARAMETER DryRun
Print the setup, sink and core commands; change nothing and start nothing.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File scripts\run-emulator.ps1 -DryRun
powershell -ExecutionPolicy Bypass -File scripts\run-emulator.ps1 -Codec ldac -Duration 10

.NOTES
Exit codes: 0 PASS, 1 FAIL, 2 the script could not run the test at all.
#>
[CmdletBinding()]
param(
    [ValidateSet('ldac', 'aptxhd', 'aptxll', 'aptx', 'sbcxq', 'sbc', 'aac', 'lhdcv5', 'opus', 'opus05', 'faststream')]
    [string]$Codec = 'ldac',
    [int]$Duration = 10,
    [int]$Port = 0,
    [string]$CoreExe,
    [string]$UpstreamDir,
    [string]$ConfigDir,
    [string]$Python = 'python',
    [switch]$SkipSetup,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$LASTEXITCODE = 0

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ConfigDir) { $ConfigDir = Join-Path $RepoRoot '.emu-config' }
$Artifacts = Join-Path $RepoRoot 'artifacts'

$CodecPattern = @{
    'ldac' = 'LDAC'; 'aptxhd' = 'aptX HD'; 'aptxll' = 'aptX LL'; 'aptx' = 'aptX'
    'sbcxq' = 'SBC'; 'sbc' = 'SBC'; 'aac' = 'AAC'; 'lhdcv5' = 'LHDC'
    'opus' = 'Opus'; 'opus05' = 'Opus'; 'faststream' = 'FastStream'
}

function Find-Upstream {
    if ($UpstreamDir) { return $UpstreamDir }
    $dir = $RepoRoot
    for ($i = 0; $i -lt 6 -and $dir; $i++) {
        if (Test-Path -LiteralPath (Join-Path $dir 'tools\emu\emu_sink.py') -PathType Leaf) { return $dir }
        $nested = Join-Path $dir 'upstream'
        if (Test-Path -LiteralPath (Join-Path $nested 'tools\emu\emu_sink.py') -PathType Leaf) { return $nested }
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    throw 'upstream clone not found (no tools\emu\emu_sink.py above this repo); pass -UpstreamDir.'
}

function Resolve-CoreExe {
    param([string]$Upstream)
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($CoreExe) { $candidates.Add($CoreExe) }
    if ($env:LOCALAPPDATA) { $candidates.Add((Join-Path $env:LOCALAPPDATA 'A2DP Windows Bridge\a2dpwb-core.exe')) }
    $candidates.Add((Join-Path $Upstream 'target\release\a2dpwb-core.exe'))
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw "a2dpwb-core.exe not found (tried: $($candidates -join '; ')); build it (docs\BUILD-FOR-SOURCE.md) or pass -CoreExe."
}

function Get-FreePort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function Quote-Argument {
    param([string]$Value)
    if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
    return $Value
}

$sink = $null
$oldConfigEnv = $env:A2DPWB_CONFIG_DIR
try {
    $upstream = Find-Upstream
    $emuDir = Join-Path $upstream 'tools\emu'
    $venvPython = Join-Path $emuDir '.venv\Scripts\python.exe'
    $sinkScript = Join-Path $emuDir 'emu_sink.py'
    $setupScript = Join-Path $emuDir 'setup_env.py'
    $core = Resolve-CoreExe -Upstream $upstream
    if ($Port -le 0) { $Port = Get-FreePort }

    Write-Host "Upstream : $upstream"
    Write-Host "Core     : $core"
    Write-Host "Config   : $ConfigDir"
    Write-Host "Port     : $Port"
    Write-Host "Codec    : $Codec   Duration: ${Duration}s"

    if ($DryRun) {
        Write-Host ''
        Write-Host 'DRY RUN - nothing will be started or written.'
        if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf) -and -not $SkipSetup) {
            Write-Host "would run: `"$Python`" `"$setupScript`""
        }
        Write-Host "would run: `"$venvPython`" `"$sinkScript`" --port $Port --log-level INFO"
        Write-Host ("would run: `"$core`" --cli --hci-tcp 127.0.0.1:{0} -d 00:A2:D0:00:00:02 -c {1} --test-tone --duration {2}" -f $Port, $Codec, $Duration)
        Write-Host "would set A2DPWB_CONFIG_DIR=$ConfigDir"
        exit 0
    }

    if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
        if ($SkipSetup) { throw "tools\emu\.venv is missing and -SkipSetup was given: run `"$Python`" `"$setupScript`" first." }
        Write-Host 'Creating the emulator virtual environment (python tools/emu/setup_env.py)...'
        & $Python $setupScript
        if ($LASTEXITCODE -ne 0) { throw "setup_env.py failed (exit $LASTEXITCODE)." }
    }
    else {
        Write-Host "Using existing venv: $venvPython"
    }
    if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) { throw 'the venv python still does not exist after setup_env.py.' }

    New-Item -ItemType Directory -Force -Path $Artifacts | Out-Null
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $sinkOut = Join-Path $Artifacts "emu-sink-$Codec-$stamp.out.log"
    $sinkErr = Join-Path $Artifacts "emu-sink-$Codec-$stamp.err.log"
    $coreOut = Join-Path $Artifacts "emu-core-$Codec-$stamp.out.log"
    $coreErr = Join-Path $Artifacts "emu-core-$Codec-$stamp.err.log"

    Write-Host 'Starting the virtual sink...'
    $sinkArgs = @('emu_sink.py', '--port', "$Port", '--log-level', 'INFO')
    $sink = Start-Process -FilePath $venvPython -ArgumentList ($sinkArgs | ForEach-Object { Quote-Argument $_ }) `
        -WorkingDirectory $emuDir -RedirectStandardOutput $sinkOut -RedirectStandardError $sinkErr -PassThru -NoNewWindow

    $ready = $false
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if ($sink.HasExited) {
            $tail = if (Test-Path -LiteralPath $sinkErr) { (Get-Content -LiteralPath $sinkErr -Tail 20) -join "`n" } else { '' }
            throw "the sink exited early (code $($sink.ExitCode)). stderr:`n$tail"
        }
        if ((Test-Path -LiteralPath $sinkOut) -and (Select-String -LiteralPath $sinkOut -Pattern 'READY' -Quiet)) { $ready = $true; break }
        Start-Sleep -Milliseconds 300
    }
    if (-not $ready) { throw "the sink printed no READY within 60 s (see $sinkOut / $sinkErr)." }
    Write-Host 'Sink ready.'

    $env:A2DPWB_CONFIG_DIR = $ConfigDir
    Write-Host 'Streaming the test tone...'
    $coreArgs = @('--cli', '--hci-tcp', "127.0.0.1:$Port", '-d', '00:A2:D0:00:00:02', '-c', $Codec, '--test-tone', '--duration', "$Duration")
    $coreProc = Start-Process -FilePath $core -ArgumentList ($coreArgs | ForEach-Object { Quote-Argument $_ }) `
        -RedirectStandardOutput $coreOut -RedirectStandardError $coreErr -PassThru -NoNewWindow
    $waitSeconds = $Duration + 60
    $exited = $false
    try {
        $coreProc | Wait-Process -Timeout $waitSeconds -ErrorAction Stop
        $exited = $true
    }
    catch {
        $exited = $coreProc.HasExited
    }
    if (-not $exited) {
        Write-Warning "the core did not exit within $waitSeconds s; stopping it."
        Stop-Process -Id $coreProc.Id -Force -ErrorAction SilentlyContinue
        $coreProc.WaitForExit(5000) | Out-Null
    }
    $coreCode = $coreProc.ExitCode

    $log = (Get-Content -LiteralPath $coreOut -ErrorAction SilentlyContinue) + (Get-Content -LiteralPath $coreErr -ErrorAction SilentlyContinue)
    $logFile = Join-Path $Artifacts "emu-$Codec-$stamp.log"
    $log | Set-Content -LiteralPath $logFile
    $streaming = $log | Select-String -Pattern '\[Streaming\]' -Quiet
    $codecSeen = $log | Select-String -Pattern ("Codec:\s*" + [regex]::Escape($CodecPattern[$Codec])) -Quiet

    Write-Host ''
    Write-Host "Core exit code : $coreCode"
    Write-Host "Streaming state: $streaming"
    Write-Host "Codec '$($CodecPattern[$Codec])' : $codecSeen"
    Write-Host "Log            : $logFile"
    if ($coreCode -eq 0 -and $streaming -and $codecSeen) {
        Write-Host 'PASS' -ForegroundColor Green
        exit 0
    }
    Write-Host 'FAIL' -ForegroundColor Red
    Write-Host 'Last log lines:'
    $log | Select-Object -Last 15 | ForEach-Object { Write-Host "  $_" }
    exit 1
}
catch {
    Write-Error "run-emulator failed: $($_.Exception.Message)"
    exit 2
}
finally {
    if ($sink -and -not $sink.HasExited) {
        Write-Host "Stopping the virtual sink (PID $($sink.Id))..."
        Stop-Process -Id $sink.Id -Force -ErrorAction SilentlyContinue
    }
    $env:A2DPWB_CONFIG_DIR = $oldConfigEnv
}
