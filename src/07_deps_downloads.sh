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

