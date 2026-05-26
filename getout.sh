#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="0.1.3"
INSTALL_PATH="/usr/local/bin/getout"
UPDATE_URL="https://raw.githubusercontent.com/xiaochengshiguduo/getout/main/getout.sh"
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

APP="getout"
CONF_DIR="/etc/getout"
MODE_FILE="$CONF_DIR/mode"
SERVER_CONF="$CONF_DIR/server.conf"
CLIENT_CONF="$CONF_DIR/client.conf"
TUN_CONF="$CONF_DIR/tun2socks.yaml"
ROUTES_UP="$CONF_DIR/routes-up.sh"
ROUTES_DOWN="$CONF_DIR/routes-down.sh"
RUNTIME_DNS_SERVERS=("8.8.8.8" "1.1.1.1")
RUNTIME_DNS_V6_SERVERS=("2001:4860:4860::8888" "2606:4700:4700::1111")
RESOLV_ORIG="$CONF_DIR/resolv.conf.orig"

GOST_BIN="/usr/local/bin/getout-gost"
TUN_BIN="/usr/local/bin/getout-tun2socks"
GOST_SERVICE="/etc/systemd/system/getout-gost.service"
TUN_SERVICE="/etc/systemd/system/getout-tun.service"

GOST_VERSION="2.11.5"
HEV_VERSION="2.15.0"
TABLE_ID="20"
MARK_ID="438"
TUN_NAME="tun0"
DNS64_SERVERS=(
  "2001:67c:2960::64"
  "2a00:1098:2b::1"
  "2a00:1098:2c::1"
  "2a01:4f8:c2c:123f::1"
  "2001:67c:2960::6464"
)

info() { echo -e "${BLUE}[信息]${NC} $*"; }
success() { echo -e "${GREEN}[成功]${NC} $*"; }
warn() { echo -e "${YELLOW}[警告]${NC} $*"; }
err() { echo -e "${RED}[错误]${NC} $*" >&2; }
fatal() { err "$*"; exit 1; }

running_from_install_path() {
  local src="${BASH_SOURCE[0]:-$0}" real_src real_install
  [ "$src" = "$INSTALL_PATH" ] && return 0
  if command -v realpath >/dev/null 2>&1; then
    real_src="$(realpath "$src" 2>/dev/null || true)"
    real_install="$(realpath "$INSTALL_PATH" 2>/dev/null || true)"
    [ -n "$real_src" ] && [ -n "$real_install" ] && [ "$real_src" = "$real_install" ] && return 0
  fi
  return 1
}

extract_script_version() {
  sed -n 's/^SCRIPT_VERSION="\([^"]\+\)".*/\1/p' "$1" | head -n1
}

install_from_update_url() {
  local mode="${1:-install}" tmp version download_url
  tmp="/tmp/getout-${mode}.$$"
  download_url="$UPDATE_URL"
  if [[ "$download_url" == http://* || "$download_url" == https://* ]]; then
    download_url="${download_url}?v=${SCRIPT_VERSION}&t=$(date +%s)"
  fi
  trap 'rm -f "$tmp"' RETURN EXIT

  rm -f "$tmp"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 20 --retry 2 --retry-delay 1 "$download_url" -o "$tmp" || fatal "getout 下载失败。"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$download_url" || fatal "getout 下载失败。"
  else
    fatal "未找到 curl 或 wget，无法下载安装 getout。"
  fi

  [ -s "$tmp" ] || fatal "getout 下载结果为空。"
  bash -n "$tmp" || fatal "getout 语法校验失败，已取消安装。"
  grep -q 'getout 管理面板' "$tmp" || fatal "getout 特征校验失败，已取消安装。"
  grep -q '^SCRIPT_VERSION=' "$tmp" || fatal "getout 版本校验失败，已取消安装。"
  grep -q '^UPDATE_URL=' "$tmp" || fatal "getout 更新源校验失败，已取消安装。"
  version="$(extract_script_version "$tmp")"
  [ -n "$version" ] || fatal "无法读取 getout 版本号，已取消安装。"

  install -m 0755 "$tmp" "$INSTALL_PATH"
  rm -f "$tmp"
  trap - RETURN EXIT

  if [ "$mode" = "update" ]; then
    success "getout 已更新，当前版本 ${version}。"
  else
    success "已安装全局命令：getout。"
  fi
}

ensure_global_command() {
  running_from_install_path && return 0
  install_from_update_url install
}

update_getout() {
  require_root
  install_from_update_url update
}

require_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || fatal "请使用 root 权限运行：sudo bash $0"
}

require_debian() {
  [ -r /etc/os-release ] || fatal "无法识别系统。当前脚本仅支持 Debian。"
  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID:-}" = "debian" ] || fatal "当前系统是 ${PRETTY_NAME:-unknown}，此脚本仅支持 Debian。"
}

install_deps() {
  local missing=() cmd pkg
  declare -A map=(
    [curl]=curl [gzip]=gzip [gunzip]=gzip [ip]=iproute2 [ss]=iproute2
    [systemctl]=systemd [sysctl]=procps [awk]=mawk [grep]=grep [sed]=sed
  )
  for cmd in "${!map[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("${map[$cmd]}")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    info "安装依赖：${missing[*]} ca-certificates"
    apt-get update -y
    apt-get install -y ca-certificates "${missing[@]}"
  fi
}

ensure_tun() {
  [ -c /dev/net/tun ] || fatal "未检测到 /dev/net/tun，请先在 VPS 控制面板开启 TUN。"
}

arch_gost() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "armv8" ;;
    *) fatal "gost 不支持当前架构：$(uname -m)" ;;
  esac
}

arch_hev() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) fatal "hev-socks5-tunnel 不支持当前架构：$(uname -m)" ;;
  esac
}

with_dns64_resolv() {
  local dns="$1" orig rc
  shift
  orig="$(cat /etc/resolv.conf 2>/dev/null || true)"
  printf 'nameserver %s\noptions timeout:3 attempts:2\n' "$dns" > /etc/resolv.conf || return 1
  "$@"
  rc=$?
  printf '%s\n' "$orig" > /etc/resolv.conf || true
  return "$rc"
}

download_dns64_only() {
  local url="$1" output="$2" dns tmp rc=1
  tmp="$(mktemp)"
  for dns in "${DNS64_SERVERS[@]}"; do
    info "通过 DNS64 下载：$dns"
    if with_dns64_resolv "$dns" curl -6 -fL --connect-timeout 15 --retry 2 --retry-delay 1 -o "$tmp" "$url"; then
      install -m 0644 "$tmp" "$output"
      rm -f "$tmp"
      return 0
    fi
    warn "DNS64 $dns 下载失败，尝试下一个。"
  done
  rm -f "$tmp"
  return "$rc"
}

download_gost() {
  local arch url tmp
  arch="$(arch_gost)"
  url="https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost-linux-${arch}-${GOST_VERSION}.gz"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  info "下载 gost：$url"
  download_dns64_only "$url" "$tmp" || fatal "gost 下载失败：所有 DNS64 服务器均不可用。"
  gunzip -c "$tmp" > "$GOST_BIN"
  chmod +x "$GOST_BIN"
  rm -f "$tmp"
  trap - RETURN
}

download_hev() {
  local arch url tmp
  arch="$(arch_hev)"
  url="https://github.com/heiher/hev-socks5-tunnel/releases/download/${HEV_VERSION}/hev-socks5-tunnel-linux-${arch}"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  info "下载 hev-socks5-tunnel：$url"
  download_dns64_only "$url" "$tmp" || fatal "hev-socks5-tunnel 下载失败：所有 DNS64 服务器均不可用。"
  install -m 0755 "$tmp" "$TUN_BIN"
  rm -f "$tmp"
  trap - RETURN
}

is_ipv6() { [[ "$1" == *:* ]]; }
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

strip_brackets() {
  local s="$1"
  s="${s#[}"
  s="${s%]}"
  echo "$s"
}

shell_quote() {
  printf '%q' "$1"
}

yaml_quote() {
  local s="$1"
  s="${s//\'/\'\'}"
  printf "'%s'" "$s"
}

systemd_escape_percent() {
  printf '%s' "$1" | sed 's/%/%%/g'
}

reject_url_unsafe() {
  local name="$1" value="$2"
  [[ "$value" != *[[:space:]]* ]] || fatal "$name 不能包含空白字符。"
  [[ "$value" != *"@"* ]] || fatal "$name 不能包含 @ 字符。"
}

ssh_remote_ip() {
  if [ -n "${SSH_CONNECTION:-}" ]; then
    awk '{print $1}' <<<"$SSH_CONNECTION"
  elif [ -n "${SSH_CLIENT:-}" ]; then
    awk '{print $1}' <<<"$SSH_CLIENT"
  else
    true
  fi
}

main_ipv4() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true
}

main_ipv6() {
  ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true
}

write_routes_scripts() {
  mkdir -p "$CONF_DIR"
  cat > "$ROUTES_UP" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CONF_DIR="/etc/getout"
# shellcheck disable=SC1091
[ -f "$CONF_DIR/client.conf" ] && . "$CONF_DIR/client.conf"
TABLE_ID="${TABLE_ID:-20}"
MARK_ID="${MARK_ID:-438}"
TUN_NAME="${TUN_NAME:-tun0}"
MODE="${MODE:-v4}"
RUNTIME_DNS_SERVERS="${RUNTIME_DNS_SERVERS:-2001:4860:4860::8888 2606:4700:4700::1111}"
RUNTIME_DNS_ENABLE="${RUNTIME_DNS_ENABLE:-1}"
RESOLV_ORIG="$CONF_DIR/resolv.conf.orig"

run() { "$@" 2>/dev/null || true; }
is_ipv6() { [[ "${1:-}" == *:* ]]; }
is_ipv4() { [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
add4_to_main() { [ -n "${1:-}" ] && run ip rule add to "$1" lookup main pref "$2"; }
add6_to_main() { [ -n "${1:-}" ] && run ip -6 rule add to "$1" lookup main pref "$2"; }
apply_runtime_dns() {
  [ "$RUNTIME_DNS_ENABLE" = "1" ] || return 0
  [ -f "$RESOLV_ORIG" ] || cat /etc/resolv.conf > "$RESOLV_ORIG" 2>/dev/null || true
  { for dns in $RUNTIME_DNS_SERVERS; do printf 'nameserver %s\n' "$dns"; done; printf 'options timeout:2 attempts:1\n'; } > /etc/resolv.conf 2>/dev/null || true
}

"$CONF_DIR/routes-down.sh" >/dev/null 2>&1 || true
apply_runtime_dns

# 避免 tun2socks 访问上游 SOCKS5 时被自己接管。
run ip rule add fwmark "$MARK_ID" lookup main pref 10
run ip -6 rule add fwmark "$MARK_ID" lookup main pref 10

# 保护当前 SSH 会话回包、SOCKS5 上游地址。
if is_ipv6 "${SSH_REMOTE_IP:-}"; then add6_to_main "${SSH_REMOTE_IP}/128" 5; elif is_ipv4 "${SSH_REMOTE_IP:-}"; then add4_to_main "${SSH_REMOTE_IP}/32" 5; fi
if is_ipv6 "${SOCKS_ADDRESS:-}"; then add6_to_main "${SOCKS_ADDRESS}/128" 6; elif is_ipv4 "${SOCKS_ADDRESS:-}"; then add4_to_main "${SOCKS_ADDRESS}/32" 6; fi
for dns in $RUNTIME_DNS_SERVERS; do if is_ipv6 "$dns"; then add6_to_main "$dns/128" 7; elif is_ipv4 "$dns"; then add4_to_main "$dns/32" 7; fi; done

# 保护本地/内网/链路本地/组播网段。
for cidr in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/4; do add4_to_main "$cidr" 16; done
for cidr in ::1/128 fe80::/10 fc00::/7 ff00::/8; do add6_to_main "$cidr" 16; done

# V4 全局代理。
run ip route add default dev "$TUN_NAME" table "$TABLE_ID"
run ip rule add lookup "$TABLE_ID" pref 20

# V4+V6 双栈全局代理。
if [ "$MODE" = "dual" ]; then
  run ip -6 route add default dev "$TUN_NAME" table "$TABLE_ID"
  run ip -6 rule add lookup "$TABLE_ID" pref 20
fi
EOF

  cat > "$ROUTES_DOWN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CONF_DIR="/etc/getout"
# shellcheck disable=SC1091
[ -f "$CONF_DIR/client.conf" ] && . "$CONF_DIR/client.conf"
TABLE_ID="${TABLE_ID:-20}"
MARK_ID="${MARK_ID:-438}"
TUN_NAME="${TUN_NAME:-tun0}"
RUNTIME_DNS_SERVERS="${RUNTIME_DNS_SERVERS:-2001:4860:4860::8888 2606:4700:4700::1111}"
RUNTIME_DNS_ENABLE="${RUNTIME_DNS_ENABLE:-1}"
RESOLV_ORIG="$CONF_DIR/resolv.conf.orig"

run() { "$@" 2>/dev/null || true; }
is_ipv6() { [[ "${1:-}" == *:* ]]; }
is_ipv4() { [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
del4_to_main() { [ -n "${1:-}" ] && run ip rule del to "$1" lookup main pref "$2"; }
del6_to_main() { [ -n "${1:-}" ] && run ip -6 rule del to "$1" lookup main pref "$2"; }
restore_dns() {
  [ "$RUNTIME_DNS_ENABLE" = "1" ] || return 0
  if [ -f "$RESOLV_ORIG" ]; then
    cat "$RESOLV_ORIG" > /etc/resolv.conf 2>/dev/null || true
    rm -f "$RESOLV_ORIG"
  fi
}

run ip rule del fwmark "$MARK_ID" lookup main pref 10
run ip -6 rule del fwmark "$MARK_ID" lookup main pref 10

if is_ipv6 "${SSH_REMOTE_IP:-}"; then del6_to_main "${SSH_REMOTE_IP}/128" 5; elif is_ipv4 "${SSH_REMOTE_IP:-}"; then del4_to_main "${SSH_REMOTE_IP}/32" 5; fi
if is_ipv6 "${SOCKS_ADDRESS:-}"; then del6_to_main "${SOCKS_ADDRESS}/128" 6; elif is_ipv4 "${SOCKS_ADDRESS:-}"; then del4_to_main "${SOCKS_ADDRESS}/32" 6; fi
for dns in $RUNTIME_DNS_SERVERS; do if is_ipv6 "$dns"; then del6_to_main "$dns/128" 7; elif is_ipv4 "$dns"; then del4_to_main "$dns/32" 7; fi; done

for cidr in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/4; do del4_to_main "$cidr" 16; done
for cidr in ::1/128 fe80::/10 fc00::/7 ff00::/8; do del6_to_main "$cidr" 16; done

run ip rule del lookup "$TABLE_ID" pref 20
run ip -6 rule del lookup "$TABLE_ID" pref 20
run ip route del default dev "$TUN_NAME" table "$TABLE_ID"
run ip -6 route del default dev "$TUN_NAME" table "$TABLE_ID"
restore_dns
EOF
  chmod +x "$ROUTES_UP" "$ROUTES_DOWN"
}

service_active() {
  systemctl is-active --quiet "$1" 2>/dev/null
}

service_enabled_text() {
  local out
  out="$(systemctl is-enabled "$1" 2>/dev/null || true)"
  [ -n "$out" ] && echo "$out" || echo disabled
}

current_mode() {
  [ -f "$MODE_FILE" ] && cat "$MODE_FILE" || echo none
}

server_active() { service_active getout-gost.service; }
tun_active() { service_active getout-tun.service; }
client_mode_active() {
  local mode="$(current_mode)"
  tun_active && [ "$mode" = "$1" ]
}

stop_server_keep_config() {
  systemctl stop getout-gost.service 2>/dev/null || true
  systemctl disable getout-gost.service 2>/dev/null || true
}

stop_client_keep_config() {
  systemctl stop getout-tun.service 2>/dev/null || true
  cleanup_rules
  systemctl disable getout-tun.service 2>/dev/null || true
}

prompt_server_info() {
  require_root; require_debian; install_deps
  mkdir -p "$CONF_DIR"
  local port user pass yn
  read -rp "请输入入口 SOCKS5 监听端口 [默认: 1080]: " port
  port="${port:-1080}"
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || fatal "端口无效：$port"

  read -rp "是否设置用户名密码? [Y/n]: " yn
  yn="${yn:-Y}"
  user=""; pass=""
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    read -rp "用户名: " user
    [ -n "$user" ] || fatal "用户名不能为空。"
    read -rsp "密码: " pass; echo
    [ -n "$pass" ] || fatal "密码不能为空。"
    reject_url_unsafe "用户名" "$user"
    reject_url_unsafe "密码" "$pass"
  fi

  {
    printf 'PORT=%s\n' "$(shell_quote "$port")"
    printf 'USERNAME=%s\n' "$(shell_quote "$user")"
    printf 'PASSWORD=%s\n' "$(shell_quote "$pass")"
  } > "$SERVER_CONF"
}

write_gost_service() {
  [ -f "$SERVER_CONF" ] || fatal "未找到入口配置，请先修改入口信息。"
  # shellcheck disable=SC1090
  . "$SERVER_CONF"
  local auth listen
  auth=""
  if [ -n "${USERNAME:-}" ]; then
    reject_url_unsafe "用户名" "$USERNAME"
    reject_url_unsafe "密码" "${PASSWORD:-}"
    auth="${USERNAME}:${PASSWORD}@"
  fi
  listen="$(systemd_escape_percent "socks5://${auth}:${PORT}")"
  cat > "$GOST_SERVICE" <<EOF
[Unit]
Description=Getout Gost SOCKS5 Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$GOST_BIN -L=$listen
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

start_server() {
  require_root; require_debian; install_deps
  mkdir -p "$CONF_DIR"
  stop_client_keep_config
  [ -x "$GOST_BIN" ] || download_gost
  [ -f "$SERVER_CONF" ] || prompt_server_info
  write_gost_service
  echo "server" > "$MODE_FILE"
  systemctl enable --now getout-gost.service
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    # shellcheck disable=SC1090
    . "$SERVER_CONF"
    ufw allow "${PORT}/tcp" >/dev/null || true
  fi
  sleep 1
  systemctl is-active --quiet getout-gost.service || fatal "getout-gost.service 启动失败，请查看：journalctl -u getout-gost.service -e"
  success "入口模式已启动。"
  status
}

stop_server() {
  require_root
  stop_server_keep_config
  success "入口模式已关闭。"
}

configure_server() {
  prompt_server_info
  [ -x "$GOST_BIN" ] || download_gost
  write_gost_service
  if server_active; then
    systemctl restart getout-gost.service
    systemctl enable getout-gost.service >/dev/null 2>&1 || true
    sleep 1
    systemctl is-active --quiet getout-gost.service || fatal "getout-gost.service 重启失败，请查看：journalctl -u getout-gost.service -e"
    success "入口信息已更新并立即应用。"
    status
  else
    success "入口信息已保存，启动入口模式后生效。"
    if tun_active; then
      warn "当前出口模式正在运行，入口信息不会影响当前出口模式。"
    fi
  fi
}

install_server() {
  start_server
}

has_default_ipv4_route() {
  ip -4 route show default 2>/dev/null | grep -q .
}

has_public_ipv4_exit() {
  local ip
  ip="$(curl -4 -s --connect-timeout 5 --max-time 8 https://api.ipify.org 2>/dev/null || curl -4 -s --connect-timeout 5 --max-time 8 http://v4.ident.me 2>/dev/null || true)"
  is_ipv4 "$ip"
}

runtime_dns_servers_text() {
  if has_default_ipv4_route || has_public_ipv4_exit; then
    printf '%s\n' "${RUNTIME_DNS_SERVERS[*]}"
  else
    printf '%s\n' "${RUNTIME_DNS_V6_SERVERS[*]}"
  fi
}

write_client_conf() {
  local mode="$1" address="$2" port="$3" username="$4" password="$5" ssh_ip v4 v6 runtime_dns
  ssh_ip="$(ssh_remote_ip || true)"
  v4="$(main_ipv4 || true)"
  v6="$(main_ipv6 || true)"
  runtime_dns="$(runtime_dns_servers_text)"
  mkdir -p "$CONF_DIR"
  {
    printf 'MODE=%s\n' "$(shell_quote "$mode")"
    printf 'SOCKS_ADDRESS=%s\n' "$(shell_quote "$address")"
    printf 'SOCKS_PORT=%s\n' "$(shell_quote "$port")"
    printf 'SOCKS_USERNAME=%s\n' "$(shell_quote "$username")"
    printf 'SOCKS_PASSWORD=%s\n' "$(shell_quote "$password")"
    printf 'SSH_REMOTE_IP=%s\n' "$(shell_quote "$ssh_ip")"
    printf 'MAIN_IPV4=%s\n' "$(shell_quote "$v4")"
    printf 'MAIN_IPV6=%s\n' "$(shell_quote "$v6")"
    printf 'TABLE_ID=%s\n' "$(shell_quote "$TABLE_ID")"
    printf 'MARK_ID=%s\n' "$(shell_quote "$MARK_ID")"
    printf 'TUN_NAME=%s\n' "$(shell_quote "$TUN_NAME")"
    printf 'RUNTIME_DNS_SERVERS=%s\n' "$(shell_quote "$runtime_dns")"
    printf 'RUNTIME_DNS_ENABLE=1\n'
  } > "$CLIENT_CONF"
}

ask_socks_config() {
  local mode="$1" address port username password
  read -rp "请输入 SOCKS5 服务器地址 IPv4/IPv6: " address
  address="$(strip_brackets "$address")"
  [ -n "$address" ] || fatal "SOCKS5 地址不能为空。"
  read -rp "请输入 SOCKS5 服务器端口 [默认: 1080]: " port
  port="${port:-1080}"
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || fatal "端口无效：$port"
  read -rp "用户名 [可留空]: " username
  password=""
  if [ -n "$username" ]; then
    read -rsp "密码: " password; echo
    reject_url_unsafe "用户名" "$username"
    reject_url_unsafe "密码" "$password"
  fi
  write_client_conf "$mode" "$address" "$port" "$username" "$password"
}

reuse_client_config_for_mode() {
  local mode="$1" address port username password
  [ -f "$CLIENT_CONF" ] || return 1
  # shellcheck disable=SC1090
  . "$CLIENT_CONF"
  address="${SOCKS_ADDRESS:-}"
  port="${SOCKS_PORT:-}"
  username="${SOCKS_USERNAME:-}"
  password="${SOCKS_PASSWORD:-}"
  [ -n "$address" ] && [ -n "$port" ] || return 1
  write_client_conf "$mode" "$address" "$port" "$username" "$password"
  return 0
}

write_tun_config() {
  # shellcheck disable=SC1090
  . "$CLIENT_CONF"
  cat > "$TUN_CONF" <<EOF
tunnel:
  name: $TUN_NAME
  mtu: 8500
  multi-queue: false
  ipv4: 198.18.0.1
  ipv6: 'fc00::1'

socks5:
  port: $SOCKS_PORT
  address: $(yaml_quote "$SOCKS_ADDRESS")
  udp: 'tcp'
  mark: $MARK_ID
EOF
  if [ -n "${SOCKS_USERNAME:-}" ]; then
    cat >> "$TUN_CONF" <<EOF
  username: $(yaml_quote "$SOCKS_USERNAME")
  password: $(yaml_quote "$SOCKS_PASSWORD")
EOF
  fi
  cat >> "$TUN_CONF" <<'EOF'

misc:
  log-level: warn
  limit-nofile: 65535
EOF
}

write_tun_service() {
  local mode="$1"
  cat > "$TUN_SERVICE" <<EOF
[Unit]
Description=Getout Tun2Socks Client ($mode)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/sbin/sysctl -w net.ipv4.conf.all.rp_filter=0
ExecStart=$TUN_BIN $TUN_CONF
ExecStartPost=/bin/sleep 1
ExecStartPost=$ROUTES_UP
ExecStopPost=$ROUTES_DOWN
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

start_client() {
  local mode="$1"
  require_root; require_debian; install_deps; ensure_tun
  mkdir -p "$CONF_DIR"
  stop_server_keep_config
  if tun_active; then
    systemctl stop getout-tun.service 2>/dev/null || true
    cleanup_rules
  fi
  [ -x "$TUN_BIN" ] || download_hev
  if ! reuse_client_config_for_mode "$mode"; then
    ask_socks_config "$mode"
  fi
  write_tun_config
  write_routes_scripts
  echo "$mode" > "$MODE_FILE"
  write_tun_service "$mode"
  systemctl enable --now getout-tun.service
  sleep 2
  systemctl is-active --quiet getout-tun.service || fatal "getout-tun.service 启动失败，请查看：journalctl -u getout-tun.service -e"
  success "${mode} 模式已启动。"
  status
}

stop_client() {
  local mode="$(current_mode)"
  require_root
  stop_client_keep_config
  case "$mode" in
    v4) success "V4 单栈模式已关闭。" ;;
    dual) success "V4+V6 双栈模式已关闭。" ;;
    *) success "出口模式已关闭。" ;;
  esac
}

configure_client() {
  require_root; require_debian; install_deps; ensure_tun
  mkdir -p "$CONF_DIR"
  local mode
  if tun_active; then
    mode="$(current_mode)"
    [ "$mode" = "v4" ] || [ "$mode" = "dual" ] || mode="v4"
  elif [ -f "$CLIENT_CONF" ]; then
    # shellcheck disable=SC1090
    . "$CLIENT_CONF"
    mode="${MODE:-v4}"
  else
    mode="v4"
  fi
  ask_socks_config "$mode"
  [ -x "$TUN_BIN" ] || download_hev
  write_tun_config
  write_routes_scripts
  write_tun_service "$mode"
  echo "$mode" > "$MODE_FILE"
  if tun_active; then
    systemctl stop getout-tun.service 2>/dev/null || true
    cleanup_rules
    systemctl enable --now getout-tun.service
    sleep 2
    systemctl is-active --quiet getout-tun.service || fatal "getout-tun.service 重启失败，请查看：journalctl -u getout-tun.service -e"
    success "出口信息已更新并立即应用。"
    status
  else
    success "出口信息已保存，启动 V4/双栈模式后生效。"
    if server_active; then
      warn "当前入口模式正在运行，出口信息不会影响当前入口模式。"
    fi
  fi
}

install_tun() {
  start_client "$1"
}

cleanup_rules() {
  [ -x "$ROUTES_DOWN" ] && "$ROUTES_DOWN" >/dev/null 2>&1 || true
}

restart_getout() {
  require_root
  if server_active; then
    systemctl restart getout-gost.service
    systemctl enable getout-gost.service >/dev/null 2>&1 || true
    systemctl disable getout-tun.service >/dev/null 2>&1 || true
    sleep 1
    systemctl is-active --quiet getout-gost.service || fatal "getout-gost.service 重启失败，请查看：journalctl -u getout-gost.service -e"
    success "入口模式已重启。"
    status
  elif tun_active; then
    cleanup_rules
    systemctl restart getout-tun.service
    systemctl enable getout-tun.service >/dev/null 2>&1 || true
    systemctl disable getout-gost.service >/dev/null 2>&1 || true
    sleep 2
    systemctl is-active --quiet getout-tun.service || fatal "getout-tun.service 重启失败，请查看：journalctl -u getout-tun.service -e"
    success "出口模式已重启。"
    status
  else
    warn "当前 getout 未运行，请选择 1/3/4 启动。"
  fi
}

uninstall_all() {
  require_root
  cleanup_rules
  systemctl stop getout-tun.service getout-gost.service 2>/dev/null || true
  systemctl disable getout-tun.service getout-gost.service 2>/dev/null || true
  rm -f "$TUN_SERVICE" "$GOST_SERVICE"
  rm -f "$TUN_BIN" "$GOST_BIN"
  rm -f "$INSTALL_PATH"
  rm -rf "$CONF_DIR"
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed getout-tun.service getout-gost.service 2>/dev/null || true
  success "getout 已卸载并清理完成。"
}

status() {
  local mode gost_state tun_state gost_enabled tun_enabled
  mode="$(current_mode)"
  gost_state="已停止"; tun_state="已停止"
  server_active && gost_state="运行中"
  tun_active && tun_state="运行中"
  gost_enabled="$(service_enabled_text getout-gost.service)"
  tun_enabled="$(service_enabled_text getout-tun.service)"

  echo -e "${CYAN}========== getout 状态 ==========${NC}"
  echo "版本: $SCRIPT_VERSION"
  echo
  echo "当前运行:"
  echo "入口模式: $gost_state"
  if tun_active && [ "$mode" = "v4" ]; then
    echo "V4 单栈模式: 运行中"
  else
    echo "V4 单栈模式: 已停止"
  fi
  if tun_active && [ "$mode" = "dual" ]; then
    echo "V4+V6 双栈模式: 运行中"
  else
    echo "V4+V6 双栈模式: 已停止"
  fi
  if server_active; then
    echo "当前模式: server"
  elif tun_active; then
    echo "当前模式: $mode"
  else
    echo "当前模式: none"
  fi
  echo
  echo "自启动:"
  echo "入口模式: $gost_enabled"
  echo "出口模式: $tun_enabled"

  echo
  echo "入口信息:"
  if [ -f "$SERVER_CONF" ]; then
    # shellcheck disable=SC1090
    . "$SERVER_CONF"
    echo "监听端口: ${PORT:-}"
    if [ -n "${USERNAME:-}" ]; then
      echo "认证: 开启"
      echo "用户名: ${USERNAME:-}"
      echo "密码: ${PASSWORD:-}"
    else
      echo "认证: 关闭"
    fi
  else
    echo "未配置"
  fi

  echo
  echo "出口信息:"
  if [ -f "$CLIENT_CONF" ]; then
    # shellcheck disable=SC1090
    . "$CLIENT_CONF"
    echo "SOCKS5: [${SOCKS_ADDRESS:-}]:${SOCKS_PORT:-}"
    echo "用户名: ${SOCKS_USERNAME:-}"
    echo "密码: ${SOCKS_PASSWORD:-}"
  else
    echo "未配置"
  fi

  echo
  echo "出口测试:"
  echo -n "IPv4: "; curl -4 -s --connect-timeout 8 --max-time 12 https://api.ipify.org || curl -4 -s --connect-timeout 8 --max-time 12 http://v4.ident.me || echo -n "失败"; echo
  echo -n "IPv6: "; curl -6 -s --connect-timeout 8 --max-time 12 https://api64.ipify.org || curl -6 -s --connect-timeout 8 --max-time 12 http://v6.ident.me || echo -n "失败"; echo
}

menu_action_label() {
  local type="$1" mode="$(current_mode)"
  case "$type" in
    server)
      if server_active; then echo "关闭入口模式"; else echo "启动入口模式"; fi ;;
    v4)
      if tun_active && [ "$mode" = "v4" ]; then echo "关闭 V4 单栈模式"; else echo "启动 V4 单栈模式"; fi ;;
    dual)
      if tun_active && [ "$mode" = "dual" ]; then echo "关闭 V4+V6 双栈模式"; else echo "启动 V4+V6 双栈模式"; fi ;;
  esac
}

menu() {
  clear || true
  echo -e "${BLUE}====================================================${NC}"
  echo -e "${BLUE}                 getout 管理面板${NC}"
  echo -e "${BLUE}====================================================${NC}"
  echo "1.$(menu_action_label server)"
  echo "2.修改入口信息"
  echo "3.$(menu_action_label v4)"
  echo "4.$(menu_action_label dual)"
  echo "5.修改出口信息"
  echo "6.重启 getout"
  echo "7.查看状态"
  echo "8.更新 getout"
  echo "9.卸载 getout"
  echo "10.退出"
  echo
  read -rp "请选择 [1-10]: " choice
  case "$choice" in
    1) if server_active; then stop_server; else start_server; fi ;;
    2) configure_server ;;
    3) if client_mode_active v4; then stop_client; else start_client v4; fi ;;
    4) if client_mode_active dual; then stop_client; else start_client dual; fi ;;
    5) configure_client ;;
    6) restart_getout ;;
    7) status ;;
    8) update_getout ;;
    9) read -rp "确认卸载 getout? [y/N]: " yn; [[ "$yn" =~ ^[Yy]$ ]] && uninstall_all || echo "已取消" ;;
    10) exit 0 ;;
    *) fatal "无效选项。" ;;
  esac
}

usage() {
  cat <<EOF
用法：getout [server|v4|dual|stop|restart|status|update|uninstall]

server     启动入口模式，复用已有入口配置；没有配置时询问
v4         启动 V4 单栈出口模式，复用已有出口配置；没有配置时询问
dual       启动 V4+V6 双栈出口模式，复用已有出口配置；没有配置时询问
stop       关闭当前运行中的 getout 模式，并关闭对应自启动
restart    重启当前运行中的 getout 模式
status     查看状态
update     更新 getout
uninstall  卸载并清理 getout
EOF
}

stop_current() {
  if server_active; then
    stop_server
  elif tun_active; then
    stop_client
  else
    warn "当前 getout 未运行。"
  fi
}

main() {
  case "${1:-}" in
    -h|--help|help) ;;
    *) require_root; require_debian ;;
  esac
  case "${1:-}" in
    uninstall|remove|un|-h|--help|help) ;;
    *) ensure_global_command ;;
  esac

  case "${1:-}" in
    server) start_server ;;
    v4) start_client v4 ;;
    dual) start_client dual ;;
    stop) stop_current ;;
    restart) restart_getout ;;
    status) status ;;
    update) update_getout ;;
    uninstall|remove|un) uninstall_all ;;
    -h|--help|help) usage ;;
    "") menu ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
