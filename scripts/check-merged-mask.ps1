<#
.SYNOPSIS
    Check upstream's masking code against a real diagnostic bundle.

.DESCRIPTION
    Takes the masking code of upstream A2DP-Windows-Bridge
    (app/src/crates/core/src/diag.rs, the merged state), compiles it as it is
    with rustc and runs it over every text file of a diagnostic bundle, then
    scans the result for identifiers that must not survive.

    The point is to check upstream's fix on a real archive, not only on
    generated logs: the bundle of issue #81 is the one with real data in it.

    The harness (mask-harness.rs) is upstream's masking block plus an entry
    point. It is seeded the way app/src/core/src/bundle.rs seeds the masker
    (masker.know(name); masker.know_adapter(address)), otherwise the device
    names are not masked and the result is misleading.

.PARAMETER Bundle
    The bundle to check: a .zip (the bundle as the app wrote it) or a folder.

.PARAMETER Names
    The names the app tells the masker: the profile's and the devices',
    separated by commas. Without them the names are not masked - the check
    says so. (One string, because powershell.exe -File does not pass arrays.)

.PARAMETER AdapterAddress
    The adapter's own address, the one the app tells the masker.

.PARAMETER MaskerSource
    The upstream file with the masking code (app/src/crates/core/src/diag.rs).
    Its masking block is copied out by this script.

.PARAMETER OutDir
    Where the masked copy is written. Default: a temp folder.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\check-merged-mask.ps1 `
      -Bundle "$env:APPDATA\A2DPWB\logs\bundles\a2dpwb-diag-<stamp>.zip" `
      -Names '<profile name>','<device name>' -AdapterAddress '<adapter address>'

.NOTES
    Needs rustc with a linker (the gnu toolchain works without MSVC:
    rustup run stable-x86_64-pc-windows-gnu rustc ...).
    Exit codes: 0 nothing identifying survives, 1 something survived.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Bundle,
    [string[]]$Names = @(),
    [string]$UserName = '',
    [string]$AdapterAddress = '',
    [string]$MaskerSource = '',
    [string]$OutDir = '',
    [switch]$KeepOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
# powershell.exe -File passes every argument as one string, so a list comes in
# as "a,b,c"
$nameList = @()
if ($Names) { $nameList = @($Names -join ',' -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
if (-not $UserName) {
    # $env:USERNAME can be empty (a service-like session); the profile path
    # has the name
    $UserName = if ($env:USERPROFILE) { Split-Path -Leaf $env:USERPROFILE } else { '' }
}
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('maskcheck-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null

# Where the masking code comes from: a file given, else upstream's own
# develop-v2.x (so the check always runs against the current code).
if (-not $MaskerSource) {
    $download = Join-Path $work 'diag-upstream.rs'
    $url = 'https://raw.githubusercontent.com/SeiyaFunaokaJP/A2DP-Windows-Bridge/develop-v2.x/app/src/crates/core/src/diag.rs'
    try {
        Invoke-WebRequest -Uri $url -OutFile $download -UseBasicParsing -TimeoutSec 60
        $MaskerSource = $download
        Write-Host "masking source: $url"
    }
    catch {
        $local = Join-Path $repoRoot 'upstream\app\src\crates\core\src\diag.rs'
        if (Test-Path -LiteralPath $local) {
            $MaskerSource = $local
            Write-Host "masking source: $local (upstream could not be reached)"
        }
        else {
            Write-Error "no masking source: pass -MaskerSource, or clone upstream next to this repo"
            exit 2
        }
    }
}
if (-not (Test-Path -LiteralPath $MaskerSource)) { Write-Error "no masking source: $MaskerSource"; exit 2 }

# --- the upstream masking block -------------------------------------------------
# The block is copied verbatim from upstream's diag.rs; only the entry point
# (tools/mask-harness.rs) is ours. The block starts at "pub fn
# mask_identifiers" and ends at the end of "fn mask_usb_serials".
$src = Get-Content -LiteralPath $MaskerSource
$start = ($src | Select-String -Pattern '^pub fn mask_identifiers' | Select-Object -First 1).LineNumber
if (-not $start) { Write-Error 'no mask_identifiers in the masking source'; exit 2 }
# the block ends with the closing brace of the last masking function
$last = ($src | Select-String -Pattern '^fn mask_usb_serials' | Select-Object -First 1).LineNumber
if (-not $last) { Write-Error 'no mask_usb_serials in the masking source'; exit 2 }
$endIdx = $last - 1
while ($endIdx -lt $src.Count -and $src[$endIdx] -ne '}') { $endIdx++ }
$block = $src[($start - 1)..$endIdx]
Write-Host ("masking block: lines {0}..{1} ({2} lines)" -f $start, ($endIdx + 1), $block.Count)

$harnessRs = Join-Path $work 'harness.rs'
$harnessExe = Join-Path $work 'harness.exe'
$entry = Get-Content -LiteralPath (Join-Path $repoRoot 'tools\mask-harness.rs') -Raw
$entry = $entry.Replace('@@MASK_BLOCK@@', ($block -join "`r`n"))
[System.IO.File]::WriteAllText($harnessRs, $entry, (New-Object System.Text.UTF8Encoding($false)))

Write-Host '== building the harness (upstream masking code, as it is) =='
$build = & rustup run stable-x86_64-pc-windows-gnu rustc -O --edition 2024 -o $harnessExe $harnessRs 2>&1
if (-not (Test-Path -LiteralPath $harnessExe)) {
    $build | ForEach-Object { Write-Host "  $_" }
    Write-Error 'the harness did not build'
    exit 2
}
Write-Host "  built $harnessExe"

# --- the bundle -----------------------------------------------------------------
Add-Type -AssemblyName System.IO.Compression.FileSystem
$srcDir = Join-Path $work 'src'
$outDir = if ($OutDir) { $OutDir } else { Join-Path $work 'out' }
New-Item -ItemType Directory -Force -Path $srcDir, $outDir | Out-Null
if (Test-Path -LiteralPath $Bundle -PathType Leaf) {
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Bundle, $srcDir)
}
else {
    Copy-Item -LiteralPath $Bundle -Destination $srcDir -Recurse -Force
}

function Test-TextFile([string]$p) {
    $ext = [System.IO.Path]::GetExtension($p).ToLowerInvariant()
    return ($ext -in @('.txt', '.log', '.json', '.md', '.csv', '.xml', '.ini', '.cfg', '.yml', '.yaml'))
}

# The identifiers to look for. The ones that are not known here (the bundle's
# own device names) are reported as "not checked" instead of "clean".
$checks = [ordered]@{
    "the user name in a path" = "C:\Users\$UserName"
    'the v1 mask form'        = ':xx:xx:xx'
    'a USB serial in a path'  = 'USB\VID_0BDA&PID_4853\00E04C'
}

function Get-Text([string]$dir) {
    $all = ''
    Get-ChildItem $dir -Recurse -File | ForEach-Object {
        if (Test-TextFile $_.FullName) { $all += [System.IO.File]::ReadAllText($_.FullName) }
    }
    return $all
}

$before = Get-Text $srcDir
Write-Host ''
Write-Host '== masking every text file =='
foreach ($f in Get-ChildItem $srcDir -Recurse -File) {
    $rel = $f.FullName.Substring($srcDir.Length + 1)
    $dest = Join-Path $outDir $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    if (Test-TextFile $f.FullName) {
        $args = @($f.FullName, $dest)
        if ($nameList.Count -gt 0) { $args += $nameList }
        if ($AdapterAddress) { $args += $AdapterAddress }
        & $harnessExe @args | Out-Null
    }
    else {
        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
    }
}

$after = Get-Text $outDir
Write-Host ''
Write-Host '== what survives =='
$survivors = 0
foreach ($k in $checks.Keys) {
    $n = ([regex]::Matches($after, [regex]::Escape($checks[$k]))).Count
    $was = ([regex]::Matches($before, [regex]::Escape($checks[$k]))).Count
    if ($n -gt 0) { $survivors++ }
    Write-Host ("  {0,-26} before {1,-5} after {2,-5} {3}" -f $k, $was, $n, $(if ($n -eq 0) { 'ok' } else { 'LEFT' }))
}
if ($nameList.Count -eq 0) {
    Write-Host '  the device names        not checked (pass -Names "name1,name2", the app tells the masker those)'
}
else {
    foreach ($n in $nameList) {
        $c = ([regex]::Matches($after, [regex]::Escape($n))).Count
        if ($c -gt 0) { $survivors++ }
        Write-Host ("  {0,-26} after {1,-5} {2}" -f ("the name '" + $n + "'"), $c, $(if ($c -eq 0) { 'ok' } else { 'LEFT' }))
    }
}

Write-Host ''
Write-Host '== a masked line, for the eye =='
foreach ($line in ($after -split "`r?`n")) {
    if ($line -match 'LE Audio.*pairing') { Write-Host ("  {0}" -f $line.Trim()) }
}

if ($KeepOutput) { Write-Host ("masked copy kept in {0}" -f $outDir) }
else { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

if ($survivors -eq 0) { Write-Host 'RESULT: nothing identifying survives in the text files.'; exit 0 }
Write-Host ("RESULT: {0} identifier(s) survive." -f $survivors)
exit 1
