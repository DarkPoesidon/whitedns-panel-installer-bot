#!/usr/bin/env bash
# ==============================================================================
# WhiteDNS Soar Panel Telegram Bot - 1-Line Installer
# Repository: https://github.com/DarkPoesidon/whitedns-panel-installer-bot
#
# Usage: deploy.sh [BOT_TOKEN] | --update | --uninstall
# Re-running is safe: settings, data and existing deployments are kept.
# ==============================================================================
set -Eeuo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

INSTALL_DIR=${INSTALL_DIR:-/opt/whitedns-bot}
REPO_URL=${REPO_URL:-https://github.com/DarkPoesidon/whitedns-panel-installer-bot.git}
BRANCH=${BRANCH:-main}

fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

[[ $EUID == 0 ]] || fail 'Run as root: sudo -i, then run this command again.'

case "${1:-}" in
  --update|update)
    [[ -f $INSTALL_DIR/update.sh ]] || fail "No installation found in $INSTALL_DIR."
    exec bash "$INSTALL_DIR/update.sh"
    ;;
  --uninstall|uninstall)
    [[ -f $INSTALL_DIR/uninstall.sh ]] || fail "No installation found in $INSTALL_DIR."
    exec bash "$INSTALL_DIR/uninstall.sh" "${2:-}"
    ;;
esac

[[ -d /run/systemd/system ]] || fail 'A running systemd is required.'

echo '[1/5] Installing system packages...'
apt-get -o DPkg::Lock::Timeout=300 update -y
apt-get -o DPkg::Lock::Timeout=300 install -y curl git ca-certificates

# Everything that can be refused is checked here, while the running bot is still untouched.
echo '[2/5] Checking settings...'
ENV_FILE=$INSTALL_DIR/.env
read_env() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d ' "' || true; }
BOT_TOKEN=${1:-$(read_env BOT_TOKEN)}
ADMIN_CHAT_IDS=${ADMIN_CHAT_IDS:-$(read_env ADMIN_CHAT_IDS)}
if [[ -z $BOT_TOKEN && -t 0 ]]; then
  read -r -p 'BOT_TOKEN from @BotFather: ' BOT_TOKEN
  BOT_TOKEN=${BOT_TOKEN//[ \"]/}
fi
[[ $BOT_TOKEN =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || fail 'Invalid token. Expected 123456789:ABCdefGhIjk...'
if [[ -z $ADMIN_CHAT_IDS && -t 0 ]]; then
  echo 'Your Telegram chat id allows /update from Telegram. Leave empty to set it later; /id in the bot shows it.'
  read -r -p 'ADMIN_CHAT_IDS: ' ADMIN_CHAT_IDS
fi
[[ -z $ADMIN_CHAT_IDS || $ADMIN_CHAT_IDS =~ ^-?[0-9]+(,-?[0-9]+)*$ ]] || fail 'ADMIN_CHAT_IDS must be comma separated numbers.'
API_ROOT=$(read_env TELEGRAM_API_ROOT)
# Sent through curl's stdin so the token stays out of the process list. Only an explicit refusal stops
# the deploy: a network failure here may simply mean Telegram is blocked for this check.
TOKEN_CHECK=$(printf 'url = "%s/bot%s/getMe"\n' "${API_ROOT:-https://api.telegram.org}" "$BOT_TOKEN" | curl -s -o /dev/null -w '%{http_code}' --max-time 15 -K - || true)
[[ $TOKEN_CHECK != 401 && $TOKEN_CHECK != 404 ]] || fail 'Telegram rejected this BOT_TOKEN. Nothing was changed.'

# The old process loads scripts from disk when it runs, so it must not outlive the file swap.
# A bot started by hand is outside the unit and would also fight the new one for updates.
echo '[3/5] Stopping the running bot...'
systemctl stop whitedns-bot.service 2>/dev/null || true
for pid in $(pgrep -f 'src/bot\.js' || true); do
  if [[ $(readlink "/proc/$pid/cwd" 2>/dev/null) == "$INSTALL_DIR" ]]; then kill "$pid" 2>/dev/null || true; fi
done

echo '[4/5] Fetching the bot...'
if [[ -d $INSTALL_DIR/.git ]]; then
  git -C "$INSTALL_DIR" remote set-url origin "$REPO_URL"
elif [[ -e $INSTALL_DIR ]]; then
  # A directory from the old standalone installer: keep .env and data, adopt the rest.
  git -C "$INSTALL_DIR" init -q -b "$BRANCH"
  git -C "$INSTALL_DIR" remote add origin "$REPO_URL"
else
  git clone -q --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi
git -C "$INSTALL_DIR" fetch -q origin "$BRANCH"
git -C "$INSTALL_DIR" reset -q --hard FETCH_HEAD

(
  umask 077
  # Settings added by hand, such as SOAR_PANEL_VERSION, survive a re-run.
  others=$(grep -vE '^(BOT_TOKEN|ADMIN_CHAT_IDS|NODE_ENV)=' "$ENV_FILE" 2>/dev/null || true)
  printf 'BOT_TOKEN=%s\nADMIN_CHAT_IDS=%s\nNODE_ENV=production\n' "$BOT_TOKEN" "$ADMIN_CHAT_IDS" > "$ENV_FILE.new"
  [[ -z $others ]] || printf '%s\n' "$others" >> "$ENV_FILE.new"
  mv -f -- "$ENV_FILE.new" "$ENV_FILE"
)

echo '[5/5] Installing dependencies and services...'
bash "$INSTALL_DIR/scripts/bot-setup.sh"
systemctl restart whitedns-bot.service
# Long enough to see a rejected token or a polling conflict, which exit within seconds.
sleep 8
if systemctl is-active --quiet whitedns-bot.service; then
  printf '\n[OK] Bot is running. Send /start to your bot in Telegram.\n'
  printf 'Menu: whitedns-bot (or bot)   Logs: journalctl -u whitedns-bot -f\n'
else
  journalctl -u whitedns-bot -n 20 --no-pager || true
  fail 'The service failed to start. See the log above.'
fi
