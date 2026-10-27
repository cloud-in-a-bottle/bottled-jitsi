# Jitsi Meet — all-in-one container.
#
# Approach: take the four *official* Jitsi Docker images (jitsi/web,
# jitsi/prosody, jitsi/jicofo, jitsi/jvb), install their Debian
# packages into one combined image, and overlay the official
# rootfs/ config templates from each image so prosody, jicofo, jvb
# and nginx all come up in the same container under the existing
# s6-overlay + tpl templating machinery.
#
# We target the `stable-9955` release tag. This matches the upstream
# jitsi-meet Debian package versions (1.0.9955+).
#
# Why not install the Debian packages ourselves (as the earlier
# version of this app did)?  Because the upstream `jitsi-meet-prosody`
# postinst script doesn't set `http_default_host` or
# `trusted_proxies` on prosody, which makes BOSH / XMPP-WS return 404
# when proxied from nginx. The docker-image templates DO set these
# correctly (see prosody/rootfs/defaults/conf.d/jitsi-meet.cfg.lua
# line 77 and prosody/rootfs/defaults/prosody.cfg.lua line 154).

ARG JITSI_TAG=stable-9955

# Named stages we'll COPY rootfs trees from.
FROM jitsi/web:${JITSI_TAG} AS web-src
FROM jitsi/prosody:${JITSI_TAG} AS prosody-src
FROM jitsi/jicofo:${JITSI_TAG} AS jicofo-src
FROM jitsi/jvb:${JITSI_TAG} AS jvb-src
FROM jitsi/jibri:${JITSI_TAG} AS jibri-src

# Final image inherits from jitsi/base-java which already has:
#   * s6-overlay v1 at /init (stage-2 init: cont-init.d -> services.d)
#   * /usr/bin/tpl template renderer (jitsi/tpl v1.4.0)
#   * /usr/bin/{apt-dpkg-wrap,apt-cleanup} helper wrappers
#   * the jitsi/stable apt repo + debian bookworm-backports
#   * openjdk-17 (needed for jicofo + jvb)
#   * a cont-init that sets /etc/localtime from TZ
FROM jitsi/base-java:${JITSI_TAG}

ARG DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------- packages
#
# Add the prosody.im apt repo (prosody's default Debian package is too
# old for Jitsi 13; the official jitsi/prosody image installs from this
# repo and we match), then install every runtime daemon in one layer
# so each package's postinst creates its users and groups correctly.
#
# jitsi-meet-prosody's postinst is run only to pull in the plugin
# bundle; we immediately clear /etc/prosody afterwards since the
# docker-jitsi-meet templates drop fresh configs into /config at boot
# and we don't want the postinst-generated /etc/prosody cluttering
# things up.

RUN curl -sSL https://prosody.im/files/prosody-debian-packages.key | \
        gpg --dearmor -o /usr/share/keyrings/prosody.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/prosody.gpg] https://packages.prosody.im/debian bookworm main" \
        > /etc/apt/sources.list.d/prosody.list

RUN apt-dpkg-wrap apt-get update && \
    apt-dpkg-wrap apt-get install -y --no-install-recommends \
        dnsutils cron socat curl jq nginx-extras \
        python3 openssl \
        jitsi-meet-web \
        lua5.4 prosody \
        lua-cyrussasl lua-inspect lua-ldap lua-luaossl lua-sec lua-unbound \
        libldap-common sasl2-bin libsasl2-modules-ldap \
        jicofo \
        jitsi-videobridge2 iproute2 libpcap0.8 \
        jibri \
        libgl1-mesa-dri pulseaudio dbus dbus-x11 rtkit \
        unzip fonts-noto fonts-noto-cjk libcap2-bin \
        xserver-xorg-core xserver-xorg-video-dummy \
        x11-xserver-utils icewm procps \
        libatk1.0-0 libatk-bridge2.0-0 libcups2 libxcomposite1 \
        libxdamage1 libxfixes3 libxrandr2 libgbm1 libxkbcommon0 \
        libpangocairo-1.0-0 libpango-1.0-0 libcairo2 libnss3 \
        libnspr4 libdrm2 libasound2 libgtk-3-0 libdbus-1-3 \
        ca-certificates xdg-utils && \
    apt-cleanup && \
    rm -rf /var/lib/apt/lists/* && \
    adduser jibri rtkit

# Pull jitsi-meet-prosody's plugin bundle without running the
# package's postinst (which assumes an interactive debconf run and
# an already-working prosody). Matches what jitsi/prosody does.
RUN apt-dpkg-wrap apt-get update && \
    apt-dpkg-wrap apt-get -d install -y jitsi-meet-prosody && \
    dpkg -x /var/cache/apt/archives/jitsi-meet-prosody*.deb /tmp/pkg && \
    rm -f /tmp/pkg/usr/share/jitsi-meet/prosody-plugins/mod_smacks.lua && \
    mv /tmp/pkg/usr/share/jitsi-meet/prosody-plugins /prosody-plugins && \
    rm -rf /tmp/pkg /var/cache/apt/archives/*.deb /var/lib/apt/lists/* && \
    mkdir -p /prosody-plugins-custom /prosody-plugins-contrib && \
    chown -R prosody:prosody /prosody-plugins /prosody-plugins-custom /prosody-plugins-contrib

# The apt-installed /etc/prosody/*.cfg.lua files are a red herring:
# our boot-time cont-init renders fresh configs into /config/prosody/
# from the docker-image templates and points prosody at those via
# --config. But we keep /etc/prosody itself around because prosodyctl
# looks for some helper files there. Just clear out the VirtualHost
# definitions to make sure they don't accidentally leak into prosody's
# state.
RUN rm -rf /etc/prosody/conf.avail /etc/prosody/conf.d /etc/prosody/prosody.cfg.lua && \
    rm -f /etc/nginx/sites-enabled/default && \
    rm -rf /etc/nginx/conf.d/*

# ---------------------------------------------------------------- luarocks bits
#
# The prosody image builds a few lua modules (basexx, lua-cjson,
# net-url) from luarocks in a separate builder stage. We copy the
# result straight out of jitsi/prosody rather than rebuilding.

COPY --from=prosody-src /usr/local/lib/lua/5.4/   /usr/local/lib/lua/5.4/
COPY --from=prosody-src /usr/local/share/lua/5.4/ /usr/local/share/lua/5.4/

# ---------------------------------------------------------------- rootfs overlay
#
# Copy the official /defaults, /etc/cont-init.d, /etc/services.d
# trees. The colliding 10-config names get renamed so s6 runs them
# all, in a deterministic order (prosody first -- it registers users
# and mints certs the other services depend on).

# prosody -------------------------------------------------------------
COPY --from=prosody-src /defaults/prosody.cfg.lua         /defaults/prosody.cfg.lua
COPY --from=prosody-src /defaults/conf.d/                 /defaults/conf.d/
COPY --from=prosody-src /defaults/rules.d/                /defaults/rules.d/
COPY --from=prosody-src /defaults/saslauthd.conf          /defaults/saslauthd.conf
COPY --from=prosody-src /etc/sasl/                        /etc/sasl/
COPY --from=prosody-src /etc/services.d/prosody/          /etc/services.d/prosody/
COPY --from=prosody-src /etc/services.d/10-saslauthd/     /etc/services.d/10-saslauthd/
COPY --from=prosody-src /etc/cont-init.d/10-config        /etc/cont-init.d/10-prosody-config

# jicofo --------------------------------------------------------------
COPY --from=jicofo-src  /defaults/jicofo.conf             /defaults/jicofo.conf
COPY --from=jicofo-src  /defaults/logging.properties      /defaults/jicofo-logging.properties
COPY --from=jicofo-src  /etc/services.d/jicofo/           /etc/services.d/jicofo/
COPY --from=jicofo-src  /etc/cont-init.d/10-config        /etc/cont-init.d/11-jicofo-config

# jvb -----------------------------------------------------------------
COPY --from=jvb-src     /defaults/jvb.conf                /defaults/jvb.conf
COPY --from=jvb-src     /defaults/logging.properties      /defaults/jvb-logging.properties
COPY --from=jvb-src     /etc/services.d/jvb/              /etc/services.d/jvb/
COPY --from=jvb-src     /etc/cont-init.d/10-config        /etc/cont-init.d/12-jvb-config

# jibri ---------------------------------------------------------------
# Pull the headless Chrome binary, chromedriver, and shm-check probe
# from the upstream jibri image rather than reinstalling them — saves
# ~150MB of layer churn and pins us to the same Chrome version
# upstream tested with stable-9955.
COPY --from=jibri-src /opt/google                          /opt/google
COPY --from=jibri-src /usr/bin/chromedriver                /usr/bin/chromedriver
COPY --from=jibri-src /usr/bin/shm-check                   /usr/bin/shm-check
# google-chrome is normally a symlink via /etc/alternatives in the
# jibri image; in our image we install a wrapper script that strips
# chromedriver's --enable-automation switch (which Selenium injects
# unconditionally and which produces the "Chrome is being controlled
# by automated test software" infobar in jibri recordings).  See
# openhost-bootstrap/google-chrome-wrapper.sh for the rationale.
COPY openhost-bootstrap/google-chrome-wrapper.sh /usr/bin/google-chrome
RUN chmod +x /usr/bin/google-chrome && \
    ln -sf google-chrome /usr/bin/google-chrome-stable
# Defaults templates
COPY --from=jibri-src /defaults/jibri.conf                 /defaults/jibri.conf
COPY --from=jibri-src /defaults/xmpp.conf                  /defaults/jibri-xmpp.conf
COPY --from=jibri-src /defaults/logging.properties         /defaults/jibri-logging.properties
COPY --from=jibri-src /defaults/xorg-video-dummy.conf      /defaults/xorg-video-dummy.conf
# Services + cont-init
COPY --from=jibri-src /etc/services.d/10-xorg/             /etc/services.d/15-jibri-xorg/
COPY --from=jibri-src /etc/services.d/30-pulse/            /etc/services.d/16-jibri-pulse/
COPY --from=jibri-src /etc/services.d/40-jibri/            /etc/services.d/17-jibri/
COPY --from=jibri-src /etc/cont-init.d/10-config           /etc/cont-init.d/16-jibri-config
# jibri also wants a small dotfile in $HOME for ALSA loopback,
# pulse config, and the icewm config the upstream image relies on.
# The COPY preserves contents but not ownership, so we re-chown
# to the jibri user (the apt postinst created jibri:jibri).
COPY --from=jibri-src /home/jibri/                         /home/jibri/
RUN chown -R jibri:jibri /home/jibri

# web -----------------------------------------------------------------
COPY --from=web-src     /defaults/default                 /defaults/nginx-default.conf
COPY --from=web-src     /defaults/nginx.conf              /defaults/nginx.conf
COPY --from=web-src     /defaults/meet.conf               /defaults/meet.conf
COPY --from=web-src     /defaults/ssl.conf                /defaults/ssl.conf
COPY --from=web-src     /defaults/ffdhe2048.txt           /defaults/ffdhe2048.txt
COPY --from=web-src     /defaults/system-config.js        /defaults/system-config.js
COPY --from=web-src     /defaults/settings-config.js      /defaults/settings-config.js
COPY --from=web-src     /defaults/interface_config.js     /defaults/interface_config.js
COPY --from=web-src     /etc/services.d/nginx/            /etc/services.d/nginx/
COPY --from=web-src     /etc/cont-init.d/10-config        /etc/cont-init.d/13-web-config

# ---------------------------------------------------------------- patches
#
# Each service's upstream cont-init assumes `/config` is *its own*
# directory. Since we're running four services in one container we
# split them into `/config/prosody`, `/config/jicofo`, `/config/jvb`,
# and `/config/web`, then rewrite the cont-init + run scripts to
# match. Simpler than trying to coordinate a shared `/config`.
COPY patches/ /tmp/patches/
RUN bash /tmp/patches/apply-patches.sh && rm -rf /tmp/patches

# ---------------------------------------------------------------- openhost glue
#
# One bespoke cont-init of our own runs before any of the others and
# discovers the OpenHost-assigned public hostname from the first
# incoming HTTP request. The value is cached to /config/hostname so
# subsequent boots skip this. It also sets defaults for variables the
# upstream templates require that we don't want the operator to have
# to set manually (JICOFO_AUTH_PASSWORD, JVB_AUTH_PASSWORD, etc.).
COPY openhost-bootstrap/ /opt/openhost-jitsi/
COPY openhost-bootstrap/00-openhost-config.sh /etc/cont-init.d/00-openhost-config

# ---------------------------------------------------------------- recordings
#
# Browser-side local-recording with server-side persistence. A small
# Python sidecar (server.py) accepts chunked uploads and serves the
# resulting .webm files behind an admin-token URL. A JS shim
# injected via body.html intercepts Jitsi's saveRecording download
# and uploads the blob to the sidecar instead. Detailed design lives
# in recordings/server.py and recordings/recording-upload.js.
COPY recordings/server.py /opt/openhost-recordings/server.py
COPY recordings/recordings-init.sh /etc/cont-init.d/14-recordings-init
COPY recordings/recording-upload.js /usr/share/jitsi-meet/static/openhost-recordings.js
COPY recordings/body.html /usr/share/jitsi-meet/body.html
COPY recordings/jibri-finalize.sh /opt/openhost-recordings/jibri-finalize.sh

RUN chmod +x /etc/cont-init.d/* /opt/openhost-jitsi/*.sh /opt/openhost-recordings/jibri-finalize.sh /etc/services.d/*/run 2>/dev/null || true

# ---------------------------------------------------------------- runtime
EXPOSE 80
# ENABLE_XMPP_WEBSOCKET=0: the OpenHost router's WebSocket proxy
# accepts the client handshake without echoing the client's requested
# subprotocol (it calls Quart's client_ws.accept() without passing
# subprotocols through). Strict WebSocket clients -- including the
# lib-jitsi-meet browser client -- treat a missing
# Sec-WebSocket-Protocol response header as a protocol violation
# and close the connection. We disable XMPP-over-WebSocket in the
# rendered config.js and fall back to BOSH (HTTP long-polling), which
# still works through OpenHost's HTTP proxy path. This is slightly
# slower for signaling than WebSocket but indistinguishable to
# end users.
ENV DISABLE_HTTPS=1 \
    ENABLE_HTTP_REDIRECT=0 \
    ENABLE_IPV6=0 \
    XMPP_SERVER=127.0.0.1 \
    XMPP_BOSH_URL_BASE=http://127.0.0.1:5280 \
    DISABLE_COLIBRI_WEBSOCKET_JVB_LOOKUP=1 \
    ENABLE_COLIBRI_WEBSOCKET=0 \
    ENABLE_XMPP_WEBSOCKET=0 \
    DISABLE_POLLS=1 \
    TZ=UTC \
    ENABLE_RECORDING=1 \
    MAX_PARALLEL_RECORDINGS=2 \
    DISPLAY=:0 \
    JIBRI_RECORDER_USER=recorder \
    JIBRI_XMPP_USER=jibri \
    XMPP_RECORDER_DOMAIN=recorder.meet.jitsi \
    XMPP_HIDDEN_DOMAIN=recorder.meet.jitsi \
    JIBRI_BREWERY_MUC=jibribrewery \
    XMPP_INTERNAL_MUC_DOMAIN=internal-muc.meet.jitsi \
    XMPP_DOMAIN=meet.jitsi \
    XMPP_AUTH_DOMAIN=auth.meet.jitsi \
    XMPP_MUC_DOMAIN=muc.meet.jitsi \
    XMPP_GUEST_DOMAIN=guest.meet.jitsi \
    JIBRI_FINALIZE_RECORDING_SCRIPT_PATH=/opt/openhost-recordings/jibri-finalize.sh

VOLUME ["/config"]

# ENTRYPOINT ["/init"] is inherited from jitsi/base.
