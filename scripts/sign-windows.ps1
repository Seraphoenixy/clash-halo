#Requires -Version 7.0
param(
  [string]$BuildDir = '',
  # 只签这一个文件（安装包）。传了它就不再按 BuildDir 里的固定清单签名。
  [string]$FilePath = '',
  [string]$PfxPath = '',
  [string]$PfxPassword = '',
  [string]$Thumbprint = '',
  [switch]$SelfSigned,
  [string]$Subject = 'CN=Clash Halo, O=Clash Halo Project',
  [switch]$TrustSelfSigned,
  [string]$TimestampUrl = 'http://timestamp.digicert.com',
  [switch]$Unblock,
  [switch]$Report
)

# Authenticode signing for the shipped Windows binaries.
#
# Why this exists: Windows shows a security prompt for unsigned programs. There
# are three different prompts and only signing removes all of them:
#
#   * SmartScreen "Windows protected your PC" — driven by Mark-of-the-Web plus
#     the file's reputation. Unblocking the file removes it once; a publicly
#     trusted certificate removes it for everyone, and reputation accrues per
#     certificate. A *self-signed* certificate does NOT satisfy SmartScreen.
#   * UAC "Do you want to allow this app to make changes?" — shown for
#     halo-tun-service.exe --install, which is elevated on request. Signing
#     changes "Unknown publisher" into your name. A self-signed certificate is
#     enough for that, but only on machines where the certificate is trusted.
#   * Antivirus heuristics — signing is not a guarantee, but it removes the
#     "unsigned binary" signal that most engines weigh.
#
# Report mode is read-only; signing and unblocking are explicit switches.
#
# Run it with pwsh (PowerShell 7+): the #Requires line above makes an accidental
# Windows PowerShell 5.1 start fail immediately instead of hitting the 5.1
# non-BOM decoding trap.

$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
# Single-file mode signs exactly what the caller named — the installer — instead
# of the fixed list of binaries in a build directory. The targets list below then
# holds just that name, so reporting, signing and unblocking all stay one code
# path.
$singleFile = -not [string]::IsNullOrEmpty($FilePath)
if ($singleFile) {
  if (-not (Test-Path $FilePath)) { throw "file not found: $FilePath" }
  $FilePath = (Resolve-Path $FilePath).Path
  $BuildDir = Split-Path $FilePath -Parent
} else {
  if ([string]::IsNullOrEmpty($BuildDir)) { $BuildDir = Join-Path $root 'build\windows-x64' }
  if (-not (Test-Path $BuildDir)) { throw "build directory not found: $BuildDir" }
  $BuildDir = (Resolve-Path $BuildDir).Path
}

# The core is third-party; it is listed because Windows checks it too when the
# host launches it, but signing it is optional and must respect its licence.
$targets = if ($singleFile) {
  @(Split-Path $FilePath -Leaf)
} else {
  @('clash-halo.exe', 'halo-host.exe', 'halo-tun-service.exe', 'sing-box.exe')
}

function Get-FileState([string]$path) {
  $motw = $null -ne (Get-Item -LiteralPath $path -Stream Zone.Identifier -ErrorAction SilentlyContinue)
  $sig = Get-AuthenticodeSignature -LiteralPath $path
  [pscustomobject]@{
    Path      = $path
    Motw      = $motw
    Status    = $sig.Status
    Signer    = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
  }
}

function Show-Report {
  'file                  MOTW  signature    signer'
  '--------------------  ----  -----------  ------------------------------------------'
  foreach ($name in $targets) {
    $path = Join-Path $BuildDir $name
    if (-not (Test-Path $path)) { '{0,-20}  --    missing' -f $name; continue }
    $s = Get-FileState $path
    '{0,-20}  {1,-4}  {2,-11}  {3}' -f $name, $(if ($s.Motw) { 'yes' } else { 'no' }), $s.Status, $s.Signer
  }
}

function Remove-Motw {
  # Clears the "downloaded from the internet" marker. Harmless when absent, and
  # it is the whole fix for a copy that arrived in a zip: SmartScreen keys off
  # this marker plus reputation, so a local, unmarked build stops prompting.
  $cleared = 0
  Get-ChildItem $BuildDir -Recurse -File | ForEach-Object {
    if (Get-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue) {
      Unblock-File -LiteralPath $_.FullName
      $cleared++
    }
  }
  "cleared Mark-of-the-Web on $cleared file(s)"
}

function Resolve-Certificate {
  if (-not [string]::IsNullOrEmpty($Thumbprint)) {
    $cert = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My |
      Where-Object Thumbprint -eq $Thumbprint
    if (-not $cert) { throw "no certificate with thumbprint $Thumbprint in My stores" }
    return $cert
  }
  if ($SelfSigned) {
    $cert = Get-ChildItem Cert:\CurrentUser\My |
      Where-Object { $_.Subject -eq $Subject -and $_.NotAfter -gt (Get-Date) } |
      Select-Object -First 1
    if (-not $cert) {
      $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $Subject `
        -CertStoreLocation Cert:\CurrentUser\My `
        -KeyUsage DigitalSignature -KeyExportPolicy Exportable `
        -NotAfter (Get-Date).AddYears(3) `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3')
      # Write-Host, not a bare string: anything written to the pipeline becomes
      # part of this function's return value, and the caller would then receive
      # "message + certificate" as an array instead of the certificate.
      Write-Host "created self-signed code signing certificate: $($cert.Thumbprint)"
    }
    return $cert
  }
  throw 'no certificate given: pass -PfxPath, -Thumbprint or -SelfSigned'
}

function Grant-SelfSignedTrust([System.Security.Cryptography.X509Certificates.X509Certificate2]$cert) {
  # A self-signed certificate is only meaningful where it is trusted. The
  # *current user* Root and TrustedPublisher stores need no elevation, and that
  # is enough for this account: the signature turns Valid (instead of
  # UnknownError) and the publisher name replaces "unknown publisher" in the UAC
  # prompt that the service installer triggers.
  #
  # TrustedPublisher must come second: a publisher entry whose chain is not yet
  # trusted does nothing.
  foreach ($store in 'Root', 'TrustedPublisher') {
    $path = "Cert:\CurrentUser\$store"
    $already = Get-ChildItem $path | Where-Object Thumbprint -eq $cert.Thumbprint
    if ($already) { "  $store`: already trusted"; continue }
    try {
      [void](Import-Certificate -FilePath (Export-CertToTemp $cert) -CertStoreLocation $path)
      "  $store`: certificate added"
    } catch {
      "  $store`: adding failed -> $($_.Exception.Message)"
    }
  }
}

function Export-CertToTemp([System.Security.Cryptography.X509Certificates.X509Certificate2]$cert) {
  $path = Join-Path ([System.IO.Path]::GetTempPath()) ("halo-codesign-" + $cert.Thumbprint + ".cer")
  [System.IO.File]::WriteAllBytes($path, $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
  return $path
}

function Invoke-Signing([System.Security.Cryptography.X509Certificates.X509Certificate2]$cert) {
  foreach ($name in $targets) {
    $path = Join-Path $BuildDir $name
    if (-not (Test-Path $path)) { "skip $name (missing)"; continue }
    # $signArgs, not $args: $args is an automatic variable and reusing it in a
    # function is a trap that only shows up as confusing splatting failures.
    $signArgs = @{
      FilePath      = $path
      Certificate   = $cert
      HashAlgorithm = 'SHA256'
    }
    if (-not [string]::IsNullOrEmpty($TimestampUrl)) { $signArgs.TimestampServer = $TimestampUrl }

    # Retry: a multi-megabyte exe that was just written can still be held by an
    # antivirus/proxy filter driver, and the signing API then reports
    # "not a valid Win32 application" (ERROR_BAD_EXE_FORMAT) even though the PE
    # is fine. Signing the same bytes two seconds later succeeds, so a short
    # backoff is the difference between a signed release and a silently unsigned
    # one. Success is "a signature exists" — an untrusted chain still counts here,
    # because a self-signed certificate is expected to be untrusted.
    $result = $null
    for ($attempt = 1; $attempt -le 4; $attempt++) {
      try {
        $result = Set-AuthenticodeSignature @signArgs
      } catch {
        if ($attempt -eq 4) { "signing $name failed: $($_.Exception.Message)"; break }
        Start-Sleep -Milliseconds (300 * $attempt)
        continue
      }
      if ($null -ne $result.SignerCertificate) { break }
      if ($attempt -eq 4) {
        "signing $name failed: $($result.StatusMessage)"
        break
      }
      Start-Sleep -Milliseconds (300 * $attempt)
    }
    if ($null -eq $result -or $null -eq $result.SignerCertificate) { continue }

    if ($result.Status -ne 'Valid' -and $signArgs.ContainsKey('TimestampServer')) {
      # An unreachable timestamp server fails the whole call, so retry without
      # one: the signature is still valid now and only expires with the
      # certificate. An untrusted chain (self-signed) stays untrusted either
      # way, which the status below makes visible.
      "signing $name returned $($result.Status) with timestamping; retrying without a timestamp"
      $signArgs.Remove('TimestampServer')
      $result = Set-AuthenticodeSignature @signArgs
    }
    $state = Get-FileState $path
    $note = ''
    if ($SelfSigned -and $state.Status -ne 'Valid') {
      $note = '  (untrusted chain: expected for a self-signed certificate)'
    }
    '{0,-20}  {1,-11}  {2}{3}' -f $name, $state.Status, $state.Signer, $note
  }
}

if ($Report -or (-not $Unblock -and -not $PfxPath -and -not $Thumbprint -and -not $SelfSigned)) {
  '== current state =='
  Show-Report
  ''
  'Nothing was changed. To act, pass one of:'
  '  -Unblock                 clear the download marker on every file'
  '  -PfxPath <file.pfx>      sign with a real certificate (release path)'
  '  -Thumbprint <sha1>       sign with a certificate already in a My store'
  '  -SelfSigned              sign with a local development certificate'
  '  -SelfSigned -TrustSelfSigned'
  '                           also trust it in the current user Root and'
  '                           TrustedPublisher stores, so the signature reads'
  '                           Valid and the publisher name is shown'
  ''
  'Reminder: a self-signed certificate silences the UAC publisher text only on'
  'machines that trust it, and it does NOT satisfy SmartScreen. Public releases'
  'need a publicly trusted code signing certificate.'
  exit 0
}

if ($Unblock) { Remove-Motw }
if ($PfxPath -or $Thumbprint -or $SelfSigned) {
  if (-not [string]::IsNullOrEmpty($PfxPath)) {
    # Get-PfxCertificate ignores the password, so a protected pfx must be
    # imported into the user store first.
    $secure = ConvertTo-SecureString -String $PfxPassword -AsPlainText -Force
    $imported = Import-PfxCertificate -FilePath $PfxPath -CertStoreLocation Cert:\CurrentUser\My `
      -Password $secure -Exportable
    $cert = $imported
  } else {
    $cert = Resolve-Certificate
  }
  if ($SelfSigned -and $TrustSelfSigned) {
    '== trusting the self-signed certificate for this user =='
    Grant-SelfSignedTrust $cert
  }
  Invoke-Signing $cert
}

''
'== after =='
Show-Report