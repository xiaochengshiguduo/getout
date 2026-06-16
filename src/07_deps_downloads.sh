# --- 07 host prerequisites and binary downloads ------------------------------

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
    [systemctl]=systemd [sysctl]=procps [awk]=mawk [grep]=grep [sed]=sed [wg]=wireguard-tools [modprobe]=kmod
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

# 确保 nftables 可用；交互模式下询问是否安装，非交互模式下自动安装。
# 返回 0 = 可用，1 = 用户拒绝或安装失败。
ensure_nftables() {
  command -v nft >/dev/null 2>&1 && return 0
  if [ -t 0 ] && [ -t 1 ]; then
    echo -n "未找到 nft，nftables 用于保护外部入站连接回包（可选）。是否安装？[Y/n] " >&2
    local reply
    read -r reply
    if [[ "$reply" =~ ^[Nn]$ ]]; then
      info "跳过 nftables 安装，外部入站回包保护将不可用。"
      return 1
    fi
  fi
  info "正在安装 nftables..."
  apt-get update -y >/dev/null 2>&1
  apt-get install -y nftables || { err "nftables 安装失败。"; return 1; }
  command -v nft >/dev/null 2>&1 || { err "nftables 安装后仍未找到 nft 命令。"; return 1; }
  success "nftables 已安装。"
}

ensure_wgmod() {
  if ! lsmod 2>/dev/null | grep -q '^wireguard\b'; then
    modprobe wireguard 2>/dev/null || fatal "无法加载 WireGuard 内核模块 (wireguard.ko)，请确认内核版本 >= 5.6 或已安装 wireguard-dkms。"
  fi
}

ensure_wg() {
  command -v wg >/dev/null 2>&1 || fatal "未找到 wg 命令，请先安装 wireguard-tools：apt install wireguard-tools"
  ensure_wgmod
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

verify_download_sha256() {
  local file="$1" expected="$2" label="$3" checksum
  [ -n "$expected" ] || fatal "$label 缺少 SHA256 校验值，已取消安装。"
  command -v sha256sum >/dev/null 2>&1 || fatal "缺少 sha256sum，无法校验 $label。"
  checksum="$(sha256sum "$file" | awk '{print $1}')"
  [ "$checksum" = "$expected" ] || fatal "$label SHA256 校验失败，已取消安装。"
}

download_gost() {
  local arch url tmp expected
  arch="$(arch_gost)"
  url="https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost-linux-${arch}-${GOST_VERSION}.gz"
  expected="${GETOUT_GOST_SHA256:-${GOST_SHA256[$arch]:-}}"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  info "下载 gost：$url"
  download_file "$url" "$tmp" || fatal "gost 下载失败：常规下载和 DNS64 均不可用。"
  verify_download_sha256 "$tmp" "$expected" "gost ${GOST_VERSION} linux-${arch}"
  gunzip -c "$tmp" > "$GOST_BIN"
  chmod +x "$GOST_BIN"
  rm -f "$tmp"
  trap - RETURN
}

download_hev() {
  local arch url tmp expected
  arch="$(arch_hev)"
  url="https://github.com/heiher/hev-socks5-tunnel/releases/download/${HEV_VERSION}/hev-socks5-tunnel-linux-${arch}"
  expected="${GETOUT_HEV_SHA256:-${HEV_SHA256[$arch]:-}}"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  info "下载 hev-socks5-tunnel：$url"
  download_file "$url" "$tmp" || fatal "hev-socks5-tunnel 下载失败：常规下载和 DNS64 均不可用。"
  verify_download_sha256 "$tmp" "$expected" "hev-socks5-tunnel ${HEV_VERSION} linux-${arch}"
  install -m 0755 "$tmp" "$TUN_BIN"
  rm -f "$tmp"
  trap - RETURN
}

download_wg_service() {
  # WireGuard 使用系统自带的 wg-quick@.service，无需下载额外二进制。
  # 此函数仅用于确认 wg-quick 命令可用。
  command -v wg-quick >/dev/null 2>&1 || fatal "未找到 wg-quick 命令，请先安装 wireguard-tools：apt install wireguard-tools"
}
