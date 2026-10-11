import Vapor
import Foundation
import QRScanCore

// MARK: - Routes

func routes(_ app: Application, backend: ScanBackend) throws {
    let jobStore = JobStore()
    let maxPending = Int(Environment.get("WTQRK_MAX_QUEUE") ?? "100") ?? 100
    let jobQueue = JobQueue(store: jobStore, backend: backend, maxPending: maxPending)

    // Upload form UI
    app.get { req -> Response in
        let response = Response(status: .ok)
        response.headers.contentType = .html
        response.body = .init(string: uploadFormHTML)
        return response
    }

    // Serve logo image
    app.get("logo.png") { req -> Response in
        let cwd = DirectoryConfiguration.detect().workingDirectory
        let logoPath = cwd + "william_tells_qr_killer_trimmed.png"
        guard let data = FileManager.default.contents(atPath: logoPath) else {
            throw Abort(.notFound)
        }
        let response = Response(status: .ok)
        response.headers.contentType = .png
        response.body = .init(data: data)
        return response
    }

    // Serve OpenAPI spec
    app.get("openapi.yaml") { req -> Response in
        let cwd = DirectoryConfiguration.detect().workingDirectory
        let specPath = cwd + "openapi.yaml"
        guard let data = FileManager.default.contents(atPath: specPath) else {
            throw Abort(.notFound)
        }
        let response = Response(status: .ok)
        response.headers.contentType = HTTPMediaType(type: "text", subType: "yaml")
        response.body = .init(data: data)
        return response
    }

    // Swagger UI page
    app.get("docs") { req -> Response in
        let response = Response(status: .ok)
        response.headers.contentType = .html
        response.body = .init(string: """
        <!DOCTYPE html>
        <html><head>
        <title>API Docs - William Tells QR Killer</title>
        <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css">
        </head><body>
        <div id="swagger-ui"></div>
        <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
        <script>SwaggerUIBundle({ url: '/openapi.yaml', dom_id: '#swagger-ui' })</script>
        </body></html>
        """)
        return response
    }

    // MARK: - Job Status Polling

    // GET /jobs/:id
    app.get("jobs", ":id") { req async throws -> Response in
        guard let idStr = req.parameters.get("id"),
              let id = UUID(uuidString: idStr)
        else {
            throw Abort(.badRequest, reason: "Invalid job ID")
        }

        guard let job = await jobStore.get(id) else {
            throw Abort(.notFound, reason: "Job not found")
        }

        let statusResponse = JobStatusResponse(
            id: job.id,
            status: job.status.rawValue,
            createdAt: job.createdAt,
            startedAt: job.startedAt,
            completedAt: job.completedAt,
            result: job.result,
            error: job.error
        )

        let response = Response(status: .ok)
        try response.content.encode(statusResponse, as: .json)
        return response
    }

    // MARK: - Async API Endpoints (queue + poll)

    // POST /scan — enqueue single image scan
    app.post("scan") { req async throws -> Response in
        let scanReq = try req.content.decode(ScanRequest.self)

        guard let imageData = Data(base64Encoded: scanReq.imageBase64) else {
            throw Abort(.badRequest, reason: "imageBase64 is not valid base64")
        }

        let config = try (scanReq.config ?? .default).validated()
        let jobId = await jobStore.create()
        try await jobQueue.enqueue(.single(
            id: jobId, imageData: imageData, config: config, earlyExit: true
        ))

        let response = Response(status: .accepted)
        try response.content.encode(JobResponse(id: jobId, status: "queued"), as: .json)
        return response
    }

    // POST /scan/heavy — enqueue heavy scan
    app.post("scan", "heavy") { req async throws -> Response in
        let scanReq = try req.content.decode(ScanRequest.self)

        guard let imageData = Data(base64Encoded: scanReq.imageBase64) else {
            throw Abort(.badRequest, reason: "imageBase64 is not valid base64")
        }

        let config = try (scanReq.config ?? .heavy).validated()
        let jobId = await jobStore.create()
        try await jobQueue.enqueue(.single(
            id: jobId, imageData: imageData, config: config, earlyExit: false
        ))

        let response = Response(status: .accepted)
        try response.content.encode(JobResponse(id: jobId, status: "queued"), as: .json)
        return response
    }

    // POST /scan/batch — enqueue batch scan
    app.post("scan", "batch") { req async throws -> Response in
        let batchReq = try req.content.decode(BatchScanRequest.self)
        guard batchReq.images.count <= 20 else {
            throw Abort(.badRequest, reason: "Batch size exceeds maximum of 20 images")
        }
        let config = try (batchReq.config ?? .default).validated()

        // Validate all base64 upfront before queueing
        var images: [(name: String, data: Data)] = []
        for image in batchReq.images {
            guard let data = Data(base64Encoded: image.imageBase64) else {
                throw Abort(.badRequest, reason: "Invalid base64 for image id: \(image.id)")
            }
            images.append((name: image.id, data: data))
        }

        let jobId = await jobStore.create()
        try await jobQueue.enqueue(.batch(id: jobId, images: images, config: config, earlyExit: true))

        let response = Response(status: .accepted)
        try response.content.encode(JobResponse(id: jobId, status: "queued"), as: .json)
        return response
    }

    // POST /upload — enqueue multipart file upload
    //
    // Accepts: multipart/form-data with field "mode" (optional, "default"|"heavy")
    // and one or more file fields named "files".
    app.on(.POST, "upload", body: .collect(maxSize: "50mb")) { req async throws -> Response in
        // Decode mode field
        let mode: String
        if let modeStr = try? req.content.get(String.self, at: "mode") {
            mode = modeStr
        } else {
            mode = "default"
        }
        let config = mode == "heavy" ? MutationConfig.heavy : MutationConfig.default

        // Collect all uploaded files from the multipart form
        var images: [(name: String, data: Data)] = []

        // Vapor decodes repeated "files" fields as an array when using a Codable struct.
        // Try array first, then single file fallback.
        struct MultiFiles: Content { var files: [File]; var mode: String? }
        struct SingleFile: Content { var files: File; var mode: String? }

        if let multi = try? req.content.decode(MultiFiles.self) {
            for f in multi.files {
                images.append((name: f.filename, data: Data(f.data.readableBytesView)))
            }
        } else if let single = try? req.content.decode(SingleFile.self) {
            images.append((name: single.files.filename, data: Data(single.files.data.readableBytesView)))
        }

        guard !images.isEmpty else {
            throw Abort(.badRequest, reason: "No files uploaded")
        }

        let jobId = await jobStore.create()
        try await jobQueue.enqueue(.batch(id: jobId, images: images, config: config, earlyExit: mode != "heavy"))

        let response = Response(status: .accepted)
        try response.content.encode(JobResponse(id: jobId, status: "queued"), as: .json)
        return response
    }

    // MARK: - Utility Endpoints

    // Readiness, not just liveness: the load balancer health check targets this, so an instance
    // whose sandbox gate failed (or whose slots were all retired) leaves rotation instead of
    // failing every job.
    app.get("health") { req async -> Response in
        let (ready, detail) = await backend.readiness()
        return Response(status: ready ? .ok : .serviceUnavailable,
                        body: .init(string: ready ? "ok" : "not ready: \(detail)"))
    }

    app.get("config") { req -> Response in
        let defaultConfig = MutationConfig.default
        let heavyConfig = MutationConfig.heavy
        let info: [String: Any] = [
            "default": [
                "scales": defaultConfig.resolvedScales,
                "brightnessDeltas": defaultConfig.resolvedBrightnessDeltas,
                "contrastDeltas": defaultConfig.resolvedContrastDeltas,
                "blurRadii": defaultConfig.resolvedBlurRadii,
                "rotationDegrees": defaultConfig.resolvedRotationDegrees,
                "sharpenIntensities": defaultConfig.resolvedSharpenIntensities,
                "totalMutations": defaultConfig.totalMutationCount
            ],
            "heavy": [
                "scales": heavyConfig.resolvedScales,
                "brightnessDeltas": heavyConfig.resolvedBrightnessDeltas,
                "contrastDeltas": heavyConfig.resolvedContrastDeltas,
                "blurRadii": heavyConfig.resolvedBlurRadii,
                "rotationDegrees": heavyConfig.resolvedRotationDegrees,
                "sharpenIntensities": heavyConfig.resolvedSharpenIntensities,
                "totalMutations": heavyConfig.totalMutationCount
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: info, options: .prettyPrinted)
        let response = Response(status: .ok)
        response.headers.contentType = .json
        response.body = .init(data: data)
        return response
    }
}

// MARK: - Upload Form HTML

let uploadFormHTML = ##"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>William Tells QR Killer</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Playfair+Display:wght@600;700;900&family=Source+Sans+3:wght@400;600&family=Source+Code+Pro:wght@400;500&display=swap');

  * { box-sizing: border-box; margin: 0; padding: 0; }

  body {
    font-family: 'Source Sans 3', Georgia, serif;
    background: #1a1610; color: #d4c9a8;
    min-height: 100vh; padding: 2rem;
    background-image:
      radial-gradient(ellipse at 50% 0%, #2a231a 0%, transparent 60%),
      repeating-linear-gradient(0deg, transparent, transparent 50px, #1e1912 50px, #1e1912 51px);
  }

  .header {
    text-align: center; margin-bottom: 2rem;
  }
  .header img {
    width: 160px; height: 160px; border-radius: 50%;
    border: 3px solid #5c4a2a; margin-bottom: 1rem;
    box-shadow: 0 4px 20px rgba(0,0,0,0.5);
  }
  h1 {
    font-family: 'Playfair Display', Georgia, serif;
    font-size: 1.8rem; font-weight: 900; color: #e8dcc0;
    letter-spacing: 0.05em; text-transform: uppercase;
  }
  .subtitle {
    color: #8a7d65; font-size: 0.85rem; margin-top: 0.25rem;
    font-style: italic; letter-spacing: 0.03em;
  }

  .drop-zone {
    border: 2px dashed #4a3d28; border-radius: 10px; padding: 3rem 2rem;
    text-align: center; cursor: pointer; transition: all 0.2s;
    background: #211c14; margin-bottom: 1rem;
  }
  .drop-zone:hover, .drop-zone.dragover {
    border-color: #a08050; background: #28221a;
    box-shadow: inset 0 0 30px rgba(160,128,80,0.05);
  }
  .drop-zone p { color: #8a7d65; font-size: 0.95rem; }
  .drop-zone .formats { color: #5c5040; font-size: 0.75rem; margin-top: 0.5rem; }

  .controls {
    display: flex; gap: 0.75rem; align-items: center;
    margin-bottom: 1.5rem; flex-wrap: wrap;
  }

  .mode-toggle {
    display: flex; background: #28221a; border-radius: 8px;
    overflow: hidden; border: 1px solid #3d3425;
  }
  .mode-toggle label {
    font-size: 0.8rem; cursor: pointer; color: #6b5d45;
  }
  .mode-toggle input { display: none; }
  .mode-toggle input:checked + span { background: #6b5530; color: #e8dcc0; }
  .mode-toggle label span {
    display: block; padding: 0.4rem 0.8rem; border-radius: 6px;
    transition: all 0.15s;
  }

  .file-list { display: flex; flex-wrap: wrap; gap: 0.5rem; margin-bottom: 1rem; }
  .file-tag {
    background: #28221a; border: 1px solid #3d3425; border-radius: 6px;
    padding: 0.3rem 0.6rem; font-size: 0.75rem;
    display: flex; align-items: center; gap: 0.4rem; color: #b0a080;
  }
  .file-tag .remove { cursor: pointer; color: #6b5d45; font-size: 0.9rem; }
  .file-tag .remove:hover { color: #c0463a; }

  button.scan {
    background: #6b5530; color: #e8dcc0; border: 1px solid #8a7040;
    border-radius: 8px; padding: 0.6rem 1.5rem; font-size: 0.85rem;
    font-weight: 600; cursor: pointer; transition: all 0.15s;
    font-family: 'Source Sans 3', Georgia, serif;
    letter-spacing: 0.04em; text-transform: uppercase;
  }
  button.scan:hover { background: #7d6438; border-color: #a08050; }
  button.scan:disabled { opacity: 0.35; cursor: not-allowed; }

  .spinner { display: none; margin-left: 0.5rem; color: #8a7d65; }
  .spinner.active { display: inline-block; animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }

  .results { margin-top: 1rem; }

  .result-card {
    background: #211c14; border: 1px solid #3d3425; border-radius: 10px;
    padding: 1rem 1.25rem; margin-bottom: 0.75rem;
  }
  .result-header {
    display: flex; justify-content: space-between;
    align-items: center; margin-bottom: 0.5rem;
  }
  .result-filename {
    font-family: 'Playfair Display', Georgia, serif;
    font-weight: 600; font-size: 0.9rem; color: #e0d4b8;
  }
  .result-timing {
    color: #6b5d45; font-size: 0.75rem;
    font-family: 'Source Code Pro', monospace;
  }
  .result-payload {
    font-family: 'Source Code Pro', monospace; font-size: 0.8rem;
    color: #b8a060; word-break: break-all;
    padding: 0.5rem 0.75rem; background: #1a1610;
    border: 1px solid #2d2518; border-radius: 6px; margin: 0.5rem 0;
  }
  .result-payload.none { color: #5c5040; font-style: italic; }
  .result-meta { font-size: 0.75rem; color: #6b5d45; }

  .summary-bar {
    background: #28221a; border: 1px solid #3d3425; border-radius: 10px;
    padding: 0.75rem 1.25rem; margin-bottom: 1rem;
    display: flex; gap: 2rem; font-size: 0.8rem;
  }
  .summary-bar .val {
    color: #e0d4b8; font-weight: 600;
    font-family: 'Source Code Pro', monospace;
  }
</style>
</head>
<body>

<div class="header">
  <img src="/logo.png" alt="William Tells QR Killer">
  <h1>William Tells QR Killer</h1>
  <p class="subtitle">Apple Vision QR decoder &middot; <a href="/docs" style="color:#8a7d65;">API Docs</a></p>
</div>

<div class="drop-zone" id="dropZone">
  <p>Drop images here or click to select</p>
  <p class="formats">PNG, JPEG, HEIC, SVG, PDF, WebP, TIFF, GIF, BMP</p>
  <input type="file" id="fileInput" multiple accept="image/*,.svg,.pdf,.heic,.heif,.webp" hidden>
</div>

<div class="file-list" id="fileList"></div>

<div class="controls">
  <div class="mode-toggle">
    <label><input type="radio" name="mode" value="default" checked><span>Scan</span></label>
    <label><input type="radio" name="mode" value="heavy"><span>Heavy</span></label>
  </div>
  <button class="scan" id="scanBtn" disabled>Scan</button>
  <span class="spinner" id="spinner">&#9881;</span>
  <span id="status" style="font-size:0.8rem;color:#8a7d65;"></span>
</div>

<div class="results" id="results"></div>

<script>
const dropZone = document.getElementById('dropZone');
const fileInput = document.getElementById('fileInput');
const fileList = document.getElementById('fileList');
const scanBtn = document.getElementById('scanBtn');
const spinner = document.getElementById('spinner');
const status = document.getElementById('status');
const resultsDiv = document.getElementById('results');
let files = [];

dropZone.addEventListener('click', () => fileInput.click());
dropZone.addEventListener('dragover', e => { e.preventDefault(); dropZone.classList.add('dragover'); });
dropZone.addEventListener('dragleave', () => dropZone.classList.remove('dragover'));
dropZone.addEventListener('drop', e => {
  e.preventDefault(); dropZone.classList.remove('dragover');
  addFiles(e.dataTransfer.files);
});
fileInput.addEventListener('change', () => addFiles(fileInput.files));

function addFiles(newFiles) {
  for (const f of newFiles) files.push(f);
  renderFileList();
}

function removeFile(i) { files.splice(i, 1); renderFileList(); }

function renderFileList() {
  fileList.innerHTML = files.map((f, i) =>
    `<div class="file-tag">${f.name} <span class="remove" onclick="removeFile(${i})">&#215;</span></div>`
  ).join('');
  scanBtn.disabled = files.length === 0;
}

function renderResults(data, elapsed) {
  let html = `<div class="summary-bar">
    <div>Scanned: <span class="val">${data.totalProcessed}</span></div>
    <div>Detected: <span class="val">${data.totalWithDetections}</span></div>
    <div>Total: <span class="val">${elapsed}ms</span></div>
  </div>`;

  for (const r of data.results) {
    const rep = r.report;
    const dets = rep.detections || [];

    const muts = rep.mutationsTried || 0;
    html += `<div class="result-card">`;
    html += `<div class="result-header">
      <span class="result-filename">${r.id}</span>
      <span class="result-timing">${r.durationMs}ms${muts > 0 ? ' &middot; ' + muts + ' mutations' : ' &middot; raw'}</span>
    </div>`;

    if (dets.length > 0) {
      for (const d of dets) {
        html += `<div class="result-payload">${d.payload.replace(/</g,'&lt;')}</div>`;
        const bb = d.boundingBox;
        html += `<div class="result-meta">${d.symbology.replace('VNBarcodeSymbology','')} &middot; bbox: [${bb.x.toFixed(3)}, ${bb.y.toFixed(3)}, ${bb.width.toFixed(3)}, ${bb.height.toFixed(3)}]</div>`;
      }
    } else {
      html += `<div class="result-payload none">No QR code detected</div>`;
    }

    html += `</div>`;
  }

  resultsDiv.innerHTML = html;
}

scanBtn.addEventListener('click', async () => {
  if (files.length === 0) return;

  scanBtn.disabled = true;
  spinner.classList.add('active');
  status.textContent = 'Uploading...';
  resultsDiv.innerHTML = '';

  const formData = new FormData();
  const mode = document.querySelector('input[name="mode"]:checked').value;
  formData.append('mode', mode);
  for (const f of files) formData.append('files[]', f);

  const t0 = performance.now();

  try {
    // Submit to queue
    const resp = await fetch('/upload', { method: 'POST', body: formData });
    const submission = await resp.json();

    if (submission.error) {
      status.textContent = `Error: ${submission.reason || 'Unknown error'}`;
      spinner.classList.remove('active');
      scanBtn.disabled = files.length === 0;
      return;
    }

    const jobId = submission.id;
    status.textContent = 'Queued...';

    // Poll for results
    const poll = setInterval(async () => {
      try {
        const pollResp = await fetch(`/jobs/${jobId}`);
        const job = await pollResp.json();

        if (job.status === 'processing') {
          status.textContent = 'Processing...';
        } else if (job.status === 'completed') {
          clearInterval(poll);
          const elapsed = Math.round(performance.now() - t0);
          status.textContent = `Done in ${elapsed}ms`;
          spinner.classList.remove('active');
          scanBtn.disabled = files.length === 0;

          if (job.result && job.result.batchResponse) {
            renderResults(job.result.batchResponse, elapsed);
          } else if (job.result && job.result.scanReport) {
            renderResults({
              totalProcessed: 1,
              totalWithDetections: job.result.scanReport.detections.length > 0 ? 1 : 0,
              results: [{ id: 'scan', report: job.result.scanReport, durationMs: elapsed }]
            }, elapsed);
          }
        } else if (job.status === 'failed') {
          clearInterval(poll);
          status.textContent = `Error: ${job.error || 'Scan failed'}`;
          spinner.classList.remove('active');
          scanBtn.disabled = files.length === 0;
        }
      } catch (e) {
        clearInterval(poll);
        status.textContent = `Poll error: ${e.message}`;
        spinner.classList.remove('active');
        scanBtn.disabled = files.length === 0;
      }
    }, 500);

  } catch (err) {
    status.textContent = `Error: ${err.message}`;
    spinner.classList.remove('active');
    scanBtn.disabled = files.length === 0;
  }
});
</script>
</body>
</html>
"""##
