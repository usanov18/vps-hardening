# VPS Hardening Script

Terminal-first bootstrap и hardening для свежего Ubuntu VPS.

## Для Кого Этот Скрипт

Этот репозиторий нужен тем, кто поднял новый VPS и хочет одним скриптом сделать первый нормальный hardening без шумного TUI и без превращения проекта в Terraform или Ansible.

Он особенно полезен, если тебе нужно:

- безопасно перенести SSH на другой порт
- создать обычного admin-пользователя с доступом по ключу
- отключить `root` и парольный вход только после проверки нового входа
- применить более строгий baseline для UFW и Fail2Ban
- опционально включить сетевой профиль для proxy, tunnel и нагруженных серверов

## Что Делает Скрипт

| Зона | Поведение |
| --- | --- |
| Terminal UX | На экран выводятся только шаги, запросы, предупреждения и финальный статус |
| Логи | Полный лог прогона пишется в `/var/log/vps-hardening/run-YYYYMMDD-HHMMSS.log` |
| SSH | Есть bootstrap на `22`, опциональный перенос на новый порт и жёсткое закрытие после подтверждения |
| Доступ | Можно подготовить отдельного non-root admin-пользователя с `NOPASSWD:ALL` |
| Firewall | UFW-правила, которыми управляет скрипт, обновляются без удаления посторонних правил |
| Fail2Ban | Ставит более жёсткий базовый профиль для `sshd` и включает `recidive` |
| Network tuning | Может включить BBR, `fq`, увеличенные буферы, backlog tuning, keepalive tuning, `tcp_fastopen`, `tcp_mtu_probing` и опциональный `ip_forward` |

## Что Подготовить До Запуска

Перед первым запуском проверь это:

1. Используй свежий Ubuntu VPS.
2. Держи под рукой provider console, VNC, Lish или rescue-доступ.
3. Первый вход на сервер делай под `root`.
4. Подготовь SSH-ключ на своём компьютере или будь готов создать его.
5. Не закрывай исходную SSH-сессию, пока не проверишь новый путь входа.

## SSH-Ключи Простыми Словами

Здесь важно понять только одно:

- **приватный ключ** хранится у тебя на компьютере
- **публичный ключ** кладётся на сервер

Скрипт просит только **public key**. Приватный ключ в него вставлять нельзя.

Типовые локальные пути:

- Linux или macOS private key: `~/.ssh/id_ed25519`
- Linux или macOS public key: `~/.ssh/id_ed25519.pub`
- Windows private key: `%USERPROFILE%\.ssh\id_ed25519`
- Windows public key: `%USERPROFILE%\.ssh\id_ed25519.pub`

Если ключа ещё нет, создай его на своей машине:

```bash
ssh-keygen -t ed25519 -C "<label>"
```

## Быстрый Старт

```bash
curl -fsSL -o hardening.sh https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh
chmod +x hardening.sh
sudo ./hardening.sh
```

Запускай из обычной SSH-сессии с реальным TTY.

## Первый Запуск Для Новичка

### 1. Подключись к серверу

Со своей машины:

```bash
ssh root@IP_СЕРВЕРА
```

Если провайдер выдал пароль, используй его для первого входа.

### 2. Скачай скрипт на сервер

```bash
curl -fsSL -o hardening.sh https://raw.githubusercontent.com/usanov18/vps-hardening/main/hardening.sh
chmod +x hardening.sh
```

### 3. Запусти от root

```bash
sudo ./hardening.sh
```

### 4. Ответь на вопросы скрипта

Скрипт последовательно спросит:

| Вопрос | Что это значит | Что обычно выбрать новичку |
| --- | --- | --- |
| `SSH port` | Порт, на котором будет работать SSH | Выбери порт, который не забудешь |
| `Extra TCP ports` | Дополнительные TCP-порты для UFW | Открывай только то, что реально нужно |
| `Extra UDP ports` | Дополнительные UDP-порты для UFW | Оставь пусто, если UDP не нужен |
| `Prepare a dedicated admin user` | Создать отдельного пользователя с sudo | Обычно `yes` |
| `Copy keys from /root` | Переиспользовать текущие root-ключи | Обычно `yes`, если root уже заходит нужным ключом |
| `Paste an extra SSH public key` | Добавить ещё один public key | Используй, если хочешь дать другой ключ admin-пользователю |
| `Disable root login and password auth after a successful test` | Жёсткий SSH hardening после проверки | Обычно `yes`, если вход по ключу уже готов |
| `Apply network tuning baseline` | Включить сетевой sysctl-профиль | Обычно `yes` для proxy, panel, tunnel и нагруженных серверов |
| `Enable IPv4 forwarding` | Включить `net.ipv4.ip_forward` | Обычно `yes` для tunnel/proxy, иначе `no` |

### 5. Аккуратно пройди SSH-checkpoint

Когда скрипт дойдёт до проверки SSH:

1. не закрывай текущую SSH-сессию
2. открой второе окно терминала
3. выполни команду, которую покажет скрипт
4. убедись, что новый вход реально работает
5. только после этого подтверждай checkpoint

Это главный защитный шаг от случайного lockout.

## Что Добавляет Новый Сетевой Модуль

Логика из дополнительного sysctl-скрипта теперь встроена прямо в основной скрипт и использует нейтральные имена файлов.

При включении модуль пишет:

```text
/etc/sysctl.d/99-vps-hardening-net.conf
```

Он применяет:

- `net.core.default_qdisc = fq`
- `net.ipv4.tcp_congestion_control = bbr`
- увеличенные TCP receive и send буферы
- увеличенные backlog и accept queue значения
- `tcp_fastopen`
- `tcp_mtu_probing`
- `tcp_slow_start_after_idle = 0`
- TCP keepalive tuning
- `tcp_retries2 = 12`
- опциональный `net.ipv4.ip_forward = 1`

Перед применением скрипт делает backup известных sysctl-конфигов, включая старые кастомные tuning-файлы, в:

```text
/etc/vps-hardening/sysctl-backups/<timestamp>/
```

Также скрипт сохраняет предыдущие live sysctl-значения в:

```text
/etc/vps-hardening/network-sysctl-baseline.conf
```

Если позже отключить этот модуль, управляемый sysctl-файл будет удалён, а baseline runtime-значения будут восстановлены.

## Что Происходит Во Время Прогона

Порядок работы такой:

1. обновление системы и установка пакетов
2. создание admin-пользователя и подготовка SSH-ключей
3. SSH bootstrap на `22` и выбранном новом порту
4. ручная проверка нового входа во второй сессии
5. финальный SSH hardening, если вход подтверждён
6. настройка UFW и ICMP baseline
7. настройка Fail2Ban
8. опциональный сетевой sysctl-профиль
9. финальная сводка на экране и подробный лог на диске

## Что Делать После Завершения

Если ты сменил SSH-порт и создал пользователя `deploy`, следующий вход обычно будет таким:

```bash
ssh -p 2222 deploy@IP_СЕРВЕРА
```

Если нужен конкретный приватный ключ:

```bash
ssh -i ~/.ssh/id_ed25519 -p 2222 deploy@IP_СЕРВЕРА
```

Старую root-сессию закрывай только после того, как новый вход точно заработал.

## Поведение При Повторных Запусках

Скрипт рассчитан на повторный запуск.

Что важно:

- `Enter` сохраняет текущие списки TCP и UDP портов
- `none` очищает сохранённый список TCP или UDP портов
- если выбранный SSH-порт уже является активным SSH-портом, скрипт переиспользует его без лишнего подтверждения
- управляемые UFW-правила обновляются без полного сброса firewall

## Какие Файлы Пишет Скрипт

Во время обычного прогона могут создаваться или обновляться:

- `/etc/vps-hardening/last-config.conf`
- `/var/log/vps-hardening/run-YYYYMMDD-HHMMSS.log`
- `/etc/ssh/sshd_config.d/90-vps-hardening.conf`
- `/etc/systemd/system/ssh.socket.d/override.conf`, если используется socket activation
- `/etc/fail2ban/jail.d/10-vps-hardening.local`
- `/etc/sysctl.d/99-vps-hardening-net.conf`, если включён network tuning
- `/etc/sudoers.d/90-vps-hardening-<user>`, если создаётся admin-пользователь

## Границы Проекта

Репозиторий намеренно ограничен только bootstrap-слоем VPS.

Он не занимается:

- Terraform
- cloud-ресурсами
- раскаткой приложений
- reverse proxy
- установкой панелей, кроме открытия нужных тебе портов
