#Requires -Version 7.0
param(
  [string]$Subject = 'CN=Clash Halo, O=Clash Halo Project'
)

# 把本项目的自签名代码签名证书装进「本地计算机」的受信任根与受信任发布者。
#
# 为什么需要这一步：这台机器会把未受信任的程序以**低完整性**（Low）启动。
# 实测（2026-11-03）：
#   * Explorer 启动微软签名的 notepad.exe -> Medium
#   * Explorer 启动本项目 exe 与用户自己的未签名 C# 程序 -> Low
# 低完整性进程被 Windows 禁止添加通知区域图标（Shell_NotifyIcon 返回
# “拒绝访问”），托盘图标因此不会出现，同时每次启动还会弹「打开文件 - 安全警告」。
#
# 只把证书放进**当前用户**的 Root/TrustedPublisher 不够：启动策略是在更早、
# 更高的层级决定完整性级别的，所以必须写进 LocalMachine。这一步需要管理员。
$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  throw '需要管理员权限：请打开“管理员”身份的 pwsh，再运行本脚本。'
}

$cert = Get-ChildItem Cert:\CurrentUser\My |
  Where-Object { $_.Subject -eq $Subject } |
  Select-Object -First 1
if (-not $cert) {
  throw "没有找到证书 $Subject。请先运行：pwsh -File scripts/sign-windows.ps1 -SelfSigned"
}

$cer = Join-Path ([System.IO.Path]::GetTempPath()) ("halo-codesign-" + $cert.Thumbprint + ".cer")
[System.IO.File]::WriteAllBytes($cer, $cert.Export(
  [System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))

try {
  foreach ($store in 'Root', 'TrustedPublisher') {
    $path = "Cert:\LocalMachine\$store"
    $existing = Get-ChildItem $path | Where-Object Thumbprint -eq $cert.Thumbprint
    if ($existing) {
      Write-Output "LocalMachine\$store : already trusted"
      continue
    }
    [void](Import-Certificate -FilePath $cer -CertStoreLocation $path)
    Write-Output "LocalMachine\$store : certificate added"
  }
} finally {
  Remove-Item $cer -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output '证书已加入本地计算机信任。请完全退出 Clash Halo（托盘菜单“退出”，或在任务管理器结束 halo-host.exe），'
Write-Output '然后重新启动 build\windows-x64\clash-halo.exe。'
Write-Output ''
Write-Output '判断是否生效：启动后查看 build\windows-x64\user-data\logs\host.log'
Write-Output '  * “托盘图标已创建”            -> 已生效'
Write-Output '  * “托盘图标未创建（integrity=Medium …）” -> 信任已生效但系统仍拒绝，需检查安全软件的沙箱设置'
Write-Output '  * “托盘图标未创建（integrity=Low …）”    -> 信任未生效，本脚本可能没有在管理员下运行'
