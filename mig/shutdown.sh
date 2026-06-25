#!/bin/bash
# shutdown.sh — runs on GCE shutdown hook BEFORE the OS shuts down.
# Signals the counter process so it can flush state gracefully.
#
# GCP fires this script when a Spot VM is preempted. The counter's SIGTERM handler does the actual Firestore write + GCS log upload.
# This script just waits for that to complete cleanly.

set -euo pipefail
exec > >(tee /var/log/counter-shutdown.log | logger -t counter-shutdown) 2>&1

echo "=== Shutdown hook triggered: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# systemd already sends SIGTERM to the counter service on shutdown.
# Give it up to 25 seconds to flush (GCP allows ~30s total).
TIMEOUT=25
ELAPSED=0

echo "Waiting for counter service to flush state..."
while systemctl is-active --quiet counter && [ $ELAPSED -lt $TIMEOUT ]; do
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done

if systemctl is-active --quiet counter; then
  echo "WARN: counter did not stop in ${TIMEOUT}s, sending SIGKILL"
  systemctl kill -s SIGKILL counter
else
  echo "Counter stopped cleanly after ${ELAPSED}s"
fi

echo "=== Shutdown hook complete ==="
