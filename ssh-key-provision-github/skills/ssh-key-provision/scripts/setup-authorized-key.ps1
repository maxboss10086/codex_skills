param(
  [Parameter(Mandatory = $true)]
  [string]$HostName,

  [int]$Port = 22,

  [Parameter(Mandatory = $true)]
  [string]$User,

  [string]$PrivateKeyPath,

  [securestring]$Password
)

$ErrorActionPreference = 'Stop'

function Expand-UserPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  if ($Path -eq '~') {
    return $HOME
  }
  if ($Path.StartsWith('~/') -or $Path.StartsWith('~\')) {
    return Join-Path $HOME $Path.Substring(2)
  }
  return $Path
}

function ConvertTo-PlainText {
  param([Parameter(Mandatory = $true)][securestring]$Secure)

  $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
  }
}

function Invoke-Native {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  $output = & $FilePath @Arguments 2>&1
  $exit = $LASTEXITCODE
  [pscustomobject]@{
    ExitCode = $exit
    Output = ($output -join [Environment]::NewLine)
  }
}

function Get-PrivateKeyPath {
  param(
    [string]$RequestedPath,
    [Parameter(Mandatory = $true)][string]$HostName,
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$User
  )

  $sshDir = Join-Path $HOME '.ssh'
  New-Item -ItemType Directory -Force $sshDir | Out-Null

  if ($RequestedPath) {
    $resolved = Expand-UserPath $RequestedPath
    if (-not (Test-Path -LiteralPath $resolved)) {
      throw "Private key does not exist: $resolved"
    }
    if (-not (Test-Path -LiteralPath "$resolved.pub")) {
      throw "Public key does not exist: $resolved.pub"
    }
    return $resolved
  }

  $candidates = @(
    (Join-Path $sshDir 'id_ed25519'),
    (Join-Path $sshDir 'id_rsa'),
    (Join-Path $sshDir 'id_ecdsa')
  )

  foreach ($candidate in $candidates) {
    if ((Test-Path -LiteralPath $candidate) -and (Test-Path -LiteralPath "$candidate.pub")) {
      return $candidate
    }
  }

  $safe = "$HostName`_$Port`_$User" -replace '[^A-Za-z0-9_.-]', '_'
  $newKey = Join-Path $sshDir "codex_${safe}_ed25519"
  if (-not (Test-Path -LiteralPath $newKey)) {
    $keygen = Invoke-Native 'ssh-keygen.exe' @('-t', 'ed25519', '-f', $newKey, '-N', '', '-C', "codex@$HostName")
    if ($keygen.ExitCode -ne 0) {
      throw "ssh-keygen failed: $($keygen.Output)"
    }
  }
  return $newKey
}

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

if (-not $Password) {
  $Password = Read-Host -Prompt "Password for $User@$HostName" -AsSecureString
}

$privateKey = Get-PrivateKeyPath -RequestedPath $PrivateKeyPath -HostName $HostName -Port $Port -User $User
$publicKeyPath = "$privateKey.pub"
$publicKey = (Get-Content -LiteralPath $publicKeyPath -Raw).Trim()

$verifyArgs = @(
  '-o', 'BatchMode=yes',
  '-o', 'ConnectTimeout=8',
  '-o', 'StrictHostKeyChecking=accept-new',
  '-i', $privateKey,
  '-p', [string]$Port,
  "$User@$HostName",
  'echo codex_key_ok'
)

$initialVerify = Invoke-Native 'ssh.exe' $verifyArgs
if ($initialVerify.ExitCode -eq 0 -and $initialVerify.Output -match 'codex_key_ok') {
  [pscustomobject]@{
    Status = 'already_configured'
    HostName = $HostName
    Port = $Port
    User = $User
    PrivateKeyPath = $privateKey
    PublicKeyPath = $publicKeyPath
    Verification = 'succeeded'
  } | ConvertTo-Json -Depth 3
  exit 0
}

if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
  $provider = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
  if (-not $provider) {
    Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
  }
  $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
  if ($repo -and $repo.InstallationPolicy -ne 'Trusted') {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
  }
  Install-Module -Name Posh-SSH -Scope CurrentUser -Force -AllowClobber
}

Import-Module Posh-SSH

$plainPassword = ConvertTo-PlainText $Password
$credential = [pscredential]::new($User, (ConvertTo-SecureString $plainPassword -AsPlainText -Force))

$session = New-SSHSession -ComputerName $HostName -Port $Port -Credential $credential -AcceptKey -ConnectionTimeout 20
try {
  $escapedKey = $publicKey.Replace("'", "'\''")
  $remoteCommand = "mkdir -p ~/.ssh; chmod 700 ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF '$escapedKey' ~/.ssh/authorized_keys || echo '$escapedKey' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys; echo codex_authorized_keys_ready"
  $remoteResult = Invoke-SSHCommand -SessionId $session.SessionId -Command $remoteCommand -TimeOut 20
  if (($remoteResult.Output -join "`n") -notmatch 'codex_authorized_keys_ready') {
    throw "Remote authorized_keys update did not confirm success."
  }
} finally {
  if ($session) {
    Remove-SSHSession -SessionId $session.SessionId | Out-Null
  }
  $plainPassword = $null
}

$finalVerify = Invoke-Native 'ssh.exe' $verifyArgs
if ($finalVerify.ExitCode -ne 0 -or $finalVerify.Output -notmatch 'codex_key_ok') {
  throw "Key login verification failed: $($finalVerify.Output)"
}

[pscustomobject]@{
  Status = 'configured'
  HostName = $HostName
  Port = $Port
  User = $User
  PrivateKeyPath = $privateKey
  PublicKeyPath = $publicKeyPath
  Verification = 'succeeded'
} | ConvertTo-Json -Depth 3
