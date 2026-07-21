#!/usr/bin/env python3
"""Minimal SAML callback listener for AWS Client VPN (replaces server.go).

Listens on 127.0.0.1:35001, waits for the IdP to POST the SAMLResponse,
URL-encodes it and writes it to saml-response.txt (mode 0600), then exits.

The AWS VPN SAML flow always redirects to http://127.0.0.1:35001/ with the
assertion in a POST form field named "SAMLResponse".
"""
import os
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

OUT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "saml-response.txt")
HOST, PORT = "127.0.0.1", 35001


class SAMLHandler(BaseHTTPRequestHandler):
    def _reply(self, code, msg):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(msg.encode())

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", "replace")
        fields = urllib.parse.parse_qs(body)
        saml = fields.get("SAMLResponse", [""])[0]
        if not saml:
            self._reply(400, "SAMLResponse field is empty or missing\n")
            print("POST received but no SAMLResponse field", file=sys.stderr)
            return
        # openvpn expects the value URL-encoded, matching server.go's url.QueryEscape
        encoded = urllib.parse.quote(saml, safe="")
        fd = os.open(OUT_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(encoded)
        self._reply(200, "Got SAMLResponse. You can close this window and return to the terminal.\n")
        print("Saved SAMLResponse to %s (%d bytes encoded)" % (OUT_FILE, len(encoded)), file=sys.stderr)
        self.server._got_response = True

    def do_GET(self):
        self._reply(405, "POST expected (this is the AWS VPN SAML callback listener)\n")

    def log_message(self, *args):
        pass  # keep the terminal quiet


def main():
    httpd = HTTPServer((HOST, PORT), SAMLHandler)
    httpd._got_response = False
    print("SAML listener ready on http://%s:%d" % (HOST, PORT), file=sys.stderr)
    while not httpd._got_response:
        httpd.handle_request()
    print("SAML response captured; listener shutting down.", file=sys.stderr)


if __name__ == "__main__":
    main()
