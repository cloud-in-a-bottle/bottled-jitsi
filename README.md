# openhost-jitsi

[Jitsi Meet](https://meet.jit.si/) packaged as an OpenHost app.

Runs the full Jitsi stack — Prosody (XMPP), Jicofo (focus), Jitsi
Videobridge (SFU), and Nginx — in a single container supervised by
[s6-overlay](https://github.com/just-containers/s6-overlay). The
image is assembled by merging the rootfs trees of the four official
`jitsi/web`, `jitsi/prosody`, `jitsi/jicofo`, and `jitsi/jvb`
container images, so the tpl-rendered configs are exactly those
upstream maintains and tests.

## What you get

- `https://<app>.<your-openhost-host>/` — the standard Jitsi Meet web
  UI. Pick a room name, click **Start meeting**, share the URL.
- Works with standard Jitsi Meet client apps (desktop, iOS, Android)
  since the server speaks vanilla BOSH / XMPP-WebSocket / Colibri.
- Self-contained: no external TURN/STUN/coturn required on the
  happy path. JVB self-discovers its public IP via a static mapping
  or STUN and advertises it in ICE candidates.

## Architecture

```
 browser
    │  https + wss  (443/tcp)                 media UDP (9500/udp)
    ▼                                                      │
 OpenHost Caddy  ─── plain http/ws ───▶ nginx :80          │
                                         │                 │
                                         ▼                 │
                                       meet.conf           │
                                         ├── /http-bind ─▶ prosody :5280
                                         ├── /xmpp-ws   ─▶ prosody :5280
                                         └── static JS (Jitsi SPA)
                                                          ▲│
                                                   XMPP   ││
                                                   :5222  ││
                                                 jicofo ──┤│
                                                 jvb ─────┘│
                                                            │
                                                        browser◀
```

All four services live in one container. `/config/{prosody,jicofo,jvb,web}`
are per-service subdirs so their `chown -R` lines don't fight each
other. `s6-overlay` supervises the four services via the exact same
`run` scripts the upstream jitsi/* images ship, after a build-time
sed pass to retarget `/config/...` paths into the per-service subdirs.

## Ports

Declared in `openhost.toml`:

| Port       | Purpose                                            |
|------------|----------------------------------------------------|
| 80/tcp     | Container nginx; OpenHost proxies to it internally |
| 9500/udp   | JVB media; **must be reachable from the internet** |

The 9500 port is in the 9000–9999 range OpenHost permits for extra
ports. `JVB_PORT=9500` is set inside the container so Jitsi matches
what OpenHost publishes on the host. If you change the port, update
both the manifest `host_port` and the `JVB_PORT` env var and
redeploy.

## First-boot hostname discovery

OpenHost does not currently inject the app's public hostname as an
env var. On first boot, cont-init runs a one-shot HTTP listener on
port 80 that captures `X-Forwarded-Host` from the first incoming
request, caches it to `$OPENHOST_APP_DATA_DIR/hostname`, and uses
that for all Jitsi config rendering. Subsequent boots skip the
discovery step. If you'd rather set it explicitly, provide
`PUBLIC_URL=https://...` as an env var.

## Shared secrets

`$OPENHOST_APP_DATA_DIR/secrets/` holds the three inter-service
XMPP passwords (`JICOFO_AUTH_PASSWORD`, `JICOFO_COMPONENT_SECRET`,
`JVB_AUTH_PASSWORD`). They're auto-generated on first boot and
reused forever. Prosody's flat-file user db in
`$OPENHOST_APP_DATA_DIR/prosody-data/` (effectively `/config/prosody/data`
inside the container) persists the registered focus + jvb users so
services stay authenticated across restarts.

## Resource requirements

3 GB RAM / 2 CPUs (set in `openhost.toml`) is comfortable for a
single room with 5–10 participants at 720p. The dominant cost is
aggregate outbound bandwidth (~2.5 Mbps per participant, fanned out
by JVB), not CPU. Bump memory if you expect larger rooms.

## Security notes

- **Anyone with the URL can open a room.** OpenHost's owner-login
  gate is disabled for this app (`public_paths = ["/"]`) because
  participants are typically random people you invited, not
  OpenHost account holders. If you want to lock it down, enable
  Jitsi's [secure-domain](https://jitsi.github.io/handbook/docs/devops-guide/secure-domain/)
  mode via `ENABLE_AUTH=1` (not yet exposed as a first-class env var
  in this wrapper — edit the Dockerfile ENV block).
- Media (DTLS-SRTP over UDP/9500) is end-to-end encrypted between
  browsers and JVB. JVB sees plaintext (SFU semantics). Turn on
  [E2EE](https://jitsi.github.io/handbook/docs/user-guide/e2ee/) in
  the meeting UI if you need peer-to-peer encryption.

## What's not included

- **Jibri** (recording, live-streaming) — requires host kernel ALSA
  loopback and a headless Chrome per recording; not feasible in
  OpenHost's one-container-per-app model.
- **Jigasi** (SIP dial-in) — skipped for v1.
- **External coturn** — if your users are behind restrictive
  firewalls that block outgoing UDP to non-443 ports, they will
  fail to get media through. Deploy a coturn separately and wire it
  in via `TURN_HOST`/`TURN_PORT` env vars (exposed by the upstream
  prosody template).
- **Colibri WebSocket** — disabled (`ENABLE_COLIBRI_WEBSOCKET=0`).
  JVB falls back to WebRTC DataChannels over SCTP, which works fine.
  Re-enabling would require more work to wire up the nginx
  `/colibri-ws/...` regex to a colocated JVB on 127.0.0.1.

## Licensing

Jitsi Meet and its components are Apache 2.0. This wrapper repo is
distributed under the same license.
