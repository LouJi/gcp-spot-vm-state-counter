#!/bin/bash
# setup_gcp.sh — one-time GCP project setup.
# Creates the service account, Firestore database, and GCS log bucket.

set -euo pipefail

PROJECT_ID="${1:?Usage: ./setup_gcp.sh <PROJECT_ID>}"
REGION="${2:-us-central1}"
BUCKET="${PROJECT_ID}-vm-logs"
SA_NAME="counter-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "=== Setting up GCP project: $PROJECT_ID ==="

gcloud config set project "$PROJECT_ID"

echo "--- Enabling APIs ---"
gcloud services enable \
  compute.googleapis.com \
  firestore.googleapis.com \
  storage.googleapis.com

echo "--- Creating service account ---"
gcloud iam service-accounts create "$SA_NAME" \
  --display-name="Spot Counter Service Account" \
  --project="$PROJECT_ID" || echo "Service account already exists"

echo "--- Granting IAM roles ---"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/datastore.user"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/storage.objectAdmin"

echo "--- Creating Firestore database ---"
gcloud firestore databases create \
  --location="$REGION" \
  --project="$PROJECT_ID" || echo "Firestore database already exists"

echo "--- Creating GCS log bucket ---"
gsutil mb -p "$PROJECT_ID" -l "$REGION" "gs://$BUCKET" || echo "Bucket already exists"
gsutil lifecycle set /dev/stdin "gs://$BUCKET" << 'EOF'
{"rule":[{"action":{"type":"Delete"},"condition":{"age":90}}]}
EOF

echo ""
echo "=== Setup complete ==="
echo "Bucket:          gs://$BUCKET"
echo "Service account: $SA_EMAIL"
echo "Firestore:       $PROJECT_ID (default)"
echo ""
echo "Next: export GCP_PROJECT_ID=$PROJECT_ID"
echo "      export GCS_LOG_BUCKET=$BUCKET"
