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

cleanup() {
  [ -n "${LPID:-}" ] && kill "$LPID" 2>/dev/null || true
  [ -n "${AUTH_FILE:-}" ] && rm -f "$AUTH_FILE" || true
}
trap cleanup EXIT

rm -f "$SAML_FILE"

# AWS keeps a session pinned to one gateway IP, so resolve a random-prefixed
# hostname once and reuse that exact IP for both phases.
RAND="$(openssl rand -hex 12)"
SRV="$(dig +short A "${RAND}.${VPN_HOST}" | grep -E '^[0-9.]+$' | head -n1)"
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
