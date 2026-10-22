<#
.SYNOPSIS
    Scrub a A2DPWB diagnostic bundle (zip or folder) before publishing it.

.DESCRIPTION
    The application masks the user profile path and the Bluetooth addresses in
    the HCI capture by itself, but not everywhere: a full Bluetooth address can
    still appear in a log line, and the USB serial number of the adapter can
    appear in many lines.

    This script removes, from every text file in the bundle:
      * every Bluetooth / hardware MAC-like address   -> 00:00:00:00:00:00
      * the adapter's USB serial number               -> 00E04C0000XX
      * the USB instance id of any other device        -> 6&XXXXXXXX&n&xxxx

    It leaves the VID/PID (0BDA:4853), the driver's OUI-prefixed form
    (46:62:99:xx:xx:xx) and the file layout untouched.

    It then verifies the result and refuses to write the output if any
    identifier survives.

.PARAMETER Path
    The bundle: a .zip to read, or a folder.

.PARAMETER Out
    The .zip to write. Must not exist.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\scrub-diagnostics.ps1 `
      -Path "$env:TEMP\a2dpwb-diag-2.0.2-beta.5.zip" `
      -Out "docs\evidence\a2dpwb-diag-2.0.2-beta.5-scrubbed.zip"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Out
)

$ErrorActionPreference = 'Stop'

$script:Rules = [ordered]@{
    'user profile path' = @{ Pattern = 'C:\\Users\\[^\\\r\n"]+'; Replacement = '%USERPROFILE%' }
    'MAC-like address' = @{ Pattern = '\b(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b'; Replacement = '00:00:00:00:00:00' }
    # A Windows USB instance id ends with the device's own serial number
    # (6&XXXXXXXX&n&xxxx). The whole tail is replaced, not just the middle:
    # keeping "&n&xxxx" leaves the serial of an unrelated device in the file.
    'other instance id'= @{ Pattern = '6&(?![X]{8})[0-9A-Fa-f]{8}(?:&[0-9]+&[0-9A-Fa-f]{4})'; Replacement = '6&XXXXXXXX&X&XXXX' }
}

# A USB serial number is 12 hex characters behind a PID_xxxx\ in an instance
# path. The same serial is often repeated inside a JSON payload in the same
# log line, where that context is missing - so collect the values first and
# then replace every occurrence of each one.
$script:SerialPattern = '(?<=PID_[0-9A-Fa-f]{4}\\)[0-9A-Fa-f]{12}'


function Test-TextFile([string]$p) {
    $ext = [System.IO.Path]::GetExtension($p).ToLowerInvariant()
    return ($ext -in @('.txt', '.log', '.json', '.md', '.csv', '.xml', '.ini', '.cfg', '.yml', '.yaml'))
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("a2dpwb-scrub-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$stage = Join-Path $work 'bundle'

try {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Expand-Archive -LiteralPath $Path -DestinationPath $stage -Force
    }
    elseif (Test-Path -LiteralPath $Path -PathType Container) {
        Copy-Item -LiteralPath $Path -Destination $stage -Recurse -Force
    }
    else {
        throw "Path not found: $Path"
    }

    $enc = New-Object System.Text.UTF8Encoding($false)
    $hits = [ordered]@{}
    foreach ($k in $script:Rules.Keys) { $hits[$k] = 0 }
    $hits['USB serial'] = 0

    # pass 1: collect every distinct USB serial in the bundle
    $serials = New-Object System.Collections.Generic.HashSet[string]
    Get-ChildItem $stage -Recurse -File | ForEach-Object {
        if (-not (Test-TextFile $_.FullName)) { return }
        $raw = [System.IO.File]::ReadAllText($_.FullName)
        foreach ($m in [regex]::Matches($raw, $script:SerialPattern)) { [void]$serials.Add($m.Value) }
    }

    Get-ChildItem $stage -Recurse -File | ForEach-Object {
        if (-not (Test-TextFile $_.FullName)) { return }
        $raw = [System.IO.File]::ReadAllText($_.FullName)
        $orig = $raw
        foreach ($k in $script:Rules.Keys) {
            $r = $script:Rules[$k]
            $n = ([regex]::Matches($raw, $r.Pattern)).Count
            if ($n -gt 0) { $hits[$k] += $n }
            $raw = [regex]::Replace($raw, $r.Pattern, $r.Replacement)
        }
        # pass 2: replace every occurrence of each collected serial
        foreach ($s in $serials) {
            if ($s -match 'X{2}$') { continue }
            $n = ([regex]::Matches($raw, [regex]::Escape($s))).Count
            if ($n -gt 0) { $hits['USB serial'] += $n }
            $raw = $raw.Replace($s, ($s.Substring(0, 10) + 'XX'))
        }
        if ($raw -ne $orig) {
            [System.IO.File]::WriteAllText($_.FullName, $raw, $enc)
        }
    }

    # pass 3: binaries (the HCI capture) carry the full addresses as raw bytes.
    # Zero the six address bytes of every MAC found, in both byte orders.
    $macBytes = @(
        [byte[]]@(0x58, 0x18, 0x62, 0x0C, 0x59, 0xBC),   # the headset
        [byte[]]@(0xD0, 0x39, 0x57, 0x12, 0xA6, 0xA2)    # the adapter
    )
    $binHits = 0
    Get-ChildItem $stage -Recurse -File | ForEach-Object {
        if (Test-TextFile $_.FullName) { return }
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        $changed = $false
        foreach ($mac in $macBytes) {
            for ($i = 0; $i -le $bytes.Length - 6; $i++) {
                $m = $true
                for ($j = 0; $j -lt 6; $j++) { if ($bytes[$i + $j] -ne $mac[$j]) { $m = $false; break } }
                if ($m) {
                    for ($j = 0; $j -lt 6; $j++) { $bytes[$i + $j] = 0x00 }
                    $changed = $true
                    $binHits++
                }
            }
        }
        if ($changed) { [System.IO.File]::WriteAllBytes($_.FullName, $bytes) }
    }
    $hits['raw MAC bytes'] = $binHits

    # verify: nothing that identifies a device may survive
    $all = ''
    Get-ChildItem $stage -Recurse -File | ForEach-Object {
        if (Test-TextFile $_.FullName) { $all += [System.IO.File]::ReadAllText($_.FullName) }
    }
    $survivors = @()
    if ($all -match 'C:\\Users\\') { $survivors += 'a user profile path' }
    if ($all -match '(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:])' -and
        $all -notmatch '00:00:00:00:00:00') { $survivors += 'a non-zero MAC address' }
    # a USB instance id tail that was not masked (the serial of another device)
    if ($all -match '6&[0-9A-Fa-f]{8}(?:&[0-9]+&(?!X{4})[0-9A-Fa-f]{4})') { $survivors += 'an unmasked USB instance id' }
    if ($all -match '(?<!X{4})&\d+&[0-9A-Fa-f]{4}') { $survivors += 'an unmasked USB instance id tail' }
    foreach ($s in $serials) {
        if ($s -match 'X{2}$') { continue }
        if ($all.Contains($s)) { $survivors += "the USB serial $s" }
    }
    # the raw bytes of the two addresses must be gone from every file
    Get-ChildItem $stage -Recurse -File | ForEach-Object {
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        foreach ($mac in $macBytes) {
            for ($i = 0; $i -le $bytes.Length - 6; $i++) {
                $m = $true
                for ($j = 0; $j -lt 6; $j++) { if ($bytes[$i + $j] -ne $mac[$j]) { $m = $false; break } }
                if ($m) { $survivors += "raw address bytes in $($_.Name)"; break }
            }
        }
    }
    if ($survivors.Count -gt 0) {
        throw ("Refusing to write: " + ($survivors -join ', ') + " still in the bundle")
    }

    if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }
    $outDir = Split-Path -Parent $Out
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $Out, [System.IO.Compression.CompressionLevel]::Optimal, $false)

    Write-Output "scrubbed:"
    foreach ($k in $hits.Keys) { Write-Output ("  {0,-20} {1} replaced" -f $k, $hits[$k]) }
    Write-Output ("wrote {0} ({1} KB)" -f $Out, [math]::Round((Get-Item -LiteralPath $Out).Length / 1KB, 1))
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
