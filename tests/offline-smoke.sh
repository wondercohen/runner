#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)

trap 'rm -rf -- "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/work" "$TMP/logs"
chmod 700 "$TMP/logs"

cp "$ROOT/runner.sh" "$TMP/work/runner.sh"
chmod 755 "$TMP/work/runner.sh"

: > "$TMP/fake_key"
chmod 600 "$TMP/fake_key"

cat > "$TMP/work/runner.cfg" <<CFG
[global]
ssh_user = deploy
ssh_key_path = $TMP/fake_key
log_dir = $TMP/logs

[node:1]
ip = 192.0.2.10
hostname = node1.example.com
role = Test node
CFG

chmod 600 "$TMP/work/runner.cfg"

cat > "$TMP/bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
printf '256 SHA256:RUNNERTEST fake-key (ED25519)\n'
EOF

cat > "$TMP/bin/ssh-add" <<'EOF'
#!/usr/bin/env bash

if [[ "${1:-}" == "-l" ]]; then
    printf '256 SHA256:RUNNERTEST fake-key (ED25519)\n'
fi

exit 0
EOF

cat > "$TMP/bin/ssh-agent" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF

cat > "$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash

printf '%q ' "$@" >> "$RUNNER_TEST_SSH_ARGS"
printf '\n' >> "$RUNNER_TEST_SSH_ARGS"

last="${!#}"

if [[ "$last" == sudo* ]]; then
    printf 'SUDO-OUTPUT\n'
else
    printf 'NORMAL-OUTPUT\n'
fi

exit 0
EOF

chmod 755 "$TMP/bin/"*

export PATH="$TMP/bin:$PATH"
export SSH_AUTH_SOCK="$TMP/fake-agent.sock"
export RUNNER_TEST_SSH_ARGS="$TMP/ssh.args"

cd "$TMP/work"

bash -n runner.sh

version_out=$(./runner.sh --version)
grep -Fq 'SSH Runner v1.1.0' <<<"$version_out"

list_out=$(./runner.sh -l)
grep -Fq 'node1.example.com' <<<"$list_out"
! grep -Fq 'become=' <<<"$list_out"

# Normal remote command:
# quiet, noninteractive SSH, command unchanged.
: > "$RUNNER_TEST_SSH_ARGS"

out=$(./runner.sh -n 1 -y -c 'date')

grep -Fq 'NORMAL-OUTPUT' <<<"$out"

normal_args=$(cat "$RUNNER_TEST_SSH_ARGS")

grep -Eq '(^| )-q( |$)' <<<"$normal_args"
grep -Eq '(^| )-n( |$)' <<<"$normal_args"
! grep -Eq '(^| )-t( |$)' <<<"$normal_args"
grep -Fq 'date' <<<"$normal_args"

# Verbose mode replaces -q with -v.
: > "$RUNNER_TEST_SSH_ARGS"

./runner.sh -n 1 -v -y -c 'date' >/dev/null

verbose_args=$(cat "$RUNNER_TEST_SSH_ARGS")

grep -Eq '(^| )-v( |$)' <<<"$verbose_args"
! grep -Eq '(^| )-q( |$)' <<<"$verbose_args"

# Explicit sudo:
# command is not rewritten;
# only SSH gets a PTY.
: > "$RUNNER_TEST_SSH_ARGS"

script -q -e \
    -c "./runner.sh -n 1 -y -c 'sudo id -u'" \
    /dev/null \
    > "$TMP/sudo.out"

grep -Fq 'SUDO-OUTPUT' "$TMP/sudo.out"

sudo_args=$(cat "$RUNNER_TEST_SSH_ARGS")

grep -Eq '(^| )-q( |$)' <<<"$sudo_args"
grep -Eq '(^| )-t( |$)' <<<"$sudo_args"
! grep -Eq '(^| )-n( |$)' <<<"$sudo_args"
grep -Fq 'sudo\ id\ -u' <<<"$sudo_args"
! grep -Fq '/bin/bash -c' <<<"$sudo_args"

# Mixed command file:
# each line remains a separate SSH connection;
# only the explicit sudo line gets a PTY.
: > "$RUNNER_TEST_SSH_ARGS"

cat > commands.txt <<'CMDS'
date
sudo id -u
uptime
CMDS

script -q -e \
    -c "./runner.sh -n 1 -y -f commands.txt" \
    /dev/null \
    >/dev/null

[[ $(wc -l < "$RUNNER_TEST_SSH_ARGS") -eq 3 ]]
[[ $(grep -Ec '(^| )-t( |$)' "$RUNNER_TEST_SSH_ARGS") -eq 1 ]]
[[ $(grep -Ec '(^| )-n( |$)' "$RUNNER_TEST_SSH_ARGS") -eq 2 ]]

# Local commands are still executed exactly as written
# and preserve status.
set +e

local_out=$(./runner.sh -y -c 'exit 7')
local_rc=$?

set -e

grep -Fq -- '--- exit_status=7 ---' <<<"$local_out"
[[ "$local_rc" -eq 0 ]]

# The current data-only format must reject removed
# BECOME settings.
printf '\nbecome = true\n' >> runner.cfg

set +e

./runner.sh -l >"$TMP/badcfg.out" 2>&1
badcfg_rc=$?

set -e

[[ "$badcfg_rc" -ne 0 ]]
grep -Fq 'Unknown node setting: become' "$TMP/badcfg.out"

echo 'offline smoke tests passed'
