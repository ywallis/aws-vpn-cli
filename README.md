# aws-vpn-cli (headless)

Connect a headless box to an AWS Client VPN endpoint that uses **SAML**
authentication. The official AWS VPN Client is GUI-only and needs a local
browser; this uses open-source OpenVPN plus a small patch instead, and completes
the SAML step through an SSH-forwarded callback so no browser is needed *on the
box*.

Derived from [samm-git/aws-vpn-client](https://github.com/samm-git/aws-vpn-client)
(MIT — see `LICENSE`). The Go callback server is replaced by a Python one, and
the connect script is adapted for headless use.

## Contents

| File | Purpose |
|------|---------|
| `build.sh` | Build the patched OpenVPN 2.6.12 binary → `./openvpn` |
| `openvpn-v2.6.12-aws.patch` | Buffer-size patch so the multi-KB SAMLResponse isn't truncated |
| `saml_server.py` | Listens on `127.0.0.1:35001`: `GET /` redirects to the IdP, then captures the POSTed `SAMLResponse` |
| `aws-connect.sh` | Connect wrapper: fetch SAML URL → wait for auth → bring up tunnel |
| `vpn-updown.sh` | openvpn up/down hook: apply pushed DNS to systemd-resolved, revert on disconnect |
| `vpn-phase2.sh` | Root-side connect step, argument-validated; target of the optional NOPASSWD rule |
| `install-nopasswd.sh` | One-time sudo installer for passwordless activation (see below) |
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
3. In your **laptop** browser, open <http://localhost:35001> — the listener
   302-redirects to your IdP's sign-in page, so this address is bookmarkable
   and never changes. (The one-time SAML URL is also printed, and copied to
   your laptop clipboard when your terminal supports OSC 52 — see below.)
   After you authenticate, the IdP redirect returns to `127.0.0.1:35001`
   (tunneled to the box) and the script finishes bringing up the tunnel. It
   holds the foreground; `Ctrl-C` disconnects.

### Clipboard over SSH (OSC 52)

The script emits the SAML URL as an OSC 52 escape sequence, which most modern
terminals (iTerm2, kitty, WezTerm, Alacritty, Ghostty, Windows Terminal, foot)
translate into a write to the **local** clipboard — it works across SSH because
it is just terminal output. Unsupported terminals ignore it silently.

Inside tmux the script uses `tmux load-buffer -w` (tmux ≥ 3.2) instead, which
both fills tmux's paste buffer and asks the outer terminal to set the
clipboard. If the clipboard doesn't update, check the outer terminal supports
OSC 52 (some, like older GNOME Terminal, don't) — the tmux paste buffer
(`prefix ]`) still has the URL either way.

`aws-connect.sh` runs the final `openvpn` with `sudo` (needed to create the tun
device and routes). By default that prompts for your password; see the next
section to make it passwordless.

## Passwordless activation (optional)

To connect without typing a sudo password — without loosening anything
machine-wide — install a root-owned copy of the privileged pieces plus a
sudoers rule scoped to exactly one script:

```sh
sudo ./install-nopasswd.sh
```

This creates two things, and nothing else:

- `/usr/local/lib/aws-vpn/` — root-owned copies of `openvpn`, `vpn.conf`,
  `vpn-updown.sh` and `vpn-phase2.sh`. Because your user can't modify these,
  the passwordless rule can't be leveraged to run arbitrary code as root.
- `/etc/sudoers.d/aws-vpn` — allows *your user only* to run
  `/usr/local/lib/aws-vpn/vpn-phase2.sh` (and nothing else) via sudo without a
  password. `vpn-phase2.sh` validates its few runtime arguments (server IP,
  port, proto, auth file) before exec'ing the installed openvpn.

`aws-connect.sh` automatically uses the installed helper when the rule is
present, and falls back to plain `sudo` (with password prompt) when it isn't.

Because the *installed* copies are what run, re-run `sudo ./install-nopasswd.sh`
after rebuilding `openvpn` or editing `vpn.conf`. To undo everything:

```sh
sudo ./install-nopasswd.sh --uninstall
```

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
