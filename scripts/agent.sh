#!/usr/bin/env bash
# WhiteDNS server agent: probe | install | repair | uninstall.
# Mirrors the transaction of the official panel-install.sh for headless use.
# Terminal text stays ASCII; the bot translates the CODE of each event to Persian.
#
# Events on stdout:  @@ <stage> <start|ok|warn|fail> <CODE> <ascii detail>
# Final state:       $AGENT_DIR/result.env (key=value lines, no secrets)
set -Eeuo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077

AGENT_DIR=/var/lib/whitedns-agent
JOB_ENV=$AGENT_DIR/job.env
SECRET=$AGENT_DIR/admin.secret
BUNDLE_UPLOAD=$AGENT_DIR/bundle.tar.gz
RESULT=$AGENT_DIR/result.env
DATA=/var/lib/soar-panel
STATE=/var/lib/soar-panel-ops
DB=$DATA/panel.db
ACCESS=$DATA/access.json
BIN=/usr/local/bin/soar-panel
CHECK_BIN=/usr/local/bin/soar-check
UNITS=/etc/systemd/system
SERVICE=$UNITS/soar-panel.service
OPS_SERVICE=$UNITS/soar-panel-ops.service
NGINX_SITE=/etc/nginx/sites-available/soar-panel
NGINX_LINK=/etc/nginx/sites-enabled/soar-panel
APT_LEGACY_LIST=/etc/apt/sources.list.d/whitedns-official.list
UFW_COMMENT=soar-panel-installer
# Comments used by earlier versions of this bot; removed on uninstall too.
UFW_OWNED="$UFW_COMMENT|soar-tunnel-dns|soar-acme-http|soar-panel-https"

# Job parameters, parsed from job.env with an allowlist and never sourced.
ZONE='' NS_HOST='' PANEL_DOMAIN='' PUBLIC_IP='' LISTEN_IP='' ADMIN_USER=admin ADMIN_EMAIL=''
VERSION='' BUNDLE_SHA256='' RESET_ADMIN=0 ON_ZONE_MISMATCH=fail ALLOW_MIGRATE=0 UNINSTALL_MODE=keep
RESOLVERS=1.1.1.1,8.8.8.8 FAULT=''

OP='' FAIL_CODE='' FAIL_DETAIL='' WARNINGS=()
FRESH=0 ADMIN_CHANGED=0 ACTIVATED=0 TRANSACTION=0 BACKUP='' WORK_DIR='' NEEDS_BINS=0 BUNDLE_ROOT=''
OPS_WAS_ACTIVE=0 PANEL_WAS_ACTIVE=0 OLD_WAS_ACTIVE=0 PANEL_WANTED=0 PROBE_ID=''
DNS_PORT=53 PANEL_BIND='' FIREWALL_ADDED=()
TRANSACTION_FILES=("$SERVICE" "$OPS_SERVICE" "$BIN" /usr/local/bin/soar-panel-ops /usr/local/bin/soar-panel-security
  /usr/local/bin/soar-panel-menu "$CHECK_BIN" "$DB" "$ACCESS" "$DATA/public-ip"
  "$UNITS/soar-panel.service.d/90-management.conf" "$UNITS/soar-panel-ops.service.d/90-management.conf")
declare -A WAS_ENABLED=()

clean() { tr -d '\r' <<< "${1:-}" | tr '\n\t' '  ' | cut -c1-300; }
emit() { printf '@@ %s %s %s %s\n' "$1" "$2" "${3:--}" "$(clean "${4:-}")"; }
warn() { WARNINGS+=("$2"); emit "$1" warn "$2" "${3:-}"; }
die() {
  FAIL_CODE=$1; FAIL_DETAIL=$(clean "${2:-}")
  exit 1
}
fault() { [[ $FAULT != "$1" ]] || die TEST_FAULT "injected at $1"; }

valid_ipv4() {
  local part
  local -a parts
  [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r -a parts <<< "$1"
  for part in "${parts[@]}"; do
    [[ $part == 0 || $part != 0* ]] && (( 10#$part <= 255 )) || return 1
  done
}
public_ipv4() {
  local a b c
  valid_ipv4 "${1:-}" || return 1
  IFS=. read -r a b c _ <<< "$1"
  (( a > 0 && a < 224 && a != 10 && a != 127 )) || return 1
  ! (( (a == 100 && b >= 64 && b <= 127) || (a == 169 && b == 254) ||
       (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) ||
       (a == 192 && b == 0 && (c == 0 || c == 2)) || (a == 192 && b == 88 && c == 99) ||
       (a == 198 && (b == 18 || b == 19)) || (a == 198 && b == 51 && c == 100) ||
       (a == 203 && b == 0 && c == 113) ))
}
valid_domain() {
  [[ ${#1} -le 253 && $1 =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]
}

load_job() {
  local name value
  [[ -r $JOB_ENV ]] || die JOB_MISSING 'job.env not found'
  while IFS='=' read -r name value || [[ -n $name ]]; do
    case "$name" in
      ZONE|NS_HOST|PANEL_DOMAIN|PUBLIC_IP|LISTEN_IP|ADMIN_USER|ADMIN_EMAIL|VERSION|BUNDLE_SHA256|RESET_ADMIN|ON_ZONE_MISMATCH|ALLOW_MIGRATE|UNINSTALL_MODE|RESOLVERS|FAULT)
        printf -v "$name" '%s' "$value" ;;
      '') ;;
      *) die JOB_INVALID "unknown key $name" ;;
    esac
  done < "$JOB_ENV"
  [[ -z $ZONE || ( ${#ZONE} -le 24 ) ]] || die ZONE_TOO_LONG "$ZONE"
  [[ -z $ZONE ]] || valid_domain "$ZONE" || die JOB_INVALID 'ZONE'
  [[ -z $NS_HOST ]] || valid_domain "$NS_HOST" || die JOB_INVALID 'NS_HOST'
  [[ -z $PANEL_DOMAIN ]] || valid_domain "$PANEL_DOMAIN" || die JOB_INVALID 'PANEL_DOMAIN'
  [[ -z $PUBLIC_IP ]] || public_ipv4 "$PUBLIC_IP" || die JOB_INVALID 'PUBLIC_IP'
  [[ -z $LISTEN_IP ]] || valid_ipv4 "$LISTEN_IP" || die JOB_INVALID 'LISTEN_IP'
  [[ $ADMIN_USER =~ ^[a-zA-Z0-9_.-]{1,64}$ ]] || die JOB_INVALID 'ADMIN_USER'
  [[ -z $VERSION || $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die JOB_INVALID 'VERSION'
  [[ -z $BUNDLE_SHA256 || $BUNDLE_SHA256 =~ ^[a-f0-9]{64}$ ]] || die JOB_INVALID 'BUNDLE_SHA256'
  [[ $RESOLVERS =~ ^[0-9.,]+$ ]] || die JOB_INVALID 'RESOLVERS'
}

# --- facts ---------------------------------------------------------------------
detect_arch() { case "$(uname -m)" in x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;; *) return 1;; esac; }
# A subshell, because os-release defines VERSION and would overwrite the job's panel version.
os_supported() (
  [[ -r /etc/os-release ]] || exit 1
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID%%.*}" in ubuntu:22|ubuntu:24|ubuntu:26|debian:12|debian:13) exit 0;; esac
  exit 1
)
local_ips() { ip -o -4 addr show 2>/dev/null | awk '{split($4,a,"/");print a[1]}'; }
default_ip() { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}'; }
external_ip() {
  local url ip
  for url in https://api.ipify.org https://icanhazip.com https://ifconfig.me; do
    ip=$(curl -4fsS --connect-timeout 4 --max-time 8 "$url" 2>/dev/null | tr -d ' \r\n') || continue
    public_ipv4 "$ip" && { echo "$ip"; return 0; }
  done
  return 1
}
exec_start() { systemctl show "$1" -p ExecStart --value 2>/dev/null || true; }
unit_flag() { sed -n "s/.*--$2 \([^ ;]*\).*/\1/p" <<< "$(exec_start "$1")"; }
# The panel holds an exclusive lock while running, so a hint is read from the raw file.
zone_hint() { grep -aoE '"base_zone":"[^"]*"' "$DB" 2>/dev/null | head -n1 | cut -d'"' -f4 || true; }
access_field() { grep -oE "\"$1\": *(\"[^\"]*\"|true|false)" "$ACCESS" 2>/dev/null | head -n1 | sed -E 's/^[^:]*: *//; s/"//g' || true; }

# Prints conflicting listeners on PORT, skipping the panel's own process and loopback-only binds.
port_conflicts() {
  local protocol=$1 port=$2 target=${3:-} row endpoint host own_pid
  own_pid=$(systemctl show soar-panel.service -p MainPID --value 2>/dev/null || echo 0)
  while IFS= read -r row; do
    [[ -n $row ]] || continue
    [[ $own_pid == 0 || $row != *"pid=$own_pid,"* ]] || continue
    endpoint=$(awk '{print $4}' <<< "$row"); host=${endpoint%:*}; host=${host%%%*}
    case "$host" in
      '*'|0.0.0.0|'[::]'|'::') printf '%s\n' "$row" ;;
      *) [[ -z $target || $host != "$target" ]] || printf '%s\n' "$row" ;;
    esac
  done < <(ss -H -l"$protocol"np "sport = :$port" 2>/dev/null || true)
}
owner_of() { sed -n 's/.*users:(("\([^"]*\)".*/\1/p' <<< "$1" | head -n1; }

cmd_probe() {
  local ssh_host=${1:-} listen public ip arch
  arch=$(detect_arch) || arch=unsupported
  echo "arch=$arch"
  # shellcheck disable=SC1091
  ( . /etc/os-release 2>/dev/null && echo "os=${ID:-unknown} ${VERSION_ID:-}" ) || echo 'os=unknown'
  os_supported && echo os_supported=1 || echo os_supported=0
  [[ -d /run/systemd/system ]] && echo systemd=1 || echo systemd=0
  echo "disk_mb=$(df -Pm /usr/local 2>/dev/null | awk 'END{print $4}')"
  command -v ss >/dev/null && command -v ip >/dev/null && echo net_tools=1 || echo net_tools=0
  listen=$(default_ip || true)
  if [[ -n $ssh_host ]] && local_ips | grep -Fxq -- "$ssh_host"; then listen=$ssh_host; fi
  echo "listen_ip=$listen"
  public=''
  if public_ipv4 "$ssh_host"; then public=$ssh_host
  elif public_ipv4 "$listen"; then public=$listen
  else public=$(external_ip || true); fi
  echo "public_ip=$public"
  echo "port53=$(owner_of "$(port_conflicts u 53 "$listen" | head -n1)")"
  echo "port80=$(owner_of "$(port_conflicts t 80 | head -n1)")"
  echo "port443=$(owner_of "$(port_conflicts t 443 | head -n1)")"
  if [[ -e $DB ]]; then echo installed=1; echo "zone=$(zone_hint)"; else echo installed=0; echo zone=; fi
  echo "panel_version=$( [[ -x $BIN ]] && timeout 5 "$BIN" version 2>/dev/null || true)"
  echo "https_domain=$(access_field domain)"
  echo "base_path=$( [[ -n $(access_field base_path) ]] && echo 1 || echo 0)"
  systemctl is-active --quiet soar-panel.service && echo panel_active=1 || echo panel_active=0
  systemctl is-active --quiet soar-server.service && echo old_soar=1 || echo old_soar=0
  [[ -f $NGINX_SITE ]] && echo legacy_nginx=1 || echo legacy_nginx=0
  systemctl is-active --quiet whitedns-agent.service && echo job_active=1 || echo job_active=0
  for ip in $(local_ips); do [[ $ip == 127.* ]] || echo "local_ip=$ip"; done
}

# --- stages --------------------------------------------------------------------
stage_preflight() {
  emit preflight start
  [[ $EUID == 0 ]] || die NOT_ROOT
  [[ -d /run/systemd/system ]] || die NO_SYSTEMD
  os_supported || die UNSUPPORTED_OS "$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
  detect_arch >/dev/null || die UNSUPPORTED_ARCH "$(uname -m)"
  (( $(df -Pm /usr/local | awk 'END{print $4}') >= 200 )) || die NO_DISK
  exec 9>/run/lock/soar-panel-install.lock
  flock -n 9 || die BUSY 'another panel installation is running'
  install -d -m 0700 "$STATE"
  exec 8>"$STATE/maintenance.lock"
  flock -n 8 || die BUSY 'a panel maintenance operation is running'

  # Damage left by earlier versions of this bot.
  rm -f -- "$APT_LEGACY_LIST"
  if [[ -f /etc/resolv.conf && ! -L /etc/resolv.conf && $(stat -c %a /etc/resolv.conf) != 644 ]]; then
    chmod 0644 /etc/resolv.conf
  fi

  if [[ $OP == repair && ! -e $DB ]]; then die NOT_INSTALLED; fi
  if [[ $OP == repair ]]; then
    [[ -n $ZONE ]] || ZONE=$(zone_hint)
    [[ -n $PANEL_DOMAIN ]] || PANEL_DOMAIN=$(access_field domain)
  else
    [[ -n $ZONE && -n $NS_HOST ]] || die JOB_INVALID 'ZONE and NS_HOST are required'
    public_ipv4 "$PUBLIC_IP" || die JOB_INVALID 'PUBLIC_IP is required'
  fi
  [[ -e $DB || ( -s $SECRET ) ]] || die JOB_INVALID 'admin secret is required for a new database'
  if [[ -z $LISTEN_IP ]]; then LISTEN_IP=$(default_ip || true); fi
  valid_ipv4 "$LISTEN_IP" && local_ips | grep -Fxq -- "$LISTEN_IP" || die NO_LOCAL_IP "$LISTEN_IP"

  local existing_zone
  existing_zone=$(zone_hint)
  if [[ $OP == install && -e $DB && -n $existing_zone && $existing_zone != "$ZONE" && $ON_ZONE_MISMATCH != replace ]]; then
    die ZONE_MISMATCH "$existing_zone"
  fi
  if systemctl is-active --quiet soar-server.service; then
    OLD_WAS_ACTIVE=1
    [[ $ALLOW_MIGRATE == 1 ]] || die OLD_SOAR
  fi
  read_listeners
  local conflict
  conflict=$(port_conflicts u "$DNS_PORT" "$LISTEN_IP"; port_conflicts t "$DNS_PORT" "$LISTEN_IP")
  if (( OLD_WAS_ACTIVE )) && [[ $(owner_of "$conflict") == soar-server ]]; then conflict=''; fi
  [[ -z $conflict ]] || die PORT53_BUSY "$(owner_of "$(head -n1 <<< "$conflict")")"
  emit preflight ok
}

# Keeps a port or listener the panel menu may have changed. Legacy 0.0.0.0 units migrate to LISTEN_IP.
read_listeners() {
  local previous_dns previous_bind port
  previous_dns=$(unit_flag soar-panel.service dns-listen)
  previous_bind=$(unit_flag soar-panel.service listen)
  if [[ -n $previous_dns ]]; then DNS_PORT=${previous_dns##*:}; fi
  [[ $DNS_PORT =~ ^[1-9][0-9]{0,4}$ ]] || DNS_PORT=53
  if [[ -n $previous_bind ]]; then PANEL_BIND=$previous_bind; return 0; fi
  for port in 2053 2054 2055 8053 9053; do
    if [[ -z $(port_conflicts t "$port" 127.0.0.1) ]]; then PANEL_BIND=127.0.0.1:$port; return 0; fi
  done
  die PANEL_PORT_BUSY
}

stage_deps() {
  emit deps start
  local tool missing=0 output
  for tool in systemctl sha256sum install useradd awk flock tar stat; do
    command -v "$tool" >/dev/null || die MISSING_TOOL "$tool"
  done
  for tool in dig ip ss curl; do command -v "$tool" >/dev/null || missing=1; done
  [[ -r /etc/ssl/certs/ca-certificates.crt ]] || missing=1
  if (( missing )); then
    command -v apt-get >/dev/null || die MISSING_TOOL apt-get
    # Waits for unattended-upgrades instead of killing it; killing dpkg corrupts its database.
    if [[ -n $(dpkg --audit 2>/dev/null || true) ]]; then
      timeout 300 dpkg --force-confold --configure -a >/dev/null 2>&1 || true
    fi
    local -a opts=(-o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 -o Acquire::ForceIPv4=true -o Dpkg::Options::=--force-confold)
    output=$(timeout 420 apt-get "${opts[@]}" update 2>&1) || emit deps warn APT_UPDATE_FAILED "$(grep -E '^(E|Err):' <<< "$output" | tail -n1)"
    output=$(timeout 600 apt-get "${opts[@]}" install -y --no-install-recommends ca-certificates curl dnsutils iproute2 2>&1) ||
      die APT_FAILED "$(grep -E '^E:' <<< "$output" | tail -n1)"
  fi
  emit deps ok
}

installed_version() { [[ -x $BIN ]] && timeout 5 "$BIN" version 2>/dev/null || true; }

stage_fetch() {
  emit fetch start
  local current arch asset url expected archive
  current=$(installed_version)
  if [[ -z $VERSION ]]; then VERSION=$current; fi
  [[ -n $VERSION ]] || die JOB_INVALID 'VERSION is required when no panel binary is installed'
  # Never downgrade a panel the user upgraded from inside the panel, even with soar-check missing.
  local newest
  newest=$(printf '%s\n%s\n' "$current" "$VERSION" | sort -V | tail -n1)
  if [[ -n $current && $newest == "$current" && ( $current != "$VERSION" || -x $CHECK_BIN ) ]]; then
    VERSION=$current
    NEEDS_BINS=0
    emit fetch ok KEEP_BINARIES "$current"
    return 0
  fi
  NEEDS_BINS=1
  arch=$(detect_arch)
  asset=soar-panel-$VERSION-linux-$arch.tar.gz
  url=https://github.com/WhiteDNS/Soar-Server/releases/download/panel-v$VERSION/$asset
  WORK_DIR=$(mktemp -d /var/tmp/whitedns-agent.XXXXXX)
  archive=$BUNDLE_UPLOAD
  if [[ ! -s $archive ]]; then
    archive=$WORK_DIR/$asset
    curl -fsSL --connect-timeout 15 --max-time 300 --retry 3 -o "$archive" "$url" 2>/dev/null || die NEED_BUNDLE "$asset"
  fi
  expected=$BUNDLE_SHA256
  if [[ -z $expected ]]; then
    expected=$(curl -fsSL --connect-timeout 15 --max-time 60 --retry 3 "$url.sha256" 2>/dev/null | awk '{print $1}') || expected=''
    [[ $expected =~ ^[a-f0-9]{64}$ ]] || die CHECKSUM_UNAVAILABLE "$asset"
  fi
  [[ $(sha256sum -- "$archive" | awk '{print $1}') == "$expected" ]] || {
    rm -f -- "$BUNDLE_UPLOAD"
    die CHECKSUM_MISMATCH "$asset"
  }
  tar -xzf "$archive" -C "$WORK_DIR" || die BUNDLE_INVALID 'cannot extract'
  BUNDLE_ROOT=$WORK_DIR/soar-panel-$VERSION-linux-$arch
  [[ $(cat "$BUNDLE_ROOT/ARCH" 2>/dev/null) == "$arch" ]] || die BUNDLE_INVALID 'architecture mismatch'
  bash "$BUNDLE_ROOT/panel-install.sh" --check-bundle >/dev/null 2>&1 || die BUNDLE_INVALID 'bundle checksums failed'
  rm -f -- "$BUNDLE_UPLOAD"
  emit fetch ok - "$VERSION"
}

snapshot() {
  local index path
  BACKUP=/root/soar-panel-backup-$(date -u +%Y%m%dT%H%M%SZ)-$$
  install -d -m 0700 "$BACKUP"
  for index in "${!TRANSACTION_FILES[@]}"; do
    path=${TRANSACTION_FILES[$index]}
    printf 'file-%s\t%s\n' "$index" "$path" >> "$BACKUP/paths.tsv"
    [[ ! -e $path ]] || cp -p -- "$path" "$BACKUP/file-$index"
  done
  TRANSACTION=1
}

rollback() {
  local index path unit port ok=1
  emit activate warn ROLLING_BACK
  systemctl stop soar-panel.service 2>/dev/null || true
  systemctl stop soar-panel-ops.service 2>/dev/null || true
  # The panel replaced by a fresh install comes back with its own data.
  if [[ -d $BACKUP/replaced-data ]]; then rm -rf -- "$DATA"; mv -- "$BACKUP/replaced-data" "$DATA" || ok=0; fi
  for index in "${!TRANSACTION_FILES[@]}"; do
    path=${TRANSACTION_FILES[$index]}
    if [[ -f $BACKUP/file-$index ]]; then cp -p -- "$BACKUP/file-$index" "$path" || ok=0
    else rm -f -- "$path" || ok=0; fi
  done
  systemctl daemon-reload || ok=0
  for port in "${FIREWALL_ADDED[@]:-}"; do
    [[ -z $port ]] || ufw --force delete allow "$port" comment "$UFW_COMMENT" >/dev/null 2>&1 || ok=0
  done
  for unit in soar-panel.service soar-panel-ops.service soar-server.service; do
    if [[ ${WAS_ENABLED[$unit]:-0} == 1 ]]; then systemctl enable "$unit" >/dev/null 2>&1 || ok=0
    else systemctl disable "$unit" >/dev/null 2>&1 || true; fi
    systemctl reset-failed "$unit" 2>/dev/null || true
  done
  (( ! OPS_WAS_ACTIVE )) || systemctl start soar-panel-ops.service || ok=0
  (( ! PANEL_WAS_ACTIVE )) || systemctl start soar-panel.service || ok=0
  (( ! OLD_WAS_ACTIVE )) || systemctl start soar-server.service || ok=0
  (( ok ))
}

wait_health() {
  for _ in {1..45}; do
    if systemctl is-active --quiet soar-panel.service && systemctl is-active --quiet soar-panel-ops.service &&
      curl --silent --fail --max-time 2 --unix-socket /run/soar-panel-ops/control.sock http://localhost/status >/dev/null 2>&1 &&
      timeout 8 "$BIN" health --db "$DB" --listen "$PANEL_BIND" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

write_units() {
  cat > "$SERVICE" <<UNIT
[Unit]
Description=WhiteDNS Soar Management Panel
After=network-online.target
Wants=network-online.target
Wants=soar-panel-ops.service

[Service]
Type=simple
User=soar-panel
Group=soar-panel
ExecStart=$BIN run --db $DB --dns-listen $LISTEN_IP:$DNS_PORT --listen $PANEL_BIND --trust-loopback-proxy
Restart=on-failure
RestartSec=3
TimeoutStopSec=10
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$DATA
# Go net.InterfaceAddrs needs NETLINK; without it Lantern PublicOnly fails closed.
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
UMask=0077
LimitNOFILE=8192

[Install]
WantedBy=multi-user.target
UNIT
  cat > "$OPS_SERVICE" <<UNIT
[Unit]
Description=WhiteDNS private panel maintenance service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=soar-panel
ExecStart=/usr/local/bin/soar-panel-ops --health-address $PANEL_BIND --dns-port $DNS_PORT
Restart=on-failure
RestartSec=3
RuntimeDirectory=soar-panel-ops
RuntimeDirectoryMode=0750
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/usr/local/bin $DATA $STATE /run/soar-panel-ops
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
  chmod 0644 "$SERVICE" "$OPS_SERVICE"
  rm -f -- "$UNITS/soar-panel.service.d/90-management.conf" "$UNITS/soar-panel-ops.service.d/90-management.conf"
}

open_firewall() {
  local status port
  command -v ufw >/dev/null || return 0
  status=$(ufw status 2>/dev/null) || return 1
  [[ $status == *'Status: active'* ]] || return 0
  for port in "$DNS_PORT/udp" "$DNS_PORT/tcp"; do
    if ! awk -v port="$port" '$1==port && $2=="ALLOW" && $3=="Anywhere"{found=1}END{exit !found}' <<< "$status"; then
      ufw allow "$port" comment "$UFW_COMMENT" >/dev/null || return 1
      FIREWALL_ADDED+=("$port")
    fi
  done
}

stage_activate() {
  emit activate start
  local unit existing_zone rewrite_units=0
  for unit in soar-panel.service soar-panel-ops.service soar-server.service; do
    WAS_ENABLED[$unit]=0
    if systemctl is-enabled --quiet "$unit" 2>/dev/null; then WAS_ENABLED[$unit]=1; fi
  done
  systemctl is-active --quiet soar-panel-ops.service && OPS_WAS_ACTIVE=1
  systemctl is-active --quiet soar-panel.service && PANEL_WAS_ACTIVE=1
  (( ! OPS_WAS_ACTIVE )) || systemctl stop soar-panel-ops.service
  (( ! PANEL_WAS_ACTIVE )) || systemctl stop soar-panel.service
  PANEL_WANTED=1
  snapshot

  # With the panel stopped the database lock is free, so this answer is authoritative.
  if [[ -e $DB && -x $BIN ]]; then
    existing_zone=$(timeout 10 "$BIN" zone --db "$DB" 2>/dev/null || true)
    if [[ $OP == install && -n $existing_zone && $existing_zone != "$ZONE" ]]; then
      [[ $ON_ZONE_MISMATCH == replace ]] || die ZONE_MISMATCH "$existing_zone"
      mv -- "$DATA" "$BACKUP/replaced-data"
    fi
  fi

  id soar-panel >/dev/null 2>&1 || useradd --system --home-dir "$DATA" --shell /usr/sbin/nologin soar-panel
  install -d -o soar-panel -g soar-panel -m 0700 "$DATA"
  if [[ -n $PUBLIC_IP ]]; then printf '%s\n' "$PUBLIC_IP" > "$DATA/public-ip"; chmod 0600 "$DATA/public-ip"; fi
  if (( NEEDS_BINS )); then
    local arch
    arch=$(detect_arch)
    install -m 0755 "$BUNDLE_ROOT/bin/linux-$arch/soar-panel" "$BIN"
    install -m 0755 "$BUNDLE_ROOT/bin/linux-$arch/soar-panel-ops" /usr/local/bin/soar-panel-ops
    install -m 0755 "$BUNDLE_ROOT/bin/linux-$arch/soar-check" "$CHECK_BIN"
    install -m 0755 "$BUNDLE_ROOT/panel-security.sh" /usr/local/bin/soar-panel-security
    install -m 0755 "$BUNDLE_ROOT/panel-menu.sh" /usr/local/bin/soar-panel-menu
  fi

  if [[ ! -e $DB ]]; then
    FRESH=1
    "$BIN" init --db "$DB" --zone "$ZONE" --nameserver "$NS_HOST" --public-ip "$PUBLIC_IP" \
      --resolvers "$RESOLVERS" --admin "$ADMIN_USER" --password-file "$SECRET" >/dev/null || die PANEL_INIT_FAILED
    ADMIN_CHANGED=1
  elif [[ $RESET_ADMIN == 1 ]]; then
    [[ -s $SECRET ]] || die JOB_INVALID 'admin secret is required for a password reset'
    "$BIN" admin-reset --db "$DB" --admin "$ADMIN_USER" --password-file "$SECRET" >/dev/null || die ADMIN_RESET_FAILED
    ADMIN_CHANGED=1
  fi

  # A second run must keep the private address the user already bookmarked.
  if [[ ! -e $ACCESS || -z $(access_field base_path) ]]; then
    "$BIN" configure-access --db "$DB" --listen "$PANEL_BIND" --random-path >/dev/null || die ACCESS_FAILED
  fi
  chown -R soar-panel:soar-panel "$DATA"
  chmod 0600 "$DB" "$ACCESS"

  if [[ ! -f $SERVICE || ! -f $OPS_SERVICE ]] || [[ $(unit_flag soar-panel.service dns-listen) == 0.0.0.0:* ]]; then rewrite_units=1; fi
  (( ! rewrite_units )) || write_units
  (( ! OLD_WAS_ACTIVE )) || systemctl stop soar-server.service
  systemctl daemon-reload
  open_firewall || die FIREWALL_FAILED
  fault activate
  systemctl restart soar-panel-ops.service
  systemctl is-active --quiet soar-panel-ops.service || die OPS_START_FAILED
  systemctl start soar-panel.service
  wait_health || die PANEL_UNHEALTHY "$(journalctl -u soar-panel -n 3 --no-pager -o cat 2>/dev/null | tail -n1)"

  local dns_bind
  dns_bind=$(unit_flag soar-panel.service dns-listen)
  ss -H -lun | awk -v target="$dns_bind" '$4==target{found=1}END{exit !found}' || die DNS_LISTENER_MISSING "$dns_bind/udp"
  ss -H -ltn | awk -v target="$dns_bind" '$4==target{found=1}END{exit !found}' || die DNS_LISTENER_MISSING "$dns_bind/tcp"
  systemctl enable soar-panel.service soar-panel-ops.service >/dev/null 2>&1
  (( ! OLD_WAS_ACTIVE )) || systemctl disable soar-server.service >/dev/null 2>&1
  ACTIVATED=1
  if [[ ! -e /usr/local/bin/whitedns && ! -L /usr/local/bin/whitedns ]]; then
    ln -s /usr/local/bin/soar-panel-menu /usr/local/bin/whitedns
  fi
  emit activate ok
}

nginx_other_sites() { find /etc/nginx/sites-enabled /etc/nginx/conf.d -mindepth 1 -maxdepth 1 ! -name soar-panel ! -name default 2>/dev/null | grep -q .; }

# Removes only the site this bot wrote; nginx stays running if it serves anything else.
retire_legacy_nginx() {
  [[ -f $NGINX_SITE ]] || return 0
  cp -p -- "$NGINX_SITE" "$BACKUP/nginx-site" 2>/dev/null || true
  rm -f -- "$NGINX_LINK" "$NGINX_SITE"
  if nginx_other_sites; then systemctl reload nginx 2>/dev/null || true
  else systemctl disable --now nginx >/dev/null 2>&1 || true; touch "$BACKUP/nginx-was-ours" 2>/dev/null || true; fi
}
restore_legacy_nginx() {
  [[ -f $BACKUP/nginx-site ]] || return 0
  cp -p -- "$BACKUP/nginx-site" "$NGINX_SITE"
  ln -sf "$NGINX_SITE" "$NGINX_LINK"
  if [[ -e $BACKUP/nginx-was-ours ]]; then systemctl enable --now nginx >/dev/null 2>&1 || true
  else systemctl reload nginx 2>/dev/null || true; fi
}

domain_points_here() {
  local resolver answer
  for _ in {1..18}; do
    for resolver in 1.1.1.1 8.8.8.8; do
      answer=$(dig +short +time=2 +tries=1 "@$resolver" A "$PANEL_DOMAIN" 2>/dev/null || true)
      if grep -Fxq -- "$PUBLIC_IP" <<< "$answer"; then return 0; fi
    done
    sleep 5
  done
  return 1
}

stage_https() {
  emit https start
  local current_domain output status=0 saved
  [[ -n $PUBLIC_IP ]] || PUBLIC_IP=$(cat "$DATA/public-ip" 2>/dev/null || true)
  current_domain=$(access_field domain)
  if [[ $(access_field https) == true ]]; then emit https ok KEEP_HTTPS "$current_domain"; return 0; fi
  if [[ -z $PANEL_DOMAIN ]]; then warn https NO_PANEL_DOMAIN; return 0; fi
  if ! domain_points_here; then warn https DNS_NOT_READY "$PANEL_DOMAIN"; return 0; fi

  retire_legacy_nginx
  local busy
  busy=$(port_conflicts t 80; port_conflicts t 443)
  if [[ -n $busy ]]; then
    restore_legacy_nginx
    warn https HTTPS_PORTS_BUSY "$(owner_of "$(head -n1 <<< "$busy")")"
    return 0
  fi
  systemctl stop soar-panel.service
  saved=$BACKUP/access-before-https.json
  cp -p -- "$ACCESS" "$saved"
  local -a extra=()
  [[ -z $ADMIN_EMAIL ]] || extra=(--email "$ADMIN_EMAIL")
  output=$(timeout 280 "$BIN" configure-access --db "$DB" --listen "$PANEL_BIND" --domain "$PANEL_DOMAIN" "${extra[@]}" 2>&1) || status=$?
  chown -R soar-panel:soar-panel "$DATA"
  if (( status )); then
    cp -p -- "$saved" "$ACCESS"
    systemctl start soar-panel.service
    wait_health || die PANEL_UNHEALTHY 'after failed certificate request'
    restore_legacy_nginx
    warn https CERT_FAILED "$(tail -n1 <<< "$output")"
    return 0
  fi
  systemctl start soar-panel.service
  if ! wait_health; then
    systemctl stop soar-panel.service
    cp -p -- "$saved" "$ACCESS"
    chown soar-panel:soar-panel "$ACCESS"
    systemctl start soar-panel.service
    wait_health || die PANEL_UNHEALTHY 'after reverting HTTPS'
    restore_legacy_nginx
    warn https CERT_FAILED 'panel unhealthy with HTTPS; previous address restored'
    return 0
  fi
  emit https ok
}

remove_probe() {
  [[ -n $PROBE_ID ]] || return 0
  systemctl stop soar-panel.service
  "$BIN" remove-install-probe --db "$DB" --probe-id "$PROBE_ID" >/dev/null || return 1
  chown soar-panel:soar-panel "$DB"
  PROBE_ID=''
  systemctl start soar-panel.service
  wait_health
}

run_check() {
  local code=$1 output
  shift
  if ! output=$(timeout 90 "$CHECK_BIN" "$@" 2>&1); then
    warn verify "$code" "$(tail -n1 <<< "$output")"
    return 1
  fi
}

stage_verify() {
  emit verify start
  local identity zone key profile master local_dns
  if [[ ! -x $CHECK_BIN ]]; then warn verify CHECK_TOOL_MISSING; return 0; fi
  profile=$AGENT_DIR/probe-cotten
  master=$AGENT_DIR/probe-master
  local_dns=$(unit_flag soar-panel.service dns-listen)
  systemctl stop soar-panel.service
  if ! identity=$("$BIN" create-install-probe --db "$DB" --output "$profile" --masterdns-output "$master" 2>/dev/null); then
    systemctl start soar-panel.service
    wait_health || die PANEL_UNHEALTHY 'after probe failure'
    warn verify PROBE_FAILED
    return 0
  fi
  read -r PROBE_ID zone key _ <<< "$identity"
  chown soar-panel:soar-panel "$DB"
  systemctl start soar-panel.service
  wait_health || die PANEL_UNHEALTHY 'with probe account'

  run_check TUNNEL_LOCAL_FAILED -zone "$zone" -pubkey "$key" -resolver "$local_dns" -tcp off -timeout 40s || true
  run_check COTTEN_LOCAL_FAILED -cotten-profile-file "$profile" -resolver "$local_dns" -tcp off -timeout 40s || true
  run_check MASTERDNS_LOCAL_FAILED -masterdns-profile-file "$master" -resolver "$local_dns" -tcp off -timeout 40s || true
  # The recursive path is what real clients use; failure usually means UDP/53 is filtered upstream.
  run_check TUNNEL_RECURSIVE_FAILED -zone "$zone" -pubkey "$key" -resolver "$RESOLVERS" -tcp auto -timeout 60s || true

  rm -f -- "$profile" "$master"
  remove_probe || die PANEL_UNHEALTHY 'after removing probe account'
  emit verify ok
}

cmd_converge() {
  stage_preflight
  stage_deps
  stage_fetch
  stage_activate
  rm -rf -- "${WORK_DIR:-/nonexistent}"
  WORK_DIR=''
  rm -f -- "$SECRET"
  stage_https
  stage_verify
}

# --- uninstall -----------------------------------------------------------------
restore_system_dns() {
  local had_stub=0 saved
  if [[ -f /etc/systemd/resolved.conf.d/no-stub.conf ]]; then rm -f /etc/systemd/resolved.conf.d/no-stub.conf; had_stub=1; fi
  if grep -qE '^DNSStubListener=no' /etc/systemd/resolved.conf 2>/dev/null; then
    sed -i 's/^DNSStubListener=no/#DNSStubListener=yes/' /etc/systemd/resolved.conf
    had_stub=1
  fi
  (( had_stub )) || return 0
  systemctl restart systemd-resolved 2>/dev/null || true
  [[ -f /etc/resolv.conf && ! -L /etc/resolv.conf && -e /run/systemd/resolve/stub-resolv.conf ]] || return 0
  saved=$(mktemp /var/tmp/resolv.XXXXXX)
  cp -p /etc/resolv.conf "$saved"
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  if ! timeout 8 getent hosts github.com >/dev/null 2>&1; then
    rm -f /etc/resolv.conf
    cp -p "$saved" /etc/resolv.conf
  fi
  rm -f -- "$saved"
}

remove_owned_firewall_rules() {
  local rule
  command -v ufw >/dev/null || return 0
  while IFS= read -r rule; do
    [[ -n $rule ]] && ufw --force delete allow "$rule" >/dev/null 2>&1 || true
  done < <(ufw status 2>/dev/null | grep -E "# ($UFW_OWNED)\$" | awk '$2=="ALLOW" && $3=="Anywhere"{print $1}' | sort -u)
}

cmd_uninstall() {
  emit remove start
  [[ $EUID == 0 ]] || die NOT_ROOT
  exec 9>/run/lock/soar-panel-install.lock
  flock -n 9 || die BUSY 'another panel installation is running'
  install -d -m 0700 "$STATE"
  exec 8>"$STATE/maintenance.lock"
  flock -n 8 || die BUSY 'a panel maintenance operation is running'
  BACKUP=/root/soar-panel-uninstall-$(date -u +%Y%m%dT%H%M%SZ)-$$
  install -d -m 0700 "$BACKUP"
  systemctl stop soar-panel.service soar-panel-ops.service 2>/dev/null || true
  systemctl disable soar-panel.service soar-panel-ops.service >/dev/null 2>&1 || true
  [[ ! -e $DATA ]] || cp -a -- "$DATA" "$BACKUP/data"
  local unit
  for unit in soar-panel soar-panel-ops; do
    [[ ! -e $UNITS/$unit.service ]] || cp -a -- "$UNITS/$unit.service" "$BACKUP/"
    rm -f -- "$UNITS/$unit.service"
    rm -rf -- "${UNITS:?}/$unit.service.d"
  done
  rm -f -- "$BIN" /usr/local/bin/soar-panel-ops /usr/local/bin/soar-panel-security /usr/local/bin/soar-panel-menu "$CHECK_BIN"
  if [[ -L /usr/local/bin/whitedns && $(readlink /usr/local/bin/whitedns) == /usr/local/bin/soar-panel-menu ]]; then rm -f /usr/local/bin/whitedns; fi
  systemctl daemon-reload
  systemctl reset-failed soar-panel.service soar-panel-ops.service 2>/dev/null || true
  retire_legacy_nginx
  remove_owned_firewall_rules
  restore_system_dns
  rm -f -- "$APT_LEGACY_LIST"
  if [[ $UNINSTALL_MODE == purge ]]; then
    rm -rf -- "$DATA"
    # Keep the locked inode in place so another installer cannot race this uninstall.
    find "$STATE" -mindepth 1 -maxdepth 1 ! -name maintenance.lock -exec rm -rf -- {} +
    userdel soar-panel 2>/dev/null || true
  fi
  emit remove ok
}

# --- result --------------------------------------------------------------------
panel_url() {
  [[ -x $BIN && -n $PANEL_BIND ]] || return 0
  timeout 10 "$BIN" access-url --db "$DB" --listen "$PANEL_BIND" 2>/dev/null || true
}

write_result() {
  local status=$1 tmp warning
  tmp=$RESULT.tmp
  {
    echo "status=$status"
    echo "op=$OP"
    echo "code=$FAIL_CODE"
    echo "detail=$FAIL_DETAIL"
    echo "backup=$BACKUP"
    echo "fresh=$FRESH"
    echo "admin_changed=$ADMIN_CHANGED"
    if [[ $OP != uninstall && $status == ok ]]; then
      echo "version=$VERSION"
      echo "zone=$ZONE"
      echo "panel_url=$(panel_url)"
      echo "https=$(access_field https)"
      echo "panel_bind=$PANEL_BIND"
      echo "dns_port=$DNS_PORT"
    fi
    for warning in "${WARNINGS[@]:-}"; do [[ -z $warning ]] || echo "warning=$warning"; done
  } > "$tmp"
  mv -f -- "$tmp" "$RESULT"
}

on_exit() {
  local rc=$? status=ok
  trap - EXIT INT TERM
  if (( rc )); then
    status=failed
    [[ -n $FAIL_CODE ]] || FAIL_CODE=UNEXPECTED FAIL_DETAIL="exit $rc near line ${BASH_LINENO[0]:-0}"
    if (( TRANSACTION && ! ACTIVATED )); then
      if rollback; then status=rolled_back; else status=rollback_incomplete; fi
    elif (( PANEL_WANTED )) && ! systemctl is-active --quiet soar-panel.service; then
      systemctl start soar-panel.service 2>/dev/null || true
    fi
    emit "$OP" fail "$FAIL_CODE" "$FAIL_DETAIL"
  fi
  rm -f -- "$SECRET" "$JOB_ENV" "$AGENT_DIR/probe-cotten" "$AGENT_DIR/probe-master"
  rm -rf -- "${WORK_DIR:-/nonexistent}"
  write_result "$status"
  emit "$OP" end "$status"
  exit "$rc"
}

main() {
  OP=${1:-}
  case "$OP" in
    probe) shift; cmd_probe "$@"; return 0 ;;
    install|repair|uninstall) ;;
    *) printf 'usage: agent.sh probe [ssh-host] | install | repair | uninstall\n' >&2; exit 2 ;;
  esac
  install -d -m 0700 "$AGENT_DIR"
  rm -f -- "$RESULT"
  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  load_job
  if [[ $OP == uninstall ]]; then cmd_uninstall; else cmd_converge; fi
}

# BASH_SOURCE is empty when the script arrives on stdin, as probe does.
if [[ ${BASH_SOURCE[0]:-$0} == "$0" ]]; then main "$@"; fi
