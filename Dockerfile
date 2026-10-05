# The expensive upstream assembly is published with Dockerfile.prebuilt.
# Replace the digest after rebuilding; never use a floating tag for deployment.
FROM jitsi-poc-registry.1.bottle.cloud/jitsi/prebuilt@sha256:e0c094470302cdbb4c3a2550db6752a02d4a3bb3152c9c4e1337c2eb551bd347

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
