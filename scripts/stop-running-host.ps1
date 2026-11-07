# Asks the running background host to shut down through its own IPC protocol, so
# the rebuild can replace halo-host.exe without leaving an orphaned tray process
# holding host.lock.
#
# Mirrors contract.PipeNameFor: filepath.Clean, backslashes to slashes, lower
# case, FNV-1a 64 as unpadded hex. BigInteger is deliberate: PowerShell would
# promote an overflowing uint64 multiplication to a double and silently produce
# a different hash.
#Requires -Version 7.0
param(
    [string]$DataDir = (Join-Path $env:LOCALAPPDATA 'clash-halo')
)

$ErrorActionPreference = 'Stop'

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

$pipeName = Get-PipeName $DataDir
Write-Host "pipe: $pipeName"

$pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
try {
    $pipe.Connect(3000)
} catch {
    Write-Host '后台没有在运行（管道不存在），无需关闭。'
    exit 0
}

$writer = New-Object System.IO.StreamWriter($pipe)
$writer.AutoFlush = $true
$reader = New-Object System.IO.StreamReader($pipe)
try {
    $request = @{ v = 1; id = 'shutdown-1'; action = 'host.shutdown'; params = @{} } | ConvertTo-Json -Compress
    $writer.WriteLine($request)
    # The host answers host.shutdown and *then* closes the pipe, so a state
    # change event may arrive first. Read a few lines and take the one that
    # actually carries the reply; a closed pipe here means it already exited,
    # which is the outcome this script asked for.
    for ($i = 0; $i -lt 8; $i++) {
        $line = $null
        try { $line = $reader.ReadLine() } catch { break }
        if ($null -eq $line) { break }
        Write-Host "reply: $line"
        $parsed = $null
        try { $parsed = $line | ConvertFrom-Json } catch { continue }
        if ($parsed.action -or $parsed.ok -ne $null) { break }
    }
} finally {
    foreach ($disposable in @($reader, $writer, $pipe)) {
        try { $disposable.Dispose() } catch { }
    }
}

# The host answers before tearing down (Options.AfterReply), then closes the
# pipe and leaves the tray loop. Give it that moment rather than racing it.
for ($i = 0; $i -lt 100; $i++) {
    $hosts = @(Get-CimInstance Win32_Process |
        Where-Object { $_.Name -eq 'halo-host.exe' -and $_.ExecutablePath -like 'D:\software\clash-halo-build*' })
    if ($hosts.Count -eq 0) {
        Write-Host 'halo-host 已退出。'
        exit 0
    }
    Start-Sleep -Milliseconds 200
}
throw 'halo-host 仍在运行，构建会无法替换文件'
