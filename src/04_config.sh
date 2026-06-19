# --- 04 config permissions and file metadata ---------------------------------

ensure_conf_dir() {
  mkdir -p "$CONF_DIR"
  chmod 700 "$CONF_DIR" 2>/dev/null || true
}

chmod_private_file() {
  [ -f "$1" ] && chmod 600 "$1" 2>/dev/null || true
}

assert_private_config() {
  local file="$1"
  [ -f "$file" ] || fatal "配置文件不存在：$file"
  if ! find "$file" -maxdepth 0 -type f -user root ! -perm /022 | grep -q .; then
    fatal "配置文件权限不安全：$file。请确认 owner=root 且 group/other 不可写。"
  fi
}

file_checksum() {
  [ -e "$1" ] || { echo missing; return 0; }
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}' || echo unknown
  else
    cksum "$1" 2>/dev/null | awk '{print $1":"$2}' || echo unknown
  fi
}

write_file_meta() {
  local path="$1" meta="$2" backup="$3" exists target checksum
  exists=0; [ -e "$path" ] && exists=1
  target=""
  [ -L "$path" ] && target="$(readlink "$path" 2>/dev/null || true)"
  checksum="$(file_checksum "$path")"
  {
    printf 'EXISTS=%s\n' "$(shell_quote "$exists")"
    printf 'SYMLINK_TARGET=%s\n' "$(shell_quote "$target")"
    printf 'CHECKSUM=%s\n' "$(shell_quote "$checksum")"
    if [ -e "$backup" ]; then
      printf 'BACKUP_CHECKSUM=%s\n' "$(shell_quote "$(file_checksum "$backup")")"
    else
      printf 'BACKUP_CHECKSUM=%s\n' "$(shell_quote missing)"
    fi
  } > "$meta"
  chmod_private_file "$meta"
}

