#!/usr/bin/env bash
set -euo pipefail

TTY_DEV="/dev/tty"

LOG_DIR="/var/log/vps-hardening"
STATE_DIR="/etc/vps-hardening"
STATE_FILE="${STATE_DIR}/last-config.conf"

SSHD_DROPIN="/etc/ssh/sshd_config.d/90-vps-hardening.conf"
SSH_SOCKET_DROPIN="/etc/systemd/system/ssh.socket.d/override.conf"
FAIL2BAN_DROPIN="/etc/fail2ban/jail.d/10-vps-hardening.local"
SYSCTL_DROPIN="/etc/sysctl.d/99-vps-hardening-net.conf"
SYSCTL_BACKUP_ROOT="${STATE_DIR}/sysctl-backups"
SYSCTL_BASELINE_FILE="${STATE_DIR}/network-sysctl-baseline.conf"

LOG_FILE=""
CONSOLE_FD=""
CURRENT_STEP="startup"

SSH_PORT="22"
ALLOW_TCP_PORTS=""
ALLOW_UDP_PORTS=""
TARGET_HOSTNAME=""
ADMIN_USER=""
COPY_ROOT_KEYS="no"
COPY_SUDO_USER_KEYS="no"
PASTED_PUBLIC_KEY=""
STRICT_SSH_HARDENING="no"
ADMIN_KEYS_READY="no"
SSH_TEST_CONFIRMED="no"
ENABLE_NETWORK_TUNING="yes"
ENABLE_IP_FORWARD="yes"
PRIMARY_IP=""
PREV_SSH_PORT=""
SYSCTL_BACKUP_DIR=""
DELETE_OTHER_USERS="no"
DEFERRED_DELETE_USERS=""

require_root() {
  [[ ${EUID} -eq 0 ]] || { echo "Run as root. / Запусти от root." >&2; exit 1; }
}

tty_available() {
  [[ -r "${TTY_DEV}" && -w "${TTY_DEV}" ]]
}

tty_require() {
  tty_available || { echo "A real terminal is required. / Нужен реальный терминал." >&2; exit 1; }
}

grant_log_access_to_invoking_user() {
  local user="${SUDO_USER:-}"
  local group=""

  [[ -n "${user}" && "${user}" != "root" ]] || return 0
  id -u "${user}" >/dev/null 2>&1 || return 0

  group="$(id -gn "${user}" 2>/dev/null || true)"
  [[ -n "${group}" ]] || return 0

  chgrp "${group}" "${LOG_DIR}" "${LOG_FILE}" 2>/dev/null || true
  chmod 750 "${LOG_DIR}" || true
  chmod 640 "${LOG_FILE}" || true
}

console_init() {
  mkdir -p "${LOG_DIR}"
  chmod 750 "${LOG_DIR}" || true

  LOG_FILE="${LOG_DIR}/run-$(date +%Y%m%d-%H%M%S).log"
  touch "${LOG_FILE}"
  chmod 600 "${LOG_FILE}" || true
  grant_log_access_to_invoking_user

  exec {CONSOLE_FD}>&2
  if tty_available; then
    exec {CONSOLE_FD}>/dev/tty
  fi

  exec >>"${LOG_FILE}" 2>&1
}

say() {
  printf '%s\n' "$*" >&"${CONSOLE_FD}"
}

say_blank() {
  printf '\n' >&"${CONSOLE_FD}"
}

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*"
}

step() {
  CURRENT_STEP="$1"
  say_blank
  say "==> ${CURRENT_STEP}"
  log "STEP: ${CURRENT_STEP}"
}

warn_user() {
  say "Warning / Внимание: $*"
  log "WARNING: $*"
}

die() {
  log "ERROR: $*"
  say_blank
  say "Error / Ошибка: $*"
  exit 1
}

on_exit() {
  local rc=$?

  if [[ -z "${CONSOLE_FD:-}" ]]; then
    return
  fi

  say_blank
  if [[ ${rc} -eq 0 ]]; then
    say "Completed. / Готово."
  elif [[ ${rc} -eq 130 ]]; then
    say "Stopped by user. / Остановлено пользователем."
  else
    say "Failed during / Ошибка на шаге: ${CURRENT_STEP}"
  fi
  say "Log / Лог: ${LOG_FILE:-/var/log/vps-hardening/...}"
}

on_int() {
  exit 130
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

prompt_line() {
  local prompt="$1"
  local default="${2:-}"
  local allow_blank="${3:-no}"
  local answer=""

  while true; do
    if [[ -n "${default}" ]]; then
      printf '%s [%s]: ' "${prompt}" "${default}" >"${TTY_DEV}"
    else
      printf '%s: ' "${prompt}" >"${TTY_DEV}"
    fi

    IFS= read -r answer <"${TTY_DEV}" || exit 130
    answer="$(trim "${answer}")"

    if [[ -n "${answer}" ]]; then
      printf '%s\n' "${answer}"
      return 0
    fi

    if [[ "${allow_blank}" == "yes" ]]; then
      printf '\n'
      return 0
    fi

    if [[ -n "${default}" ]]; then
      printf '%s\n' "${default}"
      return 0
    fi
  done
}

prompt_yesno() {
  local prompt="$1"
  local default="${2:-yes}"
  local suffix=""
  local answer=""

  if [[ "${default}" == "yes" ]]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi

  while true; do
    printf '%s %s: ' "${prompt}" "${suffix}" >"${TTY_DEV}"
    IFS= read -r answer <"${TTY_DEV}" || exit 130
    answer="$(trim "${answer}")"
    answer="${answer,,}"

    if [[ -z "${answer}" ]]; then
      [[ "${default}" == "yes" ]] && return 0
      return 1
    fi

    case "${answer}" in
      y|yes|д|да) return 0 ;;
      n|no|н|нет) return 1 ;;
    esac
  done
}

is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

prompt_port() {
  local prompt="$1"
  local default="$2"
  local value=""

  while true; do
    value="$(prompt_line "${prompt}" "${default}")"
    if is_valid_port "${value}"; then
      printf '%s\n' "${value}"
      return 0
    fi
    say "Use a port in range 1..65535. / Нужен порт в диапазоне 1..65535."
  done
}

normalize_port_specs() {
  local input="$1"
  local prepared=""
  local token=""
  local start=""
  local end=""
  local normalized=""
  local -A seen=()
  local parts=()

  input="$(trim "${input}")"
  [[ -z "${input}" ]] && return 0

  prepared="${input//;/,}"
  prepared="${prepared// /,}"
  prepared="${prepared//$'\t'/,}"

  IFS=',' read -r -a parts <<< "${prepared}"

  for token in "${parts[@]}"; do
    token="$(trim "${token}")"
    [[ -z "${token}" ]] && continue

    if [[ "${token}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      is_valid_port "${start}" || return 1
      is_valid_port "${end}" || return 1
      (( start <= end )) || return 1
      token="${start}-${end}"
    elif is_valid_port "${token}"; then
      :
    else
      return 1
    fi

    if [[ -z "${seen[${token}]:-}" ]]; then
      seen["${token}"]="1"
      if [[ -n "${normalized}" ]]; then
        normalized+=","
      fi
      normalized+="${token}"
    fi
  done

  printf '%s\n' "${normalized}"
}

prompt_port_specs() {
  local prompt="$1"
  local default="${2:-}"
  local value=""
  local normalized=""

  while true; do
    if [[ -n "${default}" ]]; then
      value="$(prompt_line "${prompt}" "${default}")"
    else
      value="$(prompt_line "${prompt}" "${default}" "yes")"
    fi
    value="$(trim "${value}")"

    case "${value,,}" in
      none|off|-) value="" ;;
    esac

    if [[ -z "${value}" ]]; then
      printf '\n'
      return 0
    fi

    if normalized="$(normalize_port_specs "${value}")"; then
      printf '%s\n' "${normalized}"
      return 0
    fi

    say "Use a comma-separated list like 443,8443 or a range like 10000-10100. / Используй список 443,8443 или диапазон 10000-10100."
  done
}

valid_username() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]
}

prompt_username() {
  local prompt="$1"
  local default="$2"
  local value=""

  while true; do
    value="$(prompt_line "${prompt}" "${default}")"
    if valid_username "${value}" && [[ "${value}" != "root" ]]; then
      printf '%s\n' "${value}"
      return 0
    fi
    say "Use a Linux-style username, not root. / Имя должно быть в Linux-стиле и не root."
  done
}

valid_public_key() {
  [[ "$1" =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp[0-9]+|sk-ecdsa-sha2-nistp256@openssh\.com|sk-ssh-ed25519@openssh\.com)[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]]
}

extract_public_keys() {
  local source="$1"

  [[ -f "${source}" ]] || return 0

  awk '
    match($0, /(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp[0-9]+|sk-ecdsa-sha2-nistp256@openssh\.com|sk-ssh-ed25519@openssh\.com)[[:space:]][A-Za-z0-9+\/=]+([[:space:]].*)?$/) {
      print substr($0, RSTART, RLENGTH)
    }
  ' "${source}"
}

show_public_key_help() {
  say "SSH key / SSH-ключ:"
  say "  Public key only (.pub). Только public key (.pub)."
  say "  Private key stays on your machine. Приватный ключ остаётся у тебя."
  say "  Next prompt expects one line from a .pub file. Следующий prompt ждёт одну строку из .pub."
  say "  Linux/macOS: ~/.ssh/id_ed25519 and ~/.ssh/id_ed25519.pub"
  say "  Windows: %USERPROFILE%\\.ssh\\id_ed25519 and id_ed25519.pub"
  say "  Windows option: MobaXterm/MobaKeyGen -> copy the OpenSSH public key line."
  say "  Generate locally if needed: ssh-keygen -t ed25519 -C \"<label>\""
  say "  Windows launcher in this repo: generate-ssh-key.cmd"
  say "  It opens a local helper, creates a key pair, or exports .pub/.pub.txt from an existing private key."
  say "  Example: .\\generate-ssh-key.cmd -FromExistingPrivateKey \"%USERPROFILE%\\.ssh\\mykey\" -Overwrite"
}

show_network_tuning_help() {
  say "Network tuning / Сетевой профиль:"
  say "  Adds BBR + fq, larger TCP buffers and backlog tuning."
  say "  Добавляет BBR + fq, увеличенные TCP-буферы и backlog-настройки."
  say "  Also tunes keepalive, tcp_fastopen, tcp_mtu_probing and dead-path retries."
  say "  Также настраивает keepalive, tcp_fastopen, tcp_mtu_probing и retries."
  say "  Useful for proxies, tunnels and high-throughput servers."
  say "  Полезно для proxy, tunnel и нагруженных серверов."
  say "  Common sysctl files are backed up before apply."
  say "  Перед применением делается backup известных sysctl-конфигов."
}

prompt_public_key() {
  local prompt="$1"
  local value=""

  while true; do
    printf '%s\n' "${prompt}" >"${TTY_DEV}"
    printf '%s' '> ' >"${TTY_DEV}"
    IFS= read -r value <"${TTY_DEV}" || exit 130
    value="$(trim "${value}")"

    if [[ -z "${value}" ]]; then
      printf '\n'
      return 0
    fi

    if valid_public_key "${value}"; then
      printf '%s\n' "${value}"
      return 0
    fi

    say "That does not look like a valid SSH public key. / Похоже, это невалидный SSH public key."
  done
}

csv_or_none() {
  local value="$1"
  if [[ -n "${value}" ]]; then
    printf '%s' "${value}"
  else
    printf 'none / нет'
  fi
}

bool_or_no() {
  local value="$1"
  if [[ "${value}" == "yes" ]]; then
    printf 'yes / да'
  else
    printf 'no / нет'
  fi
}

value_or_none() {
  local value="$1"
  if [[ -n "${value}" ]]; then
    printf '%s' "${value}"
  else
    printf 'none / нет'
  fi
}

reset_saved_answers() {
  SSH_PORT=""
  ALLOW_TCP_PORTS=""
  ALLOW_UDP_PORTS=""
  TARGET_HOSTNAME=""
  ADMIN_USER=""
  STRICT_SSH_HARDENING=""
  ENABLE_NETWORK_TUNING=""
  ENABLE_IP_FORWARD=""
  DELETE_OTHER_USERS="no"
}

state_set_if_present() {
  local value="$1"
  local fallback="$2"
  if [[ -n "${value}" ]]; then
    printf '%s\n' "${value}"
  else
    printf '%s\n' "${fallback}"
  fi
}

load_state() {
  local key=""
  local value=""

  [[ -f "${STATE_FILE}" ]] || return 0

  while IFS='=' read -r key value; do
    value="$(trim "${value}")"
    case "${key}" in
      SSH_PORT) SSH_PORT="${value}" ;;
      ALLOW_TCP_PORTS) ALLOW_TCP_PORTS="${value}" ;;
      ALLOW_UDP_PORTS) ALLOW_UDP_PORTS="${value}" ;;
      TARGET_HOSTNAME) TARGET_HOSTNAME="${value}" ;;
      ADMIN_USER) ADMIN_USER="${value}" ;;
      STRICT_SSH_HARDENING) STRICT_SSH_HARDENING="${value}" ;;
      ENABLE_NETWORK_TUNING) ENABLE_NETWORK_TUNING="${value}" ;;
      ENABLE_IP_FORWARD) ENABLE_IP_FORWARD="${value}" ;;
      DELETE_OTHER_USERS) DELETE_OTHER_USERS="${value}" ;;
    esac
  done < "${STATE_FILE}"
}

save_state() {
  mkdir -p "${STATE_DIR}"
  cat > "${STATE_FILE}" <<EOF
SSH_PORT=${SSH_PORT}
ALLOW_TCP_PORTS=${ALLOW_TCP_PORTS}
ALLOW_UDP_PORTS=${ALLOW_UDP_PORTS}
TARGET_HOSTNAME=${TARGET_HOSTNAME}
ADMIN_USER=${ADMIN_USER}
STRICT_SSH_HARDENING=${STRICT_SSH_HARDENING}
ENABLE_NETWORK_TUNING=${ENABLE_NETWORK_TUNING}
ENABLE_IP_FORWARD=${ENABLE_IP_FORWARD}
DELETE_OTHER_USERS=${DELETE_OTHER_USERS}
EOF
  chmod 600 "${STATE_FILE}"
}

guess_primary_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

current_static_hostname() {
  local value=""

  value="$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || true)"
  trim "${value}"
}

valid_hostname() {
  local value="$1"

  [[ ${#value} -le 253 ]] || return 1
  [[ "${value}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$ ]]
}

prompt_hostname() {
  local prompt="$1"
  local default="$2"
  local value=""

  while true; do
    value="$(prompt_line "${prompt}" "${default}")"
    if valid_hostname "${value}"; then
      printf '%s\n' "${value}"
      return 0
    fi
    say "Используй hostname в Linux-формате: строчные буквы, цифры, дефис и точка."
  done
}

port_has_tcp_listener() {
  local port="$1"
  ss -lnt "sport = :${port}" 2>/dev/null | tail -n +2 | grep -q LISTEN
}

get_port_listeners() {
  local port="$1"
  ss -lntpH "sport = :${port}" 2>/dev/null || true
}

port_listener_is_sshd() {
  local port="$1"
  local listeners=""

  listeners="$(get_port_listeners "${port}")"
  grep -q 'sshd' <<< "${listeners}" && return 0
  ssh_socket_managed && grep -q 'systemd' <<< "${listeners}"
}

prompt_ssh_port() {
  local default="$1"
  local value=""
  local listeners=""

  while true; do
    value="$(prompt_port "SSH port / SSH-порт" "${default}")"

    if ! port_has_tcp_listener "${value}"; then
      printf '%s\n' "${value}"
      return 0
    fi

    if [[ "${value}" == "${default}" ]] && port_listener_is_sshd "${value}"; then
      say "SSH already listens on port ${value}. Reusing it. / SSH уже слушает порт ${value}, оставляю его."
      printf '%s\n' "${value}"
      return 0
    fi

    listeners="$(get_port_listeners "${value}" | head -n 6)"
    say "Port ${value} is already in use. / Порт ${value} уже занят:"
    if [[ -n "${listeners}" ]]; then
      while IFS= read -r line; do
        say "  ${line}"
      done <<< "${listeners}"
    fi

    if prompt_yesno "Use this port anyway? / Использовать всё равно?" "no"; then
      printf '%s\n' "${value}"
      return 0
    fi
  done
}

user_exists() {
  id -u "$1" >/dev/null 2>&1
}

get_user_home() {
  getent passwd "$1" | awk -F: '{print $6}'
}

current_session_login_user() {
  local user=""

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && user_exists "${SUDO_USER}"; then
    printf '%s\n' "${SUDO_USER}"
    return 0
  fi

  user="$(logname 2>/dev/null || true)"
  user="$(trim "${user}")"
  if [[ -n "${user}" && "${user}" != "root" ]] && user_exists "${user}"; then
    printf '%s\n' "${user}"
    return 0
  fi

  user="$(who -m 2>/dev/null | awk '{print $1}' || true)"
  user="$(trim "${user}")"
  if [[ -n "${user}" && "${user}" != "root" ]] && user_exists "${user}"; then
    printf '%s\n' "${user}"
    return 0
  fi

  return 1
}

list_other_regular_users() {
  local keep_user="${1:-}"

  getent passwd | awk -F: -v keep="${keep_user}" '
    $3 >= 1000 &&
    $1 != "root" &&
    $1 != "nobody" &&
    $1 != keep &&
    $7 !~ /(nologin|false)$/ {
      print $1
    }
  '
}

user_has_authorized_keys() {
  local user="$1"
  local home=""

  user_exists "${user}" || return 1
  home="$(get_user_home "${user}")"
  [[ -n "${home}" && -s "${home}/.ssh/authorized_keys" ]]
}

sudo_user_keys_path() {
  local user=""
  local home=""

  user="$(current_session_login_user 2>/dev/null || true)"
  [[ -n "${user}" ]] || return 1
  home="$(get_user_home "${user}")"
  [[ -n "${home}" && -f "${home}/.ssh/authorized_keys" ]] || return 1
  printf '%s\n' "${home}/.ssh/authorized_keys"
}

planned_key_material_available() {
  [[ -n "${PASTED_PUBLIC_KEY}" ]] && return 0
  [[ "${COPY_ROOT_KEYS}" == "yes" && -f /root/.ssh/authorized_keys ]] && return 0

  if [[ "${COPY_SUDO_USER_KEYS}" == "yes" ]]; then
    sudo_user_keys_path >/dev/null 2>&1 && return 0
  fi

  [[ -n "${ADMIN_USER}" ]] && user_has_authorized_keys "${ADMIN_USER}" && return 0
  return 1
}

interactive_setup() {
  local default_ssh="22"
  local default_hostname=""
  local default_admin="deploy"
  local sudo_keys=""
  local session_login_user=""
  local network_default="yes"
  local ip_forward_default="yes"
  local use_saved_values="no"
  local edit_saved_values="no"
  local cleanup_user=""
  local cleanup_users=()

  step "Configuration / Настройка"
  if [[ -f "${STATE_FILE}" ]]; then
    load_state
    PREV_SSH_PORT="${SSH_PORT}"
  else
    PREV_SSH_PORT=""
  fi

  if [[ -f "${STATE_FILE}" ]]; then
    say "Previous run / Предыдущий запуск:"
    say "  SSH port / SSH-порт: ${SSH_PORT}"
    say "  TCP ports / TCP-порты: $(csv_or_none "${ALLOW_TCP_PORTS}")"
    say "  UDP ports / UDP-порты: $(csv_or_none "${ALLOW_UDP_PORTS}")"
    say "  Имя сервера: $(value_or_none "${TARGET_HOSTNAME}")"
    say "  Admin user / Admin-пользователь: ${ADMIN_USER}"
    say "  Строгий SSH: $(bool_or_no "${STRICT_SSH_HARDENING}")"
    say "  Network tuning / Сетевой профиль: $(bool_or_no "${ENABLE_NETWORK_TUNING}")"
    say "  IPv4 forwarding / Маршрутизация IPv4: $(bool_or_no "${ENABLE_IP_FORWARD}")"
    say "  Удаление других пользователей: $(bool_or_no "${DELETE_OTHER_USERS}")"
    say_blank

    if prompt_yesno "Использовать сохранённые значения прошлого запуска?" "no"; then
      use_saved_values="yes"
    else
      PREV_SSH_PORT=""
    fi
  fi

  if [[ "${use_saved_values}" != "yes" ]]; then
    reset_saved_answers
  fi

  SSH_PORT="$(state_set_if_present "${SSH_PORT}" "${default_ssh}")"
  default_hostname="$(current_static_hostname)"
  TARGET_HOSTNAME="$(state_set_if_present "${TARGET_HOSTNAME}" "${default_hostname}")"
  ADMIN_USER="$(state_set_if_present "${ADMIN_USER}" "${default_admin}")"
  STRICT_SSH_HARDENING="$(state_set_if_present "${STRICT_SSH_HARDENING}" "no")"
  ENABLE_NETWORK_TUNING="$(state_set_if_present "${ENABLE_NETWORK_TUNING}" "${network_default}")"
  ENABLE_IP_FORWARD="$(state_set_if_present "${ENABLE_IP_FORWARD}" "${ip_forward_default}")"
  DELETE_OTHER_USERS="$(state_set_if_present "${DELETE_OTHER_USERS}" "no")"
  PRIMARY_IP="$(guess_primary_ip || true)"
  session_login_user="$(current_session_login_user 2>/dev/null || true)"

  if [[ "${use_saved_values}" == "yes" ]]; then
    if prompt_yesno "Изменить сохранённые значения вручную?" "no"; then
      edit_saved_values="yes"
    else
      COPY_ROOT_KEYS="no"
      COPY_SUDO_USER_KEYS="no"
      PASTED_PUBLIC_KEY=""

      if [[ "${STRICT_SSH_HARDENING}" == "yes" ]] && ! planned_key_material_available; then
        STRICT_SSH_HARDENING="no"
        warn_user "Для сохранённого admin-пользователя не найден SSH-ключ, строгий SSH hardening будет пропущен."
      fi

      say "Использую сохранённую конфигурацию без повторных вопросов."
      save_state
      return 0
    fi
  fi

  if [[ "${edit_saved_values}" == "yes" ]]; then
    say "Сохранённые значения загружены. Нажми Enter, чтобы оставить текущее значение."
  fi

  SSH_PORT="$(prompt_ssh_port "${SSH_PORT}")"
  TARGET_HOSTNAME="$(prompt_hostname "Имя сервера / Hostname" "${TARGET_HOSTNAME}")"
  ALLOW_TCP_PORTS="$(prompt_port_specs "Extra TCP ports / Доп. TCP-порты (comma-separated, blank = none)" "${ALLOW_TCP_PORTS}")"
  ALLOW_UDP_PORTS="$(prompt_port_specs "Extra UDP ports / Доп. UDP-порты (comma-separated, blank = none)" "${ALLOW_UDP_PORTS}")"

  if prompt_yesno "Prepare a dedicated admin user? / Подготовить отдельного admin-пользователя?" "yes"; then
    ADMIN_USER="$(prompt_username "Admin username / Имя admin-пользователя" "${ADMIN_USER}")"

    if [[ -f /root/.ssh/authorized_keys ]] && [[ "${ADMIN_USER}" != "root" ]]; then
      prompt_yesno "Copy keys from /root to ${ADMIN_USER}? / Скопировать ключи из /root в ${ADMIN_USER}?" "yes" && COPY_ROOT_KEYS="yes" || COPY_ROOT_KEYS="no"
    else
      COPY_ROOT_KEYS="no"
    fi

    if sudo_keys="$(sudo_user_keys_path 2>/dev/null || true)"; then
      if [[ -n "${sudo_keys}" && -n "${session_login_user}" && "${session_login_user}" != "${ADMIN_USER}" ]]; then
        prompt_yesno "Copy keys from ${session_login_user} to ${ADMIN_USER}? / Скопировать ключи пользователя ${session_login_user} в ${ADMIN_USER}?" "yes" && COPY_SUDO_USER_KEYS="yes" || COPY_SUDO_USER_KEYS="no"
      else
        COPY_SUDO_USER_KEYS="no"
      fi
    else
      COPY_SUDO_USER_KEYS="no"
    fi

    show_public_key_help

    PASTED_PUBLIC_KEY="$(prompt_public_key "Paste an extra SSH public key for ${ADMIN_USER} (single line; blank = skip) / Вставь доп. SSH public key для ${ADMIN_USER}")"

    if planned_key_material_available; then
      prompt_yesno "Disable root login and password auth after a successful test? / Отключить root login и password auth после проверки?" "yes" && STRICT_SSH_HARDENING="yes" || STRICT_SSH_HARDENING="no"
    else
      STRICT_SSH_HARDENING="no"
      warn_user "No key material found for ${ADMIN_USER}; strict SSH lock-down will be skipped. / Для ${ADMIN_USER} не найден ключ, строгий SSH hardening будет пропущен."
    fi

    cleanup_users=()
    while IFS= read -r cleanup_user; do
      [[ -n "${cleanup_user}" ]] && cleanup_users+=("${cleanup_user}")
    done < <(list_other_regular_users "${ADMIN_USER}")

    if ((${#cleanup_users[@]})); then
      say "Найдены другие пользователи:"
      for cleanup_user in "${cleanup_users[@]}"; do
        say "  ${cleanup_user}"
      done
      prompt_yesno "Удалить этих пользователей после успешного входа под ${ADMIN_USER}?" "no" && DELETE_OTHER_USERS="yes" || DELETE_OTHER_USERS="no"
    else
      DELETE_OTHER_USERS="no"
    fi
  else
    ADMIN_USER=""
    COPY_ROOT_KEYS="no"
    COPY_SUDO_USER_KEYS="no"
    PASTED_PUBLIC_KEY=""
    STRICT_SSH_HARDENING="no"
    DELETE_OTHER_USERS="no"
  fi

  show_network_tuning_help
  if prompt_yesno "Apply network tuning baseline? / Применить сетевой профиль?" "${ENABLE_NETWORK_TUNING}"; then
    ENABLE_NETWORK_TUNING="yes"
    if prompt_yesno "Enable IPv4 forwarding for proxy/tunnel workloads? / Включить IPv4 forwarding для proxy/tunnel?" "${ENABLE_IP_FORWARD}"; then
      ENABLE_IP_FORWARD="yes"
    else
      ENABLE_IP_FORWARD="no"
    fi
  else
    ENABLE_NETWORK_TUNING="no"
    ENABLE_IP_FORWARD="no"
  fi

  save_state
}

confirm_configuration() {
  local cleanup_user=""
  step "Review / Проверка плана"
  say "Planned changes / Что будет применено:"
  say "  SSH port / SSH-порт: ${SSH_PORT}"
  say "  Имя сервера: ${TARGET_HOSTNAME}"
  say "  Extra TCP ports / Доп. TCP-порты: $(csv_or_none "${ALLOW_TCP_PORTS}")"
  say "  Extra UDP ports / Доп. UDP-порты: $(csv_or_none "${ALLOW_UDP_PORTS}")"

  if [[ -n "${ADMIN_USER}" ]]; then
    say "  Admin user / Admin-пользователь: ${ADMIN_USER}"
    say "  Passwordless sudo / Sudo без пароля: yes / да"
    say "  Disable root/password login after check / Отключить root/password после проверки: $(bool_or_no "${STRICT_SSH_HARDENING}")"
    say "  Удалить других пользователей после успешного входа под ${ADMIN_USER}: $(bool_or_no "${DELETE_OTHER_USERS}")"
    if [[ "${DELETE_OTHER_USERS}" == "yes" ]]; then
      while IFS= read -r cleanup_user; do
        [[ -n "${cleanup_user}" ]] && say "    - ${cleanup_user}"
      done < <(list_other_regular_users "${ADMIN_USER}")
    fi
  else
    say "  Admin user / Admin-пользователь: none / нет"
  fi

  say "  UFW / Firewall: keep existing rules + refresh managed rules"
  say "  Fail2Ban: stronger SSH defaults / более жёсткий SSH baseline"
  say "  Network tuning / Сетевой профиль: $(bool_or_no "${ENABLE_NETWORK_TUNING}")"
  if [[ "${ENABLE_NETWORK_TUNING}" == "yes" ]]; then
    say "  IPv4 forwarding / Маршрутизация IPv4: $(bool_or_no "${ENABLE_IP_FORWARD}")"
    say "  What it adds / Что добавляет: BBR, fq, bigger buffers, backlog, keepalive, fastopen"
  fi

  prompt_yesno "Continue? / Продолжить?" "no" || die "Aborted by user. / Остановлено пользователем."
}

apt_update_and_upgrade() {
  step "System update / Обновление системы"
  log "Running apt update and upgrade."

  apt-get update -y
  DEBIAN_FRONTEND=noninteractive \
    apt-get upgrade -y \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold"
}

apt_install() {
  step "Base packages / Установка пакетов"
  log "Installing required packages."

  apt-get install -y \
    openssh-server sudo ufw fail2ban \
    ca-certificates curl gnupg lsb-release \
    git jq unzip htop nano iproute2
}

hosts_hostname_line() {
  local hostname_value="$1"
  local short_name="${hostname_value%%.*}"

  if [[ "${short_name}" != "${hostname_value}" ]]; then
    printf '127.0.1.1\t%s %s\n' "${hostname_value}" "${short_name}"
  else
    printf '127.0.1.1\t%s\n' "${hostname_value}"
  fi
}

sync_hosts_hostname() {
  local hostname_value="$1"
  local tmp=""
  local hosts_line=""

  hosts_line="$(hosts_hostname_line "${hostname_value}")"
  tmp="$(mktemp)"

  [[ -f /etc/hosts ]] || touch /etc/hosts

  awk -v newline="${hosts_line}" '
    BEGIN { replaced = 0 }
    $1 == "127.0.1.1" {
      if (!replaced) {
        print newline
        replaced = 1
      }
      next
    }
    { print }
    END {
      if (!replaced) {
        print newline
      }
    }
  ' /etc/hosts > "${tmp}"

  install -m 644 "${tmp}" /etc/hosts
  rm -f "${tmp}"
}

configure_hostname() {
  local current_hostname=""

  [[ -n "${TARGET_HOSTNAME}" ]] || return 0

  step "Hostname / Имя сервера"

  current_hostname="$(current_static_hostname)"
  if [[ "${current_hostname}" == "${TARGET_HOSTNAME}" ]]; then
    log "Hostname already set to ${TARGET_HOSTNAME}; syncing /etc/hosts."
  else
    log "Changing hostname from ${current_hostname:-unknown} to ${TARGET_HOSTNAME}."
    hostnamectl set-hostname "${TARGET_HOSTNAME}"
  fi

  sync_hosts_hostname "${TARGET_HOSTNAME}"
}

ensure_admin_user() {
  local home=""
  local sudoers_file=""

  [[ -n "${ADMIN_USER}" ]] || return 0

  step "Admin user / Подготовка пользователя"

  if user_exists "${ADMIN_USER}"; then
    log "User ${ADMIN_USER} already exists."
    usermod -s /bin/bash "${ADMIN_USER}"
  else
    log "Creating user ${ADMIN_USER}."
    adduser --disabled-password --gecos "" "${ADMIN_USER}"
  fi

  groupadd -f sudo
  usermod -aG sudo "${ADMIN_USER}"

  sudoers_file="/etc/sudoers.d/90-vps-hardening-${ADMIN_USER}"
  cat > "${sudoers_file}" <<EOF
${ADMIN_USER} ALL=(ALL:ALL) NOPASSWD:ALL
EOF
  chmod 440 "${sudoers_file}"
  visudo -cf "${sudoers_file}" >/dev/null

  home="$(get_user_home "${ADMIN_USER}")"
  install -d -m 700 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "${home}/.ssh"
}

install_admin_keys() {
  local home=""
  local target=""
  local tmp=""
  local sudo_keys=""

  [[ -n "${ADMIN_USER}" ]] || return 0

  step "SSH keys / Подготовка ключей"

  home="$(get_user_home "${ADMIN_USER}")"
  target="${home}/.ssh/authorized_keys"
  tmp="$(mktemp)"

  if [[ -f "${target}" ]]; then
    extract_public_keys "${target}" >> "${tmp}"
  fi

  if [[ "${COPY_ROOT_KEYS}" == "yes" && -f /root/.ssh/authorized_keys ]]; then
    extract_public_keys /root/.ssh/authorized_keys >> "${tmp}"
  fi

  if [[ "${COPY_SUDO_USER_KEYS}" == "yes" ]]; then
    sudo_keys="$(sudo_user_keys_path 2>/dev/null || true)"
    if [[ -n "${sudo_keys}" ]]; then
      extract_public_keys "${sudo_keys}" >> "${tmp}"
    fi
  fi

  if [[ -n "${PASTED_PUBLIC_KEY}" ]]; then
    printf '%s\n' "${PASTED_PUBLIC_KEY}" >> "${tmp}"
  fi

  if [[ -s "${tmp}" ]]; then
    awk 'NF >= 2 && !seen[$1 " " $2]++' "${tmp}" > "${tmp}.uniq"
    install -m 600 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "${tmp}.uniq" "${target}"
    ADMIN_KEYS_READY="yes"
    log "Authorized keys installed for ${ADMIN_USER}."
  else
    ADMIN_KEYS_READY="no"
    warn_user "No SSH keys found for ${ADMIN_USER}. / Для ${ADMIN_USER} не найдено ни одного SSH-ключа."
  fi

  rm -f "${tmp}" "${tmp}.uniq"

  if [[ "${STRICT_SSH_HARDENING}" == "yes" && "${ADMIN_KEYS_READY}" != "yes" ]]; then
    STRICT_SSH_HARDENING="no"
    warn_user "Strict SSH lock-down was cancelled because keys are not ready. / Строгий SSH hardening отменён: ключи не подготовлены."
  fi
}

queue_deferred_user_deletion() {
  local user="$1"

  [[ -n "${user}" ]] || return 0
  case ",${DEFERRED_DELETE_USERS}," in
    *,"${user}",*) return 0 ;;
  esac

  if [[ -n "${DEFERRED_DELETE_USERS}" ]]; then
    DEFERRED_DELETE_USERS+=","
  fi
  DEFERRED_DELETE_USERS+="${user}"
}

delete_other_regular_users() {
  local user=""
  local found="no"
  local current_login=""

  [[ "${DELETE_OTHER_USERS}" == "yes" && -n "${ADMIN_USER}" ]] || return 0
  current_login="$(current_session_login_user 2>/dev/null || true)"

  if [[ "${SSH_TEST_CONFIRMED}" != "yes" ]]; then
    warn_user "Удаление пользователей пропущено: новый вход не подтверждён."
    return 0
  fi

  step "Удаление пользователей"

  while IFS= read -r user; do
    [[ -n "${user}" ]] || continue
    found="yes"

    if [[ "${user}" == "${current_login}" ]]; then
      queue_deferred_user_deletion "${user}"
      say "  ${user} -> будет удалён после завершения запуска"
      log "Отложено удаление текущего пользователя ${user} до завершения запуска."
      continue
    fi

    pkill -u "${user}" >/dev/null 2>&1 || true
    if userdel -r -f "${user}" >/dev/null 2>&1; then
      say "  ${user} -> deleted / удалён"
      log "Удалён пользователь ${user}."
    else
      warn_user "Не удалось удалить пользователя ${user}, продолжаю."
      log "Не удалось удалить пользователя ${user}."
    fi
  done < <(list_other_regular_users "${ADMIN_USER}")

  if [[ "${found}" != "yes" ]]; then
    say "Других пользователей для удаления нет."
  fi
}

run_deferred_user_deletions() {
  local user=""
  local users=()

  [[ -n "${DEFERRED_DELETE_USERS}" ]] || return 0
  IFS=',' read -r -a users <<< "${DEFERRED_DELETE_USERS}"

  for user in "${users[@]}"; do
    [[ -n "${user}" ]] || continue
    nohup bash -c "sleep 5; pkill -u '${user}' >/dev/null 2>&1 || true; userdel -r -f '${user}' >>'${LOG_FILE}' 2>&1 || true" >/dev/null 2>&1 &
    log "Запущено отложенное удаление пользователя ${user}."
  done
}

ensure_run_sshd_dir() {
  if [[ -e /run/sshd && ! -d /run/sshd ]]; then
    die "/run/sshd exists but is not a directory. / /run/sshd существует, но это не каталог."
  fi
  mkdir -p /run/sshd
  chmod 755 /run/sshd
}

ensure_sshd_include() {
  if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
    printf '\nInclude /etc/ssh/sshd_config.d/*.conf\n' >> /etc/ssh/sshd_config
  fi
}

ssh_socket_managed() {
  systemctl is-active --quiet ssh.socket || systemctl is-enabled ssh.socket >/dev/null 2>&1
}

disable_ssh_socket_activation() {
  if systemctl list-unit-files ssh.socket >/dev/null 2>&1; then
    systemctl stop ssh.socket >/dev/null 2>&1 || true
    systemctl disable ssh.socket >/dev/null 2>&1 || true
  fi

  rm -f "${SSH_SOCKET_DROPIN}" 2>/dev/null || true
  rmdir /etc/systemd/system/ssh.socket.d >/dev/null 2>&1 || true

  systemctl unmask ssh.service >/dev/null 2>&1 || true
  systemctl enable ssh.service >/dev/null 2>&1 || systemctl enable ssh >/dev/null 2>&1 || true
}

write_sshd_config() {
  local mode="$1"
  local ports=("${@:2}")
  local port=""

  ensure_sshd_include

  {
    echo "# Managed by vps-hardening"
    for port in "${ports[@]}"; do
      echo "Port ${port}"
    done
    echo "PubkeyAuthentication yes"
    echo "PermitEmptyPasswords no"
    echo "UsePAM yes"

    if [[ "${mode}" == "final" && "${STRICT_SSH_HARDENING}" == "yes" ]]; then
      echo "PermitRootLogin no"
      echo "PasswordAuthentication no"
      echo "KbdInteractiveAuthentication no"
      echo "ChallengeResponseAuthentication no"
    fi
  } > "${SSHD_DROPIN}"
}

assert_listening_port() {
  local port="$1"

  # Newer Ubuntu images may expose ssh.socket as [::]:PORT or *:PORT.
  ss -lntH "sport = :${port}" 2>/dev/null | awk '
    $1=="LISTEN" && $4 !~ /^(127\.0\.0\.1:|\[::1\]:)/ { ok=1 }
    END { exit(ok ? 0 : 1) }
  '
}

assert_ssh_banner() {
  local port="$1"

  timeout 6 bash -lc '
    exec 3<>"/dev/tcp/127.0.0.1/'"${port}"'"
    IFS= read -r -t 5 banner <&3 || exit 1
    [[ "${banner}" == SSH-* ]]
  ' >/dev/null 2>&1
}

assert_ssh_ready() {
  local port="$1"
  local attempt=""

  for attempt in 1 2 3 4 5 6 7 8; do
    if assert_listening_port "${port}" && assert_ssh_banner "${port}"; then
      return 0
    fi
    sleep 1
  done

  return 1
}

reload_ssh_stack() {
  systemctl daemon-reload

  systemctl restart ssh.service 2>/dev/null || systemctl restart ssh
}

configure_ssh_bootstrap() {
  local ports=("bootstrap" "22")

  step "SSH bootstrap / Подготовка SSH"

  if [[ "${SSH_PORT}" != "22" ]]; then
    ports+=("${SSH_PORT}")
  fi

  write_sshd_config "${ports[@]}"
  disable_ssh_socket_activation

  ensure_run_sshd_dir
  sshd -t
  reload_ssh_stack

  assert_ssh_ready "22" || die "SSH is not ready on port 22 after reload. / После reload SSH не готов на порту 22."
  if [[ "${SSH_PORT}" != "22" ]]; then
    assert_ssh_ready "${SSH_PORT}" || die "SSH is not ready on port ${SSH_PORT} after reload. / После reload SSH не готов на порту ${SSH_PORT}."
  fi
}

ufw_is_active() {
  command -v ufw >/dev/null 2>&1 || return 1
  ufw status 2>/dev/null | head -n 1 | grep -qi '^Status:[[:space:]]*active'
}

ufw_temp_allow_port() {
  local port="$1"
  ufw allow "${port}/tcp" comment "SSH temp checkpoint" >/dev/null 2>&1 || true
  ufw reload >/dev/null 2>&1 || true
}

checkpoint_ssh_access() {
  local test_user="root"

  if [[ "${ADMIN_KEYS_READY}" == "yes" ]]; then
    test_user="${ADMIN_USER}"
  fi

  if [[ "${SSH_PORT}" == "22" && "${STRICT_SSH_HARDENING}" != "yes" ]]; then
    return 0
  fi

  step "SSH checkpoint / Проверка входа"

  if ufw_is_active; then
    ufw_temp_allow_port "${SSH_PORT}"
  fi

  say "Open a second SSH session and keep this one open. / Открой вторую SSH-сессию и не закрывай текущую."
  if [[ -n "${PRIMARY_IP}" ]]; then
    say "Command / Команда:"
    say "  ssh -p ${SSH_PORT} ${test_user}@${PRIMARY_IP}"
  else
    say "Command / Команда:"
    say "  ssh -p ${SSH_PORT} ${test_user}@<server-ip>"
  fi

  if [[ "${STRICT_SSH_HARDENING}" == "yes" ]]; then
    say "Test the new admin user with a key. / Проверь вход новым пользователем по ключу."
  fi

  prompt_yesno "Confirm that the login worked? / Подтверждаешь, что вход сработал?" "no" || die "SSH checkpoint failed or was not confirmed. / Проверка SSH не подтверждена."
  SSH_TEST_CONFIRMED="yes"
}

configure_ssh_final() {
  local ports=("final" "${SSH_PORT}")

  step "SSH finalization / Финальная настройка SSH"

  [[ "${SSH_TEST_CONFIRMED}" == "yes" || "${SSH_PORT}" == "22" ]] || die "SSH finalization requires a confirmed SSH test. / Для финального SSH нужен подтверждённый тест входа."

  write_sshd_config "${ports[@]}"
  disable_ssh_socket_activation

  ensure_run_sshd_dir
  sshd -t
  reload_ssh_stack

  assert_ssh_ready "${SSH_PORT}" || die "SSH is not ready on port ${SSH_PORT} after finalization. / После финализации SSH не готов на порту ${SSH_PORT}."
}

rewrite_ufw_icmp_block() {
  local file="$1"
  local tmp=""

  [[ -f "${file}" ]] || die "Missing ${file}. / Не найден файл ${file}."
  tmp="$(mktemp)"

  awk '
    BEGIN {
      replaced = 0
      skip = 0
    }

    /^# ok icmp codes for INPUT$/ && !replaced {
      print "# ok icmp codes for INPUT"
      print "-A ufw-before-input -p icmp --icmp-type destination-unreachable -j DROP"
      print "-A ufw-before-input -p icmp --icmp-type time-exceeded -j DROP"
      print "-A ufw-before-input -p icmp --icmp-type parameter-problem -j DROP"
      print "-A ufw-before-input -p icmp --icmp-type echo-request -j DROP"
      print "-A ufw-before-input -p icmp --icmp-type source-quench -j DROP"
      print ""
      print "# ok icmp code for FORWARD"
      print "-A ufw-before-forward -p icmp --icmp-type destination-unreachable -j DROP"
      print "-A ufw-before-forward -p icmp --icmp-type time-exceeded -j DROP"
      print "-A ufw-before-forward -p icmp --icmp-type parameter-problem -j DROP"
      print "-A ufw-before-forward -p icmp --icmp-type echo-request -j DROP"
      print ""
      print "# allow dhcp client to work"
      replaced = 1
      skip = 1
      next
    }

    skip && /^# allow dhcp client to work$/ {
      skip = 0
      next
    }

    skip {
      next
    }

    {
      print
    }

    END {
      if (!replaced) {
        exit 42
      }
    }
  ' "${file}" > "${tmp}" || {
    rm -f "${tmp}"
    die "Failed to rewrite ICMP block in ${file}. / Не удалось переписать ICMP-блок в ${file}."
  }

  install -m 644 "${tmp}" "${file}"
  rm -f "${tmp}"
}

apply_ufw_icmp_baseline() {
  step "UFW baseline / ICMP-профиль"
  rewrite_ufw_icmp_block /etc/ufw/before.rules
}

apply_ufw_ports_from_csv() {
  local csv="$1"
  local proto="$2"
  local comment="$3"
  local token=""
  local spec=""
  local items=()

  [[ -n "${csv}" ]] || return 0
  IFS=',' read -r -a items <<< "${csv}"

  for token in "${items[@]}"; do
    [[ -n "${token}" ]] || continue
    spec="${token/-/:}"
    ufw allow "${spec}/${proto}" comment "${comment}"
  done
}

delete_managed_ufw_rules() {
  local number=""

  ufw status numbered 2>/dev/null | awk '
    /# Managed by vps-hardening$/ || /# vps-hardening ssh$/ || /# vps-hardening tcp$/ || /# vps-hardening udp$/ {
      if (match($0, /^\[[[:space:]]*([0-9]+)\]/, m)) {
        print m[1]
      }
    }
  ' | sort -rn | while read -r number; do
    [[ -n "${number}" ]] || continue
    ufw --force delete "${number}" >/dev/null 2>&1 || true
  done
}

remove_legacy_ufw_ssh_rule() {
  local previous_port="$1"
  local current_port="$2"

  [[ -n "${previous_port}" ]] || return 0
  [[ "${previous_port}" != "${current_port}" ]] || return 0

  ufw --force delete allow "${previous_port}/tcp" >/dev/null 2>&1 || true
}

configure_ufw() {
  step "Firewall / Настройка UFW"

  ufw default deny incoming
  ufw default allow outgoing

  apply_ufw_icmp_baseline
  delete_managed_ufw_rules
  remove_legacy_ufw_ssh_rule "${PREV_SSH_PORT}" "${SSH_PORT}"

  ufw allow "${SSH_PORT}/tcp" comment "vps-hardening ssh"
  apply_ufw_ports_from_csv "${ALLOW_TCP_PORTS}" "tcp" "vps-hardening tcp"
  apply_ufw_ports_from_csv "${ALLOW_UDP_PORTS}" "udp" "vps-hardening udp"

  if ufw_is_active; then
    ufw reload
  else
    ufw --force enable
  fi
}

current_ssh_client_ip() {
  local ip=""

  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    ip="$(awk '{print $1}' <<< "${SSH_CONNECTION}")"
  elif [[ -n "${SSH_CLIENT:-}" ]]; then
    ip="$(awk '{print $1}' <<< "${SSH_CLIENT}")"
  fi

  [[ "${ip}" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
  printf '%s\n' "${ip}"
}

configure_fail2ban() {
  local ignore_ip_line="127.0.0.1/8 ::1"
  local current_ip=""
  step "Fail2Ban / Настройка"

  mkdir -p /etc/fail2ban/jail.d

  current_ip="$(current_ssh_client_ip 2>/dev/null || true)"
  if [[ -n "${current_ip}" ]]; then
    ignore_ip_line+=" ${current_ip}"
  fi

  cat > "${FAIL2BAN_DROPIN}" <<EOF
[DEFAULT]
backend = systemd
banaction = ufw
bantime = 12h
findtime = 10m
maxretry = 4
usedns = warn
ignoreip = ${ignore_ip_line}

[sshd]
enabled = true
port = ${SSH_PORT}
mode = aggressive
maxretry = 3
findtime = 10m
bantime = 24h

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
bantime = 7d
findtime = 1d
maxretry = 5
EOF

  systemctl enable --now fail2ban
  systemctl restart fail2ban
}

sysctl_value_or_unknown() {
  local key="$1"
  local value=""

  value="$(sysctl -n "${key}" 2>/dev/null || true)"
  if [[ -n "${value}" ]]; then
    printf '%s' "${value}"
  else
    printf 'unknown / неизвестно'
  fi
}

backup_network_sysctl_conflicts() {
  local backup_dir="${SYSCTL_BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  local backed="no"
  local file=""
  local conflict_files=(
    "${SYSCTL_DROPIN}"
    "/etc/sysctl.d/99-vlf-net.conf"
    "/etc/sysctl.d/99-vlf-net-tune.conf"
    "/etc/sysctl.d/99-tcp-tuning.conf"
    "/etc/sysctl.d/10-bufferbloat.conf"
    "/etc/sysctl.d/99-sysctl.conf"
    "/etc/sysctl.conf"
  )

  SYSCTL_BACKUP_DIR=""

  for file in "${conflict_files[@]}"; do
    [[ -f "${file}" ]] || continue

    if [[ "${backed}" != "yes" ]]; then
      mkdir -p "${backup_dir}"
      backed="yes"
    fi

    cp -a "${file}" "${backup_dir}/"
  done

  if [[ "${backed}" == "yes" ]]; then
    SYSCTL_BACKUP_DIR="${backup_dir}"
    log "Backed up existing sysctl files to ${SYSCTL_BACKUP_DIR}."
  else
    log "No known sysctl conflict files found."
  fi
}

capture_network_sysctl_baseline() {
  local keys=(
    "net.ipv4.ip_forward"
    "net.core.default_qdisc"
    "net.ipv4.tcp_congestion_control"
    "net.core.rmem_max"
    "net.core.wmem_max"
    "net.ipv4.tcp_rmem"
    "net.ipv4.tcp_wmem"
    "net.core.netdev_max_backlog"
    "net.core.somaxconn"
    "net.ipv4.tcp_max_syn_backlog"
    "net.ipv4.tcp_mtu_probing"
    "net.ipv4.tcp_fastopen"
    "net.ipv4.tcp_slow_start_after_idle"
    "net.ipv4.tcp_keepalive_time"
    "net.ipv4.tcp_keepalive_intvl"
    "net.ipv4.tcp_keepalive_probes"
    "net.ipv4.tcp_retries2"
  )
  local key=""
  local value=""

  mkdir -p "${STATE_DIR}"

  {
    for key in "${keys[@]}"; do
      value="$(sysctl -n "${key}" 2>/dev/null || true)"
      [[ -n "${value}" ]] || continue
      printf '%s=%s\n' "${key}" "${value}"
    done
  } > "${SYSCTL_BASELINE_FILE}"

  chmod 600 "${SYSCTL_BASELINE_FILE}"
  log "Captured baseline sysctl values in ${SYSCTL_BASELINE_FILE}."
}

restore_network_sysctl_baseline() {
  local key=""
  local value=""

  [[ -f "${SYSCTL_BASELINE_FILE}" ]] || return 0

  while IFS='=' read -r key value; do
    [[ -n "${key}" ]] || continue
    sysctl -w "${key}=${value}" >/dev/null
  done < "${SYSCTL_BASELINE_FILE}"

  log "Restored baseline sysctl values from ${SYSCTL_BASELINE_FILE}."
}

write_network_sysctl_profile() {
  {
    echo "# Managed by vps-hardening"
    echo "# Network tuning: BBR, fq, buffers, backlog, keepalive, fastopen"
    echo
    echo "net.ipv4.ip_forward = $( [[ "${ENABLE_IP_FORWARD}" == "yes" ]] && echo 1 || echo 0 )"
    echo "net.core.default_qdisc = fq"
    echo "net.ipv4.tcp_congestion_control = bbr"
    echo
    echo "net.core.rmem_max = 67108864"
    echo "net.core.wmem_max = 67108864"
    echo "net.ipv4.tcp_rmem = 4096 87380 67108864"
    echo "net.ipv4.tcp_wmem = 4096 65536 67108864"
    echo
    echo "net.core.netdev_max_backlog = 250000"
    echo "net.core.somaxconn = 8192"
    echo "net.ipv4.tcp_max_syn_backlog = 8192"
    echo
    echo "net.ipv4.tcp_mtu_probing = 1"
    echo "net.ipv4.tcp_fastopen = 3"
    echo "net.ipv4.tcp_slow_start_after_idle = 0"
    echo
    echo "net.ipv4.tcp_keepalive_time = 45"
    echo "net.ipv4.tcp_keepalive_intvl = 10"
    echo "net.ipv4.tcp_keepalive_probes = 6"
    echo
    echo "net.ipv4.tcp_retries2 = 12"
  } > "${SYSCTL_DROPIN}"

  chmod 0644 "${SYSCTL_DROPIN}"
  log "Written network sysctl profile to ${SYSCTL_DROPIN}."
}

apply_network_sysctl_profile() {
  log "Applying sysctl profile."
  sysctl --system
}

log_network_tuning_status() {
  log "Network tuning verification:"
  sysctl \
    net.ipv4.ip_forward \
    net.core.default_qdisc \
    net.ipv4.tcp_congestion_control \
    net.core.rmem_max \
    net.core.wmem_max \
    net.ipv4.tcp_rmem \
    net.ipv4.tcp_wmem \
    net.core.netdev_max_backlog \
    net.core.somaxconn \
    net.ipv4.tcp_max_syn_backlog \
    net.ipv4.tcp_mtu_probing \
    net.ipv4.tcp_fastopen \
    net.ipv4.tcp_slow_start_after_idle \
    net.ipv4.tcp_keepalive_time \
    net.ipv4.tcp_keepalive_intvl \
    net.ipv4.tcp_keepalive_probes \
    net.ipv4.tcp_retries2

  if command -v tc >/dev/null 2>&1; then
    log "tc qdisc show:"
    tc qdisc show || true
  fi
}

disable_network_sysctl() {
  [[ -f "${SYSCTL_DROPIN}" ]] || return 0

  step "Network tuning / Отключение профиля"
  rm -f "${SYSCTL_DROPIN}"
  SYSCTL_BACKUP_DIR=""

  log "Removed managed network sysctl profile ${SYSCTL_DROPIN}."
  sysctl --system || true
  restore_network_sysctl_baseline || true
  rm -f "${SYSCTL_BASELINE_FILE}"
  warn_user "Managed network tuning profile was removed and baseline sysctl values were restored. / Профиль удалён, базовые sysctl-значения восстановлены."
}

configure_network_sysctl() {
  local already_managed="no"

  [[ -f "${SYSCTL_DROPIN}" ]] && already_managed="yes"

  if [[ "${ENABLE_NETWORK_TUNING}" != "yes" ]]; then
    disable_network_sysctl
    return 0
  fi

  step "Network tuning / Sysctl"
  if [[ "${already_managed}" != "yes" ]]; then
    capture_network_sysctl_baseline
  fi
  backup_network_sysctl_conflicts
  write_network_sysctl_profile
  apply_network_sysctl_profile
  log_network_tuning_status
}

print_runtime_status() {
  local ssh_user_status="no"
  local runtime_hostname=""

  [[ -n "${ADMIN_USER}" ]] && ssh_user_status="yes"
  runtime_hostname="$(current_static_hostname 2>/dev/null || true)"

  step "Summary / Сводка"
  say "Хост:"
  say "  Имя сервера: $(value_or_none "${runtime_hostname}")"

  say "SSH:"
  say "  Port / Порт: ${SSH_PORT}"
  say "  Root login disabled / Root login отключён: $(bool_or_no "${STRICT_SSH_HARDENING}")"
  say "  Password auth disabled / Парольный вход отключён: $(bool_or_no "${STRICT_SSH_HARDENING}")"
  say "  Admin user prepared / Admin-пользователь подготовлен: $(bool_or_no "${ssh_user_status}")"

  say "UFW / Firewall:"
  say "  Extra TCP ports / Доп. TCP-порты: $(csv_or_none "${ALLOW_TCP_PORTS}")"
  say "  Extra UDP ports / Доп. UDP-порты: $(csv_or_none "${ALLOW_UDP_PORTS}")"
  if command -v ufw >/dev/null 2>&1; then
    while IFS= read -r line; do
      [[ -n "${line}" ]] && say "  ${line}"
    done < <(ufw status numbered 2>/dev/null | sed '1d')
  fi

  say "Fail2Ban / Защита SSH:"
  if command -v fail2ban-client >/dev/null 2>&1; then
    while IFS= read -r line; do
      [[ -n "${line}" ]] && say "  ${line}"
    done < <(fail2ban-client status sshd 2>/dev/null | head -n 10 || true)
  fi

  say "Network tuning / Сетевой профиль:"
  say "  Enabled / Включён: $(bool_or_no "${ENABLE_NETWORK_TUNING}")"
  if [[ "${ENABLE_NETWORK_TUNING}" == "yes" ]]; then
    say "  IPv4 forwarding / Маршрутизация IPv4: $(bool_or_no "${ENABLE_IP_FORWARD}")"
    say "  Profile file / Файл профиля: ${SYSCTL_DROPIN}"
    say "  Backup dir / Каталог backup: $(value_or_none "${SYSCTL_BACKUP_DIR}")"
    say "  BBR / congestion control: $(sysctl_value_or_unknown net.ipv4.tcp_congestion_control)"
    say "  fq / default_qdisc: $(sysctl_value_or_unknown net.core.default_qdisc)"
    say "  tcp_fastopen: $(sysctl_value_or_unknown net.ipv4.tcp_fastopen)"
    say "  tcp_mtu_probing: $(sysctl_value_or_unknown net.ipv4.tcp_mtu_probing)"
  fi
}

main() {
  require_root
  tty_require
  console_init

  trap on_exit EXIT
  trap on_int INT

  interactive_setup
  confirm_configuration

  apt_update_and_upgrade
  apt_install

  configure_hostname
  ensure_admin_user
  install_admin_keys

  configure_ssh_bootstrap
  checkpoint_ssh_access
  configure_ssh_final
  delete_other_regular_users

  configure_ufw
  configure_fail2ban
  configure_network_sysctl

  print_runtime_status
  run_deferred_user_deletions
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
