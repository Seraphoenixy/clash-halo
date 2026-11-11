#Requires -Version 7.0
param(
  [string]$OutDir = '',
  [ValidateSet('release', 'profile', 'debug')]
  [string]$BuildMode = 'release'
)

# Builds the Android APK and collects it into build\android-arm64, the same
# level as build\windows-x64.
#
# Flutter and Gradle keep their own trees under apps\flutter\build; those stay
# intermediates. This script resolves the toolchain, runs the build, and copies
# the final APK plus its SHA-256 into the shared build\ directory.
#
# Run it with PowerShell 7 (pwsh), not Windows PowerShell 5.1: 5.1 decodes a
# .ps1 without a BOM using the legacy ANSI code page, which turns the Chinese
# text into a parse error. `#Requires` above makes the mismatch an immediate,
# readable failure instead of a syntax error.
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent

function Resolve-Tool {
    param([string]$Local, [string]$Command)
    if ($Local -and (Test-Path -LiteralPath $Local)) {
        return (Resolve-Path -LiteralPath $Local).Path
    }
    $found = Get-Command $Command -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.Source }
    throw "找不到 $Command：把它放在 .tools 下，或加入 PATH。"
}

$flutter = Resolve-Tool (Join-Path $root '.tools\flutter\bin\flutter.bat') 'flutter'

# JDK: project-local copy first. Leave JAVA_HOME untouched when the caller
# already set it or no local copy exists.
if ([string]::IsNullOrEmpty($env:JAVA_HOME)) {
    $jdkDir = Join-Path $root '.tools\jdk-17.0.21+9'
    if (-not (Test-Path -LiteralPath $jdkDir)) {
        $jdkDir = Get-ChildItem -LiteralPath (Join-Path $root '.tools') -Directory -Filter 'jdk-*' -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if ($jdkDir) { $env:JAVA_HOME = (Resolve-Path -LiteralPath $jdkDir).Path }
}

# Android SDK: project-local copy first. The Flutter Android build reads both
# variables, and older Gradle plugins only look at ANDROID_SDK_ROOT.
$sdk = Join-Path $root '.tools\android\sdk'
if (Test-Path -LiteralPath $sdk) {
    $env:ANDROID_HOME = (Resolve-Path -LiteralPath $sdk).Path
    $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
}

if ([string]::IsNullOrEmpty($OutDir)) { $OutDir = Join-Path $root 'build\android-arm64' }
New-Item -ItemType Directory -Force $OutDir | Out-Null
# Resolve now: the build runs from apps\flutter, and a relative -OutDir would
# otherwise land under apps\flutter instead of the requested path.
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

$project = Join-Path $root 'apps\flutter'
Push-Location -LiteralPath $project
try {
    Write-Output "flutter build apk --$BuildMode --target-platform android-arm64"
    & $flutter build apk "--$BuildMode" --target-platform android-arm64
    $buildExit = $LASTEXITCODE
}
finally {
    Pop-Location
}
if ($buildExit -ne 0) { throw "flutter build apk 失败（退出码 $buildExit）。" }

$apkName = "app-$BuildMode.apk"
$source = Join-Path $project "build\app\outputs\flutter-apk\$apkName"
if (-not (Test-Path -LiteralPath $source)) {
    throw "构建命令成功，但找不到 APK：$source"
}

$destination = Join-Path $OutDir $apkName
Copy-Item -LiteralPath $source -Destination $destination -Force
$hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $apkName" | Set-Content -LiteralPath "$destination.sha256" -Encoding ascii

$sizeMb = (Get-Item -LiteralPath $destination).Length / 1MB
Write-Output ''
Write-Output ("APK:     {0}" -f $destination)
Write-Output ("大小:    {0:N1} MB" -f $sizeMb)
Write-Output ("SHA-256: {0}" -f $hash)
