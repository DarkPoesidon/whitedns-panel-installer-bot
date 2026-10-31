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
REPO_URL="https://github.com/DarkPoesidon/whitedns-panel-installer-bot.git"

if [[ -d "$INSTALL_DIR" ]]; then
  TARGET_DIR="$INSTALL_DIR"
elif [[ -d "$SCRIPT_DIR" && -f "$SCRIPT_DIR/package.json" ]]; then
  TARGET_DIR="$SCRIPT_DIR"
else
  echo -e "${RED}[ERROR] Bot directory (/opt/whitedns-bot) not found.${NC}"
  echo -e "Please deploy the bot first using:"
  echo -e "${YELLOW}bash <(curl -fsSL https://raw.githubusercontent.com/DarkPoesidon/whitedns-panel-installer-bot/main/deploy.sh)${NC}"
  exit 1
fi

cd "$TARGET_DIR"

# Ensure git is installed
if ! command -v git &>/dev/null; then
  echo -e "${BLUE}[INFO] Installing git...${NC}"
  apt-get update -qq && apt-get install -y -qq git
fi

# Ensure git safe directory is configured
git config --global --add safe.directory "$TARGET_DIR" 2>/dev/null || true

# If .git directory does not exist, initialize it
if [[ ! -d "$TARGET_DIR/.git" ]]; then
  echo -e "${YELLOW}[INFO] Initializing git repository in $TARGET_DIR...${NC}"
  git init -b main 2>/dev/null || git init
  git remote add origin "$REPO_URL" 2>/dev/null || true
fi

# Ensure remote origin is configured
git remote set-url origin "$REPO_URL" 2>/dev/null || git remote add origin "$REPO_URL" 2>/dev/null || true

echo -e "${BLUE}[1/3] Fetching latest updates from GitHub...${NC}"
git fetch --all --prune
git reset --hard origin/main

echo -e "${BLUE}[2/3] Updating npm packages...${NC}"
npm install --omit=dev

# Make all scripts executable and link global CLI shortcuts
chmod +x "$TARGET_DIR/scripts/install-soar.sh" "$TARGET_DIR/scripts/uninstall-soar.sh" "$TARGET_DIR/scripts/repair-soar.sh" 2>/dev/null || true
chmod +x "$TARGET_DIR/menu.sh" "$TARGET_DIR/update.sh" "$TARGET_DIR/uninstall.sh" 2>/dev/null || true

cat > /usr/bin/whitedns-bot <<'EOF_BIN'
#!/usr/bin/env bash
if [[ -f /opt/whitedns-bot/menu.sh ]]; then
  exec bash /opt/whitedns-bot/menu.sh "$@"
else
  exec bash <(curl -fsSL https://raw.githubusercontent.com/DarkPoesidon/whitedns-panel-installer-bot/main/menu.sh) "$@"
fi
EOF_BIN
chmod +x /usr/bin/whitedns-bot
cp -f /usr/bin/whitedns-bot /usr/bin/bot
mkdir -p /usr/local/bin
cp -f /usr/bin/whitedns-bot /usr/local/bin/whitedns-bot
cp -f /usr/bin/whitedns-bot /usr/local/bin/bot
hash -r 2>/dev/null || true

echo -e "${BLUE}[3/3] Restarting systemd service (whitedns-bot.service)...${NC}"
systemctl daemon-reload
systemctl restart whitedns-bot.service 2>/dev/null || systemctl restart whitedns-bot 2>/dev/null || true

sleep 2
if systemctl is-active --quiet whitedns-bot.service || systemctl is-active --quiet whitedns-bot; then
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
