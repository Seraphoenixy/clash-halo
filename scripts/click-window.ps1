# Clicks a point given in *logical* client coordinates.
#
# The screenshot pipeline works in physical pixels (PrintWindow output) while the
# Flutter layout uses logical pixels, and at 200% scaling those differ by a factor
# of two. Passing logical values here and scaling by the real DPI is what keeps
# the click where it was intended.
#
# Coordinates are relative to the **client area**, matching what Flutter lays out
# and what `capture-window.ps1` photographs. Do not add the title bar back in:
# GetWindowRect already starts at the frame, so anchoring to it pushed every click
# 29 logical px down (measured: client origin 13,58 at 192 DPI) — aiming at 订阅
# (y=127) actually hit the row below it, and the page never changed while the
# script reported success.
#Requires -Version 7.0
param(
    [Parameter(Mandatory)][double]$X,
    [Parameter(Mandatory)][double]$Y,
    [string]$ProcessName = 'clash-halo'
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HaloClick {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
'@

# Same reason as capture-window.ps1: an unaware process gets the window rect and
# SetCursorPos in virtualized units, so a click aimed at logical (95,168) lands
# at (142,252) and opens the wrong page. Per-monitor v2 makes the scaling below
# mean what it says. Fails harmlessly if the manifest already set an awareness.
[void][HaloClick]::SetProcessDpiAwarenessContext([IntPtr](-4))

$proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 } |
    Select-Object -First 1
if (-not $proc) { throw "找不到 $ProcessName 的窗口" }

$hwnd = $proc.MainWindowHandle
[void][HaloClick]::BringWindowToTop($hwnd)
[void][HaloClick]::SetForegroundWindow($hwnd)
Start-Sleep -Milliseconds 600

# Anchor at the *client* origin, not the window rect: the frame's title bar is
# part of GetWindowRect but not of the Flutter view.
$origin = New-Object HaloClick+POINT
[void][HaloClick]::ClientToScreen($hwnd, [ref]$origin)

# Logical -> physical follows the window's DPI, not its width. Deriving it from
# "width / 1180" only worked while the window happened to be exactly 1180
# logical px wide; resizing the window silently shifted every click.
$scale = [HaloClick]::GetDpiForWindow($hwnd) / 96.0
$absX = $origin.X + [int]($X * $scale)
$absY = $origin.Y + [int]($Y * $scale)

[void][HaloClick]::SetCursorPos($absX, $absY)
Start-Sleep -Milliseconds 200
[HaloClick]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)  # left down
Start-Sleep -Milliseconds 80
[HaloClick]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)  # left up
Write-Host "clicked logical client ($X,$Y) -> screen ($absX,$absY) scale=$scale"
