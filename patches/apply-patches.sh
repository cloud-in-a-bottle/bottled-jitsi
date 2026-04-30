#!/bin/bash
# Patches the official docker-jitsi-meet cont-init + service scripts
# to use per-service /config subdirectories instead of a shared
# /config root. Run at image build time.
set -euo pipefail

# --------------------------------------------------------------- prosody
# Prosody expects /config/{prosody.cfg.lua,conf.d,certs,data}. Move
# them under /config/prosody/. The /defaults templates also contain
# literal /config paths that tpl passes through unchanged, so we have
# to rewrite them too.
PROSODY_SED=(
    -e 's#/config/prosody\.cfg\.lua#/config/prosody/prosody.cfg.lua#g'
    -e 's#/config/data#/config/prosody/data#g'
    -e 's#/config/certs#/config/prosody/certs#g'
    -e 's#/config/conf\.d#/config/prosody/conf.d#g'
    -e 's#/config/rules\.d#/config/prosody/rules.d#g'
)
sed -i "${PROSODY_SED[@]}" \
    /etc/cont-init.d/10-prosody-config \
    /etc/services.d/prosody/run \
    /defaults/prosody.cfg.lua \
    /defaults/conf.d/jitsi-meet.cfg.lua \
    /defaults/conf.d/brewery.cfg.lua \
    /defaults/conf.d/visitors.cfg.lua

# Extra fixups that can't be done via simple sed:
sed -i \
    -e 's#chown -R prosody /config\b#chown -R prosody /config/prosody#g' \
    -e 's#cp -r /defaults/\* /config$#mkdir -p /config/prosody/conf.d \&\& cp /defaults/prosody.cfg.lua /config/prosody/ \&\& cp -r /defaults/conf.d /config/prosody/#g' \
    -e 's#stat -c %U /config\b#stat -c %U /config/prosody#g' \
    /etc/cont-init.d/10-prosody-config

# Force the expected directory layout to exist before any of the
# upstream checks run.  The upstream script assumes /config is
# prosody-owned from the start (because in the upstream image the
# /config VOLUME is pre-created during docker build). We're sharing
# /config across services, so we need to make the per-service subdir
# first.
python3 - <<'PY'
import pathlib
p = pathlib.Path("/etc/cont-init.d/10-prosody-config")
text = p.read_text()
prologue = (
    "#!/usr/bin/with-contenv bash\n"
    "mkdir -p /config/prosody/data /config/prosody/conf.d /config/prosody/certs /config/prosody/rules.d\n"
)
text = text.replace("#!/usr/bin/with-contenv bash", prologue, 1)
p.write_text(text)
PY

# --------------------------------------------------------------- jicofo
# jicofo expects /config/jicofo.conf and /config/logging.properties.
# We renamed logging.properties to jicofo-logging.properties in
# /defaults so it doesn't clash with jvb's copy. Rewrite references
# in both the cont-init script and the jicofo.conf template file
# (which contains literal /config paths that tpl passes through).
JICOFO_SED=(
    -e 's#/config/jicofo\.conf#/config/jicofo/jicofo.conf#g'
    -e 's#/config/logging\.properties#/config/jicofo/logging.properties#g'
)
sed -i "${JICOFO_SED[@]}" \
    /etc/cont-init.d/11-jicofo-config \
    /etc/services.d/jicofo/run \
    /defaults/jicofo.conf \
    /defaults/jicofo-logging.properties

sed -i \
    -e 's#tpl /defaults/logging\.properties#tpl /defaults/jicofo-logging.properties#g' \
    -e 's#chown -R jicofo:jitsi /config\b#chown -R jicofo:jitsi /config/jicofo#g' \
    /etc/cont-init.d/11-jicofo-config

# The upstream jicofo cont-init file greps /config/... so make sure
# our /config/jicofo directory is created before tpl writes to it.
python3 - <<'PY'
import pathlib
p = pathlib.Path("/etc/cont-init.d/11-jicofo-config")
text = p.read_text()
# Insert mkdir near the top (after the shebang + set -e if any).
# The upstream script is a simple bash; prepending is safe.
if "mkdir -p /config/jicofo" not in text:
    text = text.replace(
        "#!/usr/bin/with-contenv bash",
        "#!/usr/bin/with-contenv bash\nmkdir -p /config/jicofo",
        1,
    )
p.write_text(text)
PY

sed -i \
    -e 's#/config/jicofo\.conf#/config/jicofo/jicofo.conf#g' \
    -e 's#/config/logging\.properties#/config/jicofo/logging.properties#g' \
    /etc/services.d/jicofo/run

# --------------------------------------------------------------- jvb
JVB_SED=(
    -e 's#/config/jvb\.conf#/config/jvb/jvb.conf#g'
    -e 's#/config/logging\.properties#/config/jvb/logging.properties#g'
)
sed -i "${JVB_SED[@]}" \
    /etc/cont-init.d/12-jvb-config \
    /etc/services.d/jvb/run \
    /defaults/jvb.conf \
    /defaults/jvb-logging.properties

sed -i \
    -e 's#tpl /defaults/logging\.properties#tpl /defaults/jvb-logging.properties#g' \
    -e 's#chown -R jvb:jitsi /config\b#chown -R jvb:jitsi /config/jvb#g' \
    /etc/cont-init.d/12-jvb-config

python3 - <<'PY'
import pathlib
p = pathlib.Path("/etc/cont-init.d/12-jvb-config")
text = p.read_text()
if "mkdir -p /config/jvb" not in text:
    text = text.replace(
        "#!/usr/bin/with-contenv bash",
        "#!/usr/bin/with-contenv bash\nmkdir -p /config/jvb",
        1,
    )
p.write_text(text)
PY

sed -i \
    -e 's#/config/jvb\.conf#/config/jvb/jvb.conf#g' \
    -e 's#/config/logging\.properties#/config/jvb/logging.properties#g' \
    -e 's#-Dnet\.java\.sip\.communicator\.SC_HOME_DIR_LOCATION=/#-Dnet.java.sip.communicator.SC_HOME_DIR_LOCATION=/config/jvb#g' \
    -e 's#-Dnet\.java\.sip\.communicator\.SC_HOME_DIR_NAME=config#-Dnet.java.sip.communicator.SC_HOME_DIR_NAME=sipcomm#g' \
    /etc/services.d/jvb/run

# --------------------------------------------------------------- web (nginx)
# Web uses a lot of /config paths; rewriter is verbose but mechanical.
# The one wrinkle is the shell brace expansion
#   mkdir -p /config/{nginx/site-confs,keys}
# which we must rewrite explicitly before the generic sed rules, or
# the 'keys' leg is left under /config instead of /config/web.
#
# The /defaults templates themselves also contain literal /config
# paths (e.g. 'include /config/nginx/meet.conf' in nginx-default.conf)
# which tpl passes through unchanged, so we patch the templates too.
WEB_SED=(
    -e 's#/config/{nginx/site-confs,keys}#/config/web/nginx/site-confs /config/web/keys#g'
    -e 's#/config/nginx\b#/config/web/nginx#g'
    -e 's#/config/keys\b#/config/web/keys#g'
    -e 's#/config/acme\b#/config/web/acme#g'
    -e 's#/config/acme-certs\b#/config/web/acme-certs#g'
    -e 's#/config/config\.js\b#/config/web/config.js#g'
    -e 's#/config/custom-config\.js\b#/config/web/custom-config.js#g'
    -e 's#/config/interface_config\.js\b#/config/web/interface_config.js#g'
    -e 's#/config/custom-interface_config\.js\b#/config/web/custom-interface_config.js#g'
)
sed -i "${WEB_SED[@]}" \
    /etc/cont-init.d/13-web-config \
    /etc/services.d/nginx/run \
    /defaults/nginx.conf \
    /defaults/nginx-default.conf \
    /defaults/meet.conf \
    /defaults/ssl.conf

sed -i \
    -e 's#tpl /defaults/default\b#tpl /defaults/nginx-default.conf#g' \
    -e 's#chown -R www-data /config\b#chown -R www-data /config/web#g' \
    /etc/cont-init.d/13-web-config

# Force nginx to echo the 'xmpp' WebSocket subprotocol back to the
# client on /xmpp-websocket. Prosody's mod_websocket in some versions
# omits the Sec-WebSocket-Protocol response header under certain
# proxy configurations, which causes strict client implementations
# (including lib-jitsi-meet in Chrome/Firefox) to abort the
# connection immediately after the WebSocket handshake.
#
# We use proxy_pass_header + a lua/perl helper? No -- simplest way
# is to have nginx synthesize the subprotocol response header
# outside of the proxy path. We use a map + add_header combo so the
# header is emitted on any non-2xx response (add_header applies
# only to 2xx/3xx by default; 'always' extends it to all codes
# including 101 Switching Protocols).
python3 - <<'PY'
import pathlib
p = pathlib.Path("/defaults/meet.conf")
text = p.read_text()
# Insert add_header inside the /xmpp-websocket location block. The
# 'always' flag is required to make nginx include the header on the
# 101 Switching Protocols response (which by default skips
# non-2xx/3xx add_header directives).
needle = 'location = /xmpp-websocket {'
injection = (
    'location = /xmpp-websocket {\n'
    '    # Echo the client-requested xmpp subprotocol in the 101\n'
    '    # response; strict WebSocket clients abort otherwise.\n'
    '    add_header Sec-WebSocket-Protocol "xmpp" always;\n'
    '    more_set_headers "Sec-WebSocket-Protocol: xmpp";\n'
)
assert needle in text, "xmpp-websocket block not found"
text = text.replace(needle, injection, 1)
p.write_text(text)
print("[patches] injected subprotocol header into meet.conf")
PY

# Make sure every services.d run script inherits container env. The
# upstream jvb run uses /bin/bash but with `with-contenv bash` the
# env var forwarding works; we don't need to change that.

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
#     /etc/jitsi/jibri/{jibri,xmpp}-N.conf and logging-N.properties
#     since each references JIBRI_INSTANCE_ID and points at
#     per-instance log dirs)
#   * /config/logs-N (java FileHandler log path; sharing across
#     processes is technically supported via lock files but produces
#     interleaved logs that are very hard to debug — give each
#     instance its own dir)
#
# The recordings directory (/config/recordings/<session-id>) is
# shared across instances; jicofo mints unique session IDs so there's
# no collision risk.
#
# At runtime, the operator picks how many instances to actually use
# via MAX_PARALLEL_RECORDINGS in [1, MAX_JIBRI_INSTANCES] (default
# 1).  Each instance's run script self-disables via 's6-svc -O' if
# its index >= MAX_PARALLEL_RECORDINGS, so we always bake all 6
# service definitions into the image but only spend resources on
# the configured count.
#
# We ALSO disable all instances entirely when ENABLE_RECORDING != 1,
# preserving the prior behavior where recording can be turned off
# for users who don't want the privileged-app opt-in.
MAX_JIBRI_INSTANCES=6

# Retarget the cont-init script to render per-instance config files.
# The upstream cont-init renders one set of config files; we replace
# its tpl calls with a loop that renders N sets. Other than the tpl
# calls, the cont-init's environment validation, capability check,
# and instance-id defaulting are still useful, so we keep them and
# only rewrite the rendering block.
python3 - <<'PY'
import pathlib
import re
p = pathlib.Path("/etc/cont-init.d/16-jibri-config")
text = p.read_text()

# Replace the four tpl calls with our looped renderer. The marker
# we look for is the upstream "always recreate configs" comment
# block; everything from there to the next blank line is replaced.
old = (
    "# always recreate configs\n"
    "tpl /defaults/jibri.conf > /etc/jitsi/jibri/jibri.conf\n"
    "tpl /defaults/xmpp.conf > /etc/jitsi/jibri/xmpp.conf\n"
    "tpl /defaults/logging.properties > /etc/jitsi/jibri/logging.properties\n"
    "tpl /defaults/xorg-video-dummy.conf > /etc/jitsi/jibri/xorg-video-dummy.conf\n"
)
new = (
    "# Render per-instance configs. Each instance has its own\n"
    "# jibri-N.conf (with a unique JIBRI_INSTANCE_ID), xmpp-N.conf\n"
    "# (which inherits the same instance-id via env), and\n"
    "# logging-N.properties (writes to /config/logs-N/). The\n"
    "# xorg-video-dummy.conf has no per-instance state.\n"
    "tpl /defaults/xorg-video-dummy.conf > /etc/jitsi/jibri/xorg-video-dummy.conf\n"
    "for i in $(seq 0 $(( ${MAX_JIBRI_INSTANCES:-6} - 1 ))); do\n"
    "    export JIBRI_INSTANCE_ID=\"${OPENHOST_JIBRI_INSTANCE_ID_PREFIX:-jibri}-${i}\"\n"
    "    export JIBRI_LOGS_DIR=\"/config/logs-${i}\"\n"
    "    mkdir -p \"$JIBRI_LOGS_DIR\"\n"
    "    chown -R jibri \"$JIBRI_LOGS_DIR\"\n"
    "    # The logging.properties references /config/logs/* literally;\n"
    "    # rewrite to /config/logs-N/* on the fly via tpl + sed.\n"
    "    tpl /defaults/jibri-logging.properties \\\n"
    "        | sed \"s#/config/logs/#/config/logs-${i}/#g\" \\\n"
    "        > \"/etc/jitsi/jibri/logging-${i}.properties\"\n"
    "    tpl /defaults/jibri.conf > \"/etc/jitsi/jibri/jibri-${i}.conf\"\n"
    "    tpl /defaults/jibri-xmpp.conf > \"/etc/jitsi/jibri/xmpp-${i}.conf\"\n"
    "    # jibri.conf has 'include \"xmpp.conf\"' (relative to its own\n"
    "    # location); rewrite to point at the per-instance file.\n"
    "    sed -i \"s#include \\\"xmpp.conf\\\"#include \\\"xmpp-${i}.conf\\\"#g\" \\\n"
    "        \"/etc/jitsi/jibri/jibri-${i}.conf\"\n"
    "done\n"
)
assert old in text, "could not find tpl block in 16-jibri-config to replace"
text = text.replace(old, new, 1)

# The upstream cont-init also runs `mkdir -p /config/logs` and chowns
# it; that's still useful as a no-op fallback (log path for any
# instance whose logging.properties wasn't rewritten correctly).
p.write_text(text)
PY

# Stamp the MAX_JIBRI_INSTANCES build-time constant into a place the
# cont-init and the per-instance run scripts can read it from. We
# write it as a /var/run/s6/container_environment file at boot via
# 00-openhost-config.sh, but services.d/run scripts execute BEFORE
# container_environment is fully populated for subsequent services,
# so the safest thing is also to bake the same value into a
# build-time file that everyone reads.
echo "$MAX_JIBRI_INSTANCES" > /etc/openhost-jibri-max-instances

# Per-instance Xorg / Pulse / Jibri service definitions. We start
# from the existing 15-jibri-xorg, 16-jibri-pulse, 17-jibri trees
# (each is a one-file directory with a `run` script) and clone them
# 6 times.
for instance_kind in xorg pulse jibri; do
    case $instance_kind in
        xorg)  src=15-jibri-xorg  ;;
        pulse) src=16-jibri-pulse ;;
        jibri) src=17-jibri        ;;
    esac
    for i in $(seq 0 $(( MAX_JIBRI_INSTANCES - 1 ))); do
        dst="${src}-${i}"
        cp -r "/etc/services.d/$src" "/etc/services.d/$dst"
    done
    rm -rf "/etc/services.d/$src"
done

# Shared prologue sourced from each per-instance run script. It
# (a) derives INSTANCE_INDEX from the service-dir name, and
# (b) self-disables the service when ENABLE_RECORDING != 1 or when
#     INSTANCE_INDEX >= MAX_PARALLEL_RECORDINGS.
# Both checks must run before any per-service setup, so we put them
# in a shared file rather than duplicating across the three run
# script bodies.
mkdir -p /etc/jitsi/jibri
cat > /etc/jitsi/jibri/run-prologue.sh <<'PROLOGUE'
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
PROLOGUE
chmod 644 /etc/jitsi/jibri/run-prologue.sh

# Per-instance run scripts. Each sources the shared prologue, then
# does only the kind-specific setup before exec'ing its daemon.

cat > /tmp/_xorg_run <<'RUN'
#!/usr/bin/with-contenv bash
. /etc/jitsi/jibri/run-prologue.sh

DISPLAY=":${INSTANCE_INDEX}"
DAEMON="/usr/bin/Xorg -nocursor -noreset +extension RANDR +extension RENDER \
    -logfile /tmp/xorg-${INSTANCE_INDEX}.log \
    -config /etc/jitsi/jibri/xorg-video-dummy.conf ${DISPLAY}"
exec s6-setuidgid jibri /bin/bash -c "exec $DAEMON"
RUN

cat > /tmp/_pulse_run <<'RUN'
#!/usr/bin/with-contenv bash
. /etc/jitsi/jibri/run-prologue.sh

# Each pulse instance gets its own runtime dir so the unix sockets
# don't collide. We also override the log path so we can tell whose
# log is whose.  The rest of the pulse config (~/.config/pulse/)
# is shared and instance-agnostic.
HOME=/home/jibri
PULSE_RUNTIME_PATH="/run/pulse-${INSTANCE_INDEX}"
mkdir -p "$PULSE_RUNTIME_PATH"
chown jibri:jibri "$PULSE_RUNTIME_PATH"
export PULSE_RUNTIME_PATH HOME

# The default daemon.conf logs to /config/logs/pulse.log; rewrite
# at startup to a per-instance path via --log-target.
exec s6-setuidgid jibri /bin/bash -c \
    "PULSE_RUNTIME_PATH='$PULSE_RUNTIME_PATH' exec /usr/bin/pulseaudio \
        --log-target=file:/config/logs-${INSTANCE_INDEX}/pulse.log"
RUN

cat > /tmp/_jibri_run <<'RUN'
#!/usr/bin/with-contenv bash
. /etc/jitsi/jibri/run-prologue.sh

# we have to set HOME, otherwise chrome can't find ~/.asoundrc
HOME=/home/jibri
DISPLAY=":${INSTANCE_INDEX}"
PULSE_RUNTIME_PATH="/run/pulse-${INSTANCE_INDEX}"
export HOME DISPLAY PULSE_RUNTIME_PATH

CONFIG_FILE="/etc/jitsi/jibri/jibri-${INSTANCE_INDEX}.conf"
LOGGING_FILE="/etc/jitsi/jibri/logging-${INSTANCE_INDEX}.properties"

CHROME_BIN_PATH="$(which google-chrome)"
[ $? -ne 0 ] && CHROME_BIN_PATH="$(which chromium)"
# Pre-warm chrome so the first recording starts quickly. Each
# instance pre-warms against its own DISPLAY so the cached state
# applies when jibri actually launches chromedriver later.
#
# Note: --timeout is a chromedriver flag (not chrome's), so we wrap
# the invocation in coreutils `timeout` to bound the warm-up. If the
# Xorg for this DISPLAY isn't ready yet, we'd otherwise hang here
# indefinitely and prevent jibri from ever starting.
if [ -n "$CHROME_BIN_PATH" ]; then
    timeout 30s s6-setuidgid jibri \
        env DISPLAY="$DISPLAY" PULSE_RUNTIME_PATH="$PULSE_RUNTIME_PATH" \
        "$CHROME_BIN_PATH" --headless about:blank \
        || echo "[jibri-${INSTANCE_INDEX}] chrome pre-warm timed out or failed; continuing" >&2
fi

DAEMON="java \
    -Djava.util.logging.config.file=${LOGGING_FILE} \
    -Dconfig.file=${CONFIG_FILE} \
    -jar /opt/jitsi/jibri/jibri.jar \
    --config /etc/jitsi/jibri/config.json"
exec s6-setuidgid jibri /bin/bash -c "exec $DAEMON"
RUN

# Install the same run script in every cloned service dir.
for i in $(seq 0 $(( MAX_JIBRI_INSTANCES - 1 ))); do
    install -m 755 /tmp/_xorg_run  "/etc/services.d/15-jibri-xorg-${i}/run"
    install -m 755 /tmp/_pulse_run "/etc/services.d/16-jibri-pulse-${i}/run"
    install -m 755 /tmp/_jibri_run "/etc/services.d/17-jibri-${i}/run"
done
rm -f /tmp/_xorg_run /tmp/_pulse_run /tmp/_jibri_run

# Tell prosody about the recorder hidden domain.  The upstream
# template gates the relevant blocks on $ENABLE_RECORDING which
# we set in the Dockerfile ENV; the prosody config patches we run
# above already rewrote /config/conf.d paths into
# /config/prosody/conf.d so this works without further changes.

echo "[patches] applied successfully"
