# --- 13 lifecycle, status, and diagnostics -----------------------------------

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

