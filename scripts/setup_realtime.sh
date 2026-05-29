#!/usr/bin/env bash
#
# One-time GCP setup for Glack's realtime pipeline (Phase 7).
#
# What this does:
#   1. Enables the Cloud Pub/Sub + Workspace Events APIs in your project
#   2. Creates the Pub/Sub topic + pull subscription Glack uses
#   3. Grants the Chat publisher service account publisher access on the
#      topic (so Workspace Events can deliver to it)
#
# Glack handles steps (2) and (3) automatically once you re-sign-in with
# the new `pubsub` OAuth scope, but running this script up front makes
# the first launch instant — no waiting on API enablement to propagate.
#
# Prereqs: `gcloud auth login` already done with the same account you
# sign into Glack with (taha@askflorence.health).
#
# Usage: bash scripts/setup_realtime.sh

set -euo pipefail

PROJECT="${GLACK_GCP_PROJECT:-glack-497804}"
TOPIC="glack-chat-events"
SUB="glack-chat-events-sub"
CHAT_PUBLISHER="chat-api-push@system.gserviceaccount.com"

# Make sure gcloud is on PATH (brew install puts it at this path on Apple Silicon).
if ! command -v gcloud >/dev/null 2>&1; then
  export PATH="/opt/homebrew/share/google-cloud-sdk/bin:$PATH"
fi
if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud not found. Install via: brew install --cask google-cloud-sdk"
  exit 1
fi

echo "===> Enabling APIs in ${PROJECT}"
gcloud services enable pubsub.googleapis.com workspaceevents.googleapis.com \
  --project="${PROJECT}"

echo "===> Ensuring Pub/Sub topic ${TOPIC}"
if ! gcloud pubsub topics describe "${TOPIC}" --project="${PROJECT}" >/dev/null 2>&1; then
  gcloud pubsub topics create "${TOPIC}" --project="${PROJECT}"
else
  echo "    already exists"
fi

echo "===> Granting ${CHAT_PUBLISHER} publisher on the topic"
gcloud pubsub topics add-iam-policy-binding "${TOPIC}" \
  --member="serviceAccount:${CHAT_PUBLISHER}" \
  --role="roles/pubsub.publisher" \
  --project="${PROJECT}" >/dev/null

echo "===> Ensuring Pub/Sub pull subscription ${SUB}"
if ! gcloud pubsub subscriptions describe "${SUB}" --project="${PROJECT}" >/dev/null 2>&1; then
  gcloud pubsub subscriptions create "${SUB}" \
    --topic="${TOPIC}" \
    --ack-deadline=30 \
    --project="${PROJECT}"
else
  echo "    already exists"
fi

echo
echo "✅ GCP side ready."
echo
echo "Next steps in Glack:"
echo "  1. Sign out + sign in (one-time, to grant the new pubsub scope)"
echo "  2. The realtime pipeline starts automatically on sign-in"
echo
echo "Verify: tail the unified log while you type in Chat web →"
echo "  log stream --predicate 'subsystem == \"com.github.taha-abbasi.glack\" AND category == \"sync\"' --info --style compact"
echo "You should see 'event google.workspace.chat.message.v1.created' within ~2s."
