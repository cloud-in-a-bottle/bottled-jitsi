# openhost-jitsi

[Jitsi Meet](https://meet.jit.si/) packaged as an OpenHost app.

Runs the full Jitsi stack — Prosody (XMPP), Jicofo (focus), Jitsi
Videobridge (SFU), and Nginx — in a single container supervised by
[s6-overlay](https://github.com/just-containers/s6-overlay).

## What you get

- A working Jitsi Meet instance at `https://<app>.<your-openhost-host>/`.
- Any user who can reach the URL can create rooms and join calls.
- Media flows over UDP on the public `jvb-media` port (9500 by
  default, fixed by `openhost.toml` so it's advertisable in SDP).
- Signaling (XMPP-WS, BOSH, Colibri-WS) rides the same 443 your
  OpenHost router already uses, proxied over the router's WebSocket
  passthrough.

## Architecture

OpenHost apps are strictly one image per app, so the four Jitsi
components have to live in a single container. We apt-install the
upstream Debian packages (`jitsi-meet`, `jitsi-videobridge2`, `jicofo`,
`prosody`, `nginx-full`) — the same path the official quickstart uses
— and supervise them with `s6-overlay`. At container boot,
`/etc/cont-init.d/10-configure-jitsi.sh` rewrites the installer's
generated configs to the real `PUBLIC_URL`, pins `JVB_PORT=9500`,
strips the built-in HTTPS vhost (OpenHost's Caddy terminates TLS in
front of us), and advertises the VM's public IP to the ICE harvester
so WebRTC candidates are actually reachable.

```
browser
  │  https + wss (443/tcp)
  ▼
OpenHost Caddy ───────────┐
  │                        │ plain http, WebSocket passthrough
  │                        ▼
  │                nginx :80   (container)
  │                  ├─ static SPA: /usr/share/jitsi-meet
  │                  ├─ /http-bind  ➜ prosody :5280
  │                  ├─ /xmpp-websocket ➜ prosody :5280
  │                  └─ /colibri-ws/jvb/… ➜ jvb :9090 (internal)
  │
  │   media UDP 9500  ──────────────────────────▶ jvb :9500
  └──────────────────────────────────────────────┘
                       public VM IP
```

## Ports

Declared in `openhost.toml`:

| Port       | Purpose                                            |
|------------|----------------------------------------------------|
| 80/tcp     | Container nginx; OpenHost proxies to it internally |
| 9500/udp   | JVB media; **must be reachable from the internet** |

The 9500 port is in the 9000–9999 range OpenHost permits for extra
ports. `JVB_PORT=9500` is set inside the container so Jitsi matches
what OpenHost publishes on the host.

## Required environment

Set in the OpenHost app config (Settings → Environment):

- **`PUBLIC_URL`** — the https URL users will type into their browser,
  e.g. `https://jitsi.<your-vm>/`. Used to rewrite nginx/prosody
  vhosts and the Jitsi client config. Without this the install sits at
  `localhost` and won't talk to browsers.
- **`JVB_ADVERTISE_IP`** *(strongly recommended)* — the public IPv4
  address of your OpenHost VM. JVB inserts this into SDP ICE
  candidates. If unset, JVB tries to self-discover via STUN
  (`stun.l.google.com:19302`); that usually works on public clouds but
  can fail behind corporate NAT.

Optional:

- `JVB_PORT` — override the 9500 default. If you change it you also
  need to update the `host_port` in `openhost.toml` and redeploy.

## Resource requirements

3 GB RAM / 2 CPUs (set in `openhost.toml`) is comfortable for a single
room of 5–10 participants at 720p. The dominant cost is aggregate
outbound bandwidth (~2.5 Mbps per participant, fanned out by JVB), not
CPU. Scale memory up if you expect larger rooms.

## Data

- `/data/app_data/jitsi/secrets/` — generated XMPP shared secrets for
  jicofo/jvb/prosody. Persisted so restarts don't invalidate in-flight
  sessions.
- `/data/app_data/jitsi/prosody-data/` — prosody's flat-file state
  dir, linked to `/var/lib/prosody` inside the container. Only
  populated if you enable internal auth; empty otherwise.
- `/data/app_temp_data/jitsi/` — per-boot scratch (nginx cache, JVB
  temp). Safe to nuke at any time.

## Security notes

- **Anyone with the URL can open a room.** That's how Jitsi works.
  Require a room password (set inside the meeting) or enable JWT
  auth if you want to restrict who can start a conference. The
  [secure-domain](https://jitsi.github.io/handbook/docs/devops-guide/secure-domain/)
  upstream guide walks through the latter.
- OpenHost's owner-login gate is **disabled** for this app
  (`public_paths = ["/"]` in the manifest). Participants don't have
  OpenHost accounts, so gating at the router level would block every
  guest.
- Media (DTLS-SRTP over UDP/9500) is end-to-end encrypted between the
  browser and JVB; JVB sees plaintext (it's an SFU, not an E2EE mixer).
  Turn on [E2EE](https://jitsi.github.io/handbook/docs/user-guide/e2ee/)
  in the meeting UI if you need peer-to-peer encryption.

## What's not included

- **Jibri** (recording, live-streaming) — needs host-kernel ALSA
  loopback and a headless Chrome per recording; incompatible with
  OpenHost's one-container model.
- **Jigasi** (SIP dial-in) — skipped for v1 to keep the container
  smaller. Add via another apt-installed package if needed.
- **Coturn** (TURN for clients that can't reach UDP/9500) — if your
  users are behind restrictive corporate firewalls that block outgoing
  UDP to non-standard ports, they'll fail to get media. Deploy a
  separate TURN server (either elsewhere or as a second OpenHost app)
  and wire it into the Jitsi config via `TURN_HOST`/`TURN_PORT`.

## Licensing

Jitsi Meet and its components are Apache 2.0. This wrapper repo is
released under the same license.
