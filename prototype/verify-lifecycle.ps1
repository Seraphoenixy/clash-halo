#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$backend = Join-Path $PSScriptRoot 'bin\halo-prototype.exe'
$ui = Join-Path $PSScriptRoot 'bin\ui\halo_lifecycle.exe'
$runtime = Join-Path $PSScriptRoot 'runtime'
New-Item -ItemType Directory -Force $runtime | Out-Null
if (Get-Process halo-prototype -ErrorAction SilentlyContinue) {
    throw 'Close any existing prototype before running the isolated probe.'
}
$hostProcess = Start-Process $backend -WindowStyle Hidden -PassThru
try {
    Start-Sleep -Seconds 2
    $initial = (& $backend status | ConvertFrom-Json)
    if ($initial.backendPid -ne $hostProcess.Id) { throw 'Backend PID mismatch' }
    $runs = @()
    foreach ($number in 1,2) {
        $report = Join-Path $runtime "ui-probe-$number.json"
        $windowProcess = Start-Process $ui -ArgumentList @('--lifecycle-probe', $report) -WindowStyle Hidden -PassThru
        if (!$windowProcess.WaitForExit(30000)) {
            Stop-Process -Id $windowProcess.Id
            throw 'UI probe did not exit within 30 seconds'
        }
        if ($windowProcess.ExitCode -ne 0) { throw 'UI probe returned failure' }
        $reply = Get-Content $report -Raw | ConvertFrom-Json
        if ($reply.backendPid -ne $hostProcess.Id -or $reply.error) { throw 'UI could not reconnect to original backend' }
        $hostProcess.Refresh()
        if ($hostProcess.HasExited) { throw 'Backend exited with UI' }
        $runs += [pscustomobject]@{uiPid=$windowProcess.Id; uiExited=$true; backendPid=$reply.backendPid}
    }
    $result = [pscustomobject]@{
        checkedAt=(Get-Date).ToString('o')
        uiRuns=$runs
        backendSurvived=$true
        coreStarted=$false
        systemProxyChanged=$false
        tunEnabled=$false
    }
    $result | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $runtime 'lifecycle-result.json')
    $result | ConvertTo-Json -Depth 5
} finally {
    & $backend quit
    if (!$hostProcess.WaitForExit(5000)) { Stop-Process -Id $hostProcess.Id }
}
