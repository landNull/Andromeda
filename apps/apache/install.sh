#!/bin/sh
# modules/20-apache2.sh — rewrite/headers/expires, localhost bind, dnsmasq
# Apache packages are installed in 10-core-prereqs. This phase only tunes.

echo "STEP 20: Apache modules, localhost bind, devel DNS"

if [ "$DRYRUN" -eq 1 ]; then
  echo "+ a2enmod rewrite headers expires"
elif have a2enmod; then
  run_root a2enmod rewrite >/dev/null 2>&1 || true
  run_root a2enmod headers >/dev/null 2>&1 || true
  run_root a2enmod expires >/dev/null 2>&1 || true
fi

if [ "$LOCALHOST" -eq 1 ]; then
  if [ -d /etc/apache2 ]; then
    printf '%s\n' "Listen 127.0.0.1:80" | write_dropin /etc/apache2/conf-available/andromeda-localhost.conf
    if have a2enconf; then
      run_root a2enconf andromeda-localhost >/dev/null 2>&1 || true
    fi
  fi
  echo "localhost: Apache should listen on 127.0.0.1 only (disable stock Listen 80 if it still binds all addresses)"
fi

# dnsmasq: devel / --localhost only. Never on test/live (use public DNS).
if [ "$LOCALHOST" -eq 1 ] || [ "$ROLE" = devel ]; then
  if [ "$LOCALHOST" -eq 1 ]; then
    dns_ip=127.0.0.1
  else
    dns_ip=${DEV_DNS_IP:-}
    if [ -z "$dns_ip" ]; then
      dns_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    [ -n "$dns_ip" ] || dns_ip=127.0.0.1
  fi
  if [ -d /etc/dnsmasq.d ] || [ "$DRYRUN" -eq 1 ]; then
    printf '%s\n' "address=/devel/${dns_ip}" | write_dropin /etc/dnsmasq.d/andromeda.conf
  fi
  svc_start dnsmasq
else
  echo "VPS $ROLE: skip dnsmasq (use public DNS / Cloudflare)"
fi
