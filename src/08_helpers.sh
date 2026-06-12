# --- 08 encoding, address, and SSH helpers -----------------------------------

is_ipv6() { [[ "$1" == *:* ]]; }
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

strip_brackets() {
  local s="$1"
  s="${s#[}"
  s="${s%]}"
  echo "$s"
}

shell_quote() {
  printf '%q' "$1"
}

yaml_quote() {
  local s="$1"
  s="${s//\'/\'\'}"
  printf "'%s'" "$s"
}

systemd_escape_percent() {
  printf '%s' "$1" | sed 's/%/%%/g'
}

reject_url_unsafe() {
  local name="$1" value="$2"
  [[ "$value" != *[[:space:]]* ]] || fatal "$name 不能包含空白字符。"
  [[ "$value" != *"@"* ]] || fatal "$name 不能包含 @ 字符。"
  [[ "$value" != *":"* ]] || fatal "$name 不能包含 : 字符。"
  [[ "$value" != *"/"* ]] || fatal "$name 不能包含 / 字符。"
  [[ "$value" != *"?"* ]] || fatal "$name 不能包含 ? 字符。"
  [[ "$value" != *"#"* ]] || fatal "$name 不能包含 # 字符。"
  [[ "$value" != *"%"* ]] || fatal "$name 不能包含 % 字符。"
  [[ "$value" != *"&"* ]] || fatal "$name 不能包含 & 字符。"
  [[ "$value" != *"["* ]] || fatal "$name 不能包含 [ 字符。"
  [[ "$value" != *"]"* ]] || fatal "$name 不能包含 ] 字符。"
  [[ "$value" != *"\\"* ]] || fatal "$name 不能包含 \\ 字符。"
}

ssh_remote_ip() {
  if [ -n "${SSH_CONNECTION:-}" ]; then
    awk '{print $1}' <<<"$SSH_CONNECTION"
  elif [ -n "${SSH_CLIENT:-}" ]; then
    awk '{print $1}' <<<"$SSH_CLIENT"
  else
    true
  fi
}

ssh_listen_ports() {
  {
    if [ -n "${SSH_CONNECTION:-}" ]; then
      awk '{print $4}' <<<"$SSH_CONNECTION"
    fi
    if command -v sshd >/dev/null 2>&1; then
      sshd -T 2>/dev/null | awk '$1=="port" {print $2}'
    elif [ -x /usr/sbin/sshd ]; then
      /usr/sbin/sshd -T 2>/dev/null | awk '$1=="port" {print $2}'
    fi
    if command -v ss >/dev/null 2>&1; then
      ss -H -ltnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}'
    fi
  } | awk '/^[0-9]+$/ && $1 >= 1 && $1 <= 65535 {seen[$1]=1} END {for (p in seen) print p}' | sort -n
}

# --- subnet helpers for NAT rules -------------------------------------------

# 从 addr/prefix 计算 IPv4 网络 CIDR (例: 10.66.66.1/24 → 10.66.66.0/24)
get_v4_network() {
  local addr="${1%%/*}" prefix="${1##*/}"
  IFS=. read -r a b c d <<< "$addr"
  local ip=$(( (a << 24) + (b << 16) + (c << 8) + d ))
  local mask=$(( 0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF ))
  local net=$(( ip & mask ))
  echo "$(( (net >> 24) & 255 )).$(( (net >> 16) & 255 )).$(( (net >> 8) & 255 )).$(( net & 255 ))/$prefix"
}

# 从 addr/prefix 计算 IPv6 网络 CIDR (例: fd86:ea04:1115::1/64 → fd86:ea04:1115::/64)
get_v6_network() {
  local addr="${1%%/*}" prefix="${1##*/}"
  if [[ "$addr" == *"::"* ]]; then
    echo "${addr%%::*}::/$prefix"
  else
    echo "$addr/$prefix"
  fi
}

main_ipv4() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true
}

main_ipv6() {
  ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true
}

