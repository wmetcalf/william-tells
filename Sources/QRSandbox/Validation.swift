import Foundation
import QRScanCore

/// One detection, validated and flattened (the shape the blastbox envelope carries).
public struct ValidDetection: Sendable, Equatable, Codable {
    public let payload: String
    public let symbology: String
    public let confidence: Double
    public let bboxX: Double, bboxY: Double, bboxW: Double, bboxH: Double
}

public struct ValidScan: Sendable, Codable {
    public let mode: String
    public let compute: String
    public let imageWidth: Int
    public let imageHeight: Int
    public let mutationsTried: Int
    public let detections: [ValidDetection]
    /// The scanner's `inputType`, already checked against `QRScannerEngine.inputMIMEs`.
    public var inputType: String? = nil
}

public struct ScanWarning: Sendable, Equatable, Codable {
    public let code: String
    public let message: String
}

public enum ParsedScan: Sendable {
    case ok(ValidScan, warnings: [ScanWarning])
    /// The scanner itself reported failure (`ok: false`), with its own code + message.
    case failed(code: String, message: String)
}

public struct OutputError: Error, CustomStringConvertible {
    public let description: String
    init(_ d: String) { description = d }
}

/// Validates `wtqrk-scan`'s output. That process just parsed a hostile image, so its stdout is
/// UNTRUSTED: a compromised scanner can still lie about what it found (the sandbox bounds what it
/// can reach, not what it says), but it cannot get oversized, mistyped or out-of-range data past
/// this point. Same rules as the Python engine's `parse_scan_output`.
public enum ScanOutputValidator {
    public static let maxStdoutBytes = 4 << 20
    public static let maxDetections = 256
    public static let maxPayloadChars = 4096

    public static func parse(_ stdout: Data) throws -> ParsedScan {
        guard stdout.count <= maxStdoutBytes else { throw OutputError("scanner output exceeds \(maxStdoutBytes) bytes") }
        guard let doc = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] else {
            throw OutputError("scanner output is not a JSON object")
        }
        guard doc["schema"] as? String == "wtqrk.scan/1" else { throw OutputError("scanner output has the wrong schema") }
        var inputType: String? = nil
        if let t = doc["inputType"], !(t is NSNull) {
            guard let label = t as? String, QRScannerEngine.inputMIMEs[label] != nil else {
                throw OutputError("inputType must be one of \(QRScannerEngine.inputMIMEs.keys.sorted())")
            }
            inputType = label
        }
        guard isTrue(doc["ok"]) else {
            let err = doc["error"] as? [String: Any] ?? [:]
            return .failed(code: clip(err["code"] as? String ?? "scan_failed", 64),
                           message: clip(err["message"] as? String ?? "", 2000))
        }
        guard let report = doc["report"] as? [String: Any] else { throw OutputError("report missing") }
        let dims = report["imageDimensions"] as? [String: Any] ?? [:]
        guard let raw = report["detections"] as? [Any] else { throw OutputError("detections must be a list") }

        var warnings: [ScanWarning] = []
        if raw.count > maxDetections {
            warnings.append(ScanWarning(code: "detections_truncated",
                                        message: "kept \(maxDetections) of \(raw.count) detections"))
        }
        var dets: [ValidDetection] = []
        for item in raw.prefix(maxDetections) {
            guard let d = item as? [String: Any] else { throw OutputError("detection must be an object") }
            guard let payload = d["payload"] as? String else { throw OutputError("payload must be a string") }
            if payload.count > maxPayloadChars {
                warnings.append(ScanWarning(code: "payload_truncated",
                                            message: "a payload was cut to \(maxPayloadChars) chars"))
            }
            guard let bb = d["boundingBox"] as? [String: Any] else { throw OutputError("boundingBox must be an object") }
            guard let sym = d["symbology"] as? String else { throw OutputError("symbology must be a string") }
            // Vision boxes are normalized; mutations can push them slightly outside [0, 1].
            dets.append(ValidDetection(
                payload: clip(payload, maxPayloadChars), symbology: clip(sym, 64),
                confidence: try num(d["confidence"], 0, 1),
                bboxX: try num(bb["x"], -10, 10), bboxY: try num(bb["y"], -10, 10),
                bboxW: try num(bb["width"], 0, 10), bboxH: try num(bb["height"], 0, 10)))
        }
        guard let mode = doc["mode"] as? String, let compute = doc["compute"] as? String else {
            throw OutputError("mode/compute must be strings")
        }
        return .ok(ValidScan(mode: clip(mode, 16), compute: clip(compute, 16),
                             imageWidth: try int(dims["width"], 1, 1 << 20),
                             imageHeight: try int(dims["height"], 1, 1 << 20),
                             mutationsTried: try int(report["mutationsTried"], 0, 10_000),
                             detections: dets, inputType: inputType),
                   warnings: warnings)
    }

    static func isTrue(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID() && n.boolValue
    }

    static func isNumber(_ v: Any?) -> NSNumber? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n
    }

    static func num(_ v: Any?, _ lo: Double, _ hi: Double) throws -> Double {
        guard let n = isNumber(v), n.doubleValue.isFinite, (lo...hi).contains(n.doubleValue) else {
            throw OutputError("not a finite number in [\(lo), \(hi)]: \(String(describing: v))")
        }
        return n.doubleValue
    }

    static func int(_ v: Any?, _ lo: Int, _ hi: Int) throws -> Int {
        guard let n = isNumber(v), n.doubleValue == n.doubleValue.rounded(),
              let i = Int(exactly: n.doubleValue), (lo...hi).contains(i) else {
            throw OutputError("not an int in [\(lo), \(hi)]: \(String(describing: v))")
        }
        return i
    }

    static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) : s }

    /// Strict `WTQRK_CONFIG`: an object of known keys, each a list of at most 10 finite numbers.
    /// Returns canonical JSON for the scanner's `--config-json`.
    public static func canonicalConfig(_ raw: String) throws -> String {
        let keys: Set<String> = ["scales", "brightnessDeltas", "contrastDeltas", "blurRadii",
                                 "rotationDegrees", "sharpenIntensities"]
        guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              Set(obj.keys).isSubset(of: keys) else {
            throw OutputError("WTQRK_CONFIG must be an object with keys from \(keys.sorted())")
        }
        for (k, v) in obj {
            guard let list = v as? [Any], list.count <= 10,
                  list.allSatisfy({ isNumber($0)?.doubleValue.isFinite == true }) else {
                throw OutputError("WTQRK_CONFIG.\(k) must be a list of at most 10 finite numbers")
            }
        }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
