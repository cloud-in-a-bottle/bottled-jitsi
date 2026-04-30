"""End-to-end tests for the recordings sidecar.

We spin up the real ThreadingHTTPServer on a free port and drive it
with urllib. No mocks except where we want to inject crash conditions.
"""

from __future__ import annotations

import json
import shutil
import socket
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest

import server as rec_server


def _free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]
    finally:
        s.close()


@pytest.fixture
def running_server(tmp_path: Path):
    """Start the real server on a free port; tear it down after the test."""
    rec_dir = tmp_path / "rec"
    rec_dir.mkdir()
    token_file = tmp_path / "admin_token"
    port = _free_port()

    state = rec_server._State(
        rec_dir=rec_dir,
        admin_token=rec_server._load_or_create_admin_token(token_file),
        max_bytes=10 * 1024 * 1024,  # 10 MiB cap to keep tests bounded
        public_origin_hint="",
    )
    rec_server._Handler.state = state

    from http.server import ThreadingHTTPServer

    httpd = ThreadingHTTPServer(("127.0.0.1", port), rec_server._Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{port}"

    yield {"base": base, "rec_dir": rec_dir, "state": state, "token": state.admin_token}

    httpd.shutdown()
    httpd.server_close()
    thread.join(timeout=5)


def _post_json(url: str, body: dict) -> tuple[int, dict]:
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode("utf-8") or "{}")


def _post_bytes(url: str, payload: bytes) -> tuple[int, dict]:
    req = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/octet-stream"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode("utf-8") or "{}")


def _get(url: str) -> tuple[int, bytes, dict]:
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            return resp.status, resp.read(), dict(resp.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)


def _delete(url: str) -> int:
    req = urllib.request.Request(url, method="DELETE")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code


# ---- happy path -----------------------------------------------------------


def test_full_upload_lifecycle(running_server):
    base = running_server["base"]
    token = running_server["token"]

    # init
    code, body = _post_json(f"{base}/api/recordings/init", {"room": "test-room", "started_by": "alice"})
    assert code == 200
    rec_id = body["id"]
    assert len(rec_id) == 16

    # upload two chunks
    payload1 = b"hello "
    payload2 = b"world\n"
    code, body = _post_bytes(f"{base}/api/recordings/{rec_id}/chunk", payload1)
    assert code == 200
    assert body["received"] == len(payload1)
    code, body = _post_bytes(f"{base}/api/recordings/{rec_id}/chunk", payload2)
    assert code == 200
    assert body["total"] == len(payload1) + len(payload2)

    # finalize
    req = urllib.request.Request(
        f"{base}/api/recordings/{rec_id}/finalize", data=b"", method="POST"
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        assert resp.status == 200

    # listing reachable via admin token
    code, html, _ = _get(f"{base}/{token}/")
    assert code == 200
    assert b"test-room" in html
    assert b"alice" in html

    # download
    code, content, headers = _get(f"{base}/{token}/recording/{rec_id}")
    assert code == 200
    assert content == payload1 + payload2
    assert headers.get("Content-Type") == "video/webm"

    # delete
    assert _delete(f"{base}/{token}/recording/{rec_id}") == 200
    code, _, _ = _get(f"{base}/{token}/recording/{rec_id}")
    assert code == 404


def test_init_rejects_bad_room(running_server):
    base = running_server["base"]
    code, body = _post_json(f"{base}/api/recordings/init", {"room": "../escape"})
    assert code == 400
    assert "room" in body["error"]


def test_init_truncates_started_by(running_server):
    base = running_server["base"]
    long_name = "X" * 200
    code, body = _post_json(f"{base}/api/recordings/init", {"room": "ok", "started_by": long_name})
    assert code == 200
    rec_id = body["id"]
    meta = json.loads((running_server["rec_dir"] / f"{rec_id}.json").read_text())
    assert len(meta["started_by"]) == 64


def test_admin_token_required_for_listing(running_server):
    base = running_server["base"]
    # Wrong token; has the right shape (>=24 chars base64-url) so the
    # upstream nginx fragment would proxy it, but the sidecar checks
    # the value.
    code, body, _ = _get(f"{base}/this-is-not-the-real-admin-token/")
    assert code == 404


def test_unfinalized_recording_not_downloadable(running_server):
    base = running_server["base"]
    token = running_server["token"]
    code, body = _post_json(f"{base}/api/recordings/init", {"room": "r"})
    rec_id = body["id"]
    _post_bytes(f"{base}/api/recordings/{rec_id}/chunk", b"data")
    # No finalize.
    code, _, _ = _get(f"{base}/{token}/recording/{rec_id}")
    assert code == 404


def test_chunk_rejects_unknown_id(running_server):
    base = running_server["base"]
    code, body = _post_bytes(f"{base}/api/recordings/0123456789abcdef/chunk", b"x")
    assert code == 404


def test_chunk_rejects_after_finalize(running_server):
    base = running_server["base"]
    code, body = _post_json(f"{base}/api/recordings/init", {"room": "r"})
    rec_id = body["id"]
    _post_bytes(f"{base}/api/recordings/{rec_id}/chunk", b"x")
    req = urllib.request.Request(f"{base}/api/recordings/{rec_id}/finalize", method="POST")
    urllib.request.urlopen(req, timeout=5)
    code, body = _post_bytes(f"{base}/api/recordings/{rec_id}/chunk", b"y")
    assert code == 409


def test_finalize_idempotent(running_server):
    base = running_server["base"]
    code, body = _post_json(f"{base}/api/recordings/init", {"room": "r"})
    rec_id = body["id"]
    _post_bytes(f"{base}/api/recordings/{rec_id}/chunk", b"x")
    req = urllib.request.Request(f"{base}/api/recordings/{rec_id}/finalize", method="POST")
    with urllib.request.urlopen(req, timeout=5) as r1:
        assert r1.status == 200
    with urllib.request.urlopen(req, timeout=5) as r2:
        assert r2.status == 200
        body2 = json.loads(r2.read())
        assert body2.get("already_finalized") is True


# ---- quota eviction -------------------------------------------------------


def test_quota_evicts_oldest(running_server):
    """Recording N+1 evicts recording 1 once the cap is reached."""
    base = running_server["base"]
    state = running_server["state"]

    # Cap is 10 MiB (set in fixture). Upload three 4 MiB recordings;
    # by the time the third is being chunked, the first should be
    # gone.
    payload_4mib = b"\x00" * (4 * 1024 * 1024)
    ids: list[str] = []
    for i in range(3):
        code, body = _post_json(f"{base}/api/recordings/init", {"room": f"r{i}"})
        rec_id = body["id"]
        _post_bytes(f"{base}/api/recordings/{rec_id}/chunk", payload_4mib)
        req = urllib.request.Request(f"{base}/api/recordings/{rec_id}/finalize", method="POST")
        urllib.request.urlopen(req, timeout=10).read()
        ids.append(rec_id)
        # Ensure started_at differs across recordings so the oldest
        # eviction can be deterministic. Sleep just past the second
        # boundary used by _now_iso (timespec='seconds').
        time.sleep(1.1)

    metas = rec_server._list_meta(state.rec_dir)
    surviving = {m["id"] for m in metas if m.get("finalized")}
    assert ids[0] not in surviving, "oldest recording should have been evicted"
    assert ids[2] in surviving, "newest recording should be kept"


# ---- startup orphan sweep ------------------------------------------------


def test_sweep_removes_orphan_tmp(tmp_path: Path):
    rec_dir = tmp_path / "rec"
    rec_dir.mkdir()
    (rec_dir / "abcdef0123456789.webm.tmp").write_bytes(b"partial")
    rec_server._sweep_orphans(rec_dir)
    assert not list(rec_dir.glob("*.tmp"))


def test_sweep_removes_metadata_for_missing_file(tmp_path: Path):
    rec_dir = tmp_path / "rec"
    rec_dir.mkdir()
    rec_id = "abcdef0123456789"
    (rec_dir / f"{rec_id}.json").write_text(
        json.dumps({"id": rec_id, "finalized": True, "started_at": "2026-01-01T00:00:00+00:00"})
    )
    # No matching .webm file.
    rec_server._sweep_orphans(rec_dir)
    assert not (rec_dir / f"{rec_id}.json").exists()


# ---- admin token persistence ---------------------------------------------


def test_admin_token_persisted(tmp_path: Path):
    f = tmp_path / "tok"
    t1 = rec_server._load_or_create_admin_token(f)
    assert len(t1) > 20
    t2 = rec_server._load_or_create_admin_token(f)
    assert t1 == t2  # same token across calls


# ---- security: oversized chunk rejection ---------------------------------


def test_chunk_rejects_oversized_content_length(running_server):
    """A client can't trigger preemptive eviction by claiming a huge
    Content-Length on a single chunk request."""
    base = running_server["base"]
    code, body = _post_json(f"{base}/api/recordings/init", {"room": "victim"})
    rec_id = body["id"]

    # Craft a request that claims 64 MiB but sends only a few bytes.
    # We don't actually need to send the body — the handler should
    # reject before reading.
    req = urllib.request.Request(
        f"{base}/api/recordings/{rec_id}/chunk",
        data=b"x",
        headers={
            "Content-Type": "application/octet-stream",
            "Content-Length": str(64 * 1024 * 1024),
        },
        method="POST",
    )
    # urlopen will adjust Content-Length based on data; bypass by
    # using a low-level connection.
    import http.client
    from urllib.parse import urlparse as _urlparse

    parts = _urlparse(base)
    conn = http.client.HTTPConnection(parts.hostname, parts.port, timeout=10)
    conn.request(
        "POST",
        f"/api/recordings/{rec_id}/chunk",
        body=b"x",
        headers={
            "Content-Type": "application/octet-stream",
            "Content-Length": str(64 * 1024 * 1024),
        },
    )
    resp = conn.getresponse()
    assert resp.status == 413
    conn.close()


# ---- DELETE edge cases ----------------------------------------------------


def test_delete_unknown_id_returns_404(running_server):
    base = running_server["base"]
    token = running_server["token"]
    code = _delete(f"{base}/{token}/recording/0123456789abcdef")
    assert code == 404


def test_delete_unfinalized_removes_tmp(running_server):
    """An admin can delete an in-progress (unfinalized) recording;
    the .webm.tmp and .json files should be removed."""
    base = running_server["base"]
    token = running_server["token"]
    rec_dir = running_server["rec_dir"]
    code, body = _post_json(f"{base}/api/recordings/init", {"room": "midway"})
    rec_id = body["id"]
    _post_bytes(f"{base}/api/recordings/{rec_id}/chunk", b"partial")

    assert (rec_dir / f"{rec_id}.webm.tmp").exists()
    assert (rec_dir / f"{rec_id}.json").exists()

    assert _delete(f"{base}/{token}/recording/{rec_id}") == 200
    assert not (rec_dir / f"{rec_id}.webm.tmp").exists()
    assert not (rec_dir / f"{rec_id}.json").exists()


# ---- empty / large input edge cases --------------------------------------


def test_unfinalized_uploads_count_against_quota(running_server):
    """A flood of unfinalized uploads can't push past the cap."""
    base = running_server["base"]

    # Fill ~10 MiB cap with two unfinalized 4 MiB uploads, then try a third.
    payload = b"\x00" * (4 * 1024 * 1024)
    code, body = _post_json(f"{base}/api/recordings/init", {"room": "a"})
    rec_a = body["id"]
    _post_bytes(f"{base}/api/recordings/{rec_a}/chunk", payload)
    code, body = _post_json(f"{base}/api/recordings/init", {"room": "b"})
    rec_b = body["id"]
    _post_bytes(f"{base}/api/recordings/{rec_b}/chunk", payload)

    # Third upload init succeeds but the chunk should be refused
    # because the cap-minus-evictable check fails (nothing finalized
    # to evict, and tmp uploads are sticky).
    code, body = _post_json(f"{base}/api/recordings/init", {"room": "c"})
    rec_c = body["id"]

    # Use http.client directly so we can observe the 507 even though
    # our handler short-circuits before reading the body (urllib's
    # higher-level urlopen sees the early-close as a broken pipe).
    import http.client
    from urllib.parse import urlparse as _urlparse

    # Probe with a tiny body but a Content-Length claiming 4 MiB.
    # Server's fail-fast check (which only inspects Content-Length,
    # not the body) returns 507 immediately, before reading any bytes.
    parts = _urlparse(base)
    conn = http.client.HTTPConnection(parts.hostname, parts.port, timeout=10)
    conn.request(
        "POST",
        f"/api/recordings/{rec_c}/chunk",
        body=b"x",
        headers={
            "Content-Type": "application/octet-stream",
            "Content-Length": str(4 * 1024 * 1024),
        },
    )
    resp = conn.getresponse()
    assert resp.status == 507
    conn.close()


def test_chunk_after_admin_delete_does_not_resurrect(running_server):
    """If an admin DELETEs a recording mid-upload, the next chunk
    must NOT recreate metadata for the deleted recording (zombie)."""
    base = running_server["base"]
    token = running_server["token"]
    rec_dir = running_server["rec_dir"]

    code, body = _post_json(f"{base}/api/recordings/init", {"room": "victim"})
    rec_id = body["id"]
    _post_bytes(f"{base}/api/recordings/{rec_id}/chunk", b"first")

    assert _delete(f"{base}/{token}/recording/{rec_id}") == 200
    assert not (rec_dir / f"{rec_id}.json").exists()

    # A late chunk POST should NOT recreate metadata.
    code, body = _post_bytes(f"{base}/api/recordings/{rec_id}/chunk", b"late")
    assert code == 404
    assert not (rec_dir / f"{rec_id}.json").exists()
    # And the .webm.tmp should not linger.
    assert not (rec_dir / f"{rec_id}.webm.tmp").exists()


def test_finalize_410_when_file_was_deleted(running_server):
    """If finalize is called twice and someone deleted the file
    between, the second call surfaces 410 instead of misleading 200."""
    base = running_server["base"]
    rec_dir = running_server["rec_dir"]
    code, body = _post_json(f"{base}/api/recordings/init", {"room": "r"})
    rec_id = body["id"]
    _post_bytes(f"{base}/api/recordings/{rec_id}/chunk", b"x")
    req = urllib.request.Request(f"{base}/api/recordings/{rec_id}/finalize", method="POST")
    urllib.request.urlopen(req, timeout=5).read()

    # Simulate external removal of the .webm (e.g. partial admin
    # delete that nuked the data file but not the JSON).
    (rec_dir / f"{rec_id}.webm").unlink()

    req = urllib.request.Request(f"{base}/api/recordings/{rec_id}/finalize", method="POST")
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            pytest.fail(f"expected 410, got {r.status}")
    except urllib.error.HTTPError as e:
        assert e.code == 410


def test_chunk_rejects_zero_length(running_server):
    """Content-Length: 0 isn't a valid chunk."""
    base = running_server["base"]
    code, body = _post_json(f"{base}/api/recordings/init", {"room": "r"})
    rec_id = body["id"]

    import http.client
    from urllib.parse import urlparse as _urlparse

    parts = _urlparse(base)
    conn = http.client.HTTPConnection(parts.hostname, parts.port, timeout=10)
    conn.request(
        "POST",
        f"/api/recordings/{rec_id}/chunk",
        body=b"",
        headers={
            "Content-Type": "application/octet-stream",
            "Content-Length": "0",
        },
    )
    resp = conn.getresponse()
    assert resp.status == 400
    conn.close()
