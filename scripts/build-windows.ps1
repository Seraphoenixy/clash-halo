#Requires -Version 7.0
param(
  [string]$OutDir = '',
  # Skip the C++/CMake step and rebuild only the Dart snapshot (data/app.so),
  # reusing the runner from the last full build. See the UI section below.
  [switch]$DartOnly,
  [switch]$Sign,
  [switch]$SelfSigned,
  [switch]$TrustSelfSigned,
  [string]$PfxPath = '',
  [string]$PfxPassword = '',
  [string]$Thumbprint = ''
)

# Assembles the runnable Windows application.
#
# Run it with PowerShell 7 (pwsh), not Windows PowerShell 5.1: 5.1 decodes a
# .ps1 without a BOM using the legacy ANSI code page, which turns these Chinese
# and the em-dashes into a parse error. `#Requires` above makes the mismatch an
# immediate, readable failure instead of a syntax error.
#
# Output goes to build\windows-x64, the directory README.txt documents and the
# one the app actually runs from. -OutDir overrides it for a staged release.
$ErrorActionPreference = 'Stop'
# Recorded so the post-deploy verification can tell "produced by this run" from
# "left over from an earlier build". Nothing else may depend on wall-clock time.
$buildStarted = Get-Date

$root = Split-Path $PSScriptRoot -Parent

# Resolve the project-local toolchain first, then PATH. CI installs Go/Flutter
# through actions and has no .tools directory, so requiring the local copy made
# both build-windows.ps1 and test.ps1 fail there.
function Resolve-Tool {
    param([string]$Local, [string]$Command)
    if ($Local -and (Test-Path -LiteralPath $Local)) {
        return (Resolve-Path -LiteralPath $Local).Path
    }
    $found = Get-Command $Command -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.Source }
    throw "找不到 $Command：把它放在 .tools 下，或加入 PATH。"
}
$go = Resolve-Tool (Join-Path $root '.tools\go\bin\go.exe') 'go'
$flutter = Resolve-Tool (Join-Path $root '.tools\flutter\bin\flutter.bat') 'flutter'
if ([string]::IsNullOrEmpty($OutDir)) { $OutDir = Join-Path $root 'build\windows-x64' }
New-Item -ItemType Directory -Force $OutDir | Out-Null
# Resolve now: the UI step runs from apps\flutter, and a relative -OutDir would
# otherwise be copied into apps\flutter\.tmp\... instead of the requested path.
$OutDir = (Resolve-Path $OutDir).Path

# Hash of the Dart snapshot *before* this run builds anything.
#
# The post-deploy check below wants to know whether the shipped app.so is older
# than the newest .dart file, because that would mean the AOT step reused an
# older kernel. Modification time alone cannot tell that apart from the honest
# case: a comment-only edit produces a byte-identical snapshot, Flutter correctly
# skips rewriting it, and the old mtime is then not a defect. Comparing the
# pre/post content answers the question directly — identical bytes mean identical
# behaviour, so no code can be missing.
$snapshotForCompare = Join-Path $root 'apps\flutter\build\windows\app.so'
$snapshotHashBefore = if (Test-Path $snapshotForCompare) {
    (Get-FileHash $snapshotForCompare).Hash
} else { '' }

# Both Go binaries are GUI-subsystem on purpose. halo-host.exe runs in the
# background behind the tray, and halo-tun-service.exe is started by the SCM:
# a console-subsystem service would flash a black window while installing.
# Redirected output still works, so diagnostics remain readable from a terminal.
Push-Location (Join-Path $root 'native\windows')
try {
    # Delete the targets first. A previous run (or a tool such as mt.exe) can
    # leave a PE at this exact path that `go build -o` does not actually replace:
    # observed on this toolchain, the timestamp moved but the bytes and size did
    # not, so an already-damaged binary survived every rebuild and kept failing
    # signing with "not a valid Win32 application". Starting from a clean path
    # makes the build reproducible.
    foreach ($name in 'halo-host.exe', 'halo-tun-service.exe') {
        $target = Join-Path $OutDir $name
        if (-not (Test-Path $target)) { continue }
        try {
            Remove-Item $target -Force -ErrorAction Stop
        } catch {
            throw "无法替换 $name：它正在运行。请先从托盘退出 Clash Halo（或结束 halo-host.exe），再重新构建。"
        }
    }
    & $go build -ldflags '-H=windowsgui' -o (Join-Path $OutDir 'halo-host.exe') ./cmd/halo-host
    if ($LASTEXITCODE) { throw 'Host build failed' }
    # halo-tun-service.exe is built later, after sing-box.exe is staged: its
    # approved-core pin has to be computed from the shipped bytes.
} finally { Pop-Location }

# NOTE: do not post-process these two exes with mt.exe to add an application
# manifest. Measured on this toolchain (SDK 10.0.26100): mt.exe exits 0 and the
# exe still runs, but the rewritten PE is rejected by the Authenticode signing
# API with "not a valid Win32 application", which silently costs the signature
# on exactly the two binaries that matter. A manifest has to enter through the
# linker as a .syso resource if it is ever needed; scripts/sign-windows.ps1
# reports the resulting state either way.

# --- UI (Dart) ---------------------------------------------------------------
# The Flutter Windows "runner" is a small C++ shell built by CMake; the interface
# itself lives in data/app.so, which `flutter assemble` produces with nothing but
# the Dart SDK. This project ships no native plugins, so the runner changes only
# when the C++ under apps\flutter\windows changes. When Visual Studio's C++ CMake
# component is absent, rebuild the Dart snapshot alone and reuse the runner from
# the last full build instead of failing the whole build on a toolchain the UI
# work does not touch. -DartOnly forces that path even when CMake is available.
$dartBin = Join-Path (Split-Path $flutter -Parent) 'dart.bat'
if (-not (Test-Path -LiteralPath $dartBin)) { $dartBin = Resolve-Tool '' 'dart' }
$flutterCache = Join-Path (Split-Path (Split-Path $flutter -Parent) -Parent) 'bin\cache'
$runnerExe = Join-Path $root 'apps\flutter\build\windows\x64\runner\Release\clash-halo.exe'

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$hasVsCmake = $false
if (Test-Path $vswhere) {
    $vsInstall = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.CMake.Project -property installationPath 2>$null
    $hasVsCmake = -not [string]::IsNullOrWhiteSpace($vsInstall)
}

$dartOnlyBuild = $DartOnly -or -not $hasVsCmake
if ($dartOnlyBuild) {
    Write-Warning '未检测到 Visual Studio 的「C++ CMake 工具」：只重建 Dart 快照（data/app.so）；外壳只在它自己的源码变化时用 cl/link 重建（scripts\build-runner.ps1）。'
}

# A moved or copied checkout leaves .dart_tool\package_config.json pointing at
# the old absolute path. `--no-pub` then hands the compiler a mirror of another
# tree, and every `package:flutter/...` import fails with misleading errors
# ("The method 'Text' isn't defined"). Repair the config before compiling.
$packageConfig = Join-Path $root '.dart_tool\package_config.json'
$rootSlash = $root.Replace('\', '/')
$staleConfig = (-not (Test-Path $packageConfig)) -or
    -not (Select-String -LiteralPath $packageConfig -SimpleMatch -Quiet -Pattern $rootSlash)
if ($staleConfig) {
    Write-Output 'Refreshing .dart_tool\package_config.json (workspace path changed)'
    & $dartBin pub get
    if ($LASTEXITCODE) { throw 'dart pub get failed' }
}

Push-Location (Join-Path $root 'apps\flutter')
try {
    # `flutter assemble` caches its asset step and the icon-font subset inside
    # build\flutter_assets. That cache is keyed on the asset files and the
    # tool's own sources -- NOT on the app's Dart code -- so a change that only
    # swaps which Icons.* a widget uses leaves the previous subset in place and
    # the new glyphs render as blank boxes. Deleting the cached tree forces
    # font-subset to run again. Measured 2026-11-05: an unchanged tree was
    # reused across three hours of Dart edits and shipped 9180 bytes with 4
    # in-use code points missing; after this deletion the same command produced
    # 9508 bytes with none missing.
    $cachedAssets = Join-Path $root 'apps\flutter\build\flutter_assets'
    if (Test-Path $cachedAssets) {
        Remove-Item $cachedAssets -Recurse -Force
    }

    if ($dartOnlyBuild) {
        # One argument per array element. A `-dTargetFile=lib/main.dart` token
        # continued across a backtick with a trailing space arrives at the tool
        # as `lib/main.dart `, and the frontend then reports the target as
        # missing. The array form has no such whitespace to get wrong.
        $assembleArgs = @(
            'assemble'
            '--no-version-check'
            '--output=build'
            '-dTargetPlatform=windows-x64'
            '-dTrackWidgetCreation=false'
            '-dBuildMode=release'
            '-dTargetFile=lib/main.dart'
            '-dTreeShakeIcons=true'
            '-dDartObfuscation=false'
            'release_bundle_windows-x64_assets'
        )
        & $flutter @assembleArgs
        if ($LASTEXITCODE) { throw 'Flutter assemble failed' }

        # `flutter assemble` stops at build\ (windows\app.so + flutter_assets).
        # A full build then has CMake install them into the runner's data\
        # directory; do that here or the staged app would keep the previous
        # snapshot while the build reports success.
        $dartBuild = Join-Path $root 'apps\flutter\build'
        $releaseDir = Split-Path $runnerExe -Parent
        $releaseData = Join-Path $releaseDir 'data'
        New-Item -ItemType Directory -Force $releaseData | Out-Null
        Copy-Item (Join-Path $dartBuild 'windows\app.so') (Join-Path $releaseData 'app.so') -Force
        $stagedAssets = Join-Path $releaseData 'flutter_assets'
        if (Test-Path $stagedAssets) { Remove-Item $stagedAssets -Recurse -Force }
        Copy-Item (Join-Path $dartBuild 'flutter_assets') $stagedAssets -Recurse -Force
        if (-not (Test-Path (Join-Path $releaseData 'icudtl.dat'))) {
            $icuData = Join-Path $flutterCache 'artifacts\engine\windows-x64\icudtl.dat'
            if (Test-Path $icuData) { Copy-Item $icuData (Join-Path $releaseData 'icudtl.dat') -Force }
            else { throw 'icudtl.dat 缺失且引擎缓存中没有副本，界面无法启动。' }
        }

        # The C++ shell is compiled by scripts\build-runner.ps1 (cl/link/rc),
        # not by CMake. It has to run after the assemble above: the engine headers
        # and the import library it compiles against are generated there.
        $windowsDir = Join-Path $root 'apps\flutter\windows'
        $needsRunner = -not (Test-Path $runnerExe)
        if (-not $needsRunner) {
            $newer = Get-ChildItem $windowsDir -Recurse -File |
                Where-Object {
                    $_.FullName -notlike '*\ephemeral\*' -and
                    $_.LastWriteTime -gt (Get-Item $runnerExe).LastWriteTime
                } | Select-Object -First 1
            $needsRunner = $null -ne $newer
        }
        if ($needsRunner) {
            Write-Output 'Windows 外壳需要重建：用 cl/link 编译，不需要 CMake'
            & (Join-Path $PSScriptRoot 'build-runner.ps1')
            if ($LASTEXITCODE) { throw 'runner 构建失败' }
        }
    } else {
        & $flutter build windows --release --no-pub
        if ($LASTEXITCODE) { throw 'Flutter build failed' }
    }
    # flutter_assets is regenerated wholesale, so drop the staged copy first:
    # a plain recursive copy merges and leaves behind assets for files that
    # have since been deleted.
    $stagedAssetsOut = Join-Path $OutDir 'data\flutter_assets'
    if (Test-Path $stagedAssetsOut) { Remove-Item $stagedAssetsOut -Recurse -Force }
    Copy-Item 'build\windows\x64\runner\Release\*' $OutDir -Recurse -Force

    # Two files the CMake install step used to produce and everything downstream
    # treats as mandatory (build-installer.ps1's precheck and the NSIS File
    # directives). On the cl/link path nothing creates them, and a machine that
    # never ran CMake has no leftovers either — so supply them here, for both
    # branches (no-op when the full build already put them in place).
    if (-not (Test-Path (Join-Path $OutDir 'flutter_windows.dll'))) {
        # clash-halo.exe links against the engine import library; without this
        # DLL next to it the staged app fails to load at all (0xc0000135).
        $engineDll = Join-Path $flutterCache 'artifacts\engine\windows-x64\flutter_windows.dll'
        if (-not (Test-Path $engineDll)) {
            throw "引擎缓存里没有 flutter_windows.dll（$engineDll）：界面外壳无法启动，先运行 flutter precache 或重装修 Flutter SDK。"
        }
        Copy-Item $engineDll (Join-Path $OutDir 'flutter_windows.dll') -Force
    }
    if (-not (Test-Path (Join-Path $OutDir 'native_assets.json'))) {
        # A legacy CMake run left an empty manifest here and the installer payload
        # still ships it. The live lookup path is data\flutter_assets\
        # NativeAssetsManifest.json (deployed with the assets above), so an empty
        # file is exactly what the old flow left behind — nothing more.
        New-Item -ItemType File (Join-Path $OutDir 'native_assets.json') | Out-Null
    }
} finally { Pop-Location }

$core = Join-Path $root 'prototype\bin\sing-box.exe'
if (!(Test-Path $core)) { throw 'Verified sing-box binary missing; no download is performed by this script' }
Copy-Item $core (Join-Path $OutDir 'sing-box.exe') -Force

# libcronet.dll ships in the same official archive and is required by the Naive
# outbound: without it sing-box refuses to start with "cronet: library not
# found" and every Naive node is unusable. It sits beside the core, which is
# where the loader looks first.
#
# Copy it before the service is installed, not only into the app directory: the
# TUN service stages its own approved core under Program Files and copies the
# companion files from here, so a build that omits it makes TUN install fail. A
# missing file is a build failure rather than a warning — the resulting packages
# would install fine and then break on the first TUN enable.
# fetch-singbox.ps1 stages both the core and this DLL into prototype\bin (its
# own contract: "the verified binaries the build and tests look for"); look
# there, not at the removed runtime\core extract.
$cronet = Join-Path $root (Join-Path 'prototype' (Join-Path 'bin' 'libcronet.dll'))
if (!(Test-Path $cronet)) {
    throw "libcronet.dll missing at $cronet; Naive nodes and the TUN service both need it"
}
Copy-Item $cronet (Join-Path $OutDir 'libcronet.dll') -Force
Write-Output 'Bundled libcronet.dll (Naive support)'

# The elevated service carries the approved core's SHA-256 in its own binary.
# The pin is what stops a replaced sing-box.exe in the app directory from being
# promoted to LocalSystem execution. It is stamped after the core is staged,
# because only then is the shipped byte sequence final.
$coreHash = (Get-FileHash (Join-Path $OutDir 'sing-box.exe') -Algorithm SHA256).Hash.ToLower()
Push-Location (Join-Path $root 'native\windows')
try {
    & $go build -ldflags "-X=clash-halo/native/windows/internal/tunservice.approvedCoreSHA256=$coreHash" -o (Join-Path $OutDir 'halo-tun-service.exe') ./cmd/halo-tun-service
    if ($LASTEXITCODE) { throw 'TUN service build failed' }
} finally { Pop-Location }
Write-Output "TUN service pinned to sing-box $($coreHash.Substring(0,12))"


# Clear the "downloaded from the internet" marker. A tree that arrived as a zip
# carries Zone.Identifier on every file, and copying preserves it; that marker is
# what makes SmartScreen show "Windows protected your PC" on every launch, even
# for a locally built binary. Harmless when no marker is present.
$cleared = 0
Get-ChildItem $OutDir -Recurse -File | ForEach-Object {
    if (Get-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue) {
        Unblock-File -LiteralPath $_.FullName
        $cleared++
    }
}
Write-Output "Cleared Mark-of-the-Web on $cleared file(s)"

# Verify the staged tree really contains this build. A build that prints
# "Staged" while shipping a stale data\app.so or a stale icon-font subset is
# exactly the failure this script exists to prevent, and it is invisible by eye:
# the old subset is a valid file that merely renders new icons as blank boxes.
$tolerance = [TimeSpan]::FromSeconds(5)

$fontPath = Join-Path $OutDir 'data\flutter_assets\fonts\MaterialIcons-Regular.otf'
if (-not (Test-Path $fontPath)) {
    throw "图标字体没有部署到 $fontPath：本次构建没有产出它。"
}

# The asset cache is deleted above, so font-subset must have run in this build.
# If the subset predates this run, that deletion silently stopped working and
# new Icons.* would be missing from the shipped font.
$fontTime = (Get-Item $fontPath).LastWriteTime
if ($fontTime -lt $buildStarted - $tolerance) {
    throw ("图标字体子集不是本次构建产出的，说明资源缓存又被复用了，新图标会显示为空白：`n" +
        "  字体   $($fontTime.ToString('yyyy-MM-dd HH:mm:ss'))`n" +
        "  构建于 $($buildStarted.ToString('yyyy-MM-dd HH:mm:ss'))")
}

# SQLite is a code asset in 3.x. A staging path that copies app.so and
# flutter_assets but drops NativeAssetsManifest.json builds fine and fails at
# the first database open, so require the mapping in the shipped tree.
$nativeAssets = Join-Path $OutDir 'data\flutter_assets\NativeAssetsManifest.json'
if (-not (Test-Path $nativeAssets)) {
    throw "NativeAssetsManifest.json 未部署到 $nativeAssets：SQLite 将无法加载。"
}
if (-not (Select-String -Path $nativeAssets -Pattern 'sqlite3' -SimpleMatch -Quiet)) {
    throw "NativeAssetsManifest.json 没有 sqlite3 映射：SQLite 将回退到不存在的下载库。"
}

# The staged snapshot must be byte-identical to the one just assembled, or
# app.so was replaced by something other than this build (a partially failed
# deploy leaves the old one in place while the Go binaries are already new).
$builtSnapshot = Join-Path $root 'apps\flutter\build\windows\app.so'
$stagedSnapshot = Join-Path $OutDir 'data\app.so'
foreach ($pair in @(@{ Built = $builtSnapshot; Staged = $stagedSnapshot; What = 'Flutter 快照' })) {
    if (-not (Test-Path $pair.Staged)) { throw "$($pair.What) 未部署到 $($pair.Staged)。" }
    if ((Test-Path $pair.Built) -and
        (Get-FileHash $pair.Built).Hash -ne (Get-FileHash $pair.Staged).Hash) {
        throw "$($pair.What) 与本次编译产物不一致：$($pair.Staged) 不是这次构建生成的。"
    }
}

# No Dart source may be newer than the shipped snapshot: that would mean the
# AOT step reused an older kernel and the UI silently lacks the latest code.
#
# Skipped when this build produced a byte-identical snapshot, which can only
# happen for a change that did not alter the compiled program — a comment, a
# rename of a local, whitespace. The old mtime is then correct, and failing the
# build over it would make every comment-only commit un-buildable.
$newestDart = Get-ChildItem -Path (Join-Path $root 'apps\flutter\lib'),
    (Join-Path $root 'packages') -Recurse -File -Filter *.dart -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
$snapshotHashAfter = if (Test-Path $snapshotForCompare) {
    (Get-FileHash $snapshotForCompare).Hash
} else { '' }
$snapshotRewritten = $snapshotHashAfter -ne $snapshotHashBefore
if ($newestDart -and
    (Get-Item $stagedSnapshot).LastWriteTime -lt $newestDart.LastWriteTime - $tolerance) {
    if ($snapshotRewritten) {
        throw ("Flutter 快照比 Dart 源码旧，界面不含最新改动：`n" +
            "  快照 $((Get-Item $stagedSnapshot).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))`n" +
            "  源码 $($newestDart.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))  $($newestDart.FullName)")
    }
    # Identical bytes: the newer .dart file did not change the compiled program.
    # Say so instead of passing silently, because a reader of this log is
    # entitled to know why an old timestamp was accepted.
    Write-Output ("注意：Flutter 快照未重写（本次编译产物与上次逐字节相同），" +
        "更新的 Dart 源码（$($newestDart.Name)）未改变编译结果，按一致处理。")
}

Write-Output ("资源校验通过：字体子集与 Flutter 快照均为本次构建产出" +
    $(if ($newestDart) { "，且不早于最新 Dart 源码（$($newestDart.Name)）" } else { '' }))


if ($Sign -or $SelfSigned -or $PfxPath -or $Thumbprint) {
    $signArgs = @{ BuildDir = $OutDir }
    if ($SelfSigned) { $signArgs.SelfSigned = $true }
    if ($TrustSelfSigned) { $signArgs.TrustSelfSigned = $true }
    if ($PfxPath) { $signArgs.PfxPath = $PfxPath; $signArgs.PfxPassword = $PfxPassword }
    if ($Thumbprint) { $signArgs.Thumbprint = $Thumbprint }
    & (Join-Path $PSScriptRoot 'sign-windows.ps1') @signArgs
}

# The application ships GPL-3.0-or-later; keep the license next to the binaries
# so a copied or installed directory is self-describing.
$license = Join-Path $root 'LICENSE'
if (-not (Test-Path -LiteralPath $license)) { throw "缺少 LICENSE 文件：$license" }
Copy-Item -LiteralPath $license -Destination (Join-Path $OutDir 'LICENSE') -Force

Write-Output "Staged Windows application: $OutDir"