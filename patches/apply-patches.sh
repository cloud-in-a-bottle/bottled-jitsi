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

# Make sure every services.d run script inherits container env. The
# upstream jvb run uses /bin/bash but with `with-contenv bash` the
# env var forwarding works; we don't need to change that.

echo "[patches] applied successfully"
