# Murmur

> [!IMPORTANT]
> The main code for this repo is hosted on [tangled](https://tangled.org/dunkirk.sh/murmur) so please report issues there :)

```bash
.
├── Sources
│   └── murmur
│       ├── Controllers
│       │   └── TranscriptionController.swift
│       ├── Migrations
│       │   └── CreateMurmurJob.swift
│       ├── Models
│       │   └── MurmurJob.swift
│       ├── Services
│       │   └── TranscriptionService.swift
│       └── murmur.swift
├── Package.swift
├── SPEC.md
└── README.md
```

## What's this?

This is a job-based whisper server using [`argmaxinc/WhisperKit`](https://github.com/argmaxinc/WhisperKit) to be super fast on M-series Apple hardware. It was primarily designed to complement [`dunkirk.sh/thistle`](https://tangled.org/@dunkirk.sh/thistle) as there weren't really any other whisper servers that worked in the way I wanted.

**Key Features:**
- 🚀 **Hardware accelerated** - Uses Apple's Neural Engine for 2-5x faster transcription
- 🔄 **Job-based API** - Async transcription with real-time progress updates via SSE
- 🔌 **Drop-in replacement** - API compatible with Python whisper servers
- 📦 **Self-contained** - No Python dependencies, just Swift + WhisperKit
- 💾 **Persistent storage** - SQLite database for job state and recovery

## Requirements

- macOS 13+ 
- Apple Silicon Mac (M1/M2/M3 for Neural Engine acceleration)
- Swift 5.9+
- 4GB+ RAM (depends on model size)

## How do I hack on it?

### Quick Start

```bash
# Clone the repository
git clone https://github.com/taciturnaxolotl/murmur.git
cd murmur

# Build the project
swift build

# Run the development server (defaults to port 8000)
swift run
```

First run will download the Whisper model (~244MB for "small" model). The server will show:
```
[ INFO ] Initializing WhisperKit...
[ INFO ] WhisperKit initialized successfully
[ INFO ] Murmur server starting on 0.0.0.0:8000
```

### Configuration

Environment variables (see `.env.example`):

- **`PORT`**: Server port (default: `8000`)
- **`HOST`**: Server host (default: `0.0.0.0`)
- **`WHISPER_MODEL`**: Model size (default: `small`)
  - Options: `tiny`, `base`, `small`, `medium`, `large-v3`
  - Tiny = fastest, Large = most accurate
- **`DATABASE_PATH`**: SQLite database location (default: `./murmur.db`)

Example:
```bash
PORT=3000 WHISPER_MODEL=tiny swift run
```

### Testing

Your server will be running at `http://localhost:8000` and you can test it with curl:

```bash
# Upload an audio file for transcription
curl -X POST http://localhost:8000/transcribe \
  -F "file=@audio.wav"
# Returns: {"job_id":"uuid-string"}

# Get job status
curl http://localhost:8000/transcribe/{job_id}
# Returns: {"status":"processing","progress":45.5,"transcript":"...","error_message":""}

# Stream real-time progress updates (SSE)
curl -N http://localhost:8000/transcribe/{job_id}/stream

# List all jobs
curl http://localhost:8000/jobs

# Delete a job
curl -X DELETE http://localhost:8000/transcribe/{job_id}
```

Supported audio formats: `wav`, `mp3`, `m4a`, `flac`

## API Documentation

### POST `/transcribe`
Upload audio file and start transcription job.

**Request:**
```bash
curl -X POST http://localhost:8000/transcribe \
  -F "file=@audio.wav"
```

**Response:**
```json
{
  "job_id": "a1b2c3d4-5678-90ab-cdef-1234567890ab"
}
```

### GET `/transcribe/:job_id`
Get current status of a transcription job.

**Request:**
```bash
curl http://localhost:8000/transcribe/a1b2c3d4-5678-90ab-cdef-1234567890ab
```

**Response:**
```json
{
  "status": "transcribing",
  "progress": 45.5,
  "transcript": "Hello world this is a partial transcript...",
  "error_message": ""
}
```

**Status values:** `pending` → `processing` → `transcribing` → `completed` or `failed`

### GET `/transcribe/:job_id/stream`
Stream real-time progress updates via Server-Sent Events with automatic reconnection support.

**Request:**
```bash
curl -N http://localhost:8000/transcribe/a1b2c3d4-5678-90ab-cdef-1234567890ab/stream
```

**Request with reconnection:**
```bash
curl -N -H "Last-Event-ID: 1704067180" http://localhost:8000/transcribe/a1b2c3d4-5678-90ab-cdef-1234567890ab/stream
```

**Response:** SSE stream with event IDs (polls every 500ms, sends updates + heartbeats)
```
id: 1704067200
event: update
data: {"status":"pending","progress":0,"transcript":"","error_message":""}

id: 1704067205
event: update
data: {"status":"processing","progress":0,"transcript":"","error_message":""}

: heartbeat

id: 1704067210
event: update
data: {"status":"transcribing","progress":12.3,"transcript":"Hello world","error_message":""}

: heartbeat

id: 1704067245
event: update
data: {"status":"completed","progress":100,"transcript":"Hello world this is a test transcription.","error_message":""}
```

**Features:**
- Event IDs allow resuming from last received update on reconnection
- Heartbeat comments (`: heartbeat`) keep connection alive every ~2.5 seconds
- Automatically retries job lookup for 5 seconds before sending error
- Stream closes when job completes or fails

**Resilient client example:**
```bash
./test_reconnect.sh <job_id>
```

### GET `/jobs`
List all transcription jobs (newest first).

**Request:**
```bash
curl http://localhost:8000/jobs
```

**Response:**
```json
{
  "jobs": [
    {
      "id": "a1b2c3d4-5678-90ab-cdef-1234567890ab",
      "status": "completed",
      "progress": 100,
      "created_at": 1704067200,
      "updated_at": 1704067245
    },
    {
      "id": "b2c3d4e5-6789-01bc-def0-2345678901bc",
      "status": "transcribing",
      "progress": 67.2,
      "created_at": 1704067150,
      "updated_at": 1704067180
    }
  ]
}
```

### DELETE `/transcribe/:job_id`
Delete a job from the database.

**Request:**
```bash
curl -X DELETE http://localhost:8000/transcribe/a1b2c3d4-5678-90ab-cdef-1234567890ab
```

**Response:**
```json
{
  "success": true
}
```

## Integration with Thistle

Murmur is a drop-in replacement for Python-based whisper servers. Just update your environment:

```bash
# In your Thistle .env file
WHISPER_SERVICE_URL=http://localhost:8000
```

No code changes required!

## Production Deployment

### Build for Production

```bash
swift build -c release
.build/release/murmur
```

### Running as a Service

Example `launchd` plist (macOS):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.murmur.server</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/murmur/.build/release/murmur</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/path/to/murmur</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PORT</key>
        <string>8000</string>
        <key>WHISPER_MODEL</key>
        <string>small</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/murmur.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/murmur.error.log</string>
</dict>
</plist>
```

## Performance

### Expected Performance (M1/M2 with Neural Engine)

| Model | Speed | Memory | Accuracy |
|-------|-------|--------|----------|
| tiny | ~10x realtime | ~500MB | Good |
| base | ~8x realtime | ~750MB | Better |
| small | ~5x realtime | ~1GB | Great |
| medium | ~3x realtime | ~1.5GB | Excellent |
| large-v3 | ~2x realtime | ~2GB | Best |

Compared to Python/faster-whisper on CPU: **2-5x faster** with lower power consumption.

## Contributing

This project uses standard commits and PRs are welcome on [tangled](https://tangled.org/dunkirk.sh/murmur).

### Project Structure

- **Models**: Database entities (Fluent ORM)
- **Controllers**: HTTP request handlers (Vapor)
- **Services**: Business logic (WhisperKit transcription)
- **Migrations**: Database schema management

### Development Tips

- Use `swift run` for quick iteration
- Check logs for transcription progress
- Press Ctrl+C for clean shutdown
- Database auto-migrates on startup

## Troubleshooting

### "Payload Too Large" error
The default max body size is 500MB. For larger files, increase in `configure()`:
```swift
app.routes.defaultMaxBodySize = "1gb"
```

### Core Audio errors
Ensure audio file format is supported (wav, mp3, m4a, flac). The server auto-detects format from file extension.

### Model download issues
First run downloads models from HuggingFace. Ensure internet connection and adequate disk space (~244MB for small model).

### Performance issues
- Use smaller models (tiny/base) for faster transcription
- Ensure running on Apple Silicon for Neural Engine acceleration
- Check Activity Monitor for thermal throttling

### SSE stream disconnections
If the SSE stream disconnects and you need to reconnect:
- Use the `Last-Event-ID` header to resume from where you left off
- The server keeps jobs in the database until explicitly deleted
- Use `test_reconnect.sh` for automatic reconnection with exponential backoff
- Server retries job lookups for 5 seconds before reporting "Job not found"

## License

MIT License - See [LICENSE.md](LICENSE.md)

<p align="center">
	<img src="https://raw.githubusercontent.com/taciturnaxolotl/carriage/master/.github/images/line-break.svg" />
</p>

<p align="center">
	&copy 2025-present <a href="https://github.com/taciturnaxolotl">Kieran Klukas</a>
</p>

<p align="center">
	<a href="https://github.com/taciturnaxolotl/murmur/blob/main/LICENSE.md"><img src="https://img.shields.io/static/v1.svg?style=for-the-badge&label=License&message=MIT&logoColor=d9e0ee&colorA=363a4f&colorB=b7bdf8"/></a>
</p>
