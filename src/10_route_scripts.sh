# --- 10 route and DNS/gai runtime hooks --------------------------------------

write_routes_scripts() {
  ensure_conf_dir
  cat > "$ROUTES_UP" <<EOF
#!/usr/bin/env bash
exec "$INSTALL_PATH" route-up
EOF
  cat > "$ROUTES_DOWN" <<EOF
#!/usr/bin/env bash
exec "$INSTALL_PATH" route-down
EOF
  chmod 700 "$ROUTES_UP" "$ROUTES_DOWN"
}

route_run() { "$@" 2>/dev/null || true; }
route_run_all() { while "$@" 2>/dev/null; do :; done; }

route_defaults() {
  TABLE_ID="${TABLE_ID:-20}"
  MARK_ID="${MARK_ID:-438}"
  BYPASS_MARK_ID="${BYPASS_MARK_ID:-439}"
  NFT_TABLE="${NFT_TABLE:-getout_protect}"
  TUN_NAME="${TUN_NAME:-tun0}"
  MODE="${MODE:-v4}"
  PRIORITY_MODE="${PRIORITY_MODE:-v6}"
  RUNTIME_DNS_SERVERS="${RUNTIME_DNS_SERVERS:-2001:4860:4860::8888 2606:4700:4700::1111}"
  RUNTIME_DNS_ENABLE="${RUNTIME_DNS_ENABLE:-1}"
}

valid_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
valid_name() { [[ "${1:-}" =~ ^[A-Za-z0-9_.:-]+$ ]]; }
valid_mode() { [[ "${1:-}" =~ ^(v4|dual|wg-v4|wg-dual)$ ]]; }
valid_priority() { [[ "${1:-}" =~ ^(v4|v6)$ ]]; }

validate_route_config() {
  valid_uint "$TABLE_ID" || { err "TABLE_ID 无效：$TABLE_ID"; return 1; }
  valid_uint "$MARK_ID" || { err "MARK_ID 无效：$MARK_ID"; return 1; }
  valid_uint "$BYPASS_MARK_ID" || { err "BYPASS_MARK_ID 无效：$BYPASS_MARK_ID"; return 1; }
  valid_name "$NFT_TABLE" || { err "NFT_TABLE 无效：$NFT_TABLE"; return 1; }
  valid_name "$TUN_NAME" || { err "TUN_NAME 无效：$TUN_NAME"; return 1; }
  valid_mode "$MODE" || { err "MODE 无效：$MODE"; return 1; }
  valid_priority "$PRIORITY_MODE" || { err "PRIORITY_MODE 无效：$PRIORITY_MODE"; return 1; }
}

load_route_client_conf_strict() {
  [ -f "$CLIENT_CONF" ] || fatal "未找到出口配置，无法应用路由。"
  load_client_conf
  route_defaults
  validate_route_config
}

load_route_client_conf_best_effort() {
  if [ -f "$CLIENT_CONF" ]; then
    if find "$CLIENT_CONF" -maxdepth 0 -type f -user root ! -perm /022 | grep -q .; then
      # shellcheck disable=SC1090
      . "$CLIENT_CONF"
    else
      warn "client.conf 权限不安全，route-down 将使用默认值尽量兜底清理。"
    fi
  fi
  route_defaults
  validate_route_config || {
    warn "路由配置含无效值，route-down 将使用默认值尽量兜底清理。"
    TABLE_ID=20; MARK_ID=438; BYPASS_MARK_ID=439; NFT_TABLE=getout_protect; TUN_NAME=tun0; MODE=v4; PRIORITY_MODE=v6
  }
}

write_meta() { write_file_meta "$@"; }

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
  if [ ! -e "$backup" ]; then
    [ -f "$marker" ] && warn "$label 原始备份缺失，已保留当前内容，避免误恢复到未知状态。"
    return 0
  fi
  current_checksum="$(file_checksum "$path")"; marker_checksum="$(cat "$marker" 2>/dev/null || true)"
  if [ -n "$marker_checksum" ] && [ "$marker_checksum" != "$current_checksum" ]; then
    warn "$label 在 getout 运行期间被外部修改，已保留当前内容；旧备份已归档，后续启动会重新备份当前状态。"
    mv -f "$backup" "$backup.conflict.$(date +%s)" 2>/dev/null || true
    [ -n "$target_backup" ] && mv -f "$target_backup" "$target_backup.conflict.$(date +%s)" 2>/dev/null || true
    rm -f "$meta" "$marker" 2>/dev/null || true
    return 0
  fi
  if [ "$exists" = "0" ]; then
    rm -f "$path" 2>/dev/null || true
  elif [ -n "$symlink_target" ]; then
    rm -f "$path" 2>/dev/null || true
    ln -s "$symlink_target" "$path" 2>/dev/null || cp -a "$backup" "$path" 2>/dev/null || true
    [ -n "$target_backup" ] && [ -e "$target_backup" ] && cp -a "$target_backup" "$(readlink -f "$path" 2>/dev/null || echo "$path")" 2>/dev/null || true
  else
    cp -a "$backup" "$path" 2>/dev/null || true
  fi
  rm -f "$backup" "$meta" "$marker" "$target_backup" 2>/dev/null || true
}

add4_to_main() { [ -n "${1:-}" ] && route_run_all ip rule del to "$1" lookup main pref "$2" && route_run ip rule add to "$1" lookup main pref "$2"; }
add6_to_main() { [ -n "${1:-}" ] && route_run_all ip -6 rule del to "$1" lookup main pref "$2" && route_run ip -6 rule add to "$1" lookup main pref "$2"; }
del4_to_main() { [ -n "${1:-}" ] && route_run_all ip rule del to "$1" lookup main pref "$2"; }
del6_to_main() { [ -n "${1:-}" ] && route_run_all ip -6 rule del to "$1" lookup main pref "$2"; }

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
    route_run_all ip rule del ipproto tcp sport "$port" lookup main pref 6
    route_run_all ip -6 rule del ipproto tcp sport "$port" lookup main pref 6
    route_run ip rule add ipproto tcp sport "$port" lookup main pref 6
    route_run ip -6 rule add ipproto tcp sport "$port" lookup main pref 6
  done
}

del_ssh_port_rules() {
  local port
  for port in $(ssh_ports_text) 22; do
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    route_run_all ip rule del ipproto tcp sport "$port" lookup main pref 6
    route_run_all ip -6 rule del ipproto tcp sport "$port" lookup main pref 6
    route_run_all ip rule del sport "$port" lookup main pref 6
    route_run_all ip -6 rule del sport "$port" lookup main pref 6
  done
}

add_inbound_protect() {
  command -v nft >/dev/null 2>&1 || { warn "未找到 nft，跳过入站回包保护；请先安装 nftables 后重启 getout。"; return 0; }
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
    if [ -f "$RESOLV_MARKER" ]; then
      warn "检测到 /etc/resolv.conf 可能已由 getout 管理，但原始备份缺失；为避免错误覆盖原始 DNS，本次不重建备份。"
    else
      backup_path /etc/resolv.conf "$RESOLV_ORIG" "$RESOLV_META" "$RESOLV_TARGET_ORIG"
    fi
  fi
  {
    printf '# getout managed resolv begin\n'
    for dns in $RUNTIME_DNS_SERVERS; do printf 'nameserver %s\n' "$dns"; done
    printf 'options timeout:2 attempts:1\n'
    printf '# getout managed resolv end\n'
  } > /etc/resolv.conf || { err "写入 /etc/resolv.conf 失败。"; return 1; }
  file_checksum /etc/resolv.conf > "$RESOLV_MARKER" 2>/dev/null || true
}

strip_gai_priority_block() {
  awk '
    $0 == "# getout managed priority begin" {skip=1; next}
    $0 == "# getout managed priority end" {skip=0; next}
    !skip {print}
  ' /etc/gai.conf 2>/dev/null
}

backup_gai_for_priority() {
  [ ! -f "$GAI_ORIG" ] || return 0
  if [ -f "$GAI_MARKER" ]; then
    warn "检测到 /etc/gai.conf 可能已由 getout 管理，但原始备份缺失；本次只更新 getout 管理块。"
  else
    backup_path /etc/gai.conf "$GAI_ORIG" "$GAI_META"
  fi
}

print_gai_priority_block() {
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
}

apply_gai_priority() {
  local tmp
  tmp="$(mktemp)" || return 0
  backup_gai_for_priority
  strip_gai_priority_block > "$tmp" || true
  { cat "$tmp" 2>/dev/null || true; print_gai_priority_block; } > /etc/gai.conf 2>/dev/null || true
  file_checksum /etc/gai.conf > "$GAI_MARKER" 2>/dev/null || true
  rm -f "$tmp" 2>/dev/null || true
}

remove_gai_priority_block() {
  local tmp
  tmp="$(mktemp)" || return 0
  strip_gai_priority_block > "$tmp" || true
  cat "$tmp" > /etc/gai.conf 2>/dev/null || true
  rm -f "$tmp" 2>/dev/null || true
  rm -f "$GAI_MARKER" 2>/dev/null || true
}

restore_dns() {
  [ "$RUNTIME_DNS_ENABLE" = "1" ] || return 0
  restore_path /etc/resolv.conf "$RESOLV_ORIG" "$RESOLV_META" "$RESOLV_MARKER" /etc/resolv.conf "$RESOLV_TARGET_ORIG"
}

restore_gai() {
  if [ -f "$GAI_ORIG" ]; then
    restore_path /etc/gai.conf "$GAI_ORIG" "$GAI_META" "$GAI_MARKER" /etc/gai.conf
  elif [ -f "$GAI_MARKER" ]; then
    remove_gai_priority_block
  fi
}

route_up() {
  require_root
  load_route_client_conf_strict
  route_down >/dev/null 2>&1 || true
  apply_runtime_dns
  apply_gai_priority
  add_inbound_protect
  route_run ip rule add fwmark "$BYPASS_MARK_ID" lookup main pref 9
  route_run ip -6 rule add fwmark "$BYPASS_MARK_ID" lookup main pref 9
  route_run ip rule add fwmark "$MARK_ID" lookup main pref 10
  route_run ip -6 rule add fwmark "$MARK_ID" lookup main pref 10
  if is_ipv6 "${SSH_REMOTE_IP:-}"; then add6_to_main "${SSH_REMOTE_IP}/128" 5; elif is_ipv4 "${SSH_REMOTE_IP:-}"; then add4_to_main "${SSH_REMOTE_IP}/32" 5; fi
  if is_ipv6 "${SOCKS_ADDRESS:-}"; then add6_to_main "${SOCKS_ADDRESS}/128" 6; elif is_ipv4 "${SOCKS_ADDRESS:-}"; then add4_to_main "${SOCKS_ADDRESS}/32" 6; fi
  add_ssh_port_rules
  local dns cidr
  for dns in $RUNTIME_DNS_SERVERS; do if is_ipv6 "$dns"; then add6_to_main "$dns/128" 7; elif is_ipv4 "$dns"; then add4_to_main "$dns/32" 7; fi; done
  for cidr in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/4; do add4_to_main "$cidr" 16; done
  for cidr in ::1/128 fe80::/10 fc00::/7 ff00::/8; do add6_to_main "$cidr" 16; done
  route_run ip route add default dev "$TUN_NAME" table "$TABLE_ID"
  route_run ip rule add lookup "$TABLE_ID" pref 20
  if [ "$MODE" = "dual" ] || [ "$MODE" = "wg-dual" ]; then
    route_run ip -6 route add default dev "$TUN_NAME" table "$TABLE_ID"
    route_run ip -6 rule add lookup "$TABLE_ID" pref 20
  fi
}

route_down() {
  require_root
  load_route_client_conf_best_effort
  route_run_all ip rule del lookup "$TABLE_ID" pref 20
  route_run_all ip -6 rule del lookup "$TABLE_ID" pref 20
  route_run_all ip route del default dev "$TUN_NAME" table "$TABLE_ID"
  route_run_all ip -6 route del default dev "$TUN_NAME" table "$TABLE_ID"
  route_run nft delete table inet "$NFT_TABLE"
  route_run_all ip rule del fwmark "$BYPASS_MARK_ID" lookup main pref 9
  route_run_all ip -6 rule del fwmark "$BYPASS_MARK_ID" lookup main pref 9
  route_run_all ip rule del fwmark "$MARK_ID" lookup main pref 10
  route_run_all ip -6 rule del fwmark "$MARK_ID" lookup main pref 10
  del_ssh_port_rules
  local dns cidr
  for dns in $RUNTIME_DNS_SERVERS; do if is_ipv6 "$dns"; then del6_to_main "$dns/128" 7; elif is_ipv4 "$dns"; then del4_to_main "$dns/32" 7; fi; done
  for cidr in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/4; do del4_to_main "$cidr" 16; done
  for cidr in ::1/128 fe80::/10 fc00::/7 ff00::/8; do del6_to_main "$cidr" 16; done
  if is_ipv6 "${SSH_REMOTE_IP:-}"; then del6_to_main "${SSH_REMOTE_IP}/128" 5; elif is_ipv4 "${SSH_REMOTE_IP:-}"; then del4_to_main "${SSH_REMOTE_IP}/32" 5; fi
  if is_ipv6 "${SOCKS_ADDRESS:-}"; then del6_to_main "${SOCKS_ADDRESS}/128" 6; elif is_ipv4 "${SOCKS_ADDRESS:-}"; then del4_to_main "${SOCKS_ADDRESS}/32" 6; fi
  restore_dns
  restore_gai
}
