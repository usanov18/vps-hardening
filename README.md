# VPS Hardening Script (Ubuntu 24+)

Interactive bootstrap & hardening script for a fresh VPS.

Designed for **clarity, safety, and repeatability**, with a strong focus on DevOps best practices and predictable behavior.

---

## 🚀 Quick start

Recommended way (download first, then run as root):

```bash
curl -fsSL https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh \
  -o /tmp/hardening.sh && \
chmod +x /tmp/hardening.sh && \
sudo /tmp/hardening.sh
```

> The script is interactive (whiptail). Run it in a real SSH session.

---

## ✨ Features

- Interactive TUI (whiptail)
- SSH hardening with custom port (does NOT disable root/password auth)
- UFW firewall (opens only selected ports)
- Fail2Ban for SSH (uses selected SSH port)
- Stateful re-runs (remembers last ports)
- Final "RUNTIME STATUS" block: SSH listeners, UFW rules, Fail2Ban port

---

## ✨ What this script intentionally does NOT do

- Does NOT manage SSH keys (`authorized_keys`)
- Does NOT disable `root` login
- Does NOT disable password authentication
- Does NOT install application stacks (e.g. 3x-ui)

---

======================================================================

---

# VPS Hardening Script (Ubuntu 24+)

Interactivny скрипт начальной настройки и базового харденина ՔS.

Cделан супимором на �4 полность и сделанность, повторяемость и повторяемость.

---

## 🚀 Быстрый старт

P�ажный способ (качать, сделать исполняˀ от руот.

```bash
curl -fsSL https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh \
  -o /tmp/hardening.sh && \
chmod +x /tmp/hardening.sh && \
sudo /tmp/hardening.sh
```

> Скрипт интерактивный (whiptail). Запускайте в обычной SSH-сессии.

---

## ✨ Возможности

- Интерактивный TUI (whiptail)
- Настройка SSH свыбором порта (роот/password НЕ отключается )
- UFW firewall (открывает только нужные порты)
- Fail2Ban для SSH (на выбранном SSH порте)
- Stateful повторяемость (запоминает порты)
- Синальный блок
0��RUNTIME STATUS": SSH listeners, UFW rules, Fail2Ban port

---

## ✨ Что скрипт намеренно НЕг делает НЕ деллать

- НЕ управляет SSH-ключами (`authorized_keys`)
- НЕотключает `root` доступ
- НЕотключает парольную аутентификацию
 - НЕ устанавливает прикладные сервисы (P�насер, 3x-ui)
