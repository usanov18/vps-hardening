#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# VPS HARDENING SCRIPT (Ubuntu 24+)
#
# 🇷🇺 Назначение:
#  - Обновление системы (apt update + безопасный upgrade)
#  - Установка и настройка: UFW, Fail2Ban
#  - Базовая настройка SSH: выбор порта
#  - Установка базовых утилит для дальнейшей работы (git, jq, unzip, htop, nano)
#
# 🇬🇧 Purpose:
#  - System update (apt update + safe upgrade)
#  - Install & configure: UFW, Fail2Ban
#  - Basic SSH setup: choose SSH port
#  - Install helpful tools for next steps (git, jq, unzip, htop, nano)
#
# ❗ ВАЖНО / IMPORTANT:
#  - Скрипт НЕ управляет SSH-ключами (authorized_keys)
#  - Script does NOT manage SSH keys (authorized_keys)
#  - Скрипт НЕ меняет root-login policy и НЕ трогает password auth
# ============================================================

# ---------- output helpers ----------
log()  { echo "[$(date -Is)] $*"; }
warn() { echo "[$(date -Is)] [WARNING] $*"; }
step() { echo; echo "========== $* =========="; }
die()  { echo "ERROR: $*" >&2; exit 1; }

CURRENT_STEP="(starting)"
trap 'die "Script failed during step: ${CURRENT_STEP}. Check output above."' ERR

require_root() {
  [[ $EUID -eq 0 ]] || die "Run as root (use: sudo bash hardening.sh)"
}

# ============================================================
# Defaults (used as suggested values)
# ============================================================
SSH_PORT_DEFAULT="22"
PANEL_PORT_DEFAULT="8443"
INBOUND_PORT_DEFAULT="443"

SSH_PORT=""
PANEL_PORT=""
INBOUND_PORT=""

ENABLE_UFW="yes"

usage() {
  cat <<'EOF'
VPS Hardening Script (Ubuntu 24+)

🇷🇺 Запуск:
  sudo bash hardening.sh

🇬🇧 Run:
  sudo bash hardening.sh

Notes:
  🇷🇺 Скрипт НЕ трогает SSH ключи (authorized_keys).
  🇬🇧 Script does NOT manage SSH keys (authorized_keys).

  🇷🇺 Скрипт НЕ отключает root-login и НЕ отключает парольный доступ.
  🇬🇧 Script does NOT disable root-login and does NOT disable password auth.
EOF
}

# ---------- input helpers ----------
is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

ask() {
  local question="$1"
  local default="$2"
  local answer=""
  read -r -p "$question [$default]: " answer
  echo "${answer:-$default}"
}

ask_yn() {
  local question="$1"
  local default="$2"
  local answer=""
  while true; do
    read -r -p "$question (y/n) [$default]: " answer
    answer="${answer:-$default}"
    case "$answer" in
      y|Y) echo "yes"; return 0 ;;
      n|N) echo "no";  return 0 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

ask_port() {
  local question="$1"
  local default="$2"
  local port=""
  while true; do
    port="$(ask "$question" "$default")"
    if is_valid_port "$port"; then
      echo "$port"
      return 0
    fi
    echo "Invalid port. Please enter a number between 1 and 65535."
  done
}

port_is_duplicate() {
  local candidate="$1"; shift
  local p
  for p in "$@"; do
    [[ -n "$p" && "$candidate" == "$p" ]] && return 0
  done
  return 1
}

ask_unique_port() {
  local question="$1"
  local default="$2"
  shift 2
  local existing=("$@")

  local p=""
  while true; do
    p="$(ask_port "$question" "$default")"
    if port_is_duplicate "$p" "${existing[@]}"; then
      echo "This port is already used by another selection. Choose a different one."
      continue
    fi
    echo "$p"
    return 0
  done
}

interactive_setup() {
  CURRENT_STEP="Interactive setup (ports)"
  step "SETUP / НАСТРОЙКА"

  warn "🇷🇺 Сейчас ты выберешь порты, которые будут ОТКРЫТЫ в firewall (UFW)."
  warn "🇷🇺 Порт SSH можно оставить 22 (нажми Enter), либо указать свой."
  warn "🇬🇧 You will choose ports that will be OPENED in the firewall (UFW)."
  warn "🇬🇧 You can keep SSH port 22 (press Enter) or choose a custom port."

  SSH_PORT="$(ask_port "SSH port / Порт SSH" "${SSH_PORT_DEFAULT}")"

  if [[ "$SSH_PORT" != "22" ]]; then
    warn "🇷🇺 Ты выбрал SSH порт ${SSH_PORT}. Порт 22 НЕ будет открыт в firewall."
    warn "🇷🇺 Не закрывай текущую SSH-сессию и проверь вход по новому порту в отдельном окне."
    warn "🇬🇧 You selected SSH port ${SSH_PORT}. Port 22 will NOT be allowed in the firewall."
    warn "🇬🇧 Keep your current SSH session open and test login on the new port in a separate window."
  else
    log "SSH port remains 22."
  fi

  local open_panel
  open_panel="$(ask_yn "Open panel port? / Открыть порт панели?" "n")"
  if [[ "$open_panel" == "yes" ]]; then
    PANEL_PORT="$(ask_unique_port "Panel port / Порт панели" "${PANEL_PORT_DEFAULT}" "${SSH_PORT}")"
  else
    PANEL_PORT=""
  fi

  local open_inbound
  open_inbound="$(ask_yn "Open inbound port? / Открыть inbound порт?" "y")"
  if [[ "$open_inbound" == "yes" ]]; then
    INBOUND_PORT="$(ask_unique_port "Inbound port / Inbound порт" "${INBOUND_PORT_DEFAULT}" "${SSH_PORT}" "${PANEL_PORT}")"
  else
    INBOUND_PORT=""
  fi
}

confirm_or_exit() {
  CURRENT_STEP="Confirmation"
  step "SUMMARY / СВОДКА"

  log "SSH port:     ${SSH_PORT}"
  log "Panel port:   ${PANEL_PORT:-not opened}"
  log "Inbound port: ${INBOUND_PORT:-not opened} (TCP + UDP)"

  warn "🇷🇺 ВАЖНО: Скрипт НЕ управляет SSH ключами (authorized_keys)."
  warn "🇷🇺 ВАЖНО: Скрипт НЕ отключает root-login и НЕ отключает парольный доступ."
  warn "🇬🇧 IMPORTANT: Script does NOT manage SSH keys (authorized_keys)."
  warn "🇬🇧 IMPORTANT: Script does NOT disable root-login and does NOT disable password auth."

  warn "🇷🇺 Продолжить? Это изменит настройки SSH и firewall."
  warn "🇬🇧 Proceed? This will change SSH and firewall settings."

  local go
  go="$(ask_yn "Proceed / Продолжить?" "n")"
  [[ "$go" == "yes" ]] || die "Aborted by user."
}

apt_update_and_upgrade() {
  CURRENT_STEP="System update (apt)"
  step "1/4 SYSTEM UPDATE / ОБНОВЛЕНИЕ СИСТЕМЫ"

  warn "🇷🇺 Будет выполнено безопасное обновление пакетов (без интерактивных вопросов)."
  warn "🇬🇧 Safe non-interactive package upgrade will be applied."

  apt-get update -y

  DEBIAN_FRONTEND=noninteractive \
  apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"
}

apt_install() {
  CURRENT_STEP="Install packages"
  step "2/4 PACKAGES / ПАКЕТЫ"

  warn "🇷🇺 Ставлю базовые утилиты для дальнейшей работы (git, jq, unzip, htop, nano)."
  warn "🇬🇧 Installing helpful tools for next steps (git, jq, unzip, htop, nano)."

  apt-get install -y \
    ufw fail2ban \
    ca-certificates curl gnupg lsb-release \
    git jq unzip htop nano
}

set_sshd_kv() {
  local key="$1"
  local value="$2"
  local file="/etc/ssh/sshd_config"

  if grep -qiE "^\s*#?\s*${key}\s+" "$file"; then
    sed -i -E "s|^\s*#?\s*${key}\s+.*|${key} ${value}|I" "$file"
  else
    echo "${key} ${value}" >>"$file"
  fi
}

assert_ssh_service_active() {
  if systemctl is-active --quiet ssh; then
    log "Confirmed: ssh service is active."
    return 0
  fi
  return 1
}

assert_sshd_listening() {
  local port="$1"

  if ss -lntp 2>/dev/null | grep -qE "LISTEN.+:${port}\b.*sshd"; then
    log "Confirmed: sshd is listening on port ${port}."
    return 0
  fi

  if assert_ssh_service_active && ss -lnt 2>/dev/null | grep -qE "LISTEN.+:${port}\b"; then
    warn "Listening check: port ${port} is LISTENing (process name not shown), ssh service is active."
    return 0
  fi

  return 1
}

configure_sshd() {
  CURRENT_STEP="Configure SSH (sshd)"
  step "3/4 SSH / НАСТРОЙКА SSH"

  warn "🇷🇺 Сейчас будет изменена конфигурация SSH."
  warn "🇷🇺 Если выбранный порт отличается от 22, порт 22 перестанет использоваться для SSH."
  warn "🇷🇺 Сохрани текущую SSH-сессию открытой и проверь вход по новому порту в отдельном окне."
  warn "🇬🇧 SSH configuration is about to be updated."
  warn "🇬🇧 If the selected port is different from 22, port 22 will no longer be used for SSH."
  warn "🇬🇧 Keep your current SSH session open and test login on the new port in a separate window."

  log "Setting SSH Port = ${SSH_PORT}"
  set_sshd_kv "Port" "${SSH_PORT}"

  # Bootstrap-friendly: do not change root-login or password auth policy.
  set_sshd_kv "PermitEmptyPasswords" "no"
  set_sshd_kv "ChallengeResponseAuthentication" "no"
  set_sshd_kv "UsePAM" "yes"

  log "Validating sshd_config (sshd -t)..."
  sshd -t

  log "Restarting SSH service..."
  systemctl restart ssh

  if ! assert_ssh_service_active; then
    die "SSH service is NOT active after restart. Do NOT close your current session."
  fi
  if ! assert_sshd_listening "${SSH_PORT}"; then
    die "SSH does NOT appear to be listening on port ${SSH_PORT}. Do NOT close your current session."
  fi

  log "SSH restarted successfully and listening check passed."
}

configure_ufw() {
  CURRENT_STEP="Configure firewall (UFW)"
  step "4/4 FIREWALL (UFW) / ФАЕРВОЛ"

  if [[ "$ENABLE_UFW" != "yes" ]]; then
    warn "🇷🇺 Firewall пропущен."
    warn "🇬🇧 Firewall skipped."
    return
  fi

  warn "🇷🇺 Входящие подключения будут запрещены по умолчанию. Откроются только выбранные порты."
  warn "🇬🇧 Incoming connections will be denied by default. Only selected ports will be allowed."

  warn "🇷🇺 ВАЖНО: Включение UFW НЕ учитывает особенности вашего провайдера и СБРОСИТ существующие правила."
  warn "🇷🇺 Если провайдер использует свои правила firewall/сетевые политики, проверьте это заранее."
  warn "🇬🇧 IMPORTANT: Enabling UFW does NOT account for provider-specific setup and WILL RESET existing rules."
  warn "🇬🇧 If your provider uses custom firewall/network policies, review them beforehand."

  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  log "Allowing SSH: ${SSH_PORT}/tcp"
  ufw allow "${SSH_PORT}/tcp" comment "SSH"

  if [[ -n "$PANEL_PORT" ]]; then
    log "Allowing Panel: ${PANEL_PORT}/tcp"
    ufw allow "${PANEL_PORT}/tcp" comment "Panel"
  else
    log "Panel port not opened."
  fi

  if [[ -n "$INBOUND_PORT" ]]; then
    log "Allowing Inbound: ${INBOUND_PORT}/tcp and ${INBOUND_PORT}/udp"
    ufw allow "${INBOUND_PORT}/tcp" comment "Inbound"
    ufw allow "${INBOUND_PORT}/udp" comment "Inbound (UDP)"
  else
    log "Inbound port not opened."
  fi

  ufw --force enable
  ufw status verbose
}

configure_fail2ban() {
  CURRENT_STEP="Configure Fail2Ban"
  step "EXTRA: FAIL2BAN / ДОП: FAIL2BAN"

  warn "🇷🇺 Fail2Ban будет включён для SSH и защитит порт ${SSH_PORT} от брутфорса."
  warn "🇬🇧 Fail2Ban will be enabled for SSH and protect port ${SSH_PORT} from brute-force."

  mkdir -p /etc/fail2ban/jail.d

  cat >/etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
bantime = 1h
findtime = 10m
maxretry = 5
EOF

  log "Written: /etc/fail2ban/jail.d/sshd.local"

  systemctl enable --now fail2ban
  systemctl restart fail2ban

  log "Fail2ban status (short):"
  systemctl --no-pager --full status fail2ban | head -n 20 || true
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  require_root

  interactive_setup
  confirm_or_exit

  apt_update_and_upgrade
  apt_install

  # Safer order:
  configure_sshd
  configure_ufw

  configure_fail2ban

  step "DONE / ГОТОВО"
  warn "🇷🇺 Если менял SSH порт — проверь вход по новому порту в отдельной сессии."
  warn "🇬🇧 If you changed SSH port — verify login on the new port in a separate session."
}

main "$@"
