#!/bin/bash
# Runtime configuration rewriter for Jitsi Meet.
#
# At build time we apt-installed the Jitsi stack with a placeholder
# hostname ("localhost") so debconf would run through non-interactively
# and the post-install scripts would generate working configs. At
# container boot the real hostname comes in via $PUBLIC_URL (set by the
# operator in openhost.toml env, or auto-derived from router headers
# on first request) and we rewrite the generated configs in-place.
#
# We also:
#   * point JVB at JVB_PORT (default 9500) and advertise the container
#     host's public address via ice4j harvest mapping, so WebRTC ICE
#     candidates the browser sees are actually reachable over UDP.
#   * disable nginx's HTTPS listener since OpenHost's Caddy already
#     handles TLS in front of us.
#   * mirror the persistent data directory into /etc/prosody/ so shared
#     secrets survive container restarts.

set -euo pipefail

log() { echo "[cont-init][jitsi] $*" >&2; }

APP_DATA="${OPENHOST_APP_DATA_DIR:-/data/app_data/jitsi}"
APP_TEMP="${OPENHOST_APP_TEMP_DIR:-/data/app_temp_data/jitsi}"
SECRETS_DIR="$APP_DATA/secrets"
PROSODY_DATA_DIR="$APP_DATA/prosody-data"

mkdir -p "$SECRETS_DIR" "$PROSODY_DATA_DIR" "$APP_TEMP"

# ---------------------------------------------------------------- hostname

# Resolve the public hostname the browser will use.
#
# Priority:
#   1. $PUBLIC_URL env var, if set (operator override).
#   2. $OPENHOST_PUBLIC_HOSTNAME env var (reserved for a future
#      OpenHost feature that injects this automatically).
#   3. Block until an HTTP client hits the container on port 80 and
#      tells us via X-Forwarded-Host. This lets us bootstrap without
#      requiring the operator to set any env vars.
#
# After resolving, we cache the value in $APP_DATA/hostname so
# subsequent restarts skip step 3.
CACHED_HOSTNAME_FILE="$APP_DATA/hostname"

resolve_hostname() {
    if [[ -n "${PUBLIC_URL:-}" ]]; then
        echo "$PUBLIC_URL" | sed -E 's#^https?://##; s#/.*$##'
        return
    fi
    if [[ -n "${OPENHOST_PUBLIC_HOSTNAME:-}" ]]; then
        echo "$OPENHOST_PUBLIC_HOSTNAME"
        return
    fi
    if [[ -f "$CACHED_HOSTNAME_FILE" ]]; then
        cat "$CACHED_HOSTNAME_FILE"
        return
    fi
    # Fall back to the discovery dance: run a one-shot python
    # listener on :80 that captures X-Forwarded-Host from the first
    # request and exits. Uses stdlib only (no nginx yet).
    log "no hostname set; waiting for first HTTP request to discover it" >&2
    python3 /usr/local/lib/jitsi/discover_hostname.py "$CACHED_HOSTNAME_FILE" >&2
    cat "$CACHED_HOSTNAME_FILE"
}

HOSTNAME="$(resolve_hostname)"
if [[ -z "$HOSTNAME" ]]; then
    log "FATAL: could not resolve public hostname"
    exit 1
fi
echo "$HOSTNAME" > "$CACHED_HOSTNAME_FILE"
PUBLIC_URL="${PUBLIC_URL:-https://$HOSTNAME}"
log "PUBLIC_URL=$PUBLIC_URL  -> hostname=$HOSTNAME"

# Replace every occurrence of the build-time placeholder ("localhost"
# or "meet.jitsi") with the real hostname in every generated config.
# We touch:
#   /etc/jitsi/meet/<host>-config.js
#   /etc/jitsi/videobridge/jvb.conf (handled below)
#   /etc/jitsi/jicofo/jicofo.conf (handled below)
#   /etc/prosody/conf.d/<host>.cfg.lua
#   /etc/nginx/sites-available/<host>.conf
#
# The Debian installer names the per-host files after whatever hostname
# was in debconf. Since we used "localhost", the files are prefixed
# "localhost.". Rename them in-place to the real hostname so nginx and
# prosody pick them up under the user's domain.

rename_host_file() {
    local src="$1" ext="$2" dst
    dst="$(echo "$src" | sed "s#/localhost$ext\$#/$HOSTNAME$ext#")"
    if [[ "$src" != "$dst" && -f "$src" ]]; then
        mv "$src" "$dst"
        log "renamed $(basename "$src") -> $(basename "$dst")"
    fi
}

# The build used PLACEHOLDER as the debconf hostname; cont-init
# swaps every occurrence (filenames + file contents) to the real
# PUBLIC_URL hostname. Keep this in sync with the Dockerfile's
# debconf-set-selections lines.
PLACEHOLDER="meet.invalid"

rename_placeholder() {
    local src="$1"
    local dst="${src//$PLACEHOLDER/$HOSTNAME}"
    [[ "$src" == "$dst" ]] && return 0
    if [[ -L "$src" ]]; then
        # Redirect the symlink to point at the renamed target, then
        # move the link itself. Otherwise the link's target becomes
        # stale after the parent file is renamed.
        local target
        target="$(readlink "$src")"
        local new_target="${target//$PLACEHOLDER/$HOSTNAME}"
        ln -sfn "$new_target" "$src"
        mv "$src" "$dst"
        log "renamed symlink $(basename "$src") -> $(basename "$dst") (target $new_target)"
    elif [[ -e "$src" ]]; then
        mv "$src" "$dst"
        log "renamed $(basename "$src") -> $(basename "$dst")"
    fi
}

shopt -s nullglob
# Literal explicit paths first, then globbed sweeps. The globs catch
# auxiliary files the jitsi postinst creates (auth.*, *.cnf, extra
# copies under /etc/prosody/certs and /var/lib/prosody) that don't
# follow a single naming pattern.
for f in /etc/prosody/conf.d/$PLACEHOLDER.cfg.lua \
         /etc/prosody/conf.avail/$PLACEHOLDER.cfg.lua \
         /etc/nginx/sites-available/$PLACEHOLDER.conf \
         /etc/nginx/sites-enabled/$PLACEHOLDER.conf \
         /etc/jitsi/meet/$PLACEHOLDER-config.js \
         /etc/jitsi/meet/*$PLACEHOLDER* \
         /etc/prosody/certs/*$PLACEHOLDER* \
         /var/lib/prosody/*$PLACEHOLDER*; do
    rename_placeholder "$f"
done
shopt -u nullglob

# Rewrite every remaining literal PLACEHOLDER reference in configs
# the installer wrote. Scoped tightly so we don't accidentally rewrite
# unrelated files.
for f in \
    /etc/nginx/sites-available/"$HOSTNAME".conf \
    /etc/nginx/sites-enabled/"$HOSTNAME".conf \
    /etc/prosody/conf.d/"$HOSTNAME".cfg.lua \
    /etc/prosody/conf.avail/"$HOSTNAME".cfg.lua \
    /etc/jitsi/meet/"$HOSTNAME"-config.js \
    /etc/jitsi/videobridge/jvb.conf \
    /etc/jitsi/videobridge/sip-communicator.properties \
    /etc/jitsi/jicofo/jicofo.conf \
    /etc/jitsi/jicofo/sip-communicator.properties ; do
    [[ -f "$f" ]] || continue
    if grep -q "$PLACEHOLDER" "$f" 2>/dev/null; then
        sed -i "s/$PLACEHOLDER/$HOSTNAME/g" "$f"
        log "rewrote hostname in $f"
    fi
done

# ---------------------------------------------------------------- TLS off

# Disable the :443 listener in the generated nginx vhost. OpenHost's
# Caddy already terminates TLS in front of us, and the container has
# no real certs anyway. We could delete the whole `server { ... :443
# ... }` block, but finding the matching brace reliably is fragile
# given nginx's freeform syntax and the upstream template's layout.
# Instead, neuter the block's binding: comment out any lines that
# would bind to :443 or reference cert files. nginx will still parse
# the block but the `listen` directive will be gone, so it becomes a
# harmless catch-all that never gets traffic.
# Disable Debian's default "Welcome to nginx" vhost and the static
# welcome HTML. Both sites-enabled/default (the vhost) and the file
# at /usr/share/nginx/html/index.html contribute to nginx serving a
# welcome page when the wrong vhost is picked; nuke them both so any
# misrouting becomes a hard 404 rather than a misleading "success".
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default
rm -f /usr/share/nginx/html/index.html /usr/share/nginx/html/index.nginx-debian.html
rm -rf /var/www/html

NGINX_CONF="/etc/nginx/sites-available/$HOSTNAME.conf"
if [[ -f "$NGINX_CONF" ]]; then
    # We need to do two transforms on the jitsi-meet nginx template:
    #   1. Disable the :443 listener + all ssl_* directives. OpenHost's
    #      Caddy already terminates TLS upstream on real port 443; our
    #      container has no real certs.
    #   2. Disable the :80 -> :443 redirect. OpenHost speaks plain
    #      HTTP to us on port 80 (which it then wraps in TLS on the
    #      way out to the browser), so if the :80 server does a 301
    #      to https:// the outer client sees a redirect loop.
    #
    # After the python rewrite the :80 server{} block becomes a plain
    # vhost that serves the jitsi SPA + proxies BOSH / WS to prosody,
    # exactly what we want.
    NGINX_CONF="$NGINX_CONF" python3 <<'PY'
import pathlib, os, re
p = pathlib.Path(os.environ["NGINX_CONF"])
text = p.read_text()

# The jitsi-meet nginx template has two server blocks:
#   * :80 -- tiny, does acme-challenge + 301 redirect to https
#   * :443 -- all the real content (root, locations, BOSH, ws, etc)
#
# OpenHost terminates TLS in front of us and speaks plain HTTP on 80
# to the container, so we need the *real* :443 content on :80. We do
# two transforms:
#   1. Rewrite "listen 443 ..." to "listen 80 default_server ...".
#      default_server makes this vhost catch Host-less requests
#      (OpenHost's router strips Host: and passes X-Forwarded-Host).
#   2. Rewrite the original :80 block's listen directives to an
#      unused localhost port so it doesn't bind :80 and fight the
#      real vhost. Then comment out its '301 https' so even that
#      backchannel never redirects anything.
#   3. Comment out every ssl_* directive and listen 443 references
#      since we're not doing TLS in-container.

# Step 1: swap :443 -> :80 default_server (first matching block only).
text = re.sub(
    r"listen\s+443\s+ssl\s+http2\s*;",
    "listen 80 default_server;",
    text,
    count=1,
)
text = re.sub(
    r"listen\s+\[::\]:443\s+ssl\s+http2\s*;",
    "listen [::]:80 default_server;",
    text,
    count=1,
)

# Step 2: the *original* :80 block's listen directives now collide
# with the newly-80 block. Bind it to a dead localhost port instead.
text = text.replace("listen 80;", "listen 127.0.0.1:65443;", 1)
text = text.replace("listen [::]:80;", "listen [::1]:65444;", 1)

# Step 3: comment out any remaining TLS-specific directives.
out = []
for line in text.splitlines():
    stripped = line.lstrip()
    if stripped.startswith("ssl_certificate") \
       or stripped.startswith("ssl_certificate_key") \
       or stripped.startswith("ssl_trusted_certificate") \
       or stripped.startswith("ssl_dhparam") \
       or stripped.startswith("ssl_protocols") \
       or stripped.startswith("ssl_ciphers") \
       or stripped.startswith("ssl_prefer_server_ciphers") \
       or stripped.startswith("ssl_session_") \
       or stripped.startswith("return 301 https") \
       or (stripped.startswith("listen") and "443" in stripped):
        out.append("# " + line)
        continue
    out.append(line)
p.write_text("\n".join(out) + "\n")
PY
    log "neutered :443 listener + ssl_* directives + HTTPS redirect in nginx config"
fi

# Make sure prosody's HTTP port (for BOSH/XMPP-WS) is bound on 5280.
# jitsi's nginx vhost proxies /http-bind and /xmpp-websocket to
# prosody's HTTP listener on that port. Prosody 13 defaults to
# serving these on HTTPS-only; jitsi expects plain-HTTP on 5280.
VHOST_CFG="/etc/prosody/conf.avail/$HOSTNAME.cfg.lua"
if [[ -f "$VHOST_CFG" ]] && ! grep -q "^http_ports" "$VHOST_CFG"; then
    python3 <<PY
import pathlib
p = pathlib.Path("$VHOST_CFG")
text = p.read_text()
# Insert before the first VirtualHost so these settings are global.
inject = (
    'http_ports = { 5280 }\n'
    'https_ports = { }\n'
    'trusted_proxies = { "127.0.0.1", "::1" }\n\n'
)
import re
m = re.search(r'^VirtualHost\s', text, re.MULTILINE)
if m:
    text = text[:m.start()] + inject + text[m.start():]
else:
    text = inject + text
p.write_text(text)
PY
    log "set http_ports/https_ports/trusted_proxies in prosody vhost config"
fi

# Force prosody to log to stdout so s6 captures it. The log directive
# must live in the *global* section -- above any VirtualHost or
# Component -- or prosodyctl treats it as host-scoped and emits a
# warning. Insert before the first VirtualHost/Component/Include
# directive, or prepend to the top of the file if none exists.
PROSODY_MAIN_CFG="/etc/prosody/prosody.cfg.lua"
if ! grep -q -- "-- openhost-jitsi: stdout log" "$PROSODY_MAIN_CFG"; then
    python3 <<PY
import pathlib, re
p = pathlib.Path("$PROSODY_MAIN_CFG")
text = p.read_text()
inject = '\n-- openhost-jitsi: stdout log (so s6 captures prosody output)\nlog = { { to = "console"; levels = { min = "debug" } } }\n\n'
m = re.search(r'^(VirtualHost|Component|Include)\b', text, re.MULTILINE)
if m:
    text = text[:m.start()] + inject + text[m.start():]
else:
    text = inject + text
p.write_text(text)
PY
    log "added console log to prosody main config (global scope)"
fi

# Make sure nginx doesn't try to open syslog on a socket that doesn't
# exist (no syslogd in-container), and logs to stdout/stderr so s6
# captures the output.
if ! grep -q "access_log /dev/stdout" /etc/nginx/nginx.conf; then
    sed -i 's#access_log .*#access_log /dev/stdout;#' /etc/nginx/nginx.conf
    sed -i 's#error_log .*#error_log /dev/stderr warn;#' /etc/nginx/nginx.conf
    log "pointed nginx logs at stdout/stderr"
fi

# ---------------------------------------------------------------- JVB

# Point JVB at a port in OpenHost's allowed 9000-9999 range. The
# openhost.toml binds the same host port, so UDP hitting the VM's
# public IP on 9500 flows straight to JVB.
JVB_PORT="${JVB_PORT:-9500}"
JVB_CONF="/etc/jitsi/videobridge/jvb.conf"
if [[ -f "$JVB_CONF" ]]; then
    # Replace or insert videobridge.ice.udp.port = <n>. The generated
    # config usually has a commented-out block; we append a fresh
    # explicit block to avoid guessing structure.
    if ! grep -qE "^\s*videobridge\s*\{" "$JVB_CONF"; then
        cat >> "$JVB_CONF" <<EOF
videobridge {
    ice {
        udp {
            port = $JVB_PORT
        }
    }
}
EOF
        log "added videobridge.ice.udp.port = $JVB_PORT to jvb.conf"
    else
        # Already exists: just amend via hocon-esque find/replace.
        sed -i -E "s#udp\s*=\s*\{\s*port\s*=\s*[0-9]+\s*\}#udp = { port = $JVB_PORT }#" "$JVB_CONF"
    fi

    # Advertise the *public* host+port to browsers in SDP. Without this
    # JVB hands out 172.x.x.x RFC1918 addresses and external browsers
    # cannot reach the media port, so 3+ participant calls silently
    # fail with black video.
    if [[ -n "${JVB_ADVERTISE_IP:-}" || -n "${JVB_ADVERTISE_IPS:-}" ]]; then
        # Prefer explicit JVB_ADVERTISE_IP; fall back to *IPS for
        # back-compat with the upstream docker-jitsi-meet env names.
        public_ip="${JVB_ADVERTISE_IP:-${JVB_ADVERTISE_IPS%%,*}}"
        local_ip="$(hostname -I | awk '{print $1}')"
        cat >> "$JVB_CONF" <<EOF

ice4j {
    harvest {
        mapping {
            static-mappings = [
                {
                    local-address = "$local_ip"
                    public-address = "$public_ip"
                }
            ]
        }
    }
}
EOF
        log "advertised public address $public_ip (local $local_ip) to ice4j"
    else
        log "JVB_ADVERTISE_IP unset; JVB will attempt to self-discover via STUN"
    fi
fi

# Tell the client JS how to reach the bridge. The generated config.js
# uses the same domain as the HTTP origin for bosh/ws, which is what
# we want, but also embeds an explicit p2p STUN list. Leave it alone.

# ---------------------------------------------------------------- persist

# If we've written shared secrets before, restore them; otherwise copy
# the fresh ones the installer just generated into the persistent dir.
for name in jicofo jvb prosody; do
    src="/etc/jitsi/$name/config"
    dst="$SECRETS_DIR/$name.config"
    if [[ -f "$dst" ]]; then
        cp -f "$dst" "$src"
        log "restored $name shared secrets from persistent storage"
    elif [[ -f "$src" ]]; then
        cp -f "$src" "$dst"
        log "persisted $name shared secrets on first boot"
    fi
done

# Point prosody at a writable data dir under app_data (the default
# /var/lib/prosody is fine across restarts but not across host
# rebuilds, so we funnel it through app_data/prosody-data).
if [[ -d /var/lib/prosody ]]; then
    rsync_if() { [[ -e "$1" ]] && cp -an "$1" "$2" 2>/dev/null || true; }
    mkdir -p "$PROSODY_DATA_DIR"
    rsync_if /var/lib/prosody/. "$PROSODY_DATA_DIR/"
    # Replace /var/lib/prosody with a symlink so prosody writes land
    # in persistent storage. This is idempotent on restart.
    if [[ ! -L /var/lib/prosody ]]; then
        rm -rf /var/lib/prosody
        ln -s "$PROSODY_DATA_DIR" /var/lib/prosody
        chown -h prosody:prosody /var/lib/prosody || true
    fi
fi

# Prosody wants a few directories to exist under the new location.
chown -R prosody:prosody "$PROSODY_DATA_DIR" || true

# /var/run/prosody is where prosody writes its pidfile + unix sockets;
# it's a tmpfs that's empty at container start.
mkdir -p /var/run/prosody /var/log/prosody
chown -R prosody:prosody /var/run/prosody /var/log/prosody

log "jitsi runtime config complete"
