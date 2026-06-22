# --- 13 lifecycle, status, and diagnostics -----------------------------------

cleanup_rules() {
  [ -x "$ROUTES_DOWN" ] && "$ROUTES_DOWN" >/dev/null 2>&1 || true
  fallback_cleanup_rules
  restore_managed_files_fallback
}

restart_server_mode() {
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
  systemctl disable getout-tun.service getout-wg.service >/dev/null 2>&1 || true
  success "入口已重启。"
}

restart_wg_server_mode() {
  local snapshot
  ensure_conf_dir
  snapshot="$(snapshot_server_files)"
  begin_server_rollback "$snapshot"
  [ -f "$SERVER_CONF" ] || fatal "未找到入口配置，请先修改入口信息。"
  assert_private_config "$SERVER_CONF"
  # shellcheck disable=SC1090
  . "$SERVER_CONF"
  [ "${SERVER_MODE:-}" = "wireguard" ] || fatal "入口配置不是 WireGuard 模式。"
  write_wg_server_service
  if ip link show getout-wg0 &>/dev/null; then
    wg-quick down "$WG_CONF" 2>/dev/null || ip link del getout-wg0 2>/dev/null || true
  fi
  restart_gw_service_with_server_rollback "$snapshot"
  systemctl enable getout-wg.service >/dev/null 2>&1 || true
  systemctl disable getout-gost.service getout-tun.service >/dev/null 2>&1 || true
  success "入口 WireGuard 模式已重启。"
}

restart_gw_service_with_server_rollback() {
  local snapshot="$1"
  systemctl restart getout-wg.service
  sleep 2
  if ! systemctl is-active --quiet getout-wg.service; then
    restore_server_or_warn "$snapshot"
    fatal "getout-wg.service 启动失败，请查看：journalctl -u getout-wg.service -e"
  fi
  clear_runtime_rollback "$snapshot"
}

rewrite_tun_runtime_for_restart() {
  local mode="$1" address port username password priority_mode
  [ -f "$CLIENT_CONF" ] || return 0
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
}

restart_tun_mode() {
  local mode="$1" snapshot
  snapshot="$(snapshot_runtime_files)"
  begin_runtime_rollback "$snapshot"
  rewrite_tun_runtime_for_restart "$mode"
  preflight_tun_runtime_with_rollback "$snapshot"
  cleanup_rules
  warn_ssh_protection_status
  restart_tun_with_rollback "$snapshot" restart
  systemctl enable getout-tun.service >/dev/null 2>&1 || true
  systemctl disable getout-gost.service getout-wg.service >/dev/null 2>&1 || true
  success "出口模式已重启。"
}

rewrite_wg_client_runtime_for_restart() {
  local mode="$1"
  [ -f "$CLIENT_CONF" ] || return 0
  assert_private_config "$CLIENT_CONF"
  # shellcheck disable=SC1090
  . "$CLIENT_CONF"
  [ "${TRANSPORT:-}" = "wireguard" ] || fatal "出口配置不是 WireGuard 模式。"
  write_wg_config
  write_routes_scripts
  write_wg_service "$mode"
}

restart_wg_client_mode() {
  local mode="$1" snapshot
  snapshot="$(snapshot_runtime_files)"
  begin_runtime_rollback "$snapshot"
  rewrite_wg_client_runtime_for_restart "$mode"
  preflight_wg_runtime_with_rollback "$snapshot"
  cleanup_rules
  warn_ssh_protection_status
  restart_wg_with_rollback "$snapshot" restart
  systemctl enable getout-wg.service >/dev/null 2>&1 || true
  systemctl disable getout-gost.service getout-tun.service >/dev/null 2>&1 || true
  success "WG 出口已重启。"
}

restart_getout() {
  require_root
  local mode_file_content
  mode_file_content="$(current_mode)"
  if server_active && [ "$mode_file_content" = "server" ]; then
    restart_server_mode
  elif wg_server_active && [ "$mode_file_content" = "wg-server" ]; then
    restart_wg_server_mode
  elif tun_active && [[ "$mode_file_content" =~ ^(v4|dual)$ ]]; then
    restart_tun_mode "$mode_file_content"
  elif wg_client_active && [[ "$mode_file_content" =~ ^wg- ]]; then
    restart_wg_client_mode "$mode_file_content"
  else
    warn "当前 getout 未运行，请选择 1/3/4/5/6 启动。"
    return 0
  fi
  status
}

uninstall_all() {
  require_root
  cleanup_rules
  systemctl stop getout-tun.service getout-gost.service getout-wg.service 2>/dev/null || true
  systemctl disable getout-tun.service getout-gost.service getout-wg.service 2>/dev/null || true
  # 清理 WireGuard 接口（如果是 getout 管理的）
  if [ -f "$WG_CONF" ]; then
    wg-quick down "$WG_CONF" 2>/dev/null || true
  fi
  rm -f "$TUN_SERVICE" "$GOST_SERVICE" "$WG_SERVICE"
  rm -f "$TUN_BIN" "$GOST_BIN"
  rm -f "$INSTALL_PATH"
  rm -rf "$CONF_DIR"
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed getout-tun.service getout-gost.service getout-wg.service 2>/dev/null || true
  success "getout 已卸载并清理完成。"
}

print_status_address() {
  local first="${1:-}" second="${2:-}"
  if [ -n "$first" ] && [ -n "$second" ]; then
    echo "地址: ${first}"
    echo "      ${second}"
  elif [ -n "$first" ]; then
    echo "地址: ${first}"
  elif [ -n "$second" ]; then
    echo "地址: ${second}"
  fi
}

print_current_status() {
  local mode="$1" gost_state="$2" tun_state="$3" wg_state="$4"
  echo "当前运行:"
  case "$mode" in
    server) echo "入口 SOCKS5: $gost_state"; echo "出口: 已停止"; echo "当前模式: server" ;;
    wg-server) echo "入口 WireGuard: $wg_state"; echo "出口: 已停止"; echo "当前模式: wg-server" ;;
    v4) echo "入口: $gost_state"; echo "s5-V4 单栈模式: $tun_state"; echo "当前模式: v4" ;;
    dual) echo "入口: $gost_state"; echo "V4+V6 双栈模式: $tun_state"; echo "当前模式: dual" ;;
    wg-v4) echo "入口: $gost_state"; echo "WG-V4 单栈模式: $wg_state"; echo "当前模式: wg-v4" ;;
    wg-dual) echo "入口: $gost_state"; echo "WG-V4+V6 双栈模式: $wg_state"; echo "当前模式: wg-dual" ;;
    *) echo "入口: $gost_state"; echo "当前模式: none" ;;
  esac
}

print_autostart_status() {
  echo "自启动:"
  echo "入口 SOCKS5: $(service_enabled_text getout-gost.service)"
  echo "出口 tun2socks: $(service_enabled_text getout-tun.service)"
  echo "WireGuard: $(service_enabled_text getout-wg.service)"
}

print_server_info() {
  echo "入口信息:"
  if [ ! -f "$SERVER_CONF" ]; then echo "未配置"; return 0; fi
  assert_private_config "$SERVER_CONF"
  # shellcheck disable=SC1090
  . "$SERVER_CONF"
  local ipv4 ipv6
  ipv4="$(main_ipv4 || true)"
  ipv6="$(main_ipv6 || true)"
  if [ "${SERVER_MODE:-}" = "wireguard" ]; then
    echo "类型: WireGuard"
    print_status_address "$ipv4" "$ipv6"
    echo "端口: ${LISTEN_PORT:-}"
    if [ -n "${PEER_PRIVATE_KEY:-}" ]; then
      echo "私钥: ${PEER_PRIVATE_KEY}"
    else
      echo "私钥: <旧配置未保存客户端私钥，请重新配置入口>"
    fi
    local server_pub
    server_pub="$(printf '%s' "${PRIVATE_KEY:-}" | wg pubkey 2>/dev/null || echo "<无法推导>")"
    echo "公钥: ${server_pub}"
  else
    echo "类型: SOCKS5"
    print_status_address "$ipv4" "$ipv6"
    echo "端口: ${PORT:-}"
    if [ -n "${USERNAME:-}" ]; then
      echo "用户名: ${USERNAME:-}"
      echo "密码: ${PASSWORD:-}"
    fi
  fi
}

print_client_info() {
  echo "出口信息:"
  if [ ! -f "$CLIENT_CONF" ]; then echo "未配置"; return 0; fi
  assert_private_config "$CLIENT_CONF"
  # shellcheck disable=SC1090
  . "$CLIENT_CONF"
  if [ "${TRANSPORT:-}" = "wireguard" ]; then
    echo "类型: WireGuard"
    local addr="${WG_SERVER_ADDRESS:-}" port="${WG_SERVER_PORT:-}"
    local v4_part="${addr%%,*}" v6_part="${addr#*,}"
    v4_part="${v4_part// /}"; v6_part="${v6_part# }"
    if [ -n "$v6_part" ] && [ "$v6_part" != "$addr" ]; then
      print_status_address "$v4_part" "$v6_part"
    else
      print_status_address "$addr"
    fi
    echo "端口: ${port}"
    echo "私钥: ${WG_CLIENT_PRIVATE_KEY:-}"
    echo "公钥: ${WG_SERVER_PUBLIC_KEY:-}"
  else
    echo "类型: SOCKS5"
    echo "地址: ${SOCKS_ADDRESS:-}"
    echo "端口: ${SOCKS_PORT:-}"
    echo "用户名: ${SOCKS_USERNAME:-}"
    echo "密码: ${SOCKS_PASSWORD:-}"
  fi
  case "${PRIORITY_MODE:-$DEFAULT_PRIORITY_MODE}" in
    v4) echo "优先模式: V4 优先" ;;
    *) echo "优先模式: V6 优先" ;;
  esac
}

print_outlet_test() {
  echo "出口测试:"
  echo -n "IPv4: "; curl -4 -s --connect-timeout 8 --max-time 12 https://api.ipify.org || curl -4 -s --connect-timeout 8 --max-time 12 http://v4.ident.me || echo -n "失败"; echo
  echo -n "IPv6: "; curl -6 -s --connect-timeout 8 --max-time 12 https://api64.ipify.org || curl -6 -s --connect-timeout 8 --max-time 12 http://v6.ident.me || echo -n "失败"; echo
}

status() {
  local mode gost_state tun_state wg_state
  mode="$(current_mode)"
  gost_state="已停止"; tun_state="已停止"; wg_state="已停止"
  server_active && gost_state="运行中"
  tun_active && tun_state="运行中"
  (wg_server_active || wg_client_active) && wg_state="运行中"

  echo -e "${CYAN}========== getout 状态 ==========${NC}"
  echo "版本: $SCRIPT_VERSION"
  echo
  print_current_status "$mode" "$gost_state" "$tun_state" "$wg_state"
  echo
  print_autostart_status
  echo
  print_server_info
  echo
  print_client_info
  echo
  print_outlet_test
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
  command -v nft >/dev/null 2>&1 && check_ok "nftables 可用" || check_warn "未找到 nft（可选，入站连接回包保护将跳过；出口启动时会提示安装）。"
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

  [ -x "$GOST_BIN" ] && check_ok "入口二进制存在：$GOST_BIN" || check_warn "入口二进制不存在，启动 SOCKS5 模式时会下载。"
  [ -x "$TUN_BIN" ] && check_ok "出口二进制存在：$TUN_BIN" || check_warn "出口二进制不存在，启动 tun2socks 出口时会下载。"
  command -v wg >/dev/null 2>&1 && check_ok "wg 命令可用" || check_warn "未找到 wg 命令，WireGuard 模式需要 wireguard-tools。"
  command -v wg-quick >/dev/null 2>&1 && check_ok "wg-quick 命令可用" || check_warn "未找到 wg-quick 命令，WireGuard 模式需要 wireguard-tools。"
  [ -f "$GOST_SERVICE" ] && check_ok "入口 SOCKS5 systemd unit 存在" || check_warn "入口 SOCKS5 systemd unit 不存在。"
  [ -f "$TUN_SERVICE" ] && check_ok "出口 tun2socks systemd unit 存在" || check_warn "出口 tun2socks systemd unit 不存在。"
  [ -f "$WG_SERVICE" ] && check_ok "WireGuard systemd unit 存在" || check_warn "WireGuard systemd unit 不存在。"

  if [ -f "$ROUTES_UP" ] && [ -f "$ROUTES_DOWN" ]; then
    bash -n "$ROUTES_UP" && bash -n "$ROUTES_DOWN" && check_ok "路由脚本语法正常" || check_fail "路由脚本语法异常。"
  else
    check_warn "路由脚本不存在，启动出口时会生成。"
  fi

  if [ "$mode" = "v4" ] || [ "$mode" = "dual" ]; then
    preflight_tun_runtime && check_ok "出口 tun2socks runtime preflight 通过" || check_fail "出口 tun2socks runtime preflight 失败。"
  elif [[ "$mode" =~ ^wg- ]]; then
    preflight_wg_runtime && check_ok "出口 WireGuard runtime preflight 通过" || check_fail "出口 WireGuard runtime preflight 失败。"
  else
    check_warn "当前不是出口模式，跳过出口 runtime preflight。"
  fi

  if [ "$failed" = "0" ]; then
    success "doctor 检查完成，未发现阻塞问题。"
  else
    fatal "doctor 检查发现阻塞问题，请按上方错误处理。"
  fi
}

