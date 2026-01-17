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
warn() { echo "[$(date -Is)] [WARNING] $*" >&2; }
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

bootstrap_tui() {
  command -v whiptail >/dev/null 2>&1 && return 0
  tty_available || return 0
  warn "Bootstrapping UI (installing whiptail)..."
  apt-get update -y
  apt-get install -y whiptail
}

has_tui() {
  command -v whiptail >/dev/null 2>&1 && tty_available && [[ -n "${TERM:-}" ]]
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
    local term="${TERM:-xterm}"
    local rc=0
    set +e
    TERM="$term" whiptail --clear --title "$title" --msgbox "$msg" 16 76 </dev/tty >/dev/tty 2>/dev/tty
    rc=$?
    set -e
    if [[ "$rc" != "0" ]]; then
      warn "whiptail msgbox failed (rc=$rc), falling back to text output"
      TUI_ENABLED="false"
      echo "$title: $msg" >&2
    fi
  else
    echo "$title: $msg" >&2
  fi
}


tui_info() {
  local title="$1"
  local msg="$2"
  if [[ "$TUI_ENABLED" == "true" ]]; then
    local term="${TERM:-xterm}"
    local rc=0
    set +e
    TERM="$term" whiptail --clear --title "$title" --infobox "$msg" 10 76 </dev/tty >/dev/tty 2>/dev/tty
    rc=$?
    set -e
    if [[ "$rc" != "0" ]]; then
      warn "whiptail infobox failed (rc=$rc), falling back to text output"
      TUI_ENABLED="false"
      echo "$title: $msg" >&2
    fi
  else
    echo "$title: $msg" >&2
  fi
}


tui_yesno() {
  local title="$1"
  local msg="$2"

  # Try whiptail first, but NEVER die on whiptail issues under curl|bash.
  if [[ "$TUI_ENABLED" == "true" ]]; then
    local term="${TERM:-xterm}"
    local rc=0

    set +e
    TERM="$term" whiptail --clear --title "$title" --yesno "$msg" 16 76 </dev/tty >/dev/tty 2>/dev/tty
    rc=$?
    set -e

    # whiptail returns: 0=yes, 1=no. Anything else = broken environment -> fallback.
    if [[ "$rc" == "0" ]]; then return 0; fi
    if [[ "$rc" == "1" ]]; then return 1; fi

    warn "whiptail failed (rc=$rc), falling back to text prompt via /dev/tty"
    TUI_ENABLED="false"
  fi

  tty_yesno_prompt "$msg (y/n) [n]: "
}
tui_input() {
  local title="$1"
  local msg="$2"
  local default="$3"
  local out=""
  local rc=0
  local tmp=""

  if [[ "$TUI_ENABLED" == "true" ]]; then
    local term="${TERM:-xterm}"

    tmp="$(mktemp -t vps-hardening-input.XXXXXX)" || tmp=""
    if [[ -z "$tmp" ]]; then
      warn "mktemp failed, falling back to text prompt via /dev/tty"
      TUI_ENABLED="false"
    else
      set +e
      TERM="$term" whiptail --clear --title "$title" --inputbox "$msg" 10 76 "$default" \
        --output-fd 3 \
        </dev/tty 1>/dev/tty 2>/dev/tty 3>"$tmp"
      rc=$?
      set -e

      if [[ "$rc" == "0" ]]; then
        # Some environments may write value twice; take first non-empty line.
        out="$(awk 'NF{print; exit}' "$tmp" 2>/dev/null || true)"
        rm -f "$tmp" 2>/dev/null || true
        out="${out//$'
'/}"
        out="$(printf '%s' "$out" | xargs)"
        printf '%s
' "$out"
        return 0
      fi

      rm -f "$tmp" 2>/dev/null || true

      if [[ "$rc" == "1" ]]; then
        return 1
      fi

      warn "whiptail inputbox failed (rc=$rc), falling back to text prompt via /dev/tty"
      TUI_ENABLED="false"
    fi
  fi

  out="$(tty_readline "$msg [$default]: " "$default")"
  out="${out//$'
'/}"
  out="$(printf '%s' "$out" | xargs)"
  printf '%s
' "$out"
}
gauge_start() {
  [[ "$TUI_ENABLED" == "true" ]] || return 0

  local term="${TERM:-xterm}"

  GAUGE_PATH="/tmp/vps-hardening-gauge.$$"
  mkfifo "$GAUGE_PATH"

  set +e
  TERM="$term" whiptail --clear --title "VPS Hardening" --gauge "Starting..." 10 76 0 \
    <"$GAUGE_PATH" >/dev/tty 2>/dev/tty &
  set -e

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
    # NOTE: tui_input returns non-zero on Cancel
    if ! val="$(tui_input "$title" "$prompt" "$default")"; then
      return 1
    fi

    # sanitize: drop CR, trim whitespace
    val="${val//$'
'/}"
    val="$(printf '%s' "$val" | xargs)"

    if [[ -z "$val" ]]; then
      tui_msg "$title" "Empty input. Please enter a port number (1..65535)."
      continue
    fi

    if is_valid_port "$val"; then
      printf '%s
' "$val"
      return 0
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
  msg="$(printf '%b' \
"🇷🇺 Выбранные порты:
SSH: ${SSH_PORT}
Panel: ${panel_txt}
Inbound: ${inbound_txt}

\
🇷🇺 Важно: скрипт НЕ управляет SSH ключами и НЕ отключает root/password.

\
🇬🇧 Selected ports:
SSH: ${SSH_PORT}
Panel: ${panel_txt}
Inbound: ${inbound_txt}

\
🇬🇧 Note: script does NOT manage SSH keys and does NOT disable root/password.
")"

  if ! tui_yesno "Confirm" "${msg}
Proceed / Продолжить?"; then
    die "Aborted by user."
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

# ssh.socket can be used on Ubuntu 24+. If the unit exists, the listening port is controlled by the socket.
# IMPORTANT: do not rely on is-enabled/is-active here; just check that the unit exists.
ssh_socket_enabled_or_active() {
  systemctl cat ssh.socket >/dev/null 2>&1
}

apply_ssh_socket_port_override() {
  local port="$1"

  mkdir -p /etc/systemd/system/ssh.socket.d

  # IMPORTANT:
  # Some systems may end up with IPv6-only listener ([::]:port), which breaks IPv4 access.
  # Bind explicitly on both IPv4 and IPv6 to avoid lockouts.
  cat >/etc/systemd/system/ssh.socket.d/override.conf <<EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:${port}
ListenStream=[::]:${port}
EOF

  systemctl daemon-reload
  systemctl restart ssh.socket
}

rollback_ssh_socket_override_to_22() {
  mkdir -p /etc/systemd/system/ssh.socket.d
  cat >/etc/systemd/system/ssh.socket.d/override.conf <<EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:22
ListenStream=[::]:22
EOF
  systemctl daemon-reload
  systemctl restart ssh.socket || true
}

assert_ssh_service_active() {
  systemctl is-active --quiet ssh
}

assert_listening_port() {
  local port="$1"
  ss -lnt 2>/dev/null | grep -qE "LISTEN.+:${port}\b"
}

assert_listening_port_ipv4() {
  local port="$1"
  # Expect an IPv4 listener like 0.0.0.0:port or A.B.C.D:port (ss prints IPv6 as [::]:port).
  ss -lnt 2>/dev/null | awk -v p=":"port '
    $1=="LISTEN" && $4 ~ (p"$") && $4 !~ /^\[::\]/ { ok=1 }
    END { exit(ok?0:1) }
  '
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
  # Temporary dual-port mode for safety
  if [[ "$SSH_PORT" != "22" ]]; then
    set_sshd_kv "Port" "22"
    echo "Port ${SSH_PORT}" >> /etc/ssh/sshd_config
  else
    set_sshd_kv "Port" "22"
  fi

  # Bootstrap-friendly (do not disable root/password auth)
  set_sshd_kv "PermitEmptyPasswords" "no"
  set_sshd_kv "ChallengeResponseAuthentication" "no"
  set_sshd_kv "UsePAM" "yes"

  ensure_run_sshd_dir

  log "Validating sshd_config (sshd -t)..."
  sshd -t

  if ssh_socket_enabled_or_active; then
    warn "🇷🇺 Обнаружен ssh.socket (socket activation). Применяю override на порт ${SSH_PORT}."
    warn "🇬🇧 Detected ssh.socket (socket activation). Applying override for port ${SSH_PORT}."
    apply_ssh_socket_port_override "${SSH_PORT}"

    # Safety: ensure IPv4 is actually listening (avoid IPv6-only lockouts)
    if ! assert_listening_port_ipv4 "${SSH_PORT}"; then
      warn "🇷🇺 ВНИМАНИЕ: SSH слушает порт ${SSH_PORT} только по IPv6. Исправляю на IPv4+IPv6 (0.0.0.0 + [::])."
      warn "🇬🇧 WARNING: SSH appears IPv6-only on port ${SSH_PORT}. Fixing to bind IPv4+IPv6 (0.0.0.0 + [::])."
      apply_ssh_socket_port_override "${SSH_PORT}"
    fi
  fi

  log "Restarting SSH service..."
  systemctl restart ssh

  if ! assert_ssh_service_active; then
    die "SSH service is NOT active after restart. Do NOT close your current session."
  fi

  if ! assert_listening_port "${SSH_PORT}"; then
    warn "SSH does NOT appear to be listening on port ${SSH_PORT}."
    warn "Debug hint: ss -lntp | grep -E ':(22|${SSH_PORT})\\b'"
    warn "Debug hint: systemctl status ssh.socket (if enabled)"
    if ssh_socket_enabled_or_active; then
      # If socket activation is used, require IPv4 listener too (most users connect over IPv4).
      if ! assert_listening_port_ipv4 "${SSH_PORT}"; then
        warn "SSH is NOT listening on IPv4 for port ${SSH_PORT} (IPv6-only). This can lock you out."
        warn "Attempting safe rollback of ssh.socket override to port 22 to preserve access..."
        rollback_ssh_socket_override_to_22
        die "Do NOT close your current session. Fix IPv4 SSH listening before continuing."
      fi

      warn "Attempting safe rollback of ssh.socket override to port 22 to preserve access..."
      rollback_ssh_socket_override_to_22
    fi
    die "Do NOT close your current session. Fix SSH port before continuing."
  fi

  log "SSH is active and listening on port ${SSH_PORT}."
}

checkpoint_optional_pause() {
  CURRENT_STEP="Checkpoint (optional SSH test pause)"
  [[ "$ENABLE_TEST_PAUSE" == "yes" && "$SSH_PORT" != "22" ]] || return 0

  tui_msg "Checkpoint" \
    "🇷🇺 Пожалуйста, проверь вход по SSH на новом порту ${SSH_PORT} в отдельном окне.
Если вход НЕ работает — нажми Cancel и НЕ продолжай.

🇬🇧 Please test SSH login on the new port ${SSH_PORT} in a separate window.
If it does NOT work — press Cancel and do NOT continue."

  if [[ "$SSH_PORT" != "22" ]]; then
    sed -i -E '/^\s*Port\s+22\s*$/d' /etc/ssh/sshd_config
    systemctl restart ssh
  fi

  if ! tui_yesno "Proceed?" "Proceed to enable UFW now? / Продолжить и включить UFW?"; then
    die "Aborted by user (SSH test checkpoint)."
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

  # Do NOT start gauge before interactive dialogs (would block whiptail input).

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

# --- entrypoint ---
# stdin-safe "sourced vs executed" guard:
# - when sourced: `return` succeeds -> do nothing
# - when executed (including `curl | bash`): `return` fails -> run main
if ( return 0 2>/dev/null ); then
  :
else
  main "$@"
fi

