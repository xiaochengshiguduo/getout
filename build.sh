#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT_DIR/getout.sh"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

modules=(
  src/00_prelude.sh
  src/01_constants.sh
  src/02_logging.sh
  src/03_update.sh
  src/04_config.sh
  src/05_resolver.sh
  src/06_rollback.sh
  src/07_deps_downloads.sh
  src/08_helpers.sh
  src/09_runtime_safety.sh
  src/10_route_scripts.sh
  src/11_server.sh
  src/12_client.sh
  src/13_lifecycle_status_doctor.sh
  src/14_cli.sh
)

: > "$TMP"
for module in "${modules[@]}"; do
  path="$ROOT_DIR/$module"
  [ -f "$path" ] || { echo "missing module: $module" >&2; exit 1; }
  cat "$path" >> "$TMP"
done

bash -n "$TMP"
install -m 0755 "$TMP" "$OUT"
(
  cd "$ROOT_DIR"
  sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256"
)
