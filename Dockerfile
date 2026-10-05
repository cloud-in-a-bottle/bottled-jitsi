# The expensive upstream assembly is published with Dockerfile.prebuilt.
# Replace the digest after rebuilding; never use a floating tag for deployment.
FROM jitsi-poc-registry.1.bottle.cloud/jitsi/prebuilt@sha256:4720bdc301f42485789d972e76e7769c3b335a55358d9867df873a2e83baa280

# Keep app-owned runtime scripts editable without rebuilding the heavy image.
# Changes to upstream versions or patches/ require republishing the base.
COPY openhost-bootstrap/ /opt/openhost-jitsi/
COPY openhost-bootstrap/00-openhost-config.sh /etc/cont-init.d/00-openhost-config
COPY openhost-bootstrap/google-chrome-wrapper.sh /usr/bin/google-chrome
COPY recordings/server.py /opt/openhost-recordings/server.py
COPY recordings/recordings-init.sh /etc/cont-init.d/14-recordings-init
COPY recordings/recording-upload.js /usr/share/jitsi-meet/static/openhost-recordings.js
COPY recordings/body.html /usr/share/jitsi-meet/body.html
COPY recordings/jibri-finalize.sh /opt/openhost-recordings/jibri-finalize.sh
RUN chmod +x /etc/cont-init.d/00-openhost-config /etc/cont-init.d/14-recordings-init \
    /opt/openhost-jitsi/*.sh /usr/bin/google-chrome \
    /opt/openhost-recordings/jibri-finalize.sh

# Runtime defaults, exposed port, volume, and /init are inherited unchanged.
