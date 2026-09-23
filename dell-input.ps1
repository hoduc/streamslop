<#
.SYNOPSIS
    Switch input source on a Dell U2715H (or similar DDC/CI-capable monitor) from Windows,
    with a monitor picker (for multi-monitor setups) and optional global hotkeys.

.DESCRIPTION
    Enumerates monitors via QueryDisplayConfig (the modern DisplayConfig API),
    then sends DDC/CI VCP "Input Select" (0x60) commands to the target monitor.

    This avoids the older EnumDisplayMonitors/GetPhysicalMonitorsFromHMONITOR
    approach for enumeration and gives you stable target names, adapter LUIDs,
    and real friendly names without relying on WMI EDID parsing.

    Standard MCCS input codes used here:
        DP     = DisplayPort      (0x0F)
        MDP    = Mini DisplayPort (0x10)
        HDMI1  = HDMI 1           (0x11)
        HDMI2  = HDMI 2           (0x12)

.USAGE
    First, find out which index is your Dell monitor:
        .\dell-input.ps1 -List

    CLI (MonitorIndex is the number shown by -List):
        .\dell-input.ps1 -Input HDMI1 -MonitorIndex 0
        .\dell-input.ps1 -Input DP    -MonitorIndex 1

    GUI (pick the monitor from the dropdown at the top; hotkeys act on
    whichever monitor is currently selected there):
        .\dell-input.ps1

    Default hotkeys (system-wide while the GUI window is open):
        Ctrl+Alt+1  -> HDMI1
        Ctrl+Alt+2  -> HDMI2
        Ctrl+Alt+D  -> DisplayPort
        Ctrl+Alt+M  -> Mini DisplayPort

.NOTES
    If Windows blocks script execution, run once:
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

    The script automatically detects and recovers from running an outdated
    cached version of itself in an old PowerShell window (relaunches fresh
    automatically) - you shouldn't need to close windows manually anymore.
#>

param(
    [ValidateSet('DP', 'MDP', 'HDMI1', 'HDMI2')]
    [string]$Input,

    [int]$MonitorIndex = -1,

    [switch]$List,

    [switch]$DebugMonitors
)

# ---- Self-heal against stale cached types ----------------------------------
# PowerShell can't redefine a C# class once it's loaded into a session, so if
# you run an older copy of this script in a window and then update the file
# and run it again in that SAME window, the old class definitions stick
# around and newer code looks "missing". Detect that mismatch here and
# relaunch in a brand-new PowerShell process instead of failing with
# confusing type errors.
$existingDC = ([System.Management.Automation.PSTypeName]'DisplayConfig').Type
if ($existingDC -and -not $existingDC.GetMethod('GetAllMonitors')) {
    Write-Host "An older version of this script is already loaded in this PowerShell window - relaunching in a fresh session..." -ForegroundColor Yellow
    $quotedPath = '"' + $PSCommandPath + '"'
    $relaunchArgs = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quotedPath)
    if ($Input) { $relaunchArgs += @('-Input', $Input) }
    if ($MonitorIndex -ge 0) { $relaunchArgs += @('-MonitorIndex', $MonitorIndex) }
    if ($List) { $relaunchArgs += '-List' }
    if ($DebugMonitors) { $relaunchArgs += '-DebugMonitors' }
    Start-Process powershell -ArgumentList $relaunchArgs
    return
}

# ---- Customize your global hotkeys here ------------------------------------
$global:HotkeyBindings = @(
    @{ Id = 1; Modifiers = 'Control,Alt'; Key = 'D1'; Input = 'HDMI1' }
    @{ Id = 2; Modifiers = 'Control,Alt'; Key = 'D2'; Input = 'HDMI2' }
    @{ Id = 3; Modifiers = 'Control,Alt'; Key = 'D';  Input = 'DP'    }
    @{ Id = 4; Modifiers = 'Control,Alt'; Key = 'M';  Input = 'MDP'   }
)

# ---- Win32 / DDC-CI + hotkey P/Invoke plumbing -----------------------------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$signature = @"
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Text;
using System.Windows.Forms;

[StructLayout(LayoutKind.Sequential)]
public struct LUID
{
    public uint LowPart;
    public int HighPart;
    public ulong ToUInt64() { return ((ulong)(uint)HighPart << 32) | LowPart; }
}

[StructLayout(LayoutKind.Sequential)]
public struct DISPLAYCONFIG_RATIONAL
{
    public uint Numerator;
    public uint Denominator;
}

[StructLayout(LayoutKind.Sequential)]
public struct DISPLAYCONFIG_PATH_SOURCE_INFO
{
    public LUID adapterId;
    public uint id;
    public uint modeInfoIdx;
    public uint statusFlags;
}

[StructLayout(LayoutKind.Sequential)]
public struct DISPLAYCONFIG_PATH_TARGET_INFO
{
    public LUID adapterId;
    public uint id;
    public uint modeInfoIdx;
    public uint outputTechnology;
    public uint rotation;
    public uint scaling;
    public DISPLAYCONFIG_RATIONAL refreshRate;
    public uint scanLineOrdering;
    public int targetAvailable;   // BOOL
    public uint statusFlags;
}

[StructLayout(LayoutKind.Sequential)]
public struct DISPLAYCONFIG_PATH_INFO
{
    public DISPLAYCONFIG_PATH_SOURCE_INFO sourceInfo;
    public DISPLAYCONFIG_PATH_TARGET_INFO targetInfo;
    public uint flags;
}

[StructLayout(LayoutKind.Sequential)]
public struct DISPLAYCONFIG_MODE_INFO
{
    public uint infoType;
    public uint id;
    public LUID adapterId;
    // Union - we don't read mode data, so just pad it out large enough.
    public ulong _pad1;
    public ulong _pad2;
    public ulong _pad3;
    public ulong _pad4;
    public ulong _pad5;
    public ulong _pad6;
    public ulong _pad7;
    public ulong _pad8;
}

[StructLayout(LayoutKind.Sequential)]
public struct DISPLAYCONFIG_DEVICE_INFO_HEADER
{
    public uint type;
    public uint size;
    public LUID adapterId;
    public uint id;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct DISPLAYCONFIG_TARGET_DEVICE_NAME
{
    public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
    public uint flags;
    public uint outputTechnology;
    public ushort edidManufactureId;
    public ushort edidProductCodeId;
    public uint connectorInstance;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
    public string monitorFriendlyDeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
    public string monitorDevicePath;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct DISPLAYCONFIG_SOURCE_DEVICE_NAME
{
    public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
    public string viewGdiDeviceName;
}

public enum DISPLAYCONFIG_DEVICE_INFO_TYPE : uint
{
    GET_SOURCE_NAME            = 1,
    GET_TARGET_NAME            = 2,
    GET_TARGET_PREFERRED_MODE  = 3,
    GET_ADAPTER_NAME           = 4
}

public class DisplayMonitor
{
    public LUID AdapterId;
    public uint TargetId;
    public uint SourceId;
    public string FriendlyName;   // e.g. "DELL U2715H"
    public string GdiDeviceName;  // e.g. "\\.\DISPLAY1" (may be null if not active)
    public string DevicePath;     // monitor device path
    public bool Active;           // has a source (i.e. currently driven)
}

public static class DisplayConfig
{
    [DllImport("user32.dll")]
    public static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPathArrayElements, out uint numModeInfoArrayElements);

    [DllImport("user32.dll")]
    public static extern int QueryDisplayConfig(uint flags,
        ref uint numPathArrayElements, [Out] DISPLAYCONFIG_PATH_INFO[] pathInfoArray,
        ref uint numModeInfoArrayElements, [Out] DISPLAYCONFIG_MODE_INFO[] modeInfoArray,
        IntPtr currentTopologyId);

    [DllImport("user32.dll")]
    public static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_TARGET_DEVICE_NAME deviceName);

    [DllImport("user32.dll")]
    public static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_SOURCE_DEVICE_NAME deviceName);

    // QDC_ALL_PATHS = 0x00000001 (include inactive paths too)
    const uint QDC_ALL_PATHS = 0x00000001;
    // QDC_ONLY_ACTIVE_PATHS = 0x00000002
    const uint QDC_ONLY_ACTIVE_PATHS = 0x00000002;

    public static List<DisplayMonitor> GetAllMonitors(bool includeInactive)
    {
        var result = new List<DisplayMonitor>();
        uint flags = includeInactive ? QDC_ALL_PATHS : QDC_ONLY_ACTIVE_PATHS;

        uint pathCount, modeCount;
        int err = GetDisplayConfigBufferSizes(flags, out pathCount, out modeCount);
        if (err != 0) return result;

        var paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
        var modes = new DISPLAYCONFIG_MODE_INFO[modeCount];

        err = QueryDisplayConfig(flags, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
        if (err != 0) return result;

        for (uint i = 0; i < pathCount; i++)
        {
            var p = paths[i];
            var m = new DisplayMonitor();
            m.AdapterId = p.targetInfo.adapterId;
            m.TargetId  = p.targetInfo.id;
            m.SourceId  = p.sourceInfo.id;
            m.Active    = p.sourceInfo.id != 0xFFFFFFFF;

            // Friendly name via GET_TARGET_NAME
            var tname = new DISPLAYCONFIG_TARGET_DEVICE_NAME();
            tname.header.type = (uint)DISPLAYCONFIG_DEVICE_INFO_TYPE.GET_TARGET_NAME;
            tname.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_TARGET_DEVICE_NAME));
            tname.header.adapterId = p.targetInfo.adapterId;
            tname.header.id = p.targetInfo.id;
            if (DisplayConfigGetDeviceInfo(ref tname) == 0)
            {
                m.FriendlyName = tname.monitorFriendlyDeviceName;
                m.DevicePath = tname.monitorDevicePath;
            }

            // GDI device name via GET_SOURCE_NAME (only meaningful for active sources)
            if (m.Active)
            {
                var sname = new DISPLAYCONFIG_SOURCE_DEVICE_NAME();
                sname.header.type = (uint)DISPLAYCONFIG_DEVICE_INFO_TYPE.GET_SOURCE_NAME;
                sname.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_SOURCE_DEVICE_NAME));
                sname.header.adapterId = p.sourceInfo.adapterId;
                sname.header.id = p.sourceInfo.id;
                if (DisplayConfigGetDeviceInfo(ref sname) == 0)
                    m.GdiDeviceName = sname.viewGdiDeviceName;
            }

            result.Add(m);
        }
        return result;
    }
}

// DDC/CI access via dxva2.dll - we get physical monitor handles from the
// adapter's GDI device name (only available for active paths).
public static class DdcCi
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR
    {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFOEX
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szDevice;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public delegate bool MonitorEnumDelegate(IntPtr hMonitor, IntPtr hdcMonitor, IntPtr lprcMonitor, IntPtr dwData);

    [DllImport("user32.dll")]
    public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumDelegate lpfnEnum, IntPtr dwData);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX lpmi);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, out uint pdwNumberOfPhysicalMonitors);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint dwPhysicalMonitorArraySize, [Out] PHYSICAL_MONITOR[] pPhysicalMonitorArray);

    [DllImport("dxva2.dll")]
    public static extern bool DestroyPhysicalMonitor(IntPtr hMonitor);

    [DllImport("dxva2.dll")]
    public static extern bool SetVCPFeature(IntPtr hMonitor, byte bVCPCode, uint dwNewValue);

    [DllImport("dxva2.dll")]
    public static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr hMonitor, byte bVCPCode, IntPtr pvct, out uint pdwCurrentValue, out uint pdwMaximumValue);

    // Map GDI device name (e.g. "\\.\DISPLAY1") to its HMONITOR by walking
    // every monitor and reading its szDevice via GetMonitorInfo.
    public static IntPtr HMonitorFromGdiName(string gdiName)
    {
        if (string.IsNullOrEmpty(gdiName)) return IntPtr.Zero;

        IntPtr found = IntPtr.Zero;
        MonitorEnumDelegate callback = (IntPtr hMonitor, IntPtr hdc, IntPtr rect, IntPtr data) =>
        {
            var mi = new MONITORINFOEX();
            mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            if (GetMonitorInfo(hMonitor, ref mi))
            {
                if (string.Equals(mi.szDevice, gdiName, StringComparison.OrdinalIgnoreCase))
                {
                    found = hMonitor;
                    return false; // stop enumeration
                }
            }
            return true; // keep going
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero);
        return found;
    }

    public static List<PHYSICAL_MONITOR> GetPhysicalMonitors(string gdiName)
    {
        var result = new List<PHYSICAL_MONITOR>();
        IntPtr hmon = HMonitorFromGdiName(gdiName);
        if (hmon == IntPtr.Zero) return result;

        uint count;
        if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hmon, out count) || count == 0)
            return result;

        var arr = new PHYSICAL_MONITOR[count];
        if (GetPhysicalMonitorsFromHMONITOR(hmon, count, arr))
        {
            foreach (var pm in arr) result.Add(pm);
        }
        return result;
    }
}

// Invisible native window used only to receive WM_HOTKEY messages.
public class HotkeyWindow : NativeWindow, IDisposable
{
    private const int WM_HOTKEY = 0x0312;

    public Action<int> OnHotkey;

    [DllImport("user32.dll")]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    public HotkeyWindow()
    {
        CreateHandle(new CreateParams());
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY && OnHotkey != null)
        {
            OnHotkey((int)m.WParam);
        }
        base.WndProc(ref m);
    }

    public void Dispose()
    {
        DestroyHandle();
    }
}
"@

if (-not ([System.Management.Automation.PSTypeName]'DisplayConfig').Type) {
    Add-Type -TypeDefinition $signature -ReferencedAssemblies 'System.Windows.Forms' -Language CSharp
}

# VCP 0x60 = Input Select. Standard MCCS codes.
$global:InputCodes = [ordered]@{
    'DP'    = 0x0F   # DisplayPort
    'MDP'   = 0x10   # Mini DisplayPort
    'HDMI1' = 0x11   # HDMI 1
    'HDMI2' = 0x12   # HDMI 2
}

$script:ModFlags = @{ 'Alt' = 0x1; 'Control' = 0x2; 'Shift' = 0x4; 'Win' = 0x8 }

function global:ConvertTo-ModifierFlags {
    param([string]$ModifierList)
    $flags = 0
    foreach ($part in ($ModifierList -split ',')) {
        $flags = $flags -bor $script:ModFlags[$part.Trim()]
    }
    return [uint32]$flags
}

# Returns a list of active monitors (DDC/CI needs an active path).
function global:Get-Monitors {
    [DisplayConfig]::GetAllMonitors($false)
}

# Given a DisplayMonitor entry, get its physical monitor handle via dxva2.
# Returns @{ Handle = IntPtr; Description = string } or $null.
function global:Get-PhysicalMonitorHandle {
    param($Monitor)

    if (-not $Monitor.GdiDeviceName) { return $null }
    $pms = [DdcCi]::GetPhysicalMonitors($Monitor.GdiDeviceName)
    if ($pms.Count -eq 0) { return $null }
    $pm = $pms[0]
    return [pscustomobject]@{
        Handle      = $pm.hPhysicalMonitor
        Description = $pm.szPhysicalMonitorDescription
    }
}

# Format: [0] DELL U2715H - \\.\DISPLAY1
function global:Get-MonitorLabel {
    param($Monitor, [int]$Index)
    $name = if ($Monitor.FriendlyName) { $Monitor.FriendlyName } else { "(unknown)" }
    $gdi  = if ($Monitor.GdiDeviceName) { $Monitor.GdiDeviceName } else { "(inactive)" }
    return "[$Index] $name - $gdi"
}

function global:Set-MonitorInput {
    param(
        [string]$InputName,
        [int]$MonitorIndex = -1
    )

    $code = $global:InputCodes[$InputName]
    $monitors = Get-Monitors

    if ($monitors.Count -eq 0) {
        Write-Host "No active monitors detected via QueryDisplayConfig." -ForegroundColor Red
        return $false
    }

    if ($MonitorIndex -lt 0) {
        if ($monitors.Count -eq 1) {
            $MonitorIndex = 0
        }
        else {
            Write-Host "Multiple monitors detected - specify -MonitorIndex." -ForegroundColor Yellow
            for ($i = 0; $i -lt $monitors.Count; $i++) {
                Write-Host ("  " + (Get-MonitorLabel -Monitor $monitors[$i] -Index $i))
            }
            return $false
        }
    }

    if ($MonitorIndex -ge $monitors.Count) {
        Write-Host "MonitorIndex $MonitorIndex out of range (found $($monitors.Count))." -ForegroundColor Red
        return $false
    }

    $target = $monitors[$MonitorIndex]
    $pm = Get-PhysicalMonitorHandle -Monitor $target
    if (-not $pm) {
        Write-Host "Could not get physical monitor handle for '$($target.FriendlyName)'." -ForegroundColor Yellow
        return $false
    }

    try {
        if ([DdcCi]::SetVCPFeature($pm.Handle, 0x60, [uint32]$code)) {
            Write-Host "Switched '$($target.FriendlyName)' ($($target.GdiDeviceName)) to $InputName." -ForegroundColor Green
            return $true
        } else {
            Write-Host "Failed to send DDC/CI command to '$($target.FriendlyName)'." -ForegroundColor Yellow
            return $false
        }
    }
    finally {
        [DdcCi]::DestroyPhysicalMonitor($pm.Handle) | Out-Null
    }
}

function global:Show-MonitorList {
    $monitors = Get-Monitors
    if ($monitors.Count -eq 0) {
        Write-Host "No active monitors detected." -ForegroundColor Red
        return
    }
    for ($i = 0; $i -lt $monitors.Count; $i++) {
        $mon = $monitors[$i]
        $pm = Get-PhysicalMonitorHandle -Monitor $mon
        $currentName = "?"
        if ($pm) {
            $current = 0; $max = 0
            [void][DdcCi]::GetVCPFeatureAndVCPFeatureReply($pm.Handle, 0x60, [IntPtr]::Zero, [ref]$current, [ref]$max)
            $found = ($global:InputCodes.GetEnumerator() | Where-Object { $_.Value -eq $current } | Select-Object -First 1).Key
            if ($found) { $currentName = $found } else { $currentName = "0x{0:X}" -f $current }
            [DdcCi]::DestroyPhysicalMonitor($pm.Handle) | Out-Null
        }
        Write-Host "$(Get-MonitorLabel -Monitor $mon -Index $i): current input = $currentName"
    }
}

function global:Show-MonitorDebug {
    Write-Host "=== QueryDisplayConfig paths (all, incl. inactive) ===" -ForegroundColor Cyan
    $all = [DisplayConfig]::GetAllMonitors($true)
    for ($i = 0; $i -lt $all.Count; $i++) {
        $m = $all[$i]
        Write-Host "[$i] Active=$($m.Active)"
        Write-Host "    FriendlyName  : $($m.FriendlyName)"
        Write-Host "    GdiDeviceName : $($m.GdiDeviceName)"
        Write-Host "    DevicePath    : $($m.DevicePath)"
        Write-Host "    Adapter LUID  : 0x$('{0:X}' -f $m.AdapterId.ToUInt64())  TargetId=$($m.TargetId)  SourceId=$($m.SourceId)"
        $pm = Get-PhysicalMonitorHandle -Monitor $m
        if ($pm) {
            Write-Host "    PhysicalMon   : '$($pm.Description)'"
            [DdcCi]::DestroyPhysicalMonitor($pm.Handle) | Out-Null
        } else {
            Write-Host "    PhysicalMon   : (none)"
        }
        Write-Host ""
    }
}

# ---- Optional GUI (with monitor picker + global hotkeys) -------------------

function global:Show-Gui {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Dell Monitor Input Switch"
    $form.Size = New-Object System.Drawing.Size -ArgumentList @(360, 340)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false

    $monLabel = New-Object System.Windows.Forms.Label
    $monLabel.Text = "Target monitor:"
    $monLabel.AutoSize = $true
    $monLabel.Location = New-Object System.Drawing.Point -ArgumentList @(15, 15)
    $form.Controls.Add($monLabel)

    $monCombo = New-Object System.Windows.Forms.ComboBox
    $monCombo.Location = New-Object System.Drawing.Point -ArgumentList @(15, 35)
    $monCombo.Width = 320
    $monCombo.DropDownStyle = 'DropDownList'

    $monitorsAtStartup = Get-Monitors
    for ($i = 0; $i -lt $monitorsAtStartup.Count; $i++) {
        [void]$monCombo.Items.Add((Get-MonitorLabel -Monitor $monitorsAtStartup[$i] -Index $i))
    }
    if ($monCombo.Items.Count -gt 0) { $monCombo.SelectedIndex = 0 }
    $global:SelectedMonitorIndex = 0
    $monCombo.Add_SelectedIndexChanged({
        $global:SelectedMonitorIndex = $monCombo.SelectedIndex
    }.GetNewClosure())
    $form.Controls.Add($monCombo)

    $status = New-Object System.Windows.Forms.Label
    $status.Text = "Choose an input:"
    $status.AutoSize = $true
    $status.Location = New-Object System.Drawing.Point -ArgumentList @(15, 70)
    $form.Controls.Add($status)

    $y = 100
    foreach ($name in 'DP', 'MDP', 'HDMI1', 'HDMI2') {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $name
        $btn.Width = 320
        $btn.Tag = $name
        $btn.Location = New-Object System.Drawing.Point -ArgumentList @(15, $y)
        $btn.Add_Click({
            param($sender, $e)
            $chosen = $sender.Tag
            $success = Set-MonitorInput -InputName $chosen -MonitorIndex $global:SelectedMonitorIndex
            $status.Text = if ($success) { "Switched to $chosen." } else { "Failed - see console." }
        })
        $form.Controls.Add($btn)
        $y += 35
    }

    # --- register global hotkeys (act on whichever monitor is selected in the dropdown) ---
    $hotkeyWin = New-Object HotkeyWindow

    $idToInput = @{}
    foreach ($b in $global:HotkeyBindings) { $idToInput[$b.Id] = $b.Input }

    $hotkeyWin.OnHotkey = {
        param($id)
        $inputName = $idToInput[$id]
        if ($inputName) {
            $success = Set-MonitorInput -InputName $inputName -MonitorIndex $global:SelectedMonitorIndex
            $status.Text = if ($success) { "Switched to $inputName (hotkey)." } else { "Hotkey failed - see console." }
        }
    }.GetNewClosure()

    $hintLines = @()
    foreach ($b in $global:HotkeyBindings) {
        $mods = $b.Modifiers -replace 'Control', 'Ctrl'
        $vk = [uint32][System.Windows.Forms.Keys]::($b.Key)
        $flags = ConvertTo-ModifierFlags -ModifierList $b.Modifiers
        $registered = [HotkeyWindow]::RegisterHotKey($hotkeyWin.Handle, $b.Id, $flags, $vk)
        $label = "$mods+$($b.Key) -> $($b.Input)"
        if (-not $registered) { $label += "  (in use - not active)" }
        $hintLines += $label
    }

    $hintBox = New-Object System.Windows.Forms.Label
    $hintBox.Text = "Hotkeys act on the monitor selected above:`n" + ($hintLines -join "`n")
    $hintBox.AutoSize = $true
    $hintBox.Location = New-Object System.Drawing.Point -ArgumentList @(15, ($y + 10))
    $hintBox.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($hintBox)

    $form.Add_FormClosing({
        foreach ($b in $global:HotkeyBindings) {
            [HotkeyWindow]::UnregisterHotKey($hotkeyWin.Handle, $b.Id) | Out-Null
        }
        $hotkeyWin.Dispose()
    })

    [void]$form.ShowDialog()
}

# ---- Entry point ------------------------------------------------------------

try {
    if ($DebugMonitors) {
        Show-MonitorDebug
    }
    elseif ($List) {
        Show-MonitorList
    }
    elseif ($Input) {
        Set-MonitorInput -InputName $Input -MonitorIndex $MonitorIndex | Out-Null
    }
    else {
        Show-Gui
    }
}
catch {
    Write-Host "Unexpected error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Read-Host "Press Enter to close"
}