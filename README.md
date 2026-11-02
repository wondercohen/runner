# SSH Runner

A lightweight Bash command runner for executing reviewed commands locally or across configured Linux servers using OpenSSH. It needs no Ansible installation, Python runtime, or agent on remote servers.

**Developed by Wonder Cohen B.V.**

## Features

- Run an individual command (`-c`) or a line-oriented command file (`-f`).
- Target localhost (the default), selected nodes (`-n`), or all nodes (`-a`).
- Connect by configured hostname by default or IP address (`-ip`).
- Global and per-node SSH usernames and private-key paths.
- SSH agent support for passphrase-protected keys.
- Commands are executed exactly as written.
- Remote commands beginning with `sudo` automatically get an interactive PTY so the server can present its normal sudo/PAM challenge.
- SSH is quiet by default; `-v` / `--verbose` enables diagnostics.
- Explicit confirmation before commands run unless `-y` is selected.
- Per-command exit status and uniquely created private log files.
- **Data-only `runner.cfg`** — no shell sourcing or execution of configuration.

## Requirements

**To run:** Bash 4.3+, OpenSSH client tools (`ssh`, `ssh-agent`, `ssh-add`, `ssh-keygen`) and standard Linux utilities including GNU `stat`, `mktemp`, `tee`, `date` and `sort`. Runner executes on a Linux workstation or administration host and is independent of remote Linux distributions.

Remote hosts need an SSH server and a shell. `sudo` is needed only for commands that explicitly use `sudo`.

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

[node:1]
ip = 192.0.2.10
hostname = node1.example.com
role = Application server

[node:2]
ip = 198.51.100.20
hostname = node2.example.com
ssh_user = ops
ssh_key_path = ~/.ssh/id_ed25519_ops
role = Database server
```

- `[global]`: required `ssh_user` and `ssh_key_path`; optional `log_dir`.
- `[node:N]`: numeric ID with required `ip` and `hostname`; optional `ssh_user`, `ssh_key_path` and `role`.
- Missing node SSH values inherit the global defaults.
- Only full-line `#` or `;` comments are supported. Do not enclose values in quotes or append inline comments.
- Paths must be absolute or begin with `~/`, which Runner expands to its user's home directory. Other variables and shell expressions are **not evaluated**.
- `runner.cfg` must be a regular file, not a symlink, owned by the current user or root, readable by Runner, and inaccessible to group/others. Use `chmod 600 runner.cfg`.

### Migrating an existing Bash-style `runner.cfg`

Use the included converter. It reads supported legacy assignments and arrays as text and **never executes the old configuration**.

```bash
python3 tools/migrate-config.py runner.cfg --output runner.cfg.new
cat runner.cfg.new

cp -p runner.cfg "runner.cfg.$(date +%Y%m%d_%H%M%S).bak"
mv runner.cfg.new runner.cfg
chmod 600 runner.cfg
./runner.sh -l
```

Legacy BECOME fields are intentionally omitted during migration. Runner no longer manages privilege escalation. Put `sudo` directly in the command when root privileges are required.

## Usage

```bash
./runner.sh --version
./runner.sh -h
./runner.sh -l
./runner.sh -c 'hostname'                         # localhost
./runner.sh -f checks/system-info.txt             # localhost
./runner.sh -n 1 -c 'uptime'                      # node by ID
./runner.sh -v -n 1 -c 'uptime'                   # verbose SSH diagnostics
./runner.sh -n node1.example.com -c 'uptime'      # node by name
./runner.sh -n 1 2 -c 'date'                      # multiple nodes
./runner.sh -a -f checks/system-info.txt          # every configured remote node
./runner.sh -a -ip -f checks/system-info.txt      # connect using IP addresses
./runner.sh -n 1 -c 'sudo id -u'                  # explicit sudo
```

Flags may appear in any order. `-n` accepts configured node IDs, hostnames and IP addresses. `-a` includes all remote nodes, not localhost. By default, Runner runs locally without SSH. `-ip` changes only the destination address, not credentials.

## Sudo

Runner does not decide which commands require root and does not prepend `sudo`.

Commands are executed exactly as written:

```text
date
uname -a
sudo systemctl restart nginx
uptime
```

For remote commands whose first command word is `sudo`, Runner requests a PTY so the remote server can display its normal sudo/PAM prompt. The server decides whether authentication requires a password, TOTP, another PAM method, or no prompt because an existing sudo timestamp is valid.

Runner does not store sudo passwords, TOTP codes, or sudo session state.

To keep the implementation simple, automatic PTY detection applies only when `sudo` is the first command word after optional whitespace. Runner does not attempt to parse arbitrary shell grammar.

See [Sudo and Runner](docs/SUDO.md) for additional notes, including an optional server-side sudo timestamp example.

## Execution, SSH failures and logs

Every non-empty, non-comment line of a `-f` file is executed as an independent command; shell state does not persist across lines. Review command files first.

SSH is quiet by default (`-q`). Use `-v` or `--verbose` to enable OpenSSH diagnostic output when troubleshooting.

SSH forwarding of X11, the agent, and extra configured forwards is explicitly disabled. Runner retains OpenSSH's normal host-key verification behavior.

Runner **never automatically retries commands**. If SSH returns `255`, Runner stops additional commands on that node, continues with remaining nodes, and reports the result as ambiguous because a remote command can also deliberately return `255`.

Other non-zero command statuses are reported literally. Runner does not try to interpret a remote program's meaning.

Log files are created uniquely using `mktemp` with permission `0600` in a private `LOG_DIR` (default `~/.local/state/runner`, required mode `0700`, owned by the Runner user). Log files can contain operational and command-output secrets; handle retention accordingly.

## Security and limitations

- No config file is executed. The parser does not expand shell syntax.
- Keep private inventories, SSH private keys, operational checks and logs out of Git.
- Runner executes reviewed commands exactly as supplied; it is not a command policy engine or sandbox.
- `-y` skips Runner's confirmation prompt. Use it only with reviewed commands.
- Remote SSH policy and sudo/PAM policy remain server responsibilities.
- Runner uses configured SSH private-key identities for remote connections.

## Offline checks

```bash
bash -n runner.sh
./runner.sh --version
./runner.sh -l
bash tests/offline-smoke.sh
# Optional, if installed:
shellcheck -s bash runner.sh
```

The smoke tests use a simulated `ssh` command and do **not** connect to real servers.

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
│   └── SUDO.md
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
