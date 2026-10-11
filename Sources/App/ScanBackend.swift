import Foundation
import QRSandbox
import QRScanCore
import Vapor

/// How the web service decodes an image.
///
/// - `sandbox` (default): each image in a fresh `wtqrk-scan` process that the kernel App-Sandboxes
///   at exec (QRSandbox). This server never parses an image itself.
/// - `inprocess` (`WTQRK_SCAN_BACKEND=inprocess`): Vision runs inside this server, the original
///   behaviour. Faster, and only for images you trust.
protocol ScanBackend: Sendable {
    var name: String { get }
    func scan(imageData: Data, config: MutationConfig, earlyExit: Bool) async throws -> ScanReport
    /// Whether a scan can succeed right now (`GET /health`).
    func readiness() async -> (ready: Bool, detail: String)
}

struct InProcessBackend: ScanBackend {
    let pool: ScannerPool
    var name: String { "inprocess (unsandboxed)" }

    func readiness() async -> (ready: Bool, detail: String) { (true, "inprocess") }

    func scan(imageData: Data, config: MutationConfig, earlyExit: Bool) async throws -> ScanReport {
        let engine = await pool.checkout()
        do {
            let report = try await engine.scan(imageData: imageData, config: config, earlyExit: earlyExit)
            await pool.checkin(engine)
            return report
        } catch {
            await pool.checkin(engine)
            throw error
        }
    }
}

struct SandboxedBackend: ScanBackend {
    let scanner: SandboxedScanner
    var name: String { "sandbox (App Sandbox, one process per image)" }

    func readiness() async -> (ready: Bool, detail: String) {
        let gate = await scanner.selfTest()
        if !gate.ok { return (false, "sandbox self-test failed: \(gate.detail)") }
        if !(await scanner.hasUsableSlot) { return (false, "every sandbox slot was retired") }
        return (true, "sandbox")
    }

    struct Failed: Error, LocalizedError {
        let code: String
        let message: String
        var errorDescription: String? { "\(code): \(message)" }
    }

    func scan(imageData: Data, config: MutationConfig, earlyExit: Bool) async throws -> ScanReport {
        let configJSON = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        switch await scanner.scan(data: imageData, heavy: !earlyExit, configJSON: configJSON) {
        case .ok(let s, _, _):
            return ScanReport(
                imageDimensions: ImageDimensions(width: s.imageWidth, height: s.imageHeight),
                mutationsTried: s.mutationsTried,
                detections: s.detections.map {
                    QRDetection(payload: $0.payload, symbology: $0.symbology, confidence: Float($0.confidence),
                                boundingBox: BoundingBox(x: $0.bboxX, y: $0.bboxY, width: $0.bboxW,
                                                         height: $0.bboxH))
                })
        case .rejected(let code, let message), .engineError(let code, let message):
            throw Failed(code: code, message: message)
        }
    }
}

/// Build the backend from the environment. Sandboxed slots use their own identifier range
/// (100+) so they never share a container with a `wtqrk-worker` on the same Mac.
func makeScanBackend(logger: Logger) async throws -> ScanBackend {
    let e = ProcessInfo.processInfo.environment
    let slots = max(1, min(Int(e["WTQRK_SANDBOX_SLOTS"] ?? "") ?? 4, 32))
    switch e["WTQRK_SCAN_BACKEND"] ?? "sandbox" {
    case "inprocess":
        logger.warning("WTQRK_SCAN_BACKEND=inprocess: images are decoded INSIDE this server, unsandboxed")
        return InProcessBackend(pool: ScannerPool(size: slots))
    case "sandbox":
        let scannerPath = e["WTQRK_SCAN_BIN"].flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
                .deletingLastPathComponent().appendingPathComponent("wtqrk-scan").path
        let scanner = try SandboxedScanner(scanner: URL(fileURLWithPath: scannerPath),
                                           slotIndices: Array(100..<(100 + slots)))
        let gate = await scanner.selfTest()
        if gate.ok {
            logger.info("sandboxed scanning: \(gate.detail)")
        } else {
            logger.error("sandboxed scanning: self-test FAILED, every scan will fail: \(gate.detail)")
        }
        return SandboxedBackend(scanner: scanner)
    case let other:
        throw Abort(.internalServerError, reason: "WTQRK_SCAN_BACKEND must be sandbox or inprocess, not \(other)")
    }
}
