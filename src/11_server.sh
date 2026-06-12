# --- 11 service state and entry/server mode ----------------------------------

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
wg_server_active() { local mode; mode="$(current_mode)"; service_active getout-wg.service && [ "$mode" = "wg-server" ]; }
wg_client_active() {
  local mode="$(current_mode)"
  service_active getout-wg.service && [[ "$mode" =~ ^wg- ]]
}
any_client_active() { tun_active || wg_client_active; }
client_mode_active() {
  local mode="$(current_mode)"
  if [[ "$mode" =~ ^wg- ]]; then
    wg_client_active && [ "$mode" = "$1" ]
  else
    tun_active && [ "$mode" = "$1" ]
  fi
}

stop_server_keep_config() {
  systemctl stop getout-gost.service 2>/dev/null || true
  systemctl disable getout-gost.service 2>/dev/null || true
}

stop_client_keep_config() {
  local mode
  mode="$(current_mode)"
  if [[ "$mode" =~ ^wg- ]]; then
    systemctl stop getout-wg.service 2>/dev/null || true
    # 服务可能处于 failed 状态，systemctl stop 不执行 ExecStopPost
    # 手动清理 WireGuard 接口作为兜底
    if ip link show getout-wg0 &>/dev/null; then
      wg-quick down "$WG_CONF" 2>/dev/null || ip link del getout-wg0 2>/dev/null || true
    fi
    cleanup_rules
    systemctl disable getout-wg.service 2>/dev/null || true
  else
    systemctl stop getout-tun.service 2>/dev/null || true
    cleanup_rules
    systemctl disable getout-tun.service 2>/dev/null || true
  fi
}

stop_wg_server_keep_config() {
  systemctl stop getout-wg.service 2>/dev/null || true
  # 服务可能处于 failed 状态，手动清理接口兜底
  if ip link show getout-wg0 &>/dev/null; then
    wg-quick down "$WG_CONF" 2>/dev/null || ip link del getout-wg0 2>/dev/null || true
  fi
  systemctl disable getout-wg.service 2>/dev/null || true
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
  [[ "$yn" =~ ^[Yy]$ ]] || fatal "入口必须设置用户名密码，避免暴露为开放代理。"
  user=""; pass=""
  read -rp "用户名: " user
  [ -n "$user" ] || fatal "用户名不能为空。"
  read -rp "密码: " pass
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
  [ -n "${USERNAME:-}" ] && [ -n "${PASSWORD:-}" ] || fatal "入口必须配置用户名密码，请先修改入口信息。"
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
  success "入口已启动。"
  status
}

stop_server() {
  require_root
  stop_server_keep_config
  success "入口已关闭。"
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
    success "入口信息已保存，启动入口后生效。"
    if tun_active; then
      warn "当前出口正在运行，入口信息不会影响当前出口。"
    fi
  fi
}

install_server() {
  start_server
}

# --- WireGuard 模式 ---

prompt_wg_server_info() {
  require_root; require_debian; install_deps
  ensure_conf_dir
  local listen_addr listen_port private_key address

  read -rp "请输入 WireGuard 监听地址 [默认: :: (双栈)]: " listen_addr
  listen_addr="${listen_addr:-::}"
  [[ "$listen_addr" =~ ^[0-9a-fA-F.:]+$ ]] || [[ "$listen_addr" == "::" ]] || fatal "地址无效：$listen_addr"

  read -rp "请输入 WireGuard 监听端口 [默认: ${DEFAULT_WG_PORT}]: " listen_port
  listen_port="${listen_port:-$DEFAULT_WG_PORT}"
  [[ "$listen_port" =~ ^[0-9]+$ ]] && [ "$listen_port" -ge 1 ] && [ "$listen_port" -le 65535 ] || fatal "端口无效：$listen_port"

  # 自动生成服务端密钥对
  private_key="$(wg genkey)" || fatal "生成私钥失败，请确认 wireguard-tools 已安装。"
  local server_pub
  server_pub="$(printf '%s' "$private_key" | wg pubkey)" || fatal "派生公钥失败。"

  read -rp "请输入服务端隧道地址/掩码 [默认: ${DEFAULT_WG_ADDRESS}]: " address
  address="${address:-$DEFAULT_WG_ADDRESS}"

  # 服务端隧道地址：IPv4 + IPv6（用逗号分隔，WireGuard 原生支持）
  local full_address="${address}, ${DEFAULT_WG_V6_ADDRESS}"

  # 从隧道地址推导对端 IP：服务端 .1 → 对端 .2
  local peer4="${address%.*}.2/32"
  local peer6="${DEFAULT_WG_V6_ADDRESS%%::*}::2/128"
  local default_allowed="${peer4},${peer6}"

  read -rp "请输入对端允许的 IP (AllowedIPs) [默认: ${default_allowed}]: " allowed_ips
  allowed_ips="${allowed_ips:-$default_allowed}"

  # 询问客户端公钥（留空自动生成客户端密钥对）
  local peer_private="" peer_public_key
  read -rp "请输入出口客户端公钥 [留空自动生成]: " peer_public_key
  if [ -z "$peer_public_key" ]; then
    peer_private="$(wg genkey)" || fatal "生成客户端私钥失败。"
    peer_public_key="$(printf '%s' "$peer_private" | wg pubkey)" || fatal "派生客户端公钥失败。"
  fi

  # 写入配置
  {
    printf 'SERVER_MODE=wireguard\n'
    printf 'LISTEN_ADDRESS=%s\n' "$(shell_quote "$listen_addr")"
    printf 'LISTEN_PORT=%s\n' "$(shell_quote "$listen_port")"
    printf 'PRIVATE_KEY=%s\n' "$(shell_quote "$private_key")"
    printf 'ADDRESS=%s\n' "$(shell_quote "$full_address")"
    printf 'PEER_PUBLIC_KEY=%s\n' "$(shell_quote "$peer_public_key")"
    printf 'ALLOWED_IPS=%s\n' "$(shell_quote "$allowed_ips")"
  } > "$SERVER_CONF"
  chmod_private_file "$SERVER_CONF"

  # 显示入口信息（所有字段）
  echo ""
  echo -e "${GREEN}========================================${NC}"
  echo -e "${GREEN} 入口信息（请复制到出口机器使用）:${NC}"
  echo -e "${GREEN}========================================${NC}"
  local ipv4 ipv6
  ipv4="$(main_ipv4 || true)"
  ipv6="$(main_ipv6 || true)"
  if [ -n "$ipv4" ] && [ -n "$ipv6" ]; then
    echo -e "  地址:"
    echo -e "    IPv4: ${BLUE}${ipv4}${NC}"
    echo -e "    IPv6: ${BLUE}${ipv6}${NC}"
  elif [ -n "$ipv4" ]; then
    echo -e "  地址: ${BLUE}${ipv4}${NC}"
  elif [ -n "$ipv6" ]; then
    echo -e "  地址: ${BLUE}${ipv6}${NC}"
  else
    echo -e "  地址: ${YELLOW}<无法检测本机IP>${NC}"
  fi
  echo -e "  端口: ${BLUE}${listen_port}${NC}"
  echo -e "  公钥: ${BLUE}${server_pub}${NC}"
  if [ -n "$peer_private" ]; then
    echo -e "  客户端私钥: ${BLUE}${peer_private}${NC}"
  fi
  echo -e "${GREEN}========================================${NC}"
}

write_wg_server_service() {
  [ -f "$SERVER_CONF" ] || fatal "未找到入口配置，请先修改入口信息。"
  assert_private_config "$SERVER_CONF"
  # shellcheck disable=SC1090
  . "$SERVER_CONF"
  [ -n "${LISTEN_PORT:-}" ] || fatal "入口配置缺少 LISTEN_PORT。"
  [ -n "${ADDRESS:-}" ] || fatal "入口配置缺少 ADDRESS。"
  [ -n "${PRIVATE_KEY:-}" ] || fatal "入口配置缺少 PRIVATE_KEY。"
  [ -n "${PEER_PUBLIC_KEY:-}" ] || fatal "入口配置缺少 PEER_PUBLIC_KEY。"

  local listen_addr="${LISTEN_ADDRESS:-::}"
  local peer_allowed
  if [ -n "${ALLOWED_IPS:-}" ]; then
    peer_allowed="$ALLOWED_IPS"
  else
    # 兼容旧配置：从 ADDRESS 提取 IPv4 部分推导 AllowedIPs
    local addr_v4="${ADDRESS%%,*}"
    addr_v4="${addr_v4// /}"
    peer_allowed="${addr_v4%.*}.2/32,${DEFAULT_WG_V6_ADDRESS%%::*}::2/128"
  fi

  # 从 ADDRESS 提取子网并生成 NAT 规则
  local nat_up="" nat_down=""
  local v4_net="" v6_net=""
  local addr_part
  for addr_part in ${ADDRESS//,/ }; do
    addr_part="${addr_part// /}"
    [ -n "$addr_part" ] || continue
    if is_ipv6 "${addr_part%%/*}"; then
      v6_net="$(get_v6_network "$addr_part")"
    else
      v4_net="$(get_v4_network "$addr_part")"
    fi
  done
  [ -n "$v4_net" ] && {
    nat_up+="PostUp = iptables -t nat -A POSTROUTING -s $v4_net ! -o %i -j MASQUERADE\n"
    nat_up+="PostUp = iptables -A FORWARD -i %i -j ACCEPT\n"
    nat_up+="PostUp = iptables -A FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT\n"
    nat_down+="PostDown = iptables -t nat -D POSTROUTING -s $v4_net ! -o %i -j MASQUERADE\n"
    nat_down+="PostDown = iptables -D FORWARD -i %i -j ACCEPT\n"
    nat_down+="PostDown = iptables -D FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT\n"
  }
  [ -n "$v6_net" ] && command -v ip6tables >/dev/null 2>&1 && {
    nat_up+="PostUp = ip6tables -t nat -A POSTROUTING -s $v6_net ! -o %i -j MASQUERADE\n"
    nat_up+="PostUp = ip6tables -A FORWARD -i %i -j ACCEPT\n"
    nat_up+="PostUp = ip6tables -A FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT\n"
    nat_down+="PostDown = ip6tables -t nat -D POSTROUTING -s $v6_net ! -o %i -j MASQUERADE\n"
    nat_down+="PostDown = ip6tables -D FORWARD -i %i -j ACCEPT\n"
    nat_down+="PostDown = ip6tables -D FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT\n"
  }

  # 写入 WireGuard 配置文件
  cat > "$WG_CONF" <<EOF
[Interface]
Address = ${ADDRESS}
ListenPort = ${LISTEN_PORT}
PrivateKey = ${PRIVATE_KEY}
$(echo -e "$nat_up$nat_down")
[Peer]
PublicKey = ${PEER_PUBLIC_KEY}
AllowedIPs = ${peer_allowed}
EOF
  chmod_private_file "$WG_CONF"

  # 写入 systemd service
  cat > "$WG_SERVICE" <<EOF
[Unit]
Description=Getout WireGuard Server
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/sbin/sysctl -w net.ipv4.ip_forward=1
ExecStartPre=/sbin/sysctl -w net.ipv6.conf.all.forwarding=1
ExecStart=/usr/bin/wg-quick up $WG_CONF
ExecStop=/usr/bin/wg-quick down $WG_CONF
ExecStopPost=/usr/bin/wg-quick down $WG_CONF 2>/dev/null || true

[Install]
WantedBy=multi-user.target
EOF
  chmod_private_file "$WG_SERVICE"
  systemctl daemon-reload
}

start_wg_server() {
  local snapshot
  require_root; require_debian; install_deps
  ensure_conf_dir; ensure_wg
  snapshot="$(snapshot_server_files)"
  begin_server_rollback "$snapshot"
  stop_client_keep_config
  stop_server_keep_config
  stop_wg_server_keep_config
  if [ -f "$SERVER_CONF" ] && grep -q '^SERVER_MODE=wireguard' "$SERVER_CONF"; then
    assert_private_config "$SERVER_CONF"
    # shellcheck disable=SC1090
    . "$SERVER_CONF"
  else
    if [ ! -t 0 ]; then
      restore_server_or_warn "$snapshot"
      fatal "未找到 WireGuard 配置，请先交互运行 getout wg-server 或在菜单中选择 2 配置。"
    fi
    prompt_wg_server_info
  fi
  [ -f "$SERVER_CONF" ] && grep -q '^SERVER_MODE=wireguard' "$SERVER_CONF" || {
    restore_server_or_warn "$snapshot"
    fatal "WireGuard 配置无效。"
  }
  write_wg_server_service
  echo "wg-server" > "$MODE_FILE"
  chmod_private_file "$MODE_FILE"
  systemctl enable --now getout-wg.service
  sleep 2
  if ! systemctl is-active --quiet getout-wg.service; then
    restore_server_or_warn "$snapshot"
    systemctl restart getout-wg.service 2>/dev/null || true
    fatal "getout-wg.service 启动失败，请查看：journalctl -u getout-wg.service -e"
  fi
  clear_runtime_rollback "$snapshot"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    assert_private_config "$SERVER_CONF"
    # shellcheck disable=SC1090
    . "$SERVER_CONF"
    ufw allow "${LISTEN_PORT}/udp" >/dev/null || true
  fi
  success "入口 WireGuard 模式已启动。"
  status
}

stop_wg_server() {
  require_root
  stop_wg_server_keep_config
  success "入口 WireGuard 模式已关闭。"
}

configure_wg_server() {
  local snapshot was_active
  was_active=0; wg_server_active && was_active=1
  ensure_conf_dir
  snapshot="$(snapshot_server_files)"
  begin_server_rollback "$snapshot"
  prompt_wg_server_info
  write_wg_server_service
  if [ "$was_active" = "1" ]; then
    systemctl restart getout-wg.service
    sleep 2
    if ! systemctl is-active --quiet getout-wg.service; then
      restore_server_or_warn "$snapshot"
      systemctl restart getout-wg.service 2>/dev/null || true
      fatal "getout-wg.service 启动失败，请查看：journalctl -u getout-wg.service -e"
    fi
    clear_runtime_rollback "$snapshot"
    systemctl enable getout-wg.service >/dev/null 2>&1 || true
    success "入口 WireGuard 信息已更新并立即应用。"
    status
  else
    clear_runtime_rollback "$snapshot"
    success "入口 WireGuard 信息已保存，启动入口后生效。"
    if any_client_active; then
      warn "当前出口正在运行，入口信息不会影响当前出口。"
    fi
  fi
}

