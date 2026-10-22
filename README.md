# SSH Runner

A lightweight **Bash command runner** for executing one command or a reviewed command file on localhost, selected Linux servers, or all configured SSH nodes. It uses the system OpenSSH client; no Ansible installation or Python runtime is required.

**Developed by Wonder Cohen B.V.**

## Features

- One-off commands with `-c`, or line-oriented command files with `-f`.
- Defaults to `localhost` without invoking SSH.
- Node selection by numeric ID, configured hostname, or configured IP address (`-n`).
- Run against all configured remote nodes with `-a`.
- Connect using configured **hostnames by default**, or IP addresses with `-ip`.
- Global and per-node SSH usernames and private-key **paths**.
- SSH-agent support for passphrase-protected keys.
- Confirmation prompt before running commands (`-y` bypasses confirmation).
- Timestamped local logs and per-command `exit_status` reporting.

## Requirements

- Linux or another Unix-like system with **Bash 4+**, OpenSSH client tools (`ssh`, `ssh-agent`, `ssh-add`, `ssh-keygen`) and standard Unix utilities.
- SSH access and suitable authorized public keys on target machines.
- The selected private keys must exist and be readable by the account running the script.

## Install

```bash
git clone https://github.com/wondercohen/runner.git
cd runner
cp runner.cfg.example runner.cfg
chmod 700 runner.sh
chmod 600 runner.cfg
```

Edit `runner.cfg` and replace the documentation-only hosts, IP addresses, usernames, and key paths. **The example hostnames and IP addresses do not point to working servers.** The actual `runner.cfg` is excluded from Git by `.gitignore`.

Alternatively, download the project files into one directory and run `./runner.sh` from there. Configuration lookup is relative to the script file, not the working directory.

## Configuration

`runner.cfg` is **Bash source code**, sourced directly by the script. Never copy untrusted content into it. A node is defined as:

```bash
SSH_USER="deploy"
SSH_KEY_PATH="${HOME}/.ssh/id_ed25519"
LOG_DIR="${HOME}/.local/state/runner"

declare -gA NODE_INVENTORY=(
  [1]="192.0.2.10|node1.example.com||"
  [2]="198.51.100.20|node2.example.com|${HOME}/.ssh/id_ed25519_ops|ops"
)
```

Each `NODE_INVENTORY` entry contains four pipe-separated fields:

`IP_ADDRESS | NODE_HOSTNAME | HOST_SSH_KEY_PATH | HOST_SSH_USER`

An empty third or fourth field uses the global `SSH_KEY_PATH` or `SSH_USER`. `NODE_ROLE` is an optional associative array containing display descriptions. Specify **private-key file paths only**, never private-key content.

`LOG_DIR` is optional, defaults to `${HOME}/.local/state/runner`, and is created when executing a command. Log files inherit restrictive permissions (`umask 077`).

## Usage

```bash
./runner.sh -h
./runner.sh -l
./runner.sh -c 'hostname'                                   # localhost
./runner.sh -f checks/system-info.txt                      # localhost
./runner.sh -n 1 -c 'hostname'                              # node 1 via hostname
./runner.sh -n node1.example.com -c 'uptime'              # named node
./runner.sh -n 1 2 -c 'uptime'                            # multiple nodes
./runner.sh -a -f checks/system-info.txt                  # all nodes via hostname
./runner.sh -a -ip -f checks/system-info.txt              # all nodes via IP
./runner.sh -n 1 localhost -c 'date'                      # mixed remote and local
./runner.sh -n 1 -c 'uptime' -y                           # skip confirmation
```

Flags may be supplied in different orders. `-a` runs on all remote nodes (it does not automatically add localhost). Node IDs, names, and IP addresses accepted by `-n` refer to the same configured node. `-ip` changes the connection address, not the selected credentials.

### Command-file behavior

The `-f` file contains **one independent shell command per non-empty, non-comment line**. Commands run through `bash -c` locally or the configured SSH account remotely. Shell state **does not** persist between lines. For example, write `cd /var/log && pwd` on one line rather than a `cd` followed by a separate `pwd`. These files contain executable commands—review them before execution.

### Results and logs

Each invocation prints a confirmation preview unless `-y` is set. Each command prints an `exit_status=N` line and appends its output to a timestamped log in `LOG_DIR`. Non-zero status means the command exited non-zero and is not always an operational failure. As in the original runner, the script's final process exit status is `0` after completing its run; inspect the command status lines for individual failures.

SSH diagnostics are visible and logged. SSH status `255` generally indicates a connection or authentication problem; check DNS, host access, username, and private-key paths.

## Security

- **Do not commit `runner.cfg`**, private keys, live infrastructure addresses, usernames, hostnames, or operational logs. The `.gitignore` contains common exclusions, but it does not replace a manual review or a secret scanner.
- The sample inventory uses `example.com` and reserved documentation IP ranges; replace the sample values in your local untracked configuration.
- The `-y` flag bypasses a deliberate safeguard; use it only for reviewed commands.
- The script runs commands with the permissions of the local user or configured remote account. It is not a sandbox and performs no command allowlisting.
- SSH uses `IdentitiesOnly=yes` with the configured key, to avoid offering unrelated keys. Verify server host-key trust rather than disabling SSH host-key verification.
- Logs can contain command output, infrastructure information and sensitive values. Restrict file access and manage log retention appropriately.
- Review every change to `runner.sh`, `runner.cfg`, and command files before execution.

## Project layout

```text
runner/
├── runner.sh                 # Bash runner
├── runner.cfg.example        # Public example; copy locally to runner.cfg
├── checks/
│   └── system-info.txt       # Safe example command file
├── .gitignore
├── LICENSE
└── README.md
```

## License

[BSD 3-Clause License](LICENSE) (`BSD-3-Clause`). This is a permissive open-source license: reuse and modification are allowed under its terms, including retention of copyright notices and no implied endorsement. The SPDX identifier matches the original script's header.

## Author and copyright

- **Copyright © 2026 Wonder Cohen B.V.**
- **KvK:** 96871571
- **Website:** https://wondercohen.com/

Created and maintained by Wonder Cohen B.V. Contributions and issue reports are welcome.
