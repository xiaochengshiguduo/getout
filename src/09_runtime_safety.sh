# --- 09 cleanup, preflight, and restart wrappers -----------------------------

run_quiet() { "$@" 2>/dev/null || true; }
run_all_quiet() { while "$@" 2>/dev/null; do :; done; }

fallback_cleanup_rules() {
  local port cidr dns
  # Remove global policy routing first so live SSH/control-plane replies return
  # to the main table before we remove the explicit protection rules.
  run_all_quiet ip rule del lookup "$TABLE_ID" pref 20
  run_all_quiet ip -6 rule del lookup "$TABLE_ID" pref 20
  run_all_quiet ip route del default dev "$TUN_NAME" table "$TABLE_ID"
  run_all_quiet ip -6 route del default dev "$TUN_NAME" table "$TABLE_ID"

  run_quiet nft delete table inet "$NFT_TABLE"
  run_all_quiet ip rule del fwmark "$BYPASS_MARK_ID" lookup main pref 9
  run_all_quiet ip -6 rule del fwmark "$BYPASS_MARK_ID" lookup main pref 9
  run_all_quiet ip rule del fwmark "$MARK_ID" lookup main pref 10
  run_all_quiet ip -6 rule del fwmark "$MARK_ID" lookup main pref 10
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

preflight_route_rules() {
  ensure_nftables || return 0
  nft delete table inet getout_preflight 2>/dev/null || true
  nft add table inet getout_preflight >/dev/null 2>&1 || { err "nftables 预检失败：无法创建 inet table。"; return 1; }
  nft add chain inet getout_preflight prerouting '{ type filter hook prerouting priority -150; policy accept; }' >/dev/null 2>&1 || { nft delete table inet getout_preflight 2>/dev/null || true; err "nftables 预检失败：当前内核不支持所需 prerouting 规则。"; return 1; }
  nft add chain inet getout_preflight output '{ type route hook output priority -150; policy accept; }' >/dev/null 2>&1 || { nft delete table inet getout_preflight 2>/dev/null || true; err "nftables 预检失败：当前内核不支持所需 output route hook。"; return 1; }
  nft add rule inet getout_preflight prerouting iifname != "$TUN_NAME" ct state new fib daddr type local ct mark set "$BYPASS_MARK_ID" >/dev/null 2>&1 || { nft delete table inet getout_preflight 2>/dev/null || true; err "nftables 预检失败：当前内核不支持 conntrack/fib 标记规则。"; return 1; }
  nft add rule inet getout_preflight output ct mark "$BYPASS_MARK_ID" meta mark set "$BYPASS_MARK_ID" >/dev/null 2>&1 || { nft delete table inet getout_preflight 2>/dev/null || true; err "nftables 预检失败：当前内核不支持 ct mark 输出规则。"; return 1; }
  nft delete table inet getout_preflight 2>/dev/null || true
}

preflight_tun_runtime() {
  [ -x "$TUN_BIN" ] || { err "未找到可执行 tun2socks：$TUN_BIN"; return 1; }
  [ -s "$TUN_CONF" ] || { err "tun2socks 配置为空或不存在：$TUN_CONF"; return 1; }
  [ -x "$ROUTES_UP" ] || { err "routes-up.sh 不可执行：$ROUTES_UP"; return 1; }
  [ -x "$ROUTES_DOWN" ] || { err "routes-down.sh 不可执行：$ROUTES_DOWN"; return 1; }
  bash -n "$ROUTES_UP" || { err "routes-up.sh 语法校验失败。"; return 1; }
  bash -n "$ROUTES_DOWN" || { err "routes-down.sh 语法校验失败。"; return 1; }
  preflight_route_rules
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
  warn "入口启动失败，已尝试恢复旧入口配置和旧 systemd 文件。"
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


preflight_wg_runtime() {
  command -v wg >/dev/null 2>&1 || { err "未找到 wg 命令，请安装 wireguard-tools"; return 1; }
  command -v wg-quick >/dev/null 2>&1 || { err "未找到 wg-quick 命令，请安装 wireguard-tools"; return 1; }
  [ -s "$WG_CONF" ] || { err "WireGuard 配置为空或不存在：$WG_CONF"; return 1; }
  [ -x "$ROUTES_UP" ] || { err "routes-up.sh 不可执行：$ROUTES_UP"; return 1; }
  [ -x "$ROUTES_DOWN" ] || { err "routes-down.sh 不可执行：$ROUTES_DOWN"; return 1; }
  bash -n "$ROUTES_UP" || { err "routes-up.sh 语法校验失败。"; return 1; }
  bash -n "$ROUTES_DOWN" || { err "routes-down.sh 语法校验失败。"; return 1; }
  preflight_route_rules
}

preflight_wg_runtime_with_rollback() {
  local snapshot="$1"
  preflight_wg_runtime || {
    restore_runtime_or_warn "$snapshot"
    exit 1
  }
}

restart_wg_with_rollback() {
  local snapshot="$1" action="${2:-restart}"
  # 清理可能残留的接口（服务 failed 后 ExecStopPost 未执行）
  if ip link show getout-wg0 &>/dev/null; then
    wg-quick down "$WG_CONF" 2>/dev/null || ip link del getout-wg0 2>/dev/null || true
  fi
  if [ "$action" = "enable" ]; then
    systemctl enable --now getout-wg.service
  else
    systemctl restart getout-wg.service
  fi
  sleep 2
  if ! systemctl is-active --quiet getout-wg.service; then
    restore_runtime_or_warn "$snapshot"
    systemctl restart getout-wg.service 2>/dev/null || true
    fatal "getout-wg.service 启动失败，请查看：journalctl -u getout-wg.service -e"
  fi
  clear_runtime_rollback "$snapshot"
}
