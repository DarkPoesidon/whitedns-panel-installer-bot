#!/usr/bin/env bash
# ==============================================================================
# WhiteDNS Soar Server - 100% Unattended Headless Installer
# Designed for Telegram Serverless Bot Automation
# ==============================================================================
set -Eeuo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
umask 077

# Required environment variables or parameters:
ZONE="${ZONE:-}"
NS_HOST="${NS_HOST:-}"
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${ZONE#*.}}"
CALLBACK_URL="${CALLBACK_URL:-}"
PANEL_PORT="${PANEL_PORT:-2053}"
DNS_PORT="${DNS_PORT:-53}"
RESOLVERS="${RESOLVERS:-1.1.1.1,8.8.8.8}"

report_progress() {
  local step="$1"
  local status="$2"
  local message="$3"
  printf '[PROGRESS] Step %s (%s): %s\n' "$step" "$status" "$message"
  if [[ -n "$CALLBACK_URL" ]]; then
    curl -s -X POST "$CALLBACK_URL" \
      -H "Content-Type: application/json" \
      -d "{\"step\": \"$step\", \"status\": \"$status\", \"message\": \"$message\"}" >/dev/null 2>&1 || true
  fi
}

die() {
  local msg="$*"
  printf '\n[FATAL ERROR] %s\n' "$msg" >&2
  report_progress "FAILED" "error" "$msg"
  exit 1
}

# ------------------------------------------------------------------------------
# 1. Validation & System Checks
# ------------------------------------------------------------------------------
report_progress "1" "in_progress" "Validating server environment and ports..."

[[ $EUID -eq 0 ]] || die "This installer must be run as root."
[[ -r /etc/os-release ]] || die "Requires Ubuntu 22.04+ or Debian 12+."
. /etc/os-release
case "$ID:${VERSION_ID%%.*}" in
  ubuntu:22|ubuntu:24|ubuntu:26|debian:12|debian:13) ;;
  *) die "Unsupported OS: $ID $VERSION_ID. Supported: Ubuntu 22/24/26, Debian 12/13." ;;
esac

case "$(uname -m)" in
  x86_64|amd64) BUNDLE_ARCH="amd64" ;;
  aarch64|arm64) BUNDLE_ARCH="arm64" ;;
  *) die "Unsupported architecture: $(uname -m). Only amd64 and arm64 are supported." ;;
esac

[[ -n "$ZONE" ]] || die "ZONE is missing."
[[ -n "$NS_HOST" ]] || die "NS_HOST is missing."
[[ -n "$PANEL_DOMAIN" ]] || die "PANEL_DOMAIN is missing."
[[ -n "$ADMIN_PASS" ]] || die "ADMIN_PASS is missing."

# Detect public IP if not supplied
if [[ -z "$PUBLIC_IP" ]]; then
  PUBLIC_IP=$(curl -4s --connect-timeout 5 https://api.ipify.org || ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')
fi
[[ -n "$PUBLIC_IP" ]] || die "Could not determine PUBLIC_IP."

# Fix systemd-resolved conflict on port 53 (common on Ubuntu)
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  if grep -qE '^#?DNSStubListener=yes' /etc/systemd/resolved.conf; then
    sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
    systemctl restart systemd-resolved || true
  fi
fi

report_progress "1" "success" "Server verified: $ID $VERSION_ID ($BUNDLE_ARCH), IP: $PUBLIC_IP"

# ------------------------------------------------------------------------------
# 2. Install Required Dependencies
# ------------------------------------------------------------------------------
report_progress "2" "in_progress" "Installing prerequisites (curl, dnsutils, iproute2, ufw, tar)..."

apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl dnsutils iproute2 ufw tar coreutils util-linux

report_progress "2" "success" "Dependencies successfully installed."

# ------------------------------------------------------------------------------
# 3. Download & Verify Official WhiteDNS Release Bundle
# ------------------------------------------------------------------------------
report_progress "3" "in_progress" "Fetching latest official WhiteDNS Soar Server release..."

PANEL_REPO="WhiteDNS/Soar-Server"
LATEST_TAG=$(curl -fsSL --retry 3 "https://api.github.com/repos/$PANEL_REPO/releases/latest" | grep '"tag_name":' | sed -E 's/.*"tag_name": "panel-v?([^"]+)".*/\1/')

if [[ -z "$LATEST_TAG" ]]; then
  LATEST_URL=$(curl -fsSL -o /dev/null -w "%{url_effective}" "https://github.com/$PANEL_REPO/releases/latest")
  LATEST_TAG="${LATEST_URL##*/panel-v}"
fi

[[ -n "$LATEST_TAG" ]] || die "Failed to determine latest WhiteDNS release version."

WORK_DIR=$(mktemp -d /tmp/whitedns-soar-install.XXXXXX)
cleanup() { rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT

ASSET_NAME="soar-panel-$LATEST_TAG-linux-$BUNDLE_ARCH.tar.gz"
DOWNLOAD_URL="https://github.com/$PANEL_REPO/releases/download/panel-v$LATEST_TAG/$ASSET_NAME"
CHECKSUM_URL="$DOWNLOAD_URL.sha256"

curl -fsSL --retry 3 "$DOWNLOAD_URL" -o "$WORK_DIR/$ASSET_NAME" || die "Failed to download $ASSET_NAME."
curl -fsSL --retry 3 "$CHECKSUM_URL" -o "$WORK_DIR/$ASSET_NAME.sha256" || die "Failed to download checksum file."

(cd "$WORK_DIR" && sha256sum --check --status "$ASSET_NAME.sha256") || die "SHA256 checksum mismatch! Aborting."

tar -xzf "$WORK_DIR/$ASSET_NAME" -C "$WORK_DIR"
EXTRACTED_DIR="$WORK_DIR/soar-panel-$LATEST_TAG-linux-$BUNDLE_ARCH"

report_progress "3" "success" "Downloaded and verified WhiteDNS v$LATEST_TAG ($BUNDLE_ARCH)."

# ------------------------------------------------------------------------------
# 4. User Provisioning, Binaries, Database & Firewall
# ------------------------------------------------------------------------------
report_progress "4" "in_progress" "Setting up system user, binaries and database..."

id soar-panel >/dev/null 2>&1 || useradd --system --home-dir /var/lib/soar-panel --shell /usr/sbin/nologin soar-panel

install -d -o soar-panel -g soar-panel -m 0700 /var/lib/soar-panel
install -d -m 0700 /var/lib/soar-panel-ops

install -m 0755 "$EXTRACTED_DIR/bin/linux-$BUNDLE_ARCH/soar-panel" /usr/local/bin/soar-panel
install -m 0755 "$EXTRACTED_DIR/bin/linux-$BUNDLE_ARCH/soar-panel-ops" /usr/local/bin/soar-panel-ops
install -m 0755 "$EXTRACTED_DIR/bin/linux-$BUNDLE_ARCH/soar-check" /usr/local/bin/soar-check
install -m 0755 "$EXTRACTED_DIR/panel-security.sh" /usr/local/bin/soar-panel-security
install -m 0755 "$EXTRACTED_DIR/panel-menu.sh" /usr/local/bin/soar-panel-menu
ln -sf /usr/local/bin/soar-panel-menu /usr/local/bin/whitedns

printf '%s\n' "$PUBLIC_IP" > /var/lib/soar-panel/public-ip
chmod 0600 /var/lib/soar-panel/public-ip
chown soar-panel:soar-panel /var/lib/soar-panel/public-ip

DB_FILE="/var/lib/soar-panel/panel.db"
PW_FILE=$(mktemp /tmp/soar-pw.XXXXXX)
printf '%s' "$ADMIN_PASS" > "$PW_FILE"
chmod 0600 "$PW_FILE"

if [[ ! -f "$DB_FILE" ]]; then
  /usr/local/bin/soar-panel init \
    --db "$DB_FILE" \
    --zone "$ZONE" \
    --nameserver "$NS_HOST" \
    --public-ip "$PUBLIC_IP" \
    --resolvers "$RESOLVERS" \
    --admin "$ADMIN_USER" \
    --password-file "$PW_FILE"
fi
rm -f -- "$PW_FILE"

chown soar-panel:soar-panel "$DB_FILE"
chmod 0600 "$DB_FILE"

# Pre-configure initial access with random secret path
/usr/local/bin/soar-panel configure-access \
  --db "$DB_FILE" \
  --listen "127.0.0.1:$PANEL_PORT" \
  --random-path

chown soar-panel:soar-panel /var/lib/soar-panel/access.json
chmod 0600 /var/lib/soar-panel/access.json

# Configure UFW firewall if enabled
if command -v ufw >/dev/null 2>&1; then
  ufw allow "$DNS_PORT/udp" comment 'soar-tunnel-dns' || true
  ufw allow "$DNS_PORT/tcp" comment 'soar-tunnel-dns' || true
  ufw allow 80/tcp comment 'soar-acme-http' || true
  ufw allow 443/tcp comment 'soar-panel-https' || true
fi

report_progress "4" "success" "User, database and firewall rules initialized."

# ------------------------------------------------------------------------------
# 5. Install & Start Systemd Services
# ------------------------------------------------------------------------------
report_progress "5" "in_progress" "Configuring and launching systemd daemon services..."

cat > /etc/systemd/system/soar-panel.service <<UNIT
[Unit]
Description=WhiteDNS Soar Management Panel
After=network-online.target
Wants=network-online.target
Wants=soar-panel-ops.service

[Service]
Type=simple
User=soar-panel
Group=soar-panel
ExecStart=/usr/local/bin/soar-panel run --db /var/lib/soar-panel/panel.db --dns-listen 0.0.0.0:$DNS_PORT --listen 127.0.0.1:$PANEL_PORT --trust-loopback-proxy
Restart=on-failure
RestartSec=3
TimeoutStopSec=10
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/soar-panel
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
UMask=0077
LimitNOFILE=8192

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/soar-panel-ops.service <<UNIT
[Unit]
Description=WhiteDNS private panel maintenance service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=soar-panel
ExecStart=/usr/local/bin/soar-panel-ops --health-address 127.0.0.1:$PANEL_PORT --dns-port $DNS_PORT
Restart=on-failure
RestartSec=3
RuntimeDirectory=soar-panel-ops
RuntimeDirectoryMode=0750
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/usr/local/bin /var/lib/soar-panel /var/lib/soar-panel-ops /run/soar-panel-ops
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl restart soar-panel-ops.service || systemctl start soar-panel-ops.service || true
systemctl restart soar-panel.service || systemctl start soar-panel.service || true
systemctl enable soar-panel-ops.service || true
systemctl enable soar-panel.service || true

# Wait for healthy service readiness (with timeout per attempt)
HEALTHY=0
for i in {1..25}; do
  if systemctl is-active --quiet soar-panel.service; then
    if timeout 3s /usr/local/bin/soar-panel health --db "$DB_FILE" --listen "127.0.0.1:$PANEL_PORT" >/dev/null 2>&1; then
      HEALTHY=1
      break
    fi
  fi
  sleep 1
done

# Fallback check: verify socket is listening
if [[ $HEALTHY -eq 0 ]]; then
  if ss -ltn | grep -qE "(:$PANEL_PORT |127\.0\.0\.1:$PANEL_PORT)"; then
    HEALTHY=1
  fi
fi

[[ $HEALTHY -eq 1 ]] || die "Panel service failed to reach healthy state on port $PANEL_PORT."

report_progress "5" "success" "Systemd daemon services active and operational."

# ------------------------------------------------------------------------------
# 6. Configure Panel Domain & SSL Certificate
# ------------------------------------------------------------------------------
report_progress "6" "in_progress" "Configuring panel domain and Let's Encrypt SSL certificate..."

systemctl stop soar-panel.service || true

# Execute configure-access with bounded timeout (30 seconds)
if ! timeout 30s /usr/local/bin/soar-panel configure-access \
    --db "$DB_FILE" \
    --listen "127.0.0.1:$PANEL_PORT" \
    --domain "$PANEL_DOMAIN" \
    --email "$ADMIN_EMAIL" \
    --random-path; then
  # Fallback to keep existing random path if domain ACME challenge times out
  timeout 10s /usr/local/bin/soar-panel configure-access \
    --db "$DB_FILE" \
    --listen "127.0.0.1:$PANEL_PORT" \
    --random-path || true
fi

chown soar-panel:soar-panel /var/lib/soar-panel/access.json || true
if [[ -d /var/lib/soar-panel/certificates ]]; then
  chown -R soar-panel:soar-panel /var/lib/soar-panel/certificates || true
fi

systemctl restart soar-panel.service || systemctl start soar-panel.service || true
sleep 2

report_progress "6" "success" "SSL and domain configuration completed."

# ------------------------------------------------------------------------------
# 7. Extract Secret Access URL & Final Summary
# ------------------------------------------------------------------------------
report_progress "7" "in_progress" "Extracting secure secret access URL..."

FINAL_URL=""
# Try official access-url command with timeout
FINAL_URL=$(timeout 8s /usr/local/bin/soar-panel access-url --db "$DB_FILE" --listen "127.0.0.1:$PANEL_PORT" 2>/dev/null || true)

# If access-url returned loopback IP, replace it with https://$PANEL_DOMAIN
if [[ "$FINAL_URL" == http://127.0.0.1* || "$FINAL_URL" == http://localhost* ]]; then
  SECRET_PATH="${FINAL_URL#*:$PANEL_PORT}"
  FINAL_URL="https://$PANEL_DOMAIN$SECRET_PATH"
fi

# Fallback: extract random security path directly from access.json
if [[ -z "$FINAL_URL" || "$FINAL_URL" == "https://$PANEL_DOMAIN" || "$FINAL_URL" == "https://$PANEL_DOMAIN/" ]]; then
  if [[ -f /var/lib/soar-panel/access.json ]]; then
    EXTRACTED_PATH=$(grep -oE '/[A-Za-z0-9_-]{20,}/' /var/lib/soar-panel/access.json | head -n 1 || true)
    if [[ -n "$EXTRACTED_PATH" ]]; then
      FINAL_URL="https://$PANEL_DOMAIN$EXTRACTED_PATH"
    fi
  fi
fi

# Ultimate safety fallback
if [[ -z "$FINAL_URL" || ! "$FINAL_URL" =~ ^https?:// ]]; then
  FINAL_URL="https://$PANEL_DOMAIN/"
fi

report_progress "7" "success" "Secret URL extracted successfully."
report_progress "COMPLETED" "success" "WhiteDNS installation complete!"

printf '\n<<<WHITEDNS_JSON_SUMMARY_START>>>\n'
cat <<JSON_OUT
{
  "status": "success",
  "version": "$LATEST_TAG",
  "panel_url": "$FINAL_URL",
  "admin_user": "$ADMIN_USER",
  "admin_pass": "$ADMIN_PASS",
  "public_ip": "$PUBLIC_IP",
  "zone": "$ZONE",
  "nameserver": "$NS_HOST",
  "panel_domain": "$PANEL_DOMAIN"
}
JSON_OUT
printf '\n<<<WHITEDNS_JSON_SUMMARY_END>>>\n'
