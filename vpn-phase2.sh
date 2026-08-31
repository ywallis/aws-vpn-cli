#!/usr/bin/env bash
#
# Root-side phase 2 of aws-connect.sh: bring up the tunnel.
#
# Installed to /usr/local/lib/aws-vpn/ (root-owned) by install-nopasswd.sh so
# that a NOPASSWD sudoers rule can target it without granting general root:
# every privileged input (openvpn binary, vpn.conf, up/down hook) is the
# root-owned installed copy, and the caller only supplies runtime values,
# validated below.
#
# Usage: vpn-phase2.sh <server-ip> <port> <udp|tcp> <auth-file>
set -euo pipefail

DIR="/usr/local/lib/aws-vpn"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (via sudo)" >&2; exit 1; }
[ $# -eq 4 ] || { echo "usage: $0 <server-ip> <port> <udp|tcp> <auth-file>" >&2; exit 1; }

SRV="$1" PORT="$2" PROTO="$3" AUTH_FILE="$4"

[[ "$SRV"   =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "ERROR: bad server ip: $SRV" >&2; exit 1; }
[[ "$PORT"  =~ ^[0-9]{1,5}$ ]]                  || { echo "ERROR: bad port: $PORT" >&2; exit 1; }
[[ "$PROTO" =~ ^(udp|tcp)$ ]]                   || { echo "ERROR: bad proto: $PROTO" >&2; exit 1; }
[ -f "$AUTH_FILE" ] || { echo "ERROR: auth file not found: $AUTH_FILE" >&2; exit 1; }
# The auth file must belong to the invoking user, so this rule can't be used
# to feed openvpn a file the caller couldn't read themselves.
[ "$(stat -c %u "$AUTH_FILE")" = "${SUDO_UID:-0}" ] || {
  echo "ERROR: auth file not owned by invoking user" >&2; exit 1
}

exec "$DIR/openvpn" --config "$DIR/vpn.conf" --verb 3 \
  --auth-nocache --inactive 3600 \
  --proto "$PROTO" --remote "$SRV" "$PORT" \
  --script-security 2 \
  --up "$DIR/vpn-updown.sh" --down "$DIR/vpn-updown.sh" --down-pre \
  --auth-user-pass "$AUTH_FILE"
