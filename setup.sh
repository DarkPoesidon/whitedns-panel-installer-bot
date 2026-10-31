#!/usr/bin/env bash
# ==============================================================================
# WhiteDNS Soar Server - Telegram Bot VPS Setup & Service Installer
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
echo -e "   WhiteDNS Autonomous Telegram Bot Installer"
echo -e "======================================================${NC}"

# 1. Root Check
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR] This script must be run as root.${NC}"
  echo -e "Please run ${YELLOW}sudo -i${NC} first, then re-run this command."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOT_DIR="${1:-$SCRIPT_DIR}"

# 2. Install Node.js 20+ and build tools if not present
NEED_NODE=0
if ! command -v node >/dev/null 2>&1; then
  NEED_NODE=1
else
  NODE_VER=$(node -v | sed 's/v//' | cut -d. -f1)
  if (( NODE_VER < 20 )); then
    NEED_NODE=1
  fi
fi

if (( NEED_NODE )); then
  echo -e "${BLUE}[1/4] Installing Node.js 20 LTS and build tools...${NC}"
  apt-get update -y
  apt-get install -y curl build-essential ca-certificates
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
  echo -e "${GREEN}[OK] Node.js $(node -v) successfully installed.${NC}"
else
  echo -e "${GREEN}[OK] Node.js $(node -v) is ready.${NC}"
fi

# 3. Check and configure BOT_TOKEN
ENV_FILE="$BOT_DIR/.env"
BOT_TOKEN="${BOT_TOKEN:-}"

if [[ -f "$ENV_FILE" ]]; then
  EXISTING_TOKEN=$(grep -E '^BOT_TOKEN=' "$ENV_FILE" | cut -d= -f2- | tr -d ' "' || true)
  if [[ -n "$EXISTING_TOKEN" ]]; then
    BOT_TOKEN="$EXISTING_TOKEN"
  fi
fi

if [[ -z "$BOT_TOKEN" ]]; then
  echo -e "\n${YELLOW}[INPUT] Telegram Bot Token configuration:${NC}"
  echo -e "Enter the BOT_TOKEN received from ${CYAN}@BotFather${NC}:"
  read -r -p "BOT_TOKEN: " INPUT_TOKEN
  BOT_TOKEN=$(echo "$INPUT_TOKEN" | tr -d ' "')
fi

if [[ -z "$BOT_TOKEN" || "$BOT_TOKEN" != *:* ]]; then
  echo -e "${RED}[ERROR] Invalid token format. Expected: 123456789:ABCdefGhIjk...${NC}"
  exit 1
fi

cat > "$ENV_FILE" <<EOF
BOT_TOKEN=${BOT_TOKEN}
NODE_ENV=production
EOF
chmod 600 "$ENV_FILE"
echo -e "${GREEN}[OK] File .env created.${NC}"

# 4. Install Node Dependencies
echo -e "${BLUE}[2/4] Installing dependencies (npm install)...${NC}"
cd "$BOT_DIR"
npm install --omit=dev

# 5. Make scripts executable and create menu symlinks
chmod +x "$BOT_DIR/scripts/install-soar.sh" "$BOT_DIR/scripts/uninstall-soar.sh" 2>/dev/null || true
chmod +x "$BOT_DIR/menu.sh" "$BOT_DIR/update.sh" "$BOT_DIR/uninstall.sh" 2>/dev/null || true
ln -sf "$BOT_DIR/menu.sh" /usr/local/bin/whitedns-bot
ln -sf "$BOT_DIR/menu.sh" /usr/local/bin/bot
ln -sf "$BOT_DIR/menu.sh" /usr/bin/whitedns-bot
ln -sf "$BOT_DIR/menu.sh" /usr/bin/bot

# 6. Create systemd service
SERVICE_FILE="/etc/systemd/system/whitedns-bot.service"
echo -e "${BLUE}[3/4] Creating systemd service (whitedns-bot.service)...${NC}"

NODE_BIN=$(command -v node)

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=WhiteDNS Autonomous Telegram Bot
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${BOT_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${NODE_BIN} src/bot.js
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now whitedns-bot.service

# 7. Verify service status
sleep 2
if systemctl is-active --quiet whitedns-bot.service; then
  echo -e "\n${GREEN}======================================================"
  echo -e "   WhiteDNS Bot successfully installed and active!"
  echo -e "======================================================${NC}"
  echo -e "Service Status: ${GREEN}Active (Running)${NC}"
  echo -e "\n${BOLD}Terminal Management Menu:${NC}"
  echo -e "  Type ${CYAN}whitedns-bot${NC} or ${CYAN}bot${NC} anytime to open the management dashboard!"
  echo -e "\nNow open Telegram and send ${CYAN}/start${NC} to your bot."
  echo -e "\nUseful server commands:"
  echo -e "  Open Menu:        ${YELLOW}whitedns-bot${NC} (or ${YELLOW}bot${NC})"
  echo -e "  View live logs:   ${YELLOW}journalctl -u whitedns-bot -f${NC}"
  echo -e "  Restart service:  ${YELLOW}systemctl restart whitedns-bot${NC}"
  echo -e "  Service status:   ${YELLOW}systemctl status whitedns-bot${NC}"
  echo -e "  Stop service:     ${YELLOW}systemctl stop whitedns-bot${NC}"
else
  echo -e "${RED}[ERROR] Service failed to start. Review logs below:${NC}"
  journalctl -u whitedns-bot -n 20 --no-pager
  exit 1
fi
