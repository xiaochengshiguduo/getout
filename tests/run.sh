#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/getout.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

pass() { printf '[OK] %s\n' "$*"; }

make_lib() {
  local lib="$1"
  awk '/^main "\$@"/ {exit} {print}' "$SCRIPT" > "$lib"
}

run_bash_syntax() {
  bash -n "$SCRIPT"
  pass 'getout.sh syntax'
}

run_route_script_syntax() {
  local t="$TMP_ROOT/routes"
  local lib="$t/lib.sh"
  mkdir -p "$t"
  make_lib "$lib"
  (
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$lib"
    CONF_DIR="$t/conf"
    CLIENT_CONF="$CONF_DIR/client.conf"
    ROUTES_UP="$CONF_DIR/routes-up.sh"
    ROUTES_DOWN="$CONF_DIR/routes-down.sh"
    mkdir -p "$CONF_DIR"
    write_routes_scripts
    bash -n "$ROUTES_UP"
    bash -n "$ROUTES_DOWN"
  )
  pass 'generated route scripts syntax'
}

run_runtime_restore_deletes_new_files() {
  local t="$TMP_ROOT/runtime"
  local lib="$t/lib.sh"
  mkdir -p "$t"
  make_lib "$lib"
  (
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$lib"
    CONF_DIR="$t/etc-getout"
    CLIENT_CONF="$CONF_DIR/client.conf"
    TUN_CONF="$CONF_DIR/tun2socks.yaml"
    ROUTES_UP="$CONF_DIR/routes-up.sh"
    ROUTES_DOWN="$CONF_DIR/routes-down.sh"
    TUN_SERVICE="$t/getout-tun.service"
    MODE_FILE="$CONF_DIR/mode"
    systemctl() { :; }
    mkdir -p "$CONF_DIR"
    printf 'old-client\n' > "$CLIENT_CONF"
    printf 'old-routes-up\n' > "$ROUTES_UP"
    snapshot="$(snapshot_runtime_files)"
    begin_runtime_rollback "$snapshot"
    printf 'new-client\n' > "$CLIENT_CONF"
    printf 'new-tun\n' > "$TUN_CONF"
    printf 'new-routes-up\n' > "$ROUTES_UP"
    printf 'new-routes-down\n' > "$ROUTES_DOWN"
    printf 'new-service\n' > "$TUN_SERVICE"
    printf 'dual\n' > "$MODE_FILE"
    restore_runtime_or_warn "$snapshot" >/dev/null 2>&1
    [ "$(cat "$CLIENT_CONF")" = old-client ]
    [ "$(cat "$ROUTES_UP")" = old-routes-up ]
    [ ! -e "$TUN_CONF" ]
    [ ! -e "$ROUTES_DOWN" ]
    [ ! -e "$TUN_SERVICE" ]
    [ ! -e "$MODE_FILE" ]
  )
  pass 'runtime rollback restores old files and deletes new files'
}

run_preflight_failure_rolls_back() {
  local t="$TMP_ROOT/preflight"
  local lib="$t/lib.sh"
  mkdir -p "$t"
  make_lib "$lib"
  cat > "$t/case.sh" <<'CASE'
#!/usr/bin/env bash
set -euo pipefail
. "$1"
root="$2"
CONF_DIR="$root/etc-getout"
CLIENT_CONF="$CONF_DIR/client.conf"
TUN_CONF="$CONF_DIR/tun2socks.yaml"
ROUTES_UP="$CONF_DIR/routes-up.sh"
ROUTES_DOWN="$CONF_DIR/routes-down.sh"
TUN_SERVICE="$root/getout-tun.service"
MODE_FILE="$CONF_DIR/mode"
TUN_BIN="$root/missing-tun2socks"
systemctl() { :; }
mkdir -p "$CONF_DIR"
printf 'old-client\n' > "$CLIENT_CONF"
snapshot="$(snapshot_runtime_files)"
begin_runtime_rollback "$snapshot"
printf '%s\n' "$snapshot" > "$root/snapshot-path"
printf 'new-client\n' > "$CLIENT_CONF"
printf 'new-tun\n' > "$TUN_CONF"
preflight_tun_runtime_with_rollback "$snapshot"
CASE
  set +e
  out="$(bash "$t/case.sh" "$lib" "$t/root" 2>&1)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ]
  [ "$(cat "$t/root/etc-getout/client.conf")" = old-client ]
  [ ! -e "$t/root/etc-getout/tun2socks.yaml" ]
  snapshot="$(cat "$t/root/snapshot-path")"
  [ ! -d "$snapshot" ]
  grep -q '未找到可执行 tun2socks' <<<"$out"
  pass 'preflight failure rolls back runtime snapshot'
}

run_daemon_reload_failure_rolls_back_runtime() {
  local t="$TMP_ROOT/daemon"
  local lib="$t/lib.sh"
  mkdir -p "$t"
  make_lib "$lib"
  cat > "$t/case.sh" <<'CASE'
#!/usr/bin/env bash
set -euo pipefail
. "$1"
root="$2"
CONF_DIR="$root/etc-getout"
CLIENT_CONF="$CONF_DIR/client.conf"
TUN_CONF="$CONF_DIR/tun2socks.yaml"
ROUTES_UP="$CONF_DIR/routes-up.sh"
ROUTES_DOWN="$CONF_DIR/routes-down.sh"
TUN_SERVICE="$root/getout-tun.service"
MODE_FILE="$CONF_DIR/mode"
TUN_BIN="$root/getout-tun2socks"
systemctl() { return 1; }
mkdir -p "$CONF_DIR"
printf 'old-client\n' > "$CLIENT_CONF"
printf 'old-service\n' > "$TUN_SERVICE"
snapshot="$(snapshot_runtime_files)"
begin_runtime_rollback "$snapshot"
printf '%s\n' "$snapshot" > "$root/snapshot-path"
cat > "$CLIENT_CONF" <<CONF
MODE=v4
SOCKS_ADDRESS=127.0.0.1
SOCKS_PORT=1080
SOCKS_USERNAME=
SOCKS_PASSWORD=
TABLE_ID=20
MARK_ID=438
BYPASS_MARK_ID=439
NFT_TABLE=getout_protect
TUN_NAME=tun0
CONF
write_tun_service v4
clear_runtime_rollback "$snapshot"
CASE
  set +e
  out="$(bash "$t/case.sh" "$lib" "$t/root" 2>&1)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ]
  [ "$(cat "$t/root/etc-getout/client.conf")" = old-client ]
  [ "$(cat "$t/root/getout-tun.service")" = old-service ]
  snapshot="$(cat "$t/root/snapshot-path")"
  [ ! -d "$snapshot" ]
  grep -q '已尝试恢复旧配置和旧 systemd 文件' <<<"$out"
  pass 'daemon-reload failure rolls back runtime snapshot'
}

run_server_daemon_reload_failure_rolls_back() {
  local t="$TMP_ROOT/server"
  local lib="$t/lib.sh"
  mkdir -p "$t"
  make_lib "$lib"
  cat > "$t/case.sh" <<'CASE'
#!/usr/bin/env bash
set -euo pipefail
. "$1"
root="$2"
CONF_DIR="$root/etc-getout"
SERVER_CONF="$CONF_DIR/server.conf"
GOST_SERVICE="$root/getout-gost.service"
MODE_FILE="$CONF_DIR/mode"
systemctl() { return 1; }
mkdir -p "$CONF_DIR"
printf 'old-server\n' > "$SERVER_CONF"
printf 'old-service\n' > "$GOST_SERVICE"
snapshot="$(snapshot_server_files)"
begin_server_rollback "$snapshot"
printf '%s\n' "$snapshot" > "$root/snapshot-path"
cat > "$SERVER_CONF" <<CONF
PORT=1080
USERNAME=user
PASSWORD=pass
CONF
write_gost_service
clear_runtime_rollback "$snapshot"
CASE
  set +e
  out="$(bash "$t/case.sh" "$lib" "$t/root" 2>&1)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ]
  [ "$(cat "$t/root/etc-getout/server.conf")" = old-server ]
  [ "$(cat "$t/root/getout-gost.service")" = old-service ]
  snapshot="$(cat "$t/root/snapshot-path")"
  [ ! -d "$snapshot" ]
  grep -q '入口模式启动失败，已尝试恢复旧入口配置和旧 systemd 文件' <<<"$out"
  pass 'entry daemon-reload failure rolls back server snapshot'
}

run_checksum_file_matches_script() {
  [ -f "$ROOT_DIR/getout.sh.sha256" ]
  (cd "$ROOT_DIR" && sha256sum -c getout.sh.sha256 >/dev/null)
  pass 'repository getout.sh.sha256 matches getout.sh'
}

run_checksum_verification() {
  local t="$TMP_ROOT/checksum"
  local lib="$t/lib.sh" sample="$t/sample.sh"
  mkdir -p "$t"
  make_lib "$lib"
  printf 'hello\n' > "$sample"
  (
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$lib"
    GETOUT_UPDATE_SHA256="$(sha256sum "$sample" | awk '{print $1}')"
    verify_update_checksum "$sample"
  )
  set +e
  out="$(bash -c '. "$1"; GETOUT_UPDATE_SHA256=bad verify_update_checksum "$2"' _ "$lib" "$sample" 2>&1)"
  rc=$?
  set -e
  [ "$rc" -ne 0 ]
  grep -q 'SHA256 校验失败' <<<"$out"
  pass 'update checksum verification accepts match and rejects mismatch'
}

run_bash_syntax
run_route_script_syntax
run_runtime_restore_deletes_new_files
run_preflight_failure_rolls_back
run_daemon_reload_failure_rolls_back_runtime
run_server_daemon_reload_failure_rolls_back
run_checksum_file_matches_script
run_checksum_verification
