# Jitsi prebuilt-image benchmark

## Method

Compare the original source build at `ae737d9` against this branch's thin
Dockerfile, which pulls a digest-pinned copy of that same built image and
overlays app scripts. Each cold deployment runs on a separate freshly
provisioned vm-manager Hetzner CPX41 VM (8 shared vCPU, 16 GiB RAM), in
Hillsboro. Both paths retain the existing Jitsi manifest, including its
6500 MiB memory limit, 4500 millicore CPU limit, and two recording workers.

The clock starts immediately before POST `/api/add_app`, including repository
clone, image download/build, container creation, and first-boot configuration.
Poll the public app URL once per second to trigger hostname discovery. Record:

- Deploy accepted: `/api/add_app` returned successfully.
- Platform running: Cloud in a Bottle reports `running`.
- Frontend ready: the actual Jitsi HTML loads (not the temporary hostname
  discovery page).
- Frontend and BOSH ready: `config.js` and the Prosody BOSH endpoint also respond.

VM provisioning and Cloud in a Bottle setup are outside the application startup
clock. Building/publishing the registry image is a one-time publisher cost and
is also outside the cold-pull clock. Cold-pull deployments include the entire
registry download; the image is never preloaded on those VMs.

The source image from the first baseline VM is pushed as an image, never as a
container commit, so no first-boot hostname, passwords, or runtime app data are
published. The unchanged full build is retained as `Dockerfile.prebuilt`.

The registry runs on `1.bottle.cloud` behind Cloud in a Bottle's HTTP proxy.
Results measure that topology and current upstream package/CDN performance;
they are not a guarantee for a different registry, region, or machine type.

## Functional verification

Separate from the startup clock, open three Chromium clients with fake camera
and microphone input, disable Jitsi P2P mode, join the same room, and check that
the Jitsi Videobridge peer connection connects and receives media. This checks
the conferencing backend rather than just the landing page.

## Results

Measurements will be added after the fresh-instance runs finish.
