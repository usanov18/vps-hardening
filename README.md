# VPS Hardening Script (Ubuntu 24+)

Interactive bootstrap & hardening script for a fresh VPS.  

## 🚀 Quick start

Run on a fresh Ubuntu VPS (recommended: review before running):

```bash
curl -fsSL https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh | sudo bash
Safer (download first):

bash
Копировать код
curl -fsSL -o hardening.sh https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh
chmod +x hardening.sh
sudo bash ./hardening.sh
ℹ️ Notes

Run as root or via sudo

The script is interactive (uses whiptail)

Re-running the script is supported and safe (previous choices are remembered)

Designed for clarity, safety, and repeatability, with a focus on DevOps best practices.

✨ Features
✅ Interactive TUI (whiptail)
Clean dialog windows, confirmations, and progress gauge

🔐 SSH hardening

Choose custom SSH port

Supports ssh.socket (systemd socket activation)

No unsafe assumptions (root login and password auth are NOT disabled)

🔥 Firewall (UFW)

Default deny incoming

Opens only selected ports

Explicit warning before rules reset

🛡 Fail2Ban

Enabled for SSH

Automatically uses selected SSH port

♻️ Stateful

Remembers ports from previous run

Shows previous selections on next execution

🧠 Safe by design

No hacks

No hidden changes

Explicit checkpoints before irreversible steps

🧩 What this script intentionally does NOT do
❌ Does NOT manage SSH keys (authorized_keys)

❌ Does NOT disable root login

❌ Does NOT disable password authentication

❌ Does NOT install application stacks (e.g. 3x-ui)

These decisions are left to the user as personal / security-sensitive choices.

🖥 Supported systems
Ubuntu 24.04 LTS

Tested with:

systemd

ssh.socket enabled

fresh VPS installations

================================================================================

VPS Hardening Script (Ubuntu 24+)
Интерактивный скрипт начальной настройки и базового харденинга VPS.
Разработан с упором на прозрачность, безопасность и повторяемость, в стиле DevOps-практик.

🚀 Быстрый запуск
Рекомендуемый способ (сразу выполнить):

bash
Копировать код
curl -fsSL https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh | sudo bash
Более безопасный вариант (скачать и проверить):

bash
Копировать код
curl -fsSL -o hardening.sh https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh
chmod +x hardening.sh
sudo bash ./hardening.sh
ℹ️ Важно

Запускать от root или через sudo

Скрипт интерактивный (whiptail)

Повторный запуск поддерживается и безопасен

✨ Возможности
✅ Интерактивный TUI-интерфейс (whiptail)
Диалоговые окна, подтверждения и индикатор прогресса

🔐 Настройка SSH

Выбор пользовательского SSH-порта

Поддержка ssh.socket (systemd socket activation)

Без опасных допущений (root-доступ и парольный вход НЕ отключаются)

🔥 Firewall (UFW)

Политика deny incoming / allow outgoing

Открываются только выбранные порты

Явное предупреждение перед сбросом правил

🛡 Fail2Ban

Включён для SSH

Автоматически использует выбранный SSH-порт

♻️ Stateful-поведение

Запоминает порты из прошлого запуска

Показывает прошлый выбор при повторном запуске

🧠 Безопасная архитектура

Без хаков

Без скрытых изменений

Контрольные точки перед необратимыми шагами

🧩 Что скрипт намеренно НЕ делает
❌ НЕ управляет SSH-ключами (authorized_keys)

❌ НЕ отключает root-доступ

❌ НЕ отключает парольную аутентификацию

❌ НЕ устанавливает прикладные сервисы (например, 3x-ui)

Эти действия оставлены пользователю как персональные и чувствительные к безопасности решения.

🖥 Поддерживаемые системы
Ubuntu 24.04 LTS

Протестировано на:

systemd

включённом ssh.socket

свежих VPS-инсталляциях
