# Jitsi Meet — all-in-one container.
#
# Approach: take the *official* Jitsi Docker images (ghcr.io/jitsi/web,
# prosody, jicofo, jvb, jibri), install their Debian packages into one
# combined image built on ghcr.io/jitsi/base-java, and copy each image's
# config templates (/defaults) and s6-overlay v3 service definitions in, so
# prosody, jicofo, jvb, nginx and jibri all come up in one container from
# the same templates and scripts upstream ships and tests.
#
# We target the `stable-11248-1` release tag. The Debian packages come from
# the jitsi stable apt repo (and packages.prosody.im for prosody), pinned
# below to the versions installed in that release's images.
#
# Since stable-11146 upstream runs every service as the unprivileged `s6`
# user (uid 1000) on a read-only root with a tmpfs /run. Cloud in a Bottle
# bind-mounts the app data dir idmapped to container root, so this image
# keeps s6-overlay running as root: our cont-init scripts (bootstrap,
# recordings, jibri) run as root, and every upstream service and config
# oneshot is started as `s6` (see patches/apply-patches.sh).

# Every jitsi image is pinned to the stable-11248-1 tag *and* its multi-arch
# index digest, so a re-pointed tag can't change what we build. The digest is
# what's enforced (a tag next to a digest is ignored), so a bump changes both
# on every line below, including the base-java FROM. Upstream publishes to
# GHCR only since stable-11146 (jitsi/docker-jitsi-meet#2271).

# Named stages we'll COPY templates, scripts and binaries from.
FROM ghcr.io/jitsi/web:stable-11248-1@sha256:12980b5e55eba7b0543a8030910ae60736aa3fdf777d4c3c58348bc6af917f43 AS web-src
FROM ghcr.io/jitsi/prosody:stable-11248-1@sha256:ccd795568ab4096edb624ca53490f2d8702ac16622df37a391dc29f664f24710 AS prosody-src
FROM ghcr.io/jitsi/jicofo:stable-11248-1@sha256:470a471e052d7d5e8b62b2ccab2b639d3e5e0b3344388439fb3ec8cd8c441e86 AS jicofo-src
FROM ghcr.io/jitsi/jvb:stable-11248-1@sha256:d2f546c8e11e6fb77285df854b0d131aab04dcaf98da946a9d16b2f03b86badb AS jvb-src
FROM ghcr.io/jitsi/jibri:stable-11248-1@sha256:b0ccc0133a9c6289797a34666fdef4c987f851727cb4d750e768781f08a2a94e AS jibri-src

# Final image inherits from jitsi/base-java which already has:
#   * Debian trixie
#   * s6-overlay v3 at /init (base bundle incl. legacy cont-init.d, then the
#     s6-rc `user` bundle, then legacy services.d)
#   * /usr/bin/tpl template renderer (jitsi/tpl v1.5.0)
#   * /usr/bin/{apt-dpkg-wrap,apt-cleanup,check-writable,setup-custom-ca}
#   * the jitsi/stable apt repo + debian trixie-backports
#   * openjdk-21 (needed for jicofo, jvb and jibri)
#   * the unprivileged `s6` user every service runs as
FROM ghcr.io/jitsi/base-java:stable-11248-1@sha256:b2b6a189edb3396c8d525f8640bce1984c9a339a2cf9044af7f950282d4220a9

USER root
ARG DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------- packages
#
# The prosody.im apt repo (trixie suite) and its signing key, exactly as the
# jitsi/prosody image ships them.
COPY --from=prosody-src /etc/apt/sources.list.d/prosody.sources /etc/apt/sources.list.d/prosody.sources
COPY --from=prosody-src /usr/share/keyrings/prosody.gpg /usr/share/keyrings/prosody.gpg

# One layer with every runtime daemon, so each package's postinst creates its
# users and groups correctly. The lists mirror the upstream Dockerfiles
# (web, prosody, jicofo, jvb, jibri) minus what we don't run (acme.sh, the
# autoscaler sidecar, rclone, upload integrations), plus python3 for our
# bootstrap and recordings sidecar.
#
# Packages from the third-party jitsi and prosody.im apt repos are pinned to
# exact versions (what the stable-11248-1 images have installed), so a new
# upstream package can't slip into a rebuild. Bump them together with the
# image digests.
#
# lua-inspect: stable-11248-1's prosody image dropped it, but the bundled
# prosody plugins still `require "inspect"` (mod_auth_token fails to load
# without it; jitsi/docker-jitsi-meet#2346, reverted in stable-11248-2). We
# keep installing it.
RUN apt-dpkg-wrap apt-get update && \
    apt-dpkg-wrap apt-get install -y \
        `# web` \
        dnsutils jq nginx-extras socat \
        jitsi-meet-web=1.0.9442-1 \
        `# prosody` \
        lua5.4 prosody=13.0.7-1~trixie2 \
        libldap-common sasl2-bin libsasl2-modules-ldap \
        lua-cyrussasl lua-inspect lua-ldap lua-luaossl lua-sec lua-unbound \
        `# jicofo` \
        jicofo=1.0-1205-1 \
        `# jvb` \
        curl iproute2 libpcap0.8 \
        jitsi-videobridge2=2.3-318-gbf271b11f-1 \
        `# jibri (chrome comes from the jibri image below)` \
        jibri=8.0-235-g87bcd3c-1 \
        dbus dbus-x11 fonts-noto fonts-noto-cjk \
        libatk-bridge2.0-0 libatk1.0-0 libatspi2.0-0 libcap2-bin \
        libgl1-mesa-dri libgtk-3-0 procps pulseaudio rtkit unzip \
        `# ours` \
        python3 openssl && \
    `# base-java ships Node.js 20 (EOL) only for the autoscaler sidecar, which` \
    `# we don't run (jitsi/docker-jitsi-meet#2348); drop it.` \
    apt-dpkg-wrap apt-get purge -y nodejs && \
    rm /etc/apt/sources.list.d/nodejs.sources && \
    dpkg-query -W jitsi-meet-web prosody jicofo jitsi-videobridge2 jibri && \
    apt-cleanup

# Filesystem tweaks the upstream Dockerfiles make after installing.
RUN set -eux; \
    # prosody: upstream patches prosody 13 to skip IDNA domain verification
    # (jitsi/docker-jitsi-meet#2197) and gives the s6 user its data dir.
    grep -q idna_to_ascii /usr/share/lua/5.4/prosody/util/jid.lua; \
    sed -i '/idna_to_ascii/d' /usr/share/lua/5.4/prosody/util/jid.lua; \
    rm -rf /etc/prosody; \
    chown s6:s6 /var/lib/prosody /var/run/saslauthd; \
    echo "TLS_REQCERT allow" >> /etc/ldap/ldap.conf; \
    # web: interface_config.js is served from /run/web/config, rendered from
    # the copy in /defaults (taken from the web image below)
    rm /usr/share/jitsi-meet/interface_config.js; \
    ln -s /run/web/.well-known /usr/share/jitsi-meet/.well-known; \
    rm -f /etc/nginx/conf.d/default.conf /etc/nginx/sites-enabled/default; \
    rm -rf /var/lib/nginx && ln -s /run/web/tmp /var/lib/nginx; \
    # jibri: config is rendered into /run/jibri/config at boot
    rm -rf /etc/jitsi/jibri && ln -s /run/jibri/config /etc/jitsi/jibri; \
    rm -rf /var/log/jitsi/jibri && ln -s /storage/logs /var/log/jitsi/jibri; \
    rm -rf /home/jibri; \
    # shared
    usermod -a -G prosody,sasl,audio,jibri,jitsi,rtkit,video s6; \
    mkdir -p /storage /config; \
    chown s6:s6 /storage

# ---------------------------------------------------------------- prosody
#
# luarocks modules (basexx, lua-cjson, net-url) built in the prosody image's
# builder stage, and the plugin trees it assembles: jitsi-meet-prosody's
# plugins plus upstream's vendored ones (mod_http_health, which
# register-setup polls), the matrix plugin, and jitsi-contrib's plugins.
COPY --from=prosody-src /usr/local/lib/lua/5.4/   /usr/local/lib/lua/5.4/
COPY --from=prosody-src /usr/local/share/lua/5.4/ /usr/local/share/lua/5.4/
COPY --from=prosody-src /prosody-plugins/         /prosody-plugins/
COPY --from=prosody-src /prosody-plugins-contrib/ /prosody-plugins-contrib/
COPY --from=prosody-src /defaults/                /defaults/
COPY --from=prosody-src /etc/sasl/                /etc/sasl/
RUN mkdir -p /prosody-plugins-custom

# ---------------------------------------------------------------- jicofo, jvb
#
# logging.properties collides between jicofo, jvb and jibri, so each goes
# in under a prefixed name; apply-patches.sh points the scripts at it.
COPY --from=jicofo-src /defaults/jicofo.conf          /defaults/jicofo.conf
COPY --from=jicofo-src /defaults/logging.properties   /defaults/jicofo-logging.properties
COPY --from=jvb-src    /defaults/jvb.conf             /defaults/jvb.conf
COPY --from=jvb-src    /defaults/logging.properties   /defaults/jvb-logging.properties

# ---------------------------------------------------------------- web
COPY --from=web-src /defaults/ /defaults/

# ---------------------------------------------------------------- jibri
#
# Chrome and chromedriver (a matched chrome-for-testing build), the shm-check
# probe, and Chrome's managed policies (incl. the distrusted eMudhra CA keys)
# come straight from the jibri image, so we run the Chrome upstream tested.
COPY --from=jibri-src /opt/chrome/                  /opt/chrome/
COPY --from=jibri-src /usr/bin/chromedriver         /usr/bin/chromedriver
COPY --from=jibri-src /usr/bin/shm-check            /usr/bin/shm-check
COPY --from=jibri-src /etc/opt/chrome/              /etc/opt/chrome/
COPY --from=jibri-src /etc/pulse/default.pa         /etc/pulse/default.pa
# The s6 user's home: .asoundrc, icewm config, the pulse config that the jibri
# config step copies to ~/.config, and the ~/.cache, ~/.config, ~/.local
# symlinks into /run/tmp.
COPY --from=jibri-src --chown=s6:s6 /home/s6/       /home/s6/
COPY --from=jibri-src /defaults/jibri.conf          /defaults/jibri.conf
COPY --from=jibri-src /defaults/xmpp.conf           /defaults/jibri-xmpp.conf
COPY --from=jibri-src /defaults/logging.properties  /defaults/jibri-logging.properties
COPY --from=jibri-src /defaults/xorg-video-dummy.conf /defaults/xorg-video-dummy.conf
# google-chrome is a symlink to /opt/chrome/chrome in the jibri image; in our
# image it is a wrapper that strips chromedriver's --enable-automation switch
# (which produces the "Chrome is being controlled by automated test software"
# infobar in recordings) and picks the right X display per jibri instance.
# See openhost-bootstrap/google-chrome-wrapper.sh.
COPY openhost-bootstrap/google-chrome-wrapper.sh /usr/bin/google-chrome
RUN chmod +x /usr/bin/google-chrome && \
    ln -sf google-chrome /usr/bin/google-chrome-stable && \
    if ldd /opt/chrome/chrome | grep 'not found'; then echo "chrome is missing libraries" >&2; exit 1; fi

# ---------------------------------------------------------------- services
#
# Upstream's s6-rc service definitions and the scripts they run, one tree per
# image. apply-patches.sh merges them into /etc/s6-overlay, renaming the
# colliding `10-config` oneshots and `config` scripts per service, starts
# every upstream service as the s6 user, and installs our per-instance jibri
# services.
COPY --from=prosody-src /etc/s6-overlay/ /tmp/upstream/prosody/
COPY --from=jicofo-src  /etc/s6-overlay/ /tmp/upstream/jicofo/
COPY --from=jvb-src     /etc/s6-overlay/ /tmp/upstream/jvb/
COPY --from=web-src     /etc/s6-overlay/ /tmp/upstream/web/
COPY patches/ /tmp/patches/
RUN bash /tmp/patches/apply-patches.sh && rm -rf /tmp/patches /tmp/upstream

# ---------------------------------------------------------------- openhost glue
#
# Legacy cont-init.d scripts run as root inside s6-overlay's `base` bundle,
# before any upstream service. 00-openhost-config discovers the public
# hostname from the first incoming HTTP request (cached in app data), loads
# or generates the shared secrets, and exports the env vars the upstream
# templates need.
COPY openhost-bootstrap/ /opt/openhost-jitsi/
COPY openhost-bootstrap/00-openhost-config.sh /etc/cont-init.d/00-openhost-config
COPY openhost-bootstrap/20-jibri-config.sh /etc/cont-init.d/20-jibri-config

# ---------------------------------------------------------------- recordings
#
# Browser-side local-recording with server-side persistence. A small
# Python sidecar (server.py) accepts chunked uploads and serves the
# resulting files behind an admin-token URL. A JS shim injected via
# body.html intercepts Jitsi's saveRecording download and uploads the
# blob to the sidecar instead; Jibri's finalize script uploads its MP4s
# the same way. Detailed design lives in recordings/server.py and
# recordings/recording-upload.js.
COPY recordings/server.py /opt/openhost-recordings/server.py
COPY recordings/recordings-init.sh /etc/cont-init.d/10-recordings-init
COPY recordings/recording-upload.js /usr/share/jitsi-meet/static/openhost-recordings.js
COPY recordings/body.html /usr/share/jitsi-meet/body.html
COPY recordings/jibri-finalize.sh /opt/openhost-recordings/jibri-finalize.sh

RUN chmod +x /etc/cont-init.d/* /opt/openhost-jitsi/*.sh /opt/openhost-recordings/jibri-finalize.sh

# ---------------------------------------------------------------- runtime
# nginx listens on 8000 (upstream moved to unprivileged ports in
# stable-11146); cloudinabottle.toml routes the app to it.
EXPOSE 8000
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
#
# No CSP_HEADER: upstream's Content-Security-Policy header (stable-10741)
# is opt-in and off by default, and we leave it off.
ENV DISABLE_HTTPS=1 \
    ENABLE_HTTP_REDIRECT=0 \
    ENABLE_IPV6=0 \
    XMPP_SERVER=127.0.0.1 \
    XMPP_BOSH_URL_BASE=http://127.0.0.1:5280 \
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
    JIBRI_RECORDING_DIR=/storage/recordings \
    JIBRI_FINALIZE_RECORDING_SCRIPT_PATH=/opt/openhost-recordings/jibri-finalize.sh

# ENTRYPOINT ["/init"] is inherited from jitsi/base. We stay root (upstream
# ends with USER s6); see the note at the top.
USER root
