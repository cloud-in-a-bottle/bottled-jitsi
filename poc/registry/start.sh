#!/bin/sh
set -eu
export REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY="${OPENHOST_APP_DATA_DIR:?}"
export REGISTRY_HTTP_ADDR=0.0.0.0:5000
export REGISTRY_HTTP_RELATIVEURLS=true
nginx -t
nginx
exec /bin/registry serve /etc/docker/registry/config.yml
