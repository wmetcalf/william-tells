// wtqrk-scan — one-shot, sandbox-friendly front-end to the William Tells scanner.
//
// Built for running one untrusted image per process under a macOS sandbox (blastbox's
// `seatbelt` / `appsandbox` backends): it reads exactly one file, writes one JSON document to
// stdout, needs no network and no writable path except $TMPDIR, and exits. No Vapor, no
// long-lived state, nothing shared between images.
//
//   wtqrk-scan scan <image|-> [--heavy] [--config-json JSON] [--compute auto|ane|gpu|cpu]
//                           [--max-bytes N]
//   wtqrk-scan self-test [--compute auto|ane|gpu|cpu]
//   wtqrk-scan devices
//   wtqrk-scan probe --read <path> --connect <port>   (confinement check for a sandbox host)
//   wtqrk-scan render-qr <message> <out.png>     (a known-positive sample for tests / ops)
//
// `scan -` reads the image from stdin: the native sandbox host hands each scan an open file
// descriptor, so the sandboxed process needs no file-path grant at all.
//
// Exit codes: 0 scanned (detections may be empty) / self-test passed; 1 internal or self-test
// failure; 2 the input is not a usable image; 3 bad config; 64 usage.

import Foundation
import QRScanCore

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

func fail(_ code: String, _ message: String, _ exit: ScanExit, mode: String? = nil) -> ScanExit {
    emit(ScanOutput(schema: scanSchema, ok: false, mode: mode, compute: nil, report: nil,
                    error: ScanErrorBody(code: code, message: message)))
    return exit
}

func usage() -> ScanExit {
    FileHandle.standardError.write(Data("""
    usage: wtqrk-scan scan <image|-> [--heavy] [--config-json JSON] [--compute auto|ane|gpu|cpu] [--max-bytes N]
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

enum ReadError: Error { case tooLarge(Int), notRegular, io(String) }

/// Read at most `maxBytes` (one more byte means "too large") from an fd.
func readCapped(fd: Int32, maxBytes: Int) throws -> Data {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 1 << 20)
    while true {
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n < 0 {
            if errno == EINTR { continue }
            throw ReadError.io(String(cString: strerror(errno)))
        }
        if n == 0 { return data }
        data.append(buf, count: n)
        if data.count > maxBytes { throw ReadError.tooLarge(data.count) }
    }
}

func readInput(_ path: String, maxBytes: Int) throws -> Data {
    if path == "-" { return try readCapped(fd: STDIN_FILENO, maxBytes: maxBytes) }
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    guard (attrs[.type] as? FileAttributeType) == .typeRegular else { throw ReadError.notRegular }
    if let size = attrs[.size] as? Int, size > maxBytes { throw ReadError.tooLarge(size) }
    return try Data(contentsOf: URL(fileURLWithPath: path), options: [.uncached])
}

func runScan(_ argv: ArraySlice<String>) async -> ScanExit {
    guard let args = Args(argv, valued: ["--config-json", "--compute", "--max-bytes"],
                          booleans: ["--heavy"]),
          args.positional.count == 1,
          let compute = parseCompute(args.options["--compute"])
    else { return usage() }

    let heavy = args.flags.contains("--heavy")
    let mode = heavy ? "heavy" : "default"
    let maxBytes = Int(args.options["--max-bytes"] ?? "") ?? 50 * 1024 * 1024

    let data: Data
    do {
        data = try readInput(args.positional[0], maxBytes: maxBytes)
    } catch ReadError.tooLarge(let n) {
        return fail("too_large", "input is at least \(n) bytes; limit \(maxBytes)", .badInput, mode: mode)
    } catch ReadError.notRegular {
        return fail("bad_input", "not a regular file", .badInput, mode: mode)
    } catch {
        return fail("unreadable", "\(error)", .badInput, mode: mode)
    }

    let (out, code) = await ScanJob.scan(data: data, heavy: heavy,
                                         configJSON: args.options["--config-json"], compute: compute)
    emit(out)
    return code
}

/// `sandbox_check(getpid(), NULL, SANDBOX_FILTER_NONE)`: nonzero when the kernel has this process
/// sandboxed. (libsystem_sandbox; called without variadic arguments, so the C ABI is plain.)
@_silgen_name("sandbox_check")
func sandbox_check(_ pid: pid_t, _ operation: UnsafePointer<CChar>?, _ type: Int32) -> Int32

func runSelfTest(_ argv: ArraySlice<String>) async -> ScanExit {
    guard let args = Args(argv, valued: ["--compute"], booleans: []),
          args.positional.isEmpty
    else { return usage() }
    var compute: ComputePreference?
    if let raw = args.options["--compute"] {
        guard let p = ComputePreference(rawValue: raw) else { return usage() }
        compute = p
    }
    let out = await ScanJob.selfTest(compute: compute,
                                     sandboxed: sandbox_check(getpid(), nil, 0) != 0)
    emit(out)
    return out.ok ? .ok : .failure
}

struct ProbeOutput: Encodable {
    let schema = "wtqrk.probe/1"
    let sandboxed: Bool
    let readDenied: Bool
    let connectDenied: Bool
}

/// Try what a confined scanner must NOT be able to do: read a file the host created outside the
/// container, and connect to a listener the host opened on loopback. Run on trusted arguments
/// only; the host reads the answers as a confinement check, alongside its own listener's view.
func runProbe(_ argv: ArraySlice<String>) -> ScanExit {
    guard let args = Args(argv, valued: ["--read", "--connect"], booleans: []),
          let path = args.options["--read"], let port = UInt16(args.options["--connect"] ?? "")
    else { return usage() }
    let fd = open(path, O_RDONLY)
    let readDenied = fd < 0
    if fd >= 0 { close(fd) }
    let s = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    close(s)
    emit(ProbeOutput(sandboxed: sandbox_check(getpid(), nil, 0) != 0, readDenied: readDenied,
                     connectDenied: rc != 0))
    return .ok
}

@main
struct WTQRKScan {
    static func main() async {
        _ = resultFD   // claim the real stdout before any framework can write to it
        let argv = CommandLine.arguments
        let code: ScanExit
        switch argv.dropFirst().first {
        case "scan": code = await runScan(argv.dropFirst(2))
        case "self-test": code = await runSelfTest(argv.dropFirst(2))
        case "render-qr":
            let rest = Array(argv.dropFirst(2))
            if rest.count == 2, let png = ScanJob.qrPNG(rest[0]),
               (try? png.write(to: URL(fileURLWithPath: rest[1]))) != nil {
                code = .ok
            } else {
                code = rest.count == 2 ? .failure : usage()
            }
        case "probe": code = runProbe(argv.dropFirst(2))
        case "devices":
            emit(["devices": QRScannerEngine.availableComputeDevices()])
            code = .ok
        default: code = usage()
        }
        exit(code.rawValue)
    }
}
