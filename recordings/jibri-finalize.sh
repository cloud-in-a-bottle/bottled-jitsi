#!/bin/bash
# Jibri's JIBRI_FINALIZE_RECORDING_SCRIPT_PATH: invoked once per
# recording with the path to the recording directory as $1. Jibri
# writes one .mp4 per recording into that directory.
#
# We POST the file to the recordings sidecar's chunked upload API
# (the same one used by the browser-side fallback), then delete the
# local copy so Jibri's recording dir doesn't fill up.
#
# All requests go to 127.0.0.1:5060 inside the container — no auth
# required for the upload endpoints (they're anonymous; the admin
# URL gate is on listing/download).

set -eu

REC_DIR="$1"
SIDECAR="${OPENHOST_RECORDINGS_SIDECAR:-http://127.0.0.1:5060}"
ROOM_NAME_FILE="$REC_DIR/metadata.json"

log() { echo "[jibri-finalize] $*" >&2; }

# Jibri puts at most one .mp4 per recording dir; just iterate in case.
shopt -s nullglob
for FILE in "$REC_DIR"/*.mp4; do
    SIZE=$(stat -c%s "$FILE")
    log "uploading $FILE ($SIZE bytes)"

    # Best-effort room name extraction from Jibri's metadata.json.
    ROOM="recording"
    if [[ -f "$ROOM_NAME_FILE" ]]; then
        ROOM=$(jq -r '.meeting_url // .room_name // "recording"' "$ROOM_NAME_FILE" 2>/dev/null \
                  | sed -E 's#^https?://[^/]+/##; s#/.*##' || echo "recording")
        # Strip trailing query / hash and normalize to alphanumerics
        # so it survives the sidecar's ROOM_RE.
        ROOM=$(echo "$ROOM" | tr -c 'A-Za-z0-9._- ' '_' | head -c 128)
        [[ -z "$ROOM" ]] && ROOM="recording"
    fi
    log "room=$ROOM"

    # init
    INIT_JSON=$(curl -fsS -X POST -H "Content-Type: application/json" \
        -d "{\"room\":\"$ROOM\",\"started_by\":\"jibri\"}" \
        "$SIDECAR/api/recordings/init") || {
        log "ERROR: init failed; leaving file in place"
        continue
    }
    REC_ID=$(echo "$INIT_JSON" | jq -r .id)
    CHUNK_SIZE=$(echo "$INIT_JSON" | jq -r '.chunk_size // 5242880')
    log "init id=$REC_ID chunk_size=$CHUNK_SIZE"

    # Upload in chunks. We use dd to slice the file in $CHUNK_SIZE
    # blocks and stream each into a separate POST.
    OFFSET=0
    OK=1
    while [[ $OFFSET -lt $SIZE ]]; do
        if ! dd if="$FILE" bs=$CHUNK_SIZE skip=$((OFFSET / CHUNK_SIZE)) count=1 status=none \
              | curl -fsS -X POST -H "Content-Type: application/octet-stream" \
                    --data-binary @- \
                    "$SIDECAR/api/recordings/$REC_ID/chunk" > /dev/null; then
            log "ERROR: chunk upload at offset $OFFSET failed"
            OK=0
            break
        fi
        OFFSET=$((OFFSET + CHUNK_SIZE))
    done

    if [[ $OK -eq 1 ]]; then
        if curl -fsS -X POST "$SIDECAR/api/recordings/$REC_ID/finalize" > /dev/null; then
            log "finalized $REC_ID; removing local copy"
            rm -f "$FILE"
        else
            log "ERROR: finalize failed; leaving file in place"
        fi
    fi
done
