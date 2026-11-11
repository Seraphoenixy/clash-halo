#Requires -Version 7.0
param(
  # 运行目录（build-windows.ps1 的产物）。默认 build\windows-x64。
  [string]$BuildDir = '',
  # 安装包输出到哪个目录。默认 build\release。
  [string]$OutDir = '',
  # 安装包文件名，默认 clash-halo-<版本>-setup.exe。只有需要固定名字时才传。
  [string]$FileName = '',
  # 版本号，覆盖 pubspec.yaml 里的。默认读 apps/flutter/pubspec.yaml 的 version。
  [string]$Version = '',
  # 跳过 scripts/build-windows.ps1。只有在确认运行目录已经是本次产物时才用。
  [switch]$SkipBuild,
  # 连运行目录一起重新构建（等价于不传 -SkipBuild，保留此开关是为了让调用处显式表达意图）。
  [switch]$Build,
  # NSIS 编译器所在目录或 makensis.exe 的完整路径。默认自动查找，找不到就下载到 .tools。
  [string]$Makensis = '',
  # 不自动下载 NSIS；缺少时直接失败。
  [switch]$NoDownload,
  # 给安装包签名（参数与 build-windows.ps1 一致）。
  [switch]$Sign,
  [switch]$SelfSigned,
  [switch]$TrustSelfSigned,
  [string]$PfxPath = '',
  [string]$PfxPassword = '',
  [string]$Thumbprint = ''
)

# 打 Windows 安装包。
#
# 为什么用 NSIS 而不是 Inno Setup 或 MSIX：
#
#   * Inno Setup 没有 portable 的编译器包：它的安装程序不能静默解压出 ISCC，
#     所以「构建机什么都没有」时会卡在一个必须点完向导的安装程序上。NSIS 官方
#     发布 nsis-<版本>.zip，解压即用。
#   * MSIX 必须签名，而且自签名包要用管理员权限导入证书才能安装。
#   * NSIS 生成的安装包可以用 7-Zip 打开：产物能被独立检查，不必先运行它。
#
# 运行目录（$BuildDir）必须是 scripts/build-windows.ps1 的输出，本脚本不负责
# 编译应用，只负责打包、验证与签名。
#
# 用 pwsh（PowerShell 7+）运行：本文件是不带 BOM 的 UTF-8，5.1 会按本地 ANSI
# 代码页解码，中文与破折号直接变成语法错误。下面的 #Requires 把这种版本不匹配
# 变成一句可读的失败提示。

$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$script = Join-Path $root 'installer\clash-halo.nsi'
if ([string]::IsNullOrEmpty($BuildDir)) { $BuildDir = Join-Path $root 'build\windows-x64' }
if ([string]::IsNullOrEmpty($OutDir)) { $OutDir = Join-Path $root 'build\release' }

if (-not (Test-Path $script)) { throw "找不到安装脚本：$script" }

# --- 版本号 ----------------------------------------------------------------
# 版本只有一个来源：apps/flutter/pubspec.yaml 的 version（`0.1.0+1`）。宿主与
# 外壳的版本资源也来自那里，两边不一致时「关于」面板与安装包的属性会各说一套。
if ([string]::IsNullOrEmpty($Version)) {
  $pubspec = Join-Path $root 'apps\flutter\pubspec.yaml'
  $line = Get-Content $pubspec | Where-Object { $_ -match '^version:\s*' } | Select-Object -First 1
  if (-not $line) { throw "apps\flutter\pubspec.yaml 里没有 version 行" }
  $Version = ($line -replace '^version:\s*', '').Trim()
}
if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$') {
  throw "版本号无法解析：$Version（期望 x.y.z 或 x.y.z+build）"
}
$major, $minor, $patch = $Matches[1], $Matches[2], $Matches[3]
$buildNumber = if ($Matches[4]) { $Matches[4] } else { '0' }
# Two different versions, and conflating them is what put "0.1.0+1" in front of
# users:
#
#   * $displayVersion is what a person reads — the installer's title bar, the
#     Programs-and-Features row, the progress log. pubspec's `0.1.0+1` means
#     "version 0.1.0, build 1"; the "+1" is a counter for the app store, not part
#     of the version a user quotes. It stays three components.
#   * $fileVersion is the PE version resource, which Windows requires to be four
#     16-bit integers. The build number is the only honest place for "+1" to go,
#     so it becomes the fourth component rather than being dropped.
$displayVersion = "$major.$minor.$patch"
$fileVersion = "$major.$minor.$patch.$buildNumber"
foreach ($part in @($major, $minor, $patch, $buildNumber)) {
  if ([int]$part -gt 65535) { throw "版本号 $Version 的某一段超过 65535，文件属性写不进去" }
}

# --- 运行目录检查 ----------------------------------------------------------
if (-not $SkipBuild) {
  Write-Output '重新构建运行目录（scripts\build-windows.ps1）…'
  $buildArgs = @{ OutDir = $BuildDir }
  & (Join-Path $PSScriptRoot 'build-windows.ps1') @buildArgs
  if ($LASTEXITCODE) { throw "构建运行目录失败（退出码 $LASTEXITCODE）" }
} elseif (-not (Test-Path $BuildDir)) {
  throw "运行目录不存在：$BuildDir。去掉 -SkipBuild，或先运行 scripts\build-windows.ps1。"
}
$BuildDir = (Resolve-Path $BuildDir).Path

# 必装文件清单。少一个就说明运行目录不是完整构建的结果，这时打出来的包装上之后
# 会以各种间接方式失败（内核启动不了、界面空白、托盘点了没反应），所以在这里拦住。
$payload = [ordered]@{
  'clash-halo.exe'      = '界面入口'
  'halo-host.exe'       = '后台宿主'
  'halo-tun-service.exe' = 'TUN 服务（首次启用时安装）'
  'sing-box.exe'         = '代理内核'
  'flutter_windows.dll' = 'Flutter 运行时'
  'libcronet.dll'       = 'Naive 支持'
  'native_assets.json'  = 'Flutter 原生资源清单'
  'data\app.so'         = '界面快照'
  'data\icudtl.dat'     = 'ICU 数据'
  'data\flutter_assets\fonts\MaterialIcons-Regular.otf' = '图标字体'
  'LICENSE'                                             = 'GPL-3.0-or-later 许可证'
}
$missing = @()
foreach ($rel in $payload.Keys) {
  if (-not (Test-Path (Join-Path $BuildDir $rel))) { $missing += $rel }
}
if ($missing.Count -gt 0) {
  throw ("运行目录缺少必要文件，安装包会以间接方式坏掉：`n  " +
    ($missing -join "`n  ") + "`n先运行 scripts\build-windows.ps1 产出完整运行目录。")
}
if (-not (Test-Path (Join-Path $BuildDir 'halo-cli.exe'))) {
  # 只有命令行工具可缺：它不影响界面与代理，安装包里也有对应的 /nonfatal。
  Write-Warning '运行目录里没有 halo-cli.exe：安装包不含命令行工具（不影响界面与代理）。'
}

# --- NSIS 编译器 -----------------------------------------------------------
# 查找顺序：显式传入 → PATH → .tools\nsis → 已安装的 NSIS → 下载到 .tools。
$nsisVersion = '3.12'
$nsisSha256 = '56581f90db321581c5381193d796fffcf2d24b2f8fed2160a6c6a3baa67f2c4f'
$nsisUrl = "https://downloads.sourceforge.net/project/nsis/NSIS%203/$nsisVersion/nsis-$nsisVersion.zip"
$toolsNsis = Join-Path $root ".tools\nsis\nsis-$nsisVersion"

function Resolve-Makensis([string]$hint) {
  if (-not [string]::IsNullOrEmpty($hint)) {
    if (Test-Path $hint -PathType Leaf) { return (Resolve-Path $hint).Path }
    $candidate = Join-Path $hint 'makensis.exe'
    if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
    $candidate = Join-Path $hint 'Bin\makensis.exe'
    if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
    throw "-Makensis 指向的位置里没有 makensis.exe：$hint"
  }
  $onPath = Get-Command makensis.exe -ErrorAction SilentlyContinue
  if ($onPath) { return $onPath.Source }
  foreach ($candidate in @(
      (Join-Path $toolsNsis 'makensis.exe'),
      (Join-Path $toolsNsis 'Bin\makensis.exe'),
      (Join-Path ${env:ProgramFiles(x86)} 'NSIS\makensis.exe'),
      (Join-Path $env:ProgramFiles 'NSIS\makensis.exe')
    )) {
    if ($candidate -and (Test-Path $candidate)) { return $candidate }
  }
  return $null
}

function Install-Nsis {
  if ($NoDownload) {
    throw ("找不到 makensis.exe，且传了 -NoDownload。安装 NSIS $nsisVersion 后重试，" +
      "或用 -Makensis 指定其目录。")
  }
  $cache = Join-Path $root ".tools\nsis"
  $zip = Join-Path $cache "nsis-$nsisVersion.zip"
  New-Item -ItemType Directory -Force $cache | Out-Null

  if (-not (Test-Path $zip)) {
    # Write-Host, not Write-Output: anything written to the pipeline becomes part
    # of this function's return value, and the caller would receive
    # "message + path" as an array instead of the path.
    Write-Host "下载 NSIS $nsisVersion（约 2.3 MB）…"
    # curl.exe 在 Windows 10 及以后是系统自带的；Invoke-WebRequest 在本机走代理时
    # 常常卡在 TLS 阶段，而构建脚本不该因为网络细节挂住。
    & curl.exe -fsSL --retry 2 --connect-timeout 20 --max-time 300 -o $zip $nsisUrl
    if ($LASTEXITCODE) {
      Remove-Item $zip -Force -ErrorAction SilentlyContinue
      throw "下载 NSIS 失败（curl 退出码 $LASTEXITCODE）：$nsisUrl"
    }
  }

  # 固定校验值。这不是安全边界（同一台机器上下载的东西），而是版本固定：一个
  # 换了内容的 zip 会让「同一份源码打出同一份安装包」这件事不成立。
  $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $nsisSha256) {
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    throw ("NSIS 压缩包的 SHA-256 与脚本记录的不一致：`n" +
      "  期望 $nsisSha256`n  实际 $actual`n" +
      "如果确实要升级 NSIS，更新本脚本里的版本号与校验值。")
  }

  Write-Host "解压 NSIS 到 $cache …"
  if (Test-Path $toolsNsis) { Remove-Item $toolsNsis -Recurse -Force }
  Expand-Archive -LiteralPath $zip -DestinationPath $cache -Force
  $resolved = Resolve-Makensis ''
  if (-not $resolved) { throw "解压 NSIS $nsisVersion 之后仍找不到 makensis.exe：$cache" }
  return $resolved
}

$makensisPath = Resolve-Makensis $Makensis
if (-not $makensisPath) {
  $makensisPath = Install-Nsis
}
$nsisDir = Split-Path $makensisPath -Parent
Write-Output "NSIS：$makensisPath"
# 版本过低会缺 MUI2 的现代界面资源；3.0 之前的输出还有编码问题。
$nsisVersionLine = (& $makensisPath -VERSION 2>&1 | Out-String).Trim()
if ($nsisVersionLine -notmatch '^v?(\d+)\.(\d+)') {
  throw "无法识别 makensis 版本：$nsisVersionLine"
}
if ([int]$Matches[1] -lt 3) {
  throw "需要 NSIS 3 或更高版本，当前为 $nsisVersionLine"
}
Write-Output "makensis 版本：$nsisVersionLine"

# --- 图标 ------------------------------------------------------------------
# The one .ico the app already uses: the runner embeds it into clash-halo.exe, so
# the installer and the uninstaller must show the same picture the taskbar and
# the Start menu show. With MUI_ICON unset NSIS falls back to its own blue globe,
# and that is exactly what shipped once.
$iconPath = Join-Path $root 'apps\flutter\windows\runner\resources\app_icon.ico'
if (-not (Test-Path $iconPath)) {
  throw ('找不到安装包图标：' + $iconPath +
    '。它属于 Flutter 外壳资源；缺了它安装包会退回 NSIS 的默认图标，与应用窗口的图标不一致。')
}
$iconPath = (Resolve-Path $iconPath).Path

# --- 输出路径 --------------------------------------------------------------
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force $OutDir | Out-Null
if ([string]::IsNullOrEmpty($FileName)) {
  # 文件名带版本，是为了让并存的几个安装包在目录里一眼分得清；不带空格，是为了
  # 让命令行与 URL 不必转义。
  $FileName = "clash-halo-$displayVersion-setup.exe"
}
$outFile = [System.IO.Path]::GetFullPath((Join-Path $OutDir $FileName))
if (Test-Path $outFile) { Remove-Item $outFile -Force }

# --- 编译 ------------------------------------------------------------------
# -INPUTCHARSET UTF8：脚本无 BOM 且含中文，缺了它 makensis 按本地 ANSI 代码页
# 解码，报的是 "Bad text encoding"，看起来像语法错误。
#
# 路径里可能有空格（安装目录默认就在 %LOCALAPPDATA%\Programs 下），所以全部用
# /D 前缀的引号形式传参。
$makensisArgs = @(
  '-INPUTCHARSET'
  'UTF8'
  '/V2'
  "/DPAYLOAD=$BuildDir"
  "/DOUT_FILE=$outFile"
  "/DAPP_VERSION=$displayVersion"
  "/DAPP_FILE_VERSION=$fileVersion"
  "/DAPP_ICON=$iconPath"
  $script
)
Write-Output "编译安装包：$outFile"
Push-Location $nsisDir
try {
  # makensis 会把 /D 之后的内容当成一个参数，PowerShell 数组形式传参即可；用
  # 反引号拼命令字符串会让带空格的路径在各处表现不同。
  & $makensisPath @makensisArgs
  $code = $LASTEXITCODE
} finally {
  Pop-Location
}
if ($code) { throw "makensis 失败（退出码 $code）" }
if (-not (Test-Path $outFile)) { throw "makensis 报告成功但没有生成 $outFile" }

# --- 产物验证 --------------------------------------------------------------
# 「构建成功」不等于「安装包里有东西」。这里独立地把安装包当压缩包读一遍，确认
# 载荷真的进去了、版本属性对得上，而不是只看 makensis 的退出码。
$sevenZip = $null
foreach ($candidate in @(
    (Join-Path $env:ProgramFiles '7-Zip\7z.exe'),
    (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe')
  )) {
  if ($candidate -and (Test-Path $candidate)) { $sevenZip = $candidate; break }
}
if (-not $sevenZip) {
  $sevenZip = (Get-Command 7z.exe -ErrorAction SilentlyContinue)?.Source
}

$size = (Get-Item $outFile).Length
$sha = (Get-FileHash $outFile -Algorithm SHA256).Hash.ToLowerInvariant()

if ($sevenZip) {
  $listing = & $sevenZip l $outFile 2>&1 | Out-String
  if ($LASTEXITCODE) { throw "7z 无法读取生成的安装包：$outFile`n$listing" }
  if ($listing -notmatch 'NSIS') {
    throw "生成的安装包不是 NSIS 格式，产物可能已损坏：$outFile"
  }
  $expected = @('clash-halo.exe', 'halo-host.exe', 'halo-tun-service.exe', 'sing-box.exe', 'libcronet.dll', 'flutter_windows.dll', 'app.so')
  $absent = @($expected | Where-Object { $listing -notmatch [regex]::Escape($_) })
  if ($absent.Count -gt 0) {
    throw "安装包里缺少预期的文件（7z 列表里找不到）：$($absent -join '、')"
  }
  Write-Output "7z 校验通过：载荷文件齐全（$(($expected -join ', '))）"
} else {
  Write-Warning '没有找到 7-Zip，跳过安装包内容校验。'
}

# 版本属性来自 VIProductVersion：装完之后资源管理器与卸载列表都读它。
#
# Checked, not assumed. "0.1.0+1" reached users because the four-part file version
# and the version a person reads were the same variable; a build that reinvents
# that mistake must fail here rather than ship.
if (-not (Test-Path $outFile)) { throw "安装包在签名前消失了：$outFile" }
# Two different fields, and picking the wrong one hides the bug:
#   * FileVersion / ProductVersion are the *strings* from the version resource —
#     the ones a person reads. They must be the three-part display version.
#   * FileVersionRaw / ProductVersionRaw are the four-part numeric form Windows
#     stores alongside them; that is where the pubspec build number belongs.
$info = (Get-Item $outFile).VersionInfo
if ($info.FileVersionRaw -ne $fileVersion) {
  throw ("安装包的数值版本是 $($info.FileVersionRaw)，期望 $fileVersion。" +
    'VIProductVersion 没有生效。')
}
foreach ($field in 'FileVersion', 'ProductVersion') {
  $shown = $info.$field
  if ($shown -ne $displayVersion) {
    throw ("安装包的 $field 显示为 $shown，期望 $displayVersion。" +
      '带 +build 号的 pubspec 版本不得进入用户可见的版本号。')
  }
}
Write-Output "版本属性校验通过：显示 $displayVersion，数值 $fileVersion"

if ($Sign -or $SelfSigned -or $PfxPath -or $Thumbprint) {
  $signArgs = @{ FilePath = $outFile }
  if ($SelfSigned) { $signArgs.SelfSigned = $true }
  if ($TrustSelfSigned) { $signArgs.TrustSelfSigned = $true }
  if ($PfxPath) { $signArgs.PfxPath = $PfxPath; $signArgs.PfxPassword = $PfxPassword }
  if ($Thumbprint) { $signArgs.Thumbprint = $Thumbprint }
  & (Join-Path $PSScriptRoot 'sign-windows.ps1') @signArgs
  if ($LASTEXITCODE) { throw "给安装包签名失败（退出码 $LASTEXITCODE）" }
  $sha = (Get-FileHash $outFile -Algorithm SHA256).Hash.ToLowerInvariant()
  $size = (Get-Item $outFile).Length
}

Write-Output ''
Write-Output "安装包：$outFile"
Write-Output ("大小：{0:N1} MB（{1} 字节）" -f ($size / 1MB), $size)
Write-Output "版本：$displayVersion（文件属性 $fileVersion）"
Write-Output "SHA-256：$sha"
Write-Output ''
Write-Output '静默安装（当前用户）：'
Write-Output "  `"$outFile`" /S"
Write-Output '静默卸载：'
Write-Output "  `"$(Join-Path $env:LOCALAPPDATA 'Programs\Clash Halo\uninstall.exe')`" /S"
