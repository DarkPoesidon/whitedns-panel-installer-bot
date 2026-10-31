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
echo -e "   🚀 WhiteDNS Soar Server - Telegram Bot Installer"
echo -e "======================================================${NC}"

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}❌ این اسکریپت باید با دسترسی root اجرا شود.${NC}"
  echo -e "دستور ${YELLOW}sudo -i${NC} را اجرا کرده و سپس مجدداً تلاش کنید."
  exit 1
fi

INSTALL_DIR="/opt/whitedns-bot"
REPO_URL="https://github.com/DarkPoesidon/whitedns-panel-installer-bot.git"

# 1. Install prerequisites (curl, git, build-essential)
echo -e "${BLUE}📦 در حال بررسی و نصب پیش‌نیازهای سیستم...${NC}"
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
  echo -e "${BLUE}📦 در حال نصب Node.js 20 LTS...${NC}"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
echo -e "${GREEN}✅ Node.js $(node -v) آماده است.${NC}"

# 3. Clone or update repository
if [[ -d "$INSTALL_DIR/.git" ]]; then
  echo -e "${BLUE}🔄 در حال به‌روزرسانی کد پروژه از گیت‌هاب...${NC}"
  cd "$INSTALL_DIR"
  git fetch --all
  git reset --hard origin/main || git reset --hard origin/master
else
  echo -e "${BLUE}📥 در حال دانلود پروژه از گیت‌هاب...${NC}"
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
  echo -e "\n${YELLOW}🔑 ورود توکن ربات تلگرام:${NC}"
  echo -e "توکن دریافتی از ${CYAN}@BotFather${NC} در تلگرام را وارد کنید:"
  read -r -p "BOT_TOKEN: " INPUT_TOKEN
  BOT_TOKEN=$(echo "$INPUT_TOKEN" | tr -d ' "')
fi

if [[ -z "$BOT_TOKEN" || "$BOT_TOKEN" != *:* ]]; then
  echo -e "${RED}❌ فرمت توکن نامعتبر است (مثال: 123456789:ABCdefGhIjk...)${NC}"
  exit 1
fi

cat > "$ENV_FILE" <<EOF
BOT_TOKEN=${BOT_TOKEN}
NODE_ENV=production
EOF
chmod 600 "$ENV_FILE"

# 5. Install dependencies
echo -e "${BLUE}📦 در حال نصب وابستگی‌ها (npm install)...${NC}"
npm install --omit=dev

chmod +x "$INSTALL_DIR/scripts/install-soar.sh"

# 6. Setup and start systemd service
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
  echo -e "   🎉 ربات WhiteDNS با موفقیت روی سرور نصب و فعال شد!"
  echo -e "======================================================${NC}"
  echo -e "🤖 وضعیت سرویس: ${GREEN}Active (Running)${NC}"
  echo -e "\n📱 اکنون به تلگرام بروید و دستور ${CYAN}/start${NC} را برای ربات ارسال نمایید."
  echo -e "\n🛠 دستورات کاربردی مدیریت سرور:"
  echo -e "• مشاهده لاگ‌های زنده:   ${YELLOW}journalctl -u whitedns-bot -f${NC}"
  echo -e "• ریستارت ربات:           ${YELLOW}systemctl restart whitedns-bot${NC}"
  echo -e "• وضعیت سرویس:            ${YELLOW}systemctl status whitedns-bot${NC}"
  echo -e "• توقف ربات:              ${YELLOW}systemctl stop whitedns-bot${NC}"
else
  echo -e "${RED}⚠️ سرویس اجرا نشد. لاگ‌ها را بررسی کنید:${NC}"
  journalctl -u whitedns-bot -n 20 --no-pager
  exit 1
fi
