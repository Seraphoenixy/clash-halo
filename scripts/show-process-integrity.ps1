#Requires -Version 7.0
param(
  # ValueFromRemainingArguments makes `pwsh -File show-process-integrity.ps1 a b`
  # work: with -File, PowerShell binds each following word positionally, and an
  # array parameter without this attribute would reject the second one.
  [Parameter(Mandatory = $false, ValueFromRemainingArguments = $true)]
  [string[]]$Name = @('clash-halo', 'halo-host', 'sing-box')
)

# 显示指定进程的完整性级别。
#
# 用途：Windows 禁止低完整性（Low）进程添加通知区域图标，也禁止它和更高权限的
# 窗口交互。排查“托盘图标不出现”这类问题时，先确认进程跑在哪个级别：
#   Medium/High -> 可以加图标；Low -> Shell_NotifyIcon 会返回“拒绝访问”。
# 参考实测：微软签名的 notepad 由资源管理器启动是 Medium；未受信任的未签名程序
# 在这台机器上会以 Low 启动；要求管理员权限的程序则以 High 启动。
$ErrorActionPreference = 'Stop'

Add-Type -Namespace HaloIL -Name Token -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(IntPtr handle);
[DllImport("advapi32.dll", SetLastError = true)] public static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
[DllImport("advapi32.dll", SetLastError = true)] public static extern bool GetTokenInformation(IntPtr token, int cls, IntPtr info, uint len, out uint needed);

'@

function Get-HaloIntegrity([int]$ProcessId) {
  $handle = [HaloIL.Token]::OpenProcess(0x1000, $false, $ProcessId)  # PROCESS_QUERY_LIMITED_INFORMATION
  if ($handle -eq [IntPtr]::Zero) { return 'open-failed' }
  try {
    $token = [IntPtr]::Zero
    if (-not [HaloIL.Token]::OpenProcessToken($handle, 0x0008, [ref]$token)) { return 'token-failed' }
    try {
      $needed = [uint32]0
      [void][HaloIL.Token]::GetTokenInformation($token, 25, [IntPtr]::Zero, 0, [ref]$needed)
      $buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal($needed)
      try {
        if (-not [HaloIL.Token]::GetTokenInformation($token, 25, $buffer, $needed, [ref]$needed)) {
          return 'info-failed'
        }
        $sid = [Runtime.InteropServices.Marshal]::ReadIntPtr($buffer, 0)
        $count = [Runtime.InteropServices.Marshal]::ReadByte($sid, 1)
        $rid = [Runtime.InteropServices.Marshal]::ReadInt32($sid, 8 + 4 * ($count - 1))
        switch ($rid) {
          0x0000 { return 'Untrusted' }
          0x1000 { return 'Low' }
          0x2000 { return 'Medium' }
          0x2100 { return 'MediumPlus' }
          0x3000 { return 'High' }
          0x4000 { return 'System' }
          default { return ('0x{0:x}' -f $rid) }
        }
      } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
      }
    } finally {
      [void][HaloIL.Token]::CloseHandle($token)
    }
  } finally {
    [void][HaloIL.Token]::CloseHandle($handle)
  }
}

'{0,-16} {1,-8} {2,-20} {3}' -f 'process', 'pid', 'started', 'integrity'
foreach ($n in $Name) {
  $found = Get-Process -Name $n -ErrorAction SilentlyContinue
  if (-not $found) {
    '{0,-16} {1}' -f $n, '<not running>'
    continue
  }
  foreach ($p in $found) {
    '{0,-16} {1,-8} {2,-20} {3}' -f $p.ProcessName, $p.Id, $p.StartTime.ToString('HH:mm:ss'), (Get-HaloIntegrity $p.Id)
  }
}
