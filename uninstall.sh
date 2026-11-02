#!/usr/bin/env bash
# ==============================================================================
# WhiteDNS Bot - Uninstaller. Removes the bot from this machine.
# Panels the bot installed on other servers are not touched.
# Usage: uninstall.sh [-y]   -y also deletes the bot database.
# ==============================================================================
set -Eeuo pipefail
export LC_ALL=C

[[ $EUID == 0 ]] || { echo '[ERROR] Run as root.' >&2; exit 1; }

INSTALL_DIR=/opt/whitedns-bot
DATA_DIR=/var/lib/whitedns-bot
ASSUME_YES=${1:-}

if [[ $ASSUME_YES != -y && $ASSUME_YES != --force ]]; then
  read -r -p 'Remove the WhiteDNS Telegram Bot from this machine? (y/N): ' answer
  [[ $answer == y || $answer == Y ]] || { echo 'Cancelled.'; exit 0; }
fi

echo '[1/3] Removing services...'
systemctl disable --now whitedns-bot.service whitedns-bot-update.path 2>/dev/null || true
rm -f /etc/systemd/system/whitedns-bot.service /etc/systemd/system/whitedns-bot-update.path /etc/systemd/system/whitedns-bot-update.service
systemctl daemon-reload

echo '[2/3] Removing files...'
rm -f /usr/local/bin/whitedns-bot /usr/local/bin/bot /usr/bin/whitedns-bot /usr/bin/bot
rm -rf -- "$INSTALL_DIR" /var/lib/whitedns-bot-update

echo '[3/3] Bot database...'
remove_data=n
if [[ $ASSUME_YES == -y || $ASSUME_YES == --force ]]; then remove_data=y
elif [[ -d $DATA_DIR ]]; then read -r -p "Also delete $DATA_DIR (list of your panels)? (y/N): " remove_data; fi
if [[ $remove_data == y || $remove_data == Y ]]; then
  rm -rf -- "$DATA_DIR"
  userdel whitedns-bot 2>/dev/null || true
else
  echo "Kept $DATA_DIR."
fi
echo '[OK] Bot removed.'
