#!/bin/bash

# Upload a small audio file
echo "Uploading audio file..."
RESPONSE=$(curl -s -X POST http://localhost:8000/transcribe -F "file=@test.wav" 2>/dev/null || echo '{"job_id":"test-job-id"}')
JOB_ID=$(echo $RESPONSE | grep -o '"job_id":"[^"]*"' | cut -d'"' -f4)

echo "Job ID: $JOB_ID"
echo ""
echo "SSE Stream output:"
echo "===================="

# Stream the results
curl -N http://localhost:8000/transcribe/$JOB_ID/stream

