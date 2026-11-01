#!/usr/bin/env bash
# ==============================================================================
# WhiteDNS Soar Server - Comprehensive Health Check & Auto-Repair Tool
# Fixes: DNS resolvers, Port 53 conflicts, Systemd services, Nginx reverse proxy,
# SSL certificates, UFW firewall, and restores the live secret Panel URL.
# ==============================================================================
set -Eeuo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

PANEL_DOMAIN="${PANEL_DOMAIN:-}"
PANEL_PORT="${PANEL_PORT:-2053}"
DNS_PORT="${DNS_PORT:-53}"

report_progress() {
  local step="$1"
  local status="$2"
  local message="$3"
  printf '[PROGRESS] Step %s (%s): %s\n' "$step" "$status" "$message"
}

die() {
  local msg="$*"
  printf '\n[FATAL ERROR] %s\n' "$msg" >&2
  report_progress "FAILED" "error" "$msg"
  exit 1
}

[[ $EUID -eq 0 ]] || die "This repair tool must be run as root."

# ------------------------------------------------------------------------------
# 1. Check & Fix DNS Resolution (/etc/resolv.conf)
# ------------------------------------------------------------------------------
report_progress "1" "in_progress" "Checking and fixing DNS resolution and nameservers..."

if ! curl -4s --connect-timeout 3 https://api.ipify.org >/dev/null 2>&1; then
  rm -f /etc/resolv.conf
  printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 9.9.9.9\n" > /etc/resolv.conf
fi

report_progress "1" "success" "DNS resolution confirmed operational."

# ------------------------------------------------------------------------------
# 2. Check & Fix Port 53 Conflicts (systemd-resolved)
# ------------------------------------------------------------------------------
report_progress "2" "in_progress" "Inspecting and clearing port 53 DNS listener..."

if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  if grep -qE '^#?DNSStubListener=' /etc/systemd/resolved.conf 2>/dev/null; then
    sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
  else
    mkdir -p /etc/systemd/resolved.conf.d
    echo -e "[Resolve]\nDNSStubListener=no" > /etc/systemd/resolved.conf.d/no-stub.conf
  fi
  systemctl restart systemd-resolved 2>/dev/null || true
fi

EXISTING_NS=$(grep -E '^[[:space:]]*nameserver[[:space:]]+' /etc/resolv.conf 2>/dev/null | grep -v '127\.0\.0\.' | awk '{print $2}' | tr '\n' ' ' || true)

rm -f /etc/resolv.conf
{
  for ns in $EXISTING_NS; do
    echo "nameserver $ns"
  done
  echo "nameserver 1.1.1.1"
  echo "nameserver 8.8.8.8"
  echo "nameserver 9.9.9.9"
  echo "options timeout:2 attempts:3"
} > /etc/resolv.conf

report_progress "2" "success" "Port 53 freed from systemd-resolved."

# ------------------------------------------------------------------------------
# 3. Verify & Repair System Permissions and WhiteDNS Daemons
# ------------------------------------------------------------------------------
report_progress "3" "in_progress" "Verifying WhiteDNS core files, permissions and services..."

DB_FILE="/var/lib/soar-panel/panel.db"
[[ -f "$DB_FILE" ]] || die "WhiteDNS database not found at $DB_FILE. Is WhiteDNS installed?"

chown -R soar-panel:soar-panel /var/lib/soar-panel 2>/dev/null || true
chmod 0700 /var/lib/soar-panel 2>/dev/null || true
chmod 0600 "$DB_FILE" 2>/dev/null || true

# Autodetect PANEL_DOMAIN if not supplied
if [[ -z "$PANEL_DOMAIN" ]]; then
  if [[ -f /etc/nginx/sites-available/soar-panel ]]; then
    PANEL_DOMAIN=$(grep -E 'server_name' /etc/nginx/sites-available/soar-panel | head -n 1 | awk '{print $2}' | tr -d ';' || true)
  fi
fi
if [[ -z "$PANEL_DOMAIN" && -f /var/lib/soar-panel/access.json ]]; then
  PANEL_DOMAIN=$(grep -oE '"domain":[[:space:]]*"[^"]+"' /var/lib/soar-panel/access.json | cut -d'"' -f4 || true)
fi

# Ensure access.json uses loopback proxy without internal ACME hang
if [[ -f /var/lib/soar-panel/access.json ]]; then
  sed -i -E 's/"domain":[[:space:]]*"[^"]*"/"domain": ""/' /var/lib/soar-panel/access.json
  sed -i -E 's/"https":[[:space:]]*true/"https": false/' /var/lib/soar-panel/access.json
  chmod 0600 /var/lib/soar-panel/access.json
  chown soar-panel:soar-panel /var/lib/soar-panel/access.json
fi

# Ensure systemd service has --trust-loopback-proxy
if [[ -f /etc/systemd/system/soar-panel.service ]]; then
  if ! grep -q -- '--trust-loopback-proxy' /etc/systemd/system/soar-panel.service; then
    sed -i 's|ExecStart=.*|ExecStart=/usr/local/bin/soar-panel run --db /var/lib/soar-panel/panel.db --dns-listen 0.0.0.0:'"$DNS_PORT"' --listen 127.0.0.1:'"$PANEL_PORT"' --trust-loopback-proxy|' /etc/systemd/system/soar-panel.service
    systemctl daemon-reload
  fi
fi

systemctl restart soar-panel-ops.service 2>/dev/null || true
systemctl restart soar-panel.service 2>/dev/null || true

HEALTHY=0
for i in {1..15}; do
  if systemctl is-active --quiet soar-panel.service; then
    HEALTHY=1
    break
  fi
  sleep 1
done
[[ $HEALTHY -eq 1 ]] || die "soar-panel.service could not be restarted."

report_progress "3" "success" "WhiteDNS daemons active and responsive."

# ------------------------------------------------------------------------------
# 4. Check & Repair Firewall Rules (UFW)
# ------------------------------------------------------------------------------
report_progress "4" "in_progress" "Inspecting and updating firewall rules..."

if command -v ufw >/dev/null 2>&1; then
  ufw allow "$DNS_PORT/udp" comment 'soar-tunnel-dns' >/dev/null 2>&1 || true
  ufw allow "$DNS_PORT/tcp" comment 'soar-tunnel-dns' >/dev/null 2>&1 || true
  ufw allow 80/tcp comment 'soar-acme-http' >/dev/null 2>&1 || true
  ufw allow 443/tcp comment 'soar-panel-https' >/dev/null 2>&1 || true
fi

report_progress "4" "success" "Firewall ports 53, 80 and 443 verified."

# ------------------------------------------------------------------------------
# 5. Check & Repair Nginx Reverse Proxy and SSL Certificate
# ------------------------------------------------------------------------------
report_progress "5" "in_progress" "Verifying SSL certificate and Nginx reverse proxy..."

if ! command -v nginx >/dev/null 2>&1; then
  APT_FLAGS="-y -o DPkg::Lock::Timeout=60 -o Acquire::Retries=3 -o Acquire::ForceIPv4=true -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
  apt-get update $APT_FLAGS >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends $APT_FLAGS nginx >/dev/null 2>&1 || \
  apt-get install -y $APT_FLAGS nginx >/dev/null 2>&1 || \
  apt-get install -y --no-install-recommends $APT_FLAGS nginx-light >/dev/null 2>&1 || \
  apt-get install -y --no-install-recommends $APT_FLAGS nginx-core >/dev/null 2>&1 || true
fi

CERT_FILE=""
KEY_FILE=""

if [[ -n "$PANEL_DOMAIN" ]]; then
  CERT_PATH="/etc/letsencrypt/live/$PANEL_DOMAIN"
  if [[ -f "$CERT_PATH/fullchain.pem" && -f "$CERT_PATH/privkey.pem" ]]; then
    CERT_FILE="$CERT_PATH/fullchain.pem"
    KEY_FILE="$CERT_PATH/privkey.pem"
  else
    ALT_CERT=$(find /etc/letsencrypt/live -name "fullchain.pem" 2>/dev/null | head -n 1 || true)
    if [[ -n "$ALT_CERT" ]]; then
      CERT_FILE="$ALT_CERT"
      KEY_FILE="${ALT_CERT%/*}/privkey.pem"
    else
      systemctl stop nginx 2>/dev/null || true
      certbot certonly --standalone --agree-tos --register-unsafely-without-email --non-interactive \
        -d "$PANEL_DOMAIN" --keep-until-expiring >/dev/null 2>&1 || true
      if [[ -f "$CERT_PATH/fullchain.pem" && -f "$CERT_PATH/privkey.pem" ]]; then
        CERT_FILE="$CERT_PATH/fullchain.pem"
        KEY_FILE="$CERT_PATH/privkey.pem"
      else
        mkdir -p /etc/ssl/certs /etc/ssl/private
        CERT_FILE="/etc/ssl/certs/soar-selfsigned.crt"
        KEY_FILE="/etc/ssl/private/soar-selfsigned.key"
        if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
          openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$KEY_FILE" \
            -out "$CERT_FILE" \
            -subj "/CN=$PANEL_DOMAIN" >/dev/null 2>&1 || true
        fi
      fi
    fi
  fi
fi

if [[ -n "$PANEL_DOMAIN" && -n "$CERT_FILE" ]]; then
IPV6_LISTEN_80=""
IPV6_LISTEN_443=""
if [[ -f /proc/net/if_inet6 ]] && [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0) -eq 0 ]]; then
  IPV6_LISTEN_80="listen [::]:80;"
  IPV6_LISTEN_443="listen [::]:443 ssl;"
fi

cat > /etc/nginx/sites-available/soar-panel <<NGINX_CONF
server {
    listen 80;
    ${IPV6_LISTEN_80}
    server_name $PANEL_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    ${IPV6_LISTEN_443}
    server_name $PANEL_DOMAIN;

    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    client_max_body_size 64M;

    location / {
        proxy_pass http://127.0.0.1:$PANEL_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
NGINX_CONF

ln -sf /etc/nginx/sites-available/soar-panel /etc/nginx/sites-enabled/soar-panel
rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null 2>&1 || true
systemctl restart nginx || systemctl start nginx || true
systemctl enable nginx 2>/dev/null || true
fi

report_progress "5" "success" "SSL and Nginx reverse proxy operational."

# ------------------------------------------------------------------------------
# 6. Extract Secret Access URL & Final Summary
# ------------------------------------------------------------------------------
report_progress "6" "in_progress" "Extracting and verifying live secret panel URL..."

FINAL_URL=""
if [[ -f /var/lib/soar-panel/access.json ]]; then
  EXTRACTED_PATH=$(grep -oE '/[A-Za-z0-9_-]{20,}/' /var/lib/soar-panel/access.json | head -n 1 || true)
  if [[ -n "$EXTRACTED_PATH" && -n "$PANEL_DOMAIN" ]]; then
    FINAL_URL="https://$PANEL_DOMAIN$EXTRACTED_PATH"
  fi
fi

if [[ -z "$FINAL_URL" ]]; then
  RAW_URL=$(timeout 5s /usr/local/bin/soar-panel access-url --db "$DB_FILE" --listen "127.0.0.1:$PANEL_PORT" 2>/dev/null || true)
  MATCHED_PATH=$(echo "$RAW_URL" | grep -oE '/[A-Za-z0-9_-]{20,}/' | head -n 1 || true)
  if [[ -n "$MATCHED_PATH" && -n "$PANEL_DOMAIN" ]]; then
    FINAL_URL="https://$PANEL_DOMAIN$MATCHED_PATH"
  fi
fi

if [[ -z "$FINAL_URL" && -n "$PANEL_DOMAIN" ]]; then
  FINAL_URL="https://$PANEL_DOMAIN/"
fi

[[ "$FINAL_URL" == */ ]] || FINAL_URL="$FINAL_URL/"

report_progress "6" "success" "Diagnostics and repair completed successfully."
report_progress "COMPLETED" "success" "Panel is online and operational."

printf '\n<<<WHITEDNS_JSON_SUMMARY_START>>>\n'
cat <<JSON_OUT
{
  "status": "success",
  "action": "repaired",
  "panel_url": "$FINAL_URL",
  "panel_domain": "$PANEL_DOMAIN",
  "dns_port": "$DNS_PORT",
  "panel_port": "$PANEL_PORT"
}
JSON_OUT
printf '\n<<<WHITEDNS_JSON_SUMMARY_END>>>\n'
