#!/bin/bash
# Merges the upstream images' s6-overlay v3 service trees (copied to
# /tmp/upstream/<image>/ by Dockerfile.prebuilt) into this image's
# /etc/s6-overlay, and installs our per-instance jibri services. Run at
# image build time.
#
# Each upstream image has a `10-config` oneshot running
# /etc/s6-overlay/scripts/config, followed by its daemons. Since stable-11146
# every service renders its config into its own /run/<service>/config, so
# the only collisions left are those names: the oneshot becomes
# `<image>-config` and its script `scripts/<image>-config`. Upstream's images
# run as the s6 user; ours runs s6-overlay as root (see Dockerfile.prebuilt),
# so every upstream oneshot and longrun is started through
# `s6-setuidgid s6`. Fails the build if upstream's layout changes under us.
set -euo pipefail

UP=/tmp/upstream
RC=/etc/s6-overlay/s6-rc.d
SCRIPTS=/etc/s6-overlay/scripts
mkdir -p "$RC/user/contents.d" "$SCRIPTS"

# take <image> <service>...: installs the image's config oneshot as
# <image>-config plus the named services, and the scripts they run.
take() {
    local image=$1
    shift
    local src="$UP/$image/s6-rc.d"
    cp -r "$src/10-config" "$RC/$image-config"
    touch "$RC/user/contents.d/$image-config"
    install -m 755 "$UP/$image/scripts/config" "$SCRIPTS/$image-config"
    sed -i "s#^/etc/s6-overlay/scripts/config\$#/etc/s6-overlay/scripts/$image-config#" "$RC/$image-config/up"
    local svc script entry
    for svc in "$@"; do
        cp -r "$src/$svc" "$RC/$svc"
        touch "$RC/user/contents.d/$svc"
        if [[ -e "$RC/$svc/dependencies.d/10-config" ]]; then
            mv "$RC/$svc/dependencies.d/10-config" "$RC/$svc/dependencies.d/$image-config"
        fi
        entry="$RC/$svc/run"
        [[ -e "$entry" ]] || entry="$RC/$svc/up"
        script="$(grep -o '^/etc/s6-overlay/scripts/[^ ]*' "$entry")"
        install -m 755 "$UP/$image/scripts/${script##*/}" "$SCRIPTS/${script##*/}"
    done
    for svc in "$image-config" "$@"; do
        local f
        for f in "$RC/$svc/up" "$RC/$svc/run"; do
            [[ -e "$f" ]] || continue
            sed -i 's#^/etc/s6-overlay/scripts/#/command/s6-setuidgid s6 /etc/s6-overlay/scripts/#' "$f"
            grep -q '^/command/s6-setuidgid s6 /etc/s6-overlay/scripts/' "$f" || {
                echo "[patches] $f does not run an upstream script; layout changed?" >&2
                exit 1
            }
        done
    done
}

# rename_logging <image>: the image's logging.properties template is
# installed as /defaults/<image>-logging.properties.
rename_logging() {
    local f="$SCRIPTS/$1-config"
    grep -q 'tpl /defaults/logging\.properties' "$f"
    sed -i "s#tpl /defaults/logging\.properties#tpl /defaults/$1-logging.properties#" "$f"
}

# prosody: config, prosody, and the oneshot that registers the
# focus/jvb/jibri users once prosody is up. Not taken: 20-saslauthd, only
# used for LDAP auth (it self-disables with `s6-svc -O`, which the s6 user
# can't do to a root-supervised service).
take prosody prosody 70-register-setup
# jicofo, jvb. Not taken: jvb's autoscaler sidecar, and jvb's `finish`,
# which halts the whole container when jvb exits cleanly (meant for
# autoscaled single-service containers; here s6 just restarts jvb).
take jicofo jicofo
rename_logging jicofo
take jvb jvb
rename_logging jvb
rm -f "$RC/jvb/finish" "$RC/jvb/timeout-finish"
# web: config and nginx. Not taken: acme-renewal and jaas-account (TLS is
# terminated by the Cloud in a Bottle router; DISABLE_HTTPS=1).
take web nginx

# --------------------------------------------------------------- jibri
#
# We support up to MAX_JIBRI_INSTANCES (=6) parallel Jibri instances
# inside this single container, sharing one prosody / jicofo /
# jvb. Each Jibri needs its own:
#
#   * Xorg display ($DISPLAY=:N, listening on TCP port 6000+N)
#   * PulseAudio runtime dir ($PULSE_RUNTIME_PATH=/run/pulse-N)
#   * JIBRI_INSTANCE_ID (the brewery-MUC nickname; must be unique
#     per jibri at the prosody level or the second login is rejected)
#   * jibri.conf, xmpp.conf, logging.properties (rendered into
#     /run/jibri/config/{jibri,xmpp}-N.conf and logging-N.properties
#     by /etc/cont-init.d/20-jibri-config, since each references
#     JIBRI_INSTANCE_ID and points at per-instance log dirs)
#   * /storage/logs-N (java FileHandler log path)
#
# The recordings directory (/storage/recordings/<session-id>) is
# shared across instances; jicofo mints unique session IDs so there's
# no collision risk.
#
# At runtime, the operator picks how many instances to actually use
# via MAX_PARALLEL_RECORDINGS in [1, MAX_JIBRI_INSTANCES]. Each
# instance's run script self-disables via 's6-svc -O' if its index >=
# MAX_PARALLEL_RECORDINGS, or if ENABLE_RECORDING != 1, so we always
# bake all 6 service definitions into the image but only spend
# resources on the configured count.
#
# These are legacy /etc/services.d services, which s6-overlay starts
# after the s6-rc user bundle, ie after prosody is up and
# 70-register-setup has registered the jibri users. Upstream's own
# jibri services (one instance, plus icewm and the autoscaler sidecar)
# are not used.
MAX_JIBRI_INSTANCES=6
echo "$MAX_JIBRI_INSTANCES" > /etc/openhost-jibri-max-instances

# Shared prologue sourced from each per-instance run script. It
# (a) derives INSTANCE_INDEX from the service-dir name, and
# (b) self-disables the service when ENABLE_RECORDING != 1 or when
#     INSTANCE_INDEX >= MAX_PARALLEL_RECORDINGS.
mkdir -p /opt/openhost-jitsi
cat > /opt/openhost-jitsi/jibri-run-prologue.sh <<'PROLOGUE'
# Sourced (not exec'd) by every jibri-* services.d/*/run script.
# Sets INSTANCE_INDEX and self-disables the service if it should
# not run with the current MAX_PARALLEL_RECORDINGS.
SVC_DIR="$(dirname "$(readlink -f "$0")")"
INSTANCE_INDEX="${SVC_DIR##*-}"

if [[ "${ENABLE_RECORDING:-1}" != "1" ]]; then
    exec s6-svc -O "$SVC_DIR"
fi
if (( INSTANCE_INDEX >= ${MAX_PARALLEL_RECORDINGS:-1} )); then
    exec s6-svc -O "$SVC_DIR"
fi

# Everything below runs as the unprivileged s6 user, like upstream's
# jibri image; its home holds the ALSA/pulse/icewm config.
HOME=/home/s6
export HOME
PROLOGUE
chmod 644 /opt/openhost-jitsi/jibri-run-prologue.sh

cat > /tmp/_xorg_run <<'RUN'
#!/command/with-contenv bash
. /opt/openhost-jitsi/jibri-run-prologue.sh

DISPLAY=":${INSTANCE_INDEX}"
DAEMON="/usr/bin/Xorg -nocursor -noreset +extension RANDR +extension RENDER \
    -logfile /storage/logs-${INSTANCE_INDEX}/xorg.log \
    -config /run/jibri/config/xorg-video-dummy.conf ${DISPLAY}"
exec s6-setuidgid s6 /bin/bash -c "exec $DAEMON"
RUN

cat > /tmp/_pulse_run <<'RUN'
#!/command/with-contenv bash
. /opt/openhost-jitsi/jibri-run-prologue.sh

# Each pulse instance gets its own runtime dir so the unix sockets
# don't collide. We also override the log path so we can tell whose
# log is whose.  The rest of the pulse config (~/.config/pulse/)
# is shared and instance-agnostic.
PULSE_RUNTIME_PATH="/run/pulse-${INSTANCE_INDEX}"
mkdir -p "$PULSE_RUNTIME_PATH"
chown s6:s6 "$PULSE_RUNTIME_PATH"
export PULSE_RUNTIME_PATH

# We wrap pulseaudio in dbus-run-session so each instance gets its
# own private session-bus.  Without this, the second and subsequent
# pulse instances fail to load module-virtual-sink (jibri-loop) with
# "D-Bus name org.PulseAudio1 already taken" — pulse uses an internal
# D-Bus connection for module IPC and only one process per session
# bus can hold the org.PulseAudio1 name.  The result is that the
# jibri-loop sink (which ffmpeg pulls audio from via its monitor)
# is unloaded immediately after creation, and jibri's next recording
# start fails with "default: No such process" from ffmpeg.
exec s6-setuidgid s6 /bin/bash -c \
    "PULSE_RUNTIME_PATH='$PULSE_RUNTIME_PATH' \
     exec dbus-run-session -- /usr/bin/pulseaudio \
        --log-target=file:/storage/logs-${INSTANCE_INDEX}/pulse.log"
RUN

cat > /tmp/_jibri_run <<'RUN'
#!/command/with-contenv bash
. /opt/openhost-jitsi/jibri-run-prologue.sh

DISPLAY=":${INSTANCE_INDEX}"
PULSE_RUNTIME_PATH="/run/pulse-${INSTANCE_INDEX}"
export DISPLAY PULSE_RUNTIME_PATH

CONFIG_FILE="/run/jibri/config/jibri-${INSTANCE_INDEX}.conf"
LOGGING_FILE="/run/jibri/config/logging-${INSTANCE_INDEX}.properties"
LOGS_DIR="/storage/logs-${INSTANCE_INDEX}"

# Pre-warm chrome so the first recording starts quickly. Each
# instance pre-warms against its own DISPLAY so the cached state
# applies when jibri actually launches chromedriver later.
#
# Note: --timeout is a chromedriver flag (not chrome's), so we wrap
# the invocation in coreutils `timeout` to bound the warm-up. If the
# Xorg for this DISPLAY isn't ready yet, we'd otherwise hang here
# indefinitely and prevent jibri from ever starting.
timeout 30s s6-setuidgid s6 \
    env DISPLAY="$DISPLAY" PULSE_RUNTIME_PATH="$PULSE_RUNTIME_PATH" \
    /usr/bin/google-chrome --headless --no-sandbox about:blank \
    || echo "[jibri-${INSTANCE_INDEX}] chrome pre-warm timed out or failed; continuing" >&2

DAEMON="java \
    -Djava.util.logging.config.file=${LOGGING_FILE} \
    -Dconfig.file=${CONFIG_FILE} \
    -Djava.io.tmpdir=/run/jibri/tmp \
    -Dwebdriver.chrome.driver=/usr/bin/chromedriver \
    -Dwebdriver.chrome.logfile=${LOGS_DIR}/chromedriver.log \
    -jar /opt/jitsi/jibri/jibri.jar"
exec s6-setuidgid s6 /bin/bash -c "exec $DAEMON"
RUN

# Install the same run script in every per-instance service dir.
for i in $(seq 0 $(( MAX_JIBRI_INSTANCES - 1 ))); do
    install -D -m 755 /tmp/_xorg_run  "/etc/services.d/15-jibri-xorg-${i}/run"
    install -D -m 755 /tmp/_pulse_run "/etc/services.d/16-jibri-pulse-${i}/run"
    install -D -m 755 /tmp/_jibri_run "/etc/services.d/17-jibri-${i}/run"
done
rm -f /tmp/_xorg_run /tmp/_pulse_run /tmp/_jibri_run

echo "[patches] applied successfully"
