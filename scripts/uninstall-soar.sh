#!/usr/bin/env bash
# ==============================================================================
# WhiteDNS Soar Server - Complete Uninstaller & Cleanup Script
# 100% Unattended Headless Execution
# ==============================================================================
set -Eeuo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

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

[[ $EUID -eq 0 ]] || die "This script must be run as root."

report_progress "1" "in_progress" "Stopping and disabling WhiteDNS daemon services..."

# 1. Stop and disable systemd services
if systemctl is-active --quiet soar-panel.service 2>/dev/null; then
  systemctl stop soar-panel.service || true
fi
if systemctl is-active --quiet soar-panel-ops.service 2>/dev/null; then
  systemctl stop soar-panel-ops.service || true
fi

systemctl disable soar-panel.service 2>/dev/null || true
systemctl disable soar-panel-ops.service 2>/dev/null || true

rm -f /etc/systemd/system/soar-panel.service
rm -f /etc/systemd/system/soar-panel-ops.service
systemctl daemon-reload

report_progress "1" "success" "Services stopped and systemd units removed."

# 2. Remove binaries and symbolic links
report_progress "2" "in_progress" "Removing WhiteDNS binaries and symlinks..."

rm -f /usr/local/bin/soar-panel
rm -f /usr/local/bin/soar-panel-ops
rm -f /usr/local/bin/soar-check
rm -f /usr/local/bin/soar-panel-security
rm -f /usr/local/bin/soar-panel-menu
rm -f /usr/local/bin/whitedns

report_progress "2" "success" "Binaries deleted."

# 3. Purge data directories and user
report_progress "3" "in_progress" "Purging configuration databases and data directories..."

rm -rf /var/lib/soar-panel
rm -rf /var/lib/soar-panel-ops
rm -rf /run/soar-panel-ops
rm -rf /root/soar-panel-access-*
rm -rf /root/soar-panel-backup-*

if id soar-panel >/dev/null 2>&1; then
  userdel soar-panel 2>/dev/null || true
fi

report_progress "3" "success" "Data files, certificates, and system user purged."

# 4. Remove Nginx reverse proxy site configuration if present
if [[ -f /etc/nginx/sites-available/soar-panel || -L /etc/nginx/sites-enabled/soar-panel ]]; then
  rm -f /etc/nginx/sites-enabled/soar-panel /etc/nginx/sites-available/soar-panel
  systemctl reload nginx 2>/dev/null || true
fi

# 5. Restore DNS Stub Listener if needed
report_progress "4" "in_progress" "Restoring default DNS configuration..."

if [[ -f /etc/systemd/resolved.conf ]]; then
  if grep -qE '^DNSStubListener=no' /etc/systemd/resolved.conf; then
    sed -i 's/^DNSStubListener=no/#DNSStubListener=yes/' /etc/systemd/resolved.conf
    systemctl restart systemd-resolved 2>/dev/null || true
  fi
fi

report_progress "4" "success" "DNS configuration restored."

# 5. Clean UFW firewall rules
if command -v ufw >/dev/null 2>&1; then
  ufw delete allow 53/udp 2>/dev/null || true
  ufw delete allow 53/tcp 2>/dev/null || true
  ufw delete allow 80/tcp 2>/dev/null || true
  ufw delete allow 443/tcp 2>/dev/null || true
fi

report_progress "COMPLETED" "success" "WhiteDNS Soar Server completely removed."

cat <<JSON_OUT
{
  "status": "success",
  "action": "uninstalled",
  "message": "WhiteDNS Soar Server was completely removed from the server."
}
JSON_OUT
