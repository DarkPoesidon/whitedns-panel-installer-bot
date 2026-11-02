#!/usr/bin/env bash
# Real test of deploy.sh, update.sh and uninstall.sh on a disposable systemd Linux.
# A local git repo stands in for GitHub and a small HTTP stub stands in for Telegram.
# Usage: sudo I_ACCEPT_THIS_MACHINE_IS_DISPOSABLE=1 bash test/agent/deploy-real.sh <checkout>
set -uo pipefail
[[ ${I_ACCEPT_THIS_MACHINE_IS_DISPOSABLE:-} == 1 ]] || { echo 'refusing: set I_ACCEPT_THIS_MACHINE_IS_DISPOSABLE=1'; exit 2; }

SRC=${1:?checkout path}
REMOTE=/tmp/wdtest-remote
WORK=/tmp/wdtest-work
OPT=/opt/whitedns-bot
TOKEN=123456:TESTTOKENabcdefghij
STATUS=/var/lib/whitedns-bot-update/status
fails=0

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
active() { systemctl is-active --quiet whitedns-bot; }

clean() {
  systemctl disable --now whitedns-bot whitedns-bot-update.path 2>/dev/null
  rm -f /etc/systemd/system/whitedns-bot*
  systemctl daemon-reload
  rm -rf "$OPT" /var/lib/whitedns-bot /var/lib/whitedns-bot-update "$REMOTE" "$WORK" /usr/local/bin/whitedns-bot /usr/local/bin/bot /usr/bin/whitedns-bot /usr/bin/bot
  userdel whitedns-bot 2>/dev/null
}
clean

# --- stand-ins -----------------------------------------------------------------
cat > /tmp/wdtest-telegram.py <<'PY'
import http.server, json, time
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        length = int(self.headers.get('content-length') or 0); self.rfile.read(length)
        m = self.path.rsplit('/', 1)[-1]
        if m == 'getUpdates': time.sleep(1); r = []
        elif m == 'getMe': r = {'id': 1, 'is_bot': True, 'first_name': 'b', 'username': 'b_bot'}
        else: r = True
        b = json.dumps({'ok': True, 'result': r}).encode()
        self.send_response(200); self.send_header('content-type', 'application/json'); self.end_headers(); self.wfile.write(b)
    do_GET = do_POST
http.server.ThreadingHTTPServer(('127.0.0.1', 18081), H).serve_forever()
PY
python3 /tmp/wdtest-telegram.py 2>/dev/null & STUB=$!
trap 'kill $STUB 2>/dev/null' EXIT
sleep 1

git config --global --add safe.directory '*'
mkdir -p "$WORK"
tar -C "$SRC" --exclude=node_modules --exclude=.git -cf - . | tar -C "$WORK" -xf -
find "$WORK" -type f \( -name '*.sh' -o -name '*.js' -o -name '*.json' -o -name '.env*' \) -exec sed -i 's/\r$//' {} +
git -C "$WORK" init -q -b main
git -C "$WORK" -c user.email=t@t -c user.name=t add -A
git -C "$WORK" -c user.email=t@t -c user.name=t commit -qm v1
git clone -q --bare "$WORK" "$REMOTE"
export REPO_URL=$REMOTE BRANCH=main

echo '== fresh deploy into a directory with existing settings'
mkdir -p "$OPT"
printf 'TELEGRAM_API_ROOT=http://127.0.0.1:18081\nSOAR_PANEL_VERSION=0.14.0\n' > "$OPT/.env"
# Old installs kept their database inside the checkout, with secrets in plain text.
cat > /tmp/wdtest-seed.cjs <<'JS'
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(process.argv[2]);
db.exec(`
  CREATE TABLE sessions (chat_id INTEGER PRIMARY KEY, step TEXT, cf_token TEXT, vps_pass TEXT);
  INSERT INTO sessions VALUES (1, 'X', 'OLDCFTOKEN', 'OLDROOTPASS');
  CREATE TABLE deployments (id INTEGER PRIMARY KEY AUTOINCREMENT, chat_id INTEGER, domain TEXT, vps_ip TEXT, panel_url TEXT, status TEXT, created_at INTEGER);
  INSERT INTO deployments (chat_id, domain, vps_ip) VALUES (1, 'kept.io', '1.2.3.4');
`);
db.close();
JS
ADMIN_CHAT_IDS=777 bash "$WORK/deploy.sh" "$TOKEN" < /dev/null > /tmp/wdtest-deploy.log 2>&1
rc=$?
tail -3 /tmp/wdtest-deploy.log | sed 's/^/    /'
check 'deploy exits 0' test "$rc" == 0
check 'service active' active
check 'runs unprivileged' test "$(systemctl show whitedns-bot -p User --value)" == whitedns-bot
check 'process is not root' test "$(ps -o uid= -p "$(systemctl show whitedns-bot -p MainPID --value)" | tr -d ' ')" == "$(id -u whitedns-bot)"
check 'code is root owned' test "$(stat -c %U "$OPT/src/bot.js")" == root
check 'bot cannot write its code' bash -c "! sudo -u whitedns-bot test -w '$OPT/src/bot.js'"
check '.env is private' test "$(stat -c %a "$OPT/.env")" == 600
check 'bot user cannot read .env' bash -c "! sudo -u whitedns-bot cat '$OPT/.env' >/dev/null 2>&1"
check 'custom setting survives' grep -q '^SOAR_PANEL_VERSION=0.14.0' "$OPT/.env"
check 'admin id saved' grep -q '^ADMIN_CHAT_IDS=777' "$OPT/.env"
check 'database created' test -f /var/lib/whitedns-bot/data.db
check 'launcher installed' test -x /usr/local/bin/whitedns-bot
check 'unit files verify' systemd-analyze verify /etc/systemd/system/whitedns-bot.service /etc/systemd/system/whitedns-bot-update.path /etc/systemd/system/whitedns-bot-update.service

echo '== re-deploy is safe'
ADMIN_CHAT_IDS=777 bash "$OPT/deploy.sh" < /dev/null > /tmp/wdtest-deploy.log 2>&1
check 'second deploy keeps token' grep -q "^BOT_TOKEN=$TOKEN" "$OPT/.env"
check 'still active' active

echo '== update reached by the Telegram request file'
git -C "$WORK" -c user.email=t@t -c user.name=t commit -q --allow-empty -m v2
git -C "$WORK" push -q "$REMOTE" main
V2=$(git -C "$WORK" rev-parse --short=7 HEAD)
sudo -u whitedns-bot bash -c "printf '777\n' > /var/lib/whitedns-bot/update-request"
for _ in $(seq 1 60); do grep -q "$V2" "$STATUS" 2>/dev/null && break; sleep 2; done
cat "$STATUS" 2>/dev/null | sed 's/^/    /'
check 'status reports the new commit' grep -q "^ok $V2 777 " "$STATUS"
check 'code moved to v2' test "$(git -C "$OPT" rev-parse --short=7 HEAD)" == "$V2"
check 'request file consumed' test ! -e /var/lib/whitedns-bot/update-request
check 'active after update' active

echo '== a broken release is rolled back'
printf "throw new Error('broken release');\n" > "$WORK/src/bot.js"
git -C "$WORK" -c user.email=t@t -c user.name=t commit -qam v3-broken
git -C "$WORK" push -q "$REMOTE" main
V3=$(git -C "$WORK" rev-parse --short=7 HEAD)
bash "$OPT/update.sh" > /tmp/wdtest-update.log 2>&1
rc=$?
check 'update reports failure' test "$rc" != 0
check 'status says failed' grep -q "^failed $V3 " "$STATUS"
check 'code returned to v2' test "$(git -C "$OPT" rev-parse --short=7 HEAD)" == "$V2"
check 'service healthy on v2' active

echo '== legacy layout migrates through the npm hook'
systemctl stop whitedns-bot
sed -i '/^User=/d; /^Group=/d' /etc/systemd/system/whitedns-bot.service
systemctl daemon-reload
rm -rf /var/lib/whitedns-bot
node --no-warnings /tmp/wdtest-seed.cjs "$OPT/data.db"
check 'seeded secrets exist' grep -qa OLDROOTPASS "$OPT/data.db"
chmod 644 "$OPT/.env"
(cd "$OPT" && npm install --omit=dev --no-audit --no-fund > /tmp/wdtest-legacy.log 2>&1)
check 'unit now unprivileged' grep -q '^User=whitedns-bot' /etc/systemd/system/whitedns-bot.service
check 'database moved' test -f /var/lib/whitedns-bot/data.db
check 'database left the checkout' test ! -e "$OPT/data.db"
check '.env tightened' test "$(stat -c %a "$OPT/.env")" == 600
systemctl restart whitedns-bot
sleep 4
check 'migrated bot active' active
check 'old secrets wiped' bash -c "! grep -qaE 'OLDCFTOKEN|OLDROOTPASS' /var/lib/whitedns-bot/data.db*"
check 'deployments kept' grep -qa 'kept.io' /var/lib/whitedns-bot/data.db

echo '== uninstall'
bash "$OPT/uninstall.sh" -y > /dev/null 2>&1
check 'service gone' bash -c "! systemctl cat whitedns-bot >/dev/null 2>&1"
check 'code gone' test ! -e "$OPT"
check 'data gone' test ! -e /var/lib/whitedns-bot
check 'launcher gone' test ! -e /usr/local/bin/whitedns-bot

rm -rf "$REMOTE" "$WORK"
echo
if (( fails )); then echo "$fails check(s) failed"; exit 1; fi
echo 'all checks passed'
