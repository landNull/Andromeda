# SYSTEM INSTRUCTIONS: BARE GIT & PROOT ENVIRONMENT

## Environment Constraints
- Context: Unprivileged Linux proot container.
- Prohibitions: No systemd, no SysVinit background services, no user switching (`setuid`/`setgid`).
- Avoid: `git daemon` flags `--detach`, `--user`, `--group` (causes hang/usage errors under ptrace).
- Gitea is removed. Never use HTTP port 3000, Web UIs, DBs, or Gitea CLI (`tea`).

## Git Architecture
- Repo Storage Root: `/var/git/<repo>.git` (bare repositories, group `www-admin`).
- Daemon Service: Managed via `/usr/local/bin/git-daemon-ctl {start|stop|restart|status}`.
- Active Daemon Invocation:
  `nohup /usr/bin/git daemon --reuseaddr --export-all --enable=receive-pack --port=9418 --base-path=/var/git /var/git`
- Andromeda Configuration (`/etc/andromeda.conf`):
  `STARDUST_GIT_TEMPLATE="git://127.0.0.1/%s.git"`

## Operational Protocols for Agent
1. Remote Protocol:
   - Loopback: `git clone git://127.0.0.1/<repo>.git`
   - Direct Filesystem (preferred/fastest): `git clone file:///var/git/<repo>.git`
2. Repo Creation: Run `create-repo <name>` before pushing untracked repositories.
3. Troubleshooting: If network clone refuses connection, run `/usr/local/bin/git-daemon-ctl status` or `start`.
