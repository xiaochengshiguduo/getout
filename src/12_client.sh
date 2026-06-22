# --- 12 outlet/client mode ----------------------------------------------------

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

write_runtime_detection_conf() {
  local ssh_ip ssh_ports v4 v6
  ssh_ip="$(ssh_remote_ip || true)"
  ssh_ports="$(ssh_listen_ports 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
  v4="$(main_ipv4 || true)"
  v6="$(main_ipv6 || true)"
  printf 'SSH_REMOTE_IP=%s\n' "$(shell_quote "$ssh_ip")"
  printf 'SSH_PORTS=%s\n' "$(shell_quote "$ssh_ports")"
  printf 'MAIN_IPV4=%s\n' "$(shell_quote "$v4")"
  printf 'MAIN_IPV6=%s\n' "$(shell_quote "$v6")"
}

write_runtime_policy_conf() {
  local priority_mode="$1" tun_name="$2" iface="$3" runtime_dns
  runtime_dns="$(runtime_dns_servers_text "$priority_mode")"
  printf 'TABLE_ID=%s\n' "$(shell_quote "$TABLE_ID")"
  printf 'MARK_ID=%s\n' "$(shell_quote "$MARK_ID")"
  printf 'BYPASS_MARK_ID=%s\n' "$(shell_quote "$BYPASS_MARK_ID")"
  printf 'NFT_TABLE=%s\n' "$(shell_quote "$NFT_TABLE")"
  [ -n "$iface" ] && printf 'IFACE=%s\n' "$(shell_quote "$iface")"
  printf 'TUN_NAME=%s\n' "$(shell_quote "$tun_name")"
  printf 'PRIORITY_MODE=%s\n' "$(shell_quote "$priority_mode")"
  printf 'RUNTIME_DNS_SERVERS=%s\n' "$(shell_quote "$runtime_dns")"
  printf 'RUNTIME_DNS_ENABLE=1\n'
}

write_runtime_common_conf() {
  local priority_mode="${1:-}" tun_name="${2:-$TUN_NAME}" iface="${3:-}"
  case "$priority_mode" in v4|v6) ;; *) priority_mode="$(current_priority_mode)" ;; esac
  write_runtime_detection_conf
  write_runtime_policy_conf "$priority_mode" "$tun_name" "$iface"
}

write_client_conf() {
  local mode="$1" address="$2" port="$3" username="$4" password="$5" priority_mode="${6:-}"
  ensure_conf_dir
  {
    printf 'MODE=%s\n' "$(shell_quote "$mode")"
    printf 'SOCKS_ADDRESS=%s\n' "$(shell_quote "$address")"
    printf 'SOCKS_PORT=%s\n' "$(shell_quote "$port")"
    printf 'SOCKS_USERNAME=%s\n' "$(shell_quote "$username")"
    printf 'SOCKS_PASSWORD=%s\n' "$(shell_quote "$password")"
    write_runtime_common_conf "$priority_mode"
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
  require_valid_port "端口" "$port"
  read -rp "上游 SOCKS5 用户名 [无认证可留空]: " username
  password=""
  if [ -n "$username" ]; then
    read -rp "上游 SOCKS5 密码 [无认证可留空]: " password
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

default_wg_client_v4_addr() { echo "${DEFAULT_WG_ADDRESS%.*}.2/32"; }
default_wg_client_v6_addr() { echo "${DEFAULT_WG_V6_ADDRESS%%::*}::2/128"; }

# 根据 WG 模式返回客户端隧道地址
default_wg_addr() {
  local mode="${1:-wg-v4}"
  case "$mode" in
    wg-dual) printf '%s, %s
' "$(default_wg_client_v4_addr)" "$(default_wg_client_v6_addr)" ;;
    *)       default_wg_client_v4_addr ;;
  esac
}

ask_wg_config() {
  local mode="$1" server_addr server_port server_public_key client_private_key

  read -rp "地址: " server_addr
  server_addr="$(strip_brackets "$server_addr")"
  [ -n "$server_addr" ] || fatal "服务器地址不能为空。"

  read -rp "端口 [默认: ${DEFAULT_WG_PORT}]: " server_port
  server_port="${server_port:-$DEFAULT_WG_PORT}"
  require_valid_port "端口" "$server_port"

  read -rp "私钥: " client_private_key
  [ -n "$client_private_key" ] || fatal "客户端私钥不能为空。"

  read -rp "公钥: " server_public_key
  [ -n "$server_public_key" ] || fatal "服务端公钥不能为空。"

  write_wg_client_conf "$mode" "$server_addr" "$server_port" "$client_private_key" "$(default_wg_addr "$mode")" "$server_public_key" "" ""
}

write_wg_client_conf() {
  local mode="$1" server_addr="$2" server_port="$3" client_private_key="$4" client_address="$5" server_public_key="$6" psk="$7" dns="$8"
  local priority_mode="${9:-}" iface="getout-${WG_IFACE}"
  ensure_conf_dir
  {
    printf 'MODE=%s\n' "$(shell_quote "$mode")"
    printf 'TRANSPORT=wireguard\n'
    printf 'WG_SERVER_ADDRESS=%s\n' "$(shell_quote "$server_addr")"
    printf 'WG_SERVER_PORT=%s\n' "$(shell_quote "$server_port")"
    printf 'WG_CLIENT_PRIVATE_KEY=%s\n' "$(shell_quote "$client_private_key")"
    printf 'WG_CLIENT_ADDRESS=%s\n' "$(shell_quote "$client_address")"
    printf 'WG_SERVER_PUBLIC_KEY=%s\n' "$(shell_quote "$server_public_key")"
    printf 'WG_PRESHARED_KEY=%s\n' "$(shell_quote "$psk")"
    printf 'WG_DNS=%s\n' "$(shell_quote "$dns")"
    printf 'SOCKS_ADDRESS=%s\n' "$(shell_quote "$server_addr")"
    write_runtime_common_conf "$priority_mode" "$iface" "$iface"
  } > "$CLIENT_CONF"
  chmod_private_file "$CLIENT_CONF"
}

reuse_wg_client_config() {
  local mode="$1"
  [ -f "$CLIENT_CONF" ] || return 1
  assert_private_config "$CLIENT_CONF"
  # shellcheck disable=SC1090
  . "$CLIENT_CONF"
  [ "${TRANSPORT:-}" = "wireguard" ] || return 1
  [ -n "${WG_SERVER_ADDRESS:-}" ] && [ -n "${WG_SERVER_PORT:-}" ] || return 1
  [ -n "${WG_CLIENT_PRIVATE_KEY:-}" ] && [ -n "${WG_SERVER_PUBLIC_KEY:-}" ] || return 1
  # Rewrite with the new mode to update MODE field; use mode-appropriate default address
  local addr="${WG_CLIENT_ADDRESS:-$(default_wg_addr "$mode")}"
  # If switching modes, update address to match new mode
  case "$mode" in
    wg-dual)
      # Ensure IPv6 address is present
      [[ "$addr" == *"fd86:ea04:1115"* ]] || addr="$(default_wg_addr "$mode")"
      ;;
    wg-v4)
      # For v4-only, strip any IPv6 part
      addr="$(default_wg_client_v4_addr)"
      ;;
  esac
  write_wg_client_conf "$mode" "$WG_SERVER_ADDRESS" "$WG_SERVER_PORT" "$WG_CLIENT_PRIVATE_KEY" "$addr" "$WG_SERVER_PUBLIC_KEY" "${WG_PRESHARED_KEY:-}" "${WG_DNS:-$DEFAULT_WG_DNS}"
  return 0
}

write_wg_config() {
  assert_private_config "$CLIENT_CONF"
  # shellcheck disable=SC1090
  . "$CLIENT_CONF"
  [ "${TRANSPORT:-}" = "wireguard" ] || return 1
  require_valid_wg_key "WG_CLIENT_PRIVATE_KEY" "${WG_CLIENT_PRIVATE_KEY:-}"
  require_valid_wg_key "WG_SERVER_PUBLIC_KEY" "${WG_SERVER_PUBLIC_KEY:-}"
  [ -z "${WG_PRESHARED_KEY:-}" ] || require_valid_wg_key "WG_PRESHARED_KEY" "$WG_PRESHARED_KEY"
  require_valid_cidr_list "WG_CLIENT_ADDRESS" "${WG_CLIENT_ADDRESS:-$(default_wg_addr "${MODE:-wg-v4}")}"
  require_valid_dns_list "WG_DNS" "${WG_DNS:-$DEFAULT_WG_DNS}"
  require_valid_port "WG_SERVER_PORT" "${WG_SERVER_PORT:-}"
  local endpoint_host
  endpoint_host="$(format_endpoint_host "${WG_SERVER_ADDRESS:-}")"

  local iface="${TUN_NAME:-getout-${WG_IFACE}}"
  cat > "$WG_CONF" <<EOF
[Interface]
PrivateKey = ${WG_CLIENT_PRIVATE_KEY}
Address = ${WG_CLIENT_ADDRESS:-$(default_wg_addr "${MODE:-wg-v4}")}
$(if [ -n "${WG_DNS:-$DEFAULT_WG_DNS}" ]; then echo "DNS = ${WG_DNS:-$DEFAULT_WG_DNS}"; fi)
Table = off

[Peer]
PublicKey = ${WG_SERVER_PUBLIC_KEY}
$(if [ -n "${WG_PRESHARED_KEY:-}" ]; then echo "PresharedKey = ${WG_PRESHARED_KEY}"; fi)
Endpoint = ${endpoint_host}:${WG_SERVER_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
  chmod_private_file "$WG_CONF"
}

write_wg_service() {
  local mode="$1"
  local iface="${TUN_NAME:-getout-${WG_IFACE}}"
  cat > "$WG_SERVICE" <<EOF
[Unit]
Description=Getout WireGuard Client ($mode)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/sbin/sysctl -w net.ipv4.conf.all.rp_filter=0
ExecStart=/usr/bin/wg-quick up $WG_CONF
ExecStartPost=/bin/sleep 1
ExecStartPost=$ROUTES_UP
ExecStop=$ROUTES_DOWN
ExecStopPost=/usr/bin/wg-quick down $WG_CONF 2>/dev/null || true
ExecStopPost=$ROUTES_DOWN

[Install]
WantedBy=multi-user.target
EOF
  chmod_private_file "$WG_SERVICE"
  systemctl daemon-reload
}

validate_socks_config() {
  [ -n "${SOCKS_ADDRESS:-}" ] || fatal "出口配置缺少 SOCKS_ADDRESS。"
  [ -n "${SOCKS_PORT:-}" ] || fatal "出口配置缺少 SOCKS_PORT。"
  require_valid_port "SOCKS_PORT" "$SOCKS_PORT"
  format_endpoint_host "$SOCKS_ADDRESS" >/dev/null
  [ -z "${SOCKS_USERNAME:-}" ] || reject_url_unsafe "SOCKS_USERNAME" "$SOCKS_USERNAME"
  [ -z "${SOCKS_PASSWORD:-}" ] || reject_url_unsafe "SOCKS_PASSWORD" "$SOCKS_PASSWORD"
}

write_tun_config() {
  assert_private_config "$CLIENT_CONF"
  # shellcheck disable=SC1090
  . "$CLIENT_CONF"
  validate_socks_config
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
ExecStop=$ROUTES_DOWN
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

write_client_runtime_files() {
  local transport="$1" mode="$2" snapshot="$3"
  if [ "$transport" = "wireguard" ]; then
    write_wg_config
    write_routes_scripts
    preflight_wg_runtime_with_rollback "$snapshot"
    echo "$mode" > "$MODE_FILE"
    chmod_private_file "$MODE_FILE"
    write_wg_service "$mode"
  else
    write_tun_config
    write_routes_scripts
    preflight_tun_runtime_with_rollback "$snapshot"
    echo "$mode" > "$MODE_FILE"
    chmod_private_file "$MODE_FILE"
    write_tun_service "$mode"
  fi
}

restart_client_runtime() {
  local transport="$1" snapshot="$2" action="${3:-enable}"
  warn_ssh_protection_status
  if [ "$transport" = "wireguard" ]; then
    restart_wg_with_rollback "$snapshot" "$action"
  else
    restart_tun_with_rollback "$snapshot" "$action"
  fi
}

prepare_socks_client_start() {
  local mode="$1"
  ensure_tun
  stop_server_keep_config
  if any_client_active; then
    stop_client_keep_config
  fi
  [ -x "$TUN_BIN" ] || download_hev
  reuse_client_config_for_mode "$mode" || ask_socks_config "$mode"
}

prepare_wg_client_start() {
  local mode="$1" snapshot="$2"
  ensure_wg
  stop_server_keep_config
  if any_client_active; then
    stop_client_keep_config
  fi
  if ! reuse_wg_client_config "$mode"; then
    if [ ! -t 0 ]; then
      restore_runtime_or_warn "$snapshot"
      fatal "未找到 WireGuard 出口配置，请先交互运行 getout $mode 或在菜单中选择 6/7 配置。"
    fi
    ask_wg_config "$mode"
  fi
}

start_client_transport() {
  local transport="$1" mode="$2" snapshot
  require_root; require_debian; install_deps
  ensure_conf_dir
  snapshot="$(snapshot_runtime_files)"
  begin_runtime_rollback "$snapshot"
  if [ "$transport" = "wireguard" ]; then
    prepare_wg_client_start "$mode" "$snapshot"
  else
    prepare_socks_client_start "$mode"
  fi
  write_client_runtime_files "$transport" "$mode" "$snapshot"
  restart_client_runtime "$transport" "$snapshot" enable
}

start_client() {
  local mode="$1"
  start_client_transport socks5 "$mode"
  success "${mode} 模式已启动。"
  status
}

start_wg_client() {
  local mode="$1"
  start_client_transport wireguard "$mode"
  success "${mode} WireGuard 模式已启动。"
  status
}

configured_client_transport() {
  if [ -f "$CLIENT_CONF" ]; then
    assert_private_config "$CLIENT_CONF"
    # shellcheck disable=SC1090
    . "$CLIENT_CONF"
    printf '%s\n' "${TRANSPORT:-socks5}"
  else
    printf 'socks5\n'
  fi
}

configure_client_mode() {
  local transport="$1" default_mode="$2" active_fn="$3" mode
  if "$active_fn"; then
    mode="$(current_mode)"
    case "$transport:$mode" in
      socks5:v4|socks5:dual|wireguard:wg-v4|wireguard:wg-dual) ;;
      socks5:*) mode="v4" ;;
      wireguard:*) mode="wg-v4" ;;
    esac
  elif [ -f "$CLIENT_CONF" ]; then
    assert_private_config "$CLIENT_CONF"
    # shellcheck disable=SC1090
    . "$CLIENT_CONF"
    mode="${MODE:-$default_mode}"
  else
    mode="$default_mode"
  fi
  printf '%s\n' "$mode"
}

apply_configured_client_runtime() {
  local transport="$1" mode="$2" snapshot="$3" was_active="$4" active_success="$5" saved_success="$6"
  write_client_runtime_files "$transport" "$mode" "$snapshot"
  if [ "$was_active" = "1" ]; then
    if [ "$transport" = "wireguard" ]; then
      systemctl stop getout-wg.service 2>/dev/null || true
    else
      systemctl stop getout-tun.service 2>/dev/null || true
    fi
    cleanup_rules
    restart_client_runtime "$transport" "$snapshot" enable
    success "$active_success"
    status
  else
    clear_runtime_rollback "$snapshot"
    success "$saved_success"
    if server_active; then
      warn "当前入口正在运行，出口信息不会影响当前入口。"
    fi
  fi
}

configure_client_transport() {
  local transport="$1" mode snapshot was_active
  require_root; require_debian; install_deps
  ensure_conf_dir
  if [ "$transport" = "wireguard" ]; then
    ensure_wg
    was_active=0; any_client_active && was_active=1
    mode="$(configure_client_mode wireguard wg-v4 wg_client_active)"
  else
    ensure_tun
    was_active=0; tun_active && was_active=1
    mode="$(configure_client_mode socks5 v4 tun_active)"
  fi
  snapshot="$(snapshot_runtime_files)"
  begin_runtime_rollback "$snapshot"
  if [ "$transport" = "wireguard" ]; then
    ask_wg_config "$mode"
    apply_configured_client_runtime wireguard "$mode" "$snapshot" "$was_active" \
      "WireGuard 出口信息已更新并立即应用。" "WireGuard 出口信息已保存，启动 WireGuard 模式后生效。"
  else
    ask_socks_config "$mode"
    [ -x "$TUN_BIN" ] || download_hev
    apply_configured_client_runtime socks5 "$mode" "$snapshot" "$was_active" \
      "出口信息已更新并立即应用。" "出口信息已保存，启动 V4/双栈模式后生效。"
  fi
}

configure_client() {
  local transport
  transport="$(configured_client_transport)"
  if [ "$transport" = "wireguard" ]; then
    configure_wg_client "$@"
  else
    configure_client_transport socks5
  fi
}

configure_wg_client() {
  configure_client_transport wireguard
}

stop_client() {
  local mode="$(current_mode)"
  require_root
  stop_client_keep_config
  case "$mode" in
    v4) success "V4 单栈模式已关闭。" ;;
    dual) success "V4+V6 双栈模式已关闭。" ;;
    wg-v4) success "WG-V4 单栈模式已关闭。" ;;
    wg-dual) success "WireGuard V4+V6 双栈模式已关闭。" ;;
    *) success "出口已关闭。" ;;
  esac
}

priority_action_label() {
  case "$(current_priority_mode)" in
    v4) echo "切换至 V6 优先模式" ;;
    *) echo "切换至 V4 优先模式" ;;
  esac
}

next_priority_mode() {
  case "$(current_priority_mode)" in
    v4) echo v6 ;;
    *) echo v4 ;;
  esac
}

rewrite_wg_client_priority_conf() {
  local priority_mode="$1" mode="${MODE:-wg-v4}"
  write_wg_client_conf "$mode" "$WG_SERVER_ADDRESS" "$WG_SERVER_PORT" "$WG_CLIENT_PRIVATE_KEY" \
    "${WG_CLIENT_ADDRESS:-$(default_wg_addr "$mode")}" "$WG_SERVER_PUBLIC_KEY" \
    "${WG_PRESHARED_KEY:-}" "${WG_DNS:-$DEFAULT_WG_DNS}" "$priority_mode"
}

rewrite_socks_client_priority_conf() {
  local priority_mode="$1" mode="${MODE:-v4}"
  local address="${SOCKS_ADDRESS:-}" port="${SOCKS_PORT:-}" username="${SOCKS_USERNAME:-}" password="${SOCKS_PASSWORD:-}"
  [ -n "$address" ] && [ -n "$port" ] || fatal "出口配置不完整，请先修改出口信息。"
  write_client_conf "$mode" "$address" "$port" "$username" "$password" "$priority_mode"
}

apply_client_priority_runtime() {
  local transport="$1" snapshot="$2" was_active=0 mode
  if [ "$transport" = "wireguard" ]; then
    wg_client_active && was_active=1
    mode="${MODE:-wg-v4}"
    write_wg_config
    write_routes_scripts
    write_wg_service "$mode"
    preflight_wg_runtime_with_rollback "$snapshot"
    if [ "$was_active" = "1" ]; then
      systemctl stop getout-wg.service 2>/dev/null || true
      cleanup_rules
      warn_ssh_protection_status
      restart_wg_with_rollback "$snapshot" enable
    else
      clear_runtime_rollback "$snapshot"
    fi
  else
    tun_active && was_active=1
    mode="${MODE:-v4}"
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
  fi
}

switch_priority_mode() {
  require_root; require_debian; install_deps
  [ -f "$CLIENT_CONF" ] || fatal "未找到出口配置，请先修改出口信息。"
  local transport snapshot priority_mode
  assert_private_config "$CLIENT_CONF"
  # shellcheck disable=SC1090
  . "$CLIENT_CONF"
  transport="${TRANSPORT:-socks5}"
  priority_mode="$(next_priority_mode)"
  snapshot="$(snapshot_runtime_files)"
  begin_runtime_rollback "$snapshot"
  if [ "$transport" = "wireguard" ]; then
    rewrite_wg_client_priority_conf "$priority_mode"
  else
    rewrite_socks_client_priority_conf "$priority_mode"
  fi
  # shellcheck disable=SC1090
  . "$CLIENT_CONF"
  apply_client_priority_runtime "$transport" "$snapshot"
  case "$priority_mode" in
    v4) success "已切换至 V4 优先模式。" ;;
    v6) success "已切换至 V6 优先模式。" ;;
  esac
  status
}
