# Jitsi Meet — all four components in one container.
#
# The official Jitsi project distributes an "official" Docker deployment
# that uses docker-compose to run four separate containers. OpenHost's
# model is strictly one-image-per-app, so we merge the four services
# into a single container using the upstream Debian packages (the same
# packages the apt quick-start guide uses) and supervise them with
# s6-overlay.
#
# The trick that makes this small: Debian's post-install scripts
# (jitsi-meet-web-config, jitsi-videobridge2, jicofo, prosody) read
# debconf answers to generate every required config file. We pre-seed
# debconf with a placeholder hostname at build time, then entrypoint.sh
# rewrites the hostname in the generated files at runtime once we know
# the real public URL. That way we don't have to hand-maintain config
# templates the size of the upstream docker-jitsi-meet repo.

FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG S6_OVERLAY_VERSION=3.2.0.2

# -----------------------------------------------------------------------------
# Base packages: a JDK (for prosody/jicofo/jvb dependencies), plus tooling
# we need for config rewriting at runtime (jq for JSON, sed/awk, envsubst,
# gettext-base provides envsubst).

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg2 \
        apt-transport-https \
        lsb-release \
        openjdk-17-jre-headless \
        gettext-base \
        jq \
        xz-utils \
        procps \
        iproute2 \
        dnsutils \
        sudo \
        debconf-utils \
        python3 \
        netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# Add the Prosody and Jitsi apt repositories. Prosody's bookworm has 0.12.x
# which Jitsi needs for the lobby/websocket features. The Jitsi repo hosts
# jitsi-videobridge2, jicofo, and jitsi-meet itself.

RUN curl -sSL https://prosody.im/files/prosody-debian-packages.key \
        -o /usr/share/keyrings/prosody-debian-packages.key && \
    echo "deb [signed-by=/usr/share/keyrings/prosody-debian-packages.key] http://packages.prosody.im/debian bookworm main" \
        > /etc/apt/sources.list.d/prosody-debian-packages.list

RUN curl -sSL https://download.jitsi.org/jitsi-key.gpg.key \
        | gpg --dearmor > /usr/share/keyrings/jitsi-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/jitsi-keyring.gpg] https://download.jitsi.org stable/" \
        > /etc/apt/sources.list.d/jitsi-stable.list

# -----------------------------------------------------------------------------
# Preseed debconf so jitsi-meet installs non-interactively. Hostname is a
# placeholder; entrypoint.sh rewrites all generated files to the real
# value on first boot. We opt for the self-signed cert path because
# OpenHost's Caddy terminates real TLS in front of us -- we never serve
# TLS directly from nginx inside this container.

# Use a placeholder hostname that doesn't collide with prosody's
# built-in "localhost" VirtualHost -- the "invalid" TLD is RFC-guaranteed
# to never resolve. cont-init.d rewrites it to the real value on boot.
RUN echo "jitsi-videobridge jitsi-videobridge/jvb-hostname string meet.invalid" | debconf-set-selections && \
    echo "jitsi-meet jitsi-meet/jvb-hostname string meet.invalid" | debconf-set-selections && \
    echo "jitsi-meet-web-config jitsi-meet/jvb-hostname string meet.invalid" | debconf-set-selections && \
    echo "jitsi-meet-web-config jitsi-meet/cert-choice select Generate a new self-signed certificate (You will later get a chance to obtain a Let's encrypt certificate)" | debconf-set-selections && \
    echo "jicofo jitsi-videobridge/jvb-hostname string meet.invalid" | debconf-set-selections

# Install prosody first (not as part of jitsi-meet) so its postinst
# completes cleanly and puts /etc/prosody/prosody.cfg.lua in place.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        lua5.2 \
        prosody \
        nginx-full \
    && rm -rf /var/lib/apt/lists/*

# jitsi-meet-prosody's postinst tries to call prosodyctl, which in
# turn needs /etc/prosody/prosody.cfg.lua to resolve the host it's
# about to configure. Make sure the expected conf.d include directive
# is present (prosody 13 upstream has it, but earlier Debian builds
# don't).
RUN if ! grep -q 'Include "conf.d/\*.cfg.lua"' /etc/prosody/prosody.cfg.lua; then \
        printf '\nInclude "conf.d/*.cfg.lua"\n' >> /etc/prosody/prosody.cfg.lua; \
    fi && \
    mkdir -p /etc/prosody/conf.avail /etc/prosody/conf.d

# Now install jitsi-meet, which pulls in jitsi-meet-prosody,
# jitsi-meet-web-config, jitsi-videobridge2, jicofo, etc.
RUN apt-get update && \
    apt-get install -y --no-install-recommends jitsi-meet && \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# Remove the systemd units the packages dropped (we don't run systemd),
# disable nginx's default HTTPS listener (OpenHost terminates TLS), and
# make jicofo/prosody/jvb log to stdout so s6 can capture them.

RUN rm -f /lib/systemd/system/jitsi-videobridge2.service \
          /lib/systemd/system/jicofo.service \
          /lib/systemd/system/prosody.service

# -----------------------------------------------------------------------------
# Install s6-overlay for process supervision. Each jitsi service gets a
# tiny run script under /etc/services.d/, and the entrypoint rewrites
# configs in /etc/cont-init.d before the services start.

ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp/
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-x86_64.tar.xz /tmp/
RUN tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz && \
    tar -C / -Jxpf /tmp/s6-overlay-x86_64.tar.xz && \
    rm /tmp/s6-overlay-*.tar.xz

# -----------------------------------------------------------------------------
# Our config rewriter + s6 service definitions. See rootfs/ for the
# full layout.

COPY rootfs/ /

RUN chmod +x /etc/cont-init.d/*.sh \
             /usr/local/lib/jitsi/discover_hostname.py \
             /etc/services.d/*/run \
             /etc/services.d/*/finish

# -----------------------------------------------------------------------------
# The web container serves the Jitsi SPA on port 80 (OpenHost proxies
# TLS to us). JVB_PORT (9500/udp by default) is media and is bound
# separately via [[ports]] in openhost.toml.
EXPOSE 80

ENV S6_CMD_WAIT_FOR_SERVICES=1 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=120000 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2

ENTRYPOINT ["/init"]
