param(
  [Parameter(Mandatory = $true)]
  [string]$HostName,

  [int]$Port = 22,

  [Parameter(Mandatory = $true)]
  [string]$User,

  [Parameter(Mandatory = $true)]
  [string]$PrivateKeyPath,

  [string]$LocalAuthPath = "$env:USERPROFILE\.codex\auth.json",

  [string]$RemoteCodexHome = '',

  [string]$PinCodexzhIp = '',

  [switch]$SkipAuthSync,

  [switch]$SkipCodexzhPin,

  [switch]$SkipAppServerRestart
)

$ErrorActionPreference = 'Stop'

function Invoke-Native {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [switch]$AllowFailure
  )

  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $FilePath @Arguments 2>&1
    $exit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  $text = ($output -join [Environment]::NewLine)
  if ($exit -ne 0 -and -not $AllowFailure) {
    throw "$FilePath failed with exit $exit`n$text"
  }
  [pscustomobject]@{
    ExitCode = $exit
    Output = $text
    Lines = @($output)
  }
}

function Invoke-Ssh {
  param(
    [Parameter(Mandatory = $true)][string]$Command,
    [int]$TimeoutSeconds = 20,
    [switch]$AllowFailure
  )

  Invoke-Native 'ssh.exe' @(
    '-o', 'BatchMode=yes',
    '-o', "ConnectTimeout=$TimeoutSeconds",
    '-i', $PrivateKeyPath,
    '-p', [string]$Port,
    "$User@$HostName",
    $Command
  ) -AllowFailure:$AllowFailure
}

function Invoke-RemoteScript {
  param(
    [Parameter(Mandatory = $true)][string]$Script,
    [int]$TimeoutSeconds = 30,
    [switch]$AllowFailure
  )

  $tmp = [IO.Path]::GetTempFileName()
  $remotePath = "/tmp/codex-repair-$([Guid]::NewGuid().ToString('N')).sh"
  try {
    $normalized = $Script -replace "`r`n", "`n"
    [IO.File]::WriteAllText($tmp, $normalized, [Text.UTF8Encoding]::new($false))
    $copy = Invoke-Native 'scp.exe' @(
      '-q',
      '-P', [string]$Port,
      '-i', $PrivateKeyPath,
      $tmp,
      "${User}@${HostName}:$remotePath"
    ) -AllowFailure:$AllowFailure
    if ($copy.ExitCode -ne 0) {
      return $copy
    }
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $output = & ssh.exe -o BatchMode=yes -o "ConnectTimeout=$TimeoutSeconds" -i $PrivateKeyPath -p $Port "$User@$HostName" "bash '$remotePath'; rc=`$?; rm -f '$remotePath'; exit `$rc" 2>&1
      $exit = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $previousErrorActionPreference
    }
    $text = ($output -join [Environment]::NewLine)
    if ($exit -ne 0 -and -not $AllowFailure) {
      throw "remote script failed with exit $exit`n$text"
    }
    [pscustomobject]@{
      ExitCode = $exit
      Output = $text
      Lines = @($output)
    }
  } finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
}

function Get-AuthFingerprint {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  $json = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
  $key = $json.OPENAI_API_KEY
  if (-not $key) {
    return $null
  }

  $hash = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($key))
  $hex = ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
  [pscustomobject]@{
    Length = $key.Length
    Sha256Prefix = $hex.Substring(0, 12)
  }
}

function Write-Section {
  param([Parameter(Mandatory = $true)][string]$Title)
  Write-Host ""
  Write-Host "== $Title =="
}

if (-not (Test-Path -LiteralPath $PrivateKeyPath)) {
  throw "Private key does not exist: $PrivateKeyPath"
}

Write-Section 'SSH and Codex basics'
$basic = Invoke-Ssh 'echo ssh_ok; echo "HOME=$HOME"; hostname; whoami; command -v codex || true; codex --version 2>/dev/null || true'
Write-Host $basic.Output

if (-not $RemoteCodexHome) {
  $remoteHome = Invoke-Ssh 'printf "%s/.codex" "$HOME"'
  $RemoteCodexHome = $remoteHome.Output.Trim()
}

if (-not $SkipAuthSync) {
  Write-Section 'Codex auth sync'
  $localFp = Get-AuthFingerprint -Path $LocalAuthPath
  if (-not $localFp) {
    Write-Warning "No local OPENAI_API_KEY found at $LocalAuthPath; skipping auth sync."
  } else {
    Invoke-Ssh "mkdir -p '$RemoteCodexHome'"
    Invoke-Native 'scp.exe' @(
      '-q',
      '-P', [string]$Port,
      '-i', $PrivateKeyPath,
      $LocalAuthPath,
      "${User}@${HostName}:$RemoteCodexHome/auth.json"
    )
    Invoke-Ssh "chmod 600 '$RemoteCodexHome/auth.json'"
    Write-Host "local auth key: len=$($localFp.Length) sha256[0:12]=$($localFp.Sha256Prefix)"
    $remoteFp = Invoke-Ssh "python3 - <<'PY'
import json, hashlib
p='$RemoteCodexHome/auth.json'
d=json.load(open(p))
k=d.get('OPENAI_API_KEY') or d.get('openai_api_key') or d.get('api_key')
print('remote auth key: len=%s sha256[0:12]=%s' % (len(k) if k else 0, hashlib.sha256(k.encode()).hexdigest()[:12] if k else 'none'))
PY" -AllowFailure
    Write-Host $remoteFp.Output
  }
}

Write-Section 'Codex Desktop path probe fix'
$profileFix = @'
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
  echo profile_fix_added
else
  echo profile_fix_present
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
    echo bashrc_fix_added
  else
    echo bashrc_fix_present
  fi
fi
'@
Write-Host (Invoke-RemoteScript $profileFix).Output

if (-not $SkipCodexzhPin -and $PinCodexzhIp) {
  Write-Section 'codexzh DNS pin'
  $hostsScript = @"
set -e
if ! grep -q '$PinCodexzhIp api.codexzh.com' /etc/hosts 2>/dev/null; then
  cp -p /etc/hosts /etc/hosts.codex-backup-`$(date +%Y%m%d%H%M%S) 2>/dev/null || true
  grep -v 'api.codexzh.com' /etc/hosts > /tmp/hosts.codex
  printf '$PinCodexzhIp api.codexzh.com\n' >> /tmp/hosts.codex
  cat /tmp/hosts.codex > /etc/hosts
  rm -f /tmp/hosts.codex
fi
grep 'api.codexzh.com' /etc/hosts
getent ahostsv4 api.codexzh.com | head -3
"@
  Write-Host (Invoke-RemoteScript $hostsScript).Output
}

if (-not $SkipAppServerRestart) {
  Write-Section 'remote app-server restart'
  $restartScript = @'
pids=$(ps -eo pid,args | awk '/codex app-server|codex app-server proxy|desktop-ssh-websocket|bash -l -i -c printf codex_probe_ok/ && !/awk/ {print $1}')
for p in $pids; do
  echo "TERM $p"
  kill -TERM "$p" 2>/dev/null || true
done
sleep 2
for p in $pids; do
  if [ -d "/proc/$p" ]; then
    echo "KILL $p"
    kill -KILL "$p" 2>/dev/null || true
  fi
done
rm -f "$HOME/.codex/app-server-control/app-server-control.sock" "$HOME/.codex/app-server-daemon/app-server.pid" 2>/dev/null || true
ps -eo pid,ppid,stat,comm,args | grep -E '[c]odex app-server|[c]odex app-server proxy|[d]esktop-ssh-websocket|[b]ash -l -i -c printf' || true
'@
  Write-Host (Invoke-RemoteScript $restartScript -AllowFailure).Output
}

Write-Section 'Codex Desktop path probe verification'
$probeScript = @'
timeout 8 "$SHELL" -l -i -c 'printf "codex_probe_ok\n"; PATH="${CODEX_INSTALL_DIR:-$HOME/.local/bin}:$PATH"; export PATH; command -v codex; codex --version'
'@
$probe = Invoke-RemoteScript $probeScript -TimeoutSeconds 15 -AllowFailure
Write-Host $probe.Output

Write-Section 'Codex request verification'
$execScript = @'
printf 'reply pong only\n' | timeout 90 codex exec --skip-git-repo-check - 2>&1 | sed -n '1,180p'
echo "codex_exec_exit:$?"
'@
$exec = Invoke-RemoteScript $execScript -TimeoutSeconds 120 -AllowFailure
Write-Host $exec.Output

Write-Section 'Doctor connectivity summary'
$doctor = Invoke-Ssh 'codex doctor 2>&1 | sed -n "1,220p"' -TimeoutSeconds 40 -AllowFailure
Write-Host $doctor.Output

[pscustomobject]@{
  Status = 'repair_attempted'
  HostName = $HostName
  Port = $Port
  User = $User
  PrivateKeyPath = $PrivateKeyPath
  RemoteCodexHome = $RemoteCodexHome
  AuthSync = (-not $SkipAuthSync -and [bool](Get-AuthFingerprint -Path $LocalAuthPath))
  CodexzhPinnedTo = if (-not $SkipCodexzhPin) { $PinCodexzhIp } else { '' }
  AppServerRestarted = (-not $SkipAppServerRestart)
  PathProbeExitCode = $probe.ExitCode
  CodexExecExitCode = $exec.ExitCode
} | ConvertTo-Json -Depth 3
