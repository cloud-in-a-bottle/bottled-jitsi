#!/usr/bin/env python3
"""First-boot hostname discovery helper.

Runs a one-shot HTTP server on port 80 until the first incoming
request gives us an X-Forwarded-Host (the header OpenHost's router
sets with the public hostname the browser used). We write that value
to the cache file argv[1] and exit, at which point the rest of
cont-init continues and nginx takes over port 80.
"""

from __future__ import annotations

import http.server
import socketserver
import sys
from pathlib import Path


BIND_PORT = 80
HTML = b"""<!DOCTYPE html>
<html><head><meta http-equiv=\"refresh\" content=\"5\"><title>Jitsi starting</title></head>
<body style=\"background:#0f1115;color:#e6e9ef;font-family:system-ui;padding:40px;text-align:center\">
<h1>Starting Jitsi Meet...</h1>
<p>First-boot bootstrap in progress. This page will reload automatically.</p>
</body></html>
"""


class _Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args, **_kw):  # type: ignore[override]
        pass

    def do_GET(self):  # noqa: N802
        host = (
            self.headers.get("X-Forwarded-Host")
            or self.headers.get("Host")
            or ""
        )
        host = host.split(":")[0].strip()
        if host and host not in ("localhost", "127.0.0.1"):
            Path(self._cache_path).write_text(host + "\n")
            self.server.captured = True  # type: ignore[attr-defined]
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(HTML)))
        self.end_headers()
        self.wfile.write(HTML)


class _OneShotServer(socketserver.TCPServer):
    allow_reuse_address = True
    captured = False


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: discover_hostname.py <cache-file>", file=sys.stderr)
        return 2
    handler = type("_H", (_Handler,), {"_cache_path": sys.argv[1]})
    server = _OneShotServer(("0.0.0.0", BIND_PORT), handler)
    try:
        while not server.captured:
            server.handle_request()
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
