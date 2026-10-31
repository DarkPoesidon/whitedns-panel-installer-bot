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
echo -e "   🤖 WhiteDNS Autonomous Telegram Bot Installer"
echo -e "======================================================${NC}"

# 1. Root Check
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}❌ این اسکریپت باید با دسترسی root اجرا شود.${NC}"
  echo -e "لطفاً با دستور ${YELLOW}sudo -i${NC} وارد root شده و مجدداً اجرا فرمایید."
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
  echo -e "${BLUE}📦 در حال نصب Node.js 20 LTS و ابزارهای کامپایل...${NC}"
  apt-get update -y
  apt-get install -y curl build-essential ca-certificates
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
  echo -e "${GREEN}✅ Node.js $(node -v) با موفقیت نصب شد.${NC}"
else
  echo -e "${GREEN}✅ نسخه فعلی Node.js: $(node -v)${NC}"
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
  echo -e "\n${YELLOW}🔑 ورود توکن ربات تلگرام:${NC}"
  echo -e "توکنی که از ${CYAN}@BotFather${NC} در تلگرام دریافت کرده‌اید را وارد کنید:"
  read -r -p "BOT_TOKEN: " INPUT_TOKEN
  BOT_TOKEN=$(echo "$INPUT_TOKEN" | tr -d ' "')
fi

if [[ -z "$BOT_TOKEN" || "$BOT_TOKEN" != *:* ]]; then
  echo -e "${RED}❌ توکن نامعتبر است. فرمت توکن باید مانند 123456789:ABCdefGhIjk... باشد.${NC}"
  exit 1
fi

cat > "$ENV_FILE" <<EOF
BOT_TOKEN=${BOT_TOKEN}
NODE_ENV=production
EOF
chmod 600 "$ENV_FILE"
echo -e "${GREEN}✅ فایل .env با موفقیت ایجاد شد.${NC}"

# 4. Install Node Dependencies
echo -e "${BLUE}📦 در حال نصب کتابخانه‌های ربات (npm install)...${NC}"
cd "$BOT_DIR"
npm install --omit=dev

# 5. Make script executable
chmod +x "$BOT_DIR/scripts/install-soar.sh"

# 6. Create systemd service
SERVICE_FILE="/etc/systemd/system/whitedns-bot.service"
echo -e "${BLUE}⚙️ در حال ساخت سرویس خودکار پایدار (systemd)...${NC}"

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
  echo -e "   🎉 ربات WhiteDNS با موفقیت روی سرور فعال شد!"
  echo -e "======================================================${NC}"
  echo -e "🤖 وضعیت سرویس: ${GREEN}Active (Running)${NC}"
  echo -e "\n📱 اکنون به تلگرام بروید و دستور ${CYAN}/start${NC} را برای ربات خود ارسال کنید."
  echo -e "\n🛠 دستورات کاربردی مدیریت ربات در سرور:"
  echo -e "• مشاهده لاگ‌های زنده:   ${YELLOW}journalctl -u whitedns-bot -f${NC}"
  echo -e "• ریستارت ربات:           ${YELLOW}systemctl restart whitedns-bot${NC}"
  echo -e "• بررسی وضعیت:            ${YELLOW}systemctl status whitedns-bot${NC}"
  echo -e "• توقف ربات:              ${YELLOW}systemctl stop whitedns-bot${NC}"
else
  echo -e "${RED}⚠️ سرویس اجرا نشد. لطفاً لاگ‌ها را بررسی کنید:${NC}"
  journalctl -u whitedns-bot -n 20 --no-pager
  exit 1
fi
