#!/usr/bin/env bash
# ==============================================================================
# WhiteDNS Bot - 1-Line Updater for Linux VPS
# ==============================================================================
set -Eeuo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}======================================================"
echo -e "   WhiteDNS Telegram Bot - Auto Updater"
echo -e "======================================================${NC}"

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR] This script must be run as root.${NC}"
  echo -e "Please run ${YELLOW}sudo -i${NC} first, then re-run this command."
  exit 1
fi

INSTALL_DIR="/opt/whitedns-bot"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "$INSTALL_DIR/.git" ]]; then
  TARGET_DIR="$INSTALL_DIR"
elif [[ -d "$SCRIPT_DIR/.git" ]]; then
  TARGET_DIR="$SCRIPT_DIR"
else
  echo -e "${RED}[ERROR] Bot directory with Git repository not found.${NC}"
  exit 1
fi

cd "$TARGET_DIR"

echo -e "${BLUE}[1/3] Fetching latest updates from GitHub...${NC}"
git fetch --all
git reset --hard origin/main

echo -e "${BLUE}[2/3] Updating npm packages...${NC}"
npm install --omit=dev

# Make all scripts executable and link global CLI shortcuts
chmod +x "$TARGET_DIR/scripts/install-soar.sh" "$TARGET_DIR/scripts/uninstall-soar.sh" 2>/dev/null || true
chmod +x "$TARGET_DIR/menu.sh" "$TARGET_DIR/update.sh" "$TARGET_DIR/uninstall.sh" 2>/dev/null || true

ln -sf "$TARGET_DIR/menu.sh" /usr/local/bin/whitedns-bot
ln -sf "$TARGET_DIR/menu.sh" /usr/local/bin/bot
ln -sf "$TARGET_DIR/menu.sh" /usr/bin/whitedns-bot
ln -sf "$TARGET_DIR/menu.sh" /usr/bin/bot

echo -e "${BLUE}[3/3] Restarting systemd service (whitedns-bot.service)...${NC}"
systemctl daemon-reload
systemctl restart whitedns-bot.service

sleep 2
if systemctl is-active --quiet whitedns-bot.service; then
  echo -e "\n${GREEN}======================================================"
  echo -e "   WhiteDNS Bot successfully updated to latest version!"
  echo -e "======================================================${NC}"
  echo -e "Service Status: ${GREEN}Active (Running)${NC}"
  echo -e "Commit: $(git log -1 --pretty=format:'%h - %s (%cd)')"
  echo -e "\nLogs: ${YELLOW}journalctl -u whitedns-bot -f${NC}"
else
  echo -e "${RED}[ERROR] Service failed to restart. Review logs below:${NC}"
  journalctl -u whitedns-bot -n 20 --no-pager
  exit 1
fi
