# --- 02 logging helpers -------------------------------------------------------

info() { echo -e "${BLUE}[信息]${NC} $*"; }
success() { echo -e "${GREEN}[成功]${NC} $*"; }
warn() { echo -e "${YELLOW}[警告]${NC} $*"; }
err() { echo -e "${RED}[错误]${NC} $*" >&2; }
fatal() { err "$*"; exit 1; }



print_header() {
  local title="$1" color="${2:-$BLUE}"
  printf '%b====================================================%b\n' "$color" "$NC"
  printf '%b%26s%b\n' "$color" "$title" "$NC"
  printf '%b====================================================%b\n' "$color" "$NC"
}
