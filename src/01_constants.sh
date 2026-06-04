SCRIPT_VERSION="0.3.0"
INSTALL_PATH="/usr/local/bin/getout"
UPDATE_URL="https://raw.githubusercontent.com/xiaochengshiguduo/getout/main/getout.sh"
UPDATE_SHA256_URL="https://raw.githubusercontent.com/xiaochengshiguduo/getout/main/getout.sh.sha256"
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

APP="getout"
CONF_DIR="/etc/getout"
MODE_FILE="$CONF_DIR/mode"
SERVER_CONF="$CONF_DIR/server.conf"
CLIENT_CONF="$CONF_DIR/client.conf"
TUN_CONF="$CONF_DIR/tun2socks.yaml"
ROUTES_UP="$CONF_DIR/routes-up.sh"
ROUTES_DOWN="$CONF_DIR/routes-down.sh"
RUNTIME_DNS_V4_SERVERS=("8.8.8.8" "1.1.1.1")
RUNTIME_DNS_V6_SERVERS=("2001:4860:4860::8888" "2606:4700:4700::1111")
DEFAULT_PRIORITY_MODE="v6"
RESOLV_ORIG="$CONF_DIR/resolv.conf.orig"
GAI_ORIG="$CONF_DIR/gai.conf.orig"
RESOLV_MARKER="$CONF_DIR/resolv.conf.getout"
GAI_MARKER="$CONF_DIR/gai.conf.getout"
RESOLV_META="$CONF_DIR/resolv.conf.meta"
RESOLV_TARGET_ORIG="$CONF_DIR/resolv.conf.target.orig"
GAI_META="$CONF_DIR/gai.conf.meta"

GOST_BIN="/usr/local/bin/getout-gost"
TUN_BIN="/usr/local/bin/getout-tun2socks"
GOST_SERVICE="/etc/systemd/system/getout-gost.service"
TUN_SERVICE="/etc/systemd/system/getout-tun.service"

GOST_VERSION="2.11.5"
HEV_VERSION="2.15.0"
TABLE_ID="20"
MARK_ID="438"
BYPASS_MARK_ID="439"
NFT_TABLE="getout_protect"
TUN_NAME="tun0"
DNS64_SERVERS=(
  "2001:67c:2960::64"
  "2a00:1098:2b::1"
  "2a00:1098:2c::1"
  "2a01:4f8:c2c:123f::1"
  "2001:67c:2960::6464"
)

# =============================================================================
# Maintainer map
# -----------------------------------------------------------------------------
# getout is intentionally published as one self-contained script so raw GitHub
# install/update and a single checksum artifact stay simple. Development sources
# live in src/*.sh; build.sh concatenates them into this release artifact.
#
# 00 prelude / shell options
# 01 constants / globals
# 02 logging helpers
# 03 self install / update / checksum
# 04 config permissions and file metadata
# 05 resolver and managed file restore
# 06 runtime/server rollback snapshots
# 07 host prerequisites and binary downloads
# 08 encoding, address, and SSH helpers
# 09 cleanup, preflight, and restart wrappers
# 10 generated route scripts
# 11 service state and entry/server mode
# 12 outlet/client mode
# 13 lifecycle, status, and diagnostics
# 14 CLI dispatch
# =============================================================================

