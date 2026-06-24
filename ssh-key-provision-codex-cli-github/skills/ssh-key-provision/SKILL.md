---
name: ssh-key-provision
description: Configure and repair SSH public-key login and Codex CLI for Linux servers from Windows/Codex Desktop. Use when the user wants Codex to ask for an SSH hostname or IP, port, username, and password, then log in once with the password, install a local public key into ~/.ssh/authorized_keys, verify key-based SSH, install Codex CLI from bundled offline Linux x64 or ARM64/aarch64 packages, fix Codex Desktop path-probe timeouts caused by non-TTY login shell startup files, repair stale remote app-server processes, sync local Codex API-key auth to the remote host, pin unstable codexzh DNS backends, diagnose 401 invalid token and stream disconnected errors for https://api.codexzh.com/v1/responses, and report the private key path to use in Codex Desktop or other SSH clients.
---

# SSH Key Provision

Use this skill to turn a working password-based SSH login into key-based SSH login for a Linux host, install Codex CLI offline, and verify or repair the connection shape Codex Desktop uses.

## Required inputs

If any detail is missing, ask the user for it before running commands:

- Hostname or IP address
- SSH port, default to `22` only if the user confirms or clearly omits it
- SSH username
- SSH password

Treat the password as a runtime secret:

- Do not write it to skill files, config files, logs, or final answers.
- Use it only to create a transient `SecureString` or credential for the current command.
- Do not repeat the password back to the user.

## Preferred Windows workflow

Run `scripts/setup-ssh-key-and-codex.ps1` from PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
$sec = ConvertTo-SecureString '<runtime password>' -AsPlainText -Force
& '<skill-dir>\scripts\setup-ssh-key-and-codex.ps1' -HostName '<host>' -Port 22 -User '<user>' -Password $sec
```

The script:

1. Calls `scripts/setup-authorized-key.ps1` to install or verify local public-key login.
2. Detects the remote platform with `uname -s` and `uname -m`.
3. Installs the bundled offline Codex CLI package for Linux `x86_64/amd64` or `aarch64/arm64`.
4. Symlinks or copies `codex` into locations visible to both normal SSH and Codex Desktop probes.
5. Verifies ordinary key-based SSH.
6. Verifies `codex --version`.
7. Verifies Codex Desktop's path probe shape: `$SHELL -l -i -c 'command -v codex ...'`.
8. If that path probe times out, applies a minimal non-TTY login-shell fix and verifies again.

## Post-provision repair workflow

When key-based SSH already works but Codex Desktop or the remote Codex CLI still fails, run `scripts/repair-codex-desktop-connection.ps1` from PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& '<skill-dir>\scripts\repair-codex-desktop-connection.ps1' -HostName '<host>' -Port 22 -User '<user>' -PrivateKeyPath '<private-key>'
```

This script is intentionally separate from the install script so it can repair a live host without reinstalling Codex CLI. It:

1. Verifies key-based SSH and `codex --version`.
2. Applies the same Codex Desktop non-TTY path-probe fix used by the installer.
3. Optionally copies the local Codex `auth.json` to the remote `~/.codex/auth.json`.
4. Optionally pins `api.codexzh.com` in `/etc/hosts` to a known working IP when DNS returns an unstable backend.
5. Stops stale `codex app-server`, `codex app-server proxy`, desktop websocket, and stuck probe processes so Codex Desktop reloads the fixed auth/config.
6. Runs the Codex Desktop path probe, `codex doctor`, and a small `codex exec` request.

## Bundled packages

The skill expects these offline packages in `assets/codex-install/`:

- `codex-package-x86_64-unknown-linux-musl.tar.gz`
- `codex-aarch64-unknown-linux-musl.tar.gz`
- `codex-package_SHA256SUMS`

Linux x64 package layout is the standalone directory bundle with `bin/codex`. Linux ARM64/aarch64 package layout is a single executable in the tarball. The setup script normalizes both layouts into:

- `~/.codex/packages/standalone/releases/<version>-<target>/bin/codex`
- `~/.codex/packages/standalone/current`
- `~/.local/bin/codex`
- `/usr/local/bin/codex` when allowed
- `/usr/bin/codex` when the user has permission, useful for restricted default PATHs

## Codex Desktop path-probe timeout

If PowerShell can run `ssh <host> 'codex --version'` but Codex Desktop shows:

`SSH: codex path probe timed out after 60000ms`

then SSH authentication is working. The failure is usually a remote login-shell startup issue. Some embedded Linux distributions run long-lived or background startup logic from `/etc/profile`; this can keep the non-TTY interactive login shell that Codex Desktop uses from closing.

The setup script tests the exact failure class with:

```sh
timeout 8 "$SHELL" -l -i -c 'command -v codex && codex --version'
```

When needed, it adds guarded blocks to `/etc/profile` and `~/.bashrc` that only activate for interactive shells without a real TTY. The blocks set a PATH containing Codex and return early so Codex Desktop's path probe can finish. The script backs up files before patching.

## Codex API/auth and stream errors

If the remote CLI can run `codex --version` but model requests fail, separate the failure class:

- `unexpected status 401 Unauthorized: 无效的令牌` means the remote app-server or CLI is using a stale/wrong API key. Sync the known-good local `~/.codex/auth.json` or `C:\Users\<user>\.codex\auth.json` to the remote `~/.codex/auth.json`, then restart remote app-server processes.
- `stream disconnected before completion: error sending request for url (https://api.codexzh.com/v1/responses)` can be caused by a bad DNS backend for `api.codexzh.com`. Test with `codex doctor` and a small `codex exec`; if pinning is needed, use `repair-codex-desktop-connection.ps1 -PinCodexzhIp 64.186.239.124`.
- `app-server control socket is already in use` usually means an old remote app-server is still running. Stop stale app-server/proxy processes and remove the old control socket before asking the user to toggle the Desktop SSH connection.

Do not print API keys. Fingerprints such as SHA-256 prefixes and key lengths are acceptable for comparison.

## Final response

Report:

- Whether key-based login verification succeeded.
- Whether remote Codex CLI installation and `codex --version` succeeded.
- Whether Codex Desktop path-probe verification succeeded.
- Whether Codex auth sync was performed and whether remote API-key fingerprint matches local auth.
- Whether codexzh DNS pinning was applied.
- Whether stale app-server processes were stopped.
- Whether `codex doctor` reachability and a small `codex exec` request succeeded.
- The private key path for Codex Desktop's identity file field.
- The host, port, and user values to use.

Do not include the password.
