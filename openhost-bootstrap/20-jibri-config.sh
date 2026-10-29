#!/command/with-contenv bash
# Renders the config for our per-instance Jibri services (see
# patches/apply-patches.sh). Our replacement for the upstream jibri image's
# config oneshot (/etc/s6-overlay/scripts/config in ghcr.io/jitsi/jibri),
# which renders a single instance: this follows the same steps but renders
# MAX_JIBRI_INSTANCES sets of jibri/xmpp/logging config. Runs as root after
# 00-openhost-config (which exports the jibri secrets and
# OPENHOST_JIBRI_INSTANCE_ID_PREFIX), and hands everything to the s6 user
# the jibri services run as.

set -eu

log() { echo "[jibri-config] $*" >&2; }

if [[ "${ENABLE_RECORDING:-}" != "1" ]]; then
    log "ENABLE_RECORDING is not 1; jibri stays off"
    exit 0
fi

# Chrome's renderer needs a large /dev/shm (shm_mb in cloudinabottle.toml).
if ! shm-check; then
    log "FATAL: /dev/shm must be at least 2GB in size"
    exit 1
fi

if [[ -z "${JIBRI_RECORDER_PASSWORD:-}" || -z "${JIBRI_XMPP_PASSWORD:-}" ]]; then
    log "FATAL: Jibri recorder password and auth password must be set"
    exit 1
fi

MAX_JIBRI_INSTANCES="$(cat /etc/openhost-jibri-max-instances)"
CONFIG_DIR=/run/jibri/config

install -d -o s6 -g s6 /run/jibri "$CONFIG_DIR" /run/jibri/tmp
install -d -o s6 -g s6 "$JIBRI_RECORDING_DIR"

# ~/.cache, ~/.config and ~/.local are symlinks into /run/tmp; ~/.config
# gets the pulse config shipped in /home/s6/config.
install -d -o s6 -g s6 /run/tmp /run/tmp/s6-cache /run/tmp/s6-config /run/tmp/s6-local
cp -r /home/s6/config/. /run/tmp/s6-config
chown -R s6:s6 /run/tmp/s6-config

# Xorg runs as s6 and can't create its socket dir itself.
install -d -m 1777 /tmp/.X11-unix

tpl /defaults/xorg-video-dummy.conf > "$CONFIG_DIR/xorg-video-dummy.conf"

# Each instance has its own jibri-N.conf (with a unique
# JIBRI_INSTANCE_ID), xmpp-N.conf (which inherits the same instance-id via
# env), and logging-N.properties (writes to /storage/logs-N/).
for i in $(seq 0 $(( MAX_JIBRI_INSTANCES - 1 ))); do
    export JIBRI_INSTANCE_ID="${OPENHOST_JIBRI_INSTANCE_ID_PREFIX:-jibri}-${i}"
    LOGS_DIR="/storage/logs-${i}"
    install -d -o s6 -g s6 "$LOGS_DIR"
    # Each instance binds its own HTTP API ports (on 127.0.0.1); jibri's
    # reference.conf defaults of 2222 (external) and 3333 (internal) are
    # shared, so without this every instance but the first fails to bind:
    # the external port crashes jibri on startup, the internal one is
    # logged at WARN. We don't actually use the API (we dispatch via the
    # XMPP brewery).
    export JIBRI_HTTP_API_EXTERNAL_PORT="$(( 2222 + i ))"
    export JIBRI_HTTP_API_INTERNAL_PORT="$(( 3333 + i ))"
    # The logging.properties references /storage/logs/* literally;
    # rewrite to /storage/logs-N/*.
    #
    # SECURITY: upstream jibri's template sets
    #   java.util.logging.ConsoleHandler.level = FINE
    # and jibri's metaconfig logger dumps EVERY resolved config value at
    # FINE via ConfigSourceSupplier — including the JIBRI_XMPP_PASSWORD
    # and JIBRI_RECORDER_PASSWORD. The console handler writes to stderr,
    # which OpenHost surfaces as the owner-facing container log, so FINE
    # leaks those secrets into the logs. Force the console handler to
    # INFO; the FileHandler stays at FINE so full debug detail is still on
    # disk under /storage/logs-N/. (Do NOT raise ConsoleHandler back to
    # FINE without redacting secrets first.)
    grep -q '^java.util.logging.ConsoleHandler.level = FINE$' /defaults/jibri-logging.properties
    tpl /defaults/jibri-logging.properties \
        | sed "s#/storage/logs/#${LOGS_DIR}/#g" \
        | sed "s#^java.util.logging.ConsoleHandler.level = FINE\$#java.util.logging.ConsoleHandler.level = INFO#" \
        > "$CONFIG_DIR/logging-${i}.properties"
    tpl /defaults/jibri.conf > "$CONFIG_DIR/jibri-${i}.conf"
    tpl /defaults/jibri-xmpp.conf > "$CONFIG_DIR/xmpp-${i}.conf"
    # jibri.conf has 'include "xmpp.conf"' (relative to its own location);
    # point it at the per-instance file.
    grep -q 'include "xmpp.conf"' "$CONFIG_DIR/jibri-${i}.conf"
    sed -i "s#include \"xmpp.conf\"#include \"xmpp-${i}.conf\"#" "$CONFIG_DIR/jibri-${i}.conf"
    # Override jibri.ffmpeg.input-linux to use this instance's X display
    # (:N) instead of the hardcoded :0.0 in jibri's reference.conf.
    # Without this, ALL instances' ffmpegs grab frames from display :0, so
    # only one recording captures the right meeting and the others get a
    # black screen of jibri-0 OR fail entirely (multi-process x11grab on
    # the same display is undefined behavior).
    cat >> "$CONFIG_DIR/jibri-${i}.conf" <<EOF
jibri.ffmpeg.input-linux = [
    "-f", "x11grab",
    "-draw_mouse", "0",
    "-r", \${jibri.ffmpeg.framerate},
    "-s", \${jibri.ffmpeg.resolution},
    "-thread_queue_size", \${jibri.ffmpeg.queue-size},
    "-i", ":${i}.0+0,0",
    "-f", \${jibri.ffmpeg.audio-source},
    "-thread_queue_size", \${jibri.ffmpeg.queue-size},
    "-i", \${jibri.ffmpeg.audio-device}
]
EOF
done

# The rendered configs hold the jibri XMPP passwords.
chown -R s6:s6 "$CONFIG_DIR"
chmod 600 "$CONFIG_DIR"/*

log "rendered config for $MAX_JIBRI_INSTANCES jibri instances"
