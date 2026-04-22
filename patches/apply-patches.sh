#!/bin/bash
# Patches the official docker-jitsi-meet cont-init + service scripts
# to use per-service /config subdirectories instead of a shared
# /config root. Run at image build time.
set -euo pipefail

# --------------------------------------------------------------- prosody
# Prosody expects /config/{prosody.cfg.lua,conf.d,certs,data}. Move
# them under /config/prosody/.
sed -i \
    -e 's#/config/prosody\.cfg\.lua#/config/prosody/prosody.cfg.lua#g' \
    -e 's#/config/data#/config/prosody/data#g' \
    -e 's#/config/certs#/config/prosody/certs#g' \
    -e 's#/config/conf\.d#/config/prosody/conf.d#g' \
    -e 's#/config/rules\.d#/config/prosody/rules.d#g' \
    -e 's#chown -R prosody /config\b#chown -R prosody /config/prosody#g' \
    -e 's#cp -r /defaults/\* /config$#mkdir -p /config/prosody \&\& cp -r /defaults/prosody.cfg.lua /defaults/conf.d /config/prosody/#g' \
    -e 's#stat -c %U /config#stat -c %U /config/prosody#g' \
    /etc/cont-init.d/10-prosody-config
sed -i 's#/config/prosody\.cfg\.lua#/config/prosody/prosody.cfg.lua#g' \
    /etc/services.d/prosody/run

# --------------------------------------------------------------- jicofo
# jicofo expects /config/jicofo.conf and /config/logging.properties.
# We also renamed logging.properties to jicofo-logging.properties in
# /defaults so it doesn't clash with jvb's copy.
sed -i \
    -e 's#/config/jicofo\.conf#/config/jicofo/jicofo.conf#g' \
    -e 's#/config/logging\.properties#/config/jicofo/logging.properties#g' \
    -e 's#tpl /defaults/logging\.properties#tpl /defaults/jicofo-logging.properties#g' \
    -e 's#chown -R jicofo:jitsi /config#chown -R jicofo:jitsi /config/jicofo#g' \
    -e 's#mkdir -p /config$#mkdir -p /config/jicofo#g' \
    -e 's#/defaults/jicofo\.conf\b#/defaults/jicofo.conf#g' \
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
sed -i \
    -e 's#/config/jvb\.conf#/config/jvb/jvb.conf#g' \
    -e 's#/config/logging\.properties#/config/jvb/logging.properties#g' \
    -e 's#tpl /defaults/logging\.properties#tpl /defaults/jvb-logging.properties#g' \
    -e 's#chown -R jvb:jitsi /config#chown -R jvb:jitsi /config/jvb#g' \
    -e 's#mkdir -p /config$#mkdir -p /config/jvb#g' \
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
sed -i \
    -e 's#/config/{nginx/site-confs,keys}#/config/web/nginx/site-confs /config/web/keys#g' \
    -e 's#/config/nginx\b#/config/web/nginx#g' \
    -e 's#/config/keys\b#/config/web/keys#g' \
    -e 's#/config/acme\b#/config/web/acme#g' \
    -e 's#/config/acme-certs\b#/config/web/acme-certs#g' \
    -e 's#/config/config\.js\b#/config/web/config.js#g' \
    -e 's#/config/custom-config\.js\b#/config/web/custom-config.js#g' \
    -e 's#/config/interface_config\.js\b#/config/web/interface_config.js#g' \
    -e 's#/config/custom-interface_config\.js\b#/config/web/custom-interface_config.js#g' \
    -e 's#tpl /defaults/default\b#tpl /defaults/nginx-default.conf#g' \
    -e 's#chown -R www-data /config#chown -R www-data /config/web#g' \
    /etc/cont-init.d/13-web-config
# The web cont-init builds /config/nginx/site-confs and emits
# /config/nginx/site-confs/default. After our rewrite this lands in
# /config/web/nginx/site-confs/default, which needs to reference the
# (now relocated) meet.conf at /config/web/nginx/meet.conf -- the
# template uses 'include /config/nginx/meet.conf' as literal text in
# the rendered file. Keep it pointing at /config/web/nginx/meet.conf.
# The template rendering already rewrote this via the sed above
# because the literal 'config/nginx/meet.conf' inside meet.conf.tpl
# isn't present (meet.conf is included via /config/nginx/site-confs/default
# which IS the rendered nginx-default.conf, and our sed rewrote its
# include paths too when the tpl output is captured).
# BUT: /defaults/nginx-default.conf still contains the string
# 'include /config/nginx/meet.conf' literal -- tpl itself does not
# substitute that. Patch the defaults file too.
sed -i 's#include /config/nginx/meet\.conf#include /config/web/nginx/meet.conf#g' \
    /defaults/nginx-default.conf
sed -i 's#include /config/nginx/ssl\.conf#include /config/web/nginx/ssl.conf#g' \
    /defaults/nginx-default.conf
sed -i 's#include /config/nginx/site-confs/\*#include /config/web/nginx/site-confs/*#g' \
    /defaults/nginx.conf

sed -i 's#/config/nginx/nginx\.conf#/config/web/nginx/nginx.conf#g' \
    /etc/services.d/nginx/run

# Make sure every services.d run script inherits container env. The
# upstream jvb run uses /bin/bash but with `with-contenv bash` the
# env var forwarding works; we don't need to change that.

echo "[patches] applied successfully"
