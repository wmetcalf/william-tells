// wtqrk-scan — one-shot, sandbox-friendly front-end to the William Tells scanner.
//
// Built for running one untrusted image per process under a macOS sandbox (blastbox's
// `seatbelt` / `appsandbox` backends): it reads exactly one file, writes one JSON document to
// stdout, needs no network and no writable path except $TMPDIR, and exits. No Vapor, no
// long-lived state, nothing shared between images.
//
//   wtqrk-scan scan <image> [--heavy] [--config-json JSON] [--compute auto|ane|gpu|cpu]
//                           [--max-bytes N]
//   wtqrk-scan self-test [--compute auto|ane|gpu|cpu]
//   wtqrk-scan devices
//   wtqrk-scan render-qr <message> <out.png>     (a known-positive sample for tests / ops)
//
// Exit codes: 0 scanned (detections may be empty) / self-test passed; 1 internal or self-test
// failure; 2 the input is not a usable image; 3 bad config; 64 usage.

import AppKit
import CoreImage
import Foundation
import QRScanCore

let schema = "wtqrk.scan/1"

enum Exit: Int32 { case ok = 0, failure = 1, badInput = 2, badConfig = 3, usage = 64 }

struct ErrorBody: Encodable { let code: String; let message: String }
struct ScanOutput: Encodable {
    let schema: String
    let ok: Bool
    let mode: String?
    let compute: String?
    let report: ScanReport?
    let error: ErrorBody?
}
struct SelfTestCase: Encodable {
    let compute: String
    let ok: Bool
    let expected: String
    let got: [String]
    let error: String?
    let ms: Int
}
struct SelfTestOutput: Encodable {
    let schema: String
    let ok: Bool
    let devices: [String]
    let cases: [SelfTestCase]
}

/// The ONLY channel for our JSON. Apple frameworks (E5RT, Espresso) print diagnostics straight
/// to fd 1; if our document shared it, one framework message would corrupt the output. So at
/// startup the real stdout is duplicated here and fd 1 is pointed at stderr.
let resultFD: Int32 = {
    let fd = dup(STDOUT_FILENO)
    dup2(STDERR_FILENO, STDOUT_FILENO)
    return fd
}()

func emit<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    var data = (try? enc.encode(value)) ?? Data("{\"ok\":false}".utf8)
    data.append(0x0A)
    data.withUnsafeBytes { buf in
        var off = 0
        while off < buf.count {
            let n = write(resultFD, buf.baseAddress! + off, buf.count - off)
            if n <= 0 { break }
            off += n
        }
    }
}

func fail(_ code: String, _ message: String, _ exit: Exit, mode: String? = nil) -> Exit {
    emit(ScanOutput(schema: schema, ok: false, mode: mode, compute: nil, report: nil,
                    error: ErrorBody(code: code, message: message)))
    return exit
}

func usage() -> Exit {
    FileHandle.standardError.write(Data("""
    usage: wtqrk-scan scan <image> [--heavy] [--config-json JSON] [--compute auto|ane|gpu|cpu] [--max-bytes N]
           wtqrk-scan self-test [--compute auto|ane|gpu|cpu]
           wtqrk-scan devices
           wtqrk-scan render-qr <message> <out.png>

    """.utf8))
    return .usage
}

/// Minimal flag parser: `--flag value` and boolean `--flag`; first positional kept.
struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init?(_ argv: ArraySlice<String>, valued: Set<String>, booleans: Set<String>) {
        var it = argv.makeIterator()
        while let arg = it.next() {
            if valued.contains(arg) {
                guard let v = it.next() else { return nil }
                options[arg] = v
            } else if booleans.contains(arg) {
                flags.insert(arg)
            } else if arg.hasPrefix("--") {
                return nil
            } else {
                positional.append(arg)
            }
        }
    }
}

func parseCompute(_ raw: String?) -> ComputePreference? {
    guard let raw else { return .auto }
    return ComputePreference(rawValue: raw)
}

func runScan(_ argv: ArraySlice<String>) async -> Exit {
    guard let args = Args(argv, valued: ["--config-json", "--compute", "--max-bytes"],
                          booleans: ["--heavy"]),
          args.positional.count == 1,
          let compute = parseCompute(args.options["--compute"])
    else { return usage() }

    let heavy = args.flags.contains("--heavy")
    let mode = heavy ? "heavy" : "default"
    let maxBytes = Int(args.options["--max-bytes"] ?? "") ?? 50 * 1024 * 1024

    var config = heavy ? MutationConfig.heavy : MutationConfig.default
    if let raw = args.options["--config-json"] {
        do {
            config = try JSONDecoder().decode(MutationConfig.self, from: Data(raw.utf8)).validated()
        } catch {
            return fail("bad_config", "\(error.localizedDescription)", .badConfig, mode: mode)
        }
    }

    let url = URL(fileURLWithPath: args.positional[0])
    let data: Data
    do {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attrs[.type] as? FileAttributeType) == .typeRegular else {
            return fail("bad_input", "not a regular file", .badInput, mode: mode)
        }
        if let size = attrs[.size] as? Int, size > maxBytes {
            return fail("too_large", "input is \(size) bytes; limit \(maxBytes)", .badInput, mode: mode)
        }
        data = try Data(contentsOf: url, options: [.uncached])
    } catch {
        return fail("unreadable", error.localizedDescription, .badInput, mode: mode)
    }

    do {
        // Same early-exit semantics as the web API: /scan stops at the first hit, /scan/heavy sweeps.
        let report = try await QRScannerEngine(compute: compute)
            .scan(imageData: data, config: config, earlyExit: !heavy)
        emit(ScanOutput(schema: schema, ok: true, mode: mode, compute: compute.rawValue,
                        report: report, error: nil))
        return .ok
    } catch let error as ScanError {
        return fail("invalid_image", error.localizedDescription, .badInput, mode: mode)
    } catch {
        return fail("scan_failed", "\(error.localizedDescription)", .failure, mode: mode)
    }
}

/// Render a QR for `message` to PNG bytes — exercised through the real ImageIO load path.
func qrPNG(_ message: String) -> Data? {
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

func runSelfTest(_ argv: ArraySlice<String>) async -> Exit {
    guard let args = Args(argv, valued: ["--compute"], booleans: []),
          args.positional.isEmpty
    else { return usage() }

    let devices = QRScannerEngine.availableComputeDevices()
    var prefs: [ComputePreference]
    if let raw = args.options["--compute"] {
        guard let p = ComputePreference(rawValue: raw) else { return usage() }
        prefs = [p]
    } else {
        // Default: what jobs use (auto) AND, when the hardware has one, the Neural Engine
        // explicitly — so a sandbox that silently blocks the ANE cannot pass on a fallback.
        prefs = [.auto]
        if devices.contains("ane") { prefs.append(.ane) }
    }

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
    emit(SelfTestOutput(schema: "wtqrk.self-test/1", ok: ok, devices: devices, cases: cases))
    return ok ? .ok : .failure
}

@main
struct WTQRKScan {
    static func main() async {
        _ = resultFD   // claim the real stdout before any framework can write to it
        let argv = CommandLine.arguments
        let code: Exit
        switch argv.dropFirst().first {
        case "scan": code = await runScan(argv.dropFirst(2))
        case "self-test": code = await runSelfTest(argv.dropFirst(2))
        case "render-qr":
            let rest = Array(argv.dropFirst(2))
            if rest.count == 2, let png = qrPNG(rest[0]),
               (try? png.write(to: URL(fileURLWithPath: rest[1]))) != nil {
                code = .ok
            } else {
                code = rest.count == 2 ? .failure : usage()
            }
        case "devices":
            emit(["devices": QRScannerEngine.availableComputeDevices()])
            code = .ok
        default: code = usage()
        }
        exit(code.rawValue)
    }
}
