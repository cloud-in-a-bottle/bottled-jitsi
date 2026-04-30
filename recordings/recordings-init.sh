#!/usr/bin/with-contenv bash
# Cont-init for the openhost-jitsi recordings sidecar.
#
# Runs after the upstream web cont-init (13-web-config). By that
# point /config/web/nginx-custom/ is the directory that the
# already-rendered meet.conf includes via
#     include /config/web/nginx-custom/*.conf;
# (the openhost patches rewrite the upstream /config/nginx-custom
# path to /config/web/nginx-custom). We drop our recordings nginx
# fragment there before nginx itself starts.
#
# Idempotent: safe to re-run on every container boot.

set -eu

log() { echo "[recordings-init] $*" >&2; }

APP_DATA="${OPENHOST_APP_DATA_DIR:-/data/app_data/jitsi}"
REC_DIR="$APP_DATA/recordings"
ADMIN_TOKEN_FILE="$APP_DATA/recordings_admin_token"

mkdir -p "$REC_DIR"
chmod 700 "$REC_DIR"

# Render the s6 run script for the sidecar with the resolved data
# path baked in. We do this from cont-init rather than ship a static
# run script because $OPENHOST_APP_DATA_DIR isn't known at image
# build time.
HOST=""
if [[ -f "$APP_DATA/hostname" ]]; then
    HOST="$(cat "$APP_DATA/hostname")"
fi
ORIGIN_HINT=""
if [[ -n "$HOST" ]]; then
    ORIGIN_HINT="https://$HOST"
fi

mkdir -p /etc/services.d/recordings
cat > /etc/services.d/recordings/run <<EOF
#!/usr/bin/with-contenv bash
exec python3 /opt/openhost-recordings/server.py \\
    --rec-dir "$REC_DIR" \\
    --admin-token-file "$ADMIN_TOKEN_FILE" \\
    --bind 127.0.0.1 \\
    --port 5060 \\
    --public-origin-hint "$ORIGIN_HINT"
EOF
chmod +x /etc/services.d/recordings/run

# Custom nginx fragment that proxies our two URL prefixes to the
# sidecar. stable-9955's meet.conf does NOT have an
# `include /config/nginx-custom/*.conf` directive (it's a more
# recent upstream addition), so we both write the fragment and
# inject the include into the rendered meet.conf.
mkdir -p /config/web/nginx-custom
cat > /config/web/nginx-custom/openhost-recordings.conf <<'EOF'
# Proxy /api/recordings/{init,<id>/chunk,<id>/finalize} and the
# admin-token-rooted /<token>/ listing pages to the recordings
# sidecar on 127.0.0.1:5060.

# Anonymous upload endpoints. POST-only at the application level;
# nginx allows any method through and the sidecar 404s the rest.
# Use a broad prefix match — the sidecar enforces the exact route
# regex internally, so over-routing here is harmless.
location ^~ /api/recordings/ {
    proxy_pass http://127.0.0.1:5060;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_request_buffering off;
    proxy_buffering off;
    # The 5 MiB chunks the JS shim sends are well under nginx's
    # global client_max_body_size 0 (which means "unlimited" in
    # docker-jitsi-meet's meet.conf).
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
}

# Admin endpoints rooted at /<admin_token>/. The sidecar enforces
# the token equality check internally; we proxy any single-segment
# prefix path so the listing URL works.  The matching room-name
# location below this in meet.conf would otherwise swallow it.
#
# We can't easily filter by token value at the nginx layer (it
# changes per deploy), so we proxy everything here that:
#   * has at least 24 chars in the first segment (admin token is
#     32 base64 chars; jitsi room names tend to be shorter and
#     contain user-friendly words), AND
#   * looks like base64-url
# False positives just hit the sidecar's 404 path; false negatives
# (legitimate admin URLs that don't match the heuristic) would be
# routed to jitsi as a room name. To avoid that: don't pick a room
# name longer than 23 chars OR matching ^[A-Za-z0-9_-]{24,}$.
location ~ ^/[A-Za-z0-9_-]{24,}/?$ {
    proxy_pass http://127.0.0.1:5060;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $remote_addr;
}

location ~ ^/[A-Za-z0-9_-]{24,}/recording/[a-f0-9]{16}$ {
    proxy_pass http://127.0.0.1:5060;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_buffering off;
    proxy_read_timeout 600s;
}
EOF

# Inject the include directive into the rendered meet.conf if it's
# not already there. The include must be inside the server { ... }
# block; we anchor on the `client_max_body_size 0;` line near the
# top, which has appeared in every meet.conf revision since at least
# stable-8252.
MEET_CONF=/config/web/nginx/meet.conf
if [[ -f "$MEET_CONF" ]] && ! grep -q "/config/web/nginx-custom" "$MEET_CONF"; then
    python3 - "$MEET_CONF" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text()
needle = "client_max_body_size 0;"
if needle in text:
    inj = "include /config/web/nginx-custom/*.conf;"
    text = text.replace(needle, needle + "\n\n" + inj, 1)
    p.write_text(text)
    print("[recordings-init] injected nginx-custom include into meet.conf", file=sys.stderr)
else:
    print("[recordings-init] WARNING: could not inject include — anchor missing", file=sys.stderr)
PY
fi

log "config written: $REC_DIR (data dir), $ADMIN_TOKEN_FILE (admin token)"

# Print the admin URL prominently in the logs for the operator.
# The token file is created by the sidecar on first start, so this
# may be empty on the very first boot — the sidecar logs it again
# right after creating it.
if [[ -s "$ADMIN_TOKEN_FILE" ]]; then
    TOKEN="$(cat "$ADMIN_TOKEN_FILE")"
    if [[ -n "$ORIGIN_HINT" ]]; then
        log "recordings listing URL: $ORIGIN_HINT/$TOKEN/"
    else
        log "recordings listing URL: /$TOKEN/  (relative to the jitsi origin)"
    fi
fi
