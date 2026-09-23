<#
.SYNOPSIS
    Switch input source on a Dell U2715H (or similar DDC/CI-capable monitor) from Windows,
    with optional global hotkeys.

.DESCRIPTION
    Uses the Windows Monitor Configuration API (dxva2.dll) to send a DDC/CI
    VCP "Input Select" (0x60) command directly to the monitor - no drivers
    or third-party tools required.

    Standard MCCS input codes used here:
        DP     = DisplayPort      (0x0F)
        MDP    = Mini DisplayPort (0x10)
        HDMI1  = HDMI 1           (0x11)
        HDMI2  = HDMI 2           (0x12)

.USAGE
    CLI:
        .\dell-input.ps1 -Input DP
        .\dell-input.ps1 -Input MDP
        .\dell-input.ps1 -Input HDMI1
        .\dell-input.ps1 -Input HDMI2
        .\dell-input.ps1 -List          # show detected monitors + current input

    GUI (with global hotkeys active while the window is open):
        .\dell-input.ps1               # no args -> shows a small button window

    Default hotkeys (work system-wide while the GUI window is open, even
    if it's not focused - edit $HotkeyBindings below to change them):
        Ctrl+Alt+1  -> HDMI1
        Ctrl+Alt+2  -> HDMI2
        Ctrl+Alt+D  -> DisplayPort
        Ctrl+Alt+M  -> Mini DisplayPort

.NOTES
    If Windows blocks script execution, run once:
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
    then re-run the script in that same PowerShell window.

    If a hotkey doesn't fire, another app has probably already claimed that
    combination - change it in $HotkeyBindings below to something free.
#>

param(
    [ValidateSet('DP', 'MDP', 'HDMI1', 'HDMI2')]
    [string]$Input,

    [switch]$List
)

# ---- Customize your global hotkeys here ------------------------------------
# Modifiers: any comma-combo of Control, Alt, Shift, Win
# Key: any name from System.Windows.Forms.Keys (D0-D9, A-Z, F1-F12, etc.)
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
using System.Windows.Forms;

public class DDC
{
    [DllImport("user32.dll")]
    public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumDelegate lpfnEnum, IntPtr dwData);

    public delegate bool MonitorEnumDelegate(IntPtr hMonitor, IntPtr hdcMonitor, IntPtr lprcMonitor, IntPtr dwData);

    [StructLayout(LayoutKind.Sequential)]
    public struct PHYSICAL_MONITOR
    {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }

    [DllImport("dxva2.dll")]
    public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, out uint pdwNumberOfPhysicalMonitors);

    [DllImport("dxva2.dll")]
    public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint dwPhysicalMonitorArraySize, [Out] PHYSICAL_MONITOR[] pPhysicalMonitorArray);

    [DllImport("dxva2.dll")]
    public static extern bool DestroyPhysicalMonitor(IntPtr hMonitor);

    [DllImport("dxva2.dll")]
    public static extern bool SetVCPFeature(IntPtr hMonitor, byte bVCPCode, uint dwNewValue);

    [DllImport("dxva2.dll")]
    public static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr hMonitor, byte bVCPCode, IntPtr pvct, out uint pdwCurrentValue, out uint pdwMaximumValue);

    public static List<PHYSICAL_MONITOR> GetAllPhysicalMonitors()
    {
        var result = new List<PHYSICAL_MONITOR>();
        MonitorEnumDelegate callback = (IntPtr hMonitor, IntPtr hdc, IntPtr rect, IntPtr data) =>
        {
            uint count;
            if (GetNumberOfPhysicalMonitorsFromHMONITOR(hMonitor, out count) && count > 0)
            {
                var monitors = new PHYSICAL_MONITOR[count];
                if (GetPhysicalMonitorsFromHMONITOR(hMonitor, count, monitors))
                {
                    result.AddRange(monitors);
                }
            }
            return true;
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero);
        return result;
    }
}

// Invisible native window used only to receive WM_HOTKEY messages.
public class HotkeyWindow : NativeWindow, IDisposable
{
    private const int WM_HOTKEY = 0x0312;

    // Called from PowerShell as: $win.OnHotkey = { param($id) ... }
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

if (-not ([System.Management.Automation.PSTypeName]'DDC').Type) {
    Add-Type -TypeDefinition $signature -ReferencedAssemblies 'System.Windows.Forms' -Language CSharp
}

# VCP 0x60 = Input Select. Standard MCCS codes.
$global:InputCodes = [ordered]@{
    'DP'    = 0x0F   # DisplayPort
    'MDP'   = 0x10   # Mini DisplayPort
    'HDMI1' = 0x11   # HDMI 1
    'HDMI2' = 0x12   # HDMI 2
}

# Win32 MOD_* flags for RegisterHotKey
$script:ModFlags = @{ 'Alt' = 0x1; 'Control' = 0x2; 'Shift' = 0x4; 'Win' = 0x8 }

function global:ConvertTo-ModifierFlags {
    param([string]$ModifierList)
    $flags = 0
    foreach ($part in ($ModifierList -split ',')) {
        $flags = $flags -bor $script:ModFlags[$part.Trim()]
    }
    return [uint32]$flags
}

function global:Get-Monitors {
    [DDC]::GetAllPhysicalMonitors()
}

function global:Set-MonitorInput {
    param([string]$InputName)

    $code = $global:InputCodes[$InputName]
    $monitors = Get-Monitors
    if ($monitors.Count -eq 0) {
        Write-Host "No DDC/CI-capable monitors detected." -ForegroundColor Red
        return $false
    }

    $ok = $false
    foreach ($mon in $monitors) {
        $handle = $mon.hPhysicalMonitor
        if ([DDC]::SetVCPFeature($handle, 0x60, [uint32]$code)) {
            Write-Host "Switched '$($mon.szPhysicalMonitorDescription)' to $InputName." -ForegroundColor Green
            $ok = $true
        }
        else {
            Write-Host "Failed to send command to '$($mon.szPhysicalMonitorDescription)'." -ForegroundColor Yellow
        }
        [DDC]::DestroyPhysicalMonitor($handle) | Out-Null
    }
    return $ok
}

function global:Show-MonitorList {
    $monitors = Get-Monitors
    if ($monitors.Count -eq 0) {
        Write-Host "No DDC/CI-capable monitors detected." -ForegroundColor Red
        return
    }
    foreach ($mon in $monitors) {
        $handle = $mon.hPhysicalMonitor
        $current = 0; $max = 0
        [void][DDC]::GetVCPFeatureAndVCPFeatureReply($handle, 0x60, [IntPtr]::Zero, [ref]$current, [ref]$max)
        $name = ($global:InputCodes.GetEnumerator() | Where-Object { $_.Value -eq $current } | Select-Object -First 1).Key
        if (-not $name) { $name = "0x{0:X}" -f $current }
        Write-Host "$($mon.szPhysicalMonitorDescription): current input = $name (max=0x$('{0:X}' -f $max))"
        [DDC]::DestroyPhysicalMonitor($handle) | Out-Null
    }
}

# ---- Optional GUI (with global hotkeys) ------------------------------------

function global:Show-Gui {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Dell Monitor Input Switch"
    $form.Size = New-Object System.Drawing.Size -ArgumentList @(280, 260)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false

    $status = New-Object System.Windows.Forms.Label
    $status.Text = "Choose an input:"
    $status.AutoSize = $true
    $status.Location = New-Object System.Drawing.Point -ArgumentList @(15, 15)
    $form.Controls.Add($status)

    $y = 45
    foreach ($name in 'DP', 'MDP', 'HDMI1', 'HDMI2') {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $name
        $btn.Width = 220
        $btn.Tag = $name
        $btn.Location = New-Object System.Drawing.Point -ArgumentList @(20, $y)
        $btn.Add_Click({
            param($sender, $e)
            $chosen = $sender.Tag
            $success = Set-MonitorInput -InputName $chosen
            $status.Text = if ($success) { "Switched to $chosen." } else { "Failed - see console." }
        })
        $form.Controls.Add($btn)
        $y += 35
    }

    # --- register global hotkeys ---
    $hotkeyWin = New-Object HotkeyWindow

    # map hotkey id -> input name, for the callback below
    $idToInput = @{}
    foreach ($b in $global:HotkeyBindings) { $idToInput[$b.Id] = $b.Input }

    $hotkeyWin.OnHotkey = {
        param($id)
        $inputName = $idToInput[$id]
        if ($inputName) {
            $success = Set-MonitorInput -InputName $inputName
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
    $hintBox.Text = "Hotkeys:`n" + ($hintLines -join "`n")
    $hintBox.AutoSize = $true
    $hintY = $y + 10
    $hintBox.Location = New-Object System.Drawing.Point -ArgumentList @(15, $hintY)
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

if ($List) {
    Show-MonitorList
}
elseif ($Input) {
    Set-MonitorInput -InputName $Input | Out-Null
}
else {
    Show-Gui
}
