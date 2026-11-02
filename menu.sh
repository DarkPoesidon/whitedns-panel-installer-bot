#!/usr/bin/env bash
# ==============================================================================
# WhiteDNS Telegram Bot - Terminal Management Menu
# ==============================================================================
set -Eeuo pipefail
export LC_ALL=C

[[ $EUID == 0 ]] || { echo '[ERROR] Run as root: sudo -i, then whitedns-bot'; exit 1; }

BOT_DIR=$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
ENV_FILE=$BOT_DIR/.env
DB=/var/lib/whitedns-bot/data.db

pause() { read -r -p 'Press Enter to return to the menu... ' _; }

set_env() {
  local key=$1 value=$2 tmp
  tmp=$(mktemp "$ENV_FILE.XXXXXX")
  grep -v "^$key=" "$ENV_FILE" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$ENV_FILE"
}

list_panels() {
  [[ -f $DB ]] || { echo 'No database yet.'; return 0; }
  DB=$DB node --no-warnings -e "
    const { DatabaseSync } = require('node:sqlite');
    const db = new DatabaseSync(process.env.DB, { readOnly: true });
    const rows = db.prepare('SELECT id, domain, vps_ip, panel_url FROM deployments ORDER BY id DESC').all();
    if (rows.length) console.table(rows); else console.log('No panels yet. Send /start to the bot.');
  " || echo 'Could not read the database.'
}

while true; do
  clear 2>/dev/null || true
  if systemctl is-active --quiet whitedns-bot.service; then STATE='ACTIVE'; else STATE='STOPPED'; fi
  cat <<MENU
======================================================
        WhiteDNS Telegram Bot - Management Menu
======================================================
 Service: $STATE | Path: $BOT_DIR
------------------------------------------------------
 1) Service status
 2) Live logs (Ctrl+C to stop)
 3) Restart bot
 4) Stop bot
 5) Start bot
------------------------------------------------------
 6) List deployed panels
 7) Update bot
 8) Change Telegram token
 9) Set admin chat ids (allowed to use /update)
10) Uninstall bot
------------------------------------------------------
 0) Exit
======================================================
MENU
  read -r -p 'Select an option: ' choice
  case "$choice" in
    1) systemctl status whitedns-bot.service --no-pager || true; pause ;;
    2) journalctl -u whitedns-bot.service -f -n 50 || true ;;
    3) systemctl restart whitedns-bot.service; sleep 2; systemctl is-active whitedns-bot.service || true; pause ;;
    4) systemctl stop whitedns-bot.service ;;
    5) systemctl start whitedns-bot.service; sleep 2; systemctl is-active whitedns-bot.service || true; pause ;;
    6) list_panels; pause ;;
    7) bash "$BOT_DIR/update.sh" || true; pause ;;
    8)
      read -r -p 'New token from @BotFather (empty to cancel): ' token
      token=${token//[ \"]/}
      if [[ $token =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
        set_env BOT_TOKEN "$token"
        systemctl restart whitedns-bot.service
        echo '[OK] Token updated.'
      else
        echo 'No change made.'
      fi
      pause
      ;;
    9)
      read -r -p 'Comma separated chat ids (send /id to the bot to see yours): ' ids
      if [[ $ids =~ ^-?[0-9]+(,-?[0-9]+)*$ ]]; then
        set_env ADMIN_CHAT_IDS "$ids"
        systemctl restart whitedns-bot.service
        echo '[OK] Admins updated.'
      else
        echo 'No change made.'
      fi
      pause
      ;;
    10) bash "$BOT_DIR/uninstall.sh"; exit 0 ;;
    0) exit 0 ;;
    *) echo 'Invalid option.'; sleep 1 ;;
  esac
done
