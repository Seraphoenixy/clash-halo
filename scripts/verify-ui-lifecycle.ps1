#Requires -Version 7.0
param(
  [string]$BuildDir = ''
)

# UI lifecycle check for the Windows build: repeated launches must reuse one
# window, and stopping the background host must leave no host process behind.
#
# Both halves are regressions that shipped once:
#   * the tray-mode host ran every shutdown step and then stayed in the systray
#     message loop forever, still holding host.lock;
#   * a host that lost the single-instance race opened *another* window, so the
#     UI and the host launched each other and the desktop gained a clash-halo.exe
#     about every two seconds.
#
# The check launches real windows, so run it on a desktop session, not in CI.
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrEmpty($BuildDir)) { $BuildDir = Join-Path $root 'build\windows-x64' }
$BuildDir = (Resolve-Path $BuildDir).Path
$dataDir = Join-Path $BuildDir 'user-data'
$uiExe = Join-Path $BuildDir 'clash-halo.exe'
$hostExe = Join-Path $BuildDir 'halo-host.exe'

# Run it with pwsh (PowerShell 7+). Windows PowerShell 5.1 decodes a .ps1 with no
# BOM using the legacy ANSI code page, which garbles the Chinese literals below
# into a parse error; the #Requires line turns that mismatch into an immediate,
# readable failure. The UTF-8 BOM is kept so every editor and tool reads the file
# correctly regardless of the shell that starts it.
$OutputEncoding = [System.Text.Encoding]::UTF8
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

foreach ($f in @($uiExe, $hostExe, (Join-Path $BuildDir 'sing-box.exe'))) {
  if (-not (Test-Path $f)) {
    throw "缺少 $f；请先执行 scripts/build-windows.ps1 组装运行目录"
  }
}

# Mirrors contract.PipeNameFor: filepath.Clean, backslashes to slashes, lower
# case, FNV-1a 64 as unpadded hex. BigInteger is deliberate: PowerShell would
# promote an overflowing uint64 multiplication to a double and silently produce
# a different hash.
function Get-PipeName([string]$Base) {
  $s = ($Base -replace '\\', '/') -replace '/+', '/'
  $s = $s.ToLowerInvariant().TrimEnd('/')
  if ([string]::IsNullOrEmpty($s)) { return 'clash-halo-host-v1' }
  $h = [System.Numerics.BigInteger]14695981039346656037
  $prime = [System.Numerics.BigInteger]1099511628211
  $mask = [System.Numerics.BigInteger]::Pow(2, 64) - 1
  foreach ($b in [System.Text.Encoding]::UTF8.GetBytes($s)) {
    $h = $h -bxor [System.Numerics.BigInteger]$b
    $h = ($h * $prime) -band $mask
  }
  $hex = $h.ToString('x').TrimStart('0')
  if ([string]::IsNullOrEmpty($hex)) { $hex = '0' }
  return 'clash-halo-host-v1-' + $hex
}

function Get-Mine([string]$Name) {
  # The leading comma matters: a function that returns an empty array emits
  # nothing at all, and `.Count` on nothing is itself nothing, so the caller
  # would compare an empty string against 1 and report a nonsense count.
  $items = @(Get-CimInstance Win32_Process |
    Where-Object { $_.Name -eq $Name -and $_.ExecutablePath -like "$BuildDir*" })
  return ,$items
}

function Invoke-Host([string]$action) {
  $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
  try {
    $pipe.Connect(5000)
    $writer = New-Object System.IO.StreamWriter($pipe)
    $writer.AutoFlush = $true
    $writer.WriteLine((@{ v = 1; id = 'lifecycle'; action = $action } | ConvertTo-Json -Compress))
    $reader = New-Object System.IO.StreamReader($pipe)
    # Events and the reply share one stream; the host broadcasts to every
    # client, so discriminate by frame shape instead of assuming line order.
    while ($true) {
      $line = $reader.ReadLine()
      if ($null -eq $line) { throw "管道在等待 $action 响应时被关闭" }
      if ($line -match '"event"\s*:') { continue }
      return $line
    }
  } finally {
    $pipe.Dispose()
  }
}

if ((Get-Mine 'clash-halo.exe').Count -gt 0 -or (Get-Mine 'halo-host.exe').Count -gt 0) {
  throw "$BuildDir 下已有进程在运行；请先结束它们再执行本检查"
}

$started = @()
$failed = $false
try {
  Write-Host "== 连续启动界面 3 次 =="
  for ($i = 1; $i -le 3; $i++) {
    $started += Start-Process -FilePath $uiExe -WorkingDirectory $BuildDir -PassThru
    Start-Sleep -Seconds 6
    $uiCount = (Get-Mine 'clash-halo.exe').Count
    $hostCount = (Get-Mine 'halo-host.exe').Count
    Write-Host ("launch {0}: clash-halo.exe={1} halo-host.exe={2}" -f $i, $uiCount, $hostCount)
    if ($uiCount -ne 1) { throw "第 $i 次启动后界面进程为 $uiCount 个，预期 1 个（重复启动应复用已有窗口）" }
    if ($hostCount -ne 1) { throw "第 $i 次启动后后台进程为 $hostCount 个，预期 1 个" }
  }

  Write-Host "== 静置 15 秒，确认没有自我增殖 =="
  Start-Sleep -Seconds 15
  $uiCount = (Get-Mine 'clash-halo.exe').Count
  $hostCount = (Get-Mine 'halo-host.exe').Count
  Write-Host "idle: clash-halo.exe=$uiCount halo-host.exe=$hostCount"
  if ($uiCount -ne 1 -or $hostCount -ne 1) { throw "静置后进程数变化：界面 $uiCount、后台 $hostCount（进程增殖回归）" }

  Write-Host "== 请求后台退出，确认宿主进程消失 =="
  $pipeName = Get-PipeName $dataDir
  $reply = Invoke-Host 'host.shutdown'
  Write-Host $reply
  if (($reply | ConvertFrom-Json).ok -ne $true) { throw "host.shutdown 未被确认：$reply" }

  $deadline = (Get-Date).AddSeconds(20)
  while ((Get-Mine 'halo-host.exe').Count -gt 0 -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
  }
  $hostCount = (Get-Mine 'halo-host.exe').Count
  $uiCount = (Get-Mine 'clash-halo.exe').Count
  Write-Host "after shutdown: clash-halo.exe=$uiCount halo-host.exe=$hostCount"
  if ($hostCount -ne 0) { throw "后台进程在 host.shutdown 后仍然存在（残留进程会一直占着 host.lock）" }
  if ($uiCount -ne 1) { throw "关闭后台不应影响界面：界面进程为 $uiCount 个，预期 1 个" }

  Write-Host "界面生命周期检查通过：重复启动不增殖，关闭后台不残留。"
} catch {
  $failed = $true
  Write-Host "界面生命周期检查失败：$($_.Exception.Message)" -ForegroundColor Red
} finally {
  # Only processes started from this build directory are touched, so a real
  # installation the user is running is never killed by this script.
  foreach ($p in (Get-Mine 'clash-halo.exe')) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
  }
  foreach ($p in (Get-Mine 'halo-host.exe')) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
  }
  foreach ($p in (Get-Mine 'sing-box.exe')) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
  }
}

if ($failed) { exit 1 }