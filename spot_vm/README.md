# Spot VM — Single Instance

Deploy a single Spot VM that runs the stateful counter. This is the simplest setup — one VM, no auto-healing.

## Prerequisites

- GCP project with billing enabled
- `gcloud` CLI authenticated (`gcloud auth login`)
- `./scripts/setup_gcp.sh` has been run (creates Firestore DB + GCS bucket)

## Deploy

```bash
PROJECT_ID="[YOUR_PROJECT_ID]"
ZONE="[VM_ZONE]"
BUCKET="$PROJECT_ID-vm-logs"

gcloud compute instances create spot-counter \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --machine-type="e2-small" \
  --provisioning-model=SPOT \
  --instance-termination-action=DELETE \
  --service-account="counter-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --scopes="cloud-platform" \
  --metadata-from-file=\
startup-script=startup.sh,\
shutdown-script=shutdown.sh,\
counter-script=counter.py \
  --metadata=\
gcs-log-bucket="$BUCKET",\
firestore-collection=vm_state,\
firestore-doc-id=counter_state \
  --no-restart-on-failure
```

## What Happens

1. VM boots → `startup.sh` reads count from Firestore → starts counter
2. Counter logs every increment, saves to Firestore every 30 s
3. GCP preempts VM → sends SIGTERM → counter flushes state → uploads shutdown log to GCS
4. (You manually create a new VM to resume — see MIG folders for auto-healing)

## Watch Logs

```bash
# Stream counter logs
gcloud compute ssh spot-counter --zone="$ZONE" -- \
  "journalctl -u counter -f"

# View saved state in Firestore
gcloud firestore documents get \
  "projects/$PROJECT_ID/databases/(default)/documents/vm_state/counter_state"

# List shutdown logs in GCS
gsutil ls gs://$BUCKET/shutdown-logs/

# Read latest shutdown log
gsutil cat $(gsutil ls gs://$BUCKET/shutdown-logs/ | tail -1)
```
