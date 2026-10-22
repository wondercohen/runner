#!/usr/bin/env bash
# SSH Runner — execute reviewed commands on localhost or configured SSH nodes.
#
# Each non-empty, non-comment line in a command file runs independently.
# Shell state does not persist between commands.
#
# Copyright (c) 2026 Wonder Cohen B.V. All rights reserved.
# SPDX-License-Identifier: BSD-3-Clause
#
# IMPORTANT: runner.cfg is sourced as Bash code. Only use trusted config files.

set -u
set -o pipefail

package="runner"
# Restrict permissions on generated log files.
umask 077
# Configuration is relative to the script, not the current working directory.
CONFIG_FILE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/runner.cfg"

load_config() {
  if [[ ! -f "$CONFIG_FILE" || ! -r "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration not readable: $CONFIG_FILE" >&2
    exit 1
  fi

  # runner.cfg is Bash code: use only a trusted, locally maintained file.
  source "$CONFIG_FILE"
  if [[ -z "${SSH_KEY_PATH:-}" || -z "${SSH_USER:-}" ]] || ! declare -p NODE_INVENTORY &>/dev/null; then
    echo "ERROR: Missing SSH_KEY_PATH, SSH_USER or NODE_INVENTORY in $CONFIG_FILE" >&2
    exit 1
  fi

  LOG_DIR="${LOG_DIR:-${HOME}/.local/state/runner}"
  LOGFILE="${LOG_DIR%/}/runner_$(date +%Y%m%d_%H%M%S).log"

  # Derived lookup arrays are kept for compatibility with node resolution.
  declare -gA NODE_MAP=() NODE_HOSTNAME=() HOST_SSH_KEY_PATH=() HOST_SSH_USER=()
  local label record ip name key user extra prior
  for label in "${!NODE_INVENTORY[@]}"; do
    record="${NODE_INVENTORY[$label]}"
    IFS='|' read -r ip name key user extra <<< "$record"
    if [[ ! "$label" =~ ^[0-9]+$ || -z "$ip" || -z "$name" || -n "${extra:-}" || "$record" != *'|'*'|'*'|'* ]]; then
      echo "ERROR: Invalid node inventory record [$label]: $record" >&2
      exit 1
    fi
    for prior in "${!NODE_MAP[@]}"; do
      if [[ "${NODE_MAP[$prior]}" == "$ip" || "${NODE_HOSTNAME[$prior]}" == "$name" ]]; then
        echo "ERROR: Duplicate IP or hostname in node [$label] and [$prior]." >&2
        exit 1
      fi
    done
    NODE_MAP[$label]="$ip"
    NODE_HOSTNAME[$label]="$name"
    HOST_SSH_KEY_PATH[$label]="${key:-$SSH_KEY_PATH}"
    HOST_SSH_USER[$label]="${user:-$SSH_USER}"
    if [[ ! "${HOST_SSH_USER[$label]}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
      echo "ERROR: Invalid SSH username for node [$label]." >&2
      exit 1
    fi
  done
  if (( ${#NODE_MAP[@]} == 0 )); then
    echo "ERROR: NODE_INVENTORY is empty in $CONFIG_FILE" >&2
    exit 1
  fi
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

cleanup() {
  if [ "$STARTED_SSH_AGENT" -eq 1 ]; then
    ssh-agent -k >/dev/null 2>&1 || true
  fi
}

# ---------- Output helpers ----------

print_run_header() {
  echo "=========================================="
  echo "$package — run started: $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
  echo "=========================================="
}

list_nodes() {
  echo "Known remote nodes (from $CONFIG_FILE):"
  local label
  for label in "${!NODE_MAP[@]}"; do
    printf "  %-20s = %-18s label=%s  (%s)  user=%s  key=%s\n" \
      "${NODE_HOSTNAME[$label]}" "${NODE_MAP[$label]}" "$label" \
      "${NODE_ROLE[$label]:-${NODE_HOSTNAME[$label]}}" "${HOST_SSH_USER[$label]}" "${HOST_SSH_KEY_PATH[$label]}"
  done | sort
  echo " "
  echo "Special target:"
  echo "  localhost    (default target — commands run directly, no SSH)"
}

usage() {
  echo "$package - run a reviewed command set on localhost or across configured SSH nodes"
  echo "Node inventory, SSH users and SSH keys are configured in $CONFIG_FILE"
  echo " "
  echo "$package [options]   (flags may be given in any order)"
  echo " "
  echo "options:"
  echo "-h, --help                           show this help"
  echo "-l, --list                           list known nodes and exit"
  echo "-c, --cmd=\"<command>\"               run one ad-hoc command"
  echo "-f, --file=<path>                    run every command line in <path>"
  echo "-n, --node=<hostname|N|ip> [...]  target one or more nodes; repeat -n or"
  echo "                                      list multiple targets after one -n"
  echo "-a, --all                            target all known remote Git nodes"
  echo "-ip, --ip                            connect by IP instead of hostname"
  echo "-y, --yes                            skip the confirmation prompt (use sparingly)"
  echo " "
  echo "Default target (no -a, no -n): localhost, run directly with bash — no SSH involved."
  echo "Remote connections use NODE_HOSTNAME unless -ip is specified."
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
  echo "  $package -l"
  echo "  $package -c \"pwd\""
  echo "  $package -f checks/system-info.txt"
  echo "  $package -c \"hostname\" -a"
  echo "  $package -n 1 -f checks/system-info.txt"
  echo "  $package -n 1 localhost -c \"hostname\""
  echo "  $package -a -ip -f checks/system-info.txt"
}

# ---------- Node resolution ----------

resolve_node() {
  local input="$1" label

  if [[ "$input" == "localhost" ]]; then
    printf '%s\n' localhost
    return 0
  fi

  if [[ -n "${NODE_MAP[$input]:-}" ]]; then
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

  local log_dir="${LOGFILE%/*}"
  # Create a private log directory only when a command is going to run.
  if ! mkdir -p -m 700 -- "$log_dir"; then
    echo "ERROR: Cannot create log directory: $log_dir" >&2
    exit 1
  fi
  if [ ! -w "$log_dir" ]; then
    echo "ERROR: Log directory is not writable: $log_dir" >&2
    exit 1
  fi
}

# ---------- Confirmation ----------

confirm_run() {
  local host destination destinations=()
  for host in "${SELECTED_HOSTS[@]}"; do
    destination=$(connection_address "$host")
    destinations+=("$destination")
  done
  echo "The following ${#CMDS[@]} command(s) will run on: ${destinations[*]}"
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
# Reports the literal exit status of every command, neutrally, with no
# success/failure judgment attached. Non-zero is not automatically a failure.
#
# "localhost" runs directly with bash -c and does not invoke SSH. All other
# targets are reached over SSH as their configured SSH user.

run_all() {
  local host c rc key user address

  for host in "${SELECTED_HOSTS[@]}"; do
    address=$(connection_address "$host")
    for c in "${CMDS[@]}"; do
      echo "=== ${address} — ${c} — $(date -u +%FT%TZ) ===" | tee -a "$LOGFILE"

      if [ "$host" == "localhost" ]; then
        bash -c "$c" 2>&1 | tee -a "$LOGFILE"
      else
        key="${HOST_SSH_KEY_PATH[$host]}"
        user="${HOST_SSH_USER[$host]}"
        ssh -n -i "$key" -o IdentitiesOnly=yes -o ConnectTimeout=10 "${user}@${address}" "$c" 2>&1 | tee -a "$LOGFILE"
      fi

      rc=${PIPESTATUS[0]}
      echo "--- exit_status=${rc} ---" | tee -a "$LOGFILE"
      if [ "$rc" -ne 0 ]; then
        NONZERO_COUNT=$((NONZERO_COUNT + 1))
      fi
      echo | tee -a "$LOGFILE"
    done
  done
}

# ---------- Main ----------

main() {
  trap cleanup EXIT

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
  echo "${NONZERO_COUNT} of $(( ${#SELECTED_HOSTS[@]} * ${#CMDS[@]} )) command run(s) returned a non-zero exit status — not necessarily a failure, see exit_status lines above."
  exit 0
}

main "$@"
