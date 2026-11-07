#Requires -Version 7.0
param(
  [string]$Path = ''
)

# 把目录树上残留的 Low 强制性完整性标签改回 Medium。
#
# 背景（2026-11-03 实测）：本仓库目录下的可执行文件带着
#   Mandatory Label\Low Mandatory Level:(I)(NW)
# 并且 ACL 里有沙箱令牌的 SID `S-1-4-…`。Windows 会以 Low 完整性启动带该标签的
# 程序，而 Low 完整性进程被禁止调用 Shell_NotifyIcon —— 于是托盘图标创建失败：
#   [host] 托盘图标未创建（integrity=Low …）
# 同一份文件复制到没有该标签的目录（如 D:\software）就是 Medium，图标正常。
#
# 为什么需要管理员：修改对象的完整性标签要对 SACL 有写权限；这些文件由一个
# 外部 SID 拥有，普通用户会得到“拒绝访问”，只有启用 SeSecurityPrivilege 才行。
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($Path)) {
    $Path = Split-Path $PSScriptRoot -Parent
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  throw '需要管理员权限：请以管理员身份打开 pwsh，再运行本脚本。'
}
if (-not (Test-Path $Path)) {
  throw "目录不存在：$Path"
}

Write-Output "目标目录：$Path"
Write-Output '把目录及全部子项的完整性标签设为 Medium（会同时传播给新建文件）…'

# /T 递归、/C 遇到无权对象继续、/Q 精简输出。
& icacls.exe $Path /setintegritylevel '(OI)(CI)M' /T /C /Q
$code = $LASTEXITCODE

Write-Output ''
Write-Output '抽查：'
foreach ($rel in @('build\windows-x64\clash-halo.exe',
                   'build\windows-x64\halo-host.exe')) {
  $file = Join-Path $Path $rel
  if (-not (Test-Path $file)) { continue }
  $line = (& icacls.exe $file | Select-String -Pattern 'Mandatory' -SimpleMatch)
  $text = if ($line) { $line.ToString().Trim() } else { '<no label>' }
  Write-Output ("  {0,-40} {1}" -f $rel, $text)
}

Write-Output ''
if ($code -ne 0) {
  Write-Output "icacls 返回 $code：部分对象仍未处理（通常是所有者不是本机用户）。"
  Write-Output '可以先用管理员权限取得所有权再重跑：'
  Write-Output "  takeown /f `"$Path`" /r /d y"
  Write-Output "  icacls `"$Path`" /setintegritylevel (OI)(CI)M /T /C"
} else {
  Write-Output '完成。请重新构建或直接启动应用，然后确认日志中出现「托盘图标已创建」。'
}
