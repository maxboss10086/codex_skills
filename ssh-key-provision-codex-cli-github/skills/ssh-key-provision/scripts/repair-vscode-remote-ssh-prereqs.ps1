param(
  [Parameter(Mandatory = $true)]
  [string]$HostName,

  [int]$Port = 22,

  [Parameter(Mandatory = $true)]
  [string]$User,

  [string]$PrivateKeyPath,

  [securestring]$Password,

  [switch]$CleanupVscodeServer
)

$ErrorActionPreference = 'Stop'

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
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [string]$Stdin
  )

  if ($PSBoundParameters.ContainsKey('Stdin')) {
    $output = $Stdin | & $FilePath @Arguments 2>&1
  } else {
    $output = & $FilePath @Arguments 2>&1
  }
  [pscustomobject]@{
    ExitCode = $LASTEXITCODE
    Output = ($output -join [Environment]::NewLine)
  }
}

function Get-SshArgs {
  $args = @(
    '-o', 'BatchMode=yes',
    '-o', 'ConnectTimeout=12',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-p', [string]$Port
  )
  if ($PrivateKeyPath) {
    $args += @('-i', $PrivateKeyPath)
  }
  $args += "$User@$HostName"
  return $args
}

$probeScript = @'
set -eu
echo "--- system ---"
uname -a
echo "--- versions ---"
(ldd --version 2>&1 || true) | head -n 4
(/lib/libc.so.6 2>&1 || true) | head -n 3
echo "--- required tools ---"
for c in ldd bash tar curl wget gzip uname sed grep awk head tail; do
  printf "%s=" "$c"
  command -v "$c" || true
done
echo "--- vscode server dirs ---"
ls -lad ~/.vscode-server* 2>/dev/null || true
'@

$installScript = @'
set -eu
if [ ! -x /lib/ld-linux-x86-64.so.2 ]; then
  echo "missing /lib/ld-linux-x86-64.so.2; this repair only supports glibc x86_64 systems" >&2
  exit 2
fi
if [ ! -x /lib/libc.so.6 ]; then
  echo "missing /lib/libc.so.6; this repair only supports glibc systems" >&2
  exit 2
fi

cat > /tmp/ldd.codex <<'EOF'
#!/bin/sh
RTLD="${RTLDLIST:-/lib/ld-linux-x86-64.so.2}"
LIBC="/lib/libc.so.6"

libc_version() {
  if [ -x "$LIBC" ]; then
    "$LIBC" 2>&1 | sed -n '1s/.*version \([0-9][0-9.]*\).*/\1/p;1q' | sed 's/\.$//'
  fi
}

case "${1:-}" in
  --version)
    ver=$(libc_version)
    [ -n "$ver" ] || ver=unknown
    echo "ldd (GNU libc) $ver"
    if [ -x "$LIBC" ]; then
      "$LIBC" 2>&1 | sed -n '2,4p'
    fi
    exit 0
    ;;
  --help|-h)
    echo "Usage: ldd [OPTION]... FILE..."
    echo "      --version  print version information"
    exit 0
    ;;
esac

if [ "$#" -eq 0 ]; then
  echo "ldd: missing file arguments" >&2
  exit 1
fi

status=0
for file in "$@"; do
  case "$file" in
    --*) continue ;;
  esac
  if [ ! -e "$file" ]; then
    echo "ldd: $file: No such file or directory" >&2
    status=1
    continue
  fi
  "$RTLD" --list "$file" || status=$?
done
exit "$status"
EOF
chmod 755 /tmp/ldd.codex

if sudo -n true 2>/dev/null; then
  sudo install -m 755 /tmp/ldd.codex /usr/bin/ldd
else
  if [ -z "${CODEX_SUDO_PASSWORD:-}" ]; then
    echo "sudo password is required to install /usr/bin/ldd" >&2
    exit 3
  fi
  printf '%s\n' "$CODEX_SUDO_PASSWORD" | sudo -S -p '' install -m 755 /tmp/ldd.codex /usr/bin/ldd
fi
rm -f /tmp/ldd.codex

if [ "${CODEX_CLEANUP_VSCODE_SERVER:-0}" = "1" ] && [ -d "$HOME/.vscode-server" ]; then
  mv "$HOME/.vscode-server" "$HOME/.vscode-server.failed.$(date +%Y%m%d%H%M%S)"
fi

echo "--- repaired ldd ---"
ldd --version | head -n 1
ldd /bin/sh | head -n 5
'@

$sshArgs = Get-SshArgs
$probe = Invoke-Native 'ssh.exe' ($sshArgs + @('sh', '-s')) -Stdin $probeScript
if ($probe.ExitCode -ne 0) {
  throw "Remote probe failed: $($probe.Output)"
}

$plainPassword = $null
try {
  if ($Password) {
    $plainPassword = ConvertTo-PlainText $Password
  }

  $remotePrefix = ''
  if ($plainPassword) {
    $escaped = $plainPassword.Replace("'", "'\''")
    $remotePrefix += "CODEX_SUDO_PASSWORD='$escaped' "
  }
  if ($CleanupVscodeServer) {
    $remotePrefix += "CODEX_CLEANUP_VSCODE_SERVER=1 "
  }

  $repair = Invoke-Native 'ssh.exe' ($sshArgs + @("$remotePrefix" + 'sh', '-s')) -Stdin $installScript
  if ($repair.ExitCode -ne 0) {
    throw "Remote repair failed: $($repair.Output)"
  }

  [pscustomobject]@{
    HostName = $HostName
    Port = $Port
    User = $User
    Probe = $probe.Output
    Repair = $repair.Output
  } | ConvertTo-Json -Depth 4
} finally {
  $plainPassword = $null
}
