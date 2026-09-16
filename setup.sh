#!/usr/bin/env bash
#
# One-shot setup for a fresh Ubuntu/Debian box.
#
#   ./setup.sh path/to/downloaded-client-config.ovpn
#
# Does, in order, what the README used to ask you to do by hand:
#   1. check build + runtime dependencies, offering to apt-get what's missing
#   2. derive vpn.conf and vpn.env from the AWS .ovpn profile you downloaded
#   3. build the patched openvpn (skipped when ./openvpn is already current)
#   4. optionally install the passwordless-activation helper
#
# Every step is idempotent, so re-running is cheap and safe:
#
#   ./setup.sh profile.ovpn      # full setup
#   ./setup.sh                   # re-check deps / rebuild, keep existing config
#   ./setup.sh -y profile.ovpn   # non-interactive (apt + sudo install, no prompts)
#   ./setup.sh --rebuild         # force a rebuild of ./openvpn
#   ./setup.sh --no-nopasswd     # skip step 4
#
# The only other privileged piece, install-nopasswd.sh, stays a separate script
# because it runs under sudo and is the literal target of the sudoers rule.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# The openvpn release this repo patches. Bumping it means dropping in a matching
# openvpn-v<VER>-aws.patch and changing this line -- nothing else.
VER="${OPENVPN_VERSION:-2.6.12}"
PATCH="openvpn-v${VER}-aws.patch"
STAMP="$HERE/.build-stamp"
BIN="$HERE/openvpn"

ASSUME_YES=0
FORCE_REBUILD=0
DO_NOPASSWD=1
PROFILE=""

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { echo "    $*"; }
warn() { echo "    WARNING: $*" >&2; }

# Yes/no prompt. -y answers yes; with no tty (CI, piped input) the answer is no,
# so nothing surprising happens unattended.
ask() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ -t 0 ] || { info "(not interactive, skipping)"; return 1; }
  local reply
  read -r -p "    $1 [y/N] " reply
  [[ "$reply" =~ ^[Yy] ]]
}

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)      ASSUME_YES=1 ;;
    --rebuild)     FORCE_REBUILD=1 ;;
    --no-nopasswd) DO_NOPASSWD=0 ;;
    -h|--help)     awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    -*)            die "unknown option: $1" ;;
    *)             [ -z "$PROFILE" ] || die "unexpected argument: $1"; PROFILE="$1" ;;
  esac
  shift
done

# Running the whole thing under sudo would leave vpn.conf/vpn.env root-owned and
# would break install-nopasswd.sh, which grants the rule to $SUDO_USER.
[ "$(id -u)" -ne 0 ] || die "run as your normal user, not root (setup.sh calls sudo itself where needed)"

# ---------------------------------------------------------------- 1. deps ----
step "Checking dependencies"

MISSING=()
need_cmd() { command -v "$1" >/dev/null 2>&1 || MISSING+=("$2"); }
need_lib() { pkg-config --exists "$1" 2>/dev/null || MISSING+=("$2"); }

apt_install() {
  # dedupe while preserving order
  local pkgs=() p
  for p in "$@"; do [[ " ${pkgs[*]-} " == *" $p "* ]] || pkgs+=("$p"); done
  echo
  info "Missing packages: ${pkgs[*]}"
  info "  sudo apt-get install -y ${pkgs[*]}"
  ask "Install them now?" || die "dependencies missing; install the packages above and re-run"
  sudo apt-get update
  sudo apt-get install -y "${pkgs[@]}"
}

# Pass 1: the tools. pkg-config must exist before the library probes below can
# say anything meaningful, so this pass runs first.
need_cmd gcc        build-essential
need_cmd make       build-essential
need_cmd patch      patch
need_cmd tar        tar
need_cmd curl       curl
need_cmd python3    python3
need_cmd openssl    openssl
need_cmd pkg-config pkg-config
[ "${#MISSING[@]}" -eq 0 ] || apt_install "${MISSING[@]}"

# Pass 2: the headers openvpn's configure requires. libcap-ng is a hard
# requirement on Linux (configure.ac: "libcap-ng package not found") and is not
# pulled in by build-essential -- omitting it is the classic fresh-box failure.
MISSING=()
need_lib openssl   libssl-dev
need_lib lzo2      liblzo2-dev
need_lib libcap-ng libcap-ng-dev
[ "${#MISSING[@]}" -eq 0 ] || apt_install "${MISSING[@]}"

info "All dependencies present."
# dig is deliberately not required: aws-connect.sh falls back to getent, which
# needs no package. Mention it only as a nicety.
command -v dig >/dev/null 2>&1 || info "(optional: 'sudo apt-get install bind9-dnsutils' for dig; getent is used otherwise)"

# ------------------------------------------------------------- 2. profile ----
if [ -n "$PROFILE" ]; then
  step "Importing endpoint profile from $PROFILE"
  [ -f "$PROFILE" ] || die "no such file: $PROFILE"

  grep -qE '^[[:space:]]*auth-federate([[:space:]]|$)' "$PROFILE" ||
    warn "no 'auth-federate' line -- is this really a SAML AWS Client VPN profile?"

  REMOTE_LINE="$(tr -d '\r' < "$PROFILE" | grep -m1 -E '^[[:space:]]*remote[[:space:]]+[^[:space:]]' || true)"
  [ -n "$REMOTE_LINE" ] || die "no 'remote <host> <port>' line found in $PROFILE"

  VPN_HOST="$(awk '{print $2}' <<<"$REMOTE_LINE")"
  PORT="$(awk '{print ($3 == "" ? 443 : $3)}' <<<"$REMOTE_LINE")"
  PROTO="$(tr -d '\r' < "$PROFILE" | grep -m1 -E '^[[:space:]]*proto[[:space:]]+' | awk '{print $2}' || true)"
  # vpn-phase2.sh only accepts bare udp/tcp; normalise udp6 / tcp-client / empty.
  case "$PROTO" in
    tcp*) PROTO=tcp ;;
    *)    PROTO=udp ;;
  esac

  [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || die "could not parse a port from: $REMOTE_LINE"

  info "endpoint: $VPN_HOST"
  info "port:     $PORT"
  info "proto:    $PROTO"

  # Keep a copy of anything we're about to replace -- these files are gitignored
  # and often hand-edited, so there's no other way back.
  for f in vpn.conf vpn.env; do
    [ -f "$f" ] && cp -p "$f" "$f.bak" && info "existing $f saved as $f.bak" || true
  done

  {
    printf '# Generated by setup.sh from %s on %s\n' "$(basename "$PROFILE")" "$(date -I)"
    printf '# The wrapper supplies remote/auth options on the CLI, so they are stripped here.\n'
    # tr -d '\r': profiles downloaded on Windows arrive CRLF, which openvpn
    # tolerates unevenly (and breaks the inline <ca> block on some versions).
    tr -d '\r' < "$PROFILE" |
      grep -vE '^[[:space:]]*(remote|remote-random-hostname|auth-user-pass|auth-federate|auth-retry)([[:space:]]|$)'
  } > vpn.conf
  chmod 600 vpn.conf

  grep -q 'BEGIN CERTIFICATE' vpn.conf || warn "vpn.conf has no inline CA chain -- check the profile"

  cat > vpn.env <<EOF
# Generated by setup.sh from $(basename "$PROFILE") on $(date -I)
VPN_HOST="$VPN_HOST"
PORT=$PORT
PROTO=$PROTO
EOF
  chmod 600 vpn.env
  info "wrote vpn.conf and vpn.env"
  CONFIG_CHANGED=1
else
  CONFIG_CHANGED=0
  [ -f vpn.conf ] && [ -f vpn.env ] ||
    die "vpn.conf/vpn.env missing -- pass your downloaded .ovpn profile: ./setup.sh <profile.ovpn>"
fi

# --------------------------------------------------------------- 3. build ----

# One line describing what ./openvpn was built from: written after a build and
# read back to decide whether the next run needs one.
stamp_want() {
  printf 'openvpn=%s patch=%s\n' "$VER" "$(sha256sum "$HERE/$PATCH" | awk '{print $1}')"
}

# Is ./openvpn current? Prints why not, when not.
openvpn_is_current() {
  [ -f "$HERE/$PATCH" ] || { echo "missing $PATCH"; return 1; }
  [ -x "$BIN" ]         || { echo "./openvpn is not built yet"; return 1; }
  [ "$(cat "$STAMP" 2>/dev/null || true)" = "$(stamp_want)" ] || {
    echo "./openvpn is stale (version or patch changed)"; return 1; }
  # Linked against this machine's OpenSSL/lzo, so a copied-in binary or one from
  # before a system upgrade can fail to run even with a matching stamp.
  "$BIN" --version >/dev/null 2>&1 || {
    echo "./openvpn does not run here (rebuilt against different system libs?)"; return 1; }
  return 0
}

build_openvpn() {
  [ -f "$PATCH" ] || die "missing $PATCH"

  [ -f "openvpn-${VER}.tar.gz" ] || \
    curl -fsSL -o "openvpn-${VER}.tar.gz" \
      "https://swupdate.openvpn.org/community/releases/openvpn-${VER}.tar.gz"

  rm -rf "openvpn-${VER}"
  tar xzf "openvpn-${VER}.tar.gz"

  (
    cd "openvpn-${VER}"

    # AWS SAML patch: enlarges buffers so the multi-KB SAMLResponse fits in the
    # username/password field (stock openvpn truncates it).
    patch -p1 < "$HERE/$PATCH"

    # --disable-dco: Ubuntu 26.04 ships in-kernel ovpn uapi headers that collide
    # with openvpn 2.6.12's vendored copies; we don't need kernel offload here.
    ./configure \
      --with-crypto-library=openssl \
      --disable-lz4 --disable-pkcs11 --disable-plugins \
      --enable-management --disable-dco

    make -j"$(nproc)"
    cp src/openvpn/openvpn "$BIN"
  )

  stamp_want > "$STAMP"
  info "built $BIN"
  info "$("$BIN" --version | head -1)"
}

step "Building patched openvpn $VER"

if [ "$FORCE_REBUILD" -eq 1 ]; then
  info "--rebuild given, rebuilding"
  BUILT=1
elif REASON="$(openvpn_is_current)"; then
  info "./openvpn is already current -- skipping ($("$BIN" --version | head -1))"
  BUILT=0
else
  [ -n "$REASON" ] && info "$REASON" || true
  BUILT=1
fi

# Plain `if`: `[ ... ] && build_openvpn || true` would swallow a build failure
# and cheerfully print "Setup complete".
if [ "$BUILT" -eq 1 ]; then
  build_openvpn
fi

# ---------------------------------------------------- 4. passwordless sudo ----
if [ "$DO_NOPASSWD" -eq 1 ]; then
  step "Passwordless activation"
  if [ -d /usr/local/lib/aws-vpn ]; then
    if [ "$BUILT" -eq 1 ] || [ "$CONFIG_CHANGED" -eq 1 ]; then
      info "already installed, refreshing the root-owned copies"
      sudo ./install-nopasswd.sh
    else
      info "already installed and up to date"
    fi
  else
    info "Installs root-owned copies under /usr/local/lib/aws-vpn and a sudoers"
    info "rule letting only you run vpn-phase2.sh without a password."
    if ask "Set that up now?"; then
      sudo ./install-nopasswd.sh
    else
      info "skipped -- aws-connect.sh will prompt for your sudo password instead"
    fi
  fi
fi

# ---------------------------------------------------------------- summary ----
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
cat <<EOF

$(printf '\033[1m==> Setup complete.\033[0m')

To connect, from your laptop:

    ssh -L 35001:localhost:35001 ${USER}@${IP:-<this-box>}

then on this box (inside tmux, so the tunnel outlives the SSH session):

    tmux new -s vpn
    ./aws-connect.sh

and open http://localhost:35001 in your laptop browser to authenticate.
EOF
