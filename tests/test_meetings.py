import re
import time
from urllib.parse import urlparse

import requests
from openhost_test_harness import OpenhostStack

# A BOSH session-creation request for the anonymous XMPP domain guests join meetings on (XMPP_DOMAIN).
BOSH_SESSION_REQUEST = (
    "<body rid='4242424242' xmlns='http://jabber.org/protocol/httpbind' to='meet.jitsi' xml:lang='en' wait='10'"
    " hold='1' content='text/xml; charset=utf-8' ver='1.6' xmpp:version='1.0' xmlns:xmpp='urn:xmpp:xbosh'/>"
)


def _context(stack: OpenhostStack, response: requests.Response | None) -> str:
    summary = "no response" if response is None else f"{response.status_code}: {response.text[:500]}"
    return f"{summary}\n\napp logs:\n{stack.app_logs()[-5000:]}"


def _anonymous(method: str, stack: OpenhostStack, path: str, ok: str, timeout: float = 600, **kwargs: object) -> str:
    """Sends an anonymous request until the response is a 200 containing ``ok``, and returns its body.

    On first boot the container captures its public hostname from the first proxied request, then renders the config
    and starts prosody, jicofo, jvb and nginx, so for a while requests fail or get a placeholder page.
    """
    deadline = time.monotonic() + timeout
    response = None
    while time.monotonic() < deadline:
        try:
            response = requests.request(method, f"{stack.url}{path}", timeout=30, **kwargs)  # type: ignore[arg-type]
        except requests.ConnectionError:
            response = None
        else:
            if response.status_code == 200 and ok in response.text:
                return response.text
        time.sleep(3)
    raise AssertionError(f"anonymous {method} {path} never returned 200 with {ok!r}: {_context(stack, response)}")


def test_guest_can_open_a_room(stack: OpenhostStack) -> None:
    # public_paths = ["/"]: invited guests without a Cloud in a Bottle login can open a meeting.
    page = _anonymous("GET", stack, "/harness-room", "lib-jitsi-meet.min.js", headers={"Accept": "text/html"})
    # body.html injects our recordings upload shim into the meeting page.
    assert "/static/openhost-recordings.js" in page, page[:2000]
    # The config points clients at the public hostname, discovered from the router's X-Forwarded-Host on first boot.
    config = _anonymous("GET", stack, "/config.js", "config.bosh")
    bosh = re.search(r"config\.bosh = (.*);", config)
    assert bosh and f"https://{urlparse(stack.url).hostname}/" in bosh.group(1), config[:2000]


def test_guest_xmpp_signalling(stack: OpenhostStack) -> None:
    # Meetings signal over BOSH (XMPP websockets are disabled): nginx proxies /http-bind to the bundled prosody, which
    # gives anonymous guests a session on meet.jitsi.
    body = _anonymous(
        "POST",
        stack,
        "/http-bind",
        "sid=",
        data=BOSH_SESSION_REQUEST,
        headers={"Content-Type": "text/xml; charset=utf-8"},
    )
    assert "type='terminate'" not in body and 'type="terminate"' not in body, body


def test_recording_upload(stack: OpenhostStack) -> None:
    # Our recordings sidecar: meeting participants upload a recording anonymously; the admin URL (whose token is in
    # the app data dir) lists and serves it, and the recording is stored in the app data dir.
    _anonymous("GET", stack, "/api/recordings/health", '"ok"')
    response = requests.post(f"{stack.url}/api/recordings/init", json={"room": "harness-room"}, timeout=30)
    assert response.status_code == 200, _context(stack, response)
    rec_id = response.json()["id"]
    data = b"\x1a\x45\xdf\xa3harness recording"
    response = requests.post(f"{stack.url}/api/recordings/{rec_id}/chunk", data=data, timeout=30)
    assert response.status_code == 200, _context(stack, response)
    response = requests.post(f"{stack.url}/api/recordings/{rec_id}/finalize", timeout=30)
    assert response.status_code == 200, _context(stack, response)

    assert (stack.data_dir / "recordings" / f"{rec_id}.webm").read_bytes() == data
    token = (stack.data_dir / "recordings_admin_token").read_text().strip()
    response = requests.get(f"{stack.url}/_recordings/{token}/", timeout=30)
    assert response.status_code == 200 and rec_id in response.text, _context(stack, response)
    response = requests.get(f"{stack.url}/_recordings/{token}/recording/{rec_id}", timeout=30)
    assert response.status_code == 200 and response.content == data, _context(stack, response)
    response = requests.get(f"{stack.url}/_recordings/not-the-token/", timeout=30)
    assert response.status_code == 404, f"listing with a wrong token: {_context(stack, response)}"
