# --- 03 self install / update / checksum -------------------------------------

running_from_install_path() {
  local src="${BASH_SOURCE[0]:-$0}" real_src real_install
  [ "$src" = "$INSTALL_PATH" ] && return 0
  if command -v realpath >/dev/null 2>&1; then
    real_src="$(realpath "$src" 2>/dev/null || true)"
    real_install="$(realpath "$INSTALL_PATH" 2>/dev/null || true)"
    [ -n "$real_src" ] && [ -n "$real_install" ] && [ "$real_src" = "$real_install" ] && return 0
  fi
  return 1
}

extract_script_version() {
  sed -n 's/^SCRIPT_VERSION="\([^"]\+\)".*/\1/p' "$1" | head -n1
}

download_to_file() {
  local url="$1" output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 20 --retry 2 --retry-delay 1 "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$output" "$url"
  else
    return 127
  fi
}

verify_update_checksum() {
  local file="$1" expected="${GETOUT_UPDATE_SHA256:-}" checksum tmp_hash hash_url sep
  if [ -z "$expected" ]; then
    tmp_hash="$(mktemp)"
    hash_url="${GETOUT_UPDATE_SHA256_URL:-$UPDATE_SHA256_URL}"
    if [[ "$hash_url" == http://* || "$hash_url" == https://* ]]; then
      sep="?"; [[ "$hash_url" == *\?* ]] && sep="&"
      hash_url="${hash_url}${sep}v=${SCRIPT_VERSION}&t=$(date +%s)"
    fi
    if download_to_file "$hash_url" "$tmp_hash" 2>/dev/null; then
      expected="$(awk 'NF {print $1; exit}' "$tmp_hash" 2>/dev/null || true)"
    fi
    rm -f "$tmp_hash" 2>/dev/null || true
  fi
  [ -n "$expected" ] || { warn "未找到 getout.sh.sha256，已跳过更新完整性校验。"; return 0; }
  command -v sha256sum >/dev/null 2>&1 || fatal "已提供 SHA256 校验值，但系统缺少 sha256sum。"
  checksum="$(sha256sum "$file" | awk '{print $1}')"
  [ "$checksum" = "$expected" ] || fatal "getout 下载文件 SHA256 校验失败，已取消安装/更新。"
}

install_from_update_url() {
  local mode="${1:-install}" tmp version download_url
  tmp="$(mktemp)"
  download_url="$UPDATE_URL"
  if [[ "$download_url" == http://* || "$download_url" == https://* ]]; then
    download_url="${download_url}?v=${SCRIPT_VERSION}&t=$(date +%s)"
  fi
  trap 'rm -f "$tmp"' RETURN EXIT

  rm -f "$tmp"
  if ! download_to_file "$download_url" "$tmp"; then
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || fatal "未找到 curl 或 wget，无法下载安装 getout。"
    fatal "getout 下载失败。"
  fi

  [ -s "$tmp" ] || fatal "getout 下载结果为空。"
  verify_update_checksum "$tmp"
  bash -n "$tmp" || fatal "getout 语法校验失败，已取消安装。"
  grep -q 'getout 管理面板' "$tmp" || fatal "getout 特征校验失败，已取消安装。"
  grep -q '^SCRIPT_VERSION=' "$tmp" || fatal "getout 版本校验失败，已取消安装。"
  grep -q '^UPDATE_URL=' "$tmp" || fatal "getout 更新源校验失败，已取消安装。"
  version="$(extract_script_version "$tmp")"
  [ -n "$version" ] || fatal "无法读取 getout 版本号，已取消安装。"

  install -m 0755 "$tmp" "$INSTALL_PATH"
  rm -f "$tmp"
  trap - RETURN EXIT

  if [ "$mode" = "update" ]; then
    success "getout 已更新，当前版本 ${version}。"
  else
    success "已安装全局命令：getout。"
  fi
}

ensure_global_command() {
  running_from_install_path && return 0
  install_from_update_url install
}

update_getout() {
  require_root
  install_from_update_url update
  if service_active getout-tun.service || service_active getout-gost.service || service_active getout-wg.service; then
    warn "getout 正在运行。需要重启才能刷新服务文件和路由脚本。"
    if [ -t 0 ]; then
      local yn
      read -rp "是否立即执行 getout restart? [y/N]: " yn
      if [[ "$yn" =~ ^[Yy]$ ]]; then
        "$INSTALL_PATH" restart || true
        return 0
      fi
    fi
    warn "已跳过自动重启。请稍后执行 getout restart。"
  fi
}

