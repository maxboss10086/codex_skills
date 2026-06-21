---
name: ssh-key-provision
description: Configure SSH public-key login for Linux servers from Windows/Codex Desktop. Use when the user wants Codex to ask for an SSH hostname or IP, port, username, and password, then log in once with the password, install a local public key into ~/.ssh/authorized_keys, verify key-based SSH, and report the private key path to use in Codex Desktop or other SSH clients.
---

# SSH Key Provision

Use this skill to turn a working password-based SSH login into key-based SSH login for any Linux host.

## Interaction contract

If any required connection detail is missing, ask the user in chat for it before running commands:

- Hostname or IP address
- SSH port, default to `22` only if the user confirms or clearly omits it
- SSH username
- SSH password

Treat the password as a runtime secret:

- Do not write it to skill files, config files, shell history notes, or final answers.
- Use it only to create a transient `SecureString` or credential for the current command.
- Do not repeat the password back to the user.

## Preferred Windows workflow

Use `scripts/setup-authorized-key.ps1` as the primary implementation on Windows. This captures the known-good path for Codex Desktop on Windows:

1. Ensure PowerShell can import modules for this process with `Set-ExecutionPolicy -Scope Process Bypass`.
2. Prefer `Posh-SSH` for the one-time password login because Windows OpenSSH does not safely accept passwords from a normal pipe.
3. Do not spend time first trying Python/paramiko, Node/npm/ssh2, `sshpass`, or password piping unless `Posh-SSH` is unavailable and cannot be installed.
4. Install `Posh-SSH` for the current user if missing and network access is available.
5. Select an existing local key if the user did not specify one; otherwise create a host-specific ed25519 key.
6. Append the public key to the remote `~/.ssh/authorized_keys` only if it is not already present.
7. Set remote permissions: `chmod 700 ~/.ssh` and `chmod 600 ~/.ssh/authorized_keys`.
8. Verify with `ssh -o BatchMode=yes -i <private-key> -p <port> <user>@<host>`.

## Key selection

If the user gives a private key path, use it.

If no private key path is provided, choose the first existing key with a matching `.pub` file:

- `~/.ssh/id_ed25519`
- `~/.ssh/id_rsa`
- `~/.ssh/id_ecdsa`

If none exists, create a new ed25519 key named like:

`~/.ssh/codex_<host>_<port>_<user>_ed25519`

Sanitize the generated filename so it contains only letters, digits, `_`, `.`, and `-`.

## Command pattern

After receiving the user's connection details, run:

```powershell
$sec = ConvertTo-SecureString '<runtime password>' -AsPlainText -Force
.\scripts\setup-authorized-key.ps1 -HostName '<host>' -Port <port> -User '<user>' -Password $sec
```

Use the skill script path from this skill directory. If running from another working directory, call it with the absolute path.

## Final response

Report:

- Whether key-based login verification succeeded.
- The private key path the user should put in Codex Desktop's identity file field.
- The host, port, and user values to use.

Do not include the password.
