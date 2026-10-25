#!/usr/bin/env bash
# fi-fix.sh — Repair syntax error in install-andromeda.sh
set -euo pipefail

TARGET_FILE="install-andromeda.sh"

if [ ! -f "$TARGET_FILE" ]; then
    echo "ERROR: Cannot find $TARGET_FILE in the current working directory." >&2
    exit 1
fi

echo "==> Creating backup: ${TARGET_FILE}.bak..."
cp "$TARGET_FILE" "${TARGET_FILE}.bak"

echo "==> Replacing corrupted bootstrap_deps function..."
python3 -c '
import re

with open("install-andromeda.sh", "r") as f:
    code = f.read()

fixed_fn = """bootstrap_deps() {
	  echo "bootstrap extras (skip when config already exists)"

  if have php-fpm || [ -x /etc/init.d/php-fpm ] || ls /etc/init.d/php*-fpm >/dev/null 2>&1; then
    for s in php8.2-fpm php8.3-fpm php8.4-fpm php7.4-fpm php-fpm; do
      if [ -x "/etc/init.d/$s" ] || [ -d "/lib/systemd/system/$s.service" ]; then
        svc_start "$s"
        break
      fi
    done
  fi

  if have mysql || have mariadb; then
    if [ "$DRYRUN" -eq 0 ]; then
      if mysql -N -e "SELECT 1" >/dev/null 2>&1; then
        echo "mariadb: local socket OK"
      else
        echo "note: mariadb not answering on the unix socket yet — start it, then re-run"
      fi
    fi
  fi

  if have etckeeper; then
    if [ -d /etc/.git ]; then
      echo "etckeeper: /etc already a repo (unchanged)"
    elif [ "$DRYRUN" -eq 1 ]; then
      echo "+ etckeeper init"
    else
      as_root etckeeper init >/dev/null 2>&1 || true
      as_root etckeeper commit -m "andromeda first run" >/dev/null 2>&1 || true
      echo "etckeeper: initialized /etc"
    fi
  fi

  if have needrestart && [ -d /etc/needrestart/conf.d ]; then
    printf '\''%s\\n'\'' '\''$nrconf{restart} = "l";'\'' \\
      | write_if_absent /etc/needrestart/conf.d/andromeda.conf
  fi

  if have logwatch; then
    printf '\''%s\\n'\'' "Detail = Low" "MailTo = root" \\
      | write_if_absent /etc/logwatch/conf/logwatch.conf
  fi

  if have goaccess && [ ! -f /etc/goaccess/goaccess.conf ]; then
    echo "note: goaccess installed — run: goaccess /var/log/apache2/access.log"
  fi

  if have smartd || [ -x /etc/init.d/smartd ] || [ -x /etc/init.d/smartmontools ]; then
    :
  fi
  if have irqbalance || [ -x /etc/init.d/irqbalance ]; then
    :
  fi
  if have haveged || [ -x /etc/init.d/haveged ]; then
    :
  fi

  age_key="$STARDUST/state/secrets/age.key"
  if have age-keygen; then
    if as_root test -f "$age_key"; then
      echo "age: $age_key exists (unchanged)"
    elif [ "$DRYRUN" -eq 1 ]; then
      echo "+ age-keygen -o $age_key"
    else
      as_root mkdir -p "$STARDUST/state/secrets"
      as_root age-keygen -o "$age_key"
      as_root chown "$OWNER:andromeda" "$age_key"
      as_root chmod 0640 "$age_key"
      echo "age: wrote $age_key"
    fi
  fi

  if have msmtp || have msmtp-mta; then
    if [ -f /etc/msmtprc ]; then
      echo "msmtp: /etc/msmtprc exists (unchanged)"
    else
      printf '\''%s\\n'\'' \\
        "# Andromeda msmtp — fill host/user/password, then: chmod 0640 /etc/msmtprc" \\
        "defaults" \\
        "auth           on" \\
        "tls            on" \\
        "tls_starttls   on" \\
        "logfile        /var/log/msmtp.log" \\
        "account        default" \\
        "host           mail.example" \\
        "port           587" \\
        "from           andromeda@example" \\
        "user           andromeda@example" \\
        "password       CHANGE-ME" \\
        | write_if_absent /etc/msmtprc.example
      if [ "$DRYRUN" -eq 0 ] && [ -t 0 ]; then
        nmail=$(install_prompt "NOTIFY email — where backup/fail mail goes (empty skip)" "" \\
          "Andromeda can mail after backup-all or a failed site-check.
This only sets NOTIFY= in /etc/andromeda.conf.
You still copy /etc/msmtprc.example to /etc/msmtprc and put real SMTP there.")
        if [ -n "$nmail" ] && [ -f /etc/andromeda.conf ]; then
          if grep -q '\''^NOTIFY='\'' /etc/andromeda.conf; then
            as_root sed -i "s|^NOTIFY=.*|NOTIFY=$nmail|" /etc/andromeda.conf
          else
            as_root sh -c "printf '\''NOTIFY=%s\\\\n'\'' '\''$nmail'\'' >> /etc/andromeda.conf"
          fi
          echo "NOTIFY=$nmail — copy /etc/msmtprc.example to /etc/msmtprc and edit SMTP"
        fi
      else
        echo "msmtp: wrote /etc/msmtprc.example (not live until you copy it)"
      fi
    fi
  fi

  if have git && [ "$DRYRUN" -eq 0 ]; then
    as_root git config --system --get safe.directory "$PLATFORMS" >/dev/null 2>&1 \\
      || as_root git config --system --add safe.directory "$PLATFORMS" || true
    as_root -u "$OWNER" git config --global init.defaultBranch devel 2>/dev/null || true
  fi

  if [ "$LOCALHOST" -eq 0 ] && { [ "$ROLE" = test ] || [ "$ROLE" = live ]; }; then
    if have certbot; then
      echo "certbot: installed — obtain certs after site-add, not during install"
    fi
  fi
}"""

updated = re.sub(r"bootstrap_deps\(\)\s*\{.*?\n\}", fixed_fn, code, flags=re.DOTALL)
with open("install-andromeda.sh", "w") as f:
    f.write(updated)
'

echo "==> Verifying POSIX shell syntax..."
if sh -n "$TARGET_FILE"; then
    echo "✓ $TARGET_FILE syntax validated successfully. You can now run the installer."
else
    echo "✗ Verification failed! Restoring backup..." >&2
    cp "${TARGET_FILE}.bak" "$TARGET_FILE"
    exit 1
fi
