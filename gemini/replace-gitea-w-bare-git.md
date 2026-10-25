### TASK:
Refactor the provided "Andromeda stack" setup/installation scripts and configuration to completely eliminate Gitea and replace it with a minimal, zero-bloat Bare Git repository workflow using `git-daemon` and standard SSH.

### CONTEXT & GOAL:
- The target runtime environment is inside a proot container (low overhead, no systemd, syscall/ptrace overhead must be minimized).
- The repo server is primarily used by a local AI coding agent (Goose) and local developer tools.
- We do not need a web UI, PR manager, SQLite/PostgreSQL database, or background Go daemon consuming idle RAM.

### INSPECT
1. INSPECT THE ENTIRE PROJECT CODE
2. MAP ALL INSTALL RELATED FILES
3. IDENTIFY ALL GITEA RELATED INSTALL FILES


### REQUIREMENTS:
1. REMOVE:
   - All Gitea binaries, downloads, configs (`app.ini`), database setup (SQLite/Postgres), and service hooks.
   - Any port forwards or reverse proxies dedicated solely to Gitea's HTTP interface (e.g. port 3000).

2. IMPLEMENT:
   - A dedicated bare repository storage root (e.g., `/var/git` or `~/git-repos`).
   - A lightweight repository init script or helper function (e.g., `create-repo <name>`) that runs `git init --bare` and configures permissions.
   - Configuration for Git transport:
     * Option A (Fastest local network / zero-auth): A lightweight daemon launcher script for `git daemon` running with `--reuseaddr --export-all --enable=receive-pack` pointing to the storage root.
     * Option B (SSH transport): Configuration for standard OpenSSH or Dropbear using authorized_keys or existing local user keys for secure push/pull.
   - Proot-friendly process management: Since systemd is unavailable in proot, provide a simple bash start/stop script (or supervisor entry if present in the stack) to run the daemon in the background.

3. REFACTOR CLIENT / GOOSE INTEGRATION:
   - Show how the clone/push URLs must be updated across the stack (e.g., switching from `http://localhost:3000/user/repo.git` to `git://127.0.0.1/repo.git` or `file:///path/to/repo.git` or `ssh://...`).

### OUTPUT FORMAT:
- Present the refactored installation script/steps clearly.
- Provide clean, commented bash snippets.
- Briefly note how Goose should be configured to target the new bare Git setup.




