# VPS Hardening Script (Ubuntu 24.04+)

Interactive bootstrap & basic hardening for a fresh Ubuntu VPS.

This project is intentionally conservative: no “magic”, no hidden steps, and no irreversible actions without explicit confirmation.  
The script focuses on predictable behavior, safe UX, and repeatable runs.

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
✅ Interactive TUI (whiptail)
Clean dialogs, confirmations, and a progress gauge (no log spam in terminal).

🔐 SSH configuration

Choose a custom SSH port

Supports ssh.socket (systemd socket activation)

Root login and password authentication are NOT disabled (by design)

🔥 Firewall (UFW)

Default: deny incoming / allow outgoing

Opens only user-selected ports

Explicit confirmation before applying changes

🛡 Fail2Ban

Enabled for SSH

Automatically configured to the selected SSH port

♻️ Stateful re-runs

Remembers ports from the previous run

Shows previous selections at the start

📊 Final runtime summary (RUNTIME STATUS)
At the end, prints:

SSH listening port(s)

Active UFW rules

Fail2Ban SSH jail port

🧩 What this script intentionally does NOT do
❌ Does NOT manage SSH keys (authorized_keys)

❌ Does NOT disable root login

❌ Does NOT disable password authentication

❌ Does NOT install application stacks (panels, proxies, 3x-ui, etc.)

These choices are intentionally left to the user as personal and security-sensitive decisions.

🗂 Logs
The script redirects detailed output into:

/var/log/vps-hardening/run-YYYYMMDD-HHMMSS.log

Terminal output stays clean and user-focused.

🖥 Supported systems
Ubuntu 24.04 LTS

Tested with:

systemd

ssh.socket enabled

fresh VPS installations

================================================================================

VPS Hardening Script (Ubuntu 24.04+)
Интерактивный скрипт начальной настройки и базового харденинга свежего Ubuntu VPS.

Проект намеренно “консервативный”: без магии, без скрытых изменений и без необратимых шагов без явного подтверждения.
Упор — на предсказуемое поведение, безопасный UX и повторяемость запусков.

🚀 Быстрый старт
Рекомендуется (скачать и запустить от root)
curl -fsSL https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh \
  -o /tmp/hardening.sh && \
chmod +x /tmp/hardening.sh && \
sudo /tmp/hardening.sh
Совет: запускай в обычной SSH-сессии. Скрипт интерактивный (whiptail) и требует TTY.

Более безопасный вариант (скачать в текущий каталог)
curl -fsSL -o hardening.sh https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh
chmod +x hardening.sh
sudo ./hardening.sh
✨ Возможности
✅ Интерактивный TUI (whiptail)
Аккуратные окна, подтверждения и индикатор прогресса (без спама логами в терминал).

🔐 Настройка SSH

Выбор пользовательского SSH-порта

Поддержка ssh.socket (systemd socket activation)

Root-доступ и парольная аутентификация НЕ отключаются (по задумке)

🔥 Firewall (UFW)

Политика: deny incoming / allow outgoing

Открываются только выбранные порты

Явное подтверждение перед применением изменений

🛡 Fail2Ban

Включается для SSH

Автоматически настраивается на выбранный SSH-порт

♻️ Повторяемые запуски (stateful)

Запоминает порты прошлого запуска

Показывает прошлые значения в начале

📊 Финальный runtime-отчёт (RUNTIME STATUS)
В конце выводится:

какие порты слушает SSH

текущие правила UFW

порт SSH в Fail2Ban

🧩 Что скрипт намеренно НЕ делает
❌ НЕ управляет SSH-ключами (authorized_keys)

❌ НЕ отключает root-доступ

❌ НЕ отключает парольную аутентификацию

❌ НЕ устанавливает прикладные сервисы (панели, прокси, 3x-ui и т.д.)

Это оставлено пользователю как персональные и чувствительные к безопасности решения.

🗂 Логи
Подробный вывод уходит в лог:

/var/log/vps-hardening/run-YYYYMMDD-HHMMSS.log

А терминал остаётся чистым и “по делу”.

🖥 Поддерживаемые системы
Ubuntu 24.04 LTS

Протестировано на:

systemd

включённом ssh.socket

свежих VPS-инсталляциях
