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
tui_cleanup() {
  # Best-effort terminal restore after whiptail <"$TTY_DEV" >"$TTY_DEV" / gauge / abrupt exits
  stty sane 2>/dev/null || true
  tput sgr0 2>/dev/null || true
  : # no clear here
}

cleanup_all() {
  # stop gauge if running, then restore tty (best-effort)
  gauge_stop 2>/dev/null || true

  # Leave whiptail/alternate screen if it was used
  tput rmcup 2>/dev/null || true
  stty sane <"$TTY_DEV" 2>/dev/null || true
  tput cnorm <"$TTY_DEV" 2>/dev/null || true

  stty sane 2>/dev/null || true
  tput sgr0 2>/dev/null || true
  tput cnorm 2>/dev/null || true

  # Do NOT "clear" here: it erases the final output.
  # Instead, just clean the current line and move to a fresh prompt line.
  if [[ -n "${CONSOLE_FD:-}" ]]; then
    printf '\r\033[K\n' >&"$CONSOLE_FD" 2>/dev/null || true
  else
    printf '\r\033[K\n' >/dev/tty 2>/dev/null || true
  fi
}

on_exit() {
  local rc=$?
  cleanup_all || true

  # Print DONE to the real console (stdout is redirected to logfile)
  if [[ $rc -eq 0 ]]; then
    if command -v say >/dev/null 2>&1; then
      say "==> DONE / ГОТОВО"
    else
      printf "\n==> DONE / ГОТОВО\n" >/dev/tty 2>/dev/null || true
    fi
  fi
}


tui_cleanup() {
  # Best-effort terminal restore after whiptail <"$TTY_DEV" >"$TTY_DEV" / gauge / abrupt exits
  stty sane 2>/dev/null || true
  tput sgr0 2>/dev/null || true
  : # no clear here
}

log()  { echo "[$(date -Is)] $*"; }
warn() { echo "[$(date -Is)] [WARNING] $*" >&2; }
step() { echo; echo "========== $* =========="; }
die()  { cleanup_all || true; echo "ERROR: $*" >&2; exit 1; }
CURRENT_STEP="(starting)"
trap 'tui_cleanup || true; echo "ERROR: Script failed during step: ${CURRENT_STEP}. Check output above." >&2; exit 1' ERR
trap 'rc=$?; cleanup_all || true; if [[ $rc -eq 0 ]]; then printf "
==> DONE / ГОТОВО
"; fi' EXIT
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


# ---------- logging / UX: keep terminal clean, write heavy output to logfile ----------
LOG_DIR="/var/log/vps-hardening"
LOG_FILE=""
CONSOLE_FD=""

console_init() {
  mkdir -p "$LOG_DIR"
  chmod 750 "$LOG_DIR" || true

  LOG_FILE="${LOG_DIR}/run-$(date +%Y%m%d-%H%M%S).log"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" || true

  # Preserve original stderr for user-visible output
  exec {CONSOLE_FD}>&2

  # Prefer real TTY if available
  if tty_available; then
    exec {CONSOLE_FD}>/dev/tty
  fi

  # Redirect all stdout/stderr to logfile
  exec >>"$LOG_FILE" 2>&1
}

say() { printf '%s\n' "$*" >&"$CONSOLE_FD"; }

die() {
  say "ERROR: $*"
  say "Log: ${LOG_FILE:-/var/log/vps-hardening/...}"
  echo "ERROR: $*" >&2
  exit 1
}

step() {
  echo
  echo "========== $* =========="
  say "==> $*"
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

# User confirmed SSH login works on the NEW port during checkpoint
SSH_TEST_CONFIRMED="no"

# ---------- TUI helpers (whiptail) ----------
TUI_ENABLED="false"
GAUGE_FD=""
GAUGE_PATH=""
GAUGE_PID=""
GAUGE_LAST_PCT="0"
GAUGE_LAST_MSG="Starting..."

bootstrap_tui() {
  command -v whiptail <"$TTY_DEV" >"$TTY_DEV" >/dev/null 2>&1 && return 0
  tty_available || return 0
  warn "Bootstrapping UI (installing whiptail)..."
  apt-get update -y
  apt-get install -y whiptail
}

has_tui() {
  command -v whiptail <"$TTY_DEV" >"$TTY_DEV" >/dev/null 2>&1 && tty_available && [[ -n "${TERM:-}" ]]
}



tui_init() {
  if has_tui; then
    TUI_ENABLED="true"
  fi
}

tui_msg() {
  gauge_pause_for_dialog || true
  local title="$1"
  local msg="$2"
  if [[ "$TUI_ENABLED" == "true" ]]; then
    local term="${TERM:-xterm}"
    local rc=0
    set +e
    TERM="$term" whiptail <"$TTY_DEV" >"$TTY_DEV" --clear --title "$title" --msgbox "$msg" 16 76 </dev/tty >/dev/tty 2>/dev/tty
    rc=$?
    set -e
    if [[ "$rc" != "0" ]]; then
      warn "whiptail <"$TTY_DEV" >"$TTY_DEV" msgbox failed (rc=$rc), falling back to text output"
      TUI_ENABLED="false"
      echo "$title: $msg" >&2
    fi
  else
    echo "$title: $msg" >&2
  fi
  gauge_resume_after_dialog || true
}
tui_info() {
  local title="$1"
  local msg="$2"
  if [[ "$TUI_ENABLED" == "true" ]]; then
    local term="${TERM:-xterm}"
    local rc=0
    set +e
    TERM="$term" whiptail <"$TTY_DEV" >"$TTY_DEV" --clear --title "$title" --infobox "$msg" 10 76 </dev/tty >/dev/tty 2>/dev/tty
    rc=$?
    set -e
    if [[ "$rc" != "0" ]]; then
      warn "whiptail <"$TTY_DEV" >"$TTY_DEV" infobox failed (rc=$rc), falling back to text output"
      TUI_ENABLED="false"
      echo "$title: $msg" >&2
    fi
  else
    echo "$title: $msg" >&2
  fi
}


tui_yesno() {
  gauge_pause_for_dialog || true
  local title="$1"
  local msg="$2"

  # Try whiptail <"$TTY_DEV" >"$TTY_DEV" first, but NEVER die on whiptail <"$TTY_DEV" >"$TTY_DEV" issues under curl|bash.
  if [[ "$TUI_ENABLED" == "true" ]]; then
    local term="${TERM:-xterm}"
    local rc=0

    set +e
    TERM="$term" whiptail <"$TTY_DEV" >"$TTY_DEV" --clear --title "$title" --yesno "$msg" 16 76 </dev/tty >/dev/tty 2>/dev/tty
    rc=$?
    set -e

    # whiptail <"$TTY_DEV" >"$TTY_DEV" returns: 0=yes, 1=no. Anything else = broken environment -> fallback.
    if [[ "$rc" == "0" ]]; then return 0; fi
    if [[ "$rc" == "1" ]]; then return 1; fi

    warn "whiptail <"$TTY_DEV" >"$TTY_DEV" failed (rc=$rc), falling back to text prompt via /dev/tty"
    TUI_ENABLED="false"
  fi

  tty_yesno_prompt "$msg (y/n) [n]: "
  gauge_resume_after_dialog || true
}
tui_input() {
  gauge_pause_for_dialog || true
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
      TERM="$term" whiptail <"$TTY_DEV" >"$TTY_DEV" --clear --title "$title" --inputbox "$msg" 10 76 "$default" \
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
  gauge_resume_after_dialog || true
  return 0
      fi

      rm -f "$tmp" 2>/dev/null || true

      if [[ "$rc" == "1" ]]; then
  gauge_resume_after_dialog || true
  return 1
      fi

      warn "whiptail <"$TTY_DEV" >"$TTY_DEV" inputbox failed (rc=$rc), falling back to text prompt via /dev/tty"
      TUI_ENABLED="false"
    fi
  fi

  out="$(tty_readline "$msg [$default]: " "$default")"
  out="${out//$'
'/}"
  out="$(printf '%s' "$out" | xargs)"
  printf '%s
' "$out"
  gauge_resume_after_dialog || true
}
gauge_start() {
  [[ "$TUI_ENABLED" == "true" ]] || return 0

  local term="${TERM:-xterm}"

  GAUGE_PATH="/tmp/vps-hardening-gauge.$$"
  mkfifo "$GAUGE_PATH"

  set +e
  TERM="$term" whiptail <"$TTY_DEV" >"$TTY_DEV" --clear --title "VPS Hardening" --gauge "Starting..." 10 76 0 \
    <"$GAUGE_PATH" >/dev/tty 2>/dev/tty &
  set -e

  GAUGE_PID="$!"
  exec {GAUGE_FD}>"$GAUGE_PATH"
}


gauge_update() {
  local pct="$1"
  local msg="$2"
  GAUGE_LAST_PCT="$pct"
  GAUGE_LAST_MSG="$msg"
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
  # IMPORTANT: wait for whiptail to fully exit BEFORE removing FIFO
  wait "$GAUGE_PID" 2>/dev/null || true
  rm -f "$GAUGE_PATH" || true
}

gauge_pause_for_dialog() {
  [[ "$TUI_ENABLED" == "true" ]] || return 0
  # Stop gauge whiptail <"$TTY_DEV" >"$TTY_DEV" to avoid conflicts with other whiptail <"$TTY_DEV" >"$TTY_DEV" dialogs
  gauge_stop || true
}

gauge_resume_after_dialog() {
  [[ "$TUI_ENABLED" == "true" ]] || return 0
  # Resume gauge (best-effort) with last known state
  gauge_start || true
  gauge_update "${GAUGE_LAST_PCT:-0}" "${GAUGE_LAST_MSG:-Resuming...}" || true
}


# ---------- port helpers ----------
is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

port_has_tcp_listener() {
  local port="$1"
  ss -lnt "sport = :${port}" 2>/dev/null | tail -n +2 | grep -q LISTEN
}

port_tcp_listener_is_sshd() {
  local port="$1"
  ss -lntp "sport = :${port}" 2>/dev/null | grep -q '"sshd"'
}


# Returns TCP LISTEN lines for a given port (best-effort; may be empty).
get_tcp_listeners_for_port() {
  local port="$1"
  ss -lntpH 2>/dev/null | awk -v p=":${port}" '$1=="LISTEN" && $4 ~ (p"$") {print}' || true
}

tcp_port_is_listening() {
  local port="$1"
  get_tcp_listeners_for_port "$port" | grep -q '.'
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
      # If port is already listening, handle it safely.
      if port_has_tcp_listener "$val"; then
# SSH re-run fast path: accept current SSH port if sshd is listening
if [[ "$title" == "SSH Port" ]] && port_tcp_listener_is_sshd "${val}"; then
  tui_msg "SSH port already active / SSH уже активен" \
    "🇷🇺 Порт ${val} уже используется SSH (sshd). Это нормально при повторном запуске.\n\nПродолжаю с этим портом.\n\n🇬🇧 Port ${val} is already used by SSH (sshd). This is normal on re-runs.\n\nContinuing with this port."
  printf '%s\n' "${val}"
  return 0
fi

        # If sshd is already listening here, it's typically OK (re-run / selecting current SSH port).
        if [[ "$title" == "SSH Port" ]] && port_tcp_listener_is_sshd "$val"; then
          gauge_pause_for_dialog || true
          if tui_yesno "SSH port already active / SSH уже активен" \
            "🇷🇺 Порт $val уже слушается SSH (sshd). Это нормально при повторном запуске.\n\nИспользовать этот порт снова?\n\n🇬🇧 Port $val is already used by SSH (sshd). This is normal on re-runs.\n\nUse this port again?"; then
            gauge_resume_after_dialog || true
            # accept $val as-is
            :
          else
            gauge_resume_after_dialog || true
            continue
          fi
        else
          gauge_pause_for_dialog || true
          if ! tui_yesno "Port in use / Порт занят" \
            "🇷🇺 Порт $val уже занят другим сервисом (TCP LISTEN).\n      Нужно выбрать другой порт.\n\n      Нажми Yes — выбрать другой.\nНажми No — отмена (скрипт остановится).\n\n      🇬🇧 Port $val is already in use by another service (TCP LISTEN).\n      You must choose another port.\n\n      Press Yes to choose another.\nPress No to cancel (script will stop)."; then
            gauge_resume_after_dialog || true
            die "Aborted by user during port selection."
          fi
          gauge_resume_after_dialog || true
          continue
        fi
      fi
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
      tui_msg "$title" "🇷🇺 Этот порт уже выбран в другом поле. Выбери другой.\n\n🇬🇧 🇷🇺 Этот порт уже выбран в другом поле. Выбери другой.

🇬🇧 This port is already used by another selection. Choose a different one."
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

  # SSH port: if it's already in use by another TCP listener, choosing it will likely fail
  # (sshd won't be able to bind). Catch this early to avoid frustrating mid-script failures.
    while true; do
      SSH_PORT="$(ask_port_loop "SSH Port" "SSH port / Порт SSH (1-65535):" "$ssh_default")"
      if [[ "$SSH_PORT" == "22" ]]; then
        break
      fi
      if tcp_port_is_listening "$SSH_PORT"; then
        local listeners
        listeners="$(get_tcp_listeners_for_port "$SSH_PORT" | head -n 6)"

        # SSH re-run: sshd already listening — OK
        if port_tcp_listener_is_sshd "$SSH_PORT"; then
          tui_msg "SSH Port" \
            "🇷🇺 Порт ${SSH_PORT} уже используется SSH (sshd).\nЭто нормально при повторном запуске.\n\nПродолжаем с этим портом.\n\n🇬🇧 Port ${SSH_PORT} is already used by SSH (sshd).\nThis is normal on re-runs.\n\nContinuing with this port."
        SSH_PORT_REUSED="yes"
          break
        fi

        if tui_yesno "SSH Port in use" \
          "Port ${SSH_PORT} is already LISTENing.\n\n🇷🇺 Порт занят другим процессом. Рекомендуется выбрать другой.\n🇬🇧 Port is used by another process. Recommended to choose a different one.\n\nDetected:\n${listeners}\n\nChoose a different SSH port? / Выбрать другой SSH-порт?"; then
          continue
        else
          die "Aborted by user due to busy SSH port ${SSH_PORT}."
        fi
      fi
      break
    done

  if [[ "$SSH_PORT" != "22" && "${SSH_PORT_REUSED:-no}" != "yes" ]]; then
    warn "🇷🇺 Ты выбрал SSH порт ${SSH_PORT}. Порт 22 будет закрыт firewall'ом после включения UFW."
    warn "🇷🇺 Не закрывай текущую SSH-сессию и проверь вход по новому порту в отдельном окне."
    warn "🇬🇧 You selected SSH port ${SSH_PORT}. Port 22 will be blocked by firewall once UFW is enabled."
    warn "🇬🇧 Keep your current SSH session open and test login on the new port in a separate window."
    if [[ "${SSH_PORT_REUSED:-no}" != "yes" ]]; then
    tui_msg "SSH Warning" \
      "🇷🇺 SSH порт: ${SSH_PORT}\nНе закрывай текущую сессию.\nПроверь вход по новому порту в отдельном окне.\n\n🇬🇧 SSH port: ${SSH_PORT}\nKeep current session open.\nTest login on new port in a separate window."
    fi
  fi

  local panel_default="${PANEL_PORT_DEFAULT}"
  [[ -n "${PANEL_PORT:-}" ]] && panel_default="${PANEL_PORT}"

  local inbound_default="${INBOUND_PORT_DEFAULT}"
  [[ -n "${INBOUND_PORT:-}" ]] && inbound_default="${INBOUND_PORT}"

  if tui_yesno "Panel Port" "Open panel port? / Открыть порт панели?"; then
    PANEL_PORT="$(ask_unique_port_loop "Panel Port" "Panel port / Порт панели (1-65535):" "$panel_default" "$SSH_PORT")"

    # Panel port may legitimately already be listening (e.g., existing admin UI).
    # This is NOT an error: the firewall rule will be added later.
    if [[ -n "$PANEL_PORT" ]] && tcp_port_is_listening "$PANEL_PORT"; then
      local listeners
      listeners="$(get_tcp_listeners_for_port "$PANEL_PORT" | head -n 6)"
      tui_msg "Panel Port" "Note: port ${PANEL_PORT} is already listening (TCP). This is OK if intentional; UFW will allow it later.\n\nDetected:\n${listeners}"
    fi
  else
    PANEL_PORT=""
  fi

  if tui_yesno "Inbound Port" "Open inbound port? / Открыть inbound порт?"; then
    INBOUND_PORT="$(ask_unique_port_loop "Inbound Port" "Inbound port / Inbound порт (1-65535):" "$inbound_default" "$SSH_PORT" "$PANEL_PORT")"

    # Same logic: inbound port might already be listening (e.g., existing service).
    # That's fine — we'll add firewall rules later.
    if [[ -n "$INBOUND_PORT" ]] && tcp_port_is_listening "$INBOUND_PORT"; then
      local listeners
      listeners="$(get_tcp_listeners_for_port "$INBOUND_PORT" | head -n 6)"
      tui_msg "Inbound Port" "Note: port ${INBOUND_PORT} is already listening (TCP). This is OK if intentional; UFW will allow it later.\n\nDetected:\n${listeners}"
    fi
  else
    INBOUND_PORT=""
  fi

  if [[ "$SSH_PORT" != "22" ]]; then
    if tui_yesno "SSH test checkpoint" \
      "Enable an extra safety checkpoint to test SSH on the NEW port AFTER SSH is reconfigured, but BEFORE enabling UFW?\n\n✅ Later in this run the script will STOP and ask you to open a second session and test:\n  ssh -p ${SSH_PORT} root@<YOUR_SERVER_IP>\n\n🇷🇺 Включить дополнительный контрольный чекпоинт для проверки SSH на НОВОМ порту ПОСЛЕ применения настроек SSH, но ДО включения UFW?\n\n✅ Позже в этом запуске скрипт ОСТАНОВИТСЯ и попросит открыть вторую сессию и проверить:\n  ssh -p ${SSH_PORT} root@<YOUR_SERVER_IP>\n\nDefault: Yes"; then
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



  # If UFW is already active (e.g., firewall enabled before this script),
  # temporarily allow the NEW SSH port so the checkpoint test is meaningful.
  if ufw_is_active; then
    warn "UFW is already active. Temporarily allowing SSH port ${SSH_PORT}/tcp for checkpoint test..."
    ufw_temp_allow_port "${SSH_PORT}"
  fi
  # SSH test checkpoint: confirm that you can log in on the NEW port before enabling UFW.
  if ! tui_yesno "SSH test result / Результат проверки" \
    "🇷🇺 СЕЙЧАС проверь вход по SSH на новом порту ${SSH_PORT}.

1) НЕ закрывай эту сессию.
2) Открой ВТОРОЕ окно/терминал и выполни:
   ssh -p ${SSH_PORT} root@<YOUR_SERVER_IP>
3) Если вход НЕ работает — нажми Cancel и НЕ продолжай.

🇬🇧 NOW test SSH login on the new port ${SSH_PORT}.

1) Do NOT close this session.
2) Open a SECOND terminal and run:
   ssh -p ${SSH_PORT} root@<YOUR_SERVER_IP>
3) If login does NOT work — press Cancel and do NOT continue.

🇷🇺 Если вход НЕ работает — выбери No (Cancel) и НЕ продолжай.
🇬🇧 If login does NOT work — choose No (Cancel) and do NOT continue.

✅ Did login on port ${SSH_PORT} work? / ✅ Вход по порту ${SSH_PORT} работает?" ; then
    die "Aborted by user (SSH test checkpoint)."
  fi

  SSH_TEST_CONFIRMED="yes"
  gauge_resume_after_dialog || true
}

finalize_legacy_ssh_port_22_if_confirmed() {
  local cfg="/etc/ssh/sshd_config"
  local backup=""

  [[ "${SSH_TEST_CONFIRMED:-no}" == "yes" ]] || return 0
  [[ "${SSH_PORT}" != "22" ]] || return 0

  grep -qE '^\s*Port\s+22\s*$' "$cfg" 2>/dev/null || return 0

  warn "🇷🇺 Вход по новому SSH порту ${SSH_PORT} подтверждён. Удаляю Port 22 из sshd_config."
  warn "🇬🇧 New SSH port ${SSH_PORT} confirmed. Removing Port 22 from sshd_config."

  backup="${cfg}.bak.$(date +%Y%m%d_%H%M%S)"
  cp -a "$cfg" "$backup"

  sed -i -E '/^\s*Port\s+22\s*$/d' "$cfg"

  if sshd -t; then
    systemctl reload ssh 2>/dev/null || systemctl restart ssh
    log "Legacy Port 22 removed from sshd_config."
  else
    warn "sshd -t failed after removing Port 22. Restoring backup: $backup"
    cp -a "$backup" "$cfg"
    systemctl reload ssh 2>/dev/null || systemctl restart ssh
    return 1
  fi
}


# ---------- firewall ----------

# ---------- firewall helpers ----------
ufw_is_active() {
  command -v ufw >/dev/null 2>&1 || return 1
  ufw status 2>/dev/null | head -n 1 | grep -qi '^Status:\s*active'
}

ufw_temp_allow_port() {
  local port="$1"
  # Best-effort: allow the new SSH port for checkpoint testing IF UFW is already active.
  # This is temporary: configure_ufw() will reset rules anyway.
  ufw allow "${port}/tcp" comment "SSH (temp for checkpoint)" >/dev/null 2>&1 || true
  ufw reload >/dev/null 2>&1 || true
}

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
  ufw status verbose >/dev/null >/dev/null

  finalize_legacy_ssh_port_22_if_confirmed
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
  console_init
  bootstrap_tui
  tui_init

  # Do NOT start gauge before interactive dialogs (would block whiptail <"$TTY_DEV" >"$TTY_DEV" input).

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

  finalize_tui
step "DONE / ГОТОВО"
echo "==> DONE / ГОТОВО"
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


finalize_tui() {
  # hard TUI restore
  gauge_stop 2>/dev/null || true
  stty sane 2>/dev/null || true
  tput sgr0 2>/dev/null || true
  tput cnorm 2>/dev/null || true
  tput rmcup 2>/dev/null || true
  : # no clear here
  printf "\n" 2>/dev/null || true
}
