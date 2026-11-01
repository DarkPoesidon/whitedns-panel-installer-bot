#!/usr/bin/env bash
# ==============================================================================
# WhiteDNS Soar Server - 100% Unattended Headless Installer
# Designed for Telegram Serverless Bot Automation
# Features: Nginx SSL Reverse Proxy, Auto-Certbot, Zero-Stall Loopback Binding
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
report_progress "1" "in_progress" "Validating server environment and resolving port 53..."

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

# Detect public IP if not supplied (multi-source fallback)
if [[ -z "$PUBLIC_IP" ]]; then
  PUBLIC_IP=$(curl -4s --connect-timeout 3 https://api.ipify.org 2>/dev/null || \
              curl -4s --connect-timeout 3 https://icanhazip.com 2>/dev/null || \
              curl -4s --connect-timeout 3 https://ifconfig.me 2>/dev/null || \
              ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' || \
              hostname -I 2>/dev/null | awk '{print $1}')
fi
PUBLIC_IP=$(echo "$PUBLIC_IP" | tr -d ' \n\r')
[[ -n "$PUBLIC_IP" ]] || die "Could not determine PUBLIC_IP."

# Fix systemd-resolved conflict on port 53 (common on Ubuntu/Debian)
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  if grep -qE '^#?DNSStubListener=' /etc/systemd/resolved.conf 2>/dev/null; then
    sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
  else
    mkdir -p /etc/systemd/resolved.conf.d
    echo -e "[Resolve]\nDNSStubListener=no" > /etc/systemd/resolved.conf.d/no-stub.conf
  fi
  systemctl restart systemd-resolved 2>/dev/null || true
fi

# Crucial: Ensure upstream DNS resolver is active and never loops back to dead 127.0.0.53
EXISTING_NS=$(grep -E '^[[:space:]]*nameserver[[:space:]]+' /etc/resolv.conf 2>/dev/null | grep -v '127\.0\.0\.' | awk '{print $2}' | tr '\n' ' ' || true)
RESOLVE_NS=$(grep -E '^[[:space:]]*nameserver[[:space:]]+' /run/systemd/resolve/resolv.conf 2>/dev/null | grep -v '127\.0\.0\.' | awk '{print $2}' | tr '\n' ' ' || true)
UPSTREAM_NS=$(printf "%s %s" "$EXISTING_NS" "$RESOLVE_NS" | tr ' ' '\n' | sort -u | grep -v '^$' || true)

rm -f /etc/resolv.conf
{
  for ns in $UPSTREAM_NS; do
    echo "nameserver $ns"
  done
  echo "nameserver 1.1.1.1"
  echo "nameserver 8.8.8.8"
  echo "nameserver 9.9.9.9"
  echo "options timeout:2 attempts:3"
} > /etc/resolv.conf

# Verify DNS resolution works; fallback to direct public DNS if host upstream failed
if ! curl -4s --connect-timeout 3 https://api.ipify.org >/dev/null 2>&1; then
  cat > /etc/resolv.conf <<EOF_DNS
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 9.9.9.9
nameserver 208.67.222.222
options timeout:2 attempts:3
EOF_DNS
fi

report_progress "1" "success" "Server verified: $ID $VERSION_ID ($BUNDLE_ARCH), IP: $PUBLIC_IP"

# ------------------------------------------------------------------------------
# 2. Install Required Dependencies
# ------------------------------------------------------------------------------
report_progress "2" "in_progress" "Preparing package manager and checking system locks..."

# Proactively stop background auto-updaters that lock apt/dpkg on fresh VPS boot
systemctl stop unattended-upgrades apt-daily.service apt-daily-upgrade.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl kill --kill-who=all unattended-upgrades.service apt-daily.service apt-daily-upgrade.service 2>/dev/null || true

# Wait gracefully up to 15 seconds for any running apt/dpkg process to finish
for i in {1..15}; do
  if ! pgrep -f "unattended-upgrade|apt.systemd.daily|apt-get|dpkg" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# If still held after 15s, terminate stale lock holders so installation is never stalled
pkill -9 -f "unattended-upgrade|apt.systemd.daily|apt-get|dpkg" 2>/dev/null || true
sleep 1

# Remove any stale lock files left behind
rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true

# Fix any partially configured packages safely with generous timeout and non-interactive flags
DEBIAN_FRONTEND=noninteractive timeout 60s dpkg --configure -a --force-confdef --force-confold 2>/dev/null || true

# Ensure universe and multiverse repositories are enabled on Ubuntu
if [[ "$ID" == "ubuntu" ]]; then
  # 1. Update deb822 format (/etc/apt/sources.list.d/ubuntu.sources)
  if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
    sed -i -E '/^Components:/ { /universe/! s/$/ universe/ }' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
    sed -i -E '/^Components:/ { /multiverse/! s/$/ multiverse/ }' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
  fi

  # 2. Update traditional format (/etc/apt/sources.list)
  if [[ -f /etc/apt/sources.list ]]; then
    sed -i -E '/^deb .*main/ { /universe/! s/main/main universe multiverse/ }' /etc/apt/sources.list 2>/dev/null || true
  fi

  # 3. If add-apt-repository is available, use it as well
  command -v add-apt-repository >/dev/null 2>&1 && add-apt-repository -y universe 2>/dev/null || true

  # 4. Explicit fallback sources file for official Ubuntu repositories
  UBUNTU_CODENAME="${VERSION_CODENAME:-}"
  [[ -n "$UBUNTU_CODENAME" ]] || UBUNTU_CODENAME=$(lsb_release -cs 2>/dev/null || echo "")
  if [[ -n "$UBUNTU_CODENAME" ]]; then
    cat > /etc/apt/sources.list.d/whitedns-official.list <<EOF_UBUNTU_SOURCES
deb http://archive.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF_UBUNTU_SOURCES
  fi
elif [[ "$ID" == "debian" ]]; then
  if [[ -f /etc/apt/sources.list ]]; then
    sed -i -E '/^deb .*main/ { /contrib/! s/main/main contrib non-free non-free-firmware/ }' /etc/apt/sources.list 2>/dev/null || true
  fi
  DEBIAN_CODENAME="${VERSION_CODENAME:-}"
  [[ -n "$DEBIAN_CODENAME" ]] || DEBIAN_CODENAME=$(lsb_release -cs 2>/dev/null || echo "")
  if [[ -n "$DEBIAN_CODENAME" ]]; then
    cat > /etc/apt/sources.list.d/whitedns-official.list <<EOF_DEBIAN_SOURCES
deb http://deb.debian.org/debian ${DEBIAN_CODENAME} main contrib non-free
deb http://deb.debian.org/debian-security ${DEBIAN_CODENAME}-security main contrib non-free
deb http://deb.debian.org/debian ${DEBIAN_CODENAME}-updates main contrib non-free
EOF_DEBIAN_SOURCES
  fi
fi

report_progress "2" "in_progress" "Updating package lists..."

APT_LOG=$(mktemp /tmp/whitedns-apt.XXXXXX)
APT_FLAGS="-y -o DPkg::Lock::Timeout=60 -o Acquire::Retries=3 -o Acquire::ForceIPv4=true -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

# Run apt-get update (with retry and log accumulation)
apt-get update $APT_FLAGS >"$APT_LOG" 2>&1 || {
  rm -f /var/lib/apt/lists/lock /var/lib/dpkg/lock* /var/cache/apt/archives/lock 2>/dev/null || true
  apt-get update $APT_FLAGS >>"$APT_LOG" 2>&1 || true
}

report_progress "2" "in_progress" "Installing prerequisites (nginx, openssl, curl, tar)..."

# Install core required packages (ca-certificates, curl, tar, openssl)
apt-get install -y --no-install-recommends $APT_FLAGS ca-certificates curl tar openssl iproute2 >>"$APT_LOG" 2>&1 || \
apt-get install -y $APT_FLAGS ca-certificates curl tar openssl iproute2 >>"$APT_LOG" 2>&1 || true

# Install Nginx reverse proxy (try nginx meta-package, fallback to nginx-light or nginx-core)
if ! command -v nginx >/dev/null 2>&1; then
  apt-get install -y --no-install-recommends $APT_FLAGS nginx >>"$APT_LOG" 2>&1 || \
  apt-get install -y $APT_FLAGS nginx >>"$APT_LOG" 2>&1 || \
  apt-get install -y --no-install-recommends $APT_FLAGS nginx-light >>"$APT_LOG" 2>&1 || \
  apt-get install -y --no-install-recommends $APT_FLAGS nginx-core >>"$APT_LOG" 2>&1 || true
fi

# Multi-tier fallback: if distro nginx packages still failed, install official Nginx from nginx.org upstream repository
if ! command -v nginx >/dev/null 2>&1; then
  report_progress "2" "in_progress" "Installing official Nginx from upstream repository..."
  mkdir -p /usr/share/keyrings
  curl -fsSL https://nginx.org/keys/nginx_signing.key 2>/dev/null | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg 2>/dev/null || true
  DISTRO_CODENAME="${VERSION_CODENAME:-}"
  [[ -n "$DISTRO_CODENAME" ]] || DISTRO_CODENAME=$(lsb_release -cs 2>/dev/null || echo "")
  if [[ -f /usr/share/keyrings/nginx-archive-keyring.gpg && -n "$DISTRO_CODENAME" ]]; then
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/${ID} ${DISTRO_CODENAME} nginx" > /etc/apt/sources.list.d/nginx-official.list
    apt-get update $APT_FLAGS >>"$APT_LOG" 2>&1 || true
    apt-get install -y $APT_FLAGS nginx >>"$APT_LOG" 2>&1 || true
  fi
fi

# Install Certbot (optional: openssl self-signed fallback exists in Step 6 if unavailable)
if ! command -v certbot >/dev/null 2>&1; then
  apt-get install -y --no-install-recommends $APT_FLAGS certbot >>"$APT_LOG" 2>&1 || true
fi

# Install optional utilities (bind9-dnsutils, ufw)
apt-get install -y --no-install-recommends $APT_FLAGS bind9-dnsutils >>"$APT_LOG" 2>&1 || \
apt-get install -y --no-install-recommends $APT_FLAGS dnsutils >>"$APT_LOG" 2>&1 || true
apt-get install -y --no-install-recommends $APT_FLAGS ufw >>"$APT_LOG" 2>&1 || true

# Validate essential tools
MISSING_TOOLS=()
for tool in curl tar openssl nginx; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    MISSING_TOOLS+=("$tool")
  fi
done

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
  APT_LAST_ERR=$(grep -iE '^(E:|error:|fatal:)' "$APT_LOG" 2>/dev/null | tail -n 3 | tr '\n' ' ' || true)
  rm -f "$APT_LOG"
  die "Failed to install required tools (${MISSING_TOOLS[*]}). Error: ${APT_LAST_ERR:-check server repository status}"
fi

rm -f "$APT_LOG"
report_progress "2" "success" "Dependencies successfully installed."

# ------------------------------------------------------------------------------
# 3. Download & Verify Official WhiteDNS Release Bundle
# ------------------------------------------------------------------------------
report_progress "3" "in_progress" "Fetching latest official WhiteDNS Soar Server release..."

# Detect latest release tag with multi-tier fallback (API, redirect, fallback version)
PANEL_REPO="WhiteDNS/Soar-Server"
LATEST_TAG=$(curl -fsSL --retry 3 "https://api.github.com/repos/$PANEL_REPO/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"tag_name": "panel-v?([^"]+)".*/\1/' || true)

if [[ -z "$LATEST_TAG" ]]; then
  LATEST_URL=$(curl -fsSL -o /dev/null -w "%{url_effective}" "https://github.com/$PANEL_REPO/releases/latest" 2>/dev/null || true)
  LATEST_TAG="${LATEST_URL##*/panel-v}"
fi

# Fallback default version if GitHub API/redirect is unreachable or rate-limited
if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "latest" || "$LATEST_TAG" == *"/"* ]]; then
  LATEST_TAG="0.14.0"
fi

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
install -d -o soar-panel -g soar-panel -m 0700 /var/lib/soar-panel/certificates
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

# Pre-configure access with random secret path on 127.0.0.1 loopback
/usr/local/bin/soar-panel configure-access \
  --db "$DB_FILE" \
  --listen "127.0.0.1:$PANEL_PORT" \
  --random-path

# Ensure domain is blank in access.json so soar-panel delegates SSL to Nginx
if [[ -f /var/lib/soar-panel/access.json ]]; then
  sed -i -E 's/"domain":[[:space:]]*"[^"]*"/"domain": ""/' /var/lib/soar-panel/access.json
  sed -i -E 's/"https":[[:space:]]*true/"https": false/' /var/lib/soar-panel/access.json
fi

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

# Wait for healthy service readiness
HEALTHY=0
for i in {1..20}; do
  if systemctl is-active --quiet soar-panel.service; then
    if timeout 3s /usr/local/bin/soar-panel health --db "$DB_FILE" --listen "127.0.0.1:$PANEL_PORT" >/dev/null 2>&1; then
      HEALTHY=1
      break
    fi
  fi
  sleep 1
done

if [[ $HEALTHY -eq 0 ]]; then
  if ss -ltn | grep -qE "(:$PANEL_PORT |127\.0\.0\.1:$PANEL_PORT)"; then
    HEALTHY=1
  fi
fi

[[ $HEALTHY -eq 1 ]] || die "Panel service failed to reach healthy state on port $PANEL_PORT."

report_progress "5" "success" "Systemd daemon services active and operational."

# ------------------------------------------------------------------------------
# 6. Configure SSL Certificate & High-Performance Nginx Reverse Proxy
# ------------------------------------------------------------------------------
report_progress "6" "in_progress" "Configuring domain SSL certificate and Nginx reverse proxy..."

systemctl stop nginx 2>/dev/null || true
mkdir -p /etc/letsencrypt

CERT_PATH="/etc/letsencrypt/live/$PANEL_DOMAIN"
CERT_FILE=""
KEY_FILE=""

# Attempt Certbot standalone Let's Encrypt certificate acquisition
certbot certonly --standalone --agree-tos --register-unsafely-without-email --non-interactive \
  -d "$PANEL_DOMAIN" --keep-until-expiring >/dev/null 2>&1 || true

if [[ -f "$CERT_PATH/fullchain.pem" && -f "$CERT_PATH/privkey.pem" ]]; then
  CERT_FILE="$CERT_PATH/fullchain.pem"
  KEY_FILE="$CERT_PATH/privkey.pem"
else
  # Check if another cert matches in letsencrypt live directory
  ALT_CERT=$(find /etc/letsencrypt/live -name "fullchain.pem" 2>/dev/null | head -n 1 || true)
  if [[ -n "$ALT_CERT" ]]; then
    CERT_FILE="$ALT_CERT"
    KEY_FILE="${ALT_CERT%/*}/privkey.pem"
  else
    # Fallback self-signed certificate: prevents total crash if domain DNS propagation is slow or rate-limited
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

# Check if IPv6 is supported by host kernel before enabling IPv6 listen sockets
IPV6_LISTEN_80=""
IPV6_LISTEN_443=""
if [[ -f /proc/net/if_inet6 ]] && [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0) -eq 0 ]]; then
  IPV6_LISTEN_80="listen [::]:80;"
  IPV6_LISTEN_443="listen [::]:443 ssl;"
fi

# Create dedicated Nginx reverse proxy configuration
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
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

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

report_progress "6" "success" "SSL certificate and Nginx proxy operational on ports 80/443."

# ------------------------------------------------------------------------------
# 7. Extract Secret Access URL & Final Summary
# ------------------------------------------------------------------------------
report_progress "7" "in_progress" "Extracting secure secret access URL..."

FINAL_URL=""
# Extract random security path directly from access.json
if [[ -f /var/lib/soar-panel/access.json ]]; then
  EXTRACTED_PATH=$(grep -oE '/[A-Za-z0-9_-]{20,}/' /var/lib/soar-panel/access.json | head -n 1 || true)
  if [[ -n "$EXTRACTED_PATH" ]]; then
    FINAL_URL="https://$PANEL_DOMAIN$EXTRACTED_PATH"
  fi
fi

# Fallback: query access-url command
if [[ -z "$FINAL_URL" ]]; then
  RAW_URL=$(timeout 5s /usr/local/bin/soar-panel access-url --db "$DB_FILE" --listen "127.0.0.1:$PANEL_PORT" 2>/dev/null || true)
  MATCHED_PATH=$(echo "$RAW_URL" | grep -oE '/[A-Za-z0-9_-]{20,}/' | head -n 1 || true)
  if [[ -n "$MATCHED_PATH" ]]; then
    FINAL_URL="https://$PANEL_DOMAIN$MATCHED_PATH"
  fi
fi

# Ultimate safety fallback
if [[ -z "$FINAL_URL" || ! "$FINAL_URL" =~ ^https?:// ]]; then
  FINAL_URL="https://$PANEL_DOMAIN/"
fi

[[ "$FINAL_URL" == */ ]] || FINAL_URL="$FINAL_URL/"

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
