# MIG — Using gcloud only

Deploys the stateful counter using a Managed Instance Group with a single Spot VM. When GCP preempts the instance, the MIG automatically creates a replacement — which resumes counting from where it left off.

## Deploy

```bash
export GCP_PROJECT_ID="[YOUR_PROJECT_ID]"
export ZONE="[YOUR_MIG_ZONE]"
chmod +x instance_template.sh
./instance_template.sh
```

## Simulate Preemption

```bash
ZONE="[GCP_ZONAL]"
MIG="spot-counter-mig"

# Get current instance name
INSTANCE=$(gcloud compute instance-groups managed list-instances $MIG \
  --zone=$ZONE --format='value(instance)' | head -1)

# Delete it — MIG recreates automatically
gcloud compute instance-groups managed delete-instances $MIG \
  --zone=$ZONE --instances=$INSTANCE

# Watch replacement come up
watch -n5 "gcloud compute instance-groups managed list-instances $MIG --zone=$ZONE"
```

## Verify Resume

```bash
PROJECT_ID="[YOUR_PROJECT_ID]"
BUCKET="$PROJECT_ID-vm-logs"

# Latest shutdown log (what count was saved)
gsutil cat $(gsutil ls gs://$BUCKET/shutdown-logs/ | tail -1)

# Latest startup log (what count was resumed)
gsutil cat $(gsutil ls gs://$BUCKET/startup-logs/ | tail -1)
```
