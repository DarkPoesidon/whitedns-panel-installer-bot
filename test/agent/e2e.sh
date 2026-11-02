#!/usr/bin/env bash
# Real end-to-end test of scripts/agent.sh on a disposable systemd Linux (WSL distro or VM).
# It installs and removes the real panel, so never run it on a server you care about.
# Usage: sudo I_ACCEPT_THIS_MACHINE_IS_DISPOSABLE=1 bash test/agent/e2e.sh
set -uo pipefail
[[ ${I_ACCEPT_THIS_MACHINE_IS_DISPOSABLE:-} == 1 ]] || { echo 'refusing: set I_ACCEPT_THIS_MACHINE_IS_DISPOSABLE=1'; exit 2; }

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
AGENT=$HERE/../../scripts/agent.sh
DIR=/var/lib/whitedns-agent
VERSION=0.14.0
ZONE=soar.e2e-test.example
NS=ns-soar.e2e-test.example
PUBLIC=45.33.32.156
PASS=E2eTestOnlyPassw0rd
fails=0

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
result() { grep -E "^$1=" "$DIR/result.env" | head -n1 | cut -d= -f2-; }
warnings() { grep -E '^warning=' "$DIR/result.env" | cut -d= -f2- | tr '\n' ' '; }

job() {
  install -d -m 0700 "$DIR"
  printf 'ZONE=%s\nNS_HOST=%s\nPUBLIC_IP=%s\nVERSION=%s\n' "$ZONE" "$NS" "$PUBLIC" "$VERSION" > "$DIR/job.env"
  printf '%s\n' "$@" >> "$DIR/job.env"
  chmod 600 "$DIR/job.env"
}
secret() { (umask 077; printf '%s' "$PASS" > "$DIR/admin.secret"); }
# Same detached launch the bot performs, so a real unit environment is exercised.
run() {
  systemd-run --quiet --wait --collect --unit=whitedns-agent \
    -p StandardOutput="truncate:$DIR/job.log" -p StandardError=inherit bash "$DIR/agent.sh" "$1" >/dev/null 2>&1
  local rc=$?
  printf -- '--- %s rc=%s status=%s code=%s detail=%s warnings=[%s]\n' "$1" "$rc" "$(result status)" "$(result code)" "$(result detail)" "$(warnings)"
  return 0
}

reset_machine() {
  systemctl stop soar-panel soar-panel-ops 2>/dev/null
  systemctl disable soar-panel soar-panel-ops 2>/dev/null
  rm -rf /var/lib/soar-panel /var/lib/soar-panel-ops /etc/systemd/system/soar-panel*.service "$DIR"
  rm -f /usr/local/bin/soar-panel /usr/local/bin/soar-panel-ops /usr/local/bin/soar-check /usr/local/bin/soar-panel-security /usr/local/bin/soar-panel-menu /usr/local/bin/whitedns
  systemctl daemon-reload
  install -d -m 0700 "$DIR"
  cp "$AGENT" "$DIR/agent.sh"
  sed -i 's/\r$//' "$DIR/agent.sh"
}

reset_machine

echo '== static'
check 'bash -n' bash -n "$AGENT"
if command -v shellcheck >/dev/null; then check 'shellcheck' shellcheck -S warning -x "$AGENT"; fi

echo '== probe is read-only'
before=$(find /etc/systemd/system /usr/local/bin -maxdepth 1 | sort | sha256sum)
probe=$(bash "$DIR/agent.sh" probe 127.0.0.1)
printf '%s\n' "$probe" | sed 's/^/    /'
check 'probe changes nothing' test "$before" == "$(find /etc/systemd/system /usr/local/bin -maxdepth 1 | sort | sha256sum)"
check 'probe sees no install' grep -q '^installed=0' <<< "$probe"
check 'stub on 127.0.0.53 is not a port 53 conflict' grep -qx 'port53=' <<< "$probe"

echo '== repair on empty machine'
job; run repair
check 'repair refuses when nothing is installed' test "$(result code)" == NOT_INSTALLED

echo '== bad job values never reach a shell'
job 'ZONE=$(touch /tmp/pwned).ex'; secret; run install
check 'injection rejected' test "$(result code)" == JOB_INVALID
check 'injection not executed' test ! -e /tmp/pwned
job 'ADMIN_ROOTKIT=1'; run install
check 'unknown key rejected' test "$(result code)" == JOB_INVALID

echo '== zone longer than the panel limit'
job 'ZONE=soar.this-domain-is-too-long.example'; secret; run install
check 'long zone stops before changes' test "$(result code)" == ZONE_TOO_LONG
check 'long zone installed nothing' test ! -e /usr/local/bin/soar-panel

echo '== rollback of a failed fresh install'
job 'FAULT=activate'; secret; run install
check 'status rolled_back' test "$(result status)" == rolled_back
check 'unit removed' test ! -e /etc/systemd/system/soar-panel.service
check 'binary removed' test ! -e /usr/local/bin/soar-panel
check 'database removed' test ! -e /var/lib/soar-panel/panel.db
check 'secret wiped after failure' test ! -e "$DIR/admin.secret"
rm -rf /root/soar-panel-backup-*

echo '== fresh install'
job; secret; run install
check 'status ok' test "$(result status)" == ok
check 'fresh flag' test "$(result fresh)" == 1
check 'warning detail reaches the result' grep -q '^warning_detail_TUNNEL_RECURSIVE_FAILED=.' "$DIR/result.env"
check 'panel active' systemctl is-active --quiet soar-panel
check 'ops active' systemctl is-active --quiet soar-panel-ops
check 'panel enabled' systemctl is-enabled --quiet soar-panel
url=$(result panel_url); echo "    url=$url"
check 'url has private path' grep -Eq '/[A-Za-z0-9_-]{24,96}/$' <<< "$url"
check 'secret wiped' test ! -e "$DIR/admin.secret"
check 'job.env wiped' test ! -e "$DIR/job.env"
check 'password absent from log' bash -c "! grep -q '$PASS' '$DIR/job.log'"
check 'password absent from result' bash -c "! grep -q '$PASS' '$DIR/result.env'"
check 'resolved stub untouched' systemctl is-active --quiet systemd-resolved
check 'resolv.conf untouched' test -L /etc/resolv.conf
check 'dns on specific ip, not 0.0.0.0' bash -c "! grep -q 'dns-listen 0.0.0.0' /etc/systemd/system/soar-panel.service"
check 'panel answers on private path' curl -fsS -o /dev/null --max-time 5 "$url"
check 'panel hides root path' bash -c "! curl -fsS -o /dev/null --max-time 5 http://$(result panel_bind)/"
db_login_hash=$(sha256sum /var/lib/soar-panel/access.json)

echo '== reinstall with the same zone keeps everything'
job; run install
check 'status ok' test "$(result status)" == ok
check 'not fresh' test "$(result fresh)" == 0
check 'password not reported changed' test "$(result admin_changed)" == 0
check 'private url unchanged' test "$(result panel_url)" == "$url"
check 'access.json unchanged' test "$db_login_hash" == "$(sha256sum /var/lib/soar-panel/access.json)"

echo '== reinstall with another zone'
job "ZONE=soar.other.example"; run install
check 'mismatch asks before changing' test "$(result code)" == ZONE_MISMATCH
check 'panel still running' systemctl is-active --quiet soar-panel

echo '== replacing the panel of another zone, and undoing it'
# The running panel keeps writing to its database, so a hash would differ; a marker proves the same directory returned.
touch /var/lib/soar-panel/e2e-marker
job 'ZONE=soar.other.example' 'ON_ZONE_MISMATCH=replace' 'FAULT=activate'; secret; run install
check 'failed replace rolled back' test "$(result status)" == rolled_back
check 'old panel running again' systemctl is-active --quiet soar-panel
check 'old data directory restored' test -e /var/lib/soar-panel/e2e-marker
systemctl stop soar-panel
check 'old zone restored' test "$(/usr/local/bin/soar-panel zone --db /var/lib/soar-panel/panel.db)" == "$ZONE"
systemctl start soar-panel
check 'old url restored' test "$(/usr/local/bin/soar-panel access-url --db /var/lib/soar-panel/panel.db --listen 127.0.0.1:2053)" == "$url"
job 'ZONE=soar.other.example' 'ON_ZONE_MISMATCH=replace'; secret; run install
check 'replace ok' test "$(result status)" == ok
check 'replace is fresh' test "$(result fresh)" == 1
check 'replace has new zone' test "$(result zone)" == soar.other.example
replaced=$(result backup)
check 'old database in backup' test -e "$replaced/replaced-data/panel.db"
check 'old data moved, not mixed' test -e "$replaced/replaced-data/e2e-marker" -a ! -e /var/lib/soar-panel/e2e-marker
url=$(result panel_url)
ZONE=soar.other.example

echo '== a newer panel is never downgraded'
job 'VERSION=0.13.0'; run repair
check 'repair keeps newer binary' test "$(result version)" == 0.14.0
systemctl stop soar-panel; rm -f /usr/local/bin/soar-check; systemctl start soar-panel
job 'VERSION=0.13.0'; run repair
check 'still not downgraded with soar-check missing' test "$(/usr/local/bin/soar-panel version)" == 0.14.0
check 'missing tool is reported' bash -c "grep -q '^warning=CHECK_TOOL_MISSING' '$DIR/result.env'"

echo '== repair of a stopped panel'
systemctl stop soar-panel
job; run repair
check 'repair status ok' test "$(result status)" == ok
check 'panel running again' systemctl is-active --quiet soar-panel
check 'repair keeps url' test "$(result panel_url)" == "$url"

echo '== repair of a deleted unit and binary'
systemctl stop soar-panel; rm -f /etc/systemd/system/soar-panel.service /usr/local/bin/soar-check; systemctl daemon-reload
job; run repair
check 'partial install repaired' test "$(result status)" == ok
check 'unit restored' test -f /etc/systemd/system/soar-panel.service
check 'tool restored' test -x /usr/local/bin/soar-check

echo '== password reset'
job 'RESET_ADMIN=1'; secret; run repair
check 'reset reported' test "$(result admin_changed)" == 1

echo '== busy port 53 stops before changes'
systemctl stop soar-panel
python3 -c "
import socket,time
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')',53)); time.sleep(40)" &
blocker=$!
sleep 1
job; run install
check 'conflict reported' test "$(result code)" == PORT53_BUSY
kill "$blocker" 2>/dev/null; wait "$blocker" 2>/dev/null
systemctl start soar-panel

echo '== uninstall keeps data when asked'
job 'UNINSTALL_MODE=keep'; run uninstall
check 'uninstall ok' test "$(result status)" == ok
check 'services gone' test ! -e /etc/systemd/system/soar-panel.service
check 'data kept' test -e /var/lib/soar-panel/panel.db
backup=$(result backup)
check 'recovery copy exists' test -e "$backup/data/panel.db"

echo '== reinstall over kept data, then purge'
job; secret; run install
check 'reinstall reuses data' test "$(result fresh)" == 0
check 'url survives uninstall' test "$(result panel_url)" == "$url"
job 'UNINSTALL_MODE=purge'; run uninstall
check 'purge ok' test "$(result status)" == ok
check 'data purged' test ! -e /var/lib/soar-panel
job 'UNINSTALL_MODE=purge'; run uninstall
check 'uninstall on empty machine is safe' test "$(result status)" == ok

rm -rf /root/soar-panel-backup-* /root/soar-panel-uninstall-*
echo
if (( fails )); then echo "$fails check(s) failed"; exit 1; fi
echo 'all checks passed'
