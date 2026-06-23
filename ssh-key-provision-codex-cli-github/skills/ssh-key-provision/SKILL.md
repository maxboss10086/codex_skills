---
name: ssh-key-provision
description: Configure SSH public-key login and Codex CLI for Linux servers from Windows/Codex Desktop. Use when the user wants Codex to ask for an SSH hostname or IP, port, username, and password, then log in once with the password, install a local public key into ~/.ssh/authorized_keys, verify key-based SSH, install Codex CLI from bundled offline Linux x64 or ARM64/aarch64 packages, fix Codex Desktop path-probe timeouts caused by non-TTY login shell startup files, and report the private key path to use in Codex Desktop or other SSH clients.
---

# SSH Key Provision

Use this skill to turn a working password-based SSH login into key-based SSH login for a Linux host, install Codex CLI offline, and verify the connection shape Codex Desktop uses.

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

## Final response

Report:

- Whether key-based login verification succeeded.
- Whether remote Codex CLI installation and `codex --version` succeeded.
- Whether Codex Desktop path-probe verification succeeded.
- The private key path for Codex Desktop's identity file field.
- The host, port, and user values to use.

Do not include the password.
