# VPS Hardening Script (Ubuntu 24+)

Interactive bootstrap & hardening script for a fresh Ubuntu VPS.

Designed for **clarity, safety, and repeatability**, with a focus on DevOps best practices and predictable behavior.

---

## 🚀 Quick start

Recommended way (download first, then run as root):

```bash
curl -fsSL https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh \
  -o /tmp/hardening.sh && \
chmod +x /tmp/hardening.sh && \
sudo /tmp/hardening.sh
Tip: run in a normal SSH session. The script is interactive (whiptail) and requires a TTY.

Safer alternative (download to current directory):

curl -fsSL -o hardening.sh https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh
chmod +x hardening.sh
sudo ./hardening.sh
✨ Features
✅ Interactive TUI (whiptail)
Dialogs, confirmations, predictable UX

🔐 SSH hardening

Custom SSH port selection

Supports ssh.socket (systemd socket activation)

Root login and password authentication are NOT disabled

🔥 Firewall (UFW)

Default deny incoming

Opens only selected ports

Explicit warning before rule reset

🛡 Fail2Ban

Enabled for SSH

Automatically uses selected SSH port

♻️ Stateful behavior

Remembers ports from previous run

Shows previous selections on re-run

🧾 Final runtime status

SSH listening port(s)

Allowed UFW rules

Fail2Ban sshd port

🧩 What this script intentionally does NOT do
❌ Does NOT manage SSH keys (authorized_keys)

❌ Does NOT disable root login

❌ Does NOT disable password authentication

❌ Does NOT install application stacks (e.g. 3x-ui)

These decisions are left to the user as security-sensitive choices.

🖥 Supported systems
Ubuntu 24.04 LTS

Fresh VPS installations

systemd + ssh.socket

================================================================================

VPS Hardening Script (Ubuntu 24+)
Интерактивный скрипт начальной настройки и базового харденинга свежего Ubuntu VPS.

Разработан с упором на прозрачность, безопасность и повторяемость, в стиле DevOps-практик и предсказуемого поведения.

🚀 Быстрый старт
Рекомендуемый способ (сначала скачать, затем запускать от root):

curl -fsSL https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh \
  -o /tmp/hardening.sh && \
chmod +x /tmp/hardening.sh && \
sudo /tmp/hardening.sh
Совет: запускайте в обычной SSH-сессии. Скрипт интерактивный (whiptail) и требует TTY.

Альтернатива (скачать в текущую директорию):

curl -fsSL -o hardening.sh https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh
chmod +x hardening.sh
sudo ./hardening.sh
✨ Возможности
✅ Интерактивный TUI (whiptail)
Диалоги, подтверждения, предсказуемый UX

🔐 Настройка SSH

Выбор пользовательского SSH-порта

Поддержка ssh.socket (systemd socket activation)

Root-доступ и парольный вход НЕ отключаются

🔥 Firewall (UFW)

Политика deny incoming

Открываются только выбранные порты

Явное предупреждение перед сбросом правил

🛡 Fail2Ban

Включён для SSH

Автоматически использует выбранный SSH-порт

♻️ Stateful-поведение

Запоминает порты прошлого запуска

Показывает прошлый выбор при повторном запуске

🧾 Финальный runtime-статус

Слушаемый порт SSH

Активные правила UFW

Порт Fail2Ban (sshd)

🧩 Что скрипт намеренно НЕ делает
❌ Не управляет SSH-ключами (authorized_keys)

❌ Не отключает root-доступ

❌ Не отключает парольную аутентификацию

❌ Не устанавливает прикладные сервисы (например, 3x-ui)

Эти решения оставлены пользователю как чувствительные к безопасности.

🖥 Поддерживаемые системы
Ubuntu 24.04 LTS

Свежие VPS-установки

systemd и ssh.socket
