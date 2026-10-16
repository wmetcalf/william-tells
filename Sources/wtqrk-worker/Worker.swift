// wtqrk-worker — native macOS blastbox worker agent for the `williamtells` engine.
//
// Speaks blastbox's generic worker-agent protocol (the one `python -m blastbox.worker.http_agent`
// serves), so a Mac joins a blastbox `static` pool with no Python on it:
//
//   GET  /healthz                       -> 200 {"ok": true, "engine": "williamtells", ...}
//   POST /detonate?name=<fn>            body = the image
//                                       -> 200 application/x-tar: metadata.json, the sealed envelope
//                                          the dispatcher's trust gate re-validates
//
// Every image is scanned by a fresh `wtqrk-scan` process that the kernel App-Sandboxes at exec
// (QRSandbox): no network, no file access beyond its own wiped container, the image handed over as
// an open file descriptor. This process never decodes anything.
//
// Configuration (same names as the Python agent where they overlap):
//   WTQRK_SCAN_BIN                      wtqrk-scan to sandbox (default: next to this binary)
//   WTQRK_WORKER_SLOT                   slot index, one per agent on a Mac (default 0)
//   WTQRK_SLOT_ROOT                     slot directory (default ~/Library/Application Support/wtqrk/slots)
//   BLASTBOX_WORKER_AGENT_BIND / _PORT  default 127.0.0.1:8765
//   BLASTBOX_WORKER_AGENT_TOKEN         bearer token (Authorization: Bearer / X-aws-proxy-auth)
//   BLASTBOX_WORKER_AGENT_ALLOW_CIDRS   peer allowlist, comma-separated
//   BLASTBOX_WORKER_AGENT_MAX_BYTES     request body cap (default 100 MiB)
//   BLASTBOX_WORKER_AGENT_UPLOAD_TIMEOUT  seconds to receive the whole body (default 120)
//   BLASTBOX_WORKER_AGENT_ALLOW_INSECURE=1  serve a non-loopback bind with no token/allowlist
// Per job (X-Blastbox-Params, already allowlisted by the dispatcher): WTQRK_MODE, WTQRK_CONFIG,
// BLASTBOX_TIMEOUT, BLASTBOX_MAX_INPUT, BLASTBOX_MEM, BLASTBOX_MAX_METADATA.

import Foundation
import NIOCore
import QRSandbox
import Vapor

@main
enum WTQRKWorker {
    static func main() async throws {
        // Vapor must not parse our argv (it would treat it as a command line).
        var env = Environment(name: "production", arguments: [CommandLine.arguments[0]])
        try LoggingSystem.bootstrap(from: &env)
        let app = try await Application.make(env)
        do {
            try await configure(app)
            try await app.execute()
        } catch {
            app.logger.critical("wtqrk-worker: \(error)")
            try? await app.asyncShutdown()
            exit(78)   // EX_CONFIG: launchd keeps restarting on a throttle; the log says why
        }
        try await app.asyncShutdown()
    }

    static func configure(_ app: Application) async throws {
        let e = ProcessInfo.processInfo.environment
        let bind = e["BLASTBOX_WORKER_AGENT_BIND"].flatMap { $0.isEmpty ? nil : $0 } ?? "127.0.0.1"
        let port = Int(e["BLASTBOX_WORKER_AGENT_PORT"] ?? "") ?? 8765
        let token = e["BLASTBOX_WORKER_AGENT_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
        let maxBytes = Int(e["BLASTBOX_WORKER_AGENT_MAX_BYTES"] ?? "") ?? 100 << 20
        let uploadTimeout = Int64(e["BLASTBOX_WORKER_AGENT_UPLOAD_TIMEOUT"] ?? "").flatMap { $0 > 0 ? $0 : nil } ?? 120
        let cidrs = try parseCIDRs(e["BLASTBOX_WORKER_AGENT_ALLOW_CIDRS"] ?? "")

        for key in ["BLASTBOX_WORKER_AGENT_TLS_CERT", "BLASTBOX_WORKER_AGENT_TLS_KEY",
                    "BLASTBOX_WORKER_AGENT_CLIENT_CA"] where !(e[key] ?? "").isEmpty {
            throw WorkerError("\(key) is set, but wtqrk-worker does not terminate TLS; run the Python "
                + "http_agent for TLS/mTLS, or put a TLS proxy in front and bind loopback")
        }
        let loopback = ["127.0.0.1", "localhost", "::1"].contains(bind)
        // An allowlist that admits every address gates nothing: a /0, or narrower entries whose
        // union covers a whole address family (0.0.0.0/1 + 128.0.0.0/1).
        let gated = token != nil || (!cidrs.isEmpty && !admitsEveryAddress(cidrs))
        if !loopback && !gated && e["BLASTBOX_WORKER_AGENT_ALLOW_INSECURE"] != "1" {
            throw WorkerError("refusing to serve \(bind):\(port) with no token and no "
                + "BLASTBOX_WORKER_AGENT_ALLOW_CIDRS narrower than every address: anyone who reaches "
                + "the port could submit jobs")
        }

        let scannerPath = e["WTQRK_SCAN_BIN"].flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
                .deletingLastPathComponent().appendingPathComponent("wtqrk-scan").path
        let slot = Int(e["WTQRK_WORKER_SLOT"] ?? "") ?? 0
        let scanner = try SandboxedScanner(scanner: URL(fileURLWithPath: scannerPath), slotIndices: [slot])
        let gate = await scanner.selfTest()
        if gate.ok {
            app.logger.info("wtqrk self-test passed: \(gate.detail)")
        } else {
            // /healthz reports NOT ready, so a static pool skips this Mac (same as blastbox's agent
            // on macOS); a job that still arrives is engine_error, never "no QR found".
            app.logger.error("wtqrk self-test FAILED; /healthz is 503 and jobs are engine_error: \(gate.detail)")
        }

        app.http.server.configuration.hostname = bind
        app.http.server.configuration.port = port
        app.routes.defaultMaxBodySize = ByteCount(value: maxBytes)
        let agent = Agent(scanner: scanner, token: token, cidrs: cidrs, maxBytes: maxBytes,
                          uploadTimeout: .seconds(uploadTimeout), gate: gate, logger: app.logger)

        app.get("healthz") { req async -> Response in
            if let denied = agent.deny(req) { return denied }
            // Ready means it can run a job now: the gate passed AND its slot was not retired by a
            // container that could not be wiped after an earlier job.
            let slotOK = await scanner.hasUsableSlot
            let ready = gate.ok && slotOK
            return Agent.json(ready ? .ok : .serviceUnavailable,
                              ["ok": ready, "engine": BlastboxEnvelope.engine, "agent": "wtqrk-worker",
                               "self_test": gate.ok ? "passed" : "failed",
                               "slot": slotOK ? "ok" : "retired"])
        }
        // .stream: nothing is read until detonate() has checked the peer, the token and the busy
        // flag, so an unauthenticated or concurrent upload can't make the worker buffer it.
        app.on(.POST, "detonate", body: .stream) { req async -> Response in
            await agent.detonate(req)
        }
        app.logger.info("""
            wtqrk-worker: serving engine=\(BlastboxEnvelope.engine) on \(bind):\(port) \
            (slot \(slot), token=\(token != nil), allowlist=\(!cidrs.isEmpty))
            """)
    }
}

struct WorkerError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

final class Agent: Sendable {
    let scanner: SandboxedScanner
    let token: String?
    let cidrs: [CIDR]
    let maxBytes: Int
    let uploadTimeout: TimeAmount
    let gate: (ok: Bool, detail: String)
    let logger: Logger
    private let busy = Busy()

    init(scanner: SandboxedScanner, token: String?, cidrs: [CIDR], maxBytes: Int,
         uploadTimeout: TimeAmount, gate: (ok: Bool, detail: String), logger: Logger) {
        self.scanner = scanner
        self.token = token
        self.cidrs = cidrs
        self.maxBytes = maxBytes
        self.uploadTimeout = uploadTimeout
        self.gate = gate
        self.logger = logger
    }

    /// The same gates as the Python agent, in the same order: peer allowlist, then the token.
    func deny(_ req: Request) -> Response? {
        if !cidrs.isEmpty {
            guard let ip = req.peerAddress?.ipAddress, cidrs.contains(where: { $0.contains(ip) }) else {
                return Agent.json(.forbidden, ["error": "forbidden"])
            }
        }
        if let token {
            let got = req.headers.first(name: "X-aws-proxy-auth")
                ?? req.headers.first(name: .authorization).flatMap {
                    $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil } ?? ""
            guard constantTimeEqual(Array(got.utf8), Array(token.utf8)) else {
                return Agent.json(.unauthorized, ["error": "unauthorized"])
            }
        }
        return nil
    }

    func detonate(_ req: Request) async -> Response {
        if let denied = deny(req) { return denied }
        // One job at a time, like the Python agent: a request landing while the previous job is
        // still running gets a fast 409 (the dispatcher fails it and retires the slot dirty).
        guard busy.tryAcquire() else { return Agent.json(.conflict, ["error": "busy"]) }
        defer { busy.release() }

        // An upload refused for its size or its pace ends the connection with the response. Left
        // open, Vapor keeps reading (and the client keeps sending) the rest of the body for as long
        // as the client likes, after the upload deadline has stopped mattering.
        if let declared = req.headers.first(name: .contentLength).flatMap(Int.init), declared > maxBytes {
            return Agent.closing(.payloadTooLarge, ["error": "too_large"])
        }
        let body: Data
        do {
            body = try await receive(req)
        } catch is UploadTimedOut {
            return Agent.closing(.requestTimeout, ["error": "upload_timeout"])
        } catch {
            return Agent.closing(.payloadTooLarge, ["error": "too_large"])
        }
        let params = parseParams(req.headers.first(name: "X-Blastbox-Params"))

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtqrk-worker-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let input = dir.appendingPathComponent("input")
            try body.write(to: input)
            let sha = try BlastboxEnvelope.sha256(fileAt: input.path)

            let outcome = await run(inputPath: input.path, params: params)
            let meta = try BlastboxEnvelope.metadataJSON(
                BlastboxEnvelope.envelope(outcome: outcome, inputSHA256: sha, head: body.prefix(1024)))
            let metaCap = int(params["BLASTBOX_MAX_METADATA"], default: 4 << 20)
            guard meta.count <= metaCap else {
                return Agent.json(.internalServerError, ["error": "engine_error"])
            }
            if case .engineError(let code, let message) = outcome {
                logger.warning("job engine_error \(code): \(message.prefix(300))")
            }
            var headers = HTTPHeaders()
            headers.contentType = HTTPMediaType(type: "application", subType: "x-tar")
            return Response(status: .ok, headers: headers,
                            body: .init(data: BlastboxEnvelope.tar(name: "metadata.json", contents: meta)))
        } catch {
            logger.warning("detonate failed: \(error)")
            return Agent.json(.internalServerError, ["error": "engine_error"])
        }
    }

    private func run(inputPath: String, params: [String: String]) async -> ScanOutcome {
        let mode = (params["WTQRK_MODE"] ?? "default").trimmingCharacters(in: .whitespaces)
        guard ["default", "heavy", ""].contains(mode) else {
            return .rejected(code: "bad_param", message: "WTQRK_MODE must be default or heavy, not \(mode.prefix(32))")
        }
        let config = params["WTQRK_CONFIG"].flatMap { $0.isEmpty ? nil : $0 }
        let limits = RunLimits(
            timeoutSeconds: Double(int(params["BLASTBOX_TIMEOUT"], default: 120)),
            maxFootprintBytes: UInt64(int(params["BLASTBOX_MEM"], default: 8 << 30)))
        return await scanner.scan(path: inputPath, maxBytes: int(params["BLASTBOX_MAX_INPUT"], default: 100 << 20),
                                  heavy: mode == "heavy", configJSON: config, limits: limits)
    }

    private func int(_ s: String?, default d: Int) -> Int {
        guard let s, let v = Int(s.trimmingCharacters(in: .whitespaces)), v > 0 else { return d }
        return v
    }

    private func parseParams(_ raw: String?) -> [String: String] {
        guard let raw, let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            return [:]
        }
        return obj.reduce(into: [:]) { $0[$1.key] = "\($1.value)" }
    }

    static func json(_ status: HTTPResponseStatus, _ obj: [String: Any]) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: status, headers: headers, body: .init(data: data))
    }

    /// `json(status, obj)`, after which the server closes the connection. A `Connection: close`
    /// header can't do it: Vapor takes keep-alive from the REQUEST alone. So the body is a stream
    /// that sends the whole JSON (Content-Length is exact, the client gets a complete response) and
    /// then fails; the failed response reaches the pipeline's close-on-error handler, which closes
    /// the channel and with it the request body still being read.
    static func closing(_ status: HTTPResponseStatus, _ obj: [String: Any]) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        var headers = HTTPHeaders()
        headers.contentType = .json
        let sent = SentOnce()
        return Response(status: status, headers: headers, body: .init(stream: { writer in
            // Vapor calls this again with an error writer once the stream has failed: send once.
            guard sent.claim() else { return }
            writer.write(.buffer(ByteBuffer(bytes: data))).whenComplete { _ in
                writer.write(.error(CloseConnection()), promise: nil)
            }
        }, count: data.count))
    }
}

func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    var diff = UInt8(a.count == b.count ? 0 : 1)
    for i in 0..<max(a.count, b.count) {
        diff |= (i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0)
    }
    return diff == 0
}

struct UploadTimedOut: Error {}
struct CloseConnection: Error {}

final class SentOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var sent = false
    func claim() -> Bool { lock.withLock { if sent { return false }; sent = true; return true } }
}

extension Agent {
    /// The request body, capped at maxBytes and at uploadTimeout of wall clock: a client trickling
    /// bytes can't hold the single-flight busy flag forever. After the deadline whatever still
    /// arrives is dropped, not buffered.
    func receive(_ req: Request) async throws -> Data {
        let loop = req.eventLoop
        let promise = loop.makePromise(of: Data.self)
        let state = UploadState()
        // A failed upload drops what it buffered at once (`abandon`): the drain callback stays
        // registered until the connection ends, and it must not hold up to maxBytes until then.
        let timer = loop.scheduleTask(in: uploadTimeout) {
            if state.abandon() { promise.fail(UploadTimedOut()) }
        }
        let max = maxBytes
        req.body.drain { part in
            switch part {
            case .buffer(var chunk):
                if !state.append(&chunk, max: max) {
                    if state.abandon() { timer.cancel(); promise.fail(Abort(.payloadTooLarge)) }
                }
            case .error(let error):
                if state.abandon() { timer.cancel(); promise.fail(error) }
            case .end:
                if let data = state.take() { timer.cancel(); promise.succeed(data) }
            }
            return loop.makeSucceededVoidFuture()
        }
        return try await promise.futureResult.get()
    }
}

final class UploadState: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private(set) var data = Data()
    /// False once over max; a no-op once the upload has ended.
    func append(_ chunk: inout ByteBuffer, max: Int) -> Bool {
        lock.withLock {
            if done { return true }
            if data.count + chunk.readableBytes > max { return false }
            data.append(contentsOf: chunk.readableBytesView)
            return true
        }
    }
    /// Ends the upload as failed, releasing the buffer. True for exactly one caller (of either).
    func abandon() -> Bool {
        lock.withLock { if done { return false }; done = true; data = Data(); return true }
    }
    /// Ends the upload as complete and hands over the buffer. Non-nil for exactly one caller.
    func take() -> Data? {
        lock.withLock {
            if done { return nil }
            done = true
            let out = data
            data = Data()
            return out
        }
    }
}

final class Busy: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    func tryAcquire() -> Bool { lock.withLock { if held { return false }; held = true; return true } }
    func release() { lock.withLock { held = false } }
}

/// An IPv4/IPv6 network for the peer allowlist.
struct CIDR: Sendable {
    let net: [UInt8]
    let bits: Int

    init(net: [UInt8], bits: Int) {
        self.net = net
        self.bits = bits
    }

    init?(_ s: String) {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: "/", maxSplits: 1)
        guard let addr = CIDR.bytes(String(parts[0])) else { return nil }
        let maxBits = addr.count * 8
        let b = parts.count == 2 ? Int(parts[1]) ?? -1 : maxBits
        guard (0...maxBits).contains(b) else { return nil }
        net = addr
        bits = b
    }

    /// An IPv4 peer and its IPv4-mapped IPv6 spelling (`::ffff:a.b.c.d`, how a dual-stack bind
    /// reports IPv4 clients) are the same peer: it matches a network of either family. Only the
    /// mapped prefix counts -- not the deprecated IPv4-compatible `::a.b.c.d` or NAT64 64:ff9b::/96.
    func contains(_ ip: String) -> Bool {
        guard let a = CIDR.bytes(ip) else { return false }
        return CIDR.forms(a).contains { $0.count == net.count && matches($0) }
    }

    static let mappedPrefix = [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF]

    /// `a` in every family it can arrive as: itself, plus its other spelling when it is IPv4 or
    /// IPv4-mapped IPv6.
    static func forms(_ a: [UInt8]) -> [[UInt8]] {
        if a.count == 4 { return [a, mappedPrefix + a] }
        if a.count == 16 && Array(a[0..<12]) == mappedPrefix { return [a, Array(a[12..<16])] }
        return [a]
    }

    /// The same network in the other family, when it has one: an IPv4 network as its mapped
    /// IPv6 range, and a network inside ::ffff:0:0/96 as the IPv4 addresses it maps.
    var otherFamily: CIDR? {
        if net.count == 4 { return CIDR(net: CIDR.mappedPrefix + net, bits: bits + 96) }
        if net.count == 16 && bits >= 96 && Array(span.lo[0..<12]) == CIDR.mappedPrefix {
            return CIDR(net: Array(net[12..<16]), bits: bits - 96)
        }
        return nil
    }

    private func matches(_ a: [UInt8]) -> Bool {
        for i in 0..<net.count {
            let take = min(8, max(0, bits - i * 8))
            if take == 0 { break }
            let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - take))
            if a[i] & mask != net[i] & mask { return false }
        }
        return true
    }

    static func bytes(_ s: String) -> [UInt8]? {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, s, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        if inet_pton(AF_INET6, s, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }
}

extension CIDR {
    /// The network's first and last address, big-endian.
    var span: (lo: [UInt8], hi: [UInt8]) {
        var lo = net, hi = net
        for i in 0..<net.count {
            let take = min(8, max(0, bits - i * 8))
            let mask = take == 0 ? UInt8(0) : UInt8(truncatingIfNeeded: 0xFF << (8 - take))
            lo[i] = net[i] & mask
            hi[i] = net[i] | ~mask
        }
        return (lo, hi)
    }
}

/// Whether `cidrs` together admit every address in `lo...hi` (both the same width).
func covers(_ cidrs: [CIDR], lo: [UInt8], hi: [UInt8]) -> Bool {
    let below = { (a: [UInt8], b: [UInt8]) in a.lexicographicallyPrecedes(b) }
    let spans = cidrs.filter { $0.net.count == lo.count }.compactMap { c -> ([UInt8], [UInt8])? in
        let (s, e) = c.span
        let start = below(s, lo) ? lo : s, end = below(hi, e) ? hi : e
        return below(end, start) ? nil : (start, end)
    }.sorted { below($0.0, $1.0) }
    var next = lo                       // the lowest address not yet shown to be covered
    for (start, end) in spans {
        if below(next, start) { return false }          // a gap no later span can fill
        if below(end, next) { continue }
        if end == hi { return true }
        next = end                      // end < hi, so end + 1 cannot overflow
        var i = next.count - 1
        while next[i] == 0xFF { next[i] = 0; i -= 1 }
        next[i] += 1
    }
    return false
}

/// Whether the allowlist admits every peer of some address family: all of IPv4, all of IPv6, or
/// every IPv4-mapped IPv6 address (how IPv4 peers can appear on a dual-stack bind). Checked for
/// every family, not just the bind's, so an allowlist can't gate one spelling and open another.
/// Matching treats an IPv4 peer and its mapped spelling as one (`CIDR.contains`), so coverage
/// does too: each network also counts in its other family, so IPv4 halves listed in different
/// spellings still add up to every IPv4 peer.
func admitsEveryAddress(_ given: [CIDR]) -> Bool {
    let cidrs = given + given.compactMap(\.otherFamily)
    let mapped = CIDR.mappedPrefix
    return covers(cidrs, lo: [UInt8](repeating: 0, count: 4), hi: [UInt8](repeating: 0xFF, count: 4))
        || covers(cidrs, lo: [UInt8](repeating: 0, count: 16), hi: [UInt8](repeating: 0xFF, count: 16))
        || covers(cidrs, lo: mapped + [0, 0, 0, 0], hi: mapped + [0xFF, 0xFF, 0xFF, 0xFF])
}

func parseCIDRs(_ raw: String) throws -> [CIDR] {
    try raw.split(separator: ",").map { s in
        guard let c = CIDR(String(s)) else { throw WorkerError("bad BLASTBOX_WORKER_AGENT_ALLOW_CIDRS entry: \(s)") }
        return c
    }
}
