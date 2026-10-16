import CoreImage
import Foundation

// One scan / self-test, as run by the sandboxed `wtqrk-scan` process. Kept here (not in the CLI)
// so the documents it emits and the sandbox host that validates them share one definition.

public let scanSchema = "wtqrk.scan/1"
public let selfTestSchema = "wtqrk.self-test/1"

public struct ScanErrorBody: Codable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// The scanner's one output document. `ok == false` carries `error`.
public struct ScanOutput: Codable, Sendable {
    public let schema: String
    public let ok: Bool
    public let mode: String?
    public let compute: String?
    public let report: ScanReport?
    public let error: ScanErrorBody?
    /// What the input was (a `QRScannerEngine.inputMIMEs` label), when it is a type the scanner
    /// accepts; the envelope's `detected` comes from here.
    public let inputType: String?

    public init(schema: String, ok: Bool, mode: String?, compute: String?, report: ScanReport?,
                error: ScanErrorBody?, inputType: String? = nil) {
        self.schema = schema
        self.ok = ok
        self.mode = mode
        self.compute = compute
        self.report = report
        self.error = error
        self.inputType = inputType
    }
}

public struct SelfTestCase: Codable, Sendable {
    public let compute: String
    public let ok: Bool
    public let expected: String
    public let got: [String]
    public let error: String?
    public let ms: Int
}

public struct SelfTestOutput: Codable, Sendable {
    public let schema: String
    public let ok: Bool
    public let devices: [String]
    public let cases: [SelfTestCase]
    /// Whether the kernel had this process sandboxed when it ran (`sandbox_check`). A sandbox
    /// host requires `true`: a scanner that silently ran unconfined must not pass the gate.
    public let sandboxed: Bool?
}

/// Exit codes shared by the CLI and its sandbox host.
public enum ScanExit: Int32, Sendable {
    case ok = 0, failure = 1, badInput = 2, badConfig = 3, usage = 64
}

public enum ScanJob {
    /// Scan one image. Same early-exit semantics as the web API: default stops at the first
    /// hit, heavy sweeps every mutation.
    public static func scan(data: Data, heavy: Bool, configJSON: String?,
                            compute: ComputePreference) async -> (ScanOutput, ScanExit) {
        let mode = heavy ? "heavy" : "default"
        let inputType = QRScannerEngine.inputType(data)
        func fail(_ code: String, _ message: String, _ exit: ScanExit) -> (ScanOutput, ScanExit) {
            (ScanOutput(schema: scanSchema, ok: false, mode: mode, compute: nil, report: nil,
                        error: ScanErrorBody(code: code, message: message), inputType: inputType), exit)
        }
        var config = heavy ? MutationConfig.heavy : MutationConfig.default
        if let configJSON {
            do {
                config = try JSONDecoder().decode(MutationConfig.self, from: Data(configJSON.utf8))
                    .validated()
            } catch {
                return fail("bad_config", "\(error.localizedDescription)", .badConfig)
            }
        }
        do {
            let report = try await QRScannerEngine(compute: compute)
                .scan(imageData: data, config: config, earlyExit: !heavy)
            return (ScanOutput(schema: scanSchema, ok: true, mode: mode, compute: compute.rawValue,
                               report: report, error: nil, inputType: inputType), .ok)
        } catch let error as ScanError {
            return fail("invalid_image", error.localizedDescription, .badInput)
        } catch {
            return fail("scan_failed", "\(error.localizedDescription)", .failure)
        }
    }

    /// Decode a freshly generated QR (random nonce) under each compute preference. With no
    /// explicit preference: `auto` (what jobs use) AND, when the hardware has one, the Neural
    /// Engine explicitly, so a sandbox that silently blocks the ANE cannot pass on a fallback.
    public static func selfTest(compute: ComputePreference?, sandboxed: Bool?) async -> SelfTestOutput {
        let devices = QRScannerEngine.availableComputeDevices()
        var prefs: [ComputePreference] = compute.map { [$0] } ?? [.auto]
        if compute == nil, devices.contains("ane") { prefs.append(.ane) }

        var cases: [SelfTestCase] = []
        for pref in prefs {
            let expected = "https://wtqrk.self-test/\(UUID().uuidString)"
            let t0 = Date()
            var got: [String] = []
            var err: String?
            if let png = qrPNG(expected) {
                do {
                    let report = try await QRScannerEngine(compute: pref)
                        .scan(imageData: png, config: .default, earlyExit: true)
                    got = report.detections.map(\.payload)
                } catch {
                    err = error.localizedDescription
                }
            } else {
                err = "could not render the test QR"
            }
            cases.append(SelfTestCase(compute: pref.rawValue, ok: got.contains(expected),
                                      expected: expected, got: got, error: err,
                                      ms: Int(Date().timeIntervalSince(t0) * 1000)))
        }
        let ok = !cases.isEmpty && cases.allSatisfy(\.ok)
        return SelfTestOutput(schema: selfTestSchema, ok: ok, devices: devices, cases: cases,
                              sandboxed: sandboxed)
    }

    /// Render a QR for `message` to PNG bytes — exercised through the real ImageIO load path.
    public static func qrPNG(_ message: String) -> Data? {
        guard let gen = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        gen.setValue(Data(message.utf8), forKey: "inputMessage")
        gen.setValue("M", forKey: "inputCorrectionLevel")
        guard let qr = gen.outputImage else { return nil }
        // 10x scale plus a white quiet zone, like a code on a screen.
        let scaled = qr.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let pad: CGFloat = 40
        let canvas = CIImage(color: .white).cropped(to: scaled.extent.insetBy(dx: -pad, dy: -pad))
        let composed = scaled.composited(over: canvas)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return ctx.pngRepresentation(of: composed, format: .RGBA8, colorSpace: cs)
    }
}
