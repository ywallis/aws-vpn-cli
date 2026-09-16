#!/usr/bin/env bash
#
# Headless AWS Client VPN connect (SAML) for this box.
#   Phase 1: run patched openvpn to obtain the SAML redirect URL (no root).
#   You:     open that URL in your laptop browser (via `ssh -L 35001:localhost:35001`).
#   Phase 2: openvpn reconnects with the captured SAML assertion (needs sudo).
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# Endpoint settings are kept out of version control. Copy vpn.env.example to
# vpn.env and set your endpoint there.
ENV_FILE="$HERE/vpn.env"
[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found (copy vpn.env.example -> vpn.env)" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${VPN_HOST:?set VPN_HOST in vpn.env}"
PORT="${PORT:-443}"
PROTO="${PROTO:-udp}"
OVPN_BIN="$HERE/openvpn"
OVPN_CONF="$HERE/vpn.conf"
SAML_FILE="$HERE/saml-response.txt"
LISTENER="$HERE/saml_server.py"

wait_file() {
  local f="$1" secs="${2:-60}"
  until [ "$secs" -eq 0 ] || [ -f "$f" ]; do sleep 1; secs=$((secs-1)); done
  [ -f "$f" ]
}

# Best-effort copy to the LAPTOP clipboard. Inside tmux, load-buffer -w has
# tmux forward it to the outer terminal (tmux >= 3.2); otherwise emit OSC 52
# straight to the tty. Either way the terminal on the laptop end must support
# OSC 52 — if it doesn't, this is a silent no-op.
copy_to_clipboard() {
  if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    printf '%s' "$1" | tmux load-buffer -w - 2>/dev/null || true
  elif [ -t 1 ] || [ -w /dev/tty ]; then
    printf '\033]52;c;%s\007' "$(printf '%s' "$1" | base64 -w0)" > /dev/tty 2>/dev/null || true
  fi
}

# Resolve an A record without requiring dig: bind9-dnsutils isn't installed on
# Ubuntu Server/cloud images, and getent is part of libc so it's always there.
resolve_a() {
  local name="$1" ip=""
  if command -v dig >/dev/null 2>&1; then
    ip="$(dig +short A "$name" | grep -E '^[0-9.]+$' | head -n1)"
  fi
  [ -n "$ip" ] || ip="$(getent ahostsv4 "$name" | awk '{print $1; exit}')"
  printf '%s' "$ip"
}

cleanup() {
  [ -n "${LPID:-}" ] && kill "$LPID" 2>/dev/null || true
  [ -n "${AUTH_FILE:-}" ] && rm -f "$AUTH_FILE" || true
}
trap cleanup EXIT

rm -f "$SAML_FILE"
# The EXIT trap covers Ctrl-C and a closing SSH session, but not SIGKILL or a
# reboot while the tunnel is up -- and a missed cleanup leaves the captured SAML
# assertion in .auth.* on disk. Sweep what earlier runs orphaned, skipping any
# file a running process still names: openvpn keeps the path in its argv for the
# life of the connection, which can be days, so file age is not a safe proxy for
# "nobody is using this".
sweep_orphaned_auth_files() {
  local referenced f n=0
  referenced="$(cat /proc/[0-9]*/cmdline 2>/dev/null | tr '\0' '\n' | grep -F "$HERE/.auth." || true)"
  for f in "$HERE"/.auth.*; do
    [ -e "$f" ] || continue
    if ! printf '%s\n' "$referenced" | grep -qxF "$f"; then
      rm -f "$f" && n=$((n+1))
    fi
  done
  [ "$n" -eq 0 ] || echo ">> swept $n orphaned SAML assertion file(s)"
}
sweep_orphaned_auth_files

# AWS keeps a session pinned to one gateway IP, so resolve a random-prefixed
# hostname once and reuse that exact IP for both phases.
RAND="$(openssl rand -hex 12)"
SRV="$(resolve_a "${RAND}.${VPN_HOST}")"
[ -n "$SRV" ] || { echo "ERROR: could not resolve ${VPN_HOST}" >&2; exit 1; }
echo ">> endpoint ${VPN_HOST} -> ${SRV}:${PORT}/${PROTO}"

echo ">> Phase 1: requesting SAML redirect URL ..."
OVPN_OUT="$(
  "$OVPN_BIN" --config "$OVPN_CONF" --verb 3 \
    --proto "$PROTO" --remote "$SRV" "$PORT" \
    --auth-user-pass <(printf '%s\n%s\n' 'N/A' 'ACS::35001') \
    2>&1 | grep 'AUTH_FAILED,CRV1' || true
)"
[ -n "$OVPN_OUT" ] || { echo "ERROR: no SAML challenge received (see output above)" >&2; exit 1; }

# AUTH_FAILED,CRV1:R:<sid>:<state>:<url>  -- parse from the marker, not the
# log timestamp, so this doesn't break if openvpn's log prefix changes.
CRV="${OVPN_OUT#*AUTH_FAILED,CRV1:}"      # -> R:<sid>:<state>:https://...
VPN_SID="$(printf '%s' "$CRV" | cut -d: -f2)"
URL="$(printf '%s' "$OVPN_OUT" | grep -Eo 'https://[^[:space:]]+')"
[ -n "$URL" ] || { echo "ERROR: could not parse SAML URL" >&2; exit 1; }
[ -n "$VPN_SID" ] || { echo "ERROR: could not parse VPN session id" >&2; exit 1; }

# Start the callback listener BEFORE handing the user the URL. It also gets
# the URL so a GET on / redirects the laptop browser to the IdP.
python3 "$LISTENER" "$URL" &
LPID=$!
sleep 1

# If the port is taken, saml_server.py exits here with its own message and the
# 180s wait below would otherwise time out for no reason. kill -0 can succeed on
# a child that exited but hasn't been reaped, so ask /proc for the real state.
listener_alive() {
  case "$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)" in
    ""|Z) return 1 ;;
    *)    return 0 ;;
  esac
}
listener_alive "$LPID" || {
  echo "ERROR: SAML listener failed to start (see its message above)" >&2
  exit 1
}

copy_to_clipboard "$URL"

cat <<EOF

============================================================================
  Authenticate in your LAPTOP browser (SSH tunnel must be up:
    ssh -L 35001:localhost:35001 ${USER}@$(hostname -I | awk '{print $1}') )

  Easiest: open  http://localhost:35001  — it redirects to the IdP login.

  The full URL (also copied to your clipboard if your terminal supports
  OSC 52):

$URL

  After signing in, the browser redirects back to 127.0.0.1:35001 and this
  script continues automatically.
============================================================================

EOF

echo ">> waiting for SAML response (up to 180s) ..."
if ! wait_file "$SAML_FILE" 180; then
  echo "ERROR: timed out waiting for SAML response" >&2; exit 1
fi
echo ">> SAML response captured."

echo ">> Phase 2: connecting ..."
# Credentials go in a private temp file, NOT bash process substitution:
# sudo closes inherited file descriptors, so a <(...) /dev/fd path is gone
# before openvpn reads it. A file also keeps the SAML assertion out of argv.
AUTH_FILE="$(mktemp "$HERE/.auth.XXXXXX")"
chmod 600 "$AUTH_FILE"
printf '%s\n%s\n' 'N/A' "CRV1::${VPN_SID}::$(cat "$SAML_FILE")" > "$AUTH_FILE"
rm -f "$SAML_FILE"   # single-use assertion; already copied into AUTH_FILE

# Prefer the root-owned helper installed by install-nopasswd.sh: its sudoers
# rule is passwordless, so no prompt. Otherwise fall back to plain sudo.
PHASE2="/usr/local/lib/aws-vpn/vpn-phase2.sh"
if [ -x "$PHASE2" ] && sudo -n -l "$PHASE2" >/dev/null 2>&1; then
  sudo -n "$PHASE2" "$SRV" "$PORT" "$PROTO" "$AUTH_FILE"
else
  sudo "$OVPN_BIN" --config "$OVPN_CONF" --verb 3 \
    --auth-nocache --inactive 3600 \
    --proto "$PROTO" --remote "$SRV" "$PORT" \
    --script-security 2 \
    --up "$HERE/vpn-updown.sh" --down "$HERE/vpn-updown.sh" --down-pre \
    --auth-user-pass "$AUTH_FILE"
fi
