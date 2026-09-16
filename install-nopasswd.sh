#!/usr/bin/env bash
#
# One-time installer for passwordless VPN activation (run with sudo).
#
# Copies the openvpn binary, vpn.conf, vpn-updown.sh and vpn-phase2.sh into
# /usr/local/lib/aws-vpn/ (root-owned, so your user can't alter what runs as
# root) and adds a sudoers drop-in letting *your user only* run vpn-phase2.sh
# without a password. Nothing else on the machine changes.
#
#   sudo ./install-nopasswd.sh              # install / refresh
#   sudo ./install-nopasswd.sh --uninstall  # remove everything it added
#
# Re-run after rebuilding openvpn or editing vpn.conf — the installed copies
# are what actually run. ./setup.sh does this for you.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="/usr/local/lib/aws-vpn"
SUDOERS="/etc/sudoers.d/aws-vpn"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run with sudo" >&2; exit 1; }

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$SUDOERS"
  rm -rf "$DEST"
  echo ">> removed $SUDOERS and $DEST"
  exit 0
fi

# The sudoers rule is granted to the user who invoked sudo, not to root.
[ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] || {
  echo "ERROR: run via sudo from your normal user account (SUDO_USER not set)" >&2
  exit 1
}

[ -x "$HERE/openvpn" ]  || { echo "ERROR: $HERE/openvpn missing — run ./setup.sh first" >&2; exit 1; }
[ -f "$HERE/vpn.conf" ] || { echo "ERROR: $HERE/vpn.conf missing — copy vpn.conf.example first" >&2; exit 1; }

install -d -o root -g root -m 755 "$DEST"
install -o root -g root -m 755 "$HERE/openvpn"       "$DEST/openvpn"
install -o root -g root -m 755 "$HERE/vpn-phase2.sh" "$DEST/vpn-phase2.sh"
install -o root -g root -m 755 "$HERE/vpn-updown.sh" "$DEST/vpn-updown.sh"
install -o root -g root -m 600 "$HERE/vpn.conf"      "$DEST/vpn.conf"

# Validate the sudoers rule before installing it — a syntax error in
# /etc/sudoers.d can lock sudo entirely.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
printf '%s ALL=(root) NOPASSWD: %s\n' "$SUDO_USER" "$DEST/vpn-phase2.sh" > "$TMP"
visudo -cf "$TMP" >/dev/null
install -o root -g root -m 440 "$TMP" "$SUDOERS"

echo ">> installed $DEST (root-owned copies) and $SUDOERS"
echo ">> $SUDO_USER can now run ./aws-connect.sh without a sudo password"
