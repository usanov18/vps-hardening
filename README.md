# VPS Hardening Script

Terminal-first bootstrap and hardening for a fresh Ubuntu VPS.

> Focus: clean interactive flow, full logs on disk, predictable reruns, and safe SSH hardening with a manual checkpoint.

Full beginner guides are available in both languages:

- English: [README.en.md](README.en.md)
- Русский: [README.ru.md](README.ru.md)

Windows local helper for SSH keys:

- On Windows, `MobaXterm` and `MobaKeyGen` also work well. Copy the OpenSSH public key line into the server prompt.
- [generate-ssh-key.cmd](generate-ssh-key.cmd) is the easiest Windows launcher. Double-click it or run it from `cmd` or PowerShell.
- [generate-ssh-key.ps1](generate-ssh-key.ps1) is the underlying PowerShell script used by the launcher.

## Language

| Document | Link |
| --- | --- |
| English | [README.en.md](README.en.md) |
| Русский | [README.ru.md](README.ru.md) |

## At a Glance

| Area | Behavior |
| --- | --- |
| Terminal UX | Minimal output on screen, detailed run log in `/var/log/vps-hardening/` |
| SSH | Bootstrap on port `22`, optional migration to a new port, manual checkpoint before strict lock-down |
| Access | Optional non-root admin user with `NOPASSWD:ALL` and SSH key onboarding |
| Firewall | UFW rules are refreshed in place without wiping unrelated rules |
| Fail2Ban | Opinionated `sshd` baseline plus `recidive` jail |
| Network Tuning | Optional BBR, `fq`, larger TCP buffers, keepalive tuning, and optional `ip_forward` |

## Quick Start

```bash
curl -fsSL -o hardening.sh https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh
chmod +x hardening.sh
sudo ./hardening.sh
```

Run it from a real SSH session with a TTY.

## Core Model

- The script keeps terminal noise low and writes full details to a log file.
- SSH changes are applied in two stages: bootstrap first, lock-down only after you confirm a successful key-based login test.
- Only the public SSH key goes to the server. The private key always stays on the user's machine.
- An optional network sysctl profile can tune BBR, buffers, backlog, keepalive, and forwarding for proxy or tunnel workloads.
- Reruns are expected. Managed UFW rules are updated without a global reset.

## Scope

This repository is intentionally limited to the VPS bootstrap layer. It does not manage Terraform, cloud resources, application deployment, or reverse proxies.
