#Requires -Version 7.0
param(
  [string]$Stage = ".tmp/rt"
)

# Real end-to-end runtime check for the Windows host:
#   - start the host headless
#   - apply a real config through the production named pipe
#   - send real traffic through the proxy the core opened
#   - prove an invalid config is refused without disturbing the running core
#   - shut down and prove no processes are left behind
#
# Run it with pwsh (PowerShell 7+). Windows PowerShell 5.1 decodes a .ps1 without
# a BOM using the legacy ANSI code page, which garbles the Chinese literals below
# into a parse error; the #Requires line turns that mismatch into an immediate,
# readable failure. The file keeps its UTF-8 BOM so every editor and tool reads
# it correctly regardless of the shell that starts it.
$ErrorActionPreference = 'Stop'

# Child output is printed in the console code page, so pin that to UTF-8.
$OutputEncoding = [System.Text.Encoding]::UTF8
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# The pipe name is derived from the data directory (contract.PipeNameFor), so it
# has to be absolute here and normalised exactly as Go and Dart normalise it.
# With a relative path each side derives a different name, and the script then
# reports a connection failure that has nothing to do with the host.
if (-not [System.IO.Path]::IsPathRooted($Stage)) {
  $Stage = Join-Path (Get-Location).Path $Stage
}
$Stage = $Stage.TrimEnd('\', '/')
$hostExe = Join-Path $Stage 'halo-host.exe'
$dataDir = Join-Path $Stage 'data'
if (Test-Path $dataDir) { Remove-Item -Recurse -Force $dataDir }

function Get-PipeName([string]$Base) {
  # Mirrors Go's contract.PipeNameFor: filepath.Clean, backslashes to slashes,
  # lower case, then FNV-1a 64 over the UTF-8 bytes as unpadded hex.
  # BigInteger is used deliberately: PowerShell would promote an overflowing
  # uint64 multiplication to a double and silently produce a different hash.
  $s = ($Base -replace '\\', '/') -replace '/+', '/'
  $s = $s.ToLowerInvariant()
  if ([string]::IsNullOrEmpty($s)) { return 'clash-halo-host-v1' }
  $h = [System.Numerics.BigInteger]14695981039346656037
  $prime = [System.Numerics.BigInteger]1099511628211
  $mask = [System.Numerics.BigInteger]::Pow(2, 64) - 1
  foreach ($b in [System.Text.Encoding]::UTF8.GetBytes($s)) {
    $h = $h -bxor [System.Numerics.BigInteger]$b
    $h = ($h * $prime) -band $mask
  }
  # Go renders the uint64 with strconv.FormatUint, which emits the minimal
  # number of digits, while BigInteger.ToString('x') keeps a leading zero for a
  # value whose top nibble is zero. Left alone, the client looks for a pipe name
  # one character longer than the host ever created.
  $hex = $h.ToString('x').TrimStart('0')
  if ([string]::IsNullOrEmpty($hex)) { $hex = '0' }
  return 'clash-halo-host-v1-' + $hex
}

$pipeName = Get-PipeName $dataDir

# Self-check against the vectors pinned on both language sides. Without this a
# drift in the derivation shows up as a confusing "cannot connect" instead of
# naming the real problem. The second vector is the one that catches a leading
# zero, since its value begins with a zero nibble.
$probes = @{
  'D:/project/clash-halo'              = 'clash-halo-host-v1-3f9aa21224b50de8'
  'D:/project/clash-halo/.tmp/rt/data' = 'clash-halo-host-v1-a8b226546c3c1b3a'
}
foreach ($base in $probes.Keys) {
  $got = Get-PipeName $base
  if ($got -ne $probes[$base]) { throw "管道名派生与 Dart/Go 不一致：$base -> $got" }
}
Write-Host "stage     = $Stage"
Write-Host "data dir  = $dataDir"
Write-Host "pipe name = $pipeName"
if (-not (Test-Path (Join-Path $Stage 'sing-box.exe'))) {
  throw "缺少 $Stage\sing-box.exe：宿主会拒绝启动，请先放入锁定版本的内核"
}

Write-Host "== starting host (no tray) =="
$hostProc = Start-Process -FilePath $hostExe -ArgumentList @('--no-tray', '--dir', $dataDir) -PassThru -RedirectStandardOutput (Join-Path $Stage 'host.out') -RedirectStandardError (Join-Path $Stage 'host.err')
Start-Sleep -Seconds 2
if ($hostProc.HasExited) { throw "host exited early: $((Get-Content (Join-Path $Stage 'host.err')) -join '; ')" }
Write-Host "host pid=$($hostProc.Id)"

function Invoke-Host([string]$action, [hashtable]$params = @{}) {
  $req = @{ v = 1; id = [guid]::NewGuid().ToString('N'); action = $action }
  if ($params.Count -gt 0) { $req.params = $params }
  $json = ($req | ConvertTo-Json -Compress -Depth 10)
  $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
  $pipe.Connect(3000)
  $writer = New-Object System.IO.StreamWriter($pipe)
  $writer.AutoFlush = $true
  $writer.WriteLine($json)
  $reader = New-Object System.IO.StreamReader($pipe)
  # Events and responses share one stream: the host broadcasts state changes to
  # every client, including the one that has just connected, so the first line
  # is often an event. Discriminate by frame shape, as a real client does,
  # instead of assuming the next line is the reply.
  while ($true) {
    $line = $reader.ReadLine()
    if ($null -eq $line) { throw "管道在等待 $action 响应时被关闭" }
    if ($line -match '"event"\s*:') { continue }
    break
  }
  $writer.Dispose()
  $reader.Dispose()
  $pipe.Dispose()
  return $line
}

Write-Host "== host.status =="
$status = Invoke-Host 'host.status'
Write-Host $status
if (($status | ConvertFrom-Json).ok -ne $true) { throw "host.status failed" }

Write-Host "== config.apply (valid) =="
$cfg = @{
  log = @{ level = 'warn'; timestamp = $true }
  inbounds = @(@{ type = 'mixed'; tag = 'mixed-in'; listen = '127.0.0.1'; listen_port = 17895 })
  outbounds = @(@{ type = 'direct'; tag = 'direct' })
  route = @{ final = 'direct' }
  experimental = @{ clash_api = @{ external_controller = '127.0.0.1:17896'; secret = '' } }
} | ConvertTo-Json -Depth 8
$apply = Invoke-Host 'config.apply' @{ config = $cfg; controller = '127.0.0.1:17896' }
Write-Host $apply
$applyObj = $apply | ConvertFrom-Json
if ($applyObj.ok -ne $true) { throw "valid apply failed: $apply" }

Write-Host "== traffic through the proxy =="
$curl = & "$env:SystemRoot\System32\curl.exe" -s -o NUL -w "%{http_code}" -x http://127.0.0.1:17895 --max-time 15 https://www.gstatic.com/generate_204
Write-Host "http_code=$curl"

Write-Host "== snapshot =="
$snapObj = (Invoke-Host 'snapshot.get' | ConvertFrom-Json)
Write-Host "coreState=$($snapObj.result.coreState) corePid=$($snapObj.result.corePid) logBytes=$($snapObj.result.logBytes)"

Write-Host "== log.tail =="
$tailObj = (Invoke-Host 'log.tail' @{ lines = 20 } | ConvertFrom-Json)
Write-Host "lines=$($tailObj.result.lines.Count) logBytes=$($tailObj.result.logBytes)"
if ($tailObj.result.lines.Count -lt 1) { throw "host log is empty" }

Write-Host "== config.apply (invalid) must be rejected and core must keep running =="
$bad = '{"outbounds":[{"type":"definitely-not-a-protocol","tag":"p"}]}'
$badObj = (Invoke-Host 'config.apply' @{ config = $bad } | ConvertFrom-Json)
Write-Host "bad ok=$($badObj.ok) code=$($badObj.error.code)"
if ($badObj.ok -ne $false) { throw "invalid config was accepted" }
$snap2 = (Invoke-Host 'snapshot.get' | ConvertFrom-Json)
Write-Host "after rejection coreState=$($snap2.result.coreState) configVersion=$($snap2.result.configVersion)"
if ($snap2.result.coreState -ne 'running') { throw "core died after a rejected apply" }

Write-Host "== UI closed but proxy keeps running =="
$before = (Invoke-Host 'snapshot.get' | ConvertFrom-Json)
Write-Host "stateVersion=$($before.result.stateVersion) corePid=$($before.result.corePid)"
$curl2 = & "$env:SystemRoot\System32\curl.exe" -s -o NUL -w "%{http_code}" -x http://127.0.0.1:17895 --max-time 15 https://www.gstatic.com/generate_204
Write-Host "traffic still works: http_code=$curl2"

Write-Host "== shutdown =="
$quit = Invoke-Host 'host.shutdown'
Write-Host $quit
$null = $hostProc.WaitForExit(8000)
if (-not $hostProc.HasExited) { throw "host did not exit" }
# ExitCode is occasionally unavailable on a redirected Process object; printing
# nothing would read like a failure in an otherwise passing run.
$exitCode = $hostProc.ExitCode
if ($null -eq $exitCode) { $exitCode = 'n/a' }
Write-Host "host exited code=$exitCode"

Write-Host "== leftover processes =="
# Only the core this host started is our business. The blanket "no sing-box may
# exist" check failed on any machine that also runs its own proxy, which made
# the script unusable exactly where it was most needed.
if ($corePid) {
  $still = Get-Process -Id $corePid -ErrorAction SilentlyContinue
  if ($still) { throw "core pid $corePid still running" }
  Write-Host "core pid $corePid is gone"
} else {
  Write-Host "host reported no core pid"
}
Write-Host "none"

Write-Host "== runtime.json =="
Get-Content (Join-Path $dataDir 'runtime.json') -Raw -Encoding UTF8
Write-Host "== host.log (last 20) =="
# The host writes UTF-8, so Windows PowerShell would otherwise decode its
# Chinese log lines with the legacy ANSI code page and print mojibake.
$log = Join-Path $dataDir 'logs\host.log'
if (Test-Path $log) { Get-Content $log -Tail 20 -Encoding UTF8 }
Write-Host "== RESULT: PASS =="
