import Foundation
import QRScanCore
import Vapor

// MARK: - Request Models

struct ScanRequest: Content {
    let imageBase64: String
    let config: MutationConfig?
}

struct BatchScanRequest: Content {
    let images: [BatchImage]
    let config: MutationConfig?
}

struct BatchImage: Content {
    let id: String
    let imageBase64: String
}

// The scanner's models live in QRScanCore (shared with the sandboxed `wtqrk-scan` CLI, which
// must not link Vapor); the web API serves them as Vapor content.
extension MutationConfig: Content {}
extension ScanReport: Content {}

// MARK: - Batch Response

struct BatchScanResponse: Content {
    let results: [BatchImageReport]
    let totalProcessed: Int
    let totalWithDetections: Int
}

struct BatchImageReport: Codable {
    let id: String
    let report: ScanReport
    let durationMs: Int
}
