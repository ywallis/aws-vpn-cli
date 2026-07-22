#!/usr/bin/env bash
#
# OpenVPN --up/--down hook: apply the pushed DNS server to systemd-resolved.
# Called by openvpn (as root) for both events; it sets $script_type and $dev,
# and exposes pushed options as $foreign_option_1, $foreign_option_2, ...
#
# "Route all DNS via VPN": while connected, tun0 becomes the catch-all DNS
# route (~.), so every lookup goes to the internal resolver. On disconnect
# the interface config is reverted.
#
set -u
dev="${dev:-tun0}"

case "${script_type:-}" in
  up)
    dns=()
    i=1
    while true; do
      var="foreign_option_${i}"
      val="${!var:-}"
      [ -n "$val" ] || break
      case "$val" in
        "dhcp-option DNS "*)     dns+=("${val#dhcp-option DNS }") ;;
        "dhcp-option DNS6 "*)    dns+=("${val#dhcp-option DNS6 }") ;;
      esac
      i=$((i+1))
    done
    if [ "${#dns[@]}" -gt 0 ] && command -v resolvectl >/dev/null; then
      resolvectl dns "$dev" "${dns[@]}"
      resolvectl domain "$dev" "~."          # send ALL queries here while up
      resolvectl default-route "$dev" true
      echo "vpn-updown: set DNS on $dev -> ${dns[*]} (routing all queries)"
    else
      echo "vpn-updown: no pushed DNS found (or resolvectl missing); leaving resolver unchanged" >&2
    fi
    ;;
  down)
    command -v resolvectl >/dev/null && resolvectl revert "$dev" 2>/dev/null || true
    echo "vpn-updown: reverted DNS on $dev"
    ;;
esac
exit 0
