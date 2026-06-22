# --- 14 CLI dispatch ---------------------------------------------------------

menu_action_label() {
  local type="$1" mode="$(current_mode)"
  case "$type" in
    server)
      if server_active; then echo "关闭 SOCKS5 模式"; else echo "启动 SOCKS5 模式"; fi ;;
    wg-server)
      if wg_server_active; then echo "关闭 WireGuard 模式"; else echo "启动 WireGuard 模式"; fi ;;
    v4)
      if tun_active && [ "$mode" = "v4" ]; then echo "关闭 s5-V4 单栈模式"; else echo "启动 s5-V4 单栈模式"; fi ;;
    dual)
      if tun_active && [ "$mode" = "dual" ]; then echo "关闭 s5-V4+V6 双栈模式"; else echo "启动 s5-V4+V6 双栈模式"; fi ;;
    wg-v4)
      if wg_client_active && [ "$mode" = "wg-v4" ]; then echo "关闭 WG-V4 单栈模式"; else echo "启动 WG-V4 单栈模式"; fi ;;
    wg-dual)
      if wg_client_active && [ "$mode" = "wg-dual" ]; then echo "关闭 WG-V4+V6 双栈模式"; else echo "启动 WG-V4+V6 双栈模式"; fi ;;
  esac
}

print_menu() {
  clear || true
  print_header "getout 管理面板" "$BLUE"
  echo "--- 入口 ---"
  echo "  1.$(menu_action_label server)"
  echo "  2.$(menu_action_label wg-server)"
  echo "  3.修改入口信息"
  echo "--- 出口 ---"
  echo "  4.$(menu_action_label v4)"
  echo "  5.$(menu_action_label dual)"
  echo "  6.$(menu_action_label wg-v4)"
  echo "  7.$(menu_action_label wg-dual)"
  echo "  8.修改出口信息"
  echo "  9.$(priority_action_label)"
  echo "--- 管理 ---"
  echo "  10.查看状态"
  echo "  11.重启 getout"
  echo "  12.更新 getout"
  echo "  13.卸载 getout"
  echo "  14.退出"
  echo
}

configure_entry_menu() {
  local entry_choice
  echo -e "${BLUE}修改入口:${NC}"
  echo "  1. SOCKS5 模式"
  echo "  2. WireGuard 模式"
  read -rp "请选择 [1/2]: " entry_choice
  case "$entry_choice" in
    1) configure_server ;;
    2) configure_wg_server ;;
    *) fatal "无效选项。" ;;
  esac
}

confirm_uninstall() {
  local yn
  read -rp "确认卸载 getout? [y/N]: " yn
  [[ "$yn" =~ ^[Yy]$ ]] && uninstall_all || echo "已取消"
}

handle_menu_choice() {
  local choice="$1"
  case "$choice" in
    1) if server_active; then stop_server; else start_server; fi ;;
    2) if wg_server_active; then stop_wg_server; else start_wg_server; fi ;;
    3) configure_entry_menu ;;
    4) if client_mode_active v4; then stop_client; else start_client v4; fi ;;
    5) if client_mode_active dual; then stop_client; else start_client dual; fi ;;
    6) if client_mode_active wg-v4; then stop_client; else start_wg_client wg-v4; fi ;;
    7) if client_mode_active wg-dual; then stop_client; else start_wg_client wg-dual; fi ;;
    8) configure_client ;;
    9) switch_priority_mode ;;
    10) status ;;
    11) restart_getout ;;
    12) update_getout ;;
    13) confirm_uninstall ;;
    14) exit 0 ;;
    *) fatal "无效选项。" ;;
  esac
}

menu() {
  local choice
  print_menu
  read -rp "请选择 [1-14]: " choice
  handle_menu_choice "$choice"
}

usage() {
  cat <<EOF
用法：getout [server|wg-server|v4|dual|wg-v4|wg-dual|stop|restart|status|doctor|check|update|uninstall]

server     启动 SOCKS5 模式
wg-server  启动 WireGuard 模式
v4         启动 s5-V4 单栈出口模式 (tun2socks)
dual       启动 s5-V4+V6 双栈出口模式 (tun2socks)
wg-v4      启动 WG-V4 单栈出口模式
wg-dual    启动 WG-V4+V6 双栈出口模式
stop       关闭当前运行中的 getout 模式
restart    重启当前运行中的 getout 模式
status     查看状态
doctor     检查系统环境、配置权限、服务文件和出口预检
check      同 doctor
update     更新 getout
uninstall  卸载并清理 getout
EOF
}

stop_current() {
  if server_active; then
    stop_server
  elif wg_server_active; then
    stop_wg_server
  elif tun_active; then
    stop_client
  elif wg_client_active; then
    stop_client
  else
    warn "当前 getout 未运行。"
  fi
}

main() {
  case "${1:-}" in
    -h|--help|help) ;;
    *) require_root; require_debian ;;
  esac
  case "${1:-}" in
    -h|--help|help) ;;
    *) secure_existing_files ;;
  esac
  case "${1:-}" in
    uninstall|remove|un|doctor|check|-h|--help|help) ;;
    *) ensure_global_command ;;
  esac

  case "${1:-}" in
    server) start_server ;;
    wg-server) start_wg_server ;;
    v4) start_client v4 ;;
    dual) start_client dual ;;
    wg-v4) start_wg_client wg-v4 ;;
    wg-dual) start_wg_client wg-dual ;;
    stop) stop_current ;;
    restart) restart_getout ;;
    status) status ;;
    doctor|check) doctor_check ;;
    update) update_getout ;;
    uninstall|remove|un) uninstall_all ;;
    -h|--help|help) usage ;;
    "") menu ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
