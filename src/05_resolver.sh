# --- 05 resolver and managed file restore ------------------------------------

restore_path_from_backup() {
  local path="$1" backup="$2" meta="$3" marker="$4" label="$5" target_backup="${6:-}"
  local exists="1" symlink_target="" backup_checksum="" current_checksum marker_checksum
  [ -f "$meta" ] && { # shellcheck disable=SC1090
    . "$meta"; exists="${EXISTS:-1}"; symlink_target="${SYMLINK_TARGET:-}"; backup_checksum="${BACKUP_CHECKSUM:-}"; }
  if [ ! -e "$backup" ]; then
    [ -f "$marker" ] && warn "$label 原始备份缺失，已保留当前内容，避免误恢复到未知状态。"
    return 0
  fi
  current_checksum="$(file_checksum "$path")"
  if [ -f "$marker" ]; then
    marker_checksum="$(cat "$marker" 2>/dev/null || true)"
    if [ -n "$marker_checksum" ] && [ "$marker_checksum" != "$current_checksum" ]; then
      warn "$label 在 getout 运行期间被外部修改，已保留当前内容；旧备份已归档，后续启动会重新备份当前状态。"
      mv -f "$backup" "$backup.conflict.$(date +%s)" 2>/dev/null || true
      [ -n "$target_backup" ] && mv -f "$target_backup" "$target_backup.conflict.$(date +%s)" 2>/dev/null || true
      rm -f "$meta" "$marker" 2>/dev/null || true
      return 0
    fi
  fi
  if [ "$exists" = "0" ]; then
    rm -f "$path" 2>/dev/null || true
  elif [ -n "$symlink_target" ]; then
    rm -f "$path" 2>/dev/null || true
    ln -s "$symlink_target" "$path" 2>/dev/null || cp -a "$backup" "$path" 2>/dev/null || true
    if [ -n "$target_backup" ] && [ -e "$target_backup" ]; then
      cp -a "$target_backup" "$(readlink -f "$path" 2>/dev/null || echo "$path")" 2>/dev/null || true
    fi
  else
    cp -a "$backup" "$path" 2>/dev/null || true
  fi
  rm -f "$backup" "$meta" "$marker" "$target_backup" 2>/dev/null || true
}

