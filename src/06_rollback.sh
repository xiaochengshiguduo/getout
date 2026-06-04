# --- 06 runtime/server rollback snapshots ------------------------------------

snapshot_runtime_files() {
  local dir
  dir="$(mktemp -d)" || fatal "创建回滚快照失败。"
  for file in "$CLIENT_CONF" "$TUN_CONF" "$ROUTES_UP" "$ROUTES_DOWN" "$TUN_SERVICE" "$MODE_FILE"; do
    touch "$dir/$(basename "$file").missing" 2>/dev/null || true
    if [ -e "$file" ]; then
      cp -a "$file" "$dir/$(basename "$file")" 2>/dev/null || true
      rm -f "$dir/$(basename "$file").missing" 2>/dev/null || true
    fi
  done
  echo "$dir"
}

snapshot_server_files() {
  local dir file
  dir="$(mktemp -d)" || fatal "创建入口回滚快照失败。"
  for file in "$SERVER_CONF" "$GOST_SERVICE" "$MODE_FILE"; do
    touch "$dir/$(basename "$file").missing" 2>/dev/null || true
    if [ -e "$file" ]; then
      cp -a "$file" "$dir/$(basename "$file")" 2>/dev/null || true
      rm -f "$dir/$(basename "$file").missing" 2>/dev/null || true
    fi
  done
  echo "$dir"
}

restore_runtime_files() {
  local dir="$1" file base
  [ -d "$dir" ] || return 0
  for file in "$CLIENT_CONF" "$TUN_CONF" "$ROUTES_UP" "$ROUTES_DOWN" "$TUN_SERVICE" "$MODE_FILE"; do
    base="$(basename "$file")"
    if [ -e "$dir/$base" ]; then
      cp -a "$dir/$base" "$file" 2>/dev/null || true
    elif [ -e "$dir/$base.missing" ]; then
      rm -f "$file" 2>/dev/null || true
    fi
  done
  systemctl daemon-reload 2>/dev/null || true
}

restore_server_files() {
  local dir="$1" file base
  [ -d "$dir" ] || return 0
  for file in "$SERVER_CONF" "$GOST_SERVICE" "$MODE_FILE"; do
    base="$(basename "$file")"
    if [ -e "$dir/$base" ]; then
      cp -a "$dir/$base" "$file" 2>/dev/null || true
    elif [ -e "$dir/$base.missing" ]; then
      rm -f "$file" 2>/dev/null || true
    fi
  done
  systemctl daemon-reload 2>/dev/null || true
}

remove_runtime_snapshot() {
  [ -n "${1:-}" ] && rm -rf "$1" 2>/dev/null || true
}

RUNTIME_ROLLBACK_SNAPSHOT=""
RUNTIME_ROLLBACK_RESTORE="restore_runtime_or_warn"

runtime_rollback_on_exit() {
  local snapshot="${RUNTIME_ROLLBACK_SNAPSHOT:-}"
  [ -n "$snapshot" ] || return 0
  RUNTIME_ROLLBACK_SNAPSHOT=""
  "${RUNTIME_ROLLBACK_RESTORE:-restore_runtime_or_warn}" "$snapshot"
}

begin_runtime_rollback() {
  RUNTIME_ROLLBACK_SNAPSHOT="$1"
  RUNTIME_ROLLBACK_RESTORE="restore_runtime_or_warn"
  trap runtime_rollback_on_exit EXIT
}

begin_server_rollback() {
  RUNTIME_ROLLBACK_SNAPSHOT="$1"
  RUNTIME_ROLLBACK_RESTORE="restore_server_or_warn"
  trap runtime_rollback_on_exit EXIT
}

clear_runtime_rollback() {
  local snapshot="${1:-${RUNTIME_ROLLBACK_SNAPSHOT:-}}"
  RUNTIME_ROLLBACK_SNAPSHOT=""
  trap - EXIT
  remove_runtime_snapshot "$snapshot"
}

secure_existing_files() {
  [ -d "$CONF_DIR" ] && chmod 700 "$CONF_DIR" 2>/dev/null || true
  chmod_private_file "$SERVER_CONF"
  chmod_private_file "$CLIENT_CONF"
  chmod_private_file "$TUN_CONF"
  chmod_private_file "$MODE_FILE"
  chmod_private_file "$GOST_SERVICE"
  chmod_private_file "$TUN_SERVICE"
  [ -f "$ROUTES_UP" ] && chmod 700 "$ROUTES_UP" 2>/dev/null || true
  [ -f "$ROUTES_DOWN" ] && chmod 700 "$ROUTES_DOWN" 2>/dev/null || true
}

