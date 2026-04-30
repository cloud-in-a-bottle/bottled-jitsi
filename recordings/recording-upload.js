// Hijack Jitsi's "save local recording" download and upload the
// blob to the openhost-jitsi recordings sidecar instead (the
// sidecar then writes it to the OpenHost app data dir and serves
// it from /<admin_token>/).
//
// Why this approach: editing the lib-jitsi-meet bundle to call our
// API directly would mean rebuilding it for every Jitsi upgrade.
// We instead hook HTMLAnchorElement.prototype.click — Jitsi's
// LocalRecordingManager.saveRecording creates an <a download="...">
// pointing at a blob: URL and clicks it; that is the only thing in
// the Jitsi web app that does that with a .webm extension. We
// short-circuit that one click and route the bytes to our sidecar,
// then offer the user a fallback download if the upload fails.
//
// All endpoints are relative to the Jitsi origin; the sidecar is
// reached via nginx's /api/recordings/* proxy.

(function () {
    'use strict';

    if (window.__openhostRecordingsHooked) {
        return;
    }
    window.__openhostRecordingsHooked = true;

    var CHUNK_SIZE = 5 * 1024 * 1024; // 5 MiB; matches sidecar default
    var INIT_URL = '/api/recordings/init';

    function log() {
        try { console.log.apply(console, ['[openhost-recordings]'].concat([].slice.call(arguments))); } catch (e) {}
    }

    // Strip HTML metacharacters from text we plan to drop into innerHTML
    // alongside trusted markup. Used because callers compose strings
    // like 'Uploading… (' + pct + '%)' and the 'pct' or error message
    // half could in principle contain server-controlled bytes.
    function safeText(s) {
        var d = document.createElement('div');
        d.textContent = String(s == null ? '' : s);
        return d.innerHTML;
    }

    function showNotice(text, opts) {
        opts = opts || {};
        var existing = document.getElementById('openhost-recording-notice');
        if (existing) existing.remove();
        var div = document.createElement('div');
        div.id = 'openhost-recording-notice';
        div.style.cssText = [
            'position:fixed', 'right:1em', 'bottom:1em', 'z-index:99999',
            'background:#222', 'color:#fff', 'padding:0.8em 1em',
            'border-radius:6px', 'box-shadow:0 4px 16px rgba(0,0,0,0.3)',
            'font-family:-apple-system,system-ui,sans-serif', 'font-size:0.9em',
            'max-width:32em', 'line-height:1.4'
        ].join(';');
        // Callers pass already-trusted markup (string templates with
        // safeText() applied to dynamic substrings); innerHTML is fine
        // here. Adding any new caller? Wrap dynamic content in
        // safeText() first.
        div.innerHTML = text;
        document.body.appendChild(div);
        if (opts.autoHideMs) {
            setTimeout(function () {
                if (div.parentNode) div.parentNode.removeChild(div);
            }, opts.autoHideMs);
        }
        return div;
    }

    function getRoomName() {
        // Jitsi's room name is the first non-empty path segment.
        var seg = (window.location.pathname || '/').split('/').filter(Boolean);
        return seg[0] || 'unknown';
    }

    function getStartedBy() {
        // Best-effort: Jitsi exposes the local participant's display
        // name on APP.conference / APP.store. Fall back to 'anonymous'
        // if we can't read it; the sidecar truncates and stores it.
        try {
            var s = window.APP && window.APP.store && window.APP.store.getState && window.APP.store.getState();
            if (s) {
                var local = s['features/base/participants'] && s['features/base/participants'].local;
                if (local && local.name) return String(local.name);
            }
        } catch (e) {
            log('getStartedBy error', e);
        }
        return 'anonymous';
    }

    async function uploadBlob(blob) {
        if (!blob || blob.size === 0) {
            throw new Error('empty recording (nothing was captured)');
        }
        var room = getRoomName();
        var startedBy = getStartedBy();
        var notice = showNotice('Uploading recording &hellip; (0%)');

        var initResp = await fetch(INIT_URL, {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ room: room, started_by: startedBy })
        });
        if (!initResp.ok) {
            throw new Error('init failed: HTTP ' + initResp.status);
        }
        var initBody = await initResp.json();
        var id = initBody.id;
        var chunkSize = initBody.chunk_size || CHUNK_SIZE;

        var total = blob.size;
        var sent = 0;
        var idx = 0;
        while (sent < total) {
            var end = Math.min(sent + chunkSize, total);
            var slice = blob.slice(sent, end);
            var resp = await fetch('/api/recordings/' + id + '/chunk', {
                method: 'POST',
                credentials: 'same-origin',
                headers: { 'Content-Type': 'application/octet-stream' },
                body: slice
            });
            if (!resp.ok) {
                throw new Error('chunk ' + idx + ' failed: HTTP ' + resp.status);
            }
            sent = end;
            idx += 1;
            var pct = Math.floor(sent * 100 / total);
            notice.innerHTML = 'Uploading recording &hellip; (' + safeText(pct) + '%)';
        }

        var finResp = await fetch('/api/recordings/' + id + '/finalize', {
            method: 'POST',
            credentials: 'same-origin'
        });
        if (!finResp.ok) {
            throw new Error('finalize failed: HTTP ' + finResp.status);
        }
        notice.innerHTML = 'Recording uploaded. Ask the host for the recordings page link.';
        setTimeout(function () { if (notice.parentNode) notice.parentNode.removeChild(notice); }, 8000);
        return id;
    }

    function fallbackDownload(blob, filename) {
        // The hijacked <a> already had a blob URL; rebuild a clean
        // one in case the original got revoked.
        var url = URL.createObjectURL(blob);
        var a = document.createElement('a');
        a.style.display = 'none';
        a.href = url;
        a.download = filename;
        document.body.appendChild(a);
        // Bypass our own hook on this synthetic click.
        a.__openhostBypass = true;
        a.click();
        setTimeout(function () { URL.revokeObjectURL(url); a.remove(); }, 1000);
    }

    var originalClick = HTMLAnchorElement.prototype.click;
    HTMLAnchorElement.prototype.click = function () {
        try {
            if (this.__openhostBypass) {
                return originalClick.apply(this, arguments);
            }
            var href = this.getAttribute('href') || this.href || '';
            var download = this.getAttribute('download') || this.download || '';
            // Only intercept blob: URLs with .webm downloads — that's
            // the LocalRecordingManager pattern. Anything else falls
            // through to native click.
            if (!download || !/\.webm($|\?)/i.test(download) || !/^blob:/i.test(href)) {
                return originalClick.apply(this, arguments);
            }
            var anchor = this; // captured for the async closure; `this` inside it is undefined under strict mode
            var anchorHref = href;
            var anchorDownload = download;
            log('intercepting recording download', anchorDownload);
            (async function () {
                var blob;
                try {
                    var r = await fetch(anchorHref);
                    blob = await r.blob();
                } catch (e) {
                    log('failed to read blob; falling back to download', e);
                    showNotice('Could not read recording for upload; saving locally instead.', { autoHideMs: 8000 });
                    try { originalClick.apply(anchor, []); } catch (e2) { log('native click also failed', e2); }
                    return;
                }
                try {
                    await uploadBlob(blob);
                } catch (e) {
                    log('upload failed; falling back to download', e);
                    showNotice(
                        'Upload failed (' + safeText(e && e.message ? e.message : String(e)) + '). Saving locally instead.',
                        { autoHideMs: 12000 }
                    );
                    fallbackDownload(blob, anchorDownload);
                } finally {
                    // Jitsi's blob URL holds the full recording in memory;
                    // release it once we're done with the bytes.
                    try { URL.revokeObjectURL(anchorHref); } catch (e) {}
                }
            })().catch(function (e) {
                log('unexpected error in upload pipeline', e);
            });
        } catch (e) {
            log('hook error; falling back to native click', e);
            return originalClick.apply(this, arguments);
        }
    };

    log('hook installed');
})();
