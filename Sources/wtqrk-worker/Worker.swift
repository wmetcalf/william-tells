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
        let cidrs = try parseCIDRs(e["BLASTBOX_WORKER_AGENT_ALLOW_CIDRS"] ?? "")

        for key in ["BLASTBOX_WORKER_AGENT_TLS_CERT", "BLASTBOX_WORKER_AGENT_TLS_KEY",
                    "BLASTBOX_WORKER_AGENT_CLIENT_CA"] where !(e[key] ?? "").isEmpty {
            throw WorkerError("\(key) is set, but wtqrk-worker does not terminate TLS; run the Python "
                + "http_agent for TLS/mTLS, or put a TLS proxy in front and bind loopback")
        }
        let loopback = ["127.0.0.1", "localhost", "::1"].contains(bind)
        if !loopback && token == nil && cidrs.isEmpty && e["BLASTBOX_WORKER_AGENT_ALLOW_INSECURE"] != "1" {
            throw WorkerError("refusing to serve \(bind):\(port) with no token and no "
                + "BLASTBOX_WORKER_AGENT_ALLOW_CIDRS: anyone who reaches the port could submit jobs")
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
        let agent = Agent(scanner: scanner, token: token, cidrs: cidrs, maxBytes: maxBytes, gate: gate,
                          logger: app.logger)

        app.get("healthz") { req async -> Response in
            if let denied = agent.deny(req) { return denied }
            return Agent.json(gate.ok ? .ok : .serviceUnavailable,
                              ["ok": gate.ok, "engine": BlastboxEnvelope.engine,
                               "agent": "wtqrk-worker", "self_test": gate.ok ? "passed" : "failed"])
        }
        app.on(.POST, "detonate", body: .collect(maxSize: ByteCount(value: maxBytes))) { req async -> Response in
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
    let gate: (ok: Bool, detail: String)
    let logger: Logger
    private let busy = Busy()

    init(scanner: SandboxedScanner, token: String?, cidrs: [CIDR], maxBytes: Int,
         gate: (ok: Bool, detail: String), logger: Logger) {
        self.scanner = scanner
        self.token = token
        self.cidrs = cidrs
        self.maxBytes = maxBytes
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

        let body = req.body.data.map { Data(buffer: $0) } ?? Data()
        guard body.count <= maxBytes else { return Agent.json(.payloadTooLarge, ["error": "too_large"]) }
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
}

func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    var diff = UInt8(a.count == b.count ? 0 : 1)
    for i in 0..<max(a.count, b.count) {
        diff |= (i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0)
    }
    return diff == 0
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

    init?(_ s: String) {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: "/", maxSplits: 1)
        guard let addr = CIDR.bytes(String(parts[0])) else { return nil }
        let maxBits = addr.count * 8
        let b = parts.count == 2 ? Int(parts[1]) ?? -1 : maxBits
        guard (0...maxBits).contains(b) else { return nil }
        net = addr
        bits = b
    }

    func contains(_ ip: String) -> Bool {
        guard let a = CIDR.bytes(ip), a.count == net.count else { return false }
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

func parseCIDRs(_ raw: String) throws -> [CIDR] {
    try raw.split(separator: ",").map { s in
        guard let c = CIDR(String(s)) else { throw WorkerError("bad BLASTBOX_WORKER_AGENT_ALLOW_CIDRS entry: \(s)") }
        return c
    }
}
