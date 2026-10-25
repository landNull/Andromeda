#!/bin/sh
# modules/40-mariadb.sh — bind 127.0.0.1, utf8mb4, modest InnoDB
# Root stays unix_socket. Site DBs are bd_* created later by andromeda-priv.
# Secure step = Debian mariadb-secure-installation minus SET PASSWORD.
# Function lives here so STEP 40 works even if the orchestrator is older.

echo "STEP 40: MariaDB drop-in + Debian-secure (no root password)"

tune_mysql

# Defined here so this phase works even if the orchestrator is older.
# Never SET PASSWORD / IDENTIFIED BY. Isolated statements so
# "plugin already loaded" cannot trip set -eu. mysql.user is a view
# on MariaDB 10.4+ — use DROP USER, not DELETE FROM mysql.user.
secure_mysql() {
  echo "MariaDB: unix_socket root, no password, drop anon/remote-root/test"

  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ start ${SVC_DB:-mysql}"
    echo "+ mysql INSTALL SONAME 'auth_socket' (ignore if loaded)"
    echo "+ mysql ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket"
    echo "+ mysql DROP USER anonymous + root@not-local"
    echo "+ mysql DROP DATABASE IF EXISTS test; FLUSH PRIVILEGES"
    return 0
  fi

  if ! have mysql && ! have mariadb; then
    echo "note: no mysql/mariadb client; skip privilege hardening"
    return 0
  fi

  if [ -n "${SVC_DB:-}" ]; then
    svc_start "$SVC_DB"
    if [ "$SVC_DB" = mysql ] && [ "${INIT:-}" != systemd ] && [ -x /etc/init.d/mariadb ]; then
      svc_start mariadb
    fi
  fi

  cli=mysql
  have mysql || cli=mariadb

  tries=0
  while [ "$tries" -lt 15 ]; do
    if as_root "$cli" -N -e "SELECT 1" >/dev/null 2>&1; then
      break
    fi
    tries=$((tries + 1))
    sleep 1
  done
  if ! as_root "$cli" -N -e "SELECT 1" >/dev/null 2>&1; then
    echo "note: mariadb not answering on the unix socket yet — start it, then re-run"
    return 0
  fi

  as_root "$cli" -e "INSTALL SONAME 'auth_socket'" >/dev/null 2>&1 || true

  if as_root "$cli" -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket" >/dev/null 2>&1; then
    echo "mariadb: root@localhost is unix_socket (no password)"
  else
    echo "note: left root@localhost auth as-is (already socket, or not MariaDB ALTER USER)"
  fi

  tmp=$(mktemp)
  if as_root "$cli" -N -B -e "SELECT CONCAT('DROP USER IF EXISTS ', QUOTE(User), '@', QUOTE(Host), ';') FROM mysql.user WHERE User = '' OR (User = 'root' AND Host NOT IN ('localhost', '127.0.0.1', '::1'))" >"$tmp" 2>/dev/null; then
    if [ -s "$tmp" ]; then
      as_root "$cli" <"$tmp" >/dev/null 2>&1 || true
      echo "mariadb: dropped anonymous / remote-root accounts"
    fi
  fi
  rm -f "$tmp"

  as_root "$cli" -e "DROP DATABASE IF EXISTS test" >/dev/null 2>&1 || true
  as_root "$cli" -e "DELETE FROM mysql.db WHERE Db = 'test' OR Db = 'test\\_%'" >/dev/null 2>&1 || true
  as_root "$cli" -e "FLUSH PRIVILEGES" >/dev/null 2>&1 || true

  if as_root "$cli" -N -e "SELECT 1" >/dev/null 2>&1; then
    echo "mariadb: local socket OK after secure"
  else
    echo "note: mariadb socket failed after secure — check /var/log/mysql/error.log" >&2
  fi
}

secure_mysql
