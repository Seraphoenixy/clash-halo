# Scrolls the app window with the mouse wheel, for reading pages taller than the window.
# Logical client coordinates, same convention as click-window.ps1.
#Requires -Version 7.0
param(
    [Parameter(Mandatory)][double]$X,
    [Parameter(Mandatory)][double]$Y,
    [Parameter(Mandatory)][int]$Notches,
    [string]$ProcessName = 'clash-halo'
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HaloWheel {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
'@

[void][HaloWheel]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))
$proc = Get-Process -Name $ProcessName | Select-Object -First 1
$hwnd = $proc.MainWindowHandle
if ($hwnd -eq [IntPtr]::Zero) { throw "no window for $ProcessName" }
[void][HaloWheel]::SetForegroundWindow($hwnd)

$dpi = [HaloWheel]::GetDpiForWindow($hwnd)
$scale = $dpi / 96.0
$pt = New-Object HaloWheel+POINT
$pt.X = [int]($X * $scale)
$pt.Y = [int]($Y * $scale)
[void][HaloWheel]::ClientToScreen($hwnd, [ref]$pt)
[void][HaloWheel]::SetCursorPos($pt.X, $pt.Y)
Start-Sleep -Milliseconds 120

# One notch is a single wheel click; the sign flips the direction. The delta is
# passed as a UInt32, so a downward notch is the two's-complement of -120 rather
# than a negative integer.
$delta = if ($Notches -ge 0) { [uint32]120 } else { [uint32]4294967176 }
for ($i = 0; $i -lt [Math]::Abs($Notches); $i++) {
    [HaloWheel]::mouse_event(0x0800, 0, 0, $delta, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
}
Write-Output "scrolled $Notches at logical ($X,$Y) scale=$scale"
