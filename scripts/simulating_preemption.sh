#!/bin/bash
# simulate_preemption.sh — send SIGTERM to the counter process locally.
# Use this to test the shutdown handler without a real GCP VM.

set -euo pipefail

COUNTER_PID=$(pgrep -f "counter.py" | head -1)

if [ -z "$COUNTER_PID" ]; then
  echo "No counter.py process found. Start it first:"
  echo "  python3 spot_vm/counter.py"
  exit 1
fi

echo "Sending SIGTERM to counter.py (PID $COUNTER_PID)..."
kill -SIGTERM "$COUNTER_PID"

echo "Watch the logs for SIGTERM handling:"
echo "  The process should log 'SIGTERM received', save state, and exit."
