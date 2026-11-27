// wtqrk-scan — one-shot, sandbox-friendly front-end to the William Tells scanner.
//
// Built for running one untrusted image per process under a macOS sandbox (blastbox's
// `seatbelt` / `appsandbox` backends): it reads exactly one file, writes one JSON document to
// stdout, needs no network and no writable path except $TMPDIR, and exits. No Vapor, no
// long-lived state, nothing shared between images.
//
//   wtqrk-scan scan <image|-> [--heavy] [--config-json JSON] [--compute auto|ane|gpu|cpu]
//                           [--max-bytes N] [--budget-ms N]
//   wtqrk-scan blastbox <image|-> [same options as scan]   (prints the sealed blastbox envelope)
//   wtqrk-scan self-test [--compute auto|ane|gpu|cpu]
//   wtqrk-scan devices
//   wtqrk-scan probe --read <path> --connect <port>   (confinement check for a sandbox host)
//   wtqrk-scan render-qr <message> <out.png>     (a known-positive sample for tests / ops)
//
// `blastbox` scans IN-PROCESS (the caller -- blastbox's pull agent -- provides the sandbox) and
// prints exactly one blastbox `metadata.json` envelope, exiting 0 even for an engine_error /
// rejected envelope (64 = usage only). WTQRK_MODE / WTQRK_CONFIG are fallbacks for --heavy /
// --config-json; the flags win, but a malformed env value is still rejected (as the push path).
// Like the push path it runs the known-QR self-test first (in this process, under the caller's
// sandbox) and seals self_test_failed when it fails; --budget-ms defaults to the 120 s job
// timeout's budget and --max-bytes to 100 MiB.
//
// `scan -` reads the image from stdin: the native sandbox host hands each scan an open file
// descriptor, so the sandboxed process needs no file-path grant at all.
//
// `--budget-ms`: stop trying mutations after N ms and report what was found, flagged
// `budgetExhausted` -- a host that kills the scanner at a timeout passes a budget inside it.
//
// Exit codes: 0 scanned (detections may be empty) / self-test passed; 1 internal or self-test
// failure; 2 the input is not a usable image; 3 bad config; 64 usage.

import Foundation
import CryptoKit
import QRSandbox
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
    usage: wtqrk-scan scan <image|-> [--heavy] [--config-json JSON] [--compute auto|ane|gpu|cpu] [--max-bytes N] [--budget-ms N]
           wtqrk-scan blastbox <image|-> [--heavy] [--config-json JSON] [--compute auto|ane|gpu|cpu] [--max-bytes N] [--budget-ms N]
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
    guard let args = Args(argv, valued: ["--config-json", "--compute", "--max-bytes", "--budget-ms"],
                          booleans: ["--heavy"]),
          args.positional.count == 1,
          let compute = parseCompute(args.options["--compute"])
    else { return usage() }
    var budget: TimeInterval?
    if let raw = args.options["--budget-ms"] {
        guard let ms = Int(raw), ms > 0, ms <= 86_400_000 else { return usage() }
        budget = TimeInterval(ms) / 1000
    }

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
                                         configJSON: args.options["--config-json"], compute: compute,
                                         budget: budget)
    emit(out)
    return code
}

/// Write all of `data` to the real stdout; false on a failed or short write (EINTR is retried).
func writeResult(_ data: Data) -> Bool {
    data.withUnsafeBytes { buf in
        var off = 0
        while off < buf.count {
            let n = Foundation.write(resultFD, buf.baseAddress! + off, buf.count - off)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            off += n
        }
        return true
    }
}

/// The scan time budget when the caller passes no `--budget-ms`: the one the push path derives
/// from the engine's 120 s job timeout, so a long sweep returns its partial result before a kill.
let blastboxDefaultBudget = ScanJob.budget(forTimeout: 120)

/// The input limit when the caller passes no `--max-bytes`: the worker's 100 MiB default
/// (blastbox-engine.toml), so a pull-path input the push path accepts is not rejected here.
let blastboxDefaultMaxBytes = 100 * 1024 * 1024

/// What `blastbox` read: the bytes (nil when over the limit), and the sha256 and head of the
/// WHOLE input -- an over-limit input is still hashed to its end, because the host's trust gate
/// refuses an envelope whose `input_sha256` is not the job's.
struct HashedInput {
    let data: Data?
    let sha256: String
    let head: Data
    let size: Int
}

/// Read and hash all of `path` (`-` = stdin), keeping at most `maxBytes` of it.
func readHashed(_ path: String, maxBytes: Int) throws -> HashedInput {
    var fd = STDIN_FILENO
    if path != "-" {
        // Follow links like `scan` does, but judge the file by the descriptor actually opened (no
        // stat-then-open race), and open non-blocking so a FIFO can't hang us before that check.
        fd = open(path, O_RDONLY | O_NONBLOCK)
        if fd < 0 { throw ReadError.io(String(cString: strerror(errno))) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw ReadError.notRegular
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
    }
    defer { if fd != STDIN_FILENO { close(fd) } }
    var hasher = SHA256()
    var data: Data? = Data()
    var head = Data()
    var size = 0
    var buf = [UInt8](repeating: 0, count: 1 << 20)
    while true {
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n < 0 {
            if errno == EINTR { continue }
            throw ReadError.io(String(cString: strerror(errno)))
        }
        if n == 0 { break }
        buf.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
        if head.count < 1024 { head.append(contentsOf: buf[0..<min(n, 1024 - head.count)]) }
        size += n
        if size > maxBytes { data = nil } else { data?.append(contentsOf: buf[0..<n]) }
    }
    let sha = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return HashedInput(data: data, sha256: sha, head: head, size: size)
}

/// The in-process known-QR self-test: when the caller's sandbox denies something Vision needs,
/// a scan finds nothing instead of failing, so no result is trusted until a generated QR decodes
/// in this very process (the push path's `self_test_failed` gate).
/// Like the push path's gate it also requires that the kernel has this process sandboxed: the
/// caller owns the sandbox, and a hostile image is never parsed outside one.
func blastboxSelfTest(_ compute: ComputePreference, requireSandbox: Bool = true) async -> (ok: Bool, detail: String) {
    if requireSandbox && sandbox_check(getpid(), nil, 0) == 0 {
        return (false, "this process is not sandboxed; run it under the caller's sandbox")
    }
    let out = await ScanJob.selfTest(compute: compute == .auto ? nil : compute, sandboxed: nil)
    let detail = out.cases.map { "\($0.compute): ok=\($0.ok)\($0.error.map { " error=\($0)" } ?? "")" }
        .joined(separator: "; ")
    return (out.ok, String(detail.prefix(1500)))
}

/// What `blastbox` hands the scanner (a seam so tests can see the derived parameters).
struct BlastboxScanRequest {
    let data: Data
    let heavy: Bool
    let configJSON: String?
    let compute: ComputePreference
    let budget: TimeInterval
}

func blastboxScan(_ r: BlastboxScanRequest) async -> (ScanOutput, ScanExit) {
    await ScanJob.scan(data: r.data, heavy: r.heavy, configJSON: r.configJSON, compute: r.compute,
                       budget: r.budget)
}

/// `wtqrk-scan blastbox`: scan in this process, print the blastbox envelope.
func runBlastbox(_ argv: ArraySlice<String>, env: [String: String] = ProcessInfo.processInfo.environment,
                 write: (Data) -> Bool = writeResult,
                 selfTest: (ComputePreference) async -> (ok: Bool, detail: String) = { await blastboxSelfTest($0) },
                 scan: (BlastboxScanRequest) async -> (ScanOutput, ScanExit) = blastboxScan)
    async -> ScanExit {
    let started = ProcessInfo.processInfo.systemUptime   // monotonic: a clock step can't stretch it
    guard let args = Args(argv, valued: ["--config-json", "--compute", "--max-bytes", "--budget-ms"],
                          booleans: ["--heavy"]),
          args.positional.count == 1,
          let compute = parseCompute(args.options["--compute"])
    else { return usage() }
    var budget = blastboxDefaultBudget
    if let raw = args.options["--budget-ms"] {
        guard let ms = Int(raw), ms > 0, ms <= 86_400_000 else { return usage() }
        budget = TimeInterval(ms) / 1000
    }
    var maxBytes = blastboxDefaultMaxBytes
    if let raw = args.options["--max-bytes"] {
        guard let n = Int(raw), n > 0 else { return usage() }
        maxBytes = n
    }

    let zeros = String(repeating: "0", count: 64)
    func finish(_ outcome: ScanOutcome, sha: String, head: Data) -> ScanExit {
        let line: Data
        if let l = try? BlastboxMode.line(outcome: outcome, inputSHA256: sha, head: head) {
            line = l
        } else {
            // Static document: nothing here can fail the way the mapping just did.
            let doc: String = #"{"artifacts":[],"detected":{"confidence":0,"label":"unknown","mime":"application/octet-stream","source":"williamtells"},"engine":"williamtells","input_sha256":"\#(sha)","payload":{"_type":"record","fields":{"error":"envelope_failed","schema":"wtqrk.scan/1"}},"status":"engine_error","warnings":[{"code":"envelope_failed","message":"could not serialise the envelope"}]}"#
            line = Data((doc + "\n").utf8)
        }
        return write(line) ? .ok : .failure
    }

    let input: HashedInput
    do {
        input = try readHashed(args.positional[0], maxBytes: maxBytes)
    } catch ReadError.notRegular {
        return finish(.rejected(code: "bad_input", message: "not a regular file"), sha: zeros, head: Data())
    } catch {
        // As `scan` (exit 2): an input that can't be read is unusable input, not an engine fault.
        return finish(.rejected(code: "unreadable", message: "\(error)"), sha: zeros, head: Data())
    }
    let (sha, head) = (input.sha256, input.head)

    // The push path's order: self-test, then per-job params, then the scan (which judges size).
    let gate = await selfTest(compute)
    guard gate.ok else {
        return finish(.engineError(code: "self_test_failed",
                                   message: "scanner failed its known-QR self-test in this process; no "
                                       + "result is trustworthy until it passes: " + gate.detail),
                      sha: sha, head: head)
    }

    // Per-job parameters, checked like the push path's `_bad_params` (a malformed one is rejected
    // even when a flag overrides it); flags win over the environment the blastbox agent forwards.
    let envMode = (env["WTQRK_MODE"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard ["default", "heavy", ""].contains(envMode) else {
        return finish(.rejected(code: "bad_param", message: "WTQRK_MODE must be default or heavy, not \(envMode.prefix(32))"),
                      sha: sha, head: head)
    }
    var envConfig: String?
    if let raw = env["WTQRK_CONFIG"], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        do { envConfig = try ScanOutputValidator.canonicalConfig(raw) }
        catch { return finish(.rejected(code: "bad_config", message: "\(error)"), sha: sha, head: head) }
    }
    let heavy = args.flags.contains("--heavy") || envMode == "heavy"
    var config = envConfig
    if let raw = args.options["--config-json"] {
        do { config = try ScanOutputValidator.canonicalConfig(raw) }
        catch { return finish(.rejected(code: "bad_config", message: "\(error)"), sha: sha, head: head) }
    }

    guard let data = input.data else {
        return finish(.rejected(code: "too_large", message: "input is \(input.size) bytes; limit \(maxBytes)"),
                      sha: sha, head: head)
    }

    // The budget counts from process start: the read, hash and self-test above ran inside the
    // same job deadline the sweep has to finish in.
    // Once it is spent the scan still gets a sliver: it then returns its minimum pass, flagged
    // budget_exhausted, instead of no envelope at all.
    let remaining = max(0.001, budget - (ProcessInfo.processInfo.systemUptime - started))
    let (out, code) = await scan(BlastboxScanRequest(data: data, heavy: heavy, configJSON: config,
                                                     compute: compute, budget: remaining))
    return finish(BlastboxMode.outcome(of: out, exit: code), sha: sha, head: head)
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
        case "blastbox": code = await runBlastbox(argv.dropFirst(2))
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
