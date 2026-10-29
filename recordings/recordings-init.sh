#!/command/with-contenv bash
# Cont-init for the openhost-jitsi recordings sidecar. Runs as root
# after 00-openhost-config and before the upstream web config oneshot
# (web-config) renders nginx's config. We:
#   1. Render an s6 run script for the sidecar with the resolved
#      data dir baked in.
#   2. Drop our nginx fragment into /run/web/config/nginx-custom/,
#      which upstream's meet.conf includes (since stable-10008).
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
# Resolve the public hostname. 00-openhost-config.sh exports
# OPENHOST_PUBLIC_HOSTNAME via /run/s6/container_environment, so
# `with-contenv bash` makes it available as a shell variable.  Fall
# back to the cached file if the env var didn't propagate (e.g. on
# very-first boot where the discovery dance is still in progress).
HOST="${OPENHOST_PUBLIC_HOSTNAME:-}"
if [[ -z "$HOST" && -r "$APP_DATA/hostname" ]]; then
    HOST="$(cat "$APP_DATA/hostname" 2>/dev/null || true)"
fi
ORIGIN_HINT=""
if [[ -n "$HOST" ]]; then
    ORIGIN_HINT="https://$HOST"
fi

mkdir -p /etc/services.d/recordings
cat > /etc/services.d/recordings/run <<EOF
#!/command/with-contenv bash
exec python3 /opt/openhost-recordings/server.py \\
    --rec-dir "$REC_DIR" \\
    --admin-token-file "$ADMIN_TOKEN_FILE" \\
    --bind 127.0.0.1 \\
    --port 5060 \\
    --public-origin-hint "$ORIGIN_HINT"
EOF
chmod +x /etc/services.d/recordings/run

# Custom nginx fragment that proxies our two URL prefixes to the
# sidecar. The web-config oneshot (running as the s6 user) creates the
# rest of /run/web later, so the directories must be s6's.
install -d -o s6 -g s6 /run/web /run/web/config /run/web/config/nginx-custom
NGINX_FRAGMENT=/run/web/config/nginx-custom/openhost-recordings.conf
cat > "$NGINX_FRAGMENT" <<'EOF'
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
    # docker-jitsi-meet's nginx.conf).
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
}

# Admin endpoints under /_recordings/<token>/... The leading
# underscore prevents collision with Jitsi room names (Jitsi's URL
# room name generator only emits lowercase letters, so an
# underscore-prefixed path can never be a valid room).
location ^~ /_recordings/ {
    proxy_pass http://127.0.0.1:5060;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_buffering off;
    proxy_read_timeout 600s;
}
EOF

chmod 644 "$NGINX_FRAGMENT"

log "config written: $REC_DIR (data dir), $ADMIN_TOKEN_FILE (admin token)"

# Print the admin URL prominently in the logs for the operator.
# The token file is created by the sidecar on first start, so this
# may be empty on the very first boot — the sidecar logs it again
# right after creating it.
if [[ -s "$ADMIN_TOKEN_FILE" ]]; then
    TOKEN="$(cat "$ADMIN_TOKEN_FILE")"
    if [[ -n "$ORIGIN_HINT" ]]; then
        log "recordings listing URL: $ORIGIN_HINT/_recordings/$TOKEN/"
    else
        log "recordings listing URL: /_recordings/$TOKEN/  (relative to the jitsi origin)"
    fi
fi
