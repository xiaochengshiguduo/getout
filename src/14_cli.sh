# --- 14 CLI dispatch ---------------------------------------------------------

menu_action_label() {
  local type="$1" mode="$(current_mode)"
  case "$type" in
    server)
      if server_active; then echo "关闭入口模式"; else echo "启动入口模式"; fi ;;
    v4)
      if tun_active && [ "$mode" = "v4" ]; then echo "关闭 V4 单栈模式"; else echo "启动 V4 单栈模式"; fi ;;
    dual)
      if tun_active && [ "$mode" = "dual" ]; then echo "关闭 V4+V6 双栈模式"; else echo "启动 V4+V6 双栈模式"; fi ;;
  esac
}

menu() {
  clear || true
  echo -e "${BLUE}====================================================${NC}"
  echo -e "${BLUE}                 getout 管理面板${NC}"
  echo -e "${BLUE}====================================================${NC}"
  echo "1.$(menu_action_label server)"
  echo "2.修改入口信息"
  echo "3.$(menu_action_label v4)"
  echo "4.$(menu_action_label dual)"
  echo "5.修改出口信息"
  echo "6.$(priority_action_label)"
  echo "7.重启 getout"
  echo "8.查看状态"
  echo "9.环境诊断"
  echo "10.更新 getout"
  echo "11.卸载 getout"
  echo "12.退出"
  echo
  read -rp "请选择 [1-12]: " choice
  case "$choice" in
    1) if server_active; then stop_server; else start_server; fi ;;
    2) configure_server ;;
    3) if client_mode_active v4; then stop_client; else start_client v4; fi ;;
    4) if client_mode_active dual; then stop_client; else start_client dual; fi ;;
    5) configure_client ;;
    6) switch_priority_mode ;;
    7) restart_getout ;;
    8) status ;;
    9) doctor_check ;;
    10) update_getout ;;
    11) read -rp "确认卸载 getout? [y/N]: " yn; [[ "$yn" =~ ^[Yy]$ ]] && uninstall_all || echo "已取消" ;;
    12) exit 0 ;;
    *) fatal "无效选项。" ;;
  esac
}

usage() {
  cat <<EOF
用法：getout [server|v4|dual|stop|restart|status|doctor|check|update|uninstall]

server     启动入口模式，复用已有入口配置；没有配置时询问
v4         启动 V4 单栈出口模式，复用已有出口配置；没有配置时询问
dual       启动 V4+V6 双栈出口模式，复用已有出口配置；没有配置时询问
stop       关闭当前运行中的 getout 模式，并关闭对应自启动
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
  elif tun_active; then
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
    v4) start_client v4 ;;
    dual) start_client dual ;;
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
