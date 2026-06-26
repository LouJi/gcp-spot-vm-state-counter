#!/bin/bash
# instance_template.sh
# Creates a MIG instance template + managed instance group for the counter.
# Uses gcloud commands only (no Terraform).

set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:?Set GCP_PROJECT_ID}"
ZONE="${ZONE:?Set ZONE}"
BUCKET="${PROJECT_ID}-vm-logs"
TEMPLATE_NAME="spot-counter-template"
MIG_NAME="spot-counter-mig"
SA_EMAIL="counter-sa@${PROJECT_ID}.iam.gserviceaccount.com"

echo "=== Creating instance template: $TEMPLATE_NAME ==="

gcloud compute instance-templates create "$TEMPLATE_NAME" \
  --project="$PROJECT_ID" \
  --machine-type="e2-small" \
  --provisioning-model=SPOT \
  --service-account="$SA_EMAIL" \
  --scopes="cloud-platform" \
  --metadata-from-file=\
startup-script=startup.sh,\
shutdown-script=shutdown.sh,\
counter-script=counter.py \
  --metadata=\
gcs-log-bucket="$BUCKET",\
firestore-collection=vm_state,\
firestore-doc-id=counter_state \
  --no-restart-on-failure \
  --tags=spot-counter

echo "=== Creating managed instance group: $MIG_NAME ==="

# Single-instance MIG — auto-heals by recreating the VM when preempted.
gcloud compute instance-groups managed create "$MIG_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --template="$TEMPLATE_NAME" \
  --size=1

# Auto-healing: recreate the instance if it goes down.
# Initial delay gives the VM time to fully boot before health checks run.
gcloud compute instance-groups managed update "$MIG_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --initial-delay=120

echo ""
echo "=== MIG deployed ==="
echo "Watch MIG status:"
echo "  gcloud compute instance-groups managed list-instances $MIG_NAME --zone=$ZONE"
echo ""
echo "Stream counter logs from the current instance:"
echo "  INSTANCE=\$(gcloud compute instance-groups managed list-instances $MIG_NAME \\"
echo "    --zone=$ZONE --format='value(instance)' | head -1)"
echo "  gcloud compute ssh \$INSTANCE --zone=$ZONE -- 'journalctl -u counter -f'"
echo ""
echo "Simulate preemption (deletes the instance; MIG auto-recreates it):"
echo "  gcloud compute instance-groups managed delete-instances $MIG_NAME \\"
echo "    --zone=$ZONE --instances=\$INSTANCE"
