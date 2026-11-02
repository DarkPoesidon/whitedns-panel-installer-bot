#!/usr/bin/env bash
# ==============================================================================
# WhiteDNS Bot - Updater. Returns to the previous commit if the new one does not start.
# Runs from the terminal, or via whitedns-bot-update.path with --from-bot.
# ==============================================================================
set -Eeuo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

INSTALL_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REQUEST=/var/lib/whitedns-bot/update-request
STATUS=/var/lib/whitedns-bot-update/status
BRANCH=${BRANCH:-main}

[[ $EUID == 0 ]] || { echo '[ERROR] Run as root.' >&2; exit 1; }
cd "$INSTALL_DIR"
[[ -d .git ]] || { echo "[ERROR] $INSTALL_DIR is not a git checkout. Run deploy.sh." >&2; exit 1; }

# The request file is writable by the unprivileged bot, so only digits are accepted from it.
CHAT_ID=
if [[ -e $REQUEST || -L $REQUEST ]]; then
  # Never follow a link here: this runs as root on a path the bot user controls.
  if [[ -f $REQUEST && ! -L $REQUEST ]]; then CHAT_ID=$(head -c 32 "$REQUEST" | tr -cd '0-9-'); fi
  # Removing it re-arms the path unit, and keeps a crash here from looping.
  rm -f -- "$REQUEST"
fi

write_status() {
  install -d -m 0755 "$(dirname "$STATUS")"
  printf '%s %s %s %s\n' "$1" "$2" "${CHAT_ID:-0}" "$(date +%s)" > "$STATUS.tmp"
  chmod 0644 "$STATUS.tmp"
  mv -f -- "$STATUS.tmp" "$STATUS"
}

service_healthy() {
  systemctl restart whitedns-bot.service || return 1
  local _
  # Must stay up beyond RestartSec, or a crash loop would look active.
  for _ in 1 2 3 4; do
    sleep 5
    systemctl is-active --quiet whitedns-bot.service || return 1
  done
}

PREVIOUS=$(git rev-parse HEAD)
echo '[1/3] Fetching...'
if ! git fetch -q origin "$BRANCH"; then
  write_status failed fetch
  echo '[ERROR] git fetch failed.' >&2
  exit 1
fi
TARGET=$(git rev-parse FETCH_HEAD)
if [[ $TARGET == "$PREVIOUS" ]] && grep -q '^User=whitedns-bot' /etc/systemd/system/whitedns-bot.service 2>/dev/null; then
  write_status ok "${TARGET:0:7}"
  echo '[OK] Already up to date.'
  exit 0
fi

echo '[2/3] Installing...'
git reset -q --hard "$TARGET"
if bash scripts/bot-setup.sh; then installed=1; else installed=0; fi

echo '[3/3] Restarting...'
if (( installed )) && service_healthy; then
  write_status ok "${TARGET:0:7}"
  printf '[OK] Updated to %s.\n' "$(git log -1 --pretty=format:'%h %s')"
  exit 0
fi

echo "[ERROR] The new version did not start. Returning to ${PREVIOUS:0:7}." >&2
journalctl -u whitedns-bot -n 15 --no-pager || true
git reset -q --hard "$PREVIOUS"
bash scripts/bot-setup.sh || true
systemctl restart whitedns-bot.service || true
write_status failed "${TARGET:0:7}"
exit 1
