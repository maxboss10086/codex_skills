param(
  [Parameter(Mandatory = $true)]
  [string]$HostName,

  [int]$Port = 22,

  [Parameter(Mandatory = $true)]
  [string]$User,

  [string]$PrivateKeyPath,

  [securestring]$Password,

  [string]$CodexVersion = '0.141.0'
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillDir = Split-Path -Parent $scriptDir
$assetDir = Join-Path $skillDir 'assets\codex-install'
$packageName = 'codex-package-x86_64-unknown-linux-musl.tar.gz'
$checksumName = 'codex-package_SHA256SUMS'
$packagePath = Join-Path $assetDir $packageName
$checksumPath = Join-Path $assetDir $checksumName

if (-not (Test-Path -LiteralPath $packagePath)) {
  throw "Missing bundled Codex package: $packagePath"
}
if (-not (Test-Path -LiteralPath $checksumPath)) {
  throw "Missing bundled Codex checksum file: $checksumPath"
}

$keyArgs = @{
  HostName = $HostName
  Port = $Port
  User = $User
  Password = $Password
}
if ($PrivateKeyPath) {
  $keyArgs.PrivateKeyPath = $PrivateKeyPath
}

$keyJson = & (Join-Path $scriptDir 'setup-authorized-key.ps1') @keyArgs
if ($LASTEXITCODE -ne 0) {
  throw "SSH key setup failed."
}

$keyResult = $keyJson | ConvertFrom-Json
$privateKey = [string]$keyResult.PrivateKeyPath

$arch = (& ssh.exe -o BatchMode=yes -o ConnectTimeout=10 -i $privateKey -p $Port "$User@$HostName" 'uname -s; uname -m') 2>&1
if ($LASTEXITCODE -ne 0) {
  throw "Could not inspect remote platform: $($arch -join [Environment]::NewLine)"
}
$platformText = $arch -join "`n"
if ($platformText -notmatch 'Linux' -or $platformText -notmatch '(x86_64|amd64)') {
  throw "Bundled offline Codex package supports Linux x64 only. Remote platform: $platformText"
}

& ssh.exe -o BatchMode=yes -o ConnectTimeout=10 -i $privateKey -p $Port "$User@$HostName" 'mkdir -p /tmp/codex-install && rm -f /tmp/codex-install/codex-package-x86_64-unknown-linux-musl.tar.gz /tmp/codex-install/codex-package_SHA256SUMS'
if ($LASTEXITCODE -ne 0) {
  throw "Failed to prepare remote /tmp/codex-install."
}

& scp.exe -P $Port -i $privateKey $packagePath "${User}@${HostName}:/tmp/codex-install/"
if ($LASTEXITCODE -ne 0) {
  throw "Failed to upload Codex package."
}

& scp.exe -P $Port -i $privateKey $checksumPath "${User}@${HostName}:/tmp/codex-install/"
if ($LASTEXITCODE -ne 0) {
  throw "Failed to upload Codex checksum file."
}

$remoteInstall = @"
set -e
cd /tmp/codex-install
sha256sum -c --ignore-missing $checksumName
version=$CodexVersion
target=x86_64-unknown-linux-musl
release_dir="`$HOME/.codex/packages/standalone/releases/`$version-`$target"
mkdir -p "`$release_dir" "`$HOME/.local/bin"
rm -rf "`$release_dir.tmp"
mkdir -p "`$release_dir.tmp"
tar -xzf $packageName -C "`$release_dir.tmp"
rm -rf "`$release_dir"
mv "`$release_dir.tmp" "`$release_dir"
chmod 0755 "`$release_dir/bin/codex" "`$release_dir/codex-path/rg"
if [ -f "`$release_dir/codex-resources/bwrap" ]; then chmod 0755 "`$release_dir/codex-resources/bwrap"; fi
ln -sfn "`$release_dir" "`$HOME/.codex/packages/standalone/current"
ln -sfn "`$HOME/.codex/packages/standalone/current/bin/codex" "`$HOME/.local/bin/codex"
ln -sfn "`$HOME/.local/bin/codex" /usr/local/bin/codex 2>/dev/null || true
touch "`$HOME/.profile" "`$HOME/.bashrc"
grep -q 'HOME/.local/bin' "`$HOME/.profile" || printf '\n# Codex CLI\nexport PATH="`$HOME/.local/bin:`$PATH"\n' >> "`$HOME/.profile"
grep -q 'HOME/.local/bin' "`$HOME/.bashrc" || printf '\n# Codex CLI\nexport PATH="`$HOME/.local/bin:`$PATH"\n' >> "`$HOME/.bashrc"
if command -v codex >/dev/null 2>&1; then codex --version; else "`$HOME/.local/bin/codex" --version; fi
"@

$installOutput = (& ssh.exe -o BatchMode=yes -o ConnectTimeout=10 -i $privateKey -p $Port "$User@$HostName" $remoteInstall) 2>&1
if ($LASTEXITCODE -ne 0) {
  throw "Remote Codex CLI install failed: $($installOutput -join [Environment]::NewLine)"
}

[pscustomobject]@{
  Status = 'configured'
  HostName = $HostName
  Port = $Port
  User = $User
  PrivateKeyPath = $privateKey
  PublicKeyPath = [string]$keyResult.PublicKeyPath
  KeyVerification = [string]$keyResult.Verification
  CodexInstall = 'succeeded'
  CodexVersionOutput = ($installOutput -join [Environment]::NewLine)
} | ConvertTo-Json -Depth 3
