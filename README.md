# VPS Hardening Script (Ubuntu 24+)

Interactive bootstrap & hardening script for a fresh Ubuntu VPS.

Designed for **clarity, safety, and repeatability**, with a focus on DevOps best practices and predictable behavior.

---

## 🚀 Quick start

### Recommended (download first, then run as root)

```bash
curl -fsSL https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh \
  -o /tmp/hardening.sh && \
chmod +x /tmp/hardening.sh && \
sudo /tmp/hardening.sh
Tip: run in a normal SSH session. The script is interactive (whiptail) and requires a TTY.

Safer alternative (download to current directory)
curl -fsSL -o hardening.sh https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh
chmod +x hardening.sh
sudo ./hardening.sh
✨ Features
✅ Interactive TUI (whiptail) — dialogs, confirmations, predictable UX

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

🧩 What this script intentionally does NOT do
❌ Does NOT manage SSH keys (authorized_keys)

❌ Does NOT disable root login

❌ Does NOT disable password authentication

❌ Does NOT install application stacks (e.g. 3x-ui, panels, proxies)

These decisions are left to the user as personal and security-sensitive choices.

🖥 Supported systems
Ubuntu 24.04 LTS

Tested with:

systemd

ssh.socket enabled

fresh VPS installations

================================================================================

VPS Hardening Script (Ubuntu 24+)
Интерактивный скрипт начальной настройки и базового харденига свежего Ubuntu VPS.

Разработан с упором на прозрачность, безопасность и повторяемость, в стиле аккуратных DevOps-практик и предсказуемого поведения.

Скрипт намеренно консервативен: без хаков, без скрытых изменений и без необратимых шагов без подтверждения.

🚀 Быстрый старт
Рекомендуемый способ (скачать и запустить от root)
curl -fsSL https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh \
  -o /tmp/hardening.sh && \
chmod +x /tmp/hardening.sh && \
sudo /tmp/hardening.sh
Совет: запускайте в обычной SSH-сессии. Скрипт интерактивный (whiptail) и требует TTY.

Более безопасный вариант (скачать в текущий каталог)
curl -fsSL -o hardening.sh https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh
chmod +x hardening.sh
sudo ./hardening.sh
✨ Возможности
✅ Интерактивный TUI (whiptail) — диалоги, подтверждения, предсказуемый UX

🔐 Настройка SSH

Выбор пользовательского SSH-порта

Поддержка ssh.socket (systemd socket activation)

Root-доступ и парольная аутентификация НЕ отключаются

🔥 Firewall (UFW)

Политика: deny incoming / allow outgoing

Открываются только выбранные порты

Явное подтверждение перед применением правил

🛡 Fail2Ban

Включён для SSH

Автоматически использует выбранный SSH-порт

♻️ Stateful-поведение

Запоминает порты предыдущего запуска

Показывает прошлые значения при повторном запуске

📊 Финальный runtime-отчёт

Активные SSH-порты

Текущие правила UFW

Порт SSH в Fail2Ban

🧩 Что скрипт намеренно НЕ делает
❌ НЕ управляет SSH-ключами (authorized_keys)

❌ НЕ отключает root-доступ

❌ НЕ отключает парольную аутентификацию

❌ НЕ устанавливает прикладные сервисы (панели, прокси и т.д.)

Эти действия оставлены пользователю как персональные и чувствительные к безопасности решения.

🖥 Поддерживаемые системы
Ubuntu 24.04 LTS

Протестировано на:

systemd

включённом ssh.socket

свежих VPS-инсталляциях
