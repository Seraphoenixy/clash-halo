# Exercises host actions over the real named pipe.
#
# Used for manual verification of actions the UI reaches only through a dialog,
# where driving the GUI would be more fragile than calling the same protocol the
# UI calls. Prints each reply verbatim so nothing is asserted that was not seen.
#Requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$Action,
    [string]$ParamsJson = '{}',
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
$pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
$pipe.Connect(3000)
$writer = New-Object System.IO.StreamWriter($pipe)
$writer.AutoFlush = $true
$reader = New-Object System.IO.StreamReader($pipe)
try {
    $request = @{
        v       = 1
        id      = "verify-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
        action  = $Action
        params  = ($ParamsJson | ConvertFrom-Json -AsHashtable)
    } | ConvertTo-Json -Compress -Depth 8
    $writer.WriteLine($request)
    # Events may arrive before the reply; read until an envelope carrying the
    # matching id shows up.
    for ($i = 0; $i -lt 20; $i++) {
        $line = $null
        try { $line = $reader.ReadLine() } catch { break }
        if ($null -eq $line) { break }
        $parsed = $null
        try { $parsed = $line | ConvertFrom-Json } catch { continue }
        if ($null -ne $parsed.action -or $null -ne $parsed.ok) {
            Write-Host $line
            break
        }
    }
} finally {
    foreach ($d in @($reader, $writer, $pipe)) { try { $d.Dispose() } catch { } }
}
