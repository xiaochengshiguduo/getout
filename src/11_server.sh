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
is_wg_client_mode() { [ "$1" = "wg-v4" ] || [ "$1" = "wg-dual" ]; }
wg_client_active() {
  local mode="$(current_mode)"
  service_active getout-wg.service && is_wg_client_mode "$mode"
}
any_client_active() { tun_active || wg_client_active; }
client_mode_active() {
  local mode="$(current_mode)"
  if is_wg_client_mode "$mode"; then
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
  if is_wg_client_mode "$mode"; then
    systemctl stop getout-wg.service 2>/dev/null || true
    # 服务可能处于 failed 状态，systemctl stop 不执行 ExecStopPost
    # 手动清理 WireGuard 接口作为兜底
    cleanup_wg_iface
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
  cleanup_wg_iface
  systemctl disable getout-wg.service 2>/dev/null || true
}

maybe_allow_ufw() {
  local port="$1" proto="$2"
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q "Status: active" || return 0
  ufw allow "${port}/${proto}" >/dev/null || warn "ufw 放行 ${port}/${proto} 失败，请手动检查防火墙。"
}

prompt_server_info() {
  require_root; require_debian; install_deps
  ensure_conf_dir
  local port user pass yn
  read -rp "请输入入口 SOCKS5 监听端口 [默认: 1080]: " port
  port="${port:-1080}"
  require_valid_port "端口" "$port"

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
  assert_private_config "$SERVER_CONF"
  # shellcheck disable=SC1090
  . "$SERVER_CONF"
  maybe_allow_ufw "$PORT" tcp
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

# --- WireGuard 模式 ---

prompt_wg_server_info() {
  require_root; require_debian; install_deps
  ensure_conf_dir
  local listen_port

  # 只询问端口
  read -rp "端口 [默认: ${DEFAULT_WG_PORT}]: " listen_port
  listen_port="${listen_port:-$DEFAULT_WG_PORT}"
  require_valid_port "端口" "$listen_port"

  # 固定参数（无需询问）
  local listen_addr="::"
  local address="$DEFAULT_WG_ADDRESS"
  local full_address="${address}, ${DEFAULT_WG_V6_ADDRESS}"

  # 自动生成服务端密钥对
  local private_key
  private_key="$(wg genkey)" || fatal "生成私钥失败，请确认 wireguard-tools 已安装。"
  local server_pub
  server_pub="$(printf '%s' "$private_key" | wg pubkey)" || fatal "派生公钥失败。"

  # 自动生成客户端密钥对
  local peer_private peer_public_key
  peer_private="$(wg genkey)" || fatal "生成客户端私钥失败。"
  peer_public_key="$(printf '%s' "$peer_private" | wg pubkey)" || fatal "派生客户端公钥失败。"

  # 从隧道地址推导对端 IP：服务端 .1 → 对端 .2
  local peer4="${address%.*}.2/32"
  local peer6="${DEFAULT_WG_V6_ADDRESS%%::*}::2/128"
  local allowed_ips="${peer4},${peer6}"

  # 写入配置
  {
    printf 'SERVER_MODE=wireguard\n'
    printf 'LISTEN_ADDRESS=%s\n' "$(shell_quote "$listen_addr")"
    printf 'LISTEN_PORT=%s\n' "$(shell_quote "$listen_port")"
    printf 'PRIVATE_KEY=%s\n' "$(shell_quote "$private_key")"
    printf 'ADDRESS=%s\n' "$(shell_quote "$full_address")"
    printf 'PEER_PRIVATE_KEY=%s\n' "$(shell_quote "$peer_private")"
    printf 'PEER_PUBLIC_KEY=%s\n' "$(shell_quote "$peer_public_key")"
    printf 'ALLOWED_IPS=%s\n' "$(shell_quote "$allowed_ips")"
  } > "$SERVER_CONF"
  chmod_private_file "$SERVER_CONF"
}

validate_wg_server_conf() {
  [ -n "${LISTEN_PORT:-}" ] || fatal "入口配置缺少 LISTEN_PORT。"
  [ -n "${ADDRESS:-}" ] || fatal "入口配置缺少 ADDRESS。"
  [ -n "${PRIVATE_KEY:-}" ] || fatal "入口配置缺少 PRIVATE_KEY。"
  [ -n "${PEER_PUBLIC_KEY:-}" ] || fatal "入口配置缺少 PEER_PUBLIC_KEY。"
  require_valid_port "LISTEN_PORT" "$LISTEN_PORT"
  require_valid_cidr_list "ADDRESS" "$ADDRESS"
  require_valid_wg_key "PRIVATE_KEY" "$PRIVATE_KEY"
  require_valid_wg_key "PEER_PUBLIC_KEY" "$PEER_PUBLIC_KEY"
  [ -z "${ALLOWED_IPS:-}" ] || require_valid_cidr_list "ALLOWED_IPS" "$ALLOWED_IPS"
}

wg_server_peer_allowed() {
  if [ -n "${ALLOWED_IPS:-}" ]; then
    printf '%s\n' "$ALLOWED_IPS"
    return 0
  fi
  local addr_v4="${ADDRESS%%,*}"
  addr_v4="${addr_v4// /}"
  printf '%s\n' "${addr_v4%.*}.2/32,${DEFAULT_WG_V6_ADDRESS%%::*}::2/128"
}

wg_server_nat_lines() {
  local v4_net="" v6_net="" addr_part
  IFS=',' read -r -a _wg_addr_parts <<< "$ADDRESS"
  for addr_part in "${_wg_addr_parts[@]}"; do
    addr_part="${addr_part//[[:space:]]/}"
    [ -n "$addr_part" ] || continue
    if is_ipv6 "${addr_part%%/*}"; then
      v6_net="$(get_v6_network "$addr_part")"
    else
      v4_net="$(get_v4_network "$addr_part")"
    fi
  done
  if [ -n "$v4_net" ]; then
    printf 'PostUp = iptables -t nat -A POSTROUTING -s %s ! -o %%i -j MASQUERADE\n' "$v4_net"
    printf 'PostUp = iptables -A FORWARD -i %%i -j ACCEPT\n'
    printf 'PostUp = iptables -A FORWARD -o %%i -m state --state RELATED,ESTABLISHED -j ACCEPT\n'
    printf 'PostDown = iptables -t nat -D POSTROUTING -s %s ! -o %%i -j MASQUERADE\n' "$v4_net"
    printf 'PostDown = iptables -D FORWARD -i %%i -j ACCEPT\n'
    printf 'PostDown = iptables -D FORWARD -o %%i -m state --state RELATED,ESTABLISHED -j ACCEPT\n'
  fi
  if [ -n "$v6_net" ] && command -v ip6tables >/dev/null 2>&1; then
    printf 'PostUp = ip6tables -t nat -A POSTROUTING -s %s ! -o %%i -j MASQUERADE\n' "$v6_net"
    printf 'PostUp = ip6tables -A FORWARD -i %%i -j ACCEPT\n'
    printf 'PostUp = ip6tables -A FORWARD -o %%i -m state --state RELATED,ESTABLISHED -j ACCEPT\n'
    printf 'PostDown = ip6tables -t nat -D POSTROUTING -s %s ! -o %%i -j MASQUERADE\n' "$v6_net"
    printf 'PostDown = ip6tables -D FORWARD -i %%i -j ACCEPT\n'
    printf 'PostDown = ip6tables -D FORWARD -o %%i -m state --state RELATED,ESTABLISHED -j ACCEPT\n'
  fi
}

write_wg_server_conf_file() {
  local peer_allowed
  peer_allowed="$(wg_server_peer_allowed)"
  cat > "$WG_CONF" <<EOF
[Interface]
Address = ${ADDRESS}
ListenPort = ${LISTEN_PORT}
PrivateKey = ${PRIVATE_KEY}
$(wg_server_nat_lines)
[Peer]
PublicKey = ${PEER_PUBLIC_KEY}
AllowedIPs = ${peer_allowed}
EOF
  chmod_private_file "$WG_CONF"
}

write_wg_systemd_service() {
  local description="$1"
  local pre_start="${2:-}"
  cat > "$WG_SERVICE" <<EOF
[Unit]
Description=$description
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
${pre_start}ExecStart=/usr/bin/wg-quick up $WG_CONF
ExecStop=/usr/bin/wg-quick down $WG_CONF
ExecStopPost=/usr/bin/wg-quick down $WG_CONF 2>/dev/null || true

[Install]
WantedBy=multi-user.target
EOF
  chmod_private_file "$WG_SERVICE"
  systemctl daemon-reload
}

write_wg_server_service() {
  [ -f "$SERVER_CONF" ] || fatal "未找到入口配置，请先修改入口信息。"
  assert_private_config "$SERVER_CONF"
  # shellcheck disable=SC1090
  . "$SERVER_CONF"
  validate_wg_server_conf
  write_wg_server_conf_file
  write_wg_systemd_service "Getout WireGuard Server" \
    $'ExecStartPre=/sbin/sysctl -w net.ipv4.ip_forward=1\nExecStartPre=/sbin/sysctl -w net.ipv6.conf.all.forwarding=1\n'
}

ensure_wg_server_config_or_prompt() {
  local snapshot="$1"
  if [ -f "$SERVER_CONF" ] && grep -q '^SERVER_MODE=wireguard' "$SERVER_CONF"; then
    assert_private_config "$SERVER_CONF"
    return 0
  fi
  if [ ! -t 0 ]; then
    restore_server_or_warn "$snapshot"
    fatal "未找到 WireGuard 配置，请先交互运行 getout wg-server 或在菜单中选择 2 配置。"
  fi
  prompt_wg_server_info
}

restart_wg_server_with_rollback() {
  local snapshot="$1" action="${2:-restart}" restore_old="${3:-0}"
  if [ "$action" = "enable" ]; then
    systemctl enable --now getout-wg.service
  else
    systemctl restart getout-wg.service
  fi
  sleep 2
  if ! systemctl is-active --quiet getout-wg.service; then
    restore_server_or_warn "$snapshot"
    [ "$restore_old" = "1" ] && systemctl restart getout-wg.service 2>/dev/null || true
    fatal "getout-wg.service 启动失败，请查看：journalctl -u getout-wg.service -e"
  fi
  clear_runtime_rollback "$snapshot"
}

maybe_allow_wg_ufw() {
  assert_private_config "$SERVER_CONF"
  # shellcheck disable=SC1090
  . "$SERVER_CONF"
  maybe_allow_ufw "$LISTEN_PORT" udp
}

apply_wg_server_config() {
  local snapshot="$1" action="$2" restore_old="${3:-0}"
  write_wg_server_service
  echo "wg-server" > "$MODE_FILE"
  chmod_private_file "$MODE_FILE"
  restart_wg_server_with_rollback "$snapshot" "$action" "$restore_old"
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
  ensure_wg_server_config_or_prompt "$snapshot"
  apply_wg_server_config "$snapshot" enable
  maybe_allow_wg_ufw
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
  if [ "$was_active" = "1" ]; then
    apply_wg_server_config "$snapshot" restart 1
    systemctl enable getout-wg.service >/dev/null 2>&1 || true
    success "入口 WireGuard 信息已更新并立即应用。"
    status
  else
    write_wg_server_service
    clear_runtime_rollback "$snapshot"
    success "入口 WireGuard 信息已保存，启动入口后生效。"
    if any_client_active; then
      warn "当前出口正在运行，入口信息不会影响当前出口。"
    fi
  fi
}

