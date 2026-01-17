#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# VPS HARDENING SCRIPT (Ubuntu 24+)
#
# 🇷🇺 Назначение:
#  - Обновление системы (apt update + безопасный upgrade)
#  - Установка и настройка: UFW, Fail2Ban
#  - Базовая настройка SSH: выбор порта
#  - Установка базовых утилит (git, jq, unzip, htop, nano)
#  - (UX) TUI (whiptail): аккуратные окна + прогресс
#  - (UX) State: показываем порты из прошлого запуска
#  - (Fix) /run/sshd перед sshd -t (tmpfs /run)
#  - (Fix) Поддержка ssh.socket (socket activation) без "мостика" 22
#
# 🇬🇧 Purpose:
#  - System update (apt update + safe upgrade)
#  - Install & configure: UFW, Fail2Ban
#  - Basic SSH setup: choose SSH port
#  - Install helpful tools (git, jq, unzip, htop, nano)
#  - (UX) TUI (whiptail): clean dialogs + progress
#  - (UX) State: show ports from previous run
#  - (Fix) Ensure /run/sshd exists before sshd -t
#  - (Fix) ssh.socket support (socket activation) without port-22 bridge
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

# ---------- tty helpers (curl | bash safe input + whiptail) ----------
tty_available() {
  [[ -r /dev/tty && -w /dev/tty ]]
}

tty_require() {
  tty_available || die "No TTY available for interactive input. Run in a real terminal (SSH session)."
}

tty_readline() {
  local prompt="$1"
  local default="${2:-}"
  local out=""

  if [[ -t 0 ]]; then
    read -r -p "$prompt" out
  else
    tty_require
    read -r -p "$prompt" out </dev/tty
  fi

  echo "${out:-$default}"
}

tty_yesno_prompt() {
  local prompt="$1"
  local ans=""

  if [[ -t 0 ]]; then
    read -r -p "$prompt" ans
  else
    tty_require
    read -r -p "$prompt" ans </dev/tty
  fi

  [[ "${ans:-n}" =~ ^[yY]$ ]]
}

# ---------- state ----------
STATE_DIR="/etc/vps-hardening"
STATE_FILE="${STATE_DIR}/last-ports.conf"

# ---------- defaults ----------
SSH_PORT_DEFAULT="22"
PANEL_PORT_DEFAULT="8443"
INBOUND_PORT_DEFAULT="443"

SSH_PORT=""
PANEL_PORT=""
INBOUND_PORT=""

ENABLE_UFW="yes"

# 🇷🇺 Опциональная пауза перед UFW, чтобы пользователь проверил вход по НОВОМУ SSH порту
# 🇬🇧 Optional pause before enabling UFW so user can test SSH on the NEW port
ENABLE_TEST_PAUSE="yes"

# ---------- TUI helpers (whiptail) ----------
TUI_ENABLED="false"
GAUGE_FD=""
GAUGE_PATH=""
GAUGE_PID=""

# Install whiptail early so TUI can be used on a clean VM.
bootstrap_tui() {
  command -v whiptail >/dev/null 2>&1 && return 0
  tty_available || return 0
  warn "Bootstrapping UI (installing whiptail)..."
  apt-get update -y
  apt-get install -y whiptail
}

# For `curl | bash`, stdin is not a TTY. We still want TUI if user has a real terminal.
# Conditions:
# - whiptail exists
# - stdout is a TTY
# - /dev/tty is available for input
has_tui() {
  command -v whiptail >/dev/null 2>&1 && [[ -t 1 ]] && tty_available
}

tui_init() {
  if has_tui; then
    TUI_ENABLED="true"
  fi
}

tui_msg() {
  local title="$1"
  local msg="$2"
  if [[ "$TUI_ENABLED" == "true" ]]; then
    whiptail --title "$title" --msgbox "$msg" 16 76 </dev/tty
  else
    echo "$title: $msg"
  fi
}

tui_info() {
  local title="$1"
  local msg="$2"
  if [[ "$TUI_ENABLED" == "true" ]]; then
    whiptail --title "$title" --infobox "$msg" 10 76 </dev/tty
  else
    echo "$title: $msg"
  fi
}

tui_yesno() {
  local title="$1"
  local msg="$2"
  if [[ "$TUI_ENABLED" == "true" ]]; then
    whiptail --title "$title" --yesno "$msg" 16 76 </dev/tty
    return $?
  else
    tty_yesno_prompt "$msg (y/n) [n]: "
  fi
}

tui_input() {
  local title="$1"
  local msg="$2"
  local default="$3"
  local out=""
  if [[ "$TUI_ENABLED" == "true" ]]; then
    out="$(whiptail --title "$title" --inputbox "$msg" 10 76 "$default" 3>&1 1>&2 2>&3 </dev/tty)" || return 1
    echo "$out"
  else
    read -r -p "$msg [$default]: " out </dev/tty
    echo "${out:-$default}"
  fi
}

gauge_start() {
  [[ "$TUI_ENABLED" == "true" ]] || return 0
  GAUGE_PATH="/tmp/vps-hardening-gauge.$$"
  mkfifo "$GAUGE_PATH"
  whiptail --title "VPS Hardening" --gauge "Starting..." 10 76 0 <"$GAUGE_PATH" </dev/tty &
  GAUGE_PID="$!"
  exec {GAUGE_FD}>"$GAUGE_PATH"
}

gauge_update() {
  local pct="$1"
  local msg="$2"
  [[ "$TUI_ENABLED" == "true" ]] || return 0
  {
    echo "XXX"
    echo "$pct"
    echo "$msg"
    echo "XXX"
  } >&"$GAUGE_FD"
}

gauge_stop() {
  [[ "$TUI_ENABLED" == "true" ]] || return 0
  gauge_update 100 "Done."
  exec {GAUGE_FD}>&-
  rm -f "$GAUGE_PATH" || true
  wait "$GAUGE_PID" 2>/dev/null || true
}

# ---------- port helpers ----------
is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

port_is_duplicate() {
  local candidate="$1"; shift
  local p
  for p in "$@"; do
    [[ -n "$p" && "$candidate" == "$p" ]] && return 0
  done
  return 1
}

ask_port_loop() {
  local title="$1"
  local prompt="$2"
  local default="$3"
  local val=""
  while true; do
    val="$(tui_input "$title" "$prompt" "$default")" || return 1
    if is_valid_port "$val"; then
      echo "$val"; return 0
    fi
    tui_msg "$title" "Invalid port: $val. Please enter 1..65535."
  done
}

ask_unique_port_loop() {
  local title="$1"
  local prompt="$2"
  local default="$3"
  shift 3
  local existing=("$@")
  local val=""
  while true; do
    val="$(ask_port_loop "$title" "$prompt" "$default")" || return 1
    if port_is_duplicate "$val" "${existing[@]}"; then
      tui_msg "$title" "This port is already used by another selection. Choose a different one."
      continue
    fi
    echo "$val"; return 0
  done
}

# ---------- state load/save ----------
load_last_ports() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE" || true
  fi
}

save_last_ports() {
  mkdir -p "$STATE_DIR"
  cat > "$STATE_FILE" <<EOF
SSH_PORT=${SSH_PORT}
PANEL_PORT=${PANEL_PORT}
INBOUND_PORT=${INBOUND_PORT}
EOF
  chmod 600 "$STATE_FILE"
}

# ---------- interactive setup ----------
interactive_setup() {
  CURRENT_STEP="Interactive setup (ports)"
  step "SETUP / НАСТРОЙКА"

  load_last_ports

  if [[ -n "${SSH_PORT:-}" || -n "${PANEL_PORT:-}" || -n "${INBOUND_PORT:-}" ]]; then
    warn "🇷🇺 Порты из прошлого запуска:"
    warn "🇷🇺 SSH: ${SSH_PORT:-нет} | Panel: ${PANEL_PORT:-нет} | Inbound: ${INBOUND_PORT:-нет}"
    warn "🇬🇧 Ports from previous run:"
    warn "🇬🇧 SSH: ${SSH_PORT:-none} | Panel: ${PANEL_PORT:-none} | Inbound: ${INBOUND_PORT:-none}"
    tui_msg "Previous selection" \
      "🇷🇺 Прошлый запуск:\nSSH: ${SSH_PORT:-нет}\nPanel: ${PANEL_PORT:-нет}\nInbound: ${INBOUND_PORT:-нет}\n\n🇬🇧 Previous run:\nSSH: ${SSH_PORT:-none}\nPanel: ${PANEL_PORT:-none}\nInbound: ${INBOUND_PORT:-none}"
  fi

  local ssh_default="${SSH_PORT_DEFAULT}"
  [[ -n "${SSH_PORT:-}" ]] && ssh_default="${SSH_PORT}"

  tui_info "Setup" "🇷🇺 Выбери порты, которые будут ОТКРЫТЫ в UFW.\n🇬🇧 Choose ports to be ALLOWED in UFW."

  SSH_PORT="$(ask_port_loop "SSH Port" "SSH port / Порт SSH (1-65535):" "$ssh_default")"

  if [[ "$SSH_PORT" != "22" ]]; then
    warn "🇷🇺 Ты выбрал SSH порт ${SSH_PORT}. Порт 22 будет закрыт firewall'ом после включения UFW."
    warn "🇷🇺 Не закрывай текущую SSH-сессию и проверь вход по новому порту в отдельном окне."
    warn "🇬🇧 You selected SSH port ${SSH_PORT}. Port 22 will be blocked by firewall once UFW is enabled."
    warn "🇬🇧 Keep your current SSH session open and test login on the new port in a separate window."
    tui_msg "SSH Warning" \
      "🇷🇺 SSH порт: ${SSH_PORT}\nНе закрывай текущую сессию.\nПроверь вход по новому порту в отдельном окне.\n\n🇬🇧 SSH port: ${SSH_PORT}\nKeep current session open.\nTest login on new port in a separate window."
  fi

  local panel_default="${PANEL_PORT_DEFAULT}"
  [[ -n "${PANEL_PORT:-}" ]] && panel_default="${PANEL_PORT}"

  local inbound_default="${INBOUND_PORT_DEFAULT}"
  [[ -n "${INBOUND_PORT:-}" ]] && inbound_default="${INBOUND_PORT}"

  if tui_yesno "Panel Port" "Open panel port? / Открыть порт панели?"; then
    PANEL_PORT="$(ask_unique_port_loop "Panel Port" "Panel port / Порт панели (1-65535):" "$panel_default" "$SSH_PORT")"
  else
    PANEL_PORT=""
  fi

  if tui_yesno "Inbound Port" "Open inbound port? / Открыть inbound порт?"; then
    INBOUND_PORT="$(ask_unique_port_loop "Inbound Port" "Inbound port / Inbound порт (1-65535):" "$inbound_default" "$SSH_PORT" "$PANEL_PORT")"
  else
    INBOUND_PORT=""
  fi

  if [[ "$SSH_PORT" != "22" ]]; then
    if tui_yesno "Safety pause" \
      "Pause before enabling UFW to test SSH on the NEW port?\n\n🇷🇺 Пауза перед включением UFW, чтобы проверить вход по НОВОМУ SSH порту?\n\nDefault: Yes"; then
      ENABLE_TEST_PAUSE="yes"
    else
      ENABLE_TEST_PAUSE="no"
    fi
  else
    ENABLE_TEST_PAUSE="no"
  fi

  save_last_ports
}

confirm_or_exit() {
  CURRENT_STEP="Confirmation"
  step "SUMMARY / СВОДКА"

  local panel_txt="${PANEL_PORT:-not opened}"
  local inbound_txt="${INBOUND_PORT:-not opened (TCP + UDP)}"
  log "SSH port:     ${SSH_PORT}"
  log "Panel port:   ${panel_txt}"
  log "Inbound port: ${inbound_txt}"

  echo
  echo "------------------------------------------------------------"
  warn "🇷🇺 КОНТРОЛЬНАЯ ТОЧКА: дальше будут применены изменения."
  warn "🇬🇧 CHECKPOINT: changes will be applied next."
  echo "------------------------------------------------------------"
  echo

  local msg
  msg="🇷🇺 Выбранные порты:\nSSH: ${SSH_PORT}\nPanel: ${panel_txt}\nInbound: ${inbound_txt}\n\n"
  msg+="🇷🇺 Важно: скрипт НЕ управляет SSH ключами и НЕ отключает root/password.\n\n"
  msg+="🇬🇧 Selected ports:\nSSH: ${SSH_PORT}\nPanel: ${panel_txt}\nInbound: ${inbound_txt}\n\n"
  msg+="🇬🇧 Note: script does NOT manage SSH keys and does NOT disable root/password."

  if [[ "$TUI_ENABLED" == "true" ]]; then
    if ! whiptail --title "Confirm" --yesno "$msg\n\nProceed / Продолжить?" 18 76 </dev/tty; then
      die "Aborted by user."
    fi
  else
    local ans=""
    ans="$(tty_readline "Proceed / Продолжить? (y/n) [n]: " "n")"
    [[ "${ans:-n}" =~ ^[yY]$ ]] || die "Aborted by user."
  fi
}

# ---------- steps ----------
apt_update_and_upgrade() {
  CURRENT_STEP="System update (apt)"
  step "1/4 SYSTEM UPDATE / ОБНОВЛЕНИЕ СИСТЕМЫ"
  gauge_update 10 "Updating system packages (apt)..."

  warn "🇷🇺 Выполняю безопасное обновление пакетов."
  warn "🇬🇧 Running safe package upgrade."

  apt-get update -y

  DEBIAN_FRONTEND=noninteractive \
  apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"
}

apt_install() {
  CURRENT_STEP="Install packages"
  step "2/4 PACKAGES / ПАКЕТЫ"
  gauge_update 35 "Installing base packages (ufw, fail2ban, tools, whiptail)..."

  warn "🇷🇺 Ставлю базовые утилиты (git, jq, unzip, htop, nano)."
  warn "🇬🇧 Installing helpful tools (git, jq, unzip, htop, nano)."

  apt-get install -y \
    ufw fail2ban \
    ca-certificates curl gnupg lsb-release \
    git jq unzip htop nano \
    whiptail
}

# ---------- ssh configuration ----------
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

ensure_run_sshd_dir() {
  if [[ -e /run/sshd && ! -d /run/sshd ]]; then
    die "/run/sshd exists but is not a directory"
  fi
  if [[ ! -d /run/sshd ]]; then
    mkdir -p /run/sshd
    chmod 755 /run/sshd
  fi
}

ssh_socket_active() {
  systemctl is-enabled --quiet ssh.socket 2>/dev/null && systemctl is-active --quiet ssh.socket 2>/dev/null
}

apply_ssh_socket_port_override() {
  local port="$1"

  mkdir -p /etc/systemd/system/ssh.socket.d

  cat >/etc/systemd/system/ssh.socket.d/override.conf <<EOF
[Socket]
ListenStream=
ListenStream=${port}
EOF

  systemctl daemon-reload
  systemctl restart ssh.socket
}

assert_ssh_service_active() {
  systemctl is-active --quiet ssh
}

assert_listening_port() {
  local port="$1"
  ss -lnt 2>/dev/null | grep -qE "LISTEN.+:${port}\b"
}

configure_sshd() {
  CURRENT_STEP="Configure SSH (sshd)"
  step "3/4 SSH / НАСТРОЙКА SSH"
  gauge_update 55 "Configuring SSH..."

  warn "🇷🇺 Сейчас будет изменена конфигурация SSH."
  warn "🇷🇺 Не закрывай текущую SSH-сессию; проверь вход по новому порту в отдельном окне."
  warn "🇬🇧 SSH config will be updated."
  warn "🇬🇧 Keep current SSH session; test login on new port in a separate window."

  log "Setting SSH Port = ${SSH_PORT}"
  set_sshd_kv "Port" "${SSH_PORT}"

  set_sshd_kv "PermitEmptyPasswords" "no"
  set_sshd_kv "ChallengeResponseAuthentication" "no"
  set_sshd_kv "UsePAM" "yes"

  ensure_run_sshd_dir

  log "Validating sshd_config (sshd -t)..."
  sshd -t

  if ssh_socket_active; then
    warn "🇷🇺 Обнаружен ssh.socket (socket activation). Применяю override на порт ${SSH_PORT}."
    warn "🇬🇧 Detected ssh.socket (socket activation). Applying override for port ${SSH_PORT}."
    apply_ssh_socket_port_override "${SSH_PORT}"
  fi

  log "Restarting SSH service..."
  systemctl restart ssh

  if ! assert_ssh_service_active; then
    die "SSH service is NOT active after restart. Do NOT close your current session."
  fi

  if ! assert_listening_port "${SSH_PORT}"; then
    warn "Debug hint: ss -lntp | grep sshd"
    warn "Debug hint: systemctl status ssh.socket (if enabled)"
    die "SSH does NOT appear to be listening on port ${SSH_PORT}. Do NOT close your current session."
  fi

  log "SSH is active and listening on port ${SSH_PORT}."
}

checkpoint_optional_pause() {
  CURRENT_STEP="Checkpoint (optional SSH test pause)"
  [[ "$ENABLE_TEST_PAUSE" == "yes" && "$SSH_PORT" != "22" ]] || return 0

  tui_msg "Checkpoint" \
    "🇷🇺 Пожалуйста, проверь вход по SSH на новом порту ${SSH_PORT} в отдельном окне.\nЕсли вход НЕ работает — нажми Cancel и НЕ продолжай.\n\n🇬🇧 Please test SSH login on the new port ${SSH_PORT} in a separate window.\nIf it does NOT work — press Cancel and do NOT continue."

  if [[ "$TUI_ENABLED" == "true" ]]; then
    whiptail --title "Proceed?" --yesno "Proceed to enable UFW now? / Продолжить и включить UFW?" 12 76 </dev/tty \
      || die "Aborted by user (SSH test checkpoint)."
  else
    local ans=""
    ans="$(tty_readline "Proceed to enable UFW now? (y/n) [n]: " "n")"
    [[ "${ans:-n}" =~ ^[yY]$ ]] || die "Aborted by user (SSH test checkpoint)."
  fi
}

# ---------- firewall ----------
configure_ufw() {
  CURRENT_STEP="Configure firewall (UFW)"
  step "4/4 FIREWALL (UFW) / ФАЕРВОЛ"
  gauge_update 75 "Configuring firewall (UFW)..."

  if [[ "$ENABLE_UFW" != "yes" ]]; then
    warn "🇷🇺 Firewall пропущен."
    warn "🇬🇧 Firewall skipped."
    return
  fi

  warn "🇷🇺 ВАЖНО: Включение UFW НЕ учитывает особенности провайдера и СБРОСИТ существующие правила."
  warn "🇬🇧 IMPORTANT: Enabling UFW may reset existing rules and does not account for provider specifics."

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

# ---------- fail2ban ----------
configure_fail2ban() {
  CURRENT_STEP="Configure Fail2Ban"
  step "EXTRA: FAIL2BAN / ДОП: FAIL2BAN"
  gauge_update 90 "Configuring Fail2Ban..."

  warn "🇷🇺 Fail2Ban будет включён для SSH и защитит порт ${SSH_PORT}."
  warn "🇬🇧 Fail2Ban will be enabled for SSH and protect port ${SSH_PORT}."

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
  require_root
  bootstrap_tui
  tui_init

  # Do NOT start gauge before interactive dialogs: gauge takes over the terminal.
  interactive_setup
  confirm_or_exit

  gauge_start
  gauge_update 0 "Initializing..."

  apt_update_and_upgrade
  apt_install

  configure_sshd
  checkpoint_optional_pause
  configure_ufw
  configure_fail2ban

  gauge_stop

  step "DONE / ГОТОВО"
  warn "🇷🇺 Если менял SSH порт — проверь вход по новому порту в отдельной сессии."
  warn "🇬🇧 If you changed SSH port — verify login on the new port in a separate session."

  tui_msg "Done" "🇷🇺 Готово.\n\n🇬🇧 Done."
}

main "$@"
