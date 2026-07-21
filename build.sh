#!/usr/bin/env bash
#
# Build the AWS-compatible (patched) OpenVPN binary used by aws-connect.sh.
# Produces ./openvpn in this directory.
#
# One-time build deps (Ubuntu/Debian):
#   sudo apt-get install -y build-essential pkg-config \
#     libssl-dev liblzo2-dev liblz4-dev libpam0g-dev
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

VER="${OPENVPN_VERSION:-2.6.12}"
PATCH="openvpn-v${VER}-aws.patch"
[ -f "$PATCH" ] || { echo "missing $PATCH" >&2; exit 1; }

[ -f "openvpn-${VER}.tar.gz" ] || \
  curl -fsSL -o "openvpn-${VER}.tar.gz" \
    "https://swupdate.openvpn.org/community/releases/openvpn-${VER}.tar.gz"

rm -rf "openvpn-${VER}"
tar xzf "openvpn-${VER}.tar.gz"
cd "openvpn-${VER}"

# AWS SAML patch: enlarges buffers so the multi-KB SAMLResponse fits in the
# username/password field (stock openvpn truncates it).
patch -p1 < "../${PATCH}"

# --disable-dco: Ubuntu 26.04 ships in-kernel ovpn uapi headers that collide
# with openvpn 2.6.12's vendored copies; we don't need kernel offload here.
./configure \
  --with-crypto-library=openssl \
  --disable-lz4 --disable-pkcs11 --disable-plugins \
  --enable-management --disable-dco

make -j"$(nproc)"
cp src/openvpn/openvpn "../openvpn"
echo ">> built $(cd .. && pwd)/openvpn"
"../openvpn" --version | head -1
