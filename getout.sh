#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="0.2.1"
INSTALL_PATH="/usr/local/bin/getout"
UPDATE_URL="https://raw.githubusercontent.com/xiaochengshiguduo/getout/main/getout.sh"
UPDATE_SHA256_URL="https://raw.githubusercontent.com/xiaochengshiguduo/getout/main/getout.sh.sha256"
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
RUNTIME_DNS_V4_SERVERS=("8.8.8.8" "1.1.1.1")
RUNTIME_DNS_V6_SERVERS=("2001:4860:4860::8888" "2606:4700:4700::1111")
DEFAULT_PRIORITY_MODE="v6"
RESOLV_ORIG="$CONF_DIR/resolv.conf.orig"
GAI_ORIG="$CONF_DIR/gai.conf.orig"
RESOLV_MARKER="$CONF_DIR/resolv.conf.getout"
GAI_MARKER="$CONF_DIR/gai.conf.getout"
RESOLV_META="$CONF_DIR/resolv.conf.meta"
RESOLV_TARGET_ORIG="$CONF_DIR/resolv.conf.target.orig"
GAI_META="$CONF_DIR/gai.conf.meta"

GOST_BIN="/usr/local/bin/getout-gost"
TUN_BIN="/usr/local/bin/getout-tun2socks"
GOST_SERVICE="/etc/systemd/system/getout-gost.service"
TUN_SERVICE="/etc/systemd/system/getout-tun.service"

GOST_VERSION="2.11.5"
HEV_VERSION="2.15.0"
TABLE_ID="20"
MARK_ID="438"
BYPASS_MARK_ID="439"
NFT_TABLE="getout_protect"
TUN_NAME="tun0"
DNS64_SERVERS=(
  "2001:67c:2960::64"
  "2a00:1098:2b::1"
  "2a00:1098:2c::1"
  "2a01:4f8:c2c:123f::1"
  "2001:67c:2960::6464"
)

# =============================================================================
# Maintainer map
# -----------------------------------------------------------------------------
# getout is intentionally published as one self-contained script so raw GitHub
# install/update and a single checksum artifact stay simple. Keep future changes
# inside these sections; if a section grows large enough, split it in src/ during
# development and generate this single-file release artifact from a build step.
#
# 00 constants / globals                 (above)
# 01 logging helpers
# 02 self install / update / checksum
# 03 config permissions and file metadata
# 04 runtime/server rollback snapshots
# 05 host prerequisites and binary downloads
# 06 encoding, address, and SSH helpers
# 07 cleanup, preflight, and restart wrappers
# 08 generated route scripts
# 09 service state and entry/server mode
# 10 outlet/client mode
# 11 lifecycle, status, diagnostics, and CLI
# =============================================================================

# --- 01 logging helpers -------------------------------------------------------

info() { echo -e "${BLUE}[信息]${NC} $*"; }
success() { echo -e "${GREEN}[成功]${NC} $*"; }
warn() { echo -e "${YELLOW}[警告]${NC} $*"; }
err() { echo -e "${RED}[错误]${NC} $*" >&2; }
fatal() { err "$*"; exit 1; }

# --- 02 self install / update / checksum -------------------------------------

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

download_to_file() {
  local url="$1" output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 20 --retry 2 --retry-delay 1 "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$output" "$url"
  else
    return 127
  fi
}

verify_update_checksum() {
  local file="$1" expected="${GETOUT_UPDATE_SHA256:-}" checksum tmp_hash hash_url sep
  if [ -z "$expected" ]; then
    tmp_hash="$(mktemp)"
    hash_url="${GETOUT_UPDATE_SHA256_URL:-$UPDATE_SHA256_URL}"
    if [[ "$hash_url" == http://* || "$hash_url" == https://* ]]; then
      sep="?"; [[ "$hash_url" == *\?* ]] && sep="&"
      hash_url="${hash_url}${sep}v=${SCRIPT_VERSION}&t=$(date +%s)"
    fi
    if download_to_file "$hash_url" "$tmp_hash" 2>/dev/null; then
      expected="$(awk 'NF {print $1; exit}' "$tmp_hash" 2>/dev/null || true)"
    fi
    rm -f "$tmp_hash" 2>/dev/null || true
  fi
  [ -n "$expected" ] || { warn "未找到 getout.sh.sha256，已跳过更新完整性校验。"; return 0; }
  command -v sha256sum >/dev/null 2>&1 || fatal "已提供 SHA256 校验值，但系统缺少 sha256sum。"
  checksum="$(sha256sum "$file" | awk '{print $1}')"
  [ "$checksum" = "$expected" ] || fatal "getout 下载文件 SHA256 校验失败，已取消安装/更新。"
}

install_from_update_url() {
  local mode="${1:-install}" tmp version download_url
  tmp="$(mktemp)"
  download_url="$UPDATE_URL"
  if [[ "$download_url" == http://* || "$download_url" == https://* ]]; then
    download_url="${download_url}?v=${SCRIPT_VERSION}&t=$(date +%s)"
  fi
  trap 'rm -f "$tmp"' RETURN EXIT

  rm -f "$tmp"
  if ! download_to_file "$download_url" "$tmp"; then
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || fatal "未找到 curl 或 wget，无法下载安装 getout。"
    fatal "getout 下载失败。"
  fi

  [ -s "$tmp" ] || fatal "getout 下载结果为空。"
  verify_update_checksum "$tmp"
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
  if service_active getout-tun.service || service_active getout-gost.service; then
    warn "getout 正在运行。需要重启才能刷新服务文件和路由脚本。"
    if [ -t 0 ]; then
      local yn
      read -rp "是否立即执行 getout restart? [y/N]: " yn
      if [[ "$yn" =~ ^[Yy]$ ]]; then
        exec "$INSTALL_PATH" restart
      fi
    fi
    warn "已跳过自动重启。请稍后执行 getout restart。"
  fi
}

# --- 03 config permissions and file metadata ---------------------------------

ensure_conf_dir() {
  mkdir -p "$CONF_DIR"
  chmod 700 "$CONF_DIR" 2>/dev/null || true
}

chmod_private_file() {
  [ -f "$1" ] && chmod 600 "$1" 2>/dev/null || true
}

assert_private_config() {
  local file="$1"
  [ -f "$file" ] || fatal "配置文件不存在：$file"
  if ! find "$file" -maxdepth 0 -type f -user root ! -perm /022 | grep -q .; then
    fatal "配置文件权限不安全：$file。请确认 owner=root 且 group/other 不可写。"
  fi
}

file_checksum() {
  [ -e "$1" ] || { echo missing; return 0; }
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}' || echo unknown
  else
    cksum "$1" 2>/dev/null | awk '{print $1":"$2}' || echo unknown
  fi
}

write_file_meta() {
  local path="$1" meta="$2" backup="$3" exists target checksum
  exists=0; [ -e "$path" ] && exists=1
  target=""
  [ -L "$path" ] && target="$(readlink "$path" 2>/dev/null || true)"
  checksum="$(file_checksum "$path")"
  {
    printf 'EXISTS=%s\n' "$(shell_quote "$exists")"
    printf 'SYMLINK_TARGET=%s\n' "$(shell_quote "$target")"
    printf 'CHECKSUM=%s\n' "$(shell_quote "$checksum")"
    if [ -e "$backup" ]; then
      printf 'BACKUP_CHECKSUM=%s\n' "$(shell_quote "$(file_checksum "$backup")")"
    else
      printf 'BACKUP_CHECKSUM=%s\n' "$(shell_quote missing)"
    fi
  } > "$meta"
  chmod_private_file "$meta"
}

backup_path_preserve_symlink() {
  local path="$1" backup="$2" meta="$3" target_backup="${4:-}"
  [ -f "$backup" ] && return 0
  write_file_meta "$path" "$meta" "$backup"
  if [ -L "$path" ]; then
    cp -a "$path" "$backup" 2>/dev/null || true
    [ -n "$target_backup" ] && cp -a "$(readlink -f "$path" 2>/dev/null || echo "$path")" "$target_backup" 2>/dev/null || true
  elif [ -e "$path" ]; then
    cp -a "$path" "$backup" 2>/dev/null || true
  else
    : > "$backup" 2>/dev/null || true
  fi
  chmod_private_file "$backup"
  [ -n "$target_backup" ] && chmod_private_file "$target_backup"
  write_file_meta "$path" "$meta" "$backup"
}

# --- 04 runtime/server rollback snapshots ------------------------------------

restore_path_from_backup() {
  local path="$1" backup="$2" meta="$3" marker="$4" label="$5" target_backup="${6:-}"
  local exists="1" symlink_target="" backup_checksum="" current_checksum marker_checksum
  [ -f "$meta" ] && { # shellcheck disable=SC1090
    . "$meta"; exists="${EXISTS:-1}"; symlink_target="${SYMLINK_TARGET:-}"; backup_checksum="${BACKUP_CHECKSUM:-}"; }
  if [ ! -e "$backup" ]; then
    [ -f "$marker" ] && warn "$label 原始备份缺失，已保留当前内容，避免误恢复到未知状态。"
    return 0
  fi
  current_checksum="$(file_checksum "$path")"
  if [ -f "$marker" ]; then
    marker_checksum="$(cat "$marker" 2>/dev/null || true)"
    if [ -n "$marker_checksum" ] && [ "$marker_checksum" != "$current_checksum" ]; then
      warn "$label 在 getout 运行期间被外部修改，已保留当前内容；旧备份已归档，后续启动会重新备份当前状态。"
      mv -f "$backup" "$backup.conflict.$(date +%s)" 2>/dev/null || true
      [ -n "$target_backup" ] && mv -f "$target_backup" "$target_backup.conflict.$(date +%s)" 2>/dev/null || true
      rm -f "$meta" "$marker" 2>/dev/null || true
      return 0
    fi
  fi
  if [ "$exists" = "0" ]; then
    rm -f "$path" 2>/dev/null || true
  elif [ -n "$symlink_target" ]; then
    rm -f "$path" 2>/dev/null || true
    ln -s "$symlink_target" "$path" 2>/dev/null || cp -a "$backup" "$path" 2>/dev/null || true
    if [ -n "$target_backup" ] && [ -e "$target_backup" ]; then
      cp -a "$target_backup" "$(readlink -f "$path" 2>/dev/null || echo "$path")" 2>/dev/null || true
    fi
  else
    cp -a "$backup" "$path" 2>/dev/null || true
  fi
  rm -f "$backup" "$meta" "$marker" "$target_backup" 2>/dev/null || true
}

snapshot_runtime_files() {
  local dir
  dir="$(mktemp -d)" || fatal "创建回滚快照失败。"
  for file in "$CLIENT_CONF" "$TUN_CONF" "$ROUTES_UP" "$ROUTES_DOWN" "$TUN_SERVICE" "$MODE_FILE"; do
    touch "$dir/$(basename "$file").missing" 2>/dev/null || true
    if [ -e "$file" ]; then
      cp -a "$file" "$dir/$(basename "$file")" 2>/dev/null || true
      rm -f "$dir/$(basename "$file").missing" 2>/dev/null || true
    fi
  done
  echo "$dir"
}

snapshot_server_files() {
  local dir file
  dir="$(mktemp -d)" || fatal "创建入口回滚快照失败。"
  for file in "$SERVER_CONF" "$GOST_SERVICE" "$MODE_FILE"; do
    touch "$dir/$(basename "$file").missing" 2>/dev/null || true
    if [ -e "$file" ]; then
      cp -a "$file" "$dir/$(basename "$file")" 2>/dev/null || true
      rm -f "$dir/$(basename "$file").missing" 2>/dev/null || true
    fi
  done
  echo "$dir"
}

restore_runtime_files() {
  local dir="$1" file base
  [ -d "$dir" ] || return 0
  for file in "$CLIENT_CONF" "$TUN_CONF" "$ROUTES_UP" "$ROUTES_DOWN" "$TUN_SERVICE" "$MODE_FILE"; do
    base="$(basename "$file")"
    if [ -e "$dir/$base" ]; then
      cp -a "$dir/$base" "$file" 2>/dev/null || true
    elif [ -e "$dir/$base.missing" ]; then
      rm -f "$file" 2>/dev/null || true
    fi
  done
  systemctl daemon-reload 2>/dev/null || true
}

restore_server_files() {
  local dir="$1" file base
  [ -d "$dir" ] || return 0
  for file in "$SERVER_CONF" "$GOST_SERVICE" "$MODE_FILE"; do
    base="$(basename "$file")"
    if [ -e "$dir/$base" ]; then
      cp -a "$dir/$base" "$file" 2>/dev/null || true
    elif [ -e "$dir/$base.missing" ]; then
      rm -f "$file" 2>/dev/null || true
    fi
  done
  systemctl daemon-reload 2>/dev/null || true
}

remove_runtime_snapshot() {
  [ -n "${1:-}" ] && rm -rf "$1" 2>/dev/null || true
}

RUNTIME_ROLLBACK_SNAPSHOT=""
RUNTIME_ROLLBACK_RESTORE="restore_runtime_or_warn"

runtime_rollback_on_exit() {
  local snapshot="${RUNTIME_ROLLBACK_SNAPSHOT:-}"
  [ -n "$snapshot" ] || return 0
  RUNTIME_ROLLBACK_SNAPSHOT=""
  "${RUNTIME_ROLLBACK_RESTORE:-restore_runtime_or_warn}" "$snapshot"
}

begin_runtime_rollback() {
  RUNTIME_ROLLBACK_SNAPSHOT="$1"
  RUNTIME_ROLLBACK_RESTORE="restore_runtime_or_warn"
  trap runtime_rollback_on_exit EXIT
}

begin_server_rollback() {
  RUNTIME_ROLLBACK_SNAPSHOT="$1"
  RUNTIME_ROLLBACK_RESTORE="restore_server_or_warn"
  trap runtime_rollback_on_exit EXIT
}

clear_runtime_rollback() {
  local snapshot="${1:-${RUNTIME_ROLLBACK_SNAPSHOT:-}}"
  RUNTIME_ROLLBACK_SNAPSHOT=""
  trap - EXIT
  remove_runtime_snapshot "$snapshot"
}

secure_existing_files() {
  [ -d "$CONF_DIR" ] && chmod 700 "$CONF_DIR" 2>/dev/null || true
  chmod_private_file "$SERVER_CONF"
  chmod_private_file "$CLIENT_CONF"
  chmod_private_file "$TUN_CONF"
  chmod_private_file "$MODE_FILE"
  chmod_private_file "$GOST_SERVICE"
  chmod_private_file "$TUN_SERVICE"
  [ -f "$ROUTES_UP" ] && chmod 700 "$ROUTES_UP" 2>/dev/null || true
  [ -f "$ROUTES_DOWN" ] && chmod 700 "$ROUTES_DOWN" 2>/dev/null || true
}

# --- 05 host prerequisites and binary downloads ------------------------------

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
    [curl]=curl [gzip]=gzip [gunzip]=gzip [ip]=iproute2 [ss]=iproute2 [nft]=nftables
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
  local dns="$1" orig rc old_trap
  shift
  orig="$(cat /etc/resolv.conf 2>/dev/null || true)"
  old_trap="$(trap -p RETURN || true)"
  trap 'printf "%s\n" "$orig" > /etc/resolv.conf 2>/dev/null || true' RETURN
  if ! printf 'nameserver %s\noptions timeout:3 attempts:2\n' "$dns" > /etc/resolv.conf; then
    printf '%s\n' "$orig" > /etc/resolv.conf 2>/dev/null || true
    trap - RETURN
    [ -n "$old_trap" ] && eval "$old_trap" || true
    return 1
  fi
  "$@"
  rc=$?
  printf '%s\n' "$orig" > /etc/resolv.conf || true
  trap - RETURN
  [ -n "$old_trap" ] && eval "$old_trap" || true
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

download_file() {
  local url="$1" output="$2"
  if curl -fL --connect-timeout 20 --retry 2 --retry-delay 1 -o "$output" "$url"; then
    return 0
  fi
  warn "常规下载失败，尝试 DNS64 下载。"
  download_dns64_only "$url" "$output"
}

download_gost() {
  local arch url tmp
  arch="$(arch_gost)"
  url="https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost-linux-${arch}-${GOST_VERSION}.gz"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  info "下载 gost：$url"
  download_file "$url" "$tmp" || fatal "gost 下载失败：常规下载和 DNS64 均不可用。"
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
  download_file "$url" "$tmp" || fatal "hev-socks5-tunnel 下载失败：常规下载和 DNS64 均不可用。"
  install -m 0755 "$tmp" "$TUN_BIN"
  rm -f "$tmp"
  trap - RETURN
}

# --- 06 encoding, address, and SSH helpers -----------------------------------

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
  [[ "$value" != *":"* ]] || fatal "$name 不能包含 : 字符。"
  [[ "$value" != *"/"* ]] || fatal "$name 不能包含 / 字符。"
  [[ "$value" != *"?"* ]] || fatal "$name 不能包含 ? 字符。"
  [[ "$value" != *"#"* ]] || fatal "$name 不能包含 # 字符。"
  [[ "$value" != *"%"* ]] || fatal "$name 不能包含 % 字符。"
  [[ "$value" != *"&"* ]] || fatal "$name 不能包含 & 字符。"
  [[ "$value" != *"["* ]] || fatal "$name 不能包含 [ 字符。"
  [[ "$value" != *"]"* ]] || fatal "$name 不能包含 ] 字符。"
  [[ "$value" != *"\\"* ]] || fatal "$name 不能包含 \\ 字符。"
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

ssh_listen_ports() {
  {
    if [ -n "${SSH_CONNECTION:-}" ]; then
      awk '{print $4}' <<<"$SSH_CONNECTION"
    fi
    if command -v sshd >/dev/null 2>&1; then
      sshd -T 2>/dev/null | awk '$1=="port" {print $2}'
    elif [ -x /usr/sbin/sshd ]; then
      /usr/sbin/sshd -T 2>/dev/null | awk '$1=="port" {print $2}'
    fi
    if command -v ss >/dev/null 2>&1; then
      ss -H -ltnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}'
    fi
  } | awk '/^[0-9]+$/ && $1 >= 1 && $1 <= 65535 {seen[$1]=1} END {for (p in seen) print p}' | sort -n
}

main_ipv4() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true
}

main_ipv6() {
  ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true
}

# --- 07 cleanup, preflight, and restart wrappers -----------------------------

run_quiet() { "$@" 2>/dev/null || true; }
run_all_quiet() { while "$@" 2>/dev/null; do :; done; }

fallback_cleanup_rules() {
  local port cidr dns
  run_quiet nft delete table inet "$NFT_TABLE"
  run_all_quiet ip rule del fwmark "$BYPASS_MARK_ID" lookup main pref 9
  run_all_quiet ip -6 rule del fwmark "$BYPASS_MARK_ID" lookup main pref 9
  run_all_quiet ip rule del fwmark "$MARK_ID" lookup main pref 10
  run_all_quiet ip -6 rule del fwmark "$MARK_ID" lookup main pref 10
  run_all_quiet ip rule del lookup "$TABLE_ID" pref 20
  run_all_quiet ip -6 rule del lookup "$TABLE_ID" pref 20
  run_all_quiet ip route del default dev "$TUN_NAME" table "$TABLE_ID"
  run_all_quiet ip -6 route del default dev "$TUN_NAME" table "$TABLE_ID"
  for port in $(ssh_listen_ports | tr '\n' ' ') 22; do
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    run_all_quiet ip rule del ipproto tcp sport "$port" lookup main pref 6
    run_all_quiet ip -6 rule del ipproto tcp sport "$port" lookup main pref 6
    run_all_quiet ip rule del sport "$port" lookup main pref 6
    run_all_quiet ip -6 rule del sport "$port" lookup main pref 6
  done
  for cidr in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/4; do
    run_all_quiet ip rule del to "$cidr" lookup main pref 16
  done
  for cidr in ::1/128 fe80::/10 fc00::/7 ff00::/8; do
    run_all_quiet ip -6 rule del to "$cidr" lookup main pref 16
  done
  for dns in "${RUNTIME_DNS_V4_SERVERS[@]}" "${RUNTIME_DNS_V6_SERVERS[@]}"; do
    if is_ipv6 "$dns"; then
      run_all_quiet ip -6 rule del to "$dns/128" lookup main pref 7
    elif is_ipv4 "$dns"; then
      run_all_quiet ip rule del to "$dns/32" lookup main pref 7
    fi
  done
}

restore_managed_files_fallback() {
  if [ -f "$RESOLV_ORIG" ]; then
    cat "$RESOLV_ORIG" > /etc/resolv.conf 2>/dev/null || warn "恢复 /etc/resolv.conf 失败，请手动检查 DNS。"
    rm -f "$RESOLV_ORIG" "$CONF_DIR/resolv.conf.getout" 2>/dev/null || true
  elif [ -f "$CONF_DIR/resolv.conf.getout" ]; then
    warn "/etc/resolv.conf 原始备份缺失，已保留当前 DNS，避免误恢复到未知内容。"
  fi
  if [ -f "$GAI_ORIG" ]; then
    cat "$GAI_ORIG" > /etc/gai.conf 2>/dev/null || warn "恢复 /etc/gai.conf 失败，请手动检查地址优先级。"
    rm -f "$GAI_ORIG" "$CONF_DIR/gai.conf.getout" 2>/dev/null || true
  elif [ -f "$CONF_DIR/gai.conf.getout" ] && [ -f /etc/gai.conf ]; then
    local tmp
    tmp="$(mktemp)" || return 0
    awk '
      $0 == "# getout managed priority begin" {skip=1; next}
      $0 == "# getout managed priority end" {skip=0; next}
      !skip {print}
    ' /etc/gai.conf 2>/dev/null > "$tmp" || true
    cat "$tmp" > /etc/gai.conf 2>/dev/null || true
    rm -f "$tmp" "$CONF_DIR/gai.conf.getout" 2>/dev/null || true
    warn "/etc/gai.conf 原始备份缺失，已移除 getout 管理块。"
  fi
}

preflight_tun_runtime() {
  [ -x "$TUN_BIN" ] || { err "未找到可执行 tun2socks：$TUN_BIN"; return 1; }
  [ -s "$TUN_CONF" ] || { err "tun2socks 配置为空或不存在：$TUN_CONF"; return 1; }
  [ -x "$ROUTES_UP" ] || { err "routes-up.sh 不可执行：$ROUTES_UP"; return 1; }
  [ -x "$ROUTES_DOWN" ] || { err "routes-down.sh 不可执行：$ROUTES_DOWN"; return 1; }
  bash -n "$ROUTES_UP" || { err "routes-up.sh 语法校验失败。"; return 1; }
  bash -n "$ROUTES_DOWN" || { err "routes-down.sh 语法校验失败。"; return 1; }
  command -v nft >/dev/null 2>&1 || { err "未找到 nft，无法启用外部入站连接回包保护。"; return 1; }
  nft delete table inet getout_preflight 2>/dev/null || true
  nft add table inet getout_preflight >/dev/null 2>&1 || { err "nftables 预检失败：无法创建 inet table。"; return 1; }
  nft add chain inet getout_preflight prerouting '{ type filter hook prerouting priority -150; policy accept; }' >/dev/null 2>&1 || { nft delete table inet getout_preflight 2>/dev/null || true; err "nftables 预检失败：当前内核不支持所需 prerouting 规则。"; return 1; }
  nft add chain inet getout_preflight output '{ type route hook output priority -150; policy accept; }' >/dev/null 2>&1 || { nft delete table inet getout_preflight 2>/dev/null || true; err "nftables 预检失败：当前内核不支持所需 output route hook。"; return 1; }
  nft add rule inet getout_preflight prerouting iifname != "$TUN_NAME" ct state new fib daddr type local ct mark set "$BYPASS_MARK_ID" >/dev/null 2>&1 || { nft delete table inet getout_preflight 2>/dev/null || true; err "nftables 预检失败：当前内核不支持 conntrack/fib 标记规则。"; return 1; }
  nft add rule inet getout_preflight output ct mark "$BYPASS_MARK_ID" meta mark set "$BYPASS_MARK_ID" >/dev/null 2>&1 || { nft delete table inet getout_preflight 2>/dev/null || true; err "nftables 预检失败：当前内核不支持 ct mark 输出规则。"; return 1; }
  nft delete table inet getout_preflight 2>/dev/null || true
}

restore_runtime_or_warn() {
  local snapshot="$1"
  RUNTIME_ROLLBACK_SNAPSHOT=""
  trap - EXIT
  restore_runtime_files "$snapshot"
  remove_runtime_snapshot "$snapshot"
  warn "启动失败，已尝试恢复旧配置和旧 systemd 文件。"
}

restore_server_or_warn() {
  local snapshot="$1"
  RUNTIME_ROLLBACK_SNAPSHOT=""
  trap - EXIT
  restore_server_files "$snapshot"
  remove_runtime_snapshot "$snapshot"
  warn "入口模式启动失败，已尝试恢复旧入口配置和旧 systemd 文件。"
}

preflight_tun_runtime_with_rollback() {
  local snapshot="$1"
  preflight_tun_runtime || {
    restore_runtime_or_warn "$snapshot"
    exit 1
  }
}

restart_tun_with_rollback() {
  local snapshot="$1" action="${2:-restart}"
  if [ "$action" = "enable" ]; then
    systemctl enable --now getout-tun.service
  else
    systemctl restart getout-tun.service
  fi
  sleep 2
  if ! systemctl is-active --quiet getout-tun.service; then
    restore_runtime_or_warn "$snapshot"
    systemctl restart getout-tun.service 2>/dev/null || true
    fatal "getout-tun.service 启动失败，请查看：journalctl -u getout-tun.service -e"
  fi
  clear_runtime_rollback "$snapshot"
}

restart_gost_with_rollback() {
  local snapshot="$1" action="${2:-restart}"
  if [ "$action" = "enable" ]; then
    systemctl enable --now getout-gost.service
  else
    systemctl restart getout-gost.service
  fi
  sleep 1
  if ! systemctl is-active --quiet getout-gost.service; then
    restore_server_or_warn "$snapshot"
    systemctl restart getout-gost.service 2>/dev/null || true
    fatal "getout-gost.service 启动失败，请查看：journalctl -u getout-gost.service -e"
  fi
  clear_runtime_rollback "$snapshot"
}

# --- 08 generated route scripts ----------------------------------------------

write_routes_scripts() {
  ensure_conf_dir
  cat > "$ROUTES_UP" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CONF_DIR="/etc/getout"
assert_private_config() {
  local file="$1"
  [ -f "$file" ] || return 1
  find "$file" -maxdepth 0 -type f -user root ! -perm /022 | grep -q .
}
# shellcheck disable=SC1091
if [ -f "$CONF_DIR/client.conf" ]; then
  assert_private_config "$CONF_DIR/client.conf" || { echo "[错误] client.conf 权限不安全，已拒绝启动路由脚本。" >&2; exit 1; }
  . "$CONF_DIR/client.conf"
fi
TABLE_ID="${TABLE_ID:-20}"
MARK_ID="${MARK_ID:-438}"
BYPASS_MARK_ID="${BYPASS_MARK_ID:-439}"
NFT_TABLE="${NFT_TABLE:-getout_protect}"
TUN_NAME="${TUN_NAME:-tun0}"
MODE="${MODE:-v4}"
RUNTIME_DNS_SERVERS="${RUNTIME_DNS_SERVERS:-2001:4860:4860::8888 2606:4700:4700::1111}"
RUNTIME_DNS_ENABLE="${RUNTIME_DNS_ENABLE:-1}"
PRIORITY_MODE="${PRIORITY_MODE:-v6}"
RESOLV_ORIG="$CONF_DIR/resolv.conf.orig"
GAI_ORIG="$CONF_DIR/gai.conf.orig"
RESOLV_MARKER="$CONF_DIR/resolv.conf.getout"
GAI_MARKER="$CONF_DIR/gai.conf.getout"
RESOLV_META="$CONF_DIR/resolv.conf.meta"
RESOLV_TARGET_ORIG="$CONF_DIR/resolv.conf.target.orig"
GAI_META="$CONF_DIR/gai.conf.meta"

run() { "$@" 2>/dev/null || true; }
run_all() { while "$@" 2>/dev/null; do :; done; }
file_checksum() { [ -e "$1" ] || { echo missing; return 0; }; if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | awk '{print $1}' || echo unknown; else cksum "$1" 2>/dev/null | awk '{print $1":"$2}' || echo unknown; fi; }
write_meta() {
  local path="$1" meta="$2" backup="$3" exists target
  exists=0; [ -e "$path" ] && exists=1
  target=""; [ -L "$path" ] && target="$(readlink "$path" 2>/dev/null || true)"
  { printf 'EXISTS=%q\n' "$exists"; printf 'SYMLINK_TARGET=%q\n' "$target"; printf 'CHECKSUM=%q\n' "$(file_checksum "$path")"; printf 'BACKUP_CHECKSUM=%q\n' "$(file_checksum "$backup")"; } > "$meta" 2>/dev/null || true
}
backup_path() {
  local path="$1" backup="$2" meta="$3" target_backup="${4:-}"
  [ -f "$backup" ] && return 0
  write_meta "$path" "$meta" "$backup"
  if [ -L "$path" ]; then
    cp -a "$path" "$backup" 2>/dev/null || true
    [ -n "$target_backup" ] && cp -a "$(readlink -f "$path" 2>/dev/null || echo "$path")" "$target_backup" 2>/dev/null || true
  elif [ -e "$path" ]; then
    cp -a "$path" "$backup" 2>/dev/null || true
  else
    : > "$backup" 2>/dev/null || true
  fi
  write_meta "$path" "$meta" "$backup"
}
restore_path() {
  local path="$1" backup="$2" meta="$3" marker="$4" label="$5" target_backup="${6:-}" exists=1 symlink_target="" marker_checksum current_checksum
  [ -f "$meta" ] && . "$meta" && exists="${EXISTS:-1}" && symlink_target="${SYMLINK_TARGET:-}"
  if [ ! -e "$backup" ]; then [ -f "$marker" ] && echo "[警告] $label 原始备份缺失，已保留当前内容，避免误恢复到未知状态。" >&2; return 0; fi
  current_checksum="$(file_checksum "$path")"; marker_checksum="$(cat "$marker" 2>/dev/null || true)"
  if [ -n "$marker_checksum" ] && [ "$marker_checksum" != "$current_checksum" ]; then echo "[警告] $label 在 getout 运行期间被外部修改，已保留当前内容；旧备份已归档，后续启动会重新备份当前状态。" >&2; mv -f "$backup" "$backup.conflict.$(date +%s)" 2>/dev/null || true; [ -n "$target_backup" ] && mv -f "$target_backup" "$target_backup.conflict.$(date +%s)" 2>/dev/null || true; rm -f "$meta" "$marker" 2>/dev/null || true; return 0; fi
  if [ "$exists" = "0" ]; then rm -f "$path" 2>/dev/null || true
  elif [ -n "$symlink_target" ]; then rm -f "$path" 2>/dev/null || true; ln -s "$symlink_target" "$path" 2>/dev/null || cp -a "$backup" "$path" 2>/dev/null || true; [ -n "$target_backup" ] && [ -e "$target_backup" ] && cp -a "$target_backup" "$(readlink -f "$path" 2>/dev/null || echo "$path")" 2>/dev/null || true
  else cp -a "$backup" "$path" 2>/dev/null || true; fi
  rm -f "$backup" "$meta" "$marker" "$target_backup" 2>/dev/null || true
}
is_ipv6() { [[ "${1:-}" == *:* ]]; }
is_ipv4() { [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
add4_to_main() { [ -n "${1:-}" ] && run_all ip rule del to "$1" lookup main pref "$2" && run ip rule add to "$1" lookup main pref "$2"; }
add6_to_main() { [ -n "${1:-}" ] && run_all ip -6 rule del to "$1" lookup main pref "$2" && run ip -6 rule add to "$1" lookup main pref "$2"; }
ssh_listen_ports() {
  {
    if [ -n "${SSH_CONNECTION:-}" ]; then
      awk '{print $4}' <<<"$SSH_CONNECTION"
    fi
    if command -v sshd >/dev/null 2>&1; then
      sshd -T 2>/dev/null | awk '$1=="port" {print $2}'
    elif [ -x /usr/sbin/sshd ]; then
      /usr/sbin/sshd -T 2>/dev/null | awk '$1=="port" {print $2}'
    fi
    if command -v ss >/dev/null 2>&1; then
      ss -H -ltnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}'
    fi
  } | awk '/^[0-9]+$/ && $1 >= 1 && $1 <= 65535 {seen[$1]=1} END {for (p in seen) print p}' | sort -n
}
ssh_ports_text() {
  local ports="${SSH_PORTS:-}"
  [ -n "$ports" ] || ports="$(ssh_listen_ports | tr '\n' ' ')"
  [ -n "$ports" ] || ports="22"
  printf '%s\n' "$ports"
}
add_ssh_port_rules() {
  local port
  for port in $(ssh_ports_text); do
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    run_all ip rule del ipproto tcp sport "$port" lookup main pref 6
    run_all ip -6 rule del ipproto tcp sport "$port" lookup main pref 6
    run ip rule add ipproto tcp sport "$port" lookup main pref 6
    run ip -6 rule add ipproto tcp sport "$port" lookup main pref 6
  done
}
add_inbound_protect() {
  command -v nft >/dev/null 2>&1 || { echo "[错误] 未找到 nft，无法启用外部入站连接回包保护。" >&2; return 1; }
  nft delete table inet "$NFT_TABLE" 2>/dev/null || true
  nft add table inet "$NFT_TABLE"
  nft add chain inet "$NFT_TABLE" prerouting '{ type filter hook prerouting priority -150; policy accept; }'
  nft add chain inet "$NFT_TABLE" output '{ type route hook output priority -150; policy accept; }'
  nft add rule inet "$NFT_TABLE" prerouting iifname != "$TUN_NAME" ct state new fib daddr type local ct mark set "$BYPASS_MARK_ID"
  nft add rule inet "$NFT_TABLE" output ct mark "$BYPASS_MARK_ID" meta mark set "$BYPASS_MARK_ID"
  nft list table inet "$NFT_TABLE" >/dev/null
}

apply_runtime_dns() {
  [ "$RUNTIME_DNS_ENABLE" = "1" ] || return 0
  if [ ! -f "$RESOLV_ORIG" ]; then
    if [ -f "$RESOLV_MARKER" ]; then echo "[警告] 检测到 /etc/resolv.conf 可能已由 getout 管理，但原始备份缺失；为避免错误覆盖原始 DNS，本次不重建备份。" >&2
    else backup_path /etc/resolv.conf "$RESOLV_ORIG" "$RESOLV_META" "$RESOLV_TARGET_ORIG"; fi
  fi
  {
    printf '# getout managed resolv begin\n'
    for dns in $RUNTIME_DNS_SERVERS; do printf 'nameserver %s\n' "$dns"; done
    printf 'options timeout:2 attempts:1\n'
    printf '# getout managed resolv end\n'
  } > /etc/resolv.conf 2>/dev/null || { echo "[错误] 写入 /etc/resolv.conf 失败。" >&2; return 1; }
  file_checksum /etc/resolv.conf > "$RESOLV_MARKER" 2>/dev/null || true
}

apply_gai_priority() {
  local tmp
  tmp="$(mktemp)" || return 0
  if [ ! -f "$GAI_ORIG" ]; then
    if [ -f "$GAI_MARKER" ]; then
      echo "[警告] 检测到 /etc/gai.conf 可能已由 getout 管理，但原始备份缺失；本次只更新 getout 管理块。" >&2
    else
      backup_path /etc/gai.conf "$GAI_ORIG" "$GAI_META"
    fi
  fi
  awk '
    $0 == "# getout managed priority begin" {skip=1; next}
    $0 == "# getout managed priority end" {skip=0; next}
    !skip {print}
  ' /etc/gai.conf 2>/dev/null > "$tmp" || true
  {
    cat "$tmp" 2>/dev/null || true
    printf '\n# getout managed priority begin\n'
    printf 'label ::1/128       0\n'
    printf 'label ::/0          1\n'
    printf 'label 2002::/16     2\n'
    printf 'label ::/96         3\n'
    printf 'label ::ffff:0:0/96 4\n'
    printf 'label fec0::/10     5\n'
    printf 'label fc00::/7      6\n'
    printf 'label 2001:0::/32   7\n'
    printf 'precedence ::1/128       50\n'
    if [ "$PRIORITY_MODE" = "v4" ]; then
      printf 'precedence ::ffff:0:0/96 100\n'
      printf 'precedence ::/0          40\n'
    else
      printf 'precedence ::/0          40\n'
      printf 'precedence ::ffff:0:0/96 10\n'
    fi
    printf 'precedence 2002::/16     30\n'
    printf 'precedence ::/96         20\n'
    printf '# getout managed priority end\n'
  } > /etc/gai.conf 2>/dev/null || true
  file_checksum /etc/gai.conf > "$GAI_MARKER" 2>/dev/null || true
  rm -f "$tmp" 2>/dev/null || true
}

"$CONF_DIR/routes-down.sh" >/dev/null 2>&1 || true
apply_runtime_dns
apply_gai_priority

# 保护外部主动连入本机的连接回包，避免 sing-box/xray/hysteria 等入站服务被出口路由接管。
add_inbound_protect
run ip rule add fwmark "$BYPASS_MARK_ID" lookup main pref 9
run ip -6 rule add fwmark "$BYPASS_MARK_ID" lookup main pref 9

# 避免 tun2socks 访问上游 SOCKS5 时被自己接管。
run ip rule add fwmark "$MARK_ID" lookup main pref 10
run ip -6 rule add fwmark "$MARK_ID" lookup main pref 10

# 保护当前 SSH 会话回包、SOCKS5 上游地址。
if is_ipv6 "${SSH_REMOTE_IP:-}"; then add6_to_main "${SSH_REMOTE_IP}/128" 5; elif is_ipv4 "${SSH_REMOTE_IP:-}"; then add4_to_main "${SSH_REMOTE_IP}/32" 5; fi
if is_ipv6 "${SOCKS_ADDRESS:-}"; then add6_to_main "${SOCKS_ADDRESS}/128" 6; elif is_ipv4 "${SOCKS_ADDRESS:-}"; then add4_to_main "${SOCKS_ADDRESS}/32" 6; fi
# SSH 回包保护（不依赖 SSH_CONNECTION，开机自启也生效）。
add_ssh_port_rules
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
assert_private_config() {
  local file="$1"
  [ -f "$file" ] || return 1
  find "$file" -maxdepth 0 -type f -user root ! -perm /022 | grep -q .
}
# shellcheck disable=SC1091
if [ -f "$CONF_DIR/client.conf" ]; then
  if assert_private_config "$CONF_DIR/client.conf"; then
    . "$CONF_DIR/client.conf"
  else
    echo "[警告] client.conf 权限不安全，routes-down 将使用默认值尽量兜底清理。" >&2
  fi
fi
TABLE_ID="${TABLE_ID:-20}"
MARK_ID="${MARK_ID:-438}"
BYPASS_MARK_ID="${BYPASS_MARK_ID:-439}"
NFT_TABLE="${NFT_TABLE:-getout_protect}"
TUN_NAME="${TUN_NAME:-tun0}"
RUNTIME_DNS_SERVERS="${RUNTIME_DNS_SERVERS:-2001:4860:4860::8888 2606:4700:4700::1111}"
RUNTIME_DNS_ENABLE="${RUNTIME_DNS_ENABLE:-1}"
RESOLV_ORIG="$CONF_DIR/resolv.conf.orig"
GAI_ORIG="$CONF_DIR/gai.conf.orig"
RESOLV_MARKER="$CONF_DIR/resolv.conf.getout"
GAI_MARKER="$CONF_DIR/gai.conf.getout"
RESOLV_META="$CONF_DIR/resolv.conf.meta"
RESOLV_TARGET_ORIG="$CONF_DIR/resolv.conf.target.orig"
GAI_META="$CONF_DIR/gai.conf.meta"

run() { "$@" 2>/dev/null || true; }
run_all() { while "$@" 2>/dev/null; do :; done; }
file_checksum() { [ -e "$1" ] || { echo missing; return 0; }; if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | awk '{print $1}' || echo unknown; else cksum "$1" 2>/dev/null | awk '{print $1":"$2}' || echo unknown; fi; }
restore_path() {
  local path="$1" backup="$2" meta="$3" marker="$4" label="$5" target_backup="${6:-}" exists=1 symlink_target="" marker_checksum current_checksum
  [ -f "$meta" ] && . "$meta" && exists="${EXISTS:-1}" && symlink_target="${SYMLINK_TARGET:-}"
  if [ ! -e "$backup" ]; then [ -f "$marker" ] && echo "[警告] $label 原始备份缺失，已保留当前内容，避免误恢复到未知状态。" >&2; return 0; fi
  current_checksum="$(file_checksum "$path")"; marker_checksum="$(cat "$marker" 2>/dev/null || true)"
  if [ -n "$marker_checksum" ] && [ "$marker_checksum" != "$current_checksum" ]; then echo "[警告] $label 在 getout 运行期间被外部修改，已保留当前内容；旧备份已归档，后续启动会重新备份当前状态。" >&2; mv -f "$backup" "$backup.conflict.$(date +%s)" 2>/dev/null || true; [ -n "$target_backup" ] && mv -f "$target_backup" "$target_backup.conflict.$(date +%s)" 2>/dev/null || true; rm -f "$meta" "$marker" 2>/dev/null || true; return 0; fi
  if [ "$exists" = "0" ]; then rm -f "$path" 2>/dev/null || true
  elif [ -n "$symlink_target" ]; then rm -f "$path" 2>/dev/null || true; ln -s "$symlink_target" "$path" 2>/dev/null || cp -a "$backup" "$path" 2>/dev/null || true; [ -n "$target_backup" ] && [ -e "$target_backup" ] && cp -a "$target_backup" "$(readlink -f "$path" 2>/dev/null || echo "$path")" 2>/dev/null || true
  else cp -a "$backup" "$path" 2>/dev/null || true; fi
  rm -f "$backup" "$meta" "$marker" "$target_backup" 2>/dev/null || true
}
is_ipv6() { [[ "${1:-}" == *:* ]]; }
is_ipv4() { [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
del4_to_main() { [ -n "${1:-}" ] && run_all ip rule del to "$1" lookup main pref "$2"; }
del6_to_main() { [ -n "${1:-}" ] && run_all ip -6 rule del to "$1" lookup main pref "$2"; }
ssh_listen_ports() {
  {
    if [ -n "${SSH_CONNECTION:-}" ]; then
      awk '{print $4}' <<<"$SSH_CONNECTION"
    fi
    if command -v sshd >/dev/null 2>&1; then
      sshd -T 2>/dev/null | awk '$1=="port" {print $2}'
    elif [ -x /usr/sbin/sshd ]; then
      /usr/sbin/sshd -T 2>/dev/null | awk '$1=="port" {print $2}'
    fi
    if command -v ss >/dev/null 2>&1; then
      ss -H -ltnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}'
    fi
  } | awk '/^[0-9]+$/ && $1 >= 1 && $1 <= 65535 {seen[$1]=1} END {for (p in seen) print p}' | sort -n
}
ssh_ports_text() {
  local ports="${SSH_PORTS:-}"
  [ -n "$ports" ] || ports="$(ssh_listen_ports | tr '\n' ' ')"
  [ -n "$ports" ] || ports="22"
  printf '%s\n' "$ports"
}
del_ssh_port_rules() {
  local port
  for port in $(ssh_ports_text) 22; do
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    run_all ip rule del ipproto tcp sport "$port" lookup main pref 6
    run_all ip -6 rule del ipproto tcp sport "$port" lookup main pref 6
    run_all ip rule del sport "$port" lookup main pref 6
    run_all ip -6 rule del sport "$port" lookup main pref 6
  done
}
restore_dns() {
  [ "$RUNTIME_DNS_ENABLE" = "1" ] || return 0
  restore_path /etc/resolv.conf "$RESOLV_ORIG" "$RESOLV_META" "$RESOLV_MARKER" /etc/resolv.conf "$RESOLV_TARGET_ORIG"
}

restore_gai() {
  if [ -f "$GAI_ORIG" ]; then
    restore_path /etc/gai.conf "$GAI_ORIG" "$GAI_META" "$GAI_MARKER" /etc/gai.conf
  elif [ -f "$GAI_MARKER" ]; then
    local tmp
    tmp="$(mktemp)" || return 0
    awk '
      $0 == "# getout managed priority begin" {skip=1; next}
      $0 == "# getout managed priority end" {skip=0; next}
      !skip {print}
    ' /etc/gai.conf 2>/dev/null > "$tmp" || true
    cat "$tmp" > /etc/gai.conf 2>/dev/null || true
    rm -f "$tmp" 2>/dev/null || true
    rm -f "$GAI_MARKER" 2>/dev/null || true
  fi
}

run nft delete table inet "$NFT_TABLE"
run_all ip rule del fwmark "$BYPASS_MARK_ID" lookup main pref 9
run_all ip -6 rule del fwmark "$BYPASS_MARK_ID" lookup main pref 9

run_all ip rule del fwmark "$MARK_ID" lookup main pref 10
run_all ip -6 rule del fwmark "$MARK_ID" lookup main pref 10

if is_ipv6 "${SSH_REMOTE_IP:-}"; then del6_to_main "${SSH_REMOTE_IP}/128" 5; elif is_ipv4 "${SSH_REMOTE_IP:-}"; then del4_to_main "${SSH_REMOTE_IP}/32" 5; fi
if is_ipv6 "${SOCKS_ADDRESS:-}"; then del6_to_main "${SOCKS_ADDRESS}/128" 6; elif is_ipv4 "${SOCKS_ADDRESS:-}"; then del4_to_main "${SOCKS_ADDRESS}/32" 6; fi
del_ssh_port_rules
for dns in $RUNTIME_DNS_SERVERS; do if is_ipv6 "$dns"; then del6_to_main "$dns/128" 7; elif is_ipv4 "$dns"; then del4_to_main "$dns/32" 7; fi; done

for cidr in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/4; do del4_to_main "$cidr" 16; done
for cidr in ::1/128 fe80::/10 fc00::/7 ff00::/8; do del6_to_main "$cidr" 16; done

run_all ip rule del lookup "$TABLE_ID" pref 20
run_all ip -6 rule del lookup "$TABLE_ID" pref 20
run_all ip route del default dev "$TUN_NAME" table "$TABLE_ID"
run_all ip -6 route del default dev "$TUN_NAME" table "$TABLE_ID"
restore_dns
restore_gai
EOF
  chmod +x "$ROUTES_UP" "$ROUTES_DOWN"
  chmod 700 "$ROUTES_UP" "$ROUTES_DOWN" 2>/dev/null || true
}

# --- 09 service state and entry/server mode ----------------------------------

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
  ensure_conf_dir
  local port user pass yn
  read -rp "请输入入口 SOCKS5 监听端口 [默认: 1080]: " port
  port="${port:-1080}"
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || fatal "端口无效：$port"

  read -rp "是否设置用户名密码? [Y/n]: " yn
  yn="${yn:-Y}"
  [[ "$yn" =~ ^[Yy]$ ]] || fatal "入口模式必须设置用户名密码，避免暴露为开放代理。"
  user=""; pass=""
  read -rp "用户名: " user
  [ -n "$user" ] || fatal "用户名不能为空。"
  read -rsp "密码: " pass; echo
  [ -n "$pass" ] || fatal "密码不能为空。"
  reject_url_unsafe "用户名" "$user"
  reject_url_unsafe "密码" "$pass"

  {
    printf 'PORT=%s\n' "$(shell_quote "$port")"
    printf 'USERNAME=%s\n' "$(shell_quote "$user")"
    printf 'PASSWORD=%s\n' "$(shell_quote "$pass")"
  } > "$SERVER_CONF"
  chmod_private_file "$SERVER_CONF"
}

write_gost_service() {
  [ -f "$SERVER_CONF" ] || fatal "未找到入口配置，请先修改入口信息。"
  assert_private_config "$SERVER_CONF"
  # shellcheck disable=SC1090
  . "$SERVER_CONF"
  local auth listen
  auth=""
  [ -n "${USERNAME:-}" ] && [ -n "${PASSWORD:-}" ] || fatal "入口模式必须配置用户名密码，请先修改入口信息。"
  reject_url_unsafe "用户名" "$USERNAME"
  reject_url_unsafe "密码" "${PASSWORD:-}"
  auth="${USERNAME}:${PASSWORD}@"
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
  chmod_private_file "$GOST_SERVICE"
  systemctl daemon-reload
}

start_server() {
  local snapshot
  require_root; require_debian; install_deps
  ensure_conf_dir
  snapshot="$(snapshot_server_files)"
  begin_server_rollback "$snapshot"
  stop_client_keep_config
  [ -x "$GOST_BIN" ] || download_gost
  [ -f "$SERVER_CONF" ] || prompt_server_info
  write_gost_service
  echo "server" > "$MODE_FILE"
  chmod_private_file "$MODE_FILE"
  restart_gost_with_rollback "$snapshot" enable
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    assert_private_config "$SERVER_CONF"
    # shellcheck disable=SC1090
    . "$SERVER_CONF"
    ufw allow "${PORT}/tcp" >/dev/null || true
  fi
  success "入口模式已启动。"
  status
}

stop_server() {
  require_root
  stop_server_keep_config
  success "入口模式已关闭。"
}

configure_server() {
  local snapshot was_active
  was_active=0; server_active && was_active=1
  ensure_conf_dir
  snapshot="$(snapshot_server_files)"
  begin_server_rollback "$snapshot"
  prompt_server_info
  [ -x "$GOST_BIN" ] || download_gost
  write_gost_service
  if [ "$was_active" = "1" ]; then
    restart_gost_with_rollback "$snapshot" restart
    systemctl enable getout-gost.service >/dev/null 2>&1 || true
    success "入口信息已更新并立即应用。"
    status
  else
    clear_runtime_rollback "$snapshot"
    success "入口信息已保存，启动入口模式后生效。"
    if tun_active; then
      warn "当前出口模式正在运行，入口信息不会影响当前出口模式。"
    fi
  fi
}

install_server() {
  start_server
}

# --- 10 outlet/client mode ----------------------------------------------------

current_priority_mode() {
  if [ -f "$CLIENT_CONF" ]; then
    assert_private_config "$CLIENT_CONF"
    # shellcheck disable=SC1090
    . "$CLIENT_CONF"
    case "${PRIORITY_MODE:-}" in
      v4|v6) echo "$PRIORITY_MODE"; return 0 ;;
    esac
  fi
  echo "$DEFAULT_PRIORITY_MODE"
}

warn_ssh_protection_status() {
  [ -f "$CLIENT_CONF" ] || return 0
  assert_private_config "$CLIENT_CONF"
  # shellcheck disable=SC1090
  . "$CLIENT_CONF"
  if [ -z "${SSH_REMOTE_IP:-}" ]; then
    warn "未检测到当前 SSH 来源 IP，仅依赖 SSH 监听端口保护回包。请确认 SSH 端口检测正确后再断开当前连接。"
  fi
  if [ -z "${SSH_PORTS:-}" ]; then
    warn "未检测到 SSH 监听端口，脚本将回退保护 22 端口；如果 SSH 使用非 22 端口，可能有断联风险。"
  else
    info "SSH 回包保护端口：${SSH_PORTS}"
  fi
}

runtime_dns_servers_text() {
  case "${1:-$(current_priority_mode)}" in
    v4) printf '%s\n' "${RUNTIME_DNS_V4_SERVERS[*]}" ;;
    *) printf '%s\n' "${RUNTIME_DNS_V6_SERVERS[*]}" ;;
  esac
}

write_client_conf() {
  local mode="$1" address="$2" port="$3" username="$4" password="$5" priority_mode="${6:-}" ssh_ip ssh_ports v4 v6 runtime_dns
  case "$priority_mode" in v4|v6) ;; *) priority_mode="$(current_priority_mode)" ;; esac
  ssh_ip="$(ssh_remote_ip || true)"
  ssh_ports="$(ssh_listen_ports | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  v4="$(main_ipv4 || true)"
  v6="$(main_ipv6 || true)"
  runtime_dns="$(runtime_dns_servers_text "$priority_mode")"
  ensure_conf_dir
  {
    printf 'MODE=%s\n' "$(shell_quote "$mode")"
    printf 'SOCKS_ADDRESS=%s\n' "$(shell_quote "$address")"
    printf 'SOCKS_PORT=%s\n' "$(shell_quote "$port")"
    printf 'SOCKS_USERNAME=%s\n' "$(shell_quote "$username")"
    printf 'SOCKS_PASSWORD=%s\n' "$(shell_quote "$password")"
    printf 'SSH_REMOTE_IP=%s\n' "$(shell_quote "$ssh_ip")"
    printf 'SSH_PORTS=%s\n' "$(shell_quote "$ssh_ports")"
    printf 'MAIN_IPV4=%s\n' "$(shell_quote "$v4")"
    printf 'MAIN_IPV6=%s\n' "$(shell_quote "$v6")"
    printf 'TABLE_ID=%s\n' "$(shell_quote "$TABLE_ID")"
    printf 'MARK_ID=%s\n' "$(shell_quote "$MARK_ID")"
    printf 'BYPASS_MARK_ID=%s\n' "$(shell_quote "$BYPASS_MARK_ID")"
    printf 'NFT_TABLE=%s\n' "$(shell_quote "$NFT_TABLE")"
    printf 'TUN_NAME=%s\n' "$(shell_quote "$TUN_NAME")"
    printf 'PRIORITY_MODE=%s\n' "$(shell_quote "$priority_mode")"
    printf 'RUNTIME_DNS_SERVERS=%s\n' "$(shell_quote "$runtime_dns")"
    printf 'RUNTIME_DNS_ENABLE=1\n'
  } > "$CLIENT_CONF"
  chmod_private_file "$CLIENT_CONF"
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
  assert_private_config "$CLIENT_CONF"
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
  assert_private_config "$CLIENT_CONF"
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
  chmod_private_file "$TUN_CONF"
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
  chmod_private_file "$TUN_SERVICE"
  systemctl daemon-reload
}

start_client() {
  local mode="$1"
  local snapshot
  require_root; require_debian; install_deps; ensure_tun
  ensure_conf_dir
  snapshot="$(snapshot_runtime_files)"
  begin_runtime_rollback "$snapshot"
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
  preflight_tun_runtime_with_rollback "$snapshot"
  echo "$mode" > "$MODE_FILE"
  chmod_private_file "$MODE_FILE"
  write_tun_service "$mode"
  warn_ssh_protection_status
  restart_tun_with_rollback "$snapshot" enable
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
  ensure_conf_dir
  local mode snapshot was_active
  was_active=0; tun_active && was_active=1
  snapshot="$(snapshot_runtime_files)"
  begin_runtime_rollback "$snapshot"
  if tun_active; then
    mode="$(current_mode)"
    [ "$mode" = "v4" ] || [ "$mode" = "dual" ] || mode="v4"
  elif [ -f "$CLIENT_CONF" ]; then
    assert_private_config "$CLIENT_CONF"
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
  preflight_tun_runtime_with_rollback "$snapshot"
  echo "$mode" > "$MODE_FILE"
  chmod_private_file "$MODE_FILE"
  if [ "$was_active" = "1" ]; then
    systemctl stop getout-tun.service 2>/dev/null || true
    cleanup_rules
    warn_ssh_protection_status
    restart_tun_with_rollback "$snapshot" enable
    success "出口信息已更新并立即应用。"
    status
  else
    clear_runtime_rollback "$snapshot"
    success "出口信息已保存，启动 V4/双栈模式后生效。"
    if server_active; then
      warn "当前入口模式正在运行，出口信息不会影响当前入口模式。"
    fi
  fi
}

priority_action_label() {
  case "$(current_priority_mode)" in
    v4) echo "切换至 V6 优先模式" ;;
    *) echo "切换至 V4 优先模式" ;;
  esac
}

switch_priority_mode() {
  require_root; require_debian; install_deps
  [ -f "$CLIENT_CONF" ] || fatal "未找到出口配置，请先修改出口信息。"
  local mode address port username password priority_mode snapshot was_active
  was_active=0; tun_active && was_active=1
  snapshot="$(snapshot_runtime_files)"
  begin_runtime_rollback "$snapshot"
  assert_private_config "$CLIENT_CONF"
  # shellcheck disable=SC1090
  . "$CLIENT_CONF"
  mode="${MODE:-v4}"
  address="${SOCKS_ADDRESS:-}"
  port="${SOCKS_PORT:-}"
  username="${SOCKS_USERNAME:-}"
  password="${SOCKS_PASSWORD:-}"
  [ -n "$address" ] && [ -n "$port" ] || fatal "出口配置不完整，请先修改出口信息。"
  case "$(current_priority_mode)" in
    v4) priority_mode="v6" ;;
    *) priority_mode="v4" ;;
  esac
  write_client_conf "$mode" "$address" "$port" "$username" "$password" "$priority_mode"
  write_tun_config
  write_routes_scripts
  write_tun_service "$mode"
  preflight_tun_runtime_with_rollback "$snapshot"
  if [ "$was_active" = "1" ]; then
    systemctl stop getout-tun.service 2>/dev/null || true
    cleanup_rules
    warn_ssh_protection_status
    restart_tun_with_rollback "$snapshot" enable
  else
    clear_runtime_rollback "$snapshot"
  fi
  case "$priority_mode" in
    v4) success "已切换至 V4 优先模式。" ;;
    v6) success "已切换至 V6 优先模式。" ;;
  esac
  status
}

install_tun() {
  start_client "$1"
}

# --- 11 lifecycle, status, diagnostics, and CLI ------------------------------

cleanup_rules() {
  [ -x "$ROUTES_DOWN" ] && "$ROUTES_DOWN" >/dev/null 2>&1 || true
  fallback_cleanup_rules
  restore_managed_files_fallback
}

restart_getout() {
  require_root
  if server_active; then
    local snapshot
    ensure_conf_dir
    snapshot="$(snapshot_server_files)"
    begin_server_rollback "$snapshot"
    [ -f "$SERVER_CONF" ] || fatal "未找到入口配置，请先修改入口信息。"
    chmod_private_file "$SERVER_CONF"
    write_gost_service
    echo "server" > "$MODE_FILE"
    chmod_private_file "$MODE_FILE"
    restart_gost_with_rollback "$snapshot" restart
    systemctl enable getout-gost.service >/dev/null 2>&1 || true
    systemctl disable getout-tun.service >/dev/null 2>&1 || true
    success "入口模式已重启。"
    status
  elif tun_active; then
    local mode address port username password priority_mode snapshot
    snapshot="$(snapshot_runtime_files)"
    begin_runtime_rollback "$snapshot"
    mode="$(current_mode)"
    [ "$mode" = "v4" ] || [ "$mode" = "dual" ] || mode="v4"
    if [ -f "$CLIENT_CONF" ]; then
      assert_private_config "$CLIENT_CONF"
      # shellcheck disable=SC1090
      . "$CLIENT_CONF"
      address="${SOCKS_ADDRESS:-}"
      port="${SOCKS_PORT:-}"
      username="${SOCKS_USERNAME:-}"
      password="${SOCKS_PASSWORD:-}"
      priority_mode="${PRIORITY_MODE:-$(current_priority_mode)}"
      [ -n "$address" ] && [ -n "$port" ] || fatal "出口配置不完整，请先修改出口信息。"
      write_client_conf "$mode" "$address" "$port" "$username" "$password" "$priority_mode"
      write_tun_config
      write_routes_scripts
      write_tun_service "$mode"
      preflight_tun_runtime_with_rollback "$snapshot"
    fi
    cleanup_rules
    warn_ssh_protection_status
    restart_tun_with_rollback "$snapshot" restart
    systemctl enable getout-tun.service >/dev/null 2>&1 || true
    systemctl disable getout-gost.service >/dev/null 2>&1 || true
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
    assert_private_config "$SERVER_CONF"
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
    assert_private_config "$CLIENT_CONF"
    # shellcheck disable=SC1090
    . "$CLIENT_CONF"
    echo "SOCKS5: [${SOCKS_ADDRESS:-}]:${SOCKS_PORT:-}"
    case "${PRIORITY_MODE:-$DEFAULT_PRIORITY_MODE}" in
      v4) echo "优先模式: V4 优先" ;;
      *) echo "优先模式: V6 优先" ;;
    esac
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

doctor_check() {
  local failed=0 mode
  mode="$(current_mode)"
  echo -e "${CYAN}========== getout doctor ==========${NC}"
  echo "版本: $SCRIPT_VERSION"
  echo

  check_ok() { echo -e "${GREEN}[OK]${NC} $*"; }
  check_warn() { echo -e "${YELLOW}[警告]${NC} $*"; }
  check_fail() { echo -e "${RED}[错误]${NC} $*"; failed=1; }

  [ "${EUID:-$(id -u)}" -eq 0 ] && check_ok "root 权限" || check_fail "请使用 root 权限运行 doctor。"
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${ID:-}" = "debian" ] && check_ok "Debian 系统：${PRETTY_NAME:-debian}" || check_fail "当前系统不是 Debian：${PRETTY_NAME:-unknown}"
  else
    check_fail "无法读取 /etc/os-release。"
  fi
  [ -c /dev/net/tun ] && check_ok "/dev/net/tun 可用" || check_fail "未检测到 /dev/net/tun。"
  command -v systemctl >/dev/null 2>&1 && check_ok "systemd/systemctl 可用" || check_fail "未找到 systemctl。"
  command -v nft >/dev/null 2>&1 && check_ok "nftables 可用" || check_fail "未找到 nft。"
  command -v ip >/dev/null 2>&1 && check_ok "iproute2 可用" || check_fail "未找到 ip 命令。"
  command -v curl >/dev/null 2>&1 && check_ok "curl 可用" || check_warn "未找到 curl，下载/状态测试可能受影响。"
  command -v sha256sum >/dev/null 2>&1 && check_ok "sha256sum 可用" || check_warn "缺少 sha256sum，无法做更新完整性校验。"

  if [ -d "$CONF_DIR" ]; then
    check_ok "配置目录存在：$CONF_DIR"
    find "$CONF_DIR" -maxdepth 0 -type d -user root ! -perm /077 | grep -q . && check_ok "配置目录权限安全" || check_fail "配置目录权限不安全，应为 root 且 group/other 不可访问。"
  else
    check_warn "配置目录不存在：$CONF_DIR"
  fi

  if [ -f "$SERVER_CONF" ]; then
    find "$SERVER_CONF" -maxdepth 0 -type f -user root ! -perm /022 | grep -q . && check_ok "入口配置权限安全" || check_fail "入口配置权限不安全。"
  else
    check_warn "入口配置不存在。"
  fi
  if [ -f "$CLIENT_CONF" ]; then
    find "$CLIENT_CONF" -maxdepth 0 -type f -user root ! -perm /022 | grep -q . && check_ok "出口配置权限安全" || check_fail "出口配置权限不安全。"
  else
    check_warn "出口配置不存在。"
  fi

  [ -x "$GOST_BIN" ] && check_ok "入口二进制存在：$GOST_BIN" || check_warn "入口二进制不存在，启动入口模式时会下载。"
  [ -x "$TUN_BIN" ] && check_ok "出口二进制存在：$TUN_BIN" || check_warn "出口二进制不存在，启动出口模式时会下载。"
  [ -f "$GOST_SERVICE" ] && check_ok "入口 systemd unit 存在" || check_warn "入口 systemd unit 不存在。"
  [ -f "$TUN_SERVICE" ] && check_ok "出口 systemd unit 存在" || check_warn "出口 systemd unit 不存在。"

  if [ -f "$ROUTES_UP" ] && [ -f "$ROUTES_DOWN" ]; then
    bash -n "$ROUTES_UP" && bash -n "$ROUTES_DOWN" && check_ok "路由脚本语法正常" || check_fail "路由脚本语法异常。"
  else
    check_warn "路由脚本不存在，启动出口模式时会生成。"
  fi

  if [ "$mode" = "v4" ] || [ "$mode" = "dual" ]; then
    preflight_tun_runtime && check_ok "出口 runtime preflight 通过" || check_fail "出口 runtime preflight 失败。"
  else
    check_warn "当前不是出口模式，跳过出口 runtime preflight。"
  fi

  if [ "$failed" = "0" ]; then
    success "doctor 检查完成，未发现阻塞问题。"
  else
    fatal "doctor 检查发现阻塞问题，请按上方错误处理。"
  fi
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
  echo "6.$(priority_action_label)"
  echo "7.重启 getout"
  echo "8.查看状态"
  echo "9.环境诊断"
  echo "10.更新 getout"
  echo "11.卸载 getout"
  echo "12.退出"
  echo
  read -rp "请选择 [1-12]: " choice
  case "$choice" in
    1) if server_active; then stop_server; else start_server; fi ;;
    2) configure_server ;;
    3) if client_mode_active v4; then stop_client; else start_client v4; fi ;;
    4) if client_mode_active dual; then stop_client; else start_client dual; fi ;;
    5) configure_client ;;
    6) switch_priority_mode ;;
    7) restart_getout ;;
    8) status ;;
    9) doctor_check ;;
    10) update_getout ;;
    11) read -rp "确认卸载 getout? [y/N]: " yn; [[ "$yn" =~ ^[Yy]$ ]] && uninstall_all || echo "已取消" ;;
    12) exit 0 ;;
    *) fatal "无效选项。" ;;
  esac
}

usage() {
  cat <<EOF
用法：getout [server|v4|dual|stop|restart|status|doctor|check|update|uninstall]

server     启动入口模式，复用已有入口配置；没有配置时询问
v4         启动 V4 单栈出口模式，复用已有出口配置；没有配置时询问
dual       启动 V4+V6 双栈出口模式，复用已有出口配置；没有配置时询问
stop       关闭当前运行中的 getout 模式，并关闭对应自启动
restart    重启当前运行中的 getout 模式
status     查看状态
doctor     检查系统环境、配置权限、服务文件和出口预检
check      同 doctor
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
    -h|--help|help) ;;
    *) secure_existing_files ;;
  esac
  case "${1:-}" in
    uninstall|remove|un|doctor|check|-h|--help|help) ;;
    *) ensure_global_command ;;
  esac

  case "${1:-}" in
    server) start_server ;;
    v4) start_client v4 ;;
    dual) start_client dual ;;
    stop) stop_current ;;
    restart) restart_getout ;;
    status) status ;;
    doctor|check) doctor_check ;;
    update) update_getout ;;
    uninstall|remove|un) uninstall_all ;;
    -h|--help|help) usage ;;
    "") menu ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
