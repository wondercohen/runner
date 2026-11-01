#!/usr/bin/env bash
# Local, simulated SSH/sudo smoke tests. Never connects to real machines.
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
cp "$PROJECT/runner.sh" "$D/runner.sh"
chmod +x "$D/runner.sh"
mkdir -p "$D/bin" "$D/logs"
chmod 700 "$D/logs"
printf 'FAKE TEST KEY\n' > "$D/key"
chmod 600 "$D/key"
cat > "$D/runner.cfg" <<CFG
[global]
ssh_user = deploy
ssh_key_path = $D/key
log_dir = $D/logs
become = false

[node:1]
ip = 192.0.2.10
hostname = node1.example.com
become = true

[node:2]
ip = 198.51.100.20
hostname = node2.example.com
become = false
CFG
chmod 600 "$D/runner.cfg"
cat > "$D/bin/ssh-add" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == -l ]]; then printf '256 SHA256:mock mock (ED25519)\n'; fi
MOCK
cat > "$D/bin/ssh-keygen" <<'MOCK'
#!/usr/bin/env bash
printf '256 SHA256:mock mock (ED25519)\n'
MOCK
cat > "$D/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "$MOCK_TRACE"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -q|-v|-tt|-n) shift ;;
    -i|-o) shift 2 ;;
    *) break ;;
  esac
done
host=$1; shift
if [[ "${MOCK_SSH_FAIL:-}" == yes ]]; then printf 'ssh: connection refused\n' >&2; exit 255; fi
/bin/bash -c "$1"
MOCK
cat > "$D/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$MOCK_TRACE"
if [[ "${MOCK_SUDO_FAIL:-}" == yes ]]; then printf 'sudo: authentication failed\n' >&2; exit 1; fi
if [[ "$1" == -H ]]; then shift; fi
if [[ "$1" == -- ]]; then shift; fi
"$@"
MOCK
chmod +x "$D/bin/"*
export MOCK_TRACE="$D/trace" SSH_AUTH_SOCK=/tmp/mock-runner-agent PATH="$D/bin:$PATH"
: > "$MOCK_TRACE"
bash -n "$D/runner.sh"
"$D/runner.sh" --version | grep -q v1.1.0
"$D/runner.sh" -l | grep -q 'node1.example.com'
"$D/runner.sh" -c 'printf "localdone\\n"' -y > "$D/local.out"
grep -q localdone "$D/local.out"
"$D/runner.sh" -n 2 -c 'echo normal_one' -c 'echo normal_two' -y > "$D/normal.out"
[[ $(grep -c '^ssh ' "$MOCK_TRACE") == 2 ]]
[[ $(grep -c -- '-o ForwardAgent=no' "$MOCK_TRACE") == 2 ]]
# Quiet by default: each SSH invocation receives -q, not -v.
[[ $(grep -c '^ssh -q -n ' "$MOCK_TRACE") == 2 ]]
if grep -q '^ssh -v ' "$MOCK_TRACE"; then echo 'Unexpected default SSH verbosity' >&2; exit 1; fi
: > "$MOCK_TRACE"
"$D/runner.sh" --verbose -n 2 -c 'echo verbose_check' -y > "$D/verbose.out"
[[ $(grep -c '^ssh -v -n ' "$MOCK_TRACE") == 1 ]]
grep -q verbose_check "$D/verbose.out"
: > "$MOCK_TRACE"
"$D/runner.sh" -v -n 2 -c 'echo short_verbose' -y > "$D/verbose-short.out"
[[ $(grep -c '^ssh -v -n ' "$MOCK_TRACE") == 1 ]]
grep -q short_verbose "$D/verbose-short.out"

grep -q normal_two "$D/normal.out"
[[ $(grep -c -- '--- exit_status=0 ---' "$D/normal.out") == 2 ]]
: > "$MOCK_TRACE"
"$D/runner.sh" -n 2 -ip -c 'hostname' -y > "$D/ip.out"
grep -q '192' "$D/ip.out" || grep -q '198.51.100.20' "$D/ip.out"
: > "$MOCK_TRACE"
script -q -e -c "'$D/runner.sh' -n 1 -c 'echo first' -c 'false' -c 'echo third' -y" /dev/null > "$D/become.out"
[[ $(grep -c '^ssh ' "$MOCK_TRACE") == 1 ]]
[[ $(grep -c '^sudo ' "$MOCK_TRACE") == 1 ]]
[[ $(grep -c '^ssh -q -tt ' "$MOCK_TRACE") == 1 ]]
[[ $(grep -c -- '--- exit_status=' "$D/become.out") == 3 ]]
: > "$MOCK_TRACE"
script -q -e -c "'$D/runner.sh' --verbose -n 1 -c 'echo become_verbose' -y" /dev/null > "$D/become-verbose.out"
[[ $(grep -c '^ssh -v -tt ' "$MOCK_TRACE") == 1 ]]
grep -q become_verbose "$D/become-verbose.out"
grep -q -- '--- exit_status=1 ---' "$D/become.out"
: > "$MOCK_TRACE"
"$D/runner.sh" --no-become -n 1 -c 'echo no-sudo' -y > "$D/no-become.out"
[[ $(grep -c '^sudo ' "$MOCK_TRACE" || true) == 0 ]]
: > "$MOCK_TRACE"
script -q -e -c "'$D/runner.sh' --become -n 2 -c 'echo sudo-mode' -y" /dev/null > "$D/override.out"
[[ $(grep -c '^sudo ' "$MOCK_TRACE") == 1 ]]
if "$D/runner.sh" --become -n 2 -c 'echo no-tty' -y < /dev/null > "$D/tty.out" 2>&1; then echo 'Expected TTY error' >&2; exit 1; fi
grep -q 'interactive terminal' "$D/tty.out"
: > "$MOCK_TRACE"
if MOCK_SSH_FAIL=yes "$D/runner.sh" -n 2 -c 'date' -c 'uptime' -y > "$D/fail.out" 2>&1; then echo 'Expected SSH transport error' >&2; exit 1; fi
[[ $(grep -c '^ssh ' "$MOCK_TRACE") == 1 ]]
grep -q 'Skipping remaining commands' "$D/fail.out"
if MOCK_SUDO_FAIL=yes script -q -e -c "'$D/runner.sh' --become -n 2 -c 'date' -y" /dev/null > "$D/sudo-fail.out"; then echo 'Expected sudo failure' >&2; exit 1; fi
grep -q 'status(es) confirmed' "$D/sudo-fail.out"
# Reject group/world-readable config.
chmod 644 "$D/runner.cfg"
if "$D/runner.sh" -l > "$D/perms.out" 2>&1; then echo 'Expected private config requirement' >&2; exit 1; fi
chmod 600 "$D/runner.cfg"
# Inert malicious Bash code in the config must be rejected, not executed.
printf '\n$(touch %s/pwned)\n' "$D" >> "$D/runner.cfg"
if "$D/runner.sh" -l > "$D/injection.out" 2>&1; then echo 'Expected unsupported syntax' >&2; exit 1; fi
[[ ! -e "$D/pwned" ]]
# Valid but hostile-looking values are inert text (never shell commands).
python3 - "$D/runner.cfg" "$D" <<'PY_INERT'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text().replace('$(touch '+sys.argv[2]+'/pwned)', 'role = $(touch '+sys.argv[2]+'/pwned)')
p.write_text(s)
PY_INERT
"$D/runner.sh" -l > "$D/inert.out"
[[ ! -e "$D/pwned" ]]
# Files are private and log names cannot collide.
python3 - "$D/logs" <<'PY'
from pathlib import Path
import stat,sys
files=list(Path(sys.argv[1]).glob('runner_*'))
assert len(files)>=4
assert len(files)==len({f.name for f in files})
assert all(stat.S_IMODE(f.stat().st_mode)==0o600 for f in files)
PY
# Migration: old Bash sample converts into the data-only configuration.
python3 "$PROJECT/tools/migrate-config.py" "$PROJECT/tests/legacy-runner.cfg.sample" --output "$D/new.cfg" > /dev/null
[[ $(stat -c '%a' "$D/new.cfg") == 600 ]]
grep -q '^ssh_key_path = ~/.ssh/id_ed25519' "$D/new.cfg"
grep -q '^become = true' "$D/new.cfg"
# Refuse executable expressions in the old format without running them.
printf 'SSH_USER=$(touch %s/pwned2)\n' "$D" > "$D/evil.cfg"
if python3 "$PROJECT/tools/migrate-config.py" "$D/evil.cfg" --output "$D/evil.new" > /dev/null 2>&1; then
  echo 'Expected converter rejection' >&2; exit 1
fi
[[ ! -e "$D/pwned2" ]]
# Older separate NODE_MAP / NODE_HOSTNAME arrays work too.
cat > "$D/old-arrays.cfg" <<'OLD'
SSH_USER='deploy'
SSH_KEY_PATH='${HOME}/.ssh/id_ed25519'
declare -A NODE_MAP=(
  [1]='192.0.2.10'
)
declare -A NODE_HOSTNAME=(
  [1]='example.com'
)
OLD
python3 "$PROJECT/tools/migrate-config.py" "$D/old-arrays.cfg" --output "$D/old-arrays.new" > /dev/null
grep -q '^hostname = example.com$' "$D/old-arrays.new"
printf 'offline smoke tests passed\n'
