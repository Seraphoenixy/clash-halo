# Captures the whole screen, for surfaces that are not one of our windows:
# the tray menu is an owned popup and PrintWindow on the main window cannot
# include it.
#Requires -Version 7.0
param([string]$Out = '')

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

if ([string]::IsNullOrEmpty($Out)) {
    $Out = Join-Path (Split-Path $PSScriptRoot -Parent) '.tmp\screen.png'
}
New-Item -ItemType Directory -Force (Split-Path $Out -Parent) | Out-Null

$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
$g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host "saved $Out ($($bounds.Width)x$($bounds.Height))"
