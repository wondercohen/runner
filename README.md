# Runner

Runner is a lightweight Bash command runner for Linux administration. It executes one or more shell commands locally or over SSH on one, several, or all configured hosts. Commands can be supplied directly on the command line or from a reviewed, line-oriented command file.

Runner uses Bash, OpenSSH, and standard Unix utilities. It does not require Ansible, a Python runtime, or a remote agent.

It is aimed at operational work that sits between repeated manual SSH sessions and a full automation or configuration-management platform.

Before execution, Runner prints the selected targets and command set for confirmation. During execution, it identifies each host and command, reports the command exit status, and writes the output to a timestamped local log.

The execution model is deliberately close to the shell: configuration in one file, SSH for remote transport, and plain-text output that is straightforward to inspect, archive, or pass to other tools.

Developed and maintained by **Wonder Cohen B.V.**

## Use cases

Runner is useful for operational work where repeated SSH sessions are cumbersome and a larger automation layer is unnecessary.

Typical uses include:

- System checks and validation
- Troubleshooting and diagnostics
- Audit and inventory collection
- Service and configuration checks
- Log and command-output collection
- Administrative changes
- Deployment or maintenance steps
- Lab and test environments
- Human-in-the-loop AI or LLM-assisted administration

The commands define the operation. Runner provides target selection, execution, confirmation, status reporting, and logging.

## Requirements

Runner requires:

- Bash 4 or later
- OpenSSH client tools: `ssh`, `ssh-agent`, `ssh-add`, and `ssh-keygen`
- Standard Unix utilities used by the script
- SSH access to remote hosts when remote execution is used

No installation is required on remote hosts beyond the SSH service and the commands you intend to run.

## Installation

Clone the repository:

```bash
git clone https://github.com/wondercohen/runner.git
cd runner
```

Create the local configuration:

```bash
cp runner.cfg.example runner.cfg
chmod 700 runner.sh
chmod 600 runner.cfg
```

Edit `runner.cfg` for your environment.

Configuration lookup is relative to `runner.sh`, not to the current working directory.

## Configuration

`runner.cfg` contains the host inventory, SSH defaults, optional per-host overrides, and log location.

Example:

```bash
SSH_USER="deploy"
SSH_KEY_PATH="${HOME}/.ssh/id_ed25519"
LOG_DIR="${HOME}/.local/state/runner"

declare -gA NODE_INVENTORY=(
  [1]="192.0.2.10|node1.example.com||"
  [2]="198.51.100.20|node2.example.com||"
  [3]="203.0.113.30|node3.example.com|${HOME}/.ssh/id_ed25519_admin|admin"
)

declare -gA NODE_ROLE=(
  [1]="Application server"
  [2]="Database server"
  [3]="Administration server"
)
```

Each `NODE_INVENTORY` entry uses this format:

```text
IP_ADDRESS|NODE_HOSTNAME|HOST_SSH_KEY_PATH|HOST_SSH_USER
```

An empty key or user field falls back to the global `SSH_KEY_PATH` or `SSH_USER`.

`NODE_ROLE` is optional and is used only for the descriptive output of `runner.sh -l`.

The example inventory uses RFC 5737 documentation addresses and `example.com` hostnames.

### Log directory

The default example configuration uses:

```bash
LOG_DIR="${HOME}/.local/state/runner"
```

To store logs under `${HOME}/logs`, set:

```bash
LOG_DIR="${HOME}/logs"
```

Runner creates the configured log directory when it executes commands.

## Usage

Show help:

```bash
./runner.sh -h
```

List configured nodes:

```bash
./runner.sh -l
```

Run one command on localhost:

```bash
./runner.sh -c 'uptime'
```

Run multiple commands on localhost:

```bash
./runner.sh -c 'date' -c 'uptime'
```

Run a command on one remote host:

```bash
./runner.sh -n 1 -c 'uptime'
```

Select a host by configured hostname:

```bash
./runner.sh -n node1.example.com -c 'uptime'
```

Select multiple hosts:

```bash
./runner.sh -n 1 2 -c 'uptime'
```

Run multiple commands on multiple hosts:

```bash
./runner.sh -n 1 2 -c 'date' -c 'uptime'
```

Run a command file on all configured remote hosts:

```bash
./runner.sh -a -f checks/system-info.txt
```

Connect by configured IP address instead of hostname:

```bash
./runner.sh -a -ip -f checks/system-info.txt
```

Include localhost together with remote targets:

```bash
./runner.sh -n 1 localhost -c 'date'
```

Skip the confirmation prompt:

```bash
./runner.sh -n 1 -c 'uptime' -y
```

### Options

`-h`, `--help`
Show help.

`-l`, `--list`
List configured remote nodes.

`-c`, `--cmd`
Add an ad-hoc command. Repeat the option to add multiple commands.

`-f`, `--file`
Read commands from a file.

`-n`, `--node`
Select one or more nodes by numeric ID, configured hostname, or configured IP address.

`-a`, `--all`
Add all configured remote nodes to the target set.

`-ip`, `--ip`
Connect to remote nodes by configured IP address instead of hostname.

`-y`, `--yes`
Run without the confirmation prompt.

Flags can be supplied in different orders.

If neither `-n` nor `-a` selects a target, Runner uses `localhost` and executes commands directly with Bash.

## Command files

A command file contains one command per non-empty, non-comment line.

Example `checks/system-info.txt`:

```text
date
uname -a
uptime
```

Run it locally:

```bash
./runner.sh -f checks/system-info.txt
```

Run it on selected hosts:

```bash
./runner.sh -n 1 2 -f checks/system-info.txt
```

Run it on all configured remote hosts:

```bash
./runner.sh -a -f checks/system-info.txt
```

Each line is executed independently. Shell state does not persist between lines.

For example:

```text
cd /var/log
pwd
```

does not carry the directory change into the second command. Use a single line when commands depend on shared shell state:

```text
cd /var/log && pwd
```

## Execution model

Runner builds a target set from the command-line options and executes commands in the order supplied.

For each selected host, Runner runs each command before moving to the next host. Remote execution uses the configured SSH user and key for that host.

Remote connections use the configured hostname by default. `-ip` switches the connection address to the configured IP address without changing the selected credentials.

For remote targets, Runner loads the required configured key into an available `ssh-agent`. If no usable agent is available, Runner starts one for its own process tree and stops it when Runner exits.

Before execution, Runner prints the target set and commands:

```text
The following 2 command(s) will run on: node01.example.com node02.example.com
---
  date
  uptime
---
Proceed? [y/N]
```

The confirmation prompt is skipped only when `-y` is specified.

## Output and logging

Runner writes command output to the terminal and to a timestamped log in `LOG_DIR`.

Each command is identified by target, command, and UTC timestamp:

```text
=== node01.example.com — uptime — 2026-10-25T09:50:40Z ===
```

The command exit status follows the output:

```text
--- exit_status=0 ---
```

Standard output and standard error are captured together.

A non-zero command status is reported as returned by the command. Runner does not assign additional meaning to that value.

After all commands complete, Runner prints the log path and a summary of non-zero command results.

Runner currently exits with process status `0` after a completed run. Use the per-command `exit_status` lines when evaluating individual command results.

Logs are created with restrictive permissions through `umask 077`.

## Example

The following is an anonymized, shortened example based on a real Runner execution.

The example uses:

```bash
LOG_DIR="${HOME}/logs"
```

```text
admin@workstation ~/runner $ ./runner.sh -n 1 2 -c 'date' -c 'uptime'

Enter passphrase for /home/admin/.ssh/id_rsa:
Identity added: /home/admin/.ssh/id_rsa

The following 2 command(s) will run on: node01.example.com node02.example.com
---
  date
  uptime
---
Proceed? [y/N] y

==========================================
runner — run started: 2026-10-25 09:50:39 UTC
==========================================

=== node01.example.com — date — 2026-10-25T09:50:39Z ===
Sun Oct 25 10:50:40 AM CET 2026
--- exit_status=0 ---

=== node01.example.com — uptime — 2026-10-25T09:50:40Z ===
10:50:41 up 3 days, 14:49, 1 user, load average: 0.00, 0.00, 0.00
--- exit_status=0 ---

=== node02.example.com — date — 2026-10-25T09:50:41Z ===
Sun Oct 25 09:50:41 AM UTC 2026
--- exit_status=0 ---

=== node02.example.com — uptime — 2026-10-25T09:50:41Z ===
09:50:44 up 2 days, 22:04, 0 users, load average: 0.00, 0.02, 0.00
--- exit_status=0 ---

Log saved: /home/admin/logs/runner_20261025_105026.log
0 of 4 command run(s) returned a non-zero exit status — not necessarily a failure, see exit_status lines above.
```

## AI and LLM-assisted administration

Runner also fits human-in-the-loop workflows with AI or LLM assistants.

Its output is plain text with explicit boundaries for the target, command, timestamp, command output, exit status, and final summary. An administrator can review commands proposed during an AI-assisted troubleshooting or administration session, execute the approved commands with Runner, and return the resulting output for further analysis.

Runner does not require direct integration with an AI service. The administrator remains the execution boundary between the assistant and the managed systems.

## Security considerations

`runner.cfg` is Bash source code and is sourced directly by Runner. Use only trusted configuration.

Runner executes commands with the privileges of the local account or the configured remote SSH account.

SSH uses `IdentitiesOnly=yes` with the configured key. Runner does not disable normal OpenSSH host-key verification.

The confirmation prompt provides an execution checkpoint. `-y` bypasses that checkpoint.

Logs can contain operational or sensitive command output and should be handled accordingly.

The supplied `.gitignore` excludes `runner.cfg`, generated logs, common key files, and local-only check files from the public repository.

## Project layout

```text
runner/
├── runner.sh
├── runner.cfg.example
├── checks/
│   └── system-info.txt
├── .gitignore
├── LICENSE
└── README.md
```

## Contributing

Issues and pull requests are welcome:

[https://github.com/wondercohen/runner](https://github.com/wondercohen/runner)

Runner is intentionally small. Changes should preserve the direct execution model, minimal dependencies, readable configuration, and plain-text output.

## License

Runner is released under the [BSD 3-Clause License](LICENSE).

Copyright © 2026 Wonder Cohen B.V.

## Maintainer

**Wonder Cohen B.V.**
[https://wondercohen.com/](https://wondercohen.com/)
