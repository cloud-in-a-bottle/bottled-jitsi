# PoC registry

This directory is a standalone Cloud in a Bottle app. Copy it to the instance
and deploy its local directory URL, or put its contents at a repository root.
The benchmark registry is deployed on `1.bottle.cloud` as `jitsi-poc-registry`.

Nginx exposes only GET/HEAD under `/v2/` on the app's normal HTTP port. Other
methods return 403. The writable registry listens on port 5000 inside the
container's network namespace, with no published host port. Publishing uses
an owner-controlled SSH tunnel into that namespace. Never expose that
internal port publicly. The deployment requires no public upload credentials.

Registry data uses `OPENHOST_APP_DATA_DIR`. Keep this app and its data while
the PoC branch is in use. Removing it makes cold deployment of the pinned
image fail; images already cached on existing instances remain available.

The temporary publishing relay and SSH tunnels are stopped after publishing.
The public endpoint is read-only even while publishing is taking place.

Keep `keepalive_timeout 0` in nginx: with persistent backend connections,
concurrent large-blob responses through this instance's app proxy could deliver
their bytes but stall at the end of the response until the 75-second keep-alive
timeout. Closing the registry-facing HTTP connection avoids that interaction.
