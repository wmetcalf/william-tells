# William Tells QR Killer

<p align="center">
  <img src="william_tells_qr_killer_trimmed.png" alt="William Tells QR Killer" width="300">
  <br><br>
  <a href="https://suno.com/s/8ySO7rhVdKfcSQ6I">Theme Song</a>
</p>

QR code decoder using Apple's Vision framework. Runs on any Mac (local or AWS mac2 instances) and decodes QR codes exactly the way an iPhone does — including obfuscated codes that open-source decoders (ZXing, pyzbar, ZBar) miss.

Includes a web UI for drag-and-drop scanning and an async job queue API for programmatic use.

## Why Apple Vision?

Open-source QR decoders behave differently than Apple's. A QR code that an iPhone reads may decode differently (or not at all) in ZXing/pyzbar. This service gives you identical decode behavior to iOS in a scriptable API.

For hard-to-read QR codes (low contrast, darkened, blurred), the service applies image mutations — brightness, contrast, scale, blur, rotation, sharpen — simulating what an iPhone camera does physically when pointing at a screen.

## Requirements

- macOS 13+ (Ventura or later)
- Swift 5.9+
- Xcode Command Line Tools
- Apple Silicon recommended (M1/M2 — uses Metal GPU + Neural Engine)

## Quick Start

> The Vapor server below decodes uploads **in-process and unsandboxed**. That's fine on your own
> machine with your own images. For untrusted input, or to plug into Loadout, deploy the
> [sandboxed blastbox engine](#sandboxed-scanning-with-blastbox) instead.

```bash
# Build
swift build -c release

# Run
.build/release/App
# Listening on http://0.0.0.0:8080

# Open the web UI
open http://localhost:8080
```

## Authentication

Optional basic auth via environment variables:

```bash
WTQRK_USER=admin WTQRK_PASS=secret .build/release/App
```

When set, all endpoints except `/health` require basic auth. When unset, no auth is required.

## Web UI

Visit `http://localhost:8080` for a drag-and-drop interface. Supports multiple files, shows decoded payloads with bounding boxes and mutation counts.

Supported formats: PNG, JPEG, HEIC, HEIF, WebP, TIFF, GIF, BMP, SVG, PDF.

## API

All scan endpoints are async — they return a job ID immediately (HTTP 202) and you poll for results.

### Submit a scan

**`POST /scan`** — Single image, default config (~60 mutations, early exit on first detection)

```bash
B64=$(base64 -i qr_image.png)

# Submit
curl -X POST http://localhost:8080/scan \
  -H "Content-Type: application/json" \
  -d "{\"imageBase64\": \"$B64\"}"
```

Response (202 Accepted):
```json
{
  "id": "1C28E693-FDA6-42F4-8F2A-A5E8CB8A8DCC",
  "status": "queued"
}
```

**`POST /scan/heavy`** — Full mutation sweep (~10,000 mutations, no early exit). Use when `/scan` finds nothing.

**`POST /scan/batch`** — Multiple images in one request (max 20):

```json
{
  "images": [
    { "id": "img-001", "imageBase64": "..." },
    { "id": "img-002", "imageBase64": "..." }
  ],
  "config": { }
}
```

**`POST /upload`** — Multipart file upload (used by the web UI).

### Poll for results

**`GET /jobs/:id`**

```bash
curl http://localhost:8080/jobs/1C28E693-FDA6-42F4-8F2A-A5E8CB8A8DCC
```

Status values: `queued`, `processing`, `completed`, `failed`.

Completed response:
```json
{
  "id": "1C28E693-FDA6-42F4-8F2A-A5E8CB8A8DCC",
  "status": "completed",
  "createdAt": "2026-03-25T12:00:00Z",
  "startedAt": "2026-03-25T12:00:00Z",
  "completedAt": "2026-03-25T12:00:01Z",
  "result": {
    "scanReport": {
      "imageDimensions": { "width": 800, "height": 823 },
      "mutationsTried": 0,
      "detections": [
        {
          "payload": "https://example.com",
          "symbology": "VNBarcodeSymbologyQR",
          "confidence": 1.0,
          "boundingBox": { "x": 0.35, "y": 0.35, "width": 0.34, "height": 0.22 }
        }
      ]
    }
  }
}
```

`mutationsTried: 0` means the QR decoded on the raw image (no mutations needed).

### Utility endpoints

- **`GET /health`** — Returns `ok`. No auth required.
- **`GET /config`** — Returns default and heavy mutation configs with total mutation counts.

## Custom Mutation Config

Override the default mutations by passing a `config` object:

```json
{
  "imageBase64": "...",
  "config": {
    "scales": [0.75, 1.0, 1.5],
    "brightnessDeltas": [-0.3, 0.0, 0.3],
    "contrastDeltas": [-0.1, 0.0],
    "blurRadii": [0.0, 1.0],
    "rotationDegrees": [0.0],
    "sharpenIntensities": [0.0]
  }
}
```

Limits: max 10 values per dimension, max 10,000 total mutations. Scale must be in (0, 5.0], blur in [0, 10.0].

## How Mutations Work

The raw image is tried first. If no QR is detected, mutations are applied via CoreImage on the Metal GPU:

| Mutation | Simulates |
|----------|-----------|
| Scale | Phone distance from screen |
| Brightness | Auto-exposure adjusting to ambient light |
| Contrast | Screen brightness vs room lighting |
| Blur | Camera focus hunting |
| Rotation | Phone tilt |
| Sharpen | Camera snapping to focus |

Default config covers brightness extremes and contrast adjustments that catch most obfuscated QR codes in ~60 mutations. Heavy mode does a full sweep across all axes (~6,000 mutations).

## Architecture

```
HTTP requests ──> Vapor (async) ──> Job Queue (FIFO)
                                        │
                                   Scanner Pool (8 engines)
                                   ┌────┬────┬────┬───┐
                                   │ E1 │ E2 │ .. │ E8│
                                   └────┴────┴────┴───┘
                                        │
                              Metal GPU + Neural Engine
```

- **8 QRScannerEngine instances** in a pool, each with its own Metal-backed CIContext
- **8 worker tasks** pull jobs from an AsyncStream FIFO queue
- **Semaphore-style checkout/checkin** — when all engines are busy, jobs wait in queue
- **Bounded queue** — rejects with 429 when the queue exceeds `WTQRK_MAX_QUEUE` (default 100)
- Input validation (bad base64, config limits, batch size) returns 400 immediately before queueing
- Completed/failed jobs are evicted after 1 hour

## Supported Barcode Types

QR, Micro QR, Data Matrix, PDF417, Aztec, Code 128, Code 39, Code 93, EAN-8, EAN-13, UPC-E, ITF-14, GS1 DataBar, GS1 DataBar Expanded, Codabar.

## AWS Deployment

Tested on `mac2.metal` (M1). Should work on any Apple Silicon EC2 instance type (`mac2-m2.metal`, `mac2-m2pro.metal`, etc.).

> **Cost warning:** EC2 Mac instances require a dedicated host, and AWS enforces a **minimum 24-hour allocation** (Apple licensing requirement). You will be billed for the full 24 hours even if you only use the instance for 10 minutes. Plan accordingly.

A Terraform config is included in `terraform/` that provisions everything — dedicated host, EC2 instance, VPC, ALB with HTTPS, ACM certificate, and Route53 DNS.

### Terraform setup

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your values:

| Variable | Description |
|----------|-------------|
| `hostname` | FQDN for the service (e.g. `qrscanner.yourdomain.com`) |
| `hosted_zone_id` | Route53 hosted zone ID for your domain |
| `key_name` | EC2 key pair name for SSH access |
| `private_key_path` | Path to the corresponding private key file |
| `ssh_allowed_cidrs` | Your IP(s) for SSH access (e.g. `["1.2.3.4/32"]`) |
| `wtqrk_user` / `wtqrk_pass` | Optional — basic auth credentials |

Then deploy:

```bash
terraform init
terraform plan
terraform apply
```

Terraform handles the build, launchd service install, and health check automatically via SSH provisioning.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8080` | HTTP listen port |
| `WTQRK_USER` | _(none)_ | Basic auth username (both must be set to enable) |
| `WTQRK_PASS` | _(none)_ | Basic auth password |
| `WTQRK_MAX_QUEUE` | `100` | Max pending jobs before 429 rejection |

## Sandboxed scanning with blastbox

Vision, ImageIO and CoreGraphics are high-value exploit targets (FORCEDENTRY went through
CoreGraphics, BLASTPASS through ImageIO's WebP decoder), and the Vapor service above feeds them
untrusted images **in one long-lived, unsandboxed process**. Keep it for local use. For hostile
input, run William Tells as the [blastbox](https://github.com/wmetcalf/blastbox) engine
`williamtells`: **one image per process, each in a fresh macOS sandbox** with the GPU and Neural
Engine granted, and no network, no home directory, and no state carried between images. It is
deployed like ClippyShot, RedTusk and titanarum, so [Loadout](https://github.com/wmetcalf/loadout)
drives it the same way.

```
client / Loadout ──▶ blastbox serve ──▶ queue ──▶ blastbox dispatch ──▶ Mac: http_agent ──▶ seatbelt ──▶ wtqrk-scan
                     (+ this UI)                  (static pool)         WilliamTellsEngine    (per image)
```

The ingress and dispatcher never decode an image; only the sandboxed `wtqrk-scan` does. They
can run on the Mac (Mac-only) or on Linux next to the other engines, with Macs as the pool.

| Path | What |
|---|---|
| `Sources/wtqrk-scan/` | One-shot CLI: `scan <image>` → one JSON document on stdout; `self-test`; `render-qr`; `devices`. No Vapor. |
| `Sources/QRScanCore/` | The scanner and models, shared by the Vapor service and the CLI. Raster input goes through an ImageIO type allowlist and a 100 M-pixel cap checked before decode. |
| `python/william_tells/blastbox_engine.py` | The engine. Validates the CLI's (untrusted) output and maps it to a generic `Record` (`wtqrk.scan/1`). |
| `python/william_tells/blastbox_ingress.py` + `static/` | Ingress extension: this web UI at `/` and `/jobs/<id>`, on top of the core `/v1/jobs` API. |
| `deploy/blastbox/williamtells-host.env.example` | Ingress + dispatcher config (one file both source). |
| `deploy/blastbox/williamtells-worker.env.example` | Mac worker-agent config. |

### Install a Mac worker

```bash
swift build -c release                              # builds App and wtqrk-scan
.build/release/wtqrk-scan self-test                 # decodes a generated QR (on the ANE when present)

pip install -e python/                              # pulls in blastbox[host]
blastbox macos doctor --backend seatbelt --accelerator gpu --accelerator ane \
    -- "$PWD/.build/release/wtqrk-scan" self-test   # sandbox confines AND the scanner works in it
```

Then run the agent with `williamtells-worker.env.example` in blastbox's
`deploy/macos/io.blastbox.worker-agent.plist`. For a Mac-only deployment, also load
`io.blastbox.ingress.plist` and `io.blastbox.dispatcher.plist` from the same directory, both
pointed at your copy of `williamtells-host.env.example`.

### Use it

```bash
curl -F file=@qr.png -F engine=williamtells -F params=WTQRK_MODE=heavy http://HOST:8005/v1/jobs
curl http://HOST:8005/v1/jobs/<job_id>              # status; result_summary.meta.detection_count
curl http://HOST:8005/v1/jobs/<job_id>/metadata     # the decoded payloads (payload.fields.payloads)
curl http://HOST:8005/v1/jobs/<job_id>/attestation  # signed receipt (with BLASTBOX_ATTEST_KEY)
```

Job params (allowlisted on the dispatcher), each sent as its own `params=KEY=VALUE` field:
`WTQRK_MODE=default|heavy` (same as `/scan` and `/scan/heavy`) and
`WTQRK_CONFIG=<mutation config JSON>` (same shape and limits as the API's `config`).

**Loadout.** Loadout talks to the ingress (`LOADOUT_WILLIAMTELLS_URL=http://HOST:8005`), maps its
`mode` setting to `WTQRK_MODE`, and turns each decoded payload into a `url` or `qr_code` artifact.

**Self-test gate.** If a sandbox grant goes missing, Vision usually doesn't fail; it returns *no
detections*. The engine runs `wtqrk-scan self-test` in the same sandbox before trusting any
result, and returns `engine_error` (never "no QR found") for every job while it fails. Run
`blastbox macos doctor` after every macOS update.

**Latency** (M4 Pro, macOS 26.6, one QR PNG): 87 ms unsandboxed; 153 ms under `seatbelt`; 95 ms
under `appsandbox`; about 270 ms end to end through ingress, dispatcher and agent. The self-test
builds a Neural Engine plan cache once; each job gets a copy-on-write clone of it, and nothing
flows back.

## License

This project is licensed under the [MIT License](LICENSE).

This software uses Apple's Vision framework and CoreImage, which are proprietary frameworks included with macOS. Running this software requires macOS and is subject to the [Apple macOS Software License Agreement](https://www.apple.com/legal/sla/).
