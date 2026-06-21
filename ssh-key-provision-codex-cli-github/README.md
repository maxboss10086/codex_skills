# SSH Key Provision + Codex CLI Skill

This repository contains a Codex skill that:

1. Asks for Linux SSH connection details.
2. Uses a one-time password login to install the local public key.
3. Verifies SSH key login.
4. Installs Codex CLI on the remote Linux x64 host using the bundled offline package.

## Install on a New Computer

Upload this repository to GitHub, then ask Codex on the new computer to install:

```text
https://github.com/<your-user>/<your-repo>/tree/main/skills/ssh-key-provision
```

Restart Codex Desktop after installation.

## Use

Ask Codex:

```text
Use $ssh-key-provision to configure SSH key login and install Codex CLI for a Linux server.
```

Codex will ask for:

- Hostname or IP
- SSH port
- SSH username
- SSH password

## Bundled Codex CLI Package

The skill includes the Linux x64 Codex CLI standalone package:

```text
skills/ssh-key-provision/assets/codex-install/codex-package-x86_64-unknown-linux-musl.tar.gz
skills/ssh-key-provision/assets/codex-install/codex-package_SHA256SUMS
skills/ssh-key-provision/assets/codex-install/install.sh
```

Do not commit passwords, private keys, or machine-specific secrets to this repository.
