#!/usr/bin/env bash
# ==============================================================================
# WhiteDNS Bot - Complete Uninstaller & Purge Script for Linux VPS
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

echo -e "${RED}======================================================"
echo -e "   WhiteDNS Telegram Bot - Complete Uninstaller"
echo -e "======================================================${NC}"

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR] This script must be run as root.${NC}"
  echo -e "Please run ${YELLOW}sudo -i${NC} first, then re-run this command."
  exit 1
fi

FORCE="${1:-}"
if [[ "$FORCE" != "-y" && "$FORCE" != "--force" ]]; then
  echo -e "${YELLOW}Are you sure you want to completely uninstall the WhiteDNS Telegram Bot? (y/N)${NC}"
  read -r -p "Confirm: " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo -e "${CYAN}Uninstallation cancelled.${NC}"
    exit 0
  fi
fi

echo -e "${BLUE}[1/3] Stopping and disabling systemd service...${NC}"
if systemctl is-active --quiet whitedns-bot.service 2>/dev/null; then
  systemctl stop whitedns-bot.service || true
fi
systemctl disable whitedns-bot.service 2>/dev/null || true
rm -f /etc/systemd/system/whitedns-bot.service
systemctl daemon-reload

echo -e "${BLUE}[2/3] Removing bot files from /opt/whitedns-bot...${NC}"
rm -rf /opt/whitedns-bot

echo -e "${BLUE}[3/3] Finalizing cleanup...${NC}"

echo -e "\n${GREEN}======================================================"
echo -e "   WhiteDNS Telegram Bot has been completely uninstalled!"
echo -e "======================================================${NC}"
echo -e "All services, files, and background daemons were removed."
