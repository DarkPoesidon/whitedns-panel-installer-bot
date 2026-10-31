#!/usr/bin/env bash
# ==============================================================================
# WhiteDNS Soar Panel Telegram Bot - 1-Line Autonomous Installer
# Repository: https://github.com/DarkPoesidon/whitedns-panel-installer-bot
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
echo -e "   WhiteDNS Soar Server - Telegram Bot Installer"
echo -e "======================================================${NC}"

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR] This script must be run as root.${NC}"
  echo -e "Please run ${YELLOW}sudo -i${NC} first, then re-run this command."
  exit 1
fi

INSTALL_DIR="/opt/whitedns-bot"
REPO_URL="https://github.com/DarkPoesidon/whitedns-panel-installer-bot.git"

# Handle CLI flags
if [[ "${1:-}" == "--update" || "${1:-}" == "update" ]]; then
  if [[ -f "$INSTALL_DIR/update.sh" ]]; then
    exec bash "$INSTALL_DIR/update.sh"
  else
    exec bash <(curl -fsSL https://raw.githubusercontent.com/DarkPoesidon/whitedns-panel-installer-bot/main/update.sh)
  fi
fi

if [[ "${1:-}" == "--uninstall" || "${1:-}" == "uninstall" ]]; then
  if [[ -f "$INSTALL_DIR/uninstall.sh" ]]; then
    exec bash "$INSTALL_DIR/uninstall.sh" "${2:-}"
  else
    exec bash <(curl -fsSL https://raw.githubusercontent.com/DarkPoesidon/whitedns-panel-installer-bot/main/uninstall.sh) "${2:-}"
  fi
fi

# 1. Install prerequisites (curl, git, build-essential)
echo -e "${BLUE}[1/5] Checking and installing system packages (curl, git, build-essential)...${NC}"
apt-get update -y
apt-get install -y curl git build-essential ca-certificates

# 2. Install Node.js 20+
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
  echo -e "${BLUE}[2/5] Installing Node.js 20 LTS from NodeSource...${NC}"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
echo -e "${GREEN}[OK] Node.js $(node -v) is ready.${NC}"

# 3. Clone or update repository
if [[ -d "$INSTALL_DIR/.git" ]]; then
  echo -e "${BLUE}[3/5] Updating repository from GitHub...${NC}"
  cd "$INSTALL_DIR"
  git fetch --all
  git reset --hard origin/main || git reset --hard origin/master
else
  echo -e "${BLUE}[3/5] Cloning repository into $INSTALL_DIR...${NC}"
  rm -rf "$INSTALL_DIR"
  git clone "$REPO_URL" "$INSTALL_DIR"
  cd "$INSTALL_DIR"
fi

# 4. Configure BOT_TOKEN
ENV_FILE="$INSTALL_DIR/.env"
BOT_TOKEN="${1:-}"

if [[ -z "$BOT_TOKEN" && -f "$ENV_FILE" ]]; then
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
echo -e "${GREEN}[OK] Environment file (.env) configured.${NC}"

# 5. Install dependencies
echo -e "${BLUE}[4/5] Installing npm dependencies (npm install)...${NC}"
npm install --omit=dev

chmod +x "$INSTALL_DIR/scripts/install-soar.sh"

# 6. Setup and start systemd service
echo -e "${BLUE}[5/5] Setting up systemd service (whitedns-bot.service)...${NC}"
SERVICE_FILE="/etc/systemd/system/whitedns-bot.service"
NODE_BIN=$(command -v node)

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=WhiteDNS Autonomous Telegram Bot
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
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

sleep 2
if systemctl is-active --quiet whitedns-bot.service; then
  echo -e "\n${GREEN}======================================================"
  echo -e "   WhiteDNS Bot successfully installed and active!"
  echo -e "======================================================${NC}"
  echo -e "Service Status: ${GREEN}Active (Running)${NC}"
  echo -e "\nNow open Telegram and send ${CYAN}/start${NC} to your bot."
  echo -e "\nUseful server commands:"
  echo -e "  View live logs:   ${YELLOW}journalctl -u whitedns-bot -f${NC}"
  echo -e "  Restart service:  ${YELLOW}systemctl restart whitedns-bot${NC}"
  echo -e "  Service status:   ${YELLOW}systemctl status whitedns-bot${NC}"
  echo -e "  Stop service:     ${YELLOW}systemctl stop whitedns-bot${NC}"
else
  echo -e "${RED}[ERROR] Service failed to start. Review logs below:${NC}"
  journalctl -u whitedns-bot -n 20 --no-pager
  exit 1
fi
