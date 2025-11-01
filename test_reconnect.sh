#!/bin/bash

# Test SSE reconnection with resilience
# This script simulates reconnection by killing and restarting the curl connection

if [ -z "$1" ]; then
    echo "Usage: $0 <job_id>"
    echo "Example: $0 F90CC737-BE41-4517-9C39-DC1C9CF1B4F2"
    exit 1
fi

JOB_ID=$1
URL="http://localhost:8000/transcribe/$JOB_ID/stream"
LAST_EVENT_ID=""

echo "Starting resilient SSE client for job: $JOB_ID"
echo "Press Ctrl+C to stop"
echo "================================"

# Function to connect with last event ID
connect_sse() {
    local headers=""
    if [ -n "$LAST_EVENT_ID" ]; then
        headers="-H \"Last-Event-ID: $LAST_EVENT_ID\""
        echo "[$(date '+%H:%M:%S')] Reconnecting with Last-Event-ID: $LAST_EVENT_ID"
    else
        echo "[$(date '+%H:%M:%S')] Initial connection"
    fi
    
    while IFS= read -r line; do
        echo "$line"
        
        # Extract event ID if present
        if [[ "$line" =~ ^id:\ ([0-9]+) ]]; then
            LAST_EVENT_ID="${BASH_REMATCH[1]}"
        fi
        
        # Check for completion or error
        if [[ "$line" == *"\"status\":\"completed\""* ]] || \
           [[ "$line" == *"\"status\":\"failed\""* ]] || \
           [[ "$line" == *"\"error\""* ]]; then
            echo "[$(date '+%H:%M:%S')] Job finished"
            exit 0
        fi
    done < <(eval "curl -N -s $headers '$URL'")
    
    # If we get here, connection was lost
    echo "[$(date '+%H:%M:%S')] Connection lost, will retry..."
}

# Keep reconnecting until job is done
RETRY_COUNT=0
MAX_RETRIES=100

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    connect_sse
    RETRY_COUNT=$((RETRY_COUNT + 1))
    
    # Exponential backoff (max 5 seconds)
    BACKOFF=$((2 ** RETRY_COUNT))
    if [ $BACKOFF -gt 5 ]; then
        BACKOFF=5
    fi
    
    echo "[$(date '+%H:%M:%S')] Retrying in ${BACKOFF}s (attempt $RETRY_COUNT/$MAX_RETRIES)..."
    sleep $BACKOFF
done

echo "[$(date '+%H:%M:%S')] Max retries reached, giving up"
exit 1
