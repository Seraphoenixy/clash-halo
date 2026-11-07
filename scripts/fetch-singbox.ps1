#Requires -Version 7.0
param(
  # Where the core is staged. Both directories are gitignored:
  #   prototype/bin        the verified binaries the build and tests look for
  #   prototype/runtime    the download cache
  [string]$BinDir = '',
  [string]$CacheDir = '',
  # Skips the download and only verifies what is already in place.
  [switch]$VerifyOnly
)

# Fetches the locked sing-box build the product ships.
#
# Why this exists: `sing-box.exe` is 79 MB of third-party binary, `prototype/bin`
# and `prototype/runtime` are gitignored, so a fresh clone has no core at all.
# `scripts/build-windows.ps1` refuses to build without it ("Verified sing-box
# binary missing; no download is performed by this script") — deliberately, so a
# local build never silently picks up a different core. CI is the other case: it
# must start from an empty checkout and end with the exact same bytes everyone
# else builds against, so the version and the digest live here and are checked.
#
# The digest is not decoration. This binary is shipped inside the installer and
# is executed by the elevated TUN service; a release whose core came from
# somewhere else is a different product.

$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrEmpty($BinDir)) { $BinDir = Join-Path $root 'prototype\bin' }
if ([string]::IsNullOrEmpty($CacheDir)) { $CacheDir = Join-Path $root 'prototype\runtime' }

# Must match the release the application was validated against. Changing it means
# re-running the whole verification record in docs/验证记录.md, not just a rebuild.
$version = '1.14.4'
$zipSha256 = '99185d75d314a07dbba4a130c8ad986cbeb629a07927975636b341ca61f991df'
$url = "https://github.com/SagerNet/sing-box/releases/download/v$version/sing-box-$version-windows-amd64.zip"

New-Item -ItemType Directory -Force $BinDir, $CacheDir | Out-Null
$zip = Join-Path $CacheDir "sing-box-$version-windows-amd64.zip"

function Get-Sha256([string]$path) {
  (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-CachedZip {
  if (-not (Test-Path $zip)) { return $false }
  $actual = Get-Sha256 $zip
  if ($actual -eq $zipSha256) { return $true }
  # A truncated or replaced download must not be reused: delete it so the next
  # run fetches again instead of failing the same way forever.
  Write-Warning "缓存的内核压缩包校验失败（$actual），重新下载。"
  Remove-Item $zip -Force -ErrorAction SilentlyContinue
  return $false
}

# Already staged and matching: nothing to do. This is the path a developer's
# machine takes, and it is why this script is safe to call before every build.
$stagedExe = Join-Path $BinDir 'sing-box.exe'
$stagedDll = Join-Path $BinDir 'libcronet.dll'
if ((Test-Path $stagedExe) -and (Test-Path $stagedDll)) {
  $reported = (& $stagedExe version 2>&1 | Out-String)
  if ($reported -match "sing-box version $([regex]::Escape($version))\b") {
    Write-Output "内核已就位：sing-box $version（$stagedExe）"
    exit 0
  }
  # A different version next to the build is exactly the situation the digest and
  # this check exist to prevent: the app would report one version while shipping
  # another.
  Write-Warning "已存在的内核不是 $version，重新获取：$($reported.Trim())"
}

if ($VerifyOnly) {
  throw "内核 $version 未就位，且传了 -VerifyOnly。"
}

if (-not (Test-CachedZip)) {
  Write-Output "下载 sing-box $version…"
  # curl.exe ships with Windows 10 and later. Invoke-WebRequest goes through the
  # machine's proxy settings, which on a runner is fine but locally has hung on
  # this project before; curl keeps the behaviour predictable in both places.
  & curl.exe -fsSL --retry 3 --retry-delay 2 --connect-timeout 30 --max-time 900 -o $zip $url
  if ($LASTEXITCODE) {
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    throw "下载内核失败（curl 退出码 $LASTEXITCODE）：$url"
  }
  $actual = Get-Sha256 $zip
  if ($actual -ne $zipSha256) {
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    throw ("内核压缩包的 SHA-256 与脚本记录的不一致：`n" +
      "  期望 $zipSha256`n  实际 $actual`n" +
      '如果确实要升级内核，同步更新本脚本的版本号与校验值，并重跑验证记录。')
  }
}

# Expand into a scratch directory first. Extracting straight over prototype\bin
# would leave a half-written sing-box.exe if it fails midway, and the build would
# then package a corrupted core with a valid-looking timestamp.
$scratch = Join-Path $CacheDir '_extract'
if (Test-Path $scratch) { Remove-Item $scratch -Recurse -Force }
New-Item -ItemType Directory -Force $scratch | Out-Null
try {
  Expand-Archive -LiteralPath $zip -DestinationPath $scratch -Force
  $inner = Join-Path $scratch "sing-box-$version-windows-amd64"
  foreach ($name in 'sing-box.exe', 'libcronet.dll') {
    $source = Join-Path $inner $name
    if (-not (Test-Path $source)) { throw "官方压缩包里没有 $name（$zip）" }
    Copy-Item $source (Join-Path $BinDir $name) -Force
  }
  # Non-fatal: the build warns and Naive nodes fail, which is a real limitation
  # but not a reason to lose the whole core.
  $license = Join-Path $inner 'LICENSE'
  if (Test-Path $license) { Copy-Item $license (Join-Path $BinDir 'sing-box-LICENSE') -Force }
} finally {
  Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

# Prove the staged binary is usable rather than merely present: the host runs
# `sing-box version` at startup and refuses a file that does not answer with
# "sing-box version".
$reported = (& $stagedExe version 2>&1 | Out-String)
if ($reported -notmatch "sing-box version $([regex]::Escape($version))\b") {
  throw "刚部署的内核没有报告版本 $version：$($reported.Trim())"
}
Write-Output "内核已部署并校验：sing-box $version（$stagedExe）"
