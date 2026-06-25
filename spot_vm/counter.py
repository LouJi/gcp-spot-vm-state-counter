"""
Stateful counter for GCP Spot VM.

Counts 0 -> 1000, incrementing every 10 seconds.
- Reads starting count from Firestore on startup.
- Writes state to Firestore every 30 seconds (heartbeat).
- On SIGTERM (preemption): flushes state + writes shutdown log to GCS.
- On startup: writes startup log to GCS with resumed count.
"""

import os
import json
import signal
import logging
import time
from datetime import datetime, timezone

from google.cloud import firestore, storage
import requests

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
PROJECT_ID           = os.environ["GCP_PROJECT_ID"]
GCS_LOG_BUCKET       = os.environ["GCS_LOG_BUCKET"]
FIRESTORE_COLLECTION = os.environ.get("FIRESTORE_COLLECTION", "vm_state")
FIRESTORE_DOC_ID     = os.environ.get("FIRESTORE_DOC_ID", "counter_state")
SAVE_INTERVAL_SEC    = int(os.environ.get("SAVE_INTERVAL_SEC", "30"))
COUNT_INTERVAL_SEC   = int(os.environ.get("COUNT_INTERVAL_SEC", "10"))
MAX_COUNT            = int(os.environ.get("MAX_COUNT", "1000"))

# ---------------------------------------------------------------------------
# GCP clients
# ---------------------------------------------------------------------------
db = firestore.Client(project=PROJECT_ID)
gcs = storage.Client(project=PROJECT_ID)


def get_instance_metadata(key: str, default: str = "unknown") -> str:
    """Pull a field from the GCE metadata server."""
    url = f"http://metadata.google.internal/computeMetadata/v1/instance/{key}"
    try:
        r = requests.get(url, headers={"Metadata-Flavor": "Google"}, timeout=2)
        return r.text if r.ok else default
    except Exception:
        return default


# Resolved once at import time; safe because the metadata server is available
# immediately after the VM boots.
INSTANCE_NAME = get_instance_metadata("name")
ZONE = get_instance_metadata("zone").split("/")[-1]


# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------

def load_state() -> int:
    """Read saved count from Firestore. Returns 0 if no prior state exists."""
    doc = db.collection(FIRESTORE_COLLECTION).document(FIRESTORE_DOC_ID).get()
    if doc.exists:
        data = doc.to_dict()
        count = int(data.get("current_count", 0))
        saved = data.get("last_updated", "never")
        log.info("STARTUP  resume count=%d  last_saved=%s", count, saved)
        return count
    log.info("STARTUP  no prior state — starting from 0")
    return 0


def save_state(count: int) -> None:
    """Persist current count to Firestore (upsert)."""
    now = datetime.now(timezone.utc).isoformat()
    db.collection(FIRESTORE_COLLECTION).document(FIRESTORE_DOC_ID).set(
        {
            "current_count": count,
            "last_updated":  now,
            "instance_name": INSTANCE_NAME,
            "zone":          ZONE,
        },
        merge=True,
    )
    log.info("FIRESTORE  saved count=%d  ts=%s", count, now)


# ---------------------------------------------------------------------------
# GCS log helpers
# ---------------------------------------------------------------------------

def _upload_log(prefix: str, payload: dict) -> None:
    now = datetime.now(timezone.utc)
    blob_name = f"{prefix}/{now.strftime('%Y%m%dT%H%M%SZ')}-{INSTANCE_NAME}.json"
    bucket = gcs.bucket(GCS_LOG_BUCKET)
    bucket.blob(blob_name).upload_from_string(
        json.dumps(payload, indent=2),
        content_type="application/json",
    )
    log.info("GCS LOG  gs://%s/%s", GCS_LOG_BUCKET, blob_name)


def write_startup_log(count: int) -> None:
    _upload_log("startup-logs", {
        "event":            "startup",
        "timestamp":        datetime.now(timezone.utc).isoformat(),
        "instance_name":    INSTANCE_NAME,
        "zone":             ZONE,
        "count_at_startup": count,
    })


def write_shutdown_log(count: int, start_time: float) -> None:
    _upload_log("shutdown-logs", {
        "event":                  "shutdown",
        "timestamp":              datetime.now(timezone.utc).isoformat(),
        "instance_name":          INSTANCE_NAME,
        "zone":                   ZONE,
        "count_at_shutdown":      count,
        "total_runtime_seconds":  int(time.monotonic() - start_time),
    })


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    start_time = time.monotonic()
    count = load_state()
    last_saved = time.monotonic()
    shutting_down = False

    write_startup_log(count)

    def handle_sigterm(signum, frame):
        """
        GCP gives ~30 s between SIGTERM and hard shutdown.
        Use it to flush Firestore + write the GCS shutdown log.
        """
        nonlocal shutting_down
        log.warning("SIGTERM  saving state before shutdown  count=%d", count)
        shutting_down = True
        save_state(count)
        write_shutdown_log(count, start_time)
        log.warning("SHUTDOWN COMPLETE  count=%d", count)

    signal.signal(signal.SIGTERM, handle_sigterm)

    log.info("Counter running  start=%d  target=%d", count, MAX_COUNT)

    while count < MAX_COUNT and not shutting_down:
        time.sleep(COUNT_INTERVAL_SEC)

        if shutting_down:
            break

        count += 1
        elapsed = int(time.monotonic() - start_time)
        log.info("COUNT %d / %d  elapsed=%ds", count, MAX_COUNT, elapsed)

        # Periodic heartbeat save to Firestore
        if time.monotonic() - last_saved >= SAVE_INTERVAL_SEC:
            save_state(count)
            last_saved = time.monotonic()

    if not shutting_down:
        log.info("COUNT FINISHED  reached %d", MAX_COUNT)
        save_state(count)


if __name__ == "__main__":
    main()
