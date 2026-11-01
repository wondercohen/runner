# SSH Runner

A lightweight Bash command runner for executing reviewed commands locally or across configured Linux servers using OpenSSH. It needs no Ansible installation, Python runtime, or agent on remote servers.

**Developed by Wonder Cohen B.V.**

## Features

- Run an individual command (`-c`) or a line-oriented command file (`-f`).
- Target localhost (the default), selected nodes (`-n`), or all nodes (`-a`).
- Connect by configured hostname by default or IP address (`-ip`).
- Global and per-node SSH usernames, private-key paths, and `become` settings.
- Optional interactive sudo (`--become`), respecting each server's sudo/PAM policy.
- SSH agent support for passphrase-protected keys; no sudo credentials stored by Runner.
- Explicit confirmation before commands run (unless `-y` is selected).
- Per-command exit status and uniquely created private log files.
- **Data-only `runner.cfg`** — no shell sourcing or execution of configuration.

## Requirements

**To run:** Bash 4.3+, OpenSSH client tools (`ssh`, `ssh-agent`, `ssh-add`, `ssh-keygen`) and standard Linux utilities including GNU `stat`, `mktemp`, `tee`, `date` and `sort`. Runner executes on a Linux workstation or administration host and is independent of remote Linux distributions. Remote hosts need an SSH server, a shell, and `sudo` only if `become` is enabled.

**For one-time migration only:** Python 3 (standard library, no third-party packages). Python is not used by `runner.sh`.

## Installation

```bash
git clone https://github.com/wondercohen/runner.git
cd runner
cp runner.cfg.example runner.cfg
chmod 700 runner.sh
chmod 600 runner.cfg
```

Edit `runner.cfg` for your environment. Example IP addresses and hostnames are fictional. Your actual `runner.cfg` is excluded from Git; **never commit local inventory or secrets**.

## Configuration (`runner.cfg`)

`runner.cfg` is **plain data** with named sections, rather than executable Bash. Runner parses supported keys strictly and rejects unknown settings, missing required fields, malformed sections and unsafe file permissions. The filename remains `runner.cfg`.

```text
[global]
ssh_user = deploy
ssh_key_path = ~/.ssh/id_ed25519
log_dir = ~/.local/state/runner
become = false

[node:1]
ip = 192.0.2.10
hostname = node1.example.com
role = Application server
become = true

[node:2]
ip = 198.51.100.20
hostname = node2.example.com
ssh_user = ops
ssh_key_path = ~/.ssh/id_ed25519_ops
# become omitted: inherits global false
```

- `[global]`: required `ssh_user` and `ssh_key_path`; optional `log_dir` and `become`.
- `[node:N]`: numeric ID with required `ip` and `hostname`; optional `ssh_user`, `ssh_key_path`, `role` and `become`.
- Missing node values inherit global defaults; global `become` defaults to `false`.
- Only literal `true` or `false` are accepted for `become`.
- Only full-line `#` or `;` comments are supported. Do not enclose values in quotes or append inline comments.
- Paths must be absolute or begin with `~/`, which Runner expands to its user's home directory. Other variables (including `$HOME`) and shell expressions are **not evaluated**.
- `runner.cfg` must be a regular file, not a symlink, owned by the current user or root, readable by Runner, and inaccessible to group/others. Use `chmod 600 runner.cfg`.

### Migrating an existing Bash-style `runner.cfg`

**Do not source or execute the old configuration to convert it.** Use the included one-time converter, which reads supported assignments and arrays as text.

From the repository directory:

```bash
# Keep the original untouched until you have reviewed the conversion.
python3 tools/migrate-config.py runner.cfg --output runner.cfg.new
cat runner.cfg.new

# Preserve a private, local backup (excluded from Git).
cp -p runner.cfg "runner.cfg.$(date +%Y%m%d_%H%M%S).bak"
mv runner.cfg.new runner.cfg
chmod 600 runner.cfg
./runner.sh -l
```

The converter supports the recent `NODE_INVENTORY` array (four or five pipe-separated fields), optional `NODE_ROLE`, and an older `NODE_MAP`/`NODE_HOSTNAME` array layout. It recognizes `${HOME}/` and `$HOME/` and converts those path prefixes to `~/`. **It rejects unsupported Bash syntax instead of evaluating it.** Complex legacy configurations require manual migration. It never overwrites an existing destination.

After conversion, test with `-l` and a local command before targeting servers. Keep your private backup outside public Git history.

## Usage

```bash
./runner.sh --version
./runner.sh -h
./runner.sh -l
./runner.sh -c 'hostname'                         # localhost
./runner.sh -f checks/system-info.txt             # localhost
./runner.sh -n 1 -c 'uptime'                      # node by ID
./runner.sh -n node1.example.com -c 'uptime'      # node by name
./runner.sh -n 1 2 -c 'date'                    # multiple nodes
./runner.sh -a -f checks/system-info.txt          # every configured remote node
./runner.sh -a -ip -f checks/system-info.txt      # connect using IP addresses
./runner.sh -n 1 --become -c 'id -u'               # force sudo
./runner.sh -n 1 --no-become -c 'id -un'           # override configured become
```

Flags may appear in any order. `-n` accepts configured node IDs, hostnames and IP addresses. `-a` includes all remote nodes, not localhost. By default, Runner runs locally without SSH. `-ip` changes only the destination address, not credentials.

### Sudo / BECOME

Runner controls **whether** to use sudo; each server decides **how** to authenticate (password, TOTP, PAM policy, or an existing sudo timestamp).

- Normal mode: one SSH connection per command, as in earlier versions.
- Become mode: one interactive SSH PTY session and one sudo invocation per target/run; each command runs in its own Bash subshell and retains a separate exit status.
- `--become` (or `-b`) forces sudo; `--no-become` disables automatic sudo; otherwise each node inherits its configured setting.
- Become mode requires a terminal and trusted administrator rights sufficient to execute an arbitrary root Bash command. It is **not** suitable for narrowly scoped sudo command allowlists.
- Runner never requests sudo credentials through its own configuration or captures keystrokes; remote PAM prompts are passed through SSH. Sensitive data printed by commands may still be logged.
- No Runner-managed credential cache, sudoers modification, or long-running privileged agent is introduced.

See [Privilege escalation design](docs/PRIVILEGE-ESCALATION.md) for implications and an **optional** four-hour sudo timestamp example. That setting is server-side and is **not** the default.

### Execution, SSH failures and logs

Every non-empty, non-comment line of a `-f` file is executed as an independent command; shell state does not persist across lines. Review command files first. The confirmation screen displays selected targets, commands and whether become is enabled.

SSH forwarding of X11, the agent, and extra configured forwards is explicitly disabled. Runner retains OpenSSH's normal host-key verification policy. SSH identities and host authentication behavior otherwise remain unchanged.

Runner **never automatically retries commands**. In normal mode, if an SSH connection returns `255`, Runner stops additional commands on that node, continues with remaining nodes, and exits non-zero. SSH return code `255` can also come from a remote command, so the result is marked **ambiguous**, not a confirmed transport error. If a become-mode session terminates unexpectedly, command results without status markers are similarly **unconfirmed**. Don't blindly repeat commands with side effects.

Other non-zero command statuses are reported without automatically categorizing them as errors. The overall exit code is non-zero for SSH-255 uncertainty or become-session failure, but not simply because an ordinary command returned a non-zero status.

Log files are created uniquely using `mktemp` with permission `0600` in a private `LOG_DIR` (default `~/.local/state/runner`, required mode `0700`, owned by the Runner user). Log files can contain operational and command-output secrets; handle retention accordingly.

## Security and limitations

- No config file is executed. The parser does not expand environment variables or shell syntax.
- Keep private inventories, SSH private keys, operational checks and logs out of Git. Review staged files even with `.gitignore`.
- Do not enable `--become` or automatic become with untrusted commands. `-y` skips only Runner's confirmation, not sudo authentication.
- Config permission validation and private log directories mitigate common local risks but do not replace host hardening, sudo policies, trusted source code or a protected working directory.
- Remote SSH user/password policies and `sudo`/PAM policy remain server responsibilities. Runner itself currently uses configured SSH private-key identities for remote connections.

## Offline checks

```bash
bash -n runner.sh
./runner.sh --version
./runner.sh -l
bash tests/offline-smoke.sh
# Optional, if installed:
shellcheck -s bash runner.sh
```

The smoke tests use simulated `ssh` and `sudo` commands and do **not** connect to real servers.

## Project layout

```text
runner/
├── runner.sh
├── runner.cfg.example
├── tools/
│   └── migrate-config.py
├── tests/
│   └── offline-smoke.sh
├── checks/
│   └── system-info.txt
├── docs/
│   └── PRIVILEGE-ESCALATION.md
├── .gitignore
├── LICENSE
└── README.md
```

## License and copyright

[BSD 3-Clause License](LICENSE) (`BSD-3-Clause`).

- **Copyright © 2026 Wonder Cohen B.V.**
- **KvK:** 96871571
- **Website:** https://wondercohen.com/

Created and maintained by Wonder Cohen B.V. Contributions and issue reports are welcome.
