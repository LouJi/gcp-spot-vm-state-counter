#!/bin/bash
# startup.sh — runs as root when the Spot VM boots.
# Installs deps, sets env vars from GCE metadata, then launches the counter.

set -euo pipefail
exec > >(tee /var/log/counter-startup.log | logger -t counter-startup) 2>&1

echo "=== Startup: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# --- Pull config from instance metadata custom attributes ---
PROJECT_ID=$(curl -sf "http://metadata.google.internal/computeMetadata/v1/project/project-id" \
  -H "Metadata-Flavor: Google")
GCS_LOG_BUCKET=$(curl -sf "http://metadata.google.internal/computeMetadata/v1/instance/attributes/gcs-log-bucket" \
  -H "Metadata-Flavor: Google")
FIRESTORE_COLLECTION=$(curl -sf "http://metadata.google.internal/computeMetadata/v1/instance/attributes/firestore-collection" \
  -H "Metadata-Flavor: Google" || echo "vm_state")
FIRESTORE_DOC_ID=$(curl -sf "http://metadata.google.internal/computeMetadata/v1/instance/attributes/firestore-doc-id" \
  -H "Metadata-Flavor: Google" || echo "counter_state")

export GCP_PROJECT_ID="$PROJECT_ID"
export GCS_LOG_BUCKET="$GCS_LOG_BUCKET"
export FIRESTORE_COLLECTION="$FIRESTORE_COLLECTION"
export FIRESTORE_DOC_ID="$FIRESTORE_DOC_ID"

# --- Install Python dependencies if not already present ---
if ! python3 -c "import google.cloud.firestore" 2>/dev/null; then
  echo "Installing dependencies..."
  
# Install pip and dependencies
apt-get update -y
apt-get install -y python3-pip python3-dev

# Verify pip3 exists before using it
which pip3 || { echo "pip3 not found after install"; exit 1; }

pip3 install --break-system-packages --quiet google-cloud-firestore google-cloud-storage requests
fi


# --- Copy counter script (it was baked into the instance template metadata) ---
SCRIPT_DIR="/opt/counter"
mkdir -p "$SCRIPT_DIR"

COUNTER_SCRIPT=$(curl -sf \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/counter-script" \
  -H "Metadata-Flavor: Google" || echo "")

if [ -n "$COUNTER_SCRIPT" ]; then
  echo "$COUNTER_SCRIPT" > "$SCRIPT_DIR/counter.py"
else
  # Fallback: script should already exist from image or previous boot
  echo "WARN: counter-script metadata not found, using existing $SCRIPT_DIR/counter.py"
fi

# --- Run the counter as a systemd service ---
cat > /etc/systemd/system/counter.service << EOF
[Unit]
Description=Stateful Spot VM Counter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment="GCP_PROJECT_ID=${GCP_PROJECT_ID}"
Environment="GCS_LOG_BUCKET=${GCS_LOG_BUCKET}"
Environment="FIRESTORE_COLLECTION=${FIRESTORE_COLLECTION}"
Environment="FIRESTORE_DOC_ID=${FIRESTORE_DOC_ID}"
ExecStart=/usr/bin/python3 ${SCRIPT_DIR}/counter.py
Restart=no
StandardOutput=journal
StandardError=journal
TimeoutStopSec=30
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable counter
systemctl start counter

echo "=== Counter service started ==="
