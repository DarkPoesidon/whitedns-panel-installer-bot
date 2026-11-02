#!/usr/bin/env bash
# Converges this checkout into a running bot: Node, user, data, dependencies, units.
# Safe to run any number of times; deploy.sh and update.sh both end up here.
set -Eeuo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

INSTALL_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SERVICE_USER=whitedns-bot
DATA_DIR=/var/lib/whitedns-bot
STATUS_DIR=/var/lib/whitedns-bot-update
UNITS=/etc/systemd/system
ENV_FILE=$INSTALL_DIR/.env
MIN_NODE=22.13.0

# Versions before 2.0 ran `npm install` as root from /update and then restarted the service,
# so they reach the new layout through this hook. Everywhere else it does nothing.
if [[ ${1:-} == --if-legacy ]]; then
  [[ $EUID == 0 && -f $UNITS/whitedns-bot.service ]] || exit 0
  grep -q "^User=$SERVICE_USER" "$UNITS/whitedns-bot.service" && exit 0
fi

[[ $EUID == 0 ]] || { echo '[ERROR] Run as root.' >&2; exit 1; }

node_ok() {
  command -v node >/dev/null || return 1
  [[ $(printf '%s\n%s\n' "$MIN_NODE" "$(node -v | tr -d v)" | sort -V | head -n1) == "$MIN_NODE" ]]
}
if ! node_ok; then
  echo '[..] Installing Node.js 22 LTS from NodeSource...'
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get -o DPkg::Lock::Timeout=300 install -y nodejs
  node_ok || { echo "[ERROR] Node.js $MIN_NODE or newer is required." >&2; exit 1; }
fi

id "$SERVICE_USER" >/dev/null 2>&1 || useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0700 "$DATA_DIR"
install -d -o root -g root -m 0755 "$STATUS_DIR"

# Move data from the old location. The bot wipes old plain text secrets on its first start.
for file in data.db data.db-wal data.db-shm; do
  if [[ -f $INSTALL_DIR/$file && ! -e $DATA_DIR/$file ]]; then mv -- "$INSTALL_DIR/$file" "$DATA_DIR/$file"; fi
done
chown -R "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR"

touch "$ENV_FILE"
chown root:root "$ENV_FILE"
chmod 0600 "$ENV_FILE"

cd "$INSTALL_DIR"
if [[ -f package-lock.json ]]; then npm ci --omit=dev --ignore-scripts --no-audit --no-fund
else npm install --omit=dev --ignore-scripts --no-audit --no-fund; fi

chmod +x update.sh uninstall.sh menu.sh deploy.sh scripts/*.sh

NODE_BIN=$(command -v node)
cat > "$UNITS/whitedns-bot.service" <<UNIT
[Unit]
Description=WhiteDNS Telegram Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$ENV_FILE
Environment=DATA_DIR=$DATA_DIR
Environment=UPDATE_STATUS_FILE=$STATUS_DIR/status
ExecStart=$NODE_BIN --disable-warning=ExperimentalWarning src/bot.js
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$DATA_DIR
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT

# /update from Telegram only creates this file; the unprivileged bot never runs the update itself.
cat > "$UNITS/whitedns-bot-update.path" <<UNIT
[Unit]
Description=Watch for WhiteDNS bot update requests

[Path]
PathExists=$DATA_DIR/update-request

[Install]
WantedBy=multi-user.target
UNIT

cat > "$UNITS/whitedns-bot-update.service" <<UNIT
[Unit]
Description=Update the WhiteDNS Telegram Bot

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash $INSTALL_DIR/update.sh --from-bot
TimeoutStartSec=600
UNIT

for launcher in /usr/local/bin/whitedns-bot /usr/local/bin/bot; do
  printf '#!/usr/bin/env bash\nexec bash %q/menu.sh "$@"\n' "$INSTALL_DIR" > "$launcher"
  chmod 0755 "$launcher"
done
# Older versions also placed these here, with a fallback that piped code from the network.
rm -f /usr/bin/whitedns-bot /usr/bin/bot

systemctl daemon-reload
systemctl enable whitedns-bot.service whitedns-bot-update.path >/dev/null 2>&1
systemctl restart whitedns-bot-update.path
