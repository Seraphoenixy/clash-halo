#Requires -Version 7.0
param(
    [Parameter(Mandatory)]
    [ValidateSet('flutter', 'cli', 'config', 'contracts', 'domain', 'storage', 'go')]
    [string]$Suite,
    [string[]]$Target,
    [string]$Filter,
    [switch]$Pub
)

$ErrorActionPreference = 'Stop'
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

switch ($Suite) {
    'flutter' {
        $directory = Join-Path $root 'apps/flutter'
        $runner = Resolve-Tool (Join-Path $root '.tools/flutter/bin/flutter.bat') 'flutter'
        $arguments = @('test', '--timeout', '60s')
        if (!$Pub -and (Test-Path (Join-Path $root '.dart_tool/package_config.json'))) {
            $arguments += '--no-pub'
        }
    }
    'go' {
        if (!$Target) { throw 'Go requires -Target, for example ./internal/app.' }
        $directory = Join-Path $root 'native/windows'
        $runner = Resolve-Tool (Join-Path $root '.tools/go/bin/go.exe') 'go'
        $arguments = @('test', '-timeout', '2m')
    }
    default {
        $flutter = Resolve-Tool (Join-Path $root '.tools/flutter/bin/flutter.bat') 'flutter'
        $runner = Join-Path (Split-Path $flutter -Parent) 'dart.bat'
        if (-not (Test-Path -LiteralPath $runner)) { $runner = Resolve-Tool '' 'dart' }
        $package = if ($Suite -eq 'cli') { 'apps/cli' } else { "packages/$Suite" }
        $directory = Join-Path $root $package
        $arguments = @('test', '--timeout', '60s')
        if (!$Target) { $Target = @('test') }
        if ($Suite -eq 'config') {
            # The core validation tests locate prototype/bin from the repo root.
            $directory = $root
            $Target = @($Target | ForEach-Object { Join-Path $package $_ })
        }
    }
}

if ($Filter) {
    $flag = if ($Suite -eq 'go') { '-run' } else { '--plain-name' }
    $arguments += @($flag, $Filter)
}
if ($Target) { $arguments += $Target }

Push-Location $directory
try {
    & $runner @arguments
    $result = $LASTEXITCODE
} finally {
    Pop-Location
}
exit $result
