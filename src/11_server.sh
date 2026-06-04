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

