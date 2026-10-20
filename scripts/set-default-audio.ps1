<#
.SYNOPSIS
Lists the active audio render endpoints and changes the Windows default output
device, e.g. to send PC audio only to the Bluetooth headphones through VB-CABLE.

.DESCRIPTION
Enumerates the active render endpoints of the MMDevice API (IMMDeviceEnumerator,
eRender, DEVICE_STATE_ACTIVE) and prints one line per endpoint:

  name | id | default

`name` is the friendly name from the device property store
(PKEY_Device_FriendlyName), `id` is the WASAPI endpoint id as returned by
IMMDevice::GetId ('{0.0.0.00000000}.{...}', the value a2dpwb-core.exe takes for
--audio-device), and the last column is `default` for the endpoint that is the
current default for the eConsole role, `no` for the others.

With -Device the script makes one endpoint the default for the eConsole, eMultimedia and eCommunications roles, which is exactly what Sound settings > Output does. The
public MMDevice API only *reads* the default, so the write goes through the
undocumented IPolicyConfig COM interface (CLSID_PolicyConfigClient
{870af99c-171d-4f9e-af0d-e63df40c2bc9}). The endpoint is matched by exact id
or by a case-insensitive substring of the friendly name; several matches are
listed and the script refuses to guess. The change is verified by reading the
default endpoint again.

Everything (enumeration, property store, SetDefaultEndpoint) is done by a C#
helper compiled with Add-Type from this file, so the script is self-contained.

.PARAMETER List
Print the active render endpoints and the current default. This is the default
action when neither -Device nor -Restore is given.

.PARAMETER Device
Render endpoint to make the default: the exact WASAPI endpoint id, or a
case-insensitive substring of the friendly name, e.g. 'VB-Audio Virtual Cable'.
When the text matches several endpoints (VB-CABLE registers a stereo and a
'16ch' render endpoint under the same driver name), the candidates are printed
and the endpoint with the shortest friendly name is taken, which is the stereo
one. Different names of the same length are reported as ambiguous and the
script exits with code 2; use the full id to be explicit. Together with
-Restore, -Device names the restore target instead of the automatic pick.

.PARAMETER Restore
Put the default back to the physical output. The candidates are the active
render endpoints whose name does not look virtual (a name containing VB-Audio
or CABLE is virtual). When several are active, endpoints on a software device
(their PnP parent is ROOT\ or SWD\, e.g. the Boom 3D 'Boom Audio' wrapper) are
skipped, then the current default is kept if it is one of the rest; otherwise
the candidates are listed and the script asks for -Device. -Device overrides
the automatic pick.

.PARAMETER WhatIf
Print the plan and change nothing (standard PowerShell common parameter).

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\set-default-audio.ps1 -List

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\set-default-audio.ps1 -Device "VB-Audio Virtual Cable" -WhatIf

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\set-default-audio.ps1 -Device "VB-Audio Virtual Cable"

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\set-default-audio.ps1 -Restore

.NOTES
Changing the default output changes where EVERY application plays, not only
A2DP-Windows-Bridge. With the virtual cable selected the PC speakers go silent
(the cable swallows the audio) while nothing streams that cable; A2DPWB -Mode
virtual captures the same cable, so start the stream before you expect sound.
Put the physical output back with -Restore when you are done.

Only active endpoints are listed and only the eConsole, eMultimedia and eCommunications roles
are changed.

Exit codes: 0 success, 1 failure (COM error or the change did not stick),
2 bad arguments, no matching endpoint, or an ambiguous name.
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
param(
    [switch]$List,
    [string]$Device,
    [switch]$Restore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$LASTEXITCODE = 0

function Fail {
    param([string]$Message, [int]$Code)
    [Console]::Error.WriteLine($Message)
    exit $Code
}

$Source = @'
using System;
using System.Runtime.InteropServices;

namespace A2dpwb.Audio
{
    internal enum EDataFlow { eRender = 0, eCapture = 1, eAll = 2 }
    internal enum ERole { eConsole = 0, eMultimedia = 1, eCommunications = 2 }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PROPERTYKEY
    {
        public Guid fmtid;
        public int pid;
    }

    [StructLayout(LayoutKind.Explicit)]
    internal struct PROPVARIANT
    {
        [FieldOffset(0)] public short vt;
        [FieldOffset(2)] public short wReserved1;
        [FieldOffset(4)] public short wReserved2;
        [FieldOffset(6)] public short wReserved3;
        [FieldOffset(8)] public IntPtr pointerValue;
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    internal class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")]
    internal class CPolicyConfigClient { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(EDataFlow dataFlow, int stateMask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int Item(int index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore store);
        [PreserveSig] int GetId(out IntPtr id);
        [PreserveSig] int GetState(out int state);
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPropertyStore
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetAt(int index, out PROPERTYKEY key);
        [PreserveSig] int GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
        [PreserveSig] int SetValue(ref PROPERTYKEY key, ref PROPVARIANT value);
        [PreserveSig] int Commit();
    }

    [ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPolicyConfig
    {
        [PreserveSig] int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, out IntPtr format);
        [PreserveSig] int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, [MarshalAs(UnmanagedType.Bool)] bool isDefault, out IntPtr format);
        [PreserveSig] int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId);
        [PreserveSig] int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr endpointFormat, IntPtr mixFormat);
        [PreserveSig] int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string deviceId, [MarshalAs(UnmanagedType.Bool)] bool isDefault, out long defaultPeriod, out long minimumPeriod);
        [PreserveSig] int SetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string deviceId, ref long period);
        [PreserveSig] int GetShareMode([MarshalAs(UnmanagedType.LPWStr)] string deviceId, out IntPtr mode);
        [PreserveSig] int SetShareMode([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr mode);
        [PreserveSig] int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string deviceId, [MarshalAs(UnmanagedType.Bool)] bool fxStore, ref PROPERTYKEY key, out PROPVARIANT value);
        [PreserveSig] int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string deviceId, [MarshalAs(UnmanagedType.Bool)] bool fxStore, ref PROPERTYKEY key, ref PROPVARIANT value);
        [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string deviceId, ERole role);
        [PreserveSig] int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string deviceId, [MarshalAs(UnmanagedType.Bool)] bool visible);
    }

    public class EndpointInfo
    {
        public string Id;
        public string Name;
        public bool IsDefaultConsole;
    }

    public static class AudioDevices
    {
        private const int STGM_READ = 0;
        private const int DEVICE_STATE_ACTIVE = 0x1;
        private const short VT_LPWSTR = 31;

        [DllImport("ole32.dll")]
        private static extern int PropVariantClear(ref PROPVARIANT value);

        private static PROPERTYKEY FriendlyNameKey()
        {
            PROPERTYKEY key = new PROPERTYKEY();
            key.fmtid = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0");
            key.pid = 14;
            return key;
        }

        public static EndpointInfo[] GetRenderEndpoints()
        {
            string defaultId = GetDefaultRenderId();
            IMMDeviceEnumerator enumerator = null;
            IMMDeviceCollection collection = null;
            try
            {
                enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
                int hr = enumerator.EnumAudioEndpoints(EDataFlow.eRender, DEVICE_STATE_ACTIVE, out collection);
                if (hr != 0) throw new COMException("IMMDeviceEnumerator::EnumAudioEndpoints(eRender, ACTIVE) failed", hr);

                int count;
                hr = collection.GetCount(out count);
                if (hr != 0) throw new COMException("IMMDeviceCollection::GetCount failed", hr);

                EndpointInfo[] result = new EndpointInfo[count];
                for (int i = 0; i < count; i++)
                {
                    IMMDevice device;
                    hr = collection.Item(i, out device);
                    if (hr != 0) throw new COMException("IMMDeviceCollection::Item failed", hr);
                    try
                    {
                        EndpointInfo info = new EndpointInfo();
                        info.Id = ReadId(device);
                        info.Name = ReadFriendlyName(device);
                        info.IsDefaultConsole = string.Equals(info.Id, defaultId, StringComparison.OrdinalIgnoreCase);
                        result[i] = info;
                    }
                    finally
                    {
                        Marshal.ReleaseComObject(device);
                    }
                }
                return result;
            }
            finally
            {
                if (collection != null) Marshal.ReleaseComObject(collection);
                if (enumerator != null) Marshal.ReleaseComObject(enumerator);
            }
        }

        public static string GetDefaultRenderId()
        {
            return GetDefaultRenderIdForRole((int)ERole.eConsole);
        }

        public static string GetDefaultRenderIdForRole(int role)
        {
            ERole wanted = (ERole)role;
            IMMDeviceEnumerator enumerator = null;
            IMMDevice device = null;
            try
            {
                enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
                int hr = enumerator.GetDefaultAudioEndpoint(EDataFlow.eRender, wanted, out device);
                if (hr != 0) throw new COMException("IMMDeviceEnumerator::GetDefaultAudioEndpoint(eRender, " + wanted + ") failed", hr);
                return ReadId(device);
            }
            finally
            {
                if (device != null) Marshal.ReleaseComObject(device);
                if (enumerator != null) Marshal.ReleaseComObject(enumerator);
            }
        }

        public static void SetDefaultRender(string deviceId)
        {
            if (deviceId == null || deviceId.Length == 0) throw new ArgumentException("deviceId is empty");
            IPolicyConfig config = null;
            try
            {
                config = (IPolicyConfig)(new CPolicyConfigClient());
                int hr = config.SetDefaultEndpoint(deviceId, ERole.eConsole);
                if (hr != 0) throw new COMException("IPolicyConfig::SetDefaultEndpoint(eConsole) failed", hr);
                hr = config.SetDefaultEndpoint(deviceId, ERole.eMultimedia);
                if (hr != 0) throw new COMException("IPolicyConfig::SetDefaultEndpoint(eMultimedia) failed", hr);
                // eCommunications too: a call app that keeps the old default would
                // still play into the virtual cable and be inaudible.
                hr = config.SetDefaultEndpoint(deviceId, ERole.eCommunications);
                if (hr != 0) throw new COMException("IPolicyConfig::SetDefaultEndpoint(eCommunications) failed", hr);
            }
            finally
            {
                if (config != null) Marshal.ReleaseComObject(config);
            }
        }

        private static string ReadId(IMMDevice device)
        {
            IntPtr pointer;
            int hr = device.GetId(out pointer);
            if (hr != 0) throw new COMException("IMMDevice::GetId failed", hr);
            try
            {
                return Marshal.PtrToStringUni(pointer);
            }
            finally
            {
                Marshal.FreeCoTaskMem(pointer);
            }
        }

        private static string ReadFriendlyName(IMMDevice device)
        {
            IPropertyStore store = null;
            try
            {
                int hr = device.OpenPropertyStore(STGM_READ, out store);
                if (hr != 0) throw new COMException("IMMDevice::OpenPropertyStore failed", hr);
                PROPERTYKEY key = FriendlyNameKey();
                PROPVARIANT value;
                hr = store.GetValue(ref key, out value);
                if (hr != 0) return null;
                string name = null;
                if (value.vt == VT_LPWSTR && value.pointerValue != IntPtr.Zero)
                {
                    name = Marshal.PtrToStringUni(value.pointerValue);
                }
                PropVariantClear(ref value);
                return name;
            }
            finally
            {
                if (store != null) Marshal.ReleaseComObject(store);
            }
        }
    }
}
'@

if (-not ('A2dpwb.Audio.AudioDevices' -as [type])) {
    Add-Type -TypeDefinition $Source -Language CSharp
}

function Test-VirtualName {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    foreach ($marker in @('VB-Audio', 'CABLE')) {
        if ($Name.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function Get-Endpoints {
    $items = [A2dpwb.Audio.AudioDevices]::GetRenderEndpoints()
    $result = @()
    foreach ($item in $items) {
        $name = $item.Name
        if ([string]::IsNullOrWhiteSpace($name)) { $name = '(no friendly name)' }
        $result += [pscustomobject]@{
            Id        = [string]$item.Id
            Name      = [string]$name
            IsDefault = [bool]$item.IsDefaultConsole
            Virtual   = (Test-VirtualName -Name ([string]$name))
        }
    }
    return $result
}

function Show-Endpoints {
    param($Endpoints)
    if (@($Endpoints).Count -eq 0) {
        Write-Host 'No active render endpoint was found.'
        return
    }
    foreach ($endpoint in $Endpoints) {
        $mark = 'no'
        if ($endpoint.IsDefault) { $mark = 'default' }
        Write-Host ('{0} | {1} | {2}' -f $endpoint.Name, $endpoint.Id, $mark)
    }
}

function Get-CurrentDefault {
    param($Endpoints)
    $current = @($Endpoints | Where-Object { $_.IsDefault })
    if ($current.Count -eq 1) { return $current[0] }
    return $null
}

function Resolve-Target {
    param($Endpoints, [string]$Query)

    if ([string]::IsNullOrWhiteSpace($Query)) {
        Fail 'The device selector is empty: pass an endpoint id or part of the friendly name.' 2
    }
    $wanted = $Query.Trim()
    if ($wanted.Length -eq 0) {
        Fail 'The device selector is empty: pass an endpoint id or part of the friendly name.' 2
    }

    $byId = @($Endpoints | Where-Object { $_.Id -eq $wanted })
    if ($byId.Count -eq 1) { return $byId[0] }

    $byExactName = @($Endpoints | Where-Object { $_.Name -eq $wanted })
    if ($byExactName.Count -eq 1) { return $byExactName[0] }

    $byName = @($Endpoints | Where-Object { $_.Name.IndexOf($wanted, [StringComparison]::OrdinalIgnoreCase) -ge 0 })

    if ($byName.Count -eq 1) { return $byName[0] }
    if ($byName.Count -eq 0) {
        $available = @($Endpoints | ForEach-Object { '  ' + $_.Name + ' | ' + $_.Id }) -join "`n"
        [Console]::Error.WriteLine("No active render endpoint matches '$Query'. Active endpoints:`n$available")
        exit 2
    }

    $shortest = $byName[0]
    foreach ($candidate in $byName) {
        if ($candidate.Name.Length -lt $shortest.Name.Length) { $shortest = $candidate }
    }
    $sameLength = @($byName | Where-Object { $_.Name.Length -eq $shortest.Name.Length })
    if ($sameLength.Count -eq 1) {
        Write-Host "'$Query' matches $($byName.Count) render endpoints; using the shortest name:"
        foreach ($candidate in $byName) { Write-Host ('  ' + $candidate.Name + ' | ' + $candidate.Id) }
        return $shortest
    }

    $candidates = @($byName | ForEach-Object { '  ' + $_.Name + ' | ' + $_.Id }) -join "`n"
    [Console]::Error.WriteLine("'$Query' is ambiguous, it matches $($byName.Count) render endpoints:`n$candidates`nUse the full id or a longer part of the name.")
    exit 2
}

function Test-HardwareEndpoint {
    param([string]$Id)

    if (-not (Get-Command -Name Get-PnpDeviceProperty -ErrorAction SilentlyContinue)) { return $null }
    $instanceId = 'SWD\MMDEVAPI\' + $Id
    try {
        $parent = (Get-PnpDeviceProperty -InstanceId $instanceId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop).Data
    }
    catch {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($parent)) { return $null }
    if ($parent -match '^(ROOT|SWD)\\') { return $false }
    return $true
}

function Select-PhysicalTarget {
    param($Endpoints)

    $candidates = @($Endpoints | Where-Object { -not $_.Virtual })
    if ($candidates.Count -eq 0) {
        Fail 'No active physical (non-virtual) render endpoint was found: pass -Device <name-or-id>.' 2
    }
    if ($candidates.Count -eq 1) { return $candidates[0] }

    $hardware = @()
    foreach ($candidate in $candidates) {
        if ((Test-HardwareEndpoint -Id $candidate.Id) -eq $true) { $hardware += $candidate }
    }
    if ($hardware.Count -eq 1) {
        Write-Host "Several non-virtual endpoints are active; ignoring the software ones and using the hardware output: $($hardware[0].Name)"
        return $hardware[0]
    }
    if ($hardware.Count -gt 1) { $candidates = $hardware }
    if ($candidates.Count -eq 1) { return $candidates[0] }

    $current = @($candidates | Where-Object { $_.IsDefault })
    if ($current.Count -eq 1) {
        Write-Host "Several physical endpoints are active; keeping the current default: $($current[0].Name)"
        return $current[0]
    }

    $list = @($candidates | ForEach-Object { '  ' + $_.Name + ' | ' + $_.Id }) -join "`n"
    [Console]::Error.WriteLine("Cannot pick a physical output automatically:`n$list`nPass -Device <name-or-id>.")
    exit 2
}

function Show-Plan {
    param($Endpoints, $Target, [string]$Action)

    $current = Get-CurrentDefault -Endpoints $Endpoints
    $currentText = '(none reported)'
    if ($null -ne $current) { $currentText = '{0} [{1}]' -f $current.Name, $current.Id }

    Write-Host "Action  : $Action"
    Write-Host "Target  : $($Target.Name)"
    Write-Host "Id      : $($Target.Id)"
    Write-Host "Virtual : $($Target.Virtual)"
    Write-Host "Current : $currentText"
    Write-Host 'Roles   : eConsole (0), eMultimedia (1), eCommunications (2)'
}

function Set-DefaultEndpoint {
    param($Target)

    if (-not $PSCmdlet.ShouldProcess(('{0} [{1}]' -f $Target.Name, $Target.Id), 'Set as default render endpoint (eConsole, eMultimedia)')) {
        Write-Host 'No change was made.'
        exit 0
    }

    try {
        [A2dpwb.Audio.AudioDevices]::SetDefaultRender($Target.Id)
    }
    catch {
        Fail "SetDefaultEndpoint failed: $($_.Exception.Message)" 1
    }

    $after = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $after = Get-Endpoints
        $default = Get-CurrentDefault -Endpoints $after
        if ($null -ne $default -and $default.Id -eq $Target.Id) {
            Write-Host "OK: the default render endpoint is now '$($default.Name)'."
            Write-Host "    $($default.Id)"
            exit 0
        }
        Start-Sleep -Milliseconds 150
    }

    $reported = '(none reported)'
    if ($null -ne $after) {
        $default = Get-CurrentDefault -Endpoints $after
        if ($null -ne $default) { $reported = '{0} [{1}]' -f $default.Name, $default.Id }
    }
    Fail "The default endpoint did not change: Windows still reports $reported." 1
}

try {
    $wantList = $List.IsPresent
    $haveDevice = $PSBoundParameters.ContainsKey('Device')

    if (-not $wantList -and -not $haveDevice -and -not $Restore.IsPresent) { $wantList = $true }

    if ($wantList -and ($haveDevice -or $Restore.IsPresent)) {
        Fail '-List cannot be combined with -Device or -Restore: run them separately.' 2
    }

    $endpoints = @(Get-Endpoints)

    if ($wantList) {
        Show-Endpoints -Endpoints $endpoints
        exit 0
    }

    if ($Restore.IsPresent) {
        if ($haveDevice) {
            $target = Resolve-Target -Endpoints $endpoints -Query $Device
        }
        else {
            $target = Select-PhysicalTarget -Endpoints $endpoints
        }
        Show-Plan -Endpoints $endpoints -Target $target -Action 'restore the physical output as default'
    }
    else {
        $target = Resolve-Target -Endpoints $endpoints -Query $Device
        Show-Plan -Endpoints $endpoints -Target $target -Action 'make this render endpoint the default'
    }

    Set-DefaultEndpoint -Target $target
    exit 0
}
catch {
    [Console]::Error.WriteLine("set-default-audio failed: $($_.Exception.Message)")
    exit 1
}
