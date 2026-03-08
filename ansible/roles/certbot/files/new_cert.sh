#!/bin/bash

set -euo pipefail

# Überprüfen, ob ein Service-Name übergeben wurde
if [ -z "$1" ]; then
  echo "Bitte den Namen des Services als Parameter übergeben."
  exit 1
fi

# Der Service-Name wird als erster Parameter übergeben
service_name=$1

# Docker-Befehl ausführen
docker run --rm \
  -v /root/.secrets/certbot/netcup.ini:/root/.secrets/certbot/netcup.ini \
  -v /etc/letsencrypt:/etc/letsencrypt \
  -v /var/log/letsencrypt:/var/log/letsencrypt \
  --cap-drop=all \
  certbot-dns-netcup:latest certbot certonly \
  --authenticator dns-netcup \
  --dns-netcup-propagation-seconds 1200 \
  --dns-netcup-credentials /root/.secrets/certbot/netcup.ini \
  --keep-until-expiring --non-interactive --expand \
  --server https://acme-v02.api.letsencrypt.org/directory \
  --agree-tos --email "letsencrypt@cindergla.de" \
  -d "$service_name"

# Zertifikat zusammenschieben
cat /etc/letsencrypt/live/$service_name/privkey.pem \
  /etc/letsencrypt/live/$service_name/fullchain.pem \
  > /etc/haproxy/ssl/$service_name.pem

systemctl restart haproxy
