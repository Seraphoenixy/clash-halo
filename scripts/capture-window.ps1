# Captures the Clash Halo window to a PNG so the layout can be inspected.
#
# Uses PrintWindow with PW_RENDERFULLCONTENT, which is what is needed for GPU
# composited windows such as Flutter's: a BitBlt of the screen region returns a
# black rectangle for them, and PrintWindow without that flag returns white.
#Requires -Version 7.0
param(
    [string]$Out = (Join-Path (Split-Path $PSScriptRoot -Parent) 'docs\images\ui-capture.png'),
    [string]$ProcessName = 'clash-halo'
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WinCapture {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

# Window APIs answer in the *caller's* DPI awareness. From an unaware process a
# 1180x760 window at 150% reports 1180x760 while it really renders at 1770x1140,
# so PrintWindow fills only the bitmap's top-left corner and every screenshot
# looks cut off on the right. Forcing per-monitor v2 makes the rect and the
# render agree. Fails harmlessly when the manifest already set an awareness.
[void][WinCapture]::SetProcessDpiAwarenessContext([IntPtr](-4))

$proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 } |
    Select-Object -First 1
if (-not $proc) { throw "找不到 $ProcessName 的窗口" }

$hwnd = $proc.MainWindowHandle
[void][WinCapture]::SetForegroundWindow($hwnd)
Start-Sleep -Milliseconds 600

$rect = New-Object WinCapture+RECT
if (-not [WinCapture]::GetWindowRect($hwnd, [ref]$rect)) { throw 'GetWindowRect 失败' }
$width = $rect.Right - $rect.Left
$height = $rect.Bottom - $rect.Top
if ($width -le 0 -or $height -le 0) { throw "窗口尺寸异常: ${width}x${height}" }

$bmp = New-Object System.Drawing.Bitmap($width, $height)
$graphics = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $graphics.GetHdc()
# 0x2 = PW_RENDERFULLCONTENT
$ok = [WinCapture]::PrintWindow($hwnd, $hdc, 2)
$graphics.ReleaseHdc($hdc)
$graphics.Dispose()

if (-not $ok) {
    $bmp.Dispose()
    throw 'PrintWindow 失败'
}

$dir = Split-Path -Parent $Out
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host "已保存 $Out (${width}x${height})"
