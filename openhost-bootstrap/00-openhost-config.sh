#!/usr/bin/with-contenv bash
# OpenHost-specific bootstrap. Runs before any of the upstream
# docker-jitsi-meet cont-init scripts so they can read the values
# we inject here out of /var/run/s6/container_environment (which
# with-contenv surfaces as shell env vars).
#
# We do three things:
#   1. Resolve the public hostname (from $PUBLIC_URL if set, else
#      from a cached first-request discovery dance on port 80).
#   2. Load persisted auth passwords from $OPENHOST_APP_DATA_DIR, or
#      generate + persist fresh ones on first boot.  Jicofo/JVB need
#      these to be stable across restarts or prosody's flat-file
#      user db will disagree with them.
#   3. Export the env vars the upstream templates expect:
#      PUBLIC_URL, JICOFO_AUTH_PASSWORD, JVB_AUTH_PASSWORD,
#      JVB_ADVERTISE_IPS, JVB_PORT.

set -eu

log() { echo "[openhost-init] $*" >&2; }

APP_DATA="${OPENHOST_APP_DATA_DIR:-/data/app_data/jitsi}"
APP_TEMP="${OPENHOST_APP_TEMP_DIR:-/data/app_temp_data/jitsi}"
mkdir -p "$APP_DATA" "$APP_TEMP"

# -------------------------------------------------------------- hostname
#
# Priority:
#   1. $PUBLIC_URL (or $OPENHOST_PUBLIC_HOSTNAME) from the operator
#   2. Cached value from a previous boot
#   3. First-request capture on port 80 via a one-shot listener

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
    log "no hostname set; waiting for first HTTP request to discover it..."
    python3 /opt/openhost-jitsi/discover_hostname.py "$CACHED_HOSTNAME_FILE" >&2
    cat "$CACHED_HOSTNAME_FILE"
}

HOSTNAME_VAL="$(resolve_hostname)"
if [[ -z "$HOSTNAME_VAL" ]]; then
    log "FATAL: could not resolve public hostname"
    exit 1
fi
echo "$HOSTNAME_VAL" > "$CACHED_HOSTNAME_FILE"

PUBLIC_URL_VAL="${PUBLIC_URL:-https://$HOSTNAME_VAL}"
log "PUBLIC_URL=$PUBLIC_URL_VAL hostname=$HOSTNAME_VAL"

# -------------------------------------------------------------- passwords
#
# Generate on first boot; re-use on subsequent boots. These are the
# *internal* shared secrets between prosody, jicofo, and jvb -- they
# never leave the container.

SECRETS_DIR="$APP_DATA/secrets"
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

persist_password() {
    local var_name="$1" file="$SECRETS_DIR/$1"
    if [[ ! -f "$file" ]]; then
        openssl rand -hex 16 > "$file"
        chmod 600 "$file"
        log "generated new $var_name"
    fi
    cat "$file"
}

JICOFO_AUTH_PASSWORD_VAL="$(persist_password JICOFO_AUTH_PASSWORD)"
JICOFO_COMPONENT_SECRET_VAL="$(persist_password JICOFO_COMPONENT_SECRET)"
JVB_AUTH_PASSWORD_VAL="$(persist_password JVB_AUTH_PASSWORD)"

# Jibri secrets — only generated when recording is enabled.  They
# never leave the container; prosody, jicofo, and jibri all read
# them out of /var/run/s6/container_environment via with-contenv.
if [[ "${ENABLE_RECORDING:-}" == "1" ]]; then
    JIBRI_XMPP_PASSWORD_VAL="$(persist_password JIBRI_XMPP_PASSWORD)"
    JIBRI_RECORDER_PASSWORD_VAL="$(persist_password JIBRI_RECORDER_PASSWORD)"

    # Chrome flags Jibri will pass to chromedriver. The upstream
    # /defaults/jibri.conf template renders these into jibri.conf
    # iff CHROMIUM_FLAGS is set; otherwise it falls back to a
    # default list that omits --disable-infobars and lets the
    # "Chrome is being controlled by automated test software"
    # banner appear in recordings.
    #
    # The list below is the upstream default plus three additions:
    #   --disable-infobars                  hides the automation infobar
    #   --disable-blink-features=AutomationControlled
    #                                        hides navigator.webdriver hints
    #   --no-default-browser-check          avoids a first-run popup
    #
    # We keep --use-fake-ui-for-media-stream so getUserMedia auto-grants;
    # --kiosk for full-screen recording; --autoplay-policy=no-user-gesture-required
    # so jitsi's media autoplays without a click.
    CHROMIUM_FLAGS_VAL="--use-fake-ui-for-media-stream,--start-maximized,--kiosk,--enabled,--autoplay-policy=no-user-gesture-required,--disable-infobars,--disable-blink-features=AutomationControlled,--no-default-browser-check,--no-first-run"

    # Number of parallel Jibri instances to start. Each one needs
    # roughly 1.5 GB RAM + 1.5 vCPU while a recording is in flight,
    # so the operator should size [resources].memory_mb /
    # cpu_millicores in openhost.toml accordingly (see the README
    # for a sizing table). Hard upper bound matches the build-time
    # MAX_JIBRI_INSTANCES baked into the image (see
    # patches/apply-patches.sh).
    BUILD_MAX="$(cat /etc/openhost-jibri-max-instances 2>/dev/null || echo 6)"
    REQUESTED="${MAX_PARALLEL_RECORDINGS:-1}"
    if ! [[ "$REQUESTED" =~ ^[1-9][0-9]*$ ]]; then
        log "FATAL: MAX_PARALLEL_RECORDINGS must be a positive integer (got: $REQUESTED)"
        exit 1
    fi
    if (( REQUESTED > BUILD_MAX )); then
        log "WARN: MAX_PARALLEL_RECORDINGS=$REQUESTED exceeds compiled-in max $BUILD_MAX; clamping"
        REQUESTED="$BUILD_MAX"
    fi
    MAX_PARALLEL_RECORDINGS_VAL="$REQUESTED"
    log "jibri parallel recording instances: $MAX_PARALLEL_RECORDINGS_VAL (max baked: $BUILD_MAX)"

    # Persist a stable per-deployment instance-id prefix.  The
    # rendered jibri.conf hardcodes JIBRI_INSTANCE_ID at template
    # render time, so we want the prefix to survive container
    # restarts; otherwise jicofo's brewery state would see a brand
    # new pool of jibris on every reboot.  We append "-N" per
    # instance index in the cont-init renderer.
    INSTANCE_ID_PREFIX_FILE="$SECRETS_DIR/jibri_instance_id_prefix"
    if [[ ! -f "$INSTANCE_ID_PREFIX_FILE" ]]; then
        printf 'jibri-%s' "$(openssl rand -hex 4)" > "$INSTANCE_ID_PREFIX_FILE"
        chmod 600 "$INSTANCE_ID_PREFIX_FILE"
    fi
    OPENHOST_JIBRI_INSTANCE_ID_PREFIX_VAL="$(cat "$INSTANCE_ID_PREFIX_FILE")"
fi

# -------------------------------------------------------------- JVB addr
#
# JVB needs to advertise a public IP in its SDP ICE candidates so
# remote browsers can actually open UDP to it. OpenHost gives us a
# fixed host port (9500/udp from the manifest) but doesn't inject the
# public IP directly. We can either:
#   * accept an explicit JVB_ADVERTISE_IP env var from the operator
#   * resolve the public hostname's A record at boot (works because
#     the OpenHost router and JVB live on the same VM)
#
# If neither works, JVB falls back to its built-in STUN-based
# discovery via stun.l.google.com, which works on most cloud VMs.

if [[ -z "${JVB_ADVERTISE_IPS:-}" ]]; then
    if [[ -n "${JVB_ADVERTISE_IP:-}" ]]; then
        JVB_ADVERTISE_IPS_VAL="$JVB_ADVERTISE_IP"
    else
        # Resolve the public hostname's A record.
        RESOLVED="$(getent ahostsv4 "$HOSTNAME_VAL" 2>/dev/null | awk 'NR==1 {print $1}')"
        if [[ -n "$RESOLVED" ]]; then
            JVB_ADVERTISE_IPS_VAL="$RESOLVED"
            log "resolved $HOSTNAME_VAL -> $JVB_ADVERTISE_IPS_VAL for JVB advertising"
        else
            JVB_ADVERTISE_IPS_VAL=""
            log "could not resolve $HOSTNAME_VAL; JVB will self-discover via STUN"
        fi
    fi
else
    JVB_ADVERTISE_IPS_VAL="$JVB_ADVERTISE_IPS"
fi

# -------------------------------------------------------------- export
#
# s6-overlay's with-contenv reads from /var/run/s6/container_environment.
# We write our values there so all later cont-init scripts (and the
# services they bootstrap) see them via `with-contenv`.

CENV=/var/run/s6/container_environment
mkdir -p "$CENV"
printf '%s' "$PUBLIC_URL_VAL"             > "$CENV/PUBLIC_URL"
printf '%s' "$HOSTNAME_VAL"               > "$CENV/OPENHOST_PUBLIC_HOSTNAME"
printf '%s' "$JICOFO_AUTH_PASSWORD_VAL"   > "$CENV/JICOFO_AUTH_PASSWORD"
printf '%s' "$JICOFO_COMPONENT_SECRET_VAL" > "$CENV/JICOFO_COMPONENT_SECRET"
printf '%s' "$JVB_AUTH_PASSWORD_VAL"      > "$CENV/JVB_AUTH_PASSWORD"
[[ -n "${JIBRI_XMPP_PASSWORD_VAL:-}" ]] && printf '%s' "$JIBRI_XMPP_PASSWORD_VAL" > "$CENV/JIBRI_XMPP_PASSWORD"
[[ -n "${JIBRI_RECORDER_PASSWORD_VAL:-}" ]] && printf '%s' "$JIBRI_RECORDER_PASSWORD_VAL" > "$CENV/JIBRI_RECORDER_PASSWORD"
[[ -n "${CHROMIUM_FLAGS_VAL:-}" ]] && printf '%s' "$CHROMIUM_FLAGS_VAL" > "$CENV/CHROMIUM_FLAGS"
[[ -n "${MAX_PARALLEL_RECORDINGS_VAL:-}" ]] && printf '%s' "$MAX_PARALLEL_RECORDINGS_VAL" > "$CENV/MAX_PARALLEL_RECORDINGS"
[[ -n "${OPENHOST_JIBRI_INSTANCE_ID_PREFIX_VAL:-}" ]] && \
    printf '%s' "$OPENHOST_JIBRI_INSTANCE_ID_PREFIX_VAL" > "$CENV/OPENHOST_JIBRI_INSTANCE_ID_PREFIX"
[[ -n "$JVB_ADVERTISE_IPS_VAL" ]] && printf '%s' "$JVB_ADVERTISE_IPS_VAL" > "$CENV/JVB_ADVERTISE_IPS"
# JVB_PORT defaults to 10000 in the upstream templates; we pin 9500
# to match the [[ports]] entry in openhost.toml (OpenHost only allows
# extra ports in the 9000-9999 range).
printf '%s' "${JVB_PORT:-9500}" > "$CENV/JVB_PORT"

log "bootstrap complete"
