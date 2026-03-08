# VPS Hardening Script

Terminal-first bootstrap and hardening for a fresh Ubuntu VPS.

## Who This Is For

This repository is for people who have a new VPS and want one script to handle the first hardening pass without a noisy TUI and without turning the setup into Terraform or Ansible.

It is especially useful when you want to:

- move SSH to a different port safely
- create a normal admin user with key-based access
- lock down `root` and password login only after you confirm the new login path works
- apply a stricter UFW and Fail2Ban baseline
- enable an optional network tuning profile for proxy, tunnel, and high-throughput workloads

## What The Script Does

| Area | Behavior |
| --- | --- |
| Terminal UX | Shows only the current step, prompts, warnings, and final status |
| Logging | Writes the full run transcript to `/var/log/vps-hardening/run-YYYYMMDD-HHMMSS.log` |
| SSH | Supports bootstrap on `22`, optional move to a chosen port, and strict lock-down after confirmation |
| Admin Access | Can prepare a dedicated non-root admin user with `NOPASSWD:ALL` |
| Firewall | Updates managed UFW rules in place without deleting unrelated rules |
| Fail2Ban | Installs a stronger `sshd` baseline and enables `recidive` |
| Network Tuning | Can apply BBR, `fq`, larger buffers, backlog tuning, keepalive tuning, `tcp_fastopen`, `tcp_mtu_probing`, and optional `ip_forward` |

## Before You Start

Use this checklist before the first run:

1. Start with a fresh Ubuntu VPS.
2. Keep your provider console, VNC, Lish, or rescue access available.
3. Connect to the server as `root` first.
4. Make sure you have an SSH key pair on your own computer, or be ready to create one.
5. Do not close your original SSH session until the script finishes and you verify the new login path.

## SSH Keys Explained Simply

You need to understand one thing before using the script:

- the **private key** stays on your own computer
- the **public key** goes to the server

The script only wants the **public key**. Never paste a private key into the script.

Typical local paths:

- Linux or macOS private key: `~/.ssh/id_ed25519`
- Linux or macOS public key: `~/.ssh/id_ed25519.pub`
- Windows private key: `%USERPROFILE%\.ssh\id_ed25519`
- Windows public key: `%USERPROFILE%\.ssh\id_ed25519.pub`

If you use `MobaXterm`, `MobaKeyGen` is also fine. Generate the key there, keep the private key on your PC, and copy the OpenSSH public key line from the generator window into the server prompt.

If you do not have a key yet, create one on your own machine:

```bash
ssh-keygen -t ed25519 -C "<label>"
```

If you are on Windows and do not want to use `MobaXterm`, this repository also includes:

```powershell
.\generate-ssh-key.cmd
```

That helper can:

- generate a new key pair in `%USERPROFILE%\.ssh`
- create a `.pub.txt` copy next to the key for easy copy-paste
- export `.pub` and `.pub.txt` from an existing private key

Example for an existing private key:

```powershell
.\generate-ssh-key.cmd -FromExistingPrivateKey "$env:USERPROFILE\.ssh\535c801bbc" -Overwrite
```

If you prefer to run PowerShell directly, you can still use `.\generate-ssh-key.ps1`, but `.\generate-ssh-key.cmd` is the easier option for beginners because the window stays open until you press Enter.

## Quick Start

```bash
curl -fsSL -o hardening.sh https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh
chmod +x hardening.sh
sudo ./hardening.sh
```

Run it from a real SSH session with a TTY.

## First Run For Beginners

### 1. Connect to the server

From your local machine:

```bash
ssh root@YOUR_SERVER_IP
```

If your provider gave you a password, use that for the first login.

### 2. Download the script on the server

```bash
curl -fsSL -o hardening.sh https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh
chmod +x hardening.sh
```

### 3. Run it as root

```bash
sudo ./hardening.sh
```

If you are on Windows and still need an SSH key before step 4, you have two normal options on your own computer:

1. Use `MobaXterm` / `MobaKeyGen`, then copy the OpenSSH public key line.
2. Use the local helper below:

```powershell
.\generate-ssh-key.cmd
```

Then open the generated `.pub.txt` file from `%USERPROFILE%\.ssh` and paste its contents into the server prompt.

### 4. Answer the prompts

The script will ask about the following:

| Prompt | What it means | Typical beginner choice |
| --- | --- | --- |
| `SSH port` | The port SSH should use | Choose a port you will remember |
| `Extra TCP ports` | Extra allowed TCP ports in UFW | Open only what you really need |
| `Extra UDP ports` | Extra allowed UDP ports in UFW | Leave blank if you do not need UDP |
| `Prepare a dedicated admin user` | Create a normal user with passwordless sudo | Usually `yes` |
| `Copy keys from /root` | Reuse existing root public keys | Usually `yes` if root already has the right key |
| `Paste an extra SSH public key` | Add another public key line | Use this if you want a different key for the admin user |
| `Disable root login and password auth after a successful test` | Stronger SSH lock-down | Usually `yes`, but only if key login is ready |
| `Apply network tuning baseline` | Enable the network sysctl profile | Usually `yes` for proxy, panel, tunnel, or busy servers |
| `Enable IPv4 forwarding` | Turn on `net.ipv4.ip_forward` | Usually `yes` for tunnel/proxy workloads, otherwise `no` |

### 5. Perform the SSH checkpoint carefully

When the script reaches the SSH checkpoint:

1. keep the current SSH session open
2. open a second terminal window
3. run the exact SSH command shown by the script
4. make sure the new login really works
5. only then confirm the checkpoint

This is the safety step that prevents locking yourself out.

## What The Network Tuning Module Adds

The integrated network profile comes from the standalone sysctl logic you shared, but it is now part of the main script and uses neutral naming.

When enabled, it writes:

```text
/etc/sysctl.d/99-vps-hardening-net.conf
```

It applies:

- `net.core.default_qdisc = fq`
- `net.ipv4.tcp_congestion_control = bbr`
- larger TCP receive and send buffers
- larger backlog and accept queue settings
- `tcp_fastopen`
- `tcp_mtu_probing`
- `tcp_slow_start_after_idle = 0`
- TCP keepalive tuning
- `tcp_retries2 = 12`
- optional `net.ipv4.ip_forward = 1`

Before applying, the script backs up common existing sysctl files, including older custom tuning files, into:

```text
/etc/vps-hardening/sysctl-backups/<timestamp>/
```

It also stores the previous live sysctl values in:

```text
/etc/vps-hardening/network-sysctl-baseline.conf
```

If you later disable this module, the managed profile file is removed and those baseline runtime values are restored.

## What Happens During The Run

The script follows this order:

1. system update and package install
2. admin user creation and SSH key preparation
3. SSH bootstrap on port `22` plus the selected new port
4. manual SSH checkpoint in a second session
5. final SSH lock-down, if confirmed
6. UFW rules and ICMP baseline
7. Fail2Ban setup
8. optional network tuning profile
9. final summary on screen and detailed log on disk

## After The Run

If you changed SSH to a new port and created an admin user called `deploy`, the next login will usually look like this:

```bash
ssh -p 2222 deploy@YOUR_SERVER_IP
```

If you use a specific private key:

```bash
ssh -i ~/.ssh/id_ed25519 -p 2222 deploy@YOUR_SERVER_IP
```

Do not close the old root session until the new one works.

## Rerun Behavior

The script is designed to be rerun.

Important behavior:

- press `Enter` to keep current TCP or UDP port lists
- type `none` to clear a saved TCP or UDP list
- if the selected SSH port is already the active SSH port, the script reuses it without another confirmation prompt
- managed UFW rules are refreshed without wiping unrelated UFW rules

## Files Written

During a normal run, the script may create or update:

- `/etc/vps-hardening/last-config.conf`
- `/var/log/vps-hardening/run-YYYYMMDD-HHMMSS.log`
- `/etc/ssh/sshd_config.d/90-vps-hardening.conf`
- `/etc/systemd/system/ssh.socket.d/override.conf` when socket activation is used
- `/etc/fail2ban/jail.d/10-vps-hardening.local`
- `/etc/sysctl.d/99-vps-hardening-net.conf` when network tuning is enabled
- `/etc/sudoers.d/90-vps-hardening-<user>` when an admin user is created

## Scope

This repository intentionally stops at the VPS bootstrap layer.

It does not manage:

- Terraform
- cloud resources
- application deployment
- reverse proxies
- panel installation beyond opening the ports you choose
