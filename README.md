# aws-vpn-client (headless)

Connect a headless box to an AWS Client VPN endpoint that uses **SAML**
authentication. The official AWS VPN Client is GUI-only and needs a local
browser; this uses open-source OpenVPN plus a small patch instead, and completes
the SAML step through an SSH-forwarded callback so no browser is needed *on the
box*.

Derived from [samm-git/aws-vpn-client](https://github.com/samm-git/aws-vpn-client)
(see `README.upstream.md` and `LICENSE`). The Go callback server is replaced by
a Python one, and the connect script is adapted for headless use.

## Contents

| File | Purpose |
|------|---------|
| `build.sh` | Build the patched OpenVPN 2.6.12 binary → `./openvpn` |
| `openvpn-v2.6.12-aws.patch` | Buffer-size patch so the multi-KB SAMLResponse isn't truncated |
| `saml_server.py` | Listens on `127.0.0.1:35001`, captures the POSTed `SAMLResponse` |
| `aws-connect.sh` | Connect wrapper: fetch SAML URL → wait for auth → bring up tunnel |
| `vpn.conf.example` | Template for `vpn.conf` (endpoint CA chain + `verify-x509-name`) |
| `vpn.env.example` | Template for `vpn.env` (endpoint host / port / proto) |

Endpoint-specific files (`vpn.conf`, `vpn.env`) and the machine-specific
`openvpn` binary are **not** committed — copy the `.example` files and run
`./build.sh`.

## Setup

```sh
# 1. build the patched openvpn (one time)
sudo apt-get install -y build-essential pkg-config \
  libssl-dev liblzo2-dev liblz4-dev libpam0g-dev
./build.sh

# 2. provide your endpoint
cp vpn.env.example  vpn.env      # set VPN_HOST / PORT / PROTO
cp vpn.conf.example vpn.conf     # paste your endpoint's CA chain + x509 name
```

`vpn.conf` is derived from your AWS `.ovpn` profile, dropping the lines the
wrapper handles on the CLI:

```sh
grep -vE '^(remote |remote-random-hostname|auth-user-pass|auth-federate|auth-retry )' \
    downloaded-client-config.ovpn > vpn.conf
```

Notes for Ubuntu 26.04 / OpenSSL 3.5: build with `--disable-dco` (in-kernel
`ovpn` headers collide with the vendored ones) — handled in `build.sh`. The
OpenSSL self-signed-cert patch shipped upstream is **not** needed here; the AWS
cert chain verifies fine against OpenSSL 3.5.

## Connect

1. From your laptop, forward the SAML callback port:
   ```sh
   ssh -L 35001:localhost:35001 <user>@<this-box>
   ```
2. On the box:
   ```sh
   ./aws-connect.sh
   ```
3. Open the printed URL in your **laptop** browser and authenticate. The IdP
   redirect returns to `127.0.0.1:35001` (tunneled to the box) and the script
   finishes bringing up the tunnel. It holds the foreground; `Ctrl-C` disconnects.

`aws-connect.sh` runs the final `openvpn` with `sudo` (needed to create the tun
device and routes).

## Keeping it running (tmux)

`openvpn` runs in the foreground, so it dies when its SSH session closes. The
`-L` forward is only needed for the login moment, but the `openvpn` *process*
must outlive your SSH session. Run it inside a tmux session **on the box** (a
tmux on your laptop would not help — the remote process is still tied to the
SSH session):

```sh
# from your laptop, SSH in WITH the callback forward:
ssh -L 35001:localhost:35001 <user>@<this-box>

# on the box:
tmux new -s vpn
./aws-connect.sh
# authenticate in your laptop browser; wait for "Initialization Sequence Completed"
# then detach:  Ctrl-b  d
```

The tmux server on the box is a daemon with no controlling terminal, so
`openvpn` survives once detached. You can now drop the `-L` forward and close
SSH — the VPN stays up. To manage it later:

```sh
tmux attach -t vpn        # view status; Ctrl-C inside disconnects the VPN
tmux kill-session -t vpn  # disconnect and tear down
```

Note: SAML requires interactive auth on every connect (the assertion is
single-use), so this is start-on-demand — there is no unattended auto-connect
or auto-reconnect.
