#!/usr/bin/env python3
"""First-boot hostname discovery helper.

When $PUBLIC_URL / $OPENHOST_PUBLIC_HOSTNAME are unset and we don't
have a cached hostname yet, this script runs a one-shot HTTP server
on port 80 that reads the first incoming request's X-Forwarded-Host
(or Host) header, writes the hostname to the path supplied as argv[1],
and exits.

Used by 10-configure-jitsi.sh before it rewrites the generated
prosody / jicofo / jvb / nginx configs with the real public hostname.
The port conflict with the real nginx is the whole point: nginx
starts *after* this script finishes (s6 sequences cont-init.d ->
legacy-services).

No third-party deps; everything is stdlib.
"""

from __future__ import annotations

import http.server
import socketserver
import sys
from pathlib import Path


BIND_PORT = 80
# Small HTML response so the waiting browser doesn't just see a blank
# page. The user refreshes after we've done our job and sees the real
# Jitsi UI.
HTML = b"""<!DOCTYPE html>
<html><head><meta http-equiv=\"refresh\" content=\"4\"><title>Jitsi starting</title></head>
<body style=\"background:#0f1115;color:#e6e9ef;font-family:system-ui;padding:40px;text-align:center\">
<h1>Jitsi is starting up...</h1>
<p>Bootstrapping XMPP + videobridge. This page will reload automatically.</p>
</body></html>
"""


class _Handler(http.server.BaseHTTPRequestHandler):
    # Suppress the default noisy access log.
    def log_message(self, *_args, **_kw):  # type: ignore[override]
        pass

    def do_GET(self):  # noqa: N802
        host = (
            self.headers.get("X-Forwarded-Host")
            or self.headers.get("Host")
            or ""
        )
        host = host.split(":")[0].strip()  # strip any :port
        if not host or host in ("localhost", "127.0.0.1"):
            # Uninteresting; tell the operator and keep listening so a
            # real external request can still arrive.
            self.send_response(503)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(HTML)
            return

        # Record it and serve the waiting page.
        out = Path(self._cache_path)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(host + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(HTML)))
        self.end_headers()
        self.wfile.write(HTML)
        # Flag the server to exit after this request.
        self.server.captured = True  # type: ignore[attr-defined]


class _OneShotServer(socketserver.TCPServer):
    allow_reuse_address = True
    captured = False


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: _discover_hostname.py <cache-file>", file=sys.stderr)
        return 2
    cache_file = sys.argv[1]

    # Bind attribute-style so the handler can write it.
    handler = type("_H", (_Handler,), {"_cache_path": cache_file})
    server = _OneShotServer(("0.0.0.0", BIND_PORT), handler)

    try:
        while not server.captured:
            server.handle_request()
    finally:
        server.server_close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
