# Jitsi prebuilt-image benchmark

## Method

Compare the original source build at `ae737d9` against this branch's thin
Dockerfile, which pulls a digest-pinned copy of that same built image and
overlays app scripts. Each cold deployment runs on a separate freshly
provisioned vm-manager Hetzner CPX41 VM (8 shared vCPU, 16 GiB RAM), in
Hillsboro. Both paths retain the existing Jitsi manifest, including its
6500 MiB memory limit, 4500 millicore CPU limit, and two recording workers.

Wait for the default apps to finish building, and verify the image inventory
contains no Jitsi images. The clock starts immediately before POST `/api/add_app`, including repository
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

## Results — 2026-10-05

All times are seconds from the deployment request. Two independent cold VMs
per path; this is a small PoC sample, not a statistical performance study.

| Milestone | Source 1 | Source 2 | Prebuilt 1 | Prebuilt 2 |
| --- | ---: | ---: | ---: | ---: |
| Deploy accepted (clone finished) | 5.671 | 3.088 | 4.282 | 3.187 |
| Platform running | 146.842 | 133.985 | 28.382 | 28.481 |
| Actual frontend + BOSH ready | 149.570 | 136.677 | 31.087 | 31.183 |
| Videobridge registered with Jicofo | 152.1 | 139.2 | 32.9 | 33.4 |
| Both recording workers available | 181.3 | 168.3 | 62.1 | 62.8 |

Mean frontend/signaling startup: **143.1 s → 31.1 s**, a **4.60× speedup**,
**78.2% reduction**, and **112.0 s saved per fresh deployment**.

The `running` flag is slightly earlier than actual frontend readiness, and
Jibri's Chrome warm-up continues after conferencing starts. Recording-worker
availability improves from approximately **174.8 s to 62.5 s** on average;
prebuilding does not eliminate that runtime warm-up.

Frontend timings use a local monotonic clock. The videobridge/recording rows
come from timestamped container logs: Jicofo's first `Added new videobridge`
and the second `JibriDetector` notification with `available = true`.
Those rows use a UTC start timestamp recorded to whole seconds, so allow
approximately one second of timestamp precision, plus any host clock skew.

The four VMs took 9.6–17.3 minutes from creation to an authenticated dashboard,
including provisioning, GitHub checkout, first-boot setup, and automation
retries. Those are not controlled provisioning benchmarks and are excluded
from the Jitsi measurements. The additional default-app settling period is
also excluded from the app startup clock.

### Exact inputs and image costs

- Cloud in a Bottle on all four VMs: `1d5ab2ee1d28497979cbb393f1a1a2ab85fac7c6`.
- Baseline Jitsi: `ae737d9d832d673ffb60eb6f53288ed9f6603113`.
- Tested PoC Jitsi: `5a1379d8266d543abbec5000e30249428fa5d80c`.
- Registry image: `jitsi-poc-registry.1.bottle.cloud/jitsi/prebuilt@sha256:4720bdc301f42485789d972e76e7769c3b335a55358d9867df873a2e83baa280`.
- Registry payload: 1,035,332,648 compressed layer bytes (62 layers).
- Full image: 2,220,586,729 bytes uncompressed; thin final image:
  2,220,756,587 bytes. The editable script layer adds about 170 kB.
- Publishing the already-built baseline image took 24.5 s, through a temporary
  SSH-protected publishing connection. That one-time cost is excluded from
  the cold-pull measurements.
- No platform or Jitsi manifest/resource changes were made for the test.

### Verification results

- Both source-build installs and both cold-pull installs reached all listed
  startup milestones.
- All four reported one operational videobridge, HTTP 200 from JVB's health
  endpoint, and two available Jibri workers.
- Three-client browser calls passed on source 1 and prebuilt 1, with P2P
  disabled. Every client had a connected videobridge peer connection and
  received nonzero audio and video bytes. No Jitsi API errors were reported.
- Image environment variables, entrypoint, command, exposed ports, and volumes
  were identical across all four final images.
- Public registry GET/HEAD succeeded; POST/PUT/PATCH/DELETE returned 403.
- Restarting the registry preserved the published, digest-pinned image.

### Cleanup

All four benchmark VMs (`jitsi-img-1005-build`, `-build2`, `-pull`, and `-pull2`)
were torn down and verified `terminated` in vm-manager. The temporary publisher
relay and SSH tunnels were stopped. The read-only registry on `1.bottle.cloud`
is intentionally retained so this branch remains deployable. Only the
`andrew/jitsi-prebuilt-image-poc` branch was pushed; main was unchanged and no
pull request was created.

### Reproduce

Provision separate fresh amd64 VMs of the same type, finish setup, and wait
for the default apps to settle. Use Cloud in a Bottle's `@ref` URL syntax:

```sh
# On the baseline instance:
bottle app deploy --name jitsi \
  https://github.com/cloud-in-a-bottle/bottled-jitsi@ae737d9d832d673ffb60eb6f53288ed9f6603113

# On a different, cold instance:
bottle app deploy --name jitsi \
  https://github.com/cloud-in-a-bottle/bottled-jitsi@andrew/jitsi-prebuilt-image-poc
```

For timing, start a monotonic clock before deployment and poll the app's `/`,
`/config.js`, and `/http-bind` endpoints. A successful platform health check
alone is insufficient: `/` initially serves the hostname-discovery listener.
Check the real Jitsi HTML and the Prosody response before stopping the clock.
Use the container logs for bridge and recording-worker registration times.
Run a three-participant call with P2P disabled to verify actual bridge media.
