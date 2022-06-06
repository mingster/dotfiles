#!/bin/sh
ssh -o UserKnownHostsFile=/dev/null -o CheckHostIP=no -o StrictHostKeyChecking=no -i $HOME/.ssh/google_compute_engine -A -p 22 mtsai@130.211.126.231
#gcloud compute --project "mimetic-myth-91918" ssh --zone "us-central1-a" "mingstercom"
