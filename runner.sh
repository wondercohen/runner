#!/usr/bin/env bash
# SSH Runner — execute reviewed commands on localhost or configured SSH nodes.
#
# Each non-empty, non-comment line in a command file runs independently.
# Shell state does not persist between commands.
#
# Copyright (c) 2026 Wonder Cohen B.V. All rights reserved.
# SPDX-License-Identifier: BSD-3-Clause
#
# runner.cfg is parsed as plain data; it is never sourced or executed.

set -u
set -o pipefail

package="runner"
VERSION="1.1.0"
# Restrict permissions on generated log files.
umask 077
# Configuration is relative to the script, not the current working directory.
CONFIG_FILE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/runner.cfg"

# Trim surrounding horizontal whitespace without invoking shell evaluation.
trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

config_error() {
  printf 'ERROR: %s:%s: %s\n' "$CONFIG_FILE" "$1" "$2" >&2
  exit 1
}

# Only ~ and ~/... have special meaning in paths. NO shell-variable expansion.
expand_config_path() {
  case "$1" in
    '~') printf '%s\n' "$HOME" ;;
    \~/*) printf '%s/%s\n' "$HOME" "${1:2}" ;;
    /*) printf '%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

# Validate local config ownership and confidentiality before parsing it.
# GNU stat is standard on the Linux workstation where Runner is installed.
validate_private_file() {
  local file="$1" mode owner numeric_mode
  if [[ ! -f "$file" || ! -r "$file" || -L "$file" ]]; then
    echo "ERROR: Configuration must be a readable regular file, not a symlink: $file" >&2
    exit 1
  fi
  mode=$(stat -c %a -- "$file") || exit 1
  owner=$(stat -c %u -- "$file") || exit 1
  if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]]; then
    echo "ERROR: Cannot validate configuration permissions: $file" >&2
    exit 1
  fi
  numeric_mode=$((8#$mode))
  if (( (numeric_mode & 077) != 0 )) || [[ "$owner" != "$(id -u)" && "$owner" != "0" ]]; then
    echo "ERROR: runner.cfg must be owned by this user (or root), and inaccessible to group/others (chmod 600): $file" >&2
    exit 1
  fi
}

# Strict, data-only section configuration. No source, eval, interpolation,
# external parser, or executable declarations are involved.
load_config() {
  validate_private_file "$CONFIG_FILE"

  SSH_USER=''
  SSH_KEY_PATH=''
  LOG_DIR=''
  BECOME_DEFAULT='false'
  declare -gA NODE_MAP=() NODE_HOSTNAME=() HOST_SSH_KEY_PATH=() HOST_SSH_USER=() HOST_BECOME=() NODE_ROLE=()
  local line section='' node='' key value lineno=0 identity section_name address
  local -A seen_section=() seen_key=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    ((lineno+=1))
    line="${line%$'\r'}"
    line=$(trim "$line")
    [[ -z "$line" || "$line" == \#* || "$line" == \;* ]] && continue

    if [[ "$line" == \[*\] ]]; then
      if [[ "$line" == '[global]' ]]; then
        section='global'; node=''; section_name='global'
      elif [[ "$line" =~ ^\[node:([0-9]+)\]$ ]]; then
        section='node'; node="${BASH_REMATCH[1]}"; section_name="node:$node"
      else
        config_error "$lineno" "Invalid section [$line] (expected [global] or [node:N])."
      fi
      [[ -z "${seen_section[$section_name]:-}" ]] || config_error "$lineno" "Duplicate section: $section_name"
      seen_section[$section_name]=1
      continue
    fi

    [[ -n "$section" && "$line" == *=* ]] || config_error "$lineno" 'Expected section header or key = value.'
    key=$(trim "${line%%=*}")
    value=$(trim "${line#*=}")
    [[ "$key" =~ ^[a-z_]+$ ]] || config_error "$lineno" "Invalid setting name: $key"
    identity="$section_name:$key"
    [[ -z "${seen_key[$identity]:-}" ]] || config_error "$lineno" "Duplicate setting: $identity"
    seen_key[$identity]=1
    [[ ! "$value" =~ [[:cntrl:]] ]] || config_error "$lineno" 'Control character in configuration value.'

    if [[ "$section" == global ]]; then
      case "$key" in
        ssh_user) SSH_USER="$value" ;;
        ssh_key_path) SSH_KEY_PATH="$value" ;;
        log_dir) LOG_DIR="$value" ;;
        become) BECOME_DEFAULT="$value" ;;
        *) config_error "$lineno" "Unknown global setting: $key" ;;
      esac
    else
      case "$key" in
        ip) NODE_MAP[$node]="$value" ;;
        hostname) NODE_HOSTNAME[$node]="$value" ;;
        ssh_user) HOST_SSH_USER[$node]="$value" ;;
        ssh_key_path) HOST_SSH_KEY_PATH[$node]="$value" ;;
        become) HOST_BECOME[$node]="$value" ;;
        role) NODE_ROLE[$node]="$value" ;;
        *) config_error "$lineno" "Unknown node setting: $key" ;;
      esac
    fi
  done < "$CONFIG_FILE"

  [[ -n "${seen_section[global]:-}" ]] || config_error 'EOF' 'Missing [global] section.'
  [[ -n "$SSH_USER" && -n "$SSH_KEY_PATH" ]] || config_error 'EOF' 'Missing global ssh_user or ssh_key_path.'
  [[ "$SSH_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*\$?$ ]] || config_error 'EOF' 'Invalid global SSH user.'
  [[ "$BECOME_DEFAULT" == true || "$BECOME_DEFAULT" == false ]] || config_error 'EOF' 'Global become must be true or false.'
  SSH_KEY_PATH=$(expand_config_path "$SSH_KEY_PATH") || config_error 'EOF' 'Global ssh_key_path must be absolute or begin with ~/.'
  LOG_DIR=$(expand_config_path "${LOG_DIR:-~/.local/state/runner}") || config_error 'EOF' 'log_dir must be absolute or begin with ~/.'
  (( ${#NODE_MAP[@]} > 0 )) || config_error 'EOF' 'No nodes defined.'

  local label prior
  for label in "${!seen_section[@]}"; do
    [[ "$label" == node:* ]] || continue
    node="${label#node:}"
    address="${NODE_MAP[$node]:-}"
    [[ -n "$address" && -n "${NODE_HOSTNAME[$node]:-}" ]] || config_error 'EOF' "Node $node missing ip or hostname."
    [[ "$address" =~ ^[a-zA-Z0-9][a-zA-Z0-9:._-]*$ ]] || config_error 'EOF' "Invalid IP/address for node $node."
    [[ "${NODE_HOSTNAME[$node]}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || config_error 'EOF' "Invalid hostname for node $node."
    for prior in "${!NODE_MAP[@]}"; do
      [[ "$prior" == "$node" ]] && continue
      if [[ "${NODE_MAP[$prior]}" == "$address" || "${NODE_HOSTNAME[$prior]}" == "${NODE_HOSTNAME[$node]}" ]]; then
        config_error 'EOF' "Duplicate node address or hostname: $node and $prior."
      fi
    done
    HOST_SSH_USER[$node]="${HOST_SSH_USER[$node]:-$SSH_USER}"
    [[ "${HOST_SSH_USER[$node]}" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*\$?$ ]] || config_error 'EOF' "Invalid SSH user for node $node."
    HOST_SSH_KEY_PATH[$node]=$(expand_config_path "${HOST_SSH_KEY_PATH[$node]:-$SSH_KEY_PATH}") || config_error 'EOF' "Invalid SSH key path for node $node."
    HOST_BECOME[$node]="${HOST_BECOME[$node]:-$BECOME_DEFAULT}"
    [[ "${HOST_BECOME[$node]}" == true || "${HOST_BECOME[$node]}" == false ]] || config_error 'EOF' "Invalid become for node $node."
  done
}

# Selected targets are stored as stable node IDs (not IPs or hostnames).
# This keeps per-node SSH credentials and the -ip override independent.
connection_address() {
  local label="$1"
  if [[ "$label" == "localhost" ]]; then
    printf '%s\n' localhost
  elif (( USE_IP )); then
    printf '%s\n' "${NODE_MAP[$label]}"
  else
    printf '%s\n' "${NODE_HOSTNAME[$label]}"
  fi
}

LOGFILE=""
SELECTED_HOSTS=()
CMDS=()
FILE=""
SKIP_CONFIRM=0
ALL_REMOTE=0
USE_IP=0
NONZERO_COUNT=0
STARTED_SSH_AGENT=0
BECOME_OVERRIDE=""
SKIPPED_COUNT=0
BECOME_ERROR=0
TRANSPORT_ERROR=0
TEMP_FILES=()

# ---------- SSH agent handling ----------
# Scoped to this script's own process tree only — it cannot persist back into
# the parent interactive shell. This function is called only when at least one
# remote host is actually targeted.
#
# ssh-add -l return codes used here:
#   0 = agent reachable and identities exist
#   1 = agent reachable but has no identities
#   2 = agent is unavailable/unreachable

ensure_ssh_agent() {
  local key="$1" agent_rc=0 expected_fp=""

  if [[ ! -f "$key" || ! -r "$key" ]]; then
    echo "ERROR: SSH private key not readable: $key" >&2
    exit 1
  fi

  if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
    eval "$(ssh-agent -s)" >/dev/null || exit 1
    STARTED_SSH_AGENT=1
  else
    ssh-add -l >/dev/null 2>&1 || agent_rc=$?
    if [[ "$agent_rc" -eq 2 ]]; then
      eval "$(ssh-agent -s)" >/dev/null || exit 1
      STARTED_SSH_AGENT=1
    fi
  fi

  expected_fp=$(ssh-keygen -lf "$key" 2>/dev/null | awk '{print $2}')
  if [[ -z "$expected_fp" ]]; then
    echo "ERROR: Unable to determine fingerprint of SSH key: $key" >&2
    exit 1
  fi

  if ! ssh-add -l 2>/dev/null | awk '{print $2}' | grep -Fxq "$expected_fp"; then
    ssh-add "$key" || {
      echo "ERROR: Failed to load SSH key into agent: $key" >&2
      exit 1
    }
  fi
}

# ShellCheck cannot detect that cleanup is invoked by the EXIT trap.
# shellcheck disable=SC2317
cleanup() {
  local tmp
  for tmp in "${TEMP_FILES[@]}"; do
    [[ -z "$tmp" ]] || rm -f -- "$tmp"
  done
  if [ "$STARTED_SSH_AGENT" -eq 1 ]; then
    ssh-agent -k >/dev/null 2>&1 || true
  fi
}

# ---------- Output helpers ----------

print_version() {
  printf 'SSH Runner v%s\n' "$VERSION"
  printf 'Copyright (c) 2026 Wonder Cohen B.V.\n'
  printf 'License: BSD-3-Clause\n'
}

print_run_header() {
  echo "=========================================="
  echo "$package — run started: $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
  echo "=========================================="
}

list_nodes() {
  echo "Known remote nodes (from $CONFIG_FILE):"
  local label
  for label in "${!NODE_MAP[@]}"; do
    printf "  %-20s = %-18s label=%s  (%s)  user=%s  key=%s  become=%s\n" \
      "${NODE_HOSTNAME[$label]}" "${NODE_MAP[$label]}" "$label" \
      "${NODE_ROLE[$label]:-${NODE_HOSTNAME[$label]}}" "${HOST_SSH_USER[$label]}" "${HOST_SSH_KEY_PATH[$label]}" "${HOST_BECOME[$label]}"
  done | sort
  echo " "
  echo "Special target:"
  echo "  localhost    (default target — commands run directly, no SSH; become=$BECOME_DEFAULT)"
}

usage() {
  echo "$package - run a reviewed command set on localhost or across configured SSH nodes"
  echo "Node inventory, SSH users and SSH keys are configured in $CONFIG_FILE (data-only sections)"
  echo " "
  echo "$package [options]   (flags may be given in any order)"
  echo " "
  echo "options:"
  echo "-h, --help                           show this help"
  echo "-V, --version                        show version and exit"
  echo "-l, --list                           list known nodes and exit"
  echo "-c, --cmd=\"<command>\"               run one ad-hoc command"
  echo "-f, --file=<path>                    run every command line in <path>"
  echo "-n, --node=<hostname|N|ip> [...]  target one or more nodes; repeat -n or"
  echo "                                      list multiple targets after one -n"
  echo "-a, --all                            target all configured remote nodes"
  echo "-ip, --ip                            connect by IP instead of hostname"
  echo "-b, --become                        run selected commands through sudo as root"
  echo "--no-become                         run without automatic sudo (override config)"
  echo "-y, --yes                            skip the confirmation prompt (use sparingly)"
  echo " "
  echo "Default target (no -a, no -n): localhost, run directly with bash — no SSH involved."
  echo "Remote connections use NODE_HOSTNAME unless -ip is specified."
  echo "Become defaults to BECOME_DEFAULT and each node may override it."
  echo "Become opens one interactive SSH session per node for all commands."
  echo "Run become mode from a terminal; the server's sudo/PAM handles authentication."
  echo " "
  echo "A -f file is line-oriented: each non-empty, non-comment line is an independent"
  echo "command. Shell state such as cd, variables, and shell options does not persist"
  echo "from one line to the next."
  echo " "
  echo "Exit status of every command is reported neutrally as exit_status=N."
  echo "Non-zero is not automatically a failure; interpret it in command context."
  echo " "
  list_nodes
  echo " "
  echo "Examples:"
  echo "  $package --version"
  echo "  $package -l"
  echo "  $package -c \"pwd\""
  echo "  $package -f checks/system-info.txt"
  echo "  $package -c \"hostname\" -a"
  echo "  $package -n 1 -f checks/system-info.txt"
  echo "  $package -n 1 localhost -c \"hostname\""
  echo "  $package -a -ip -f checks/system-info.txt"
  echo "  $package --become -n 1 -c 'id -u'"
  echo "  $package --no-become -a -c 'id -un'"
}

# ---------- Node resolution ----------

resolve_node() {
  local input="$1" label

  if [[ "$input" == "localhost" ]]; then
    printf '%s\n' localhost
    return 0
  fi

  if [[ "$input" =~ ^[0-9]+$ && -n "${NODE_MAP[$input]:-}" ]]; then
    printf '%s\n' "$input"
    return 0
  fi

  # Accept node ID, configured hostname or configured IP as input.
  # The connection itself still follows the default hostname / -ip setting.
  for label in "${!NODE_MAP[@]}"; do
    if [[ "${NODE_HOSTNAME[$label]}" == "$input" || "${NODE_MAP[$label]}" == "$input" ]]; then
      printf '%s\n' "$label"
      return 0
    fi
  done

  echo "ERROR: '$input' is not a recognised target. Run with -l to see known nodes." >&2
  return 1
}

append_host_unique() {
  local candidate="$1"
  local host

  for host in "${SELECTED_HOSTS[@]:-}"; do
    [ "$host" == "$candidate" ] && return 0
  done

  SELECTED_HOSTS+=("$candidate")
}

# ---------- Argument parsing ----------

parse_args() {
  while test $# -gt 0; do
    case "$1" in
      -V|--version)
        print_version
        exit 0
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -l|--list)
        list_nodes
        exit 0
        ;;
      -c|--cmd)
        shift
        if [ $# -eq 0 ]; then
          echo "ERROR: -c requires a command argument." >&2
          exit 1
        fi
        CMDS+=("$1")
        shift
        ;;
      --cmd=*)
        CMDS+=("${1#*=}")
        shift
        ;;
      -f|--file)
        shift
        if [ $# -eq 0 ]; then
          echo "ERROR: -f requires a file path argument." >&2
          exit 1
        fi
        FILE="$1"
        shift
        ;;
      --file=*)
        FILE="${1#*=}"
        shift
        ;;
      -n|--node)
        shift
        if [ $# -eq 0 ] || [[ "$1" == -* ]]; then
          echo "ERROR: -n requires at least one node argument." >&2
          exit 1
        fi
        while [ $# -gt 0 ] && [[ "$1" != -* ]]; do
          local resolved
          resolved=$(resolve_node "$1") || exit 1
          append_host_unique "$resolved"
          shift
        done
        ;;
      --node=*)
        local resolved
        resolved=$(resolve_node "${1#*=}") || exit 1
        append_host_unique "$resolved"
        shift
        ;;
      -a|--all)
        ALL_REMOTE=1
        shift
        ;;
      -ip|--ip)
        USE_IP=1
        shift
        ;;
      -b|--become)
        BECOME_OVERRIDE="true"
        shift
        ;;
      --no-become)
        BECOME_OVERRIDE="false"
        shift
        ;;
      -y|--yes)
        SKIP_CONFIRM=1
        shift
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

# ---------- Validation ----------

apply_defaults_and_validate() {
  local label line

  # -a adds all known remote nodes to any explicitly selected targets.
  if [ "$ALL_REMOTE" -eq 1 ]; then
    while IFS= read -r label; do
      append_host_unique "$label"
    done < <(printf '%s\n' "${!NODE_MAP[@]}" | sort -n)
  fi

  # No -a and no -n: localhost only.
  if [ "${#SELECTED_HOSTS[@]}" -eq 0 ]; then
    SELECTED_HOSTS+=("localhost")
  fi

  if [ -n "$FILE" ]; then
    if [ ! -f "$FILE" ]; then
      echo "ERROR: File not found: $FILE" >&2
      exit 1
    fi
    if [ ! -r "$FILE" ]; then
      echo "ERROR: File not readable (check permissions): $FILE" >&2
      exit 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      CMDS+=("$line")
    done < "$FILE"
  fi

  if [ "${#CMDS[@]}" -eq 0 ]; then
    echo "ERROR: No command supplied. Use -c or -f." >&2
    usage
    exit 1
  fi

  # Log files are uniquely created; reject shared or symlinked log folders.
  if [[ -L "$LOG_DIR" ]] || ! mkdir -p -- "$LOG_DIR"; then
    echo "ERROR: Unsafe or inaccessible log directory: $LOG_DIR" >&2
    exit 1
  fi
  local dir_mode dir_owner
  dir_mode=$(stat -c %a -- "$LOG_DIR") || exit 1
  dir_owner=$(stat -c %u -- "$LOG_DIR") || exit 1
  if [[ "$dir_owner" != "$(id -u)" ]] || (( (8#$dir_mode & 077) != 0 )); then
    echo "ERROR: Log directory must be owned by the current user and private (chmod 700): $LOG_DIR" >&2
    exit 1
  fi
  LOGFILE=$(mktemp "${LOG_DIR%/}/runner_$(date +%Y%m%d_%H%M%S)_XXXXXXXX") || {
    echo 'ERROR: Cannot create private log file.' >&2
    exit 1
  }

}

# ---------- Confirmation ----------

confirm_run() {
  local host destination destinations=()
  for host in "${SELECTED_HOSTS[@]}"; do
    destination=$(connection_address "$host")
    destinations+=("$destination")
  done
  echo "The following ${#CMDS[@]} command(s) will run on: ${destinations[*]}"
  echo "Privileges by target (sudo runs as root only when become=true):"
  for host in "${SELECTED_HOSTS[@]}"; do
    destination=$(connection_address "$host")
    printf '  %-26s become=%s\n' "$destination" "$(become_for_host "$host")"
  done
  echo "---"
  local c
  for c in "${CMDS[@]}"; do
    echo "  $c"
  done
  echo "---"

  if [ "$SKIP_CONFIRM" -ne 1 ]; then
    local answer
    read -r -p "Proceed? [y/N] " answer
    case "$answer" in
      [yY][eE][sS]|[yY]) ;;
      *) echo "Aborted. Nothing was run."; exit 0 ;;
    esac
  fi
}

# ---------- Execution ----------

# Only Runner decides WHETHER to sudo. PAM and sudoers decide HOW to
# authenticate. No password/TOTP is collected, generated, or stored here.
# The single privileged bash process is appropriate for trusted admin
# accounts with broad sudo rights, not restricted sudo command allowlists.

become_for_host() {
  local host="$1"
  if [[ -n "$BECOME_OVERRIDE" ]]; then
    printf '%s\n' "$BECOME_OVERRIDE"
  elif [[ "$host" == "localhost" ]]; then
    printf '%s\n' "$BECOME_DEFAULT"
  else
    printf '%s\n' "${HOST_BECOME[$host]}"
  fi
}

# POSIX shell single-quoting, including arbitrary literal single quotes.
shell_quote() {
  local value="$1"
  value="${value//\'/\'\\\'\'}"
  printf "'%s'" "$value"
}

# Runs each command in an independent bash -c *inside one sudo invocation*.
# Marker lines let Runner recover per-command statuses from one SSH session.
build_become_script() {
  local address="$1" marker="$2" c idx=0 qcommand qheader
  BECOME_SCRIPT=''
  for c in "${CMDS[@]}"; do
    qcommand=$(shell_quote "$c")
    qheader=$(shell_quote "=== ${address} — ${c} —")
    BECOME_SCRIPT+="printf '%s %s ===\\n' $qheader \"\$(date -u +%FT%TZ)\""$'\n'
    BECOME_SCRIPT+="/bin/bash -c $qcommand"$'\n'
    BECOME_SCRIPT+='__runner_rc=$?'$'\n'
    BECOME_SCRIPT+="printf '\\n%s:%s\\n' ${marker}${idx} \"\$__runner_rc\""$'\n'
    BECOME_SCRIPT+="printf '\\n'"$'\n'
    idx=$((idx+1))
  done
  BECOME_SCRIPT+='exit 0'$'\n'
}

# One SSH session and one sudo call for all commands on this host.
# sudo uses the remote terminal to prompt according to server PAM policy.
# Terminal input is NOT recorded by Runner; command output still is.
run_become_host() {
  local host="$1" address="$2" marker status_file ssh_rc idx rc expected=0
  local key user q_script remote_cmd line remainder

  if [[ ! -t 0 ]]; then
    echo "ERROR: Become mode requires an interactive terminal (stdin must be a TTY)." >&2
    SKIPPED_COUNT=$((SKIPPED_COUNT + ${#CMDS[@]}))
    BECOME_ERROR=1
    return 1
  fi

  status_file=$(mktemp "${LOG_DIR%/}/.runner_status.XXXXXXXX") || {
    echo "ERROR: Could not create private status file." >&2
    SKIPPED_COUNT=$((SKIPPED_COUNT + ${#CMDS[@]}))
    BECOME_ERROR=1
    return 1
  }
  TEMP_FILES+=("$status_file")
  marker="__RUNNER_RESULT_${BASHPID}_${RANDOM}_${RANDOM}_"
  build_become_script "$address" "$marker"

  # Do NOT pipe a password or TOTP through SSH stdin. Use remote sudo's
  # interactive /dev/tty. -tt allocates a remote PTY; -n is intentionally absent.
  if [[ "$host" == "localhost" ]]; then
    sudo -H -- /bin/bash -c "$BECOME_SCRIPT" 2>&1 |
      process_become_output "$marker" "$status_file" | tee -a "$LOGFILE"
    ssh_rc=${PIPESTATUS[0]}
  else
    key="${HOST_SSH_KEY_PATH[$host]}"
    user="${HOST_SSH_USER[$host]}"
    q_script=$(shell_quote "$BECOME_SCRIPT")
    remote_cmd="sudo -H -- /bin/bash -c ${q_script}"
    ssh -tt -i "$key" -o IdentitiesOnly=yes -o ConnectTimeout=10 \
      -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes \
      "${user}@${address}" "$remote_cmd" 2>&1 |
      process_become_output "$marker" "$status_file" | tee -a "$LOGFILE"
    ssh_rc=${PIPESTATUS[0]}
  fi

  while read -r idx rc; do
    if [[ "$idx" == "$expected" && "$rc" =~ ^[0-9]+$ && "$rc" -le 255 ]]; then
      if (( rc != 0 )); then
        NONZERO_COUNT=$((NONZERO_COUNT+1))
      fi
      expected=$((expected+1))
    else
      echo "ERROR: Invalid command status sequence from ${address}." | tee -a "$LOGFILE" >&2
      BECOME_ERROR=1
      break
    fi
  done < "$status_file"

  if (( expected < ${#CMDS[@]} )); then
    SKIPPED_COUNT=$((SKIPPED_COUNT + ${#CMDS[@]} - expected))
    echo "ERROR: ${address}: ${#CMDS[@]} command(s) requested; only ${expected} status(es) confirmed. Remaining outcomes unknown." | tee -a "$LOGFILE" >&2
    BECOME_ERROR=1
  fi
  if (( ssh_rc != 0 )); then
    echo "ERROR: ${address}: SSH/sudo session returned exit_status=${ssh_rc}." | tee -a "$LOGFILE" >&2
    BECOME_ERROR=1
  fi
  [[ "$BECOME_ERROR" -eq 0 ]]
}

# Process newline-delimited result markers, but also flush incomplete lines
# promptly so an interactive sudo/PAM prompt WITHOUT a newline remains visible.
process_become_output() {
  local marker="$1" status_file="$2" chunk pending='' remainder idx rc read_rc
  while :; do
    chunk=''
    IFS= read -r -t 0.2 chunk
    read_rc=$?
    pending+="$chunk"
    if (( read_rc == 0 )); then
      pending="${pending%$'\r'}"
      if [[ "$pending" == "$marker"* ]]; then
        remainder="${pending#"$marker"}"
        if [[ "$remainder" =~ ^([0-9]+):([0-9]+)$ ]]; then
          idx="${BASH_REMATCH[1]}"
          rc="${BASH_REMATCH[2]}"
          printf '%s %s\n' "$idx" "$rc" >> "$status_file"
          printf '%s\n' "--- exit_status=${rc} ---"
          pending=''
          continue
        fi
      fi
      printf '%s\n' "$pending"
      pending=''
    elif (( read_rc == 1 )); then
      [[ -z "$pending" ]] || printf '%s' "$pending"
      break
    elif [[ -n "$pending" && "$marker" != "$pending"* ]]; then
      # Timeout: show partially received output (e.g. "Password:") but
      # keep an incomplete status marker buffered until newline or EOF.
      printf '%s' "$pending"
      pending=''
    fi
  done
}

# Reports the literal exit status of every command, neutrally, with no
# success/failure judgment attached. Non-zero is not automatically a failure.
#
# "localhost" runs directly with bash -c and does not invoke SSH. All other
# targets are reached over SSH as their configured SSH user.

run_all() {
  local host c rc key user address idx

  for host in "${SELECTED_HOSTS[@]}"; do
    address=$(connection_address "$host")
    if [[ "$(become_for_host "$host")" == "true" ]]; then
      run_become_host "$host" "$address" || true
      continue
    fi
    for idx in "${!CMDS[@]}"; do
      c="${CMDS[$idx]}"
      echo "=== ${address} — ${c} — $(date -u +%FT%TZ) ===" | tee -a "$LOGFILE"

      if [ "$host" == "localhost" ]; then
        bash -c "$c" 2>&1 | tee -a "$LOGFILE"
      else
        key="${HOST_SSH_KEY_PATH[$host]}"
        user="${HOST_SSH_USER[$host]}"
        ssh -n -i "$key" -o IdentitiesOnly=yes -o ConnectTimeout=10 \
          -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes \
          "${user}@${address}" "$c" 2>&1 | tee -a "$LOGFILE"
      fi

      rc=${PIPESTATUS[0]}
      echo "--- exit_status=${rc} ---" | tee -a "$LOGFILE"
      if [ "$rc" -ne 0 ]; then
        NONZERO_COUNT=$((NONZERO_COUNT + 1))
      fi
      echo | tee -a "$LOGFILE"
      # SSH reserves 255 for errors, though remote commands may also return
      # 255. Treat it as ambiguous and skip further commands on this node;
      # never replay potentially side-effecting commands automatically.
      if [[ "$host" != localhost && "$rc" -eq 255 ]]; then
        echo "WARNING: ${address}: SSH returned 255 (transport/authentication failure or remote exit 255). Skipping remaining commands on this node; outcome may be uncertain." | tee -a "$LOGFILE" >&2
        TRANSPORT_ERROR=1
        SKIPPED_COUNT=$((SKIPPED_COUNT + ${#CMDS[@]} - idx - 1))
        break
      fi
    done
  done
}

# ---------- Main ----------

main() {
  trap cleanup EXIT

  # Version information must work even before runner.cfg is created.
  if [[ $# -eq 1 && ( "$1" == "--version" || "$1" == "-V" ) ]]; then
    print_version
    exit 0
  fi

  load_config
  parse_args "$@"
  apply_defaults_and_validate

  local host key
  # Load only keys for selected remote targets; localhost needs no SSH key.
  for host in "${SELECTED_HOSTS[@]}"; do
    if [[ "$host" != "localhost" ]]; then
      key="${HOST_SSH_KEY_PATH[$host]}"
      ensure_ssh_agent "$key"
    fi
  done

  confirm_run
  print_run_header | tee -a "$LOGFILE"
  run_all

  echo "Log saved: $LOGFILE"
  echo "${NONZERO_COUNT} command(s) returned a non-zero exit status; ${SKIPPED_COUNT} command(s) skipped or unconfirmed."
  if [[ "$BECOME_ERROR" -ne 0 || "$TRANSPORT_ERROR" -ne 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
