#!/bin/sh
# apps/bare-git/install.sh — bare Git repository server

PROG=${0##*/}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/lib/common.sh"

# Replaces Gitea with a minimal git daemon setup.

GIT_ROOT="/var/git"
GIT_DAEMON_PORT="9418" # Default git protocol port

echo "STEP: Setting up bare Git repository server"

# --- helpers ---

# Ensure root privileges for certain operations
as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

# Ensure 'git' user exists
ensure_git_user() {
  if id git >/dev/null 2>&1; then
    echo "user ok: git"
    return 0
  fi
  if [ "${DRYRUN:-0}" -eq 1 ]; then
    echo "+ adduser --system --shell /bin/bash --gecos \"Git Daemon User\" --group --disabled-password git"
    return 0
  fi
  if have adduser; then
    run_root adduser --system --shell /bin/bash --gecos "Git Daemon User" --group --disabled-password git || {
      echo "$PROG: could not create system user git" >&2
      return 1
    }
  elif have useradd; then
    if ! getent group git >/dev/null 2>&1; then
      run_root groupadd --system git || true
    fi
    run_root useradd -r -m -d /home/git -s /bin/bash -g git -c "Git Daemon User" git || {
      echo "$PROG: could not create system user git" >&2
      return 1
    }
  else
    echo "$PROG: no useradd/adduser to create git user" >&2
    return 1
  fi
  echo "system user: git"
}

# --- Installation steps ---

# 1. Create dedicated bare repository storage root
echo "1/3: Creating Git repository root at $GIT_ROOT"
as_root mkdir -p "$GIT_ROOT"

if ! ensure_git_user; then
  echo "$PROG: git user missing, cannot chown $GIT_ROOT" >&2
  exit 1
fi
if [ "${DRYRUN:-0}" -eq 1 ]; then
  echo "+ chown git:git $GIT_ROOT"
else
  as_root chown git:git "$GIT_ROOT"
fi

as_root chmod 775 "$GIT_ROOT" # Ensure group writeable

# 2. Lightweight repository init script (create-repo)
echo "2/3: Creating create-repo helper script"
cat << 'EOF' | as_root tee /usr/local/bin/create-repo > /dev/null
#!/bin/sh
# create-repo <repository-name> - Initializes a bare Git repository
# Usage: create-repo my-new-project
GIT_ROOT="/var/git"
REPO_NAME="$1"

if [ -z "$REPO_NAME" ]; then
  echo "Usage: create-repo <repository-name>"
  exit 1
fi

REPO_PATH="$GIT_ROOT/$REPO_NAME.git"

if [ -d "$REPO_PATH" ]; then
  echo "Error: Repository '$REPO_NAME' already exists at '$REPO_PATH'"
  exit 1
fi

echo "Initializing bare repository at $REPO_PATH"
# Create as current user, then adjust permissions
mkdir -p "$REPO_PATH"
git init --bare "$REPO_PATH" > /dev/null

# Ensure correct permissions for git daemon and push operations
chown -R git:git "$REPO_PATH" || chown -R $(whoami):$(whoami) "$REPO_PATH"
chmod -R ug+rwX,o+rX,o-w "$REPO_PATH"
# Ensure the "git" group has write access to the objects directory.
# This might be needed for git daemon's receive-pack.
find "$REPO_PATH" -type d -exec chmod g+s {} + # SetGID on directories

echo "Repository '$REPO_NAME' created successfully."
echo "To clone: git clone git://localhost/$REPO_NAME.git"
echo "To push: Ensure the user pushing has write access to the bare repository."
EOF
as_root chmod +x /usr/local/bin/create-repo

# 3. Configure and launch git daemon
echo "3/3: Setting up git daemon"
GIT_DAEMON_OPTS="--reuseaddr --export-all --enable=receive-pack --base-path=$GIT_ROOT"
GIT_DAEMON_CMD="/usr/bin/git daemon $GIT_DAEMON_OPTS --port=$GIT_DAEMON_PORT"

# Simple start/stop script for git daemon
cat << 'EOF' | as_root tee /usr/local/bin/git-daemon-ctl > /dev/null
#!/bin/sh
# git-daemon-ctl start|stop|status - Control script for git daemon

GIT_ROOT="/var/git"
GIT_DAEMON_PORT="9418"
GIT_DAEMON_OPTS="--reuseaddr --export-all --enable=receive-pack --base-path=$GIT_ROOT"
GIT_DAEMON_CMD="/usr/bin/git daemon $GIT_DAEMON_OPTS --port=$GIT_DAEMON_PORT"
PID_FILE="/var/run/git-daemon.pid"
LOG_FILE="/var/log/git-daemon.log"

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

start_daemon() {
  if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
    echo "git daemon is already running (PID: $(cat "$PID_FILE"))"
    return 0
  fi
  echo "Starting git daemon on port $GIT_DAEMON_PORT..."
  as_root mkdir -p $(dirname "$LOG_FILE") $(dirname "$PID_FILE")
  as_root chown git:git $(dirname "$LOG_FILE") || as_root chown $(whoami):$(whoami) $(dirname "$LOG_FILE")
  as_root chown git:git $(dirname "$PID_FILE") || as_root chown $(whoami):$(whoami) $(dirname "$PID_FILE")
  as_root $GIT_DAEMON_CMD --detach --pid-file="$PID_FILE" --log-file="$LOG_FILE"
  if [ $? -eq 0 ]; then
    echo "git daemon started."
    sleep 1 # Give it a moment to write PID
    if [ -f "$PID_FILE" ]; then
        echo "PID: $(cat "$PID_FILE")"
    else
        echo "Warning: PID file not found, daemon might not have started correctly."
        tail -n 10 "$LOG_FILE"
    fi
  else
    echo "Failed to start git daemon."
    tail -n 10 "$LOG_FILE"
  fi
}

stop_daemon() {
  if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    echo "Stopping git daemon (PID: $PID)..."
    as_root kill "$PID" 2>/dev/null
    if [ $? -eq 0 ]; then
      echo "git daemon stopped."
      as_root rm -f "$PID_FILE"
    else
      echo "Failed to stop git daemon (PID: $PID), perhaps already stopped or permission issue."
    fi
  else
    echo "git daemon not running (PID file not found)."
  fi
}

status_daemon() {
  if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
      echo "git daemon is running (PID: $PID) on port $GIT_DAEMON_PORT."
    else
      echo "git daemon PID file exists but process is not running. Cleaning up PID file."
      as_root rm -f "$PID_FILE"
    fi
  else
    echo "git daemon is not running."
  fi
}

case "$1" in
  start)
    start_daemon
    ;;
  stop)
    stop_daemon
    ;;
  status)
    status_daemon
    ;;
  restart)
    stop_daemon
    start_daemon
    ;;
  *)
    echo "Usage: git-daemon-ctl {start|stop|status|restart}"
    exit 1
    ;;
esac
EOF
as_root chmod +x /usr/local/bin/git-daemon-ctl

echo "Bare Git setup complete. You can now use 'create-repo <name>' and 'git-daemon-ctl start'."

# Configure a module to run this install script
cat << EOF > modules/60-bare-git.sh
#!/bin/sh
# Shim for bare-git setup.
. "\$HERE/apps/bare-git/install.sh"
EOF


echo "To complete the setup, run 'sudo /usr/local/bin/git-daemon-ctl start' after installation."
echo "Repository URLs will be in the format: git://localhost/<repo-name>.git"
echo "For Goose integration, update STARDUST_GIT_TEMPLATE in /etc/andromeda.conf to something like: git://127.0.0.1/%s.git"
