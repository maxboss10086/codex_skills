# SSH Key Provision Skill

This repository contains a Codex skill for configuring SSH public-key login on Linux servers from Windows/Codex Desktop.

## Install on a New Computer

Upload this repository to GitHub, then ask Codex on the new computer to install the skill from:

```text
https://github.com/<your-user>/<your-repo>/tree/main/skills/ssh-key-provision
```

For example:

```text
Install this Codex skill:
https://github.com/<your-user>/<your-repo>/tree/main/skills/ssh-key-provision
```

Restart Codex Desktop after installation.

## Use

Ask Codex:

```text
Use $ssh-key-provision to configure SSH key login for a Linux server.
```

Codex will ask for:

- Hostname or IP
- SSH port
- SSH username
- SSH password

The password is used only for the one-time login needed to install the public key. Do not commit passwords, private keys, or machine-specific secrets to this repository.
