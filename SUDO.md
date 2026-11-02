# Sudo and SSH Runner

SSH Runner deliberately does not implement a privilege-escalation framework.

Runner executes commands exactly as written. If a remote command begins with `sudo`, Runner allocates an SSH PTY so the remote `sudo`/PAM stack can interact with the administrator.

Examples:

```text
date
sudo systemctl restart nginx
uptime
```

`date` and `uptime` run as the configured SSH user. Only the explicit `sudo` command requests elevated privileges.

Runner does not know whether the server uses a password, TOTP, another PAM method, passwordless sudo, or an existing sudo timestamp. That policy stays entirely on the remote server.

Runner does not store, generate, cache, or forward sudo credentials itself.

## Optional sudo authentication grace period

Runner does not control sudo authentication caching. A system administrator may configure the remote server's sudo policy separately.

For example, for an individual human administrator account named `admin`, a four-hour authentication timestamp shared across that account's sessions can be configured with:

```sudoers
Defaults:admin timestamp_type=global
Defaults:admin timestamp_timeout=240
```

Important considerations:

- `admin` is the literal username. Replace it with the intended account.
- `timestamp_type=global` allows the timestamp to be reused across that user's terminals and SSH sessions. Other processes running as the same user may also reuse it.
- `timestamp_timeout=240` is a 240-minute sudo authentication timeout, not a fixed end-of-day session.
- This is a server-side policy choice, not a Runner setting or universal recommendation.
- Use `visudo` and keep a separately verified recovery path before changing production sudo/PAM configuration.

## Scope

To keep Runner simple, automatic PTY detection applies only when `sudo` is the first command word after optional leading whitespace. Runner does not parse arbitrary shell syntax to search for embedded sudo commands.
