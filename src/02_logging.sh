# --- 02 logging helpers -------------------------------------------------------

info() { echo -e "${BLUE}[信息]${NC} $*"; }
success() { echo -e "${GREEN}[成功]${NC} $*"; }
warn() { echo -e "${YELLOW}[警告]${NC} $*"; }
err() { echo -e "${RED}[错误]${NC} $*" >&2; }
fatal() { err "$*"; exit 1; }



print_header() {
  local title="$1" color="${2:-$BLUE}"
  local line="===================================================="
  local line_len=${#line}
  local title_display_len=$(printf '%s' "$title" | wc -m)
  local padding=$(( (line_len - title_display_len) / 2 ))
  printf '%b%s%b\n' "$color" "$line" "$NC"
  printf '%b%*s%s%b\n' "$color" "$padding" "" "$title" "$NC"
  printf '%b%s%b\n' "$color" "$line" "$NC"
}
