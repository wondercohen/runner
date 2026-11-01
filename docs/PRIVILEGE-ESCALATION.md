# Privilege escalation design — SSH Runner

This document describes Runner's **BECOME** integration. It deliberately does not define or modify server-side `sudoers`, PAM, TOTP, or credential-cache policies.

## Security model

1. Runner connects using the configured SSH key and **ordinary SSH user**.
2. Global `become = false` is the default in the data-only `runner.cfg` file. Each `[node:N]` section can override it with `become = true` or `false`. CLI `--become` / `--no-become` takes precedence.
3. For a node with become enabled, Runner opens **one interactive SSH session** (forced PTY with `ssh -tt`) and executes **one remote `sudo -H -- /bin/bash -c ...`** process for that invocation.
4. Inside the privileged Bash process, each reviewed command is run in a separate `/bin/bash -c` child; shell state does not persist between commands. The remote process emits a status for each command, which Runner shows and logs.
5. The server's `sudo` and PAM stack determine how to authenticate (password, rotating code, other challenge, already-authorized sudo, or passwordless policy). Runner never asks for the secret itself and never supplies credential material via a scripted stdin pipe, arguments, environment variables, files, or logs. SSH naturally forwards interactive keystrokes to the server's PTY, and well-behaved sudo/PAM prompts turn off terminal echo.
6. After the command set finishes, the SSH session terminates. Runner does **not** implement its own sudo session cache, unlock timer, or long-lived privileged daemon. The server may maintain its own sudo timestamp according to its policy.

## Why the design is different from Ansible

Ansible also treats `become` as distinct from SSH access, and supports host settings and CLI overrides. Its standard sudo plugin may use `-H -S -n` (noninteractive stdin/known password handling). Runner intentionally does not emulate Ansible's password handling; forced PTY + interactive sudo is more compatible with an arbitrary server-side PAM prompt, including TOTP.

## Important limitations

- **Broad privilege:** authorizing `sudo /bin/bash -c ...` is effectively authorizing a root shell. This is a design for trusted administrators who intentionally run arbitrary privileged commands; it does not preserve command-by-command sudoers allowlists. Avoid `become = true` for restricted automation accounts.
- **Trust command files:** any text supplied via `-c` or `-f` runs as root when become is active. Review the confirmation preview; `-y` disables this preview confirmation, not sudo authentication.
- **Interactive only:** become mode requires a terminal. It is not suitable for cron or other unattended runs without further design.
- **Terminal logs:** terminal **output** (including PAM prompt text) is logged. Input is not logged by Runner. Ensure remote PAM prompts disable echo for secrets; if any remote program prints a password, TOTP or other secret, that output may be recorded.
- **Sudo availability:** sudo must exist and allow execution as root. `sudo -H` requests the target user's home directory. Commands execute in a privileged Bash subshell; they do not automatically get a full `sudo -i` login environment.
- **SSH host verification:** Runner does not turn off OpenSSH host-key verification. Keep known hosts current and verified.
- **SSH disconnection:** if a session ends before a status line is received, Runner reports an **unconfirmed command outcome**, not a definite failure. A command might have started before the connection was interrupted. Never blindly repeat non-idempotent commands.
- **No automatic root session lifetime:** any server-side cache/grace period remains controlled by sudoers/PAM. This version introduces no changes to those policies.

## Optional sudoers authentication grace period

Runner intentionally does not control sudo authentication caching. The local `runner.cfg` is parsed as plain data, not sourced or executed. A system administrator may configure the remote server's `sudoers` policy to reduce repeated password or TOTP challenges **between independent Runner executions**.

For example, for the **individual account named `admin`**, to allow a four-hour (240-minute) authentication timestamp shared across that account's sessions:

```sudoers
Defaults:admin timestamp_type=global
Defaults:admin timestamp_timeout=240
```

- `timestamp_type=global` shares one sudo timestamp across the named user's SSH sessions and terminals; **other processes running as the same user can reuse it**, including sudo outside Runner. It does not create a Runner-specific privilege window.
- `timestamp_timeout=240` sets a **240-minute sudo authentication timeout**, not a four-hour fixed session or midnight cutoff. Its lifetime can be extended by subsequent qualifying sudo activity.
- `Defaults:admin` targets a user **literally named `admin`**. Replace it with the actual administrator account. Group-scoped rules use `Defaults:%groupname` (for example, `Defaults:%sudo`).
- With `timestamp_type=tty` (usual default), separate terminals authenticate independently. Runner's become mode already invokes sudo **once per node per run**, so a global timestamp is **not required** to avoid repeated prompts *within a single run*.
- A global four-hour cache improves convenience at the expense of a larger privilege-reuse window. Consider a shorter timeout or terminal-scoped timestamps for sensitive machines. When finished, `sudo -K` invalidates the invoking user's cached sudo authentication timestamps.
- Edit sudoers safely using `visudo`, ideally in a narrowly scoped `/etc/sudoers.d/` drop-in, and verify the configuration with `visudo -c`. Keep a separately verified recovery path before changing production authentication rules.

This is an **optional example for human administrators**, not a recommended universal default and **not** a change that Runner makes to any server.

## Reference documentation

- [Ansible: Understanding privilege escalation](https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_privilege_escalation.html)
- [Ansible: sudo become plugin](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/sudo_become.html)
- [OpenSSH ssh(1) man page](https://man.openbsd.org/ssh)
- [sudo(8) manual](https://man7.org/linux/man-pages/man8/sudo.8.html)
- [sudoers(5) manual](https://man7.org/linux/man-pages/man5/sudoers.5.html)
