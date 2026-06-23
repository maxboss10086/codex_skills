param(
  [Parameter(Mandatory = $true)]
  [string]$HostName,

  [int]$Port = 22,

  [Parameter(Mandatory = $true)]
  [string]$User,

  [string]$PrivateKeyPath,

  [securestring]$Password,

  [string]$CodexVersion = '0.141.0',

  [switch]$SkipPathProbeFix
)

$ErrorActionPreference = 'Stop'

function Invoke-Native {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  $output = & $FilePath @Arguments 2>&1
  [pscustomobject]@{
    ExitCode = $LASTEXITCODE
    Output = ($output -join [Environment]::NewLine)
    Lines = @($output)
  }
}

function Invoke-Ssh {
  param(
    [Parameter(Mandatory = $true)][string]$PrivateKey,
    [Parameter(Mandatory = $true)][string]$Command,
    [int]$TimeoutSeconds = 20
  )

  Invoke-Native 'ssh.exe' @(
    '-o', 'BatchMode=yes',
    '-o', "ConnectTimeout=$TimeoutSeconds",
    '-i', $PrivateKey,
    '-p', [string]$Port,
    "$User@$HostName",
    $Command
  )
}

function Copy-ToRemote {
  param(
    [Parameter(Mandatory = $true)][string]$PrivateKey,
    [Parameter(Mandatory = $true)][string]$LocalPath,
    [Parameter(Mandatory = $true)][string]$RemotePath
  )

  $result = Invoke-Native 'scp.exe' @(
    '-P', [string]$Port,
    '-i', $PrivateKey,
    $LocalPath,
    "${User}@${HostName}:$RemotePath"
  )
  if ($result.ExitCode -ne 0) {
    throw "Failed to upload $LocalPath to $RemotePath`: $($result.Output)"
  }
}

function Get-PackagePlan {
  param([Parameter(Mandatory = $true)][string]$Arch)

  switch -Regex ($Arch) {
    '^(x86_64|amd64)$' {
      return [pscustomobject]@{
        Target = 'x86_64-unknown-linux-musl'
        PackageName = 'codex-package-x86_64-unknown-linux-musl.tar.gz'
        Layout = 'standalone-directory'
      }
    }
    '^(aarch64|arm64)$' {
      return [pscustomobject]@{
        Target = 'aarch64-unknown-linux-musl'
        PackageName = 'codex-aarch64-unknown-linux-musl.tar.gz'
        Layout = 'single-binary'
      }
    }
    default {
      throw "Unsupported Linux architecture for bundled offline Codex package: $Arch"
    }
  }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillDir = Split-Path -Parent $scriptDir
$assetDir = Join-Path $skillDir 'assets\codex-install'
$checksumName = 'codex-package_SHA256SUMS'
$checksumPath = Join-Path $assetDir $checksumName

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

$platform = Invoke-Ssh -PrivateKey $privateKey -Command 'uname -s; uname -m'
if ($platform.ExitCode -ne 0) {
  throw "Could not inspect remote platform: $($platform.Output)"
}

$platformLines = @($platform.Lines | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
$osName = $platformLines[0]
$archName = $platformLines[1]
if ($osName -ne 'Linux') {
  throw "Bundled offline Codex packages support Linux only. Remote OS: $osName"
}

$plan = Get-PackagePlan -Arch $archName
$packagePath = Join-Path $assetDir $plan.PackageName
if (-not (Test-Path -LiteralPath $packagePath)) {
  throw "Missing bundled Codex package for $archName`: $packagePath"
}

$prepare = Invoke-Ssh -PrivateKey $privateKey -Command "mkdir -p /tmp/codex-install && rm -f /tmp/codex-install/$($plan.PackageName) /tmp/codex-install/$checksumName"
if ($prepare.ExitCode -ne 0) {
  throw "Failed to prepare remote /tmp/codex-install: $($prepare.Output)"
}

Copy-ToRemote -PrivateKey $privateKey -LocalPath $packagePath -RemotePath '/tmp/codex-install/'
Copy-ToRemote -PrivateKey $privateKey -LocalPath $checksumPath -RemotePath '/tmp/codex-install/'

$remoteInstall = @"
set -e
cd /tmp/codex-install
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum -c --ignore-missing $checksumName
fi
version=$CodexVersion
target=$($plan.Target)
package=$($plan.PackageName)
layout=$($plan.Layout)
release_dir="`$HOME/.codex/packages/standalone/releases/`$version-`$target"
rm -rf "`$release_dir.tmp"
mkdir -p "`$release_dir.tmp" "`$release_dir.tmp/bin" "`$HOME/.local/bin"
tar -xzf "`$package" -C "`$release_dir.tmp"
if [ "`$layout" = "standalone-directory" ]; then
  if [ -x "`$release_dir.tmp/bin/codex" ]; then
    :
  else
    echo "Could not find bin/codex in x64 standalone package" >&2
    find "`$release_dir.tmp" -maxdepth 3 -type f >&2
    exit 1
  fi
else
  bin_path=`$(find "`$release_dir.tmp" -type f -name 'codex*' | head -n 1)
  if [ -z "`$bin_path" ]; then
    echo "Could not find codex binary in ARM64 package" >&2
    find "`$release_dir.tmp" -maxdepth 3 -type f >&2
    exit 1
  fi
  if [ "`$bin_path" != "`$release_dir.tmp/bin/codex" ]; then
    cp "`$bin_path" "`$release_dir.tmp/bin/codex"
  fi
fi
chmod 0755 "`$release_dir.tmp/bin/codex"
if [ -f "`$release_dir.tmp/codex-path/rg" ]; then chmod 0755 "`$release_dir.tmp/codex-path/rg"; fi
if [ -f "`$release_dir.tmp/codex-resources/bwrap" ]; then chmod 0755 "`$release_dir.tmp/codex-resources/bwrap"; fi
rm -rf "`$release_dir"
mv "`$release_dir.tmp" "`$release_dir"
ln -sfn "`$release_dir" "`$HOME/.codex/packages/standalone/current"
ln -sfn "`$HOME/.codex/packages/standalone/current/bin/codex" "`$HOME/.local/bin/codex"
ln -sfn "`$HOME/.local/bin/codex" /usr/local/bin/codex 2>/dev/null || true
if [ -w /usr/bin ]; then
  cp "`$HOME/.local/bin/codex" /usr/bin/codex 2>/dev/null || true
  chmod 0755 /usr/bin/codex 2>/dev/null || true
fi
touch "`$HOME/.profile" "`$HOME/.bashrc"
grep -q 'HOME/.local/bin' "`$HOME/.profile" || printf '\n# Codex CLI\nexport PATH="`$HOME/.local/bin:`$PATH"\n' >> "`$HOME/.profile"
grep -q 'HOME/.local/bin' "`$HOME/.bashrc" || printf '\n# Codex CLI\nexport PATH="`$HOME/.local/bin:`$PATH"\n' >> "`$HOME/.bashrc"
if command -v codex >/dev/null 2>&1; then codex --version; else "`$HOME/.local/bin/codex" --version; fi
"@

$installOutput = Invoke-Ssh -PrivateKey $privateKey -Command $remoteInstall -TimeoutSeconds 30
if ($installOutput.ExitCode -ne 0) {
  throw "Remote Codex CLI install failed: $($installOutput.Output)"
}

$normalVerify = Invoke-Ssh -PrivateKey $privateKey -Command 'echo ssh_ok; command -v codex; codex --version' -TimeoutSeconds 10
if ($normalVerify.ExitCode -ne 0 -or $normalVerify.Output -notmatch 'codex') {
  throw "Remote Codex CLI verification failed: $($normalVerify.Output)"
}

$probeCommand = @'
timeout 8 "$SHELL" -l -i -c 'printf "codex_probe_ok\n"; PATH="${CODEX_INSTALL_DIR:-$HOME/.local/bin}:$PATH"; export PATH; if command -v codex >/dev/null 2>&1; then command -v codex; codex --version; exit 0; fi; exit 86'
'@

$pathProbe = Invoke-Ssh -PrivateKey $privateKey -Command $probeCommand -TimeoutSeconds 15
$pathProbeFixed = $false

if (($pathProbe.ExitCode -ne 0 -or $pathProbe.Output -notmatch 'codex_probe_ok') -and -not $SkipPathProbeFix) {
  $remoteFix = @'
set -e
if [ -f /etc/profile ] && ! grep -q 'CODEX_NON_TTY_LOGIN_PROBE_FIX' /etc/profile; then
  cp -p /etc/profile /etc/profile.codex-backup-$(date +%Y%m%d%H%M%S)
  tmp=/tmp/profile.codex.$$
  cat > "$tmp" <<'EOF'
# CODEX_NON_TTY_LOGIN_PROBE_FIX
case "$-" in
  *i*)
    if [ ! -t 0 ]; then
      export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin:$PATH"
      return 0 2>/dev/null
    fi
    ;;
esac

EOF
  cat /etc/profile >> "$tmp"
  cat "$tmp" > /etc/profile
  rm -f "$tmp"
fi
if [ -n "$HOME" ]; then
  touch "$HOME/.bashrc"
  if ! grep -q 'CODEX_NON_TTY_BASHRC_FIX' "$HOME/.bashrc"; then
    cp -p "$HOME/.bashrc" "$HOME/.bashrc.codex-backup-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    tmp=/tmp/bashrc.codex.$$
    cat > "$tmp" <<'EOF'
# CODEX_NON_TTY_BASHRC_FIX
case "$-" in
  *i*)
    if [ ! -t 0 ]; then
      export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin:$PATH"
      return 0 2>/dev/null || exit 0
    fi
    ;;
esac

EOF
    cat "$HOME/.bashrc" >> "$tmp"
    cat "$tmp" > "$HOME/.bashrc"
    rm -f "$tmp"
  fi
fi
echo codex_probe_fix_applied
'@

  $fixResult = Invoke-Ssh -PrivateKey $privateKey -Command $remoteFix -TimeoutSeconds 20
  if ($fixResult.ExitCode -ne 0) {
    throw "Failed to apply Codex Desktop path-probe fix: $($fixResult.Output)"
  }
  $pathProbeFixed = $true
  $pathProbe = Invoke-Ssh -PrivateKey $privateKey -Command $probeCommand -TimeoutSeconds 15
}

if ($pathProbe.ExitCode -ne 0 -or $pathProbe.Output -notmatch 'codex_probe_ok') {
  throw "Codex Desktop path probe still failed: $($pathProbe.Output)"
}

[pscustomobject]@{
  Status = 'configured'
  HostName = $HostName
  Port = $Port
  User = $User
  RemoteOS = $osName
  RemoteArch = $archName
  CodexTarget = $plan.Target
  PrivateKeyPath = $privateKey
  PublicKeyPath = [string]$keyResult.PublicKeyPath
  KeyVerification = [string]$keyResult.Verification
  CodexInstall = 'succeeded'
  CodexVersionOutput = ($installOutput.Output)
  CodexDesktopPathProbe = 'succeeded'
  CodexDesktopPathProbeFixApplied = $pathProbeFixed
} | ConvertTo-Json -Depth 4
