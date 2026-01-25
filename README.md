```bash
curl -fsSL https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh \
  -o /tmp/hardening.sh && \
chmod +x /tmp/hardening.sh && \
sudo /tmp/hardening.sh
Tip: run in a normal SSH session.
The script is interactive (whiptail) and requires a TTY.

Safer alternative (download to current directory)
curl -fsSL -o hardening.sh https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh
chmod +x hardening.sh
sudo ./hardening.sh
✨ Features
✅ Interactive TUI (whiptail)
Dialog windows, confirmations, predictable UX

🔐 SSH hardening
Custom SSH port selection

Supports ssh.socket (systemd socket activation)

Root login and password authentication are NOT disabled

🔥 Firewall (UFW)
Default: deny incoming / allow outgoing

Opens only user-selected ports

Explicit confirmation before applying rules

🛡 Fail2Ban
Enabled for SSH

Automatically configured to the selected SSH port

♻️ Stateful behavior
Remembers ports from the previous run

Shows previous selections on re-run

📊 Final runtime summary
SSH listening port(s)

Active UFW rules

Fail2Ban SSH jail port
