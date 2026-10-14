import CryptoKit
import Foundation
import QRScanCore

// The blastbox worker contract, for the native agent: the `metadata.json` envelope the host's
// trust gate re-validates (blastbox `contract/envelope.py`), and the tar it arrives in. The
// payload is the same `wtqrk.scan/1` Record the Python engine emits, so the host, the ingress UI
// and Loadout can't tell which agent produced a result.

public enum BlastboxEnvelope {
    public static let engine = "williamtells"
    public static let schema = "wtqrk.scan/1"

    /// Magic-number sniff of the first bytes, for when the scanner didn't report `inputType`
    /// (a failed scan). No XML parsing here: that runs only inside the sandboxed scanner.
    public static func sniff(_ head: Data) -> (label: String, mime: String) {
        let b = [UInt8](head.prefix(1024))
        func at(_ off: Int, _ magic: [UInt8]) -> Bool {
            b.count >= off + magic.count && Array(b[off..<off + magic.count]) == magic
        }
        let table: [([UInt8], String, String)] = [
            ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "png", "image/png"),
            ([0xFF, 0xD8, 0xFF], "jpeg", "image/jpeg"),
            (Array("GIF87a".utf8), "gif", "image/gif"),
            (Array("GIF89a".utf8), "gif", "image/gif"),
            ([0x49, 0x49, 0x2A, 0x00], "tiff", "image/tiff"),
            ([0x4D, 0x4D, 0x00, 0x2A], "tiff", "image/tiff"),
            (Array("BM".utf8), "bmp", "image/bmp"),
            (Array("%PDF-".utf8), "pdf", "application/pdf"),
        ]
        for (magic, label, mime) in table where at(0, magic) { return (label, mime) }
        if at(0, Array("RIFF".utf8)), at(8, Array("WEBP".utf8)) { return ("webp", "image/webp") }
        if at(4, Array("ftyp".utf8)) {
            for brand in ["heic", "heix", "heim", "heis"] where at(8, Array(brand.utf8)) {
                return ("heic", "image/heic")
            }
            for brand in ["mif1", "msf1"] where at(8, Array(brand.utf8)) {   // generic HEIF brands
                return ("heif", "image/heif")
            }
        }
        return ("unknown", "application/octet-stream")
    }

    public static func sha256(fileAt path: String) throws -> String {
        let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? fh.close() }
        var hasher = SHA256()
        while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The sealed envelope for one scan outcome. `detected` is the type the scanner reported
    /// for a completed scan (it parsed the input, sandboxed), else the magic-number sniff.
    public static func envelope(outcome: ScanOutcome, inputSHA256: String, head: Data) -> [String: Any] {
        var (label, mime) = sniff(head)
        if case .ok(let scan, _, _) = outcome, let t = scan.inputType, let m = QRScannerEngine.inputMIMEs[t] {
            (label, mime) = (t, m)
        }
        let detected: [String: Any] = ["label": label, "mime": mime,
                                       "confidence": label == "unknown" ? 0.0 : 1.0, "source": engine]
        func env(status: String, fields: [String: Any], warnings: [ScanWarning]) -> [String: Any] {
            ["engine": engine, "status": status, "input_sha256": inputSHA256, "detected": detected,
             "artifacts": [Any](),
             "warnings": warnings.map { ["code": String($0.code.prefix(64)), "message": String($0.message.prefix(2000))] },
             "payload": ["_type": "record", "fields": fields]]
        }
        switch outcome {
        case .ok(let scan, let warnings, _):
            var dets: [String: Any] = [:]
            for (i, d) in scan.detections.enumerated() {
                dets[String(i)] = ["_type": "record", "fields": [
                    "payload": d.payload, "symbology": d.symbology, "confidence": d.confidence,
                    "bbox_x": d.bboxX, "bbox_y": d.bboxY, "bbox_w": d.bboxW, "bbox_h": d.bboxH,
                ] as [String: Any]]
            }
            return env(status: "ok", fields: [
                "schema": schema, "mode": scan.mode, "compute": scan.compute,
                "image_width": scan.imageWidth, "image_height": scan.imageHeight,
                "mutations_tried": scan.mutationsTried, "detection_count": scan.detections.count,
                "payloads": scan.detections.map(\.payload),
                "detections": ["_type": "record", "fields": dets],
            ], warnings: warnings)
        case .rejected(let code, let message):
            return env(status: "rejected", fields: ["schema": schema, "error": String(code.prefix(64))],
                       warnings: [ScanWarning(code: code, message: message)])
        case .engineError(let code, let message):
            return env(status: "engine_error", fields: ["schema": schema, "error": String(code.prefix(64))],
                       warnings: [ScanWarning(code: code, message: message)])
        }
    }

    public static func metadataJSON(_ envelope: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    /// A ustar archive holding exactly one regular file.
    public static func tar(name: String, contents: Data, mtime: Date = Date()) -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ s: String, at off: Int, len: Int) {
            let bytes = Array(s.utf8.prefix(len))
            header.replaceSubrange(off..<off + bytes.count, with: bytes)
        }
        func octal(_ v: Int, at off: Int, len: Int) {
            put(String(String(v, radix: 8).suffix(len - 1)).leftPad(len - 1) , at: off, len: len - 1)
        }
        put(name, at: 0, len: 100)
        octal(0o644, at: 100, len: 8)
        octal(0, at: 108, len: 8)
        octal(0, at: 116, len: 8)
        octal(contents.count, at: 124, len: 12)
        octal(Int(mtime.timeIntervalSince1970), at: 136, len: 12)
        header.replaceSubrange(148..<156, with: Array(repeating: 0x20, count: 8))  // checksum = spaces
        header[156] = UInt8(ascii: "0")
        put("ustar\0", at: 257, len: 6)
        put("00", at: 263, len: 2)
        let sum = header.reduce(0) { $0 + Int($1) }
        put(String(String(sum, radix: 8)).leftPad(6), at: 148, len: 6)
        header[154] = 0
        header[155] = 0x20
        var out = Data(header)
        out.append(contents)
        let pad = (512 - contents.count % 512) % 512
        out.append(Data(count: pad + 1024))   // pad + two zero blocks
        return out
    }
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: "0", count: n - count) + self }
}
