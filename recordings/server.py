"""Tiny HTTP service that backs Jitsi local-recording upload + listing.

Runs inside the openhost-jitsi container alongside the four jitsi
services (web/prosody/jicofo/jvb), listens on 127.0.0.1:5060, and is
proxied to by nginx under /api/recordings/* and /<admin_token>/*.

Threat model
------------

Two classes of endpoint:

* ``/api/recordings/{init,<id>/chunk,<id>/finalize}`` — anonymous;
  anyone in a meeting can upload. The room name is a string the
  client provides and we store but don't trust.
* ``/<admin_token>/*`` — admin endpoints, where ``<admin_token>`` is
  a 24-byte URL-safe random string (32 base64url characters)
  generated on first boot and printed to the container logs.
  Possessing the token grants list / download / delete on every
  recording, indefinitely. There is no per-recording ACL —
  recordings live or die by whoever holds the admin URL. Treat the
  admin URL like a password.

Storage
-------

Files live under ``$RECORDINGS_DIR`` (passed via env, defaults to
``$OPENHOST_APP_DATA_DIR/recordings``):

    <id>.webm   - the finished recording
    <id>.json   - {id, room, started_by, started_at, finished_at,
                   size_bytes, finalized}

While a recording is uploading, the file lives at ``<id>.webm.tmp``
and the JSON has ``finalized: false``. ``finalize`` swaps it to
``<id>.webm``. A startup sweep deletes any orphaned ``*.tmp`` files
and any JSON whose recording file is missing.

A simple total-size quota (``MAX_TOTAL_BYTES``, default 5 GiB) is
enforced by deleting the oldest ``finalized`` recordings whenever a
new chunk would push us past the cap. Tmp uploads-in-progress are
exempt from eviction so we don't trample our own writes.
"""

from __future__ import annotations

import argparse
import html
import json
import logging
import os
import re
import secrets
import shutil
import sys
import threading
import time
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, BinaryIO
from urllib.parse import parse_qs, unquote, urlparse

logger = logging.getLogger("openhost-jitsi-recordings")


# Default cap; override with $RECORDINGS_MAX_BYTES.
DEFAULT_MAX_BYTES = 5 * 1024 * 1024 * 1024  # 5 GiB
DEFAULT_CHUNK_SIZE = 5 * 1024 * 1024  # 5 MiB

# Hard upper bound on a single chunk request. The JS shim sends 5 MiB
# chunks; we cap a bit above that to leave room for a future bump
# without rolling the wire format. Without this cap a malicious or
# buggy client can claim Content-Length: <huge> in one request and
# trigger preemptive eviction of every existing finalized recording
# before sending a single byte.
MAX_CHUNK_BYTES = 16 * 1024 * 1024  # 16 MiB

# Recording IDs are URL-safe random hex; we generate them ourselves and
# never trust client input.
ID_RE = re.compile(r"^[a-f0-9]{16}$")
ROOM_RE = re.compile(r"^[A-Za-z0-9._\- ]{1,128}$")

# Lock guarding state-file mutations and quota eviction.  All file IO
# inside this lock is local-disk-only and bounded; we don't hold it
# across the multi-megabyte chunk reads themselves.
_state_lock = threading.RLock()


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _meta_path(rec_dir: Path, rec_id: str) -> Path:
    return rec_dir / f"{rec_id}.json"


def _final_path(rec_dir: Path, rec_id: str) -> Path:
    return rec_dir / f"{rec_id}.webm"


def _tmp_path(rec_dir: Path, rec_id: str) -> Path:
    return rec_dir / f"{rec_id}.webm.tmp"


def _read_meta(rec_dir: Path, rec_id: str) -> dict[str, Any] | None:
    try:
        return json.loads(_meta_path(rec_dir, rec_id).read_text())
    except FileNotFoundError:
        return None
    except json.JSONDecodeError:
        logger.warning("Corrupt metadata for %s; ignoring", rec_id)
        return None


def _write_meta(rec_dir: Path, rec_id: str, meta: dict[str, Any]) -> None:
    path = _meta_path(rec_dir, rec_id)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(meta, sort_keys=True))
    os.replace(tmp, path)


def _list_meta(rec_dir: Path) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for p in sorted(rec_dir.glob("*.json")):
        rec_id = p.stem
        if not ID_RE.fullmatch(rec_id):
            continue
        meta = _read_meta(rec_dir, rec_id)
        if meta is None:
            continue
        out.append(meta)
    out.sort(key=lambda m: m.get("started_at", ""), reverse=True)
    return out


def _total_finalized_bytes(rec_dir: Path) -> int:
    return sum(int(m.get("size_bytes", 0)) for m in _list_meta(rec_dir) if m.get("finalized"))


def _evict_until_under_cap(rec_dir: Path, headroom_bytes: int, max_bytes: int) -> None:
    """Delete oldest finalized recordings until total + headroom <= cap.

    The caller is about to write ``headroom_bytes`` more; we make
    sure that fits. Tmp uploads-in-progress are not touched.
    """
    metas = sorted(_list_meta(rec_dir), key=lambda m: m.get("finished_at") or m.get("started_at", ""))
    total = sum(int(m.get("size_bytes", 0)) for m in metas if m.get("finalized"))
    for meta in metas:
        if total + headroom_bytes <= max_bytes:
            return
        if not meta.get("finalized"):
            continue
        rec_id = meta["id"]
        size = int(meta.get("size_bytes", 0))
        # Delete the data file first; if THAT fails we keep the
        # metadata so the listing still shows the (possibly partially
        # broken) recording. If the metadata delete fails after the
        # file delete we still subtract from ``total`` because the
        # bytes are gone — the leftover .json is a small leak the
        # next sweep will catch on restart.
        try:
            _final_path(rec_dir, rec_id).unlink(missing_ok=True)
        except OSError as e:
            logger.warning("Eviction of %s data failed: %s", rec_id, e)
            continue
        try:
            _meta_path(rec_dir, rec_id).unlink(missing_ok=True)
        except OSError as e:
            logger.warning("Eviction of %s metadata failed (file already deleted): %s", rec_id, e)
        total -= size
        logger.info("Evicted %s (%d bytes) to make room", rec_id, size)


def _sweep_orphans(rec_dir: Path) -> None:
    """At startup: drop any *.tmp / *.json.tmp files and any metadata
    whose recording file is missing."""
    for pattern in ("*.webm.tmp", "*.json.tmp"):
        for p in rec_dir.glob(pattern):
            try:
                p.unlink()
                logger.info("Removed orphan %s", p.name)
            except OSError as e:
                logger.warning("Could not remove orphan %s: %s", p.name, e)
    for p in rec_dir.glob("*.json"):
        rec_id = p.stem
        if not ID_RE.fullmatch(rec_id):
            continue
        meta = _read_meta(rec_dir, rec_id)
        if meta is None:
            continue
        if meta.get("finalized") and not _final_path(rec_dir, rec_id).exists():
            try:
                p.unlink()
                logger.info("Removed metadata for missing recording %s", rec_id)
            except OSError as e:
                logger.warning("Could not remove orphan metadata %s: %s", p.name, e)


def _new_rec_id() -> str:
    return secrets.token_hex(8)


def _load_or_create_admin_token(token_path: Path) -> str:
    if token_path.exists():
        token = token_path.read_text().strip()
        if token:
            return token
    token = secrets.token_urlsafe(24)
    token_path.parent.mkdir(parents=True, exist_ok=True)
    token_path.write_text(token)
    try:
        token_path.chmod(0o600)
    except OSError as e:
        # Token file is potentially world-readable; warn loudly so an
        # operator noticing odd permissions has an audit trail.
        logger.warning("Could not chmod admin token file %s to 0600: %s", token_path, e)
    return token


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------


class _State:
    """Per-server state shared by handler instances via a class attr."""

    def __init__(
        self,
        rec_dir: Path,
        admin_token: str,
        max_bytes: int,
        public_origin_hint: str | None,
    ) -> None:
        self.rec_dir = rec_dir
        self.admin_token = admin_token
        self.max_bytes = max_bytes
        # Used only to tell users in the recordings page where the
        # download links live; if empty we fall back to relative URLs.
        self.public_origin_hint = public_origin_hint or ""


class _Handler(BaseHTTPRequestHandler):
    state: _State  # set before serving

    server_version = "openhost-jitsi-recordings/1"

    # Silence the default per-request stderr logging; we log
    # explicitly for the requests we care about.
    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002, D401
        return

    # -- helpers ------------------------------------------------------------

    def _json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _error(self, status: int, message: str) -> None:
        self._json(status, {"error": message})

    def _read_json_body(self, max_bytes: int = 64 * 1024) -> dict[str, Any] | None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None
        if length <= 0 or length > max_bytes:
            return None
        try:
            data = self.rfile.read(length)
        except OSError:
            return None
        try:
            payload = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None
        return payload if isinstance(payload, dict) else None

    # -- routing ------------------------------------------------------------

    def do_GET(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler API)
        url = urlparse(self.path)
        path = url.path

        # Admin endpoints under /<token>/...
        admin_match = re.match(r"^/([^/]+)/?(.*)$", path)
        if admin_match and secrets.compare_digest(admin_match.group(1), self.state.admin_token):
            tail = admin_match.group(2)
            return self._handle_admin_get(tail, parse_qs(url.query))

        if path == "/api/recordings/health":
            return self._json(200, {"ok": True})

        return self._error(HTTPStatus.NOT_FOUND, "not found")

    def do_POST(self) -> None:  # noqa: N802
        url = urlparse(self.path)
        path = url.path

        if path == "/api/recordings/init":
            return self._handle_init()

        chunk_match = re.match(r"^/api/recordings/([a-f0-9]{16})/chunk$", path)
        if chunk_match:
            return self._handle_chunk(chunk_match.group(1))

        finalize_match = re.match(r"^/api/recordings/([a-f0-9]{16})/finalize$", path)
        if finalize_match:
            return self._handle_finalize(finalize_match.group(1))

        return self._error(HTTPStatus.NOT_FOUND, "not found")

    def do_DELETE(self) -> None:  # noqa: N802
        url = urlparse(self.path)
        path = url.path
        admin_match = re.match(r"^/([^/]+)/recording/([a-f0-9]{16})$", path)
        if admin_match and secrets.compare_digest(admin_match.group(1), self.state.admin_token):
            rec_id = admin_match.group(2)
            return self._handle_admin_delete(rec_id)
        return self._error(HTTPStatus.NOT_FOUND, "not found")

    # -- handlers: anonymous upload path -----------------------------------

    def _handle_init(self) -> None:
        body = self._read_json_body() or {}
        room = str(body.get("room", "")).strip()
        started_by = str(body.get("started_by", "")).strip()[:64] or "anonymous"
        if not ROOM_RE.fullmatch(room):
            return self._error(HTTPStatus.BAD_REQUEST, "invalid room")

        rec_id = _new_rec_id()
        meta = {
            "id": rec_id,
            "room": room,
            "started_by": started_by,
            "started_at": _now_iso(),
            "finished_at": None,
            "size_bytes": 0,
            "finalized": False,
        }
        with _state_lock:
            _tmp_path(self.state.rec_dir, rec_id).touch()
            _write_meta(self.state.rec_dir, rec_id, meta)
        logger.info("init recording %s in room %r by %r", rec_id, room, started_by)
        return self._json(200, {"id": rec_id, "chunk_size": DEFAULT_CHUNK_SIZE})

    def _handle_chunk(self, rec_id: str) -> None:
        if not ID_RE.fullmatch(rec_id):
            return self._error(HTTPStatus.BAD_REQUEST, "invalid id")
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self._error(HTTPStatus.BAD_REQUEST, "invalid Content-Length")
        if length <= 0:
            return self._error(HTTPStatus.BAD_REQUEST, "empty chunk")
        if length > MAX_CHUNK_BYTES:
            return self._error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, f"chunk too large (max {MAX_CHUNK_BYTES})")

        with _state_lock:
            meta = _read_meta(self.state.rec_dir, rec_id)
            if meta is None:
                return self._error(HTTPStatus.NOT_FOUND, "no such recording")
            if meta.get("finalized"):
                return self._error(HTTPStatus.CONFLICT, "already finalized")
            tmp = _tmp_path(self.state.rec_dir, rec_id)
            if not tmp.exists():
                return self._error(HTTPStatus.GONE, "recording gone")
            _evict_until_under_cap(self.state.rec_dir, length, self.state.max_bytes)

        # Stream the body to disk in fixed-size reads. We don't hold
        # the lock here — append-only writes to the tmp file are
        # safe because chunk requests for the same rec_id are
        # serialized by the client (one MediaRecorder, one upload
        # loop). If a peer raced, the worst case is interleaved
        # bytes; metadata stays consistent.
        try:
            written = self._stream_to_file(tmp, length)
        except OSError as e:
            logger.exception("write failed for %s", rec_id)
            return self._error(HTTPStatus.INTERNAL_SERVER_ERROR, f"write failed: {e}")

        with _state_lock:
            meta = _read_meta(self.state.rec_dir, rec_id) or meta
            meta["size_bytes"] = int(meta.get("size_bytes", 0)) + written
            _write_meta(self.state.rec_dir, rec_id, meta)
        return self._json(200, {"ok": True, "received": written, "total": meta["size_bytes"]})

    def _handle_finalize(self, rec_id: str) -> None:
        if not ID_RE.fullmatch(rec_id):
            return self._error(HTTPStatus.BAD_REQUEST, "invalid id")
        with _state_lock:
            meta = _read_meta(self.state.rec_dir, rec_id)
            if meta is None:
                return self._error(HTTPStatus.NOT_FOUND, "no such recording")
            if meta.get("finalized"):
                return self._json(200, {"ok": True, "already_finalized": True})
            tmp = _tmp_path(self.state.rec_dir, rec_id)
            final = _final_path(self.state.rec_dir, rec_id)
            if not tmp.exists():
                return self._error(HTTPStatus.GONE, "recording gone")
            try:
                os.replace(tmp, final)
                size = final.stat().st_size
                meta["finished_at"] = _now_iso()
                meta["size_bytes"] = size
                meta["finalized"] = True
                _write_meta(self.state.rec_dir, rec_id, meta)
            except OSError as e:
                # If the rename succeeded but the metadata write failed,
                # the .webm exists on disk but the JSON still says
                # finalized=False. The next admin DELETE or startup
                # sweep will eventually clean it up; we surface 500 so
                # the client can retry finalize, which is a no-op for
                # the rename and only re-attempts the metadata write.
                logger.exception("finalize failed for %s", rec_id)
                return self._error(HTTPStatus.INTERNAL_SERVER_ERROR, f"finalize failed: {e}")
        logger.info("finalized recording %s (%d bytes)", rec_id, meta["size_bytes"])
        return self._json(200, {"ok": True})

    def _stream_to_file(self, path: Path, length: int) -> int:
        """Copy ``length`` bytes from rfile to the end of ``path``."""
        copied = 0
        # Open in append mode; multiple chunks accumulate.
        with path.open("ab") as out:
            remaining = length
            while remaining > 0:
                buf = self.rfile.read(min(64 * 1024, remaining))
                if not buf:
                    raise OSError("client disconnected mid-chunk")
                out.write(buf)
                copied += len(buf)
                remaining -= len(buf)
        return copied

    # -- handlers: admin path ----------------------------------------------

    def _handle_admin_get(self, tail: str, query: dict[str, list[str]]) -> None:
        # /<token>/        → HTML listing
        # /<token>/recording/<id> → file download
        if tail == "" or tail == "/":
            return self._render_listing()
        m = re.match(r"^recording/([a-f0-9]{16})$", tail)
        if m:
            return self._serve_recording(m.group(1))
        return self._error(HTTPStatus.NOT_FOUND, "not found")

    def _handle_admin_delete(self, rec_id: str) -> None:
        with _state_lock:
            meta = _read_meta(self.state.rec_dir, rec_id)
            if meta is None:
                return self._error(HTTPStatus.NOT_FOUND, "no such recording")
            for p in (
                _final_path(self.state.rec_dir, rec_id),
                _tmp_path(self.state.rec_dir, rec_id),
                _meta_path(self.state.rec_dir, rec_id),
            ):
                try:
                    p.unlink(missing_ok=True)
                except OSError as e:
                    logger.warning("delete %s: %s", p, e)
        return self._json(200, {"ok": True})

    def _serve_recording(self, rec_id: str) -> None:
        meta = _read_meta(self.state.rec_dir, rec_id)
        if meta is None or not meta.get("finalized"):
            return self._error(HTTPStatus.NOT_FOUND, "not found")
        path = _final_path(self.state.rec_dir, rec_id)
        # Open before reading the size so the size we send in the
        # Content-Length header matches the bytes we'll actually
        # stream. A concurrent DELETE between stat and open would
        # otherwise either truncate the response or surface as an
        # unhandled OSError after headers are already sent.
        try:
            fh = path.open("rb")
        except FileNotFoundError:
            return self._error(HTTPStatus.NOT_FOUND, "not found")

        try:
            size = os.fstat(fh.fileno()).st_size
            room = meta.get("room", "recording")
            safe_room = re.sub(r"[^A-Za-z0-9._-]", "_", room)
            ts = (meta.get("started_at", "") or "").replace(":", "-")
            download_name = f"{safe_room}_{ts}.webm"

            self.send_response(200)
            self.send_header("Content-Type", "video/webm")
            self.send_header("Content-Length", str(size))
            self.send_header("Content-Disposition", f'attachment; filename="{download_name}"')
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            try:
                shutil.copyfileobj(fh, self.wfile, length=64 * 1024)
            except (BrokenPipeError, ConnectionResetError):
                # Client gave up mid-download; nothing actionable.
                pass
        finally:
            fh.close()

    def _render_listing(self) -> None:
        recordings = _list_meta(self.state.rec_dir)
        total_bytes = sum(int(m.get("size_bytes", 0)) for m in recordings if m.get("finalized"))
        rows = []
        for m in recordings:
            if not m.get("finalized"):
                state = "uploading"
                action = ""
            else:
                state = "ready"
                action = (
                    f'<a href="recording/{m["id"]}">download</a> '
                    f'<a href="#" onclick="del(\'{m["id"]}\');return false">delete</a>'
                )
            size_mb = f'{m.get("size_bytes", 0) / 1_000_000:.1f}'
            rows.append(
                "<tr>"
                f'<td>{html.escape(m.get("room", ""))}</td>'
                f'<td>{html.escape(m.get("started_at", ""))}</td>'
                f'<td>{html.escape(m.get("started_by", ""))}</td>'
                f'<td style="text-align:right">{size_mb} MB</td>'
                f"<td>{state}</td>"
                f"<td>{action}</td>"
                "</tr>"
            )
        body = LISTING_HTML.format(
            rows="\n".join(rows) or '<tr><td colspan="6" style="text-align:center;color:#888">No recordings yet.</td></tr>',
            total_mb=f"{total_bytes / 1_000_000:.1f}",
            cap_mb=f"{self.state.max_bytes / 1_000_000:.0f}",
            count=len(recordings),
        )
        encoded = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)


LISTING_HTML = """<!doctype html>
<html><head>
<meta charset="utf-8">
<title>Jitsi Recordings</title>
<style>
body {{ font-family: -apple-system, system-ui, sans-serif; max-width: 1100px; margin: 2em auto; padding: 0 1em; color: #222; }}
h1 {{ margin-bottom: 0.2em; }}
.summary {{ color: #666; margin-bottom: 1.5em; }}
table {{ border-collapse: collapse; width: 100%; }}
th, td {{ border-bottom: 1px solid #ddd; padding: 0.5em 0.6em; text-align: left; }}
th {{ background: #f5f5f5; font-weight: 600; font-size: 0.9em; }}
a {{ color: #0366d6; text-decoration: none; }}
a:hover {{ text-decoration: underline; }}
</style>
</head><body>
<h1>Jitsi Recordings</h1>
<div class="summary">{count} recording(s), {total_mb} MB used of {cap_mb} MB cap.</div>
<table>
<thead><tr>
<th>Room</th><th>Started</th><th>Started by</th><th>Size</th><th>State</th><th></th>
</tr></thead>
<tbody>
{rows}
</tbody></table>
<script>
async function del(id) {{
  if (!confirm('Delete this recording permanently?')) return;
  const r = await fetch('recording/' + id, {{method: 'DELETE'}});
  if (r.ok) location.reload();
  else alert('Delete failed: HTTP ' + r.status);
}}
</script>
</body></html>
"""


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--rec-dir", required=True, type=Path)
    p.add_argument("--admin-token-file", required=True, type=Path)
    p.add_argument("--port", type=int, default=5060)
    p.add_argument("--bind", default="127.0.0.1")
    p.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
    p.add_argument("--public-origin-hint", default="")
    return p.parse_args(argv)


def run(args: argparse.Namespace) -> None:
    args.rec_dir.mkdir(parents=True, exist_ok=True)
    _sweep_orphans(args.rec_dir)
    admin_token = _load_or_create_admin_token(args.admin_token_file)
    state = _State(
        rec_dir=args.rec_dir,
        admin_token=admin_token,
        max_bytes=args.max_bytes,
        public_origin_hint=args.public_origin_hint,
    )
    _Handler.state = state
    server = ThreadingHTTPServer((args.bind, args.port), _Handler)
    listing_url = f"/{admin_token}/"
    if state.public_origin_hint:
        listing_url = f"{state.public_origin_hint.rstrip('/')}{listing_url}"
    logger.info("listening on %s:%s", args.bind, args.port)
    logger.info("recordings listing URL (keep secret): %s", listing_url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    args = parse_args(argv)
    run(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
