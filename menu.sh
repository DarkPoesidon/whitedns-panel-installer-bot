#!/usr/bin/env bash
# ==============================================================================
# WhiteDNS Telegram Bot - Interactive Terminal Management Menu
# ==============================================================================
set -Eeuo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR] This menu must be run as root.${NC}"
  echo -e "Please run ${YELLOW}sudo -i${NC} first, then re-run ${CYAN}whitedns-bot${NC}."
  exit 1
fi

INSTALL_DIR="/opt/whitedns-bot"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "$INSTALL_DIR" ]]; then
  BOT_DIR="$INSTALL_DIR"
elif [[ -d "$SCRIPT_DIR" && -f "$SCRIPT_DIR/src/bot.js" ]]; then
  BOT_DIR="$SCRIPT_DIR"
else
  echo -e "${RED}[ERROR] WhiteDNS Bot directory not found at $INSTALL_DIR.${NC}"
  exit 1
fi

cd "$BOT_DIR"

# Self-heal global CLI shortcuts if missing
ln -sf "$BOT_DIR/menu.sh" /usr/local/bin/whitedns-bot 2>/dev/null || true
ln -sf "$BOT_DIR/menu.sh" /usr/local/bin/bot 2>/dev/null || true
ln -sf "$BOT_DIR/menu.sh" /usr/bin/whitedns-bot 2>/dev/null || true
ln -sf "$BOT_DIR/menu.sh" /usr/bin/bot 2>/dev/null || true
chmod +x "$BOT_DIR/menu.sh" 2>/dev/null || true

while true; do
  clear 2>/dev/null || true
  STATUS="UNKNOWN"
  STATUS_COLOR="$RED"
  if systemctl is-active --quiet whitedns-bot.service 2>/dev/null; then
    STATUS="ACTIVE (RUNNING)"
    STATUS_COLOR="$GREEN"
  else
    STATUS="STOPPED"
    STATUS_COLOR="$RED"
  fi

  echo -e "${CYAN}======================================================${NC}"
  echo -e "${BOLD}       WhiteDNS Telegram Bot - Management Menu        ${NC}"
  echo -e "${CYAN}======================================================${NC}"
  echo -e " Service: ${STATUS_COLOR}${STATUS}${NC} | Path: ${YELLOW}${BOT_DIR}${NC}"
  echo -e "${CYAN}------------------------------------------------------${NC}"
  echo -e " ${GREEN}1)${NC} Service Status           (systemctl status)"
  echo -e " ${GREEN}2)${NC} View Live Logs           (journalctl -u whitedns-bot -f)"
  echo -e " ${GREEN}3)${NC} Restart Bot Service      (systemctl restart)"
  echo -e " ${GREEN}4)${NC} Stop Bot Service         (systemctl stop)"
  echo -e " ${GREEN}5)${NC} Start Bot Service        (systemctl start)"
  echo -e " ${CYAN}------------------------------------------------------${NC}"
  echo -e " ${GREEN}6)${NC} View Deployed Panels     (List active servers & URLs)"
  echo -e " ${GREEN}7)${NC} Update Bot to Latest     (git pull & update)"
  echo -e " ${GREEN}8)${NC} Change Telegram Token    (Edit BOT_TOKEN in .env)"
  echo -e " ${GREEN}9)${NC} Completely Uninstall     (Purge bot and systemd unit)"
  echo -e " ${CYAN}------------------------------------------------------${NC}"
  echo -e " ${YELLOW}0) Exit Menu${NC}"
  echo -e "${CYAN}======================================================${NC}"
  read -r -p "Select an option [0-9]: " CHOICE

  case "$CHOICE" in
    1)
      echo -e "\n${BLUE}--- WhiteDNS Bot Service Status ---${NC}"
      systemctl status whitedns-bot.service --no-pager || true
      echo -e "\n${YELLOW}Press Enter to return to menu...${NC}"
      read -r
      ;;
    2)
      echo -e "\n${BLUE}--- Live Logs (Press Ctrl+C to stop) ---${NC}"
      journalctl -u whitedns-bot.service -f -n 50 || true
      ;;
    3)
      echo -e "\n${BLUE}Restarting whitedns-bot.service...${NC}"
      systemctl restart whitedns-bot.service
      sleep 2
      if systemctl is-active --quiet whitedns-bot.service; then
        echo -e "${GREEN}[OK] Service successfully restarted!${NC}"
      else
        echo -e "${RED}[ERROR] Service failed to restart.${NC}"
      fi
      echo -e "\n${YELLOW}Press Enter to return to menu...${NC}"
      read -r
      ;;
    4)
      echo -e "\n${BLUE}Stopping whitedns-bot.service...${NC}"
      systemctl stop whitedns-bot.service
      echo -e "${YELLOW}[OK] Service stopped.${NC}"
      sleep 1
      ;;
    5)
      echo -e "\n${BLUE}Starting whitedns-bot.service...${NC}"
      systemctl start whitedns-bot.service
      sleep 2
      if systemctl is-active --quiet whitedns-bot.service; then
        echo -e "${GREEN}[OK] Service is now active and running!${NC}"
      else
        echo -e "${RED}[ERROR] Failed to start service.${NC}"
      fi
      sleep 1
      ;;
    6)
      echo -e "\n${BLUE}--- Registered WhiteDNS Deployments ---${NC}"
      if [[ -f "$BOT_DIR/data.db" ]]; then
        node --input-type=module -e "
          import Database from 'better-sqlite3';
          try {
            const db = new Database('$BOT_DIR/data.db');
            const rows = db.prepare('SELECT id, domain, vps_ip, panel_url, status FROM deployments ORDER BY id DESC').all();
            if (rows.length === 0) {
              console.log('No deployments found yet. Run /start in Telegram to install a panel.');
            } else {
              console.table(rows);
            }
          } catch(e) {
            console.log('Could not read database:', e.message);
          }
        " || true
      else
        echo -e "${YELLOW}No database file found yet.${NC}"
      fi
      echo -e "\n${YELLOW}Press Enter to return to menu...${NC}"
      read -r
      ;;
    7)
      echo -e "\n${BLUE}Updating WhiteDNS Bot from GitHub...${NC}"
      if [[ -f "$BOT_DIR/update.sh" ]]; then
        bash "$BOT_DIR/update.sh"
      else
        bash <(curl -fsSL https://raw.githubusercontent.com/DarkPoesidon/whitedns-panel-installer-bot/main/update.sh)
      fi
      echo -e "\n${YELLOW}Press Enter to return to menu...${NC}"
      read -r
      ;;
    8)
      ENV_FILE="$BOT_DIR/.env"
      CURRENT_TOKEN=""
      if [[ -f "$ENV_FILE" ]]; then
        CURRENT_TOKEN=$(grep -E '^BOT_TOKEN=' "$ENV_FILE" | cut -d= -f2- || true)
      fi
      echo -e "\nCurrent BOT_TOKEN: ${YELLOW}$CURRENT_TOKEN${NC}"
      echo -e "Enter new BOT_TOKEN from @BotFather (or press Enter to cancel):"
      read -r -p "New Token: " NEW_TOKEN
      NEW_TOKEN=$(echo "$NEW_TOKEN" | tr -d ' "')
      if [[ -n "$NEW_TOKEN" && "$NEW_TOKEN" == *:* ]]; then
        cat > "$ENV_FILE" <<EOF
BOT_TOKEN=${NEW_TOKEN}
NODE_ENV=production
EOF
        chmod 600 "$ENV_FILE"
        systemctl restart whitedns-bot.service
        echo -e "${GREEN}[OK] BOT_TOKEN updated and bot restarted!${NC}"
      else
        echo -e "${YELLOW}No change made.${NC}"
      fi
      sleep 2
      ;;
    9)
      echo -e "\n${RED}--- Completely Uninstall Bot ---${NC}"
      if [[ -f "$BOT_DIR/uninstall.sh" ]]; then
        bash "$BOT_DIR/uninstall.sh"
      else
        bash <(curl -fsSL https://raw.githubusercontent.com/DarkPoesidon/whitedns-panel-installer-bot/main/uninstall.sh)
      fi
      exit 0
      ;;
    0)
      echo -e "\n${GREEN}Exiting. Good bye!${NC}"
      exit 0
      ;;
    *)
      echo -e "\n${RED}Invalid option. Please try again.${NC}"
      sleep 1
      ;;
  esac
done
