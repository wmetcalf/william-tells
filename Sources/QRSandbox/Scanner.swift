import Foundation
import QRScanCore

public enum ScanOutcome: Sendable {
    case ok(ValidScan, warnings: [ScanWarning], elapsedMs: Int)
    /// The input or the requested config is unusable (not the scanner's fault).
    case rejected(code: String, message: String)
    /// The scanner couldn't produce a trustworthy answer. Never read this as "no QR".
    case engineError(code: String, message: String)
}

/// Scans images natively: each one in a fresh `wtqrk-scan` process that the kernel sandboxes at
/// exec (App Sandbox, from the slot's ad-hoc signature), reading the image from an inherited file
/// descriptor -- so it needs no file-path grant -- with no network, a wiped container, a time and
/// memory cap, and its output validated as untrusted.
///
/// **Self-test gate.** When a sandbox loses a grant Vision needs, it doesn't fail; it finds
/// nothing, which reads like a clean result. So before trusting any scan the scanner must decode a
/// freshly generated QR (on the Neural Engine where present) inside a slot AND report that the
/// kernel had it sandboxed, and a confinement probe must show that the slot can neither read a
/// canary file outside its container nor connect to a loopback listener. Until all of that passes,
/// every scan is `engineError("self_test_failed")`.
///
/// **Warm plan cache.** A wiped container makes Vision recompile its Neural Engine plan for every
/// image (~0.5 s). The self-test -- a trusted run on a generated QR, never job input -- leaves its
/// compiled plan in the container; that is captured once, and each job's container is seeded with a
/// copy-on-write clone of it. Nothing a job writes flows back, so one image cannot poison the next.
public actor SandboxedScanner {
    public nonisolated let slots: [SandboxSlot]
    private var free: [SandboxSlot]
    private var retired: [Int: String] = [:]          // slot index -> why it can't be reused
    private var waiters: [CheckedContinuation<SandboxSlot?, Never>] = []
    private let planCache: URL
    private var planCacheReady = false
    private var gate: Task<(ok: Bool, detail: String), Never>?

    /// Prepare (or reuse) one App Sandbox slot per index; each slot runs one scan at a time.
    public init(scanner: URL, slotIndices: [Int], root: URL = SlotProvisioner.defaultRoot()) throws {
        slots = try SlotProvisioner.prepare(scanner: scanner, root: root, indices: slotIndices)
        free = slots
        planCache = root.appendingPathComponent("plan-cache-\(slotIndices.map(String.init).joined(separator: "-"))",
                                                isDirectory: true)
    }

    /// Slots taken out of service because their container could not be proven clean.
    public var retiredSlots: [Int: String] { retired }

    /// False once every slot is retired: no job can ever run again (until restart + prepare).
    public var hasUsableSlot: Bool { retired.count < slots.count }

    // MARK: self-test gate

    /// Run (once) and cache the known-positive self-test. `(false, why)` disables scanning.
    public func selfTest() async -> (ok: Bool, detail: String) {
        if let gate { return await gate.value }
        let task = Task { await self.runSelfTest() }
        gate = task
        return await task.value
    }

    private func runSelfTest() async -> (ok: Bool, detail: String) {
        guard let slot = await checkout() else { return (false, "no clean slot: \(retired)") }
        guard clean(slot) else { return (false, "slot \(slot.identifier) could not be cleaned") }
        let result = await selfTestIn(slot)
        if result.ok {
            Container.capture(slot.containerData, to: planCache)
            planCacheReady = true
        }
        if clean(slot) { release(slot) }
        return result
    }

    private func selfTestIn(_ slot: SandboxSlot) async -> (ok: Bool, detail: String) {
        let r: RunResult
        do {
            r = try await Self.spawn([slot.executable.path, "self-test"], in: slot, stdinPath: "/dev/null",
                                     limits: RunLimits(timeoutSeconds: 120))
        } catch {
            return (false, "could not start the scanner: \(error)")
        }
        let detail = String(decoding: r.stdout.suffix(1500), as: UTF8.self)
            + String(decoding: r.stderr.suffix(500), as: UTF8.self)
        guard r.killed == nil, r.exitCode == 0,
              let out = try? JSONDecoder().decode(SelfTestOutput.self, from: r.stdout), out.ok
        else { return (false, detail) }
        guard out.sandboxed == true else {
            return (false, "the scanner decoded the test QR but was NOT sandboxed (slot \(slot.identifier))")
        }
        if let why = await probeConfinement(slot) {
            return (false, "confinement probe failed in \(slot.identifier): \(why)")
        }
        return (true, "self-test passed in \(slot.identifier) (\(r.elapsedMs) ms)")
    }

    /// nil when the slot is confined: it cannot read a host canary outside its container, cannot
    /// connect to a loopback listener (and the listener saw no connection), and is sandboxed.
    private func probeConfinement(_ slot: SandboxSlot) async -> String? {
        // Outside the slot dir: App Sandbox lets a program read its own executable's directory,
        // which is why a slot dir holds nothing but the scanner and inputs never go there.
        let canary = slot.executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("canary-\(slot.index)")
        let marker = Data("wtqrk confinement canary \(UUID().uuidString)\n".utf8)
        // The read check proves nothing unless the canary really exists and is readable to an
        // unconfined process: a missing canary would make even an unsandboxed probe say "denied".
        do {
            try? FileManager.default.removeItem(at: canary)
            try marker.write(to: canary)
            guard try Data(contentsOf: canary) == marker else { return "could not create the canary" }
        } catch {
            return "could not create the canary \(canary.path): \(error)"
        }
        defer { try? FileManager.default.removeItem(at: canary) }
        guard let listener = LoopbackListener() else { return "could not open a loopback listener" }
        defer { listener.close() }
        let r: RunResult
        do {
            r = try await Self.spawn([slot.executable.path, "probe", "--read", canary.path,
                                      "--connect", String(listener.port)],
                                     in: slot, stdinPath: "/dev/null", limits: RunLimits(timeoutSeconds: 30))
        } catch {
            return "could not start the probe: \(error)"
        }
        guard r.exitCode == 0,
              let doc = try? JSONSerialization.jsonObject(with: r.stdout) as? [String: Any]
        else { return "probe output unusable (rc=\(r.exitCode))" }
        var bad: [String] = []
        if doc["sandboxed"] as? Bool != true { bad.append("not sandboxed") }
        if doc["readDenied"] as? Bool != true { bad.append("read a file outside its container") }
        if doc["connectDenied"] as? Bool != true { bad.append("connected to the network") }
        if listener.acceptedAny() { bad.append("the loopback listener received a connection") }
        return bad.isEmpty ? nil : bad.joined(separator: "; ")
    }

    // MARK: scanning

    /// Scan the image at `path` (opened read-only here; the scanner only gets the descriptor).
    public func scan(path: String, maxBytes: Int, heavy: Bool, configJSON: String?,
                     limits: RunLimits = RunLimits()) async -> ScanOutcome {
        let gate = await selfTest()
        guard gate.ok else {
            return .engineError(code: "self_test_failed",
                                message: "scanner failed its known-QR self-test in the sandbox; no "
                                    + "result is trustworthy until it passes: " + gate.detail)
        }
        var argv = ["", "scan", "-", "--max-bytes", String(maxBytes)]
        if heavy { argv.append("--heavy") }
        if let configJSON {
            do { argv += ["--config-json", try ScanOutputValidator.canonicalConfig(configJSON)] }
            catch { return .rejected(code: "bad_config", message: "\(error)") }
        }

        guard let slot = await checkout() else {
            return .engineError(code: "no_clean_slot",
                                message: "every sandbox slot was retired: \(retired)")
        }
        guard clean(slot) else {
            return .engineError(code: "slot_unclean",
                                message: "slot \(slot.identifier) could not be cleaned and was retired")
        }
        argv[0] = slot.executable.path
        if planCacheReady { Container.seed(slot.containerData, from: planCache) }
        let r: RunResult
        do {
            r = try await Self.spawn(argv, in: slot, stdinPath: path, limits: limits)
        } catch {
            if clean(slot) { release(slot) }
            return .engineError(code: "spawn_failed", message: "\(error)")
        }
        // Clean up BEFORE answering: a slot whose container can't be emptied after this job is
        // retired, and this job's answer is still the scanner's (judged below like any other).
        if clean(slot) { release(slot) }
        return Self.outcome(r)
    }

    static func outcome(_ r: RunResult) -> ScanOutcome {
        func tail(_ d: Data) -> String { String(decoding: d.suffix(500), as: UTF8.self) }
        if let why = r.killed {
            return .engineError(code: "scanner_killed", message: "scanner killed (\(why)): " + tail(r.stderr))
        }
        if r.stdoutTruncated {
            return .engineError(code: "bad_scanner_output", message: "scanner output exceeded its cap")
        }
        do {
            switch try ScanOutputValidator.parse(r.stdout) {
            case .ok(let scan, let warnings):
                return .ok(scan, warnings: warnings, elapsedMs: r.elapsedMs)
            case .failed(let code, let message):
                return r.exitCode == 2 || r.exitCode == 3
                    ? .rejected(code: code, message: message)
                    : .engineError(code: code, message: message)
            }
        } catch {
            return .engineError(code: "bad_scanner_output",
                                message: "rc=\(r.exitCode): \(error); stderr: " + tail(r.stderr))
        }
    }

    /// Scan bytes already in memory (spooled to a private temp file the scanner reads via fd).
    public func scan(data: Data, heavy: Bool, configJSON: String?,
                     limits: RunLimits = RunLimits()) async -> ScanOutcome {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtqrk-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let f = dir.appendingPathComponent("input")
            try data.write(to: f)
            defer { try? FileManager.default.removeItem(at: dir) }
            return await scan(path: f.path, maxBytes: max(data.count, 1), heavy: heavy,
                              configJSON: configJSON, limits: limits)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return .engineError(code: "spool_failed", message: "\(error)")
        }
    }

    // MARK: slots

    /// Kill anything still running from the slot, then empty its container. On failure the slot
    /// is retired (never handed out again) and false is returned; the caller must not release it.
    private func clean(_ slot: SandboxSlot) -> Bool {
        Runner.sweep(container: slot.containerData.path)
        Runner.sweep(executable: slot.executable.path)
        do {
            try Container.wipe(slot.containerData)
            return true
        } catch {
            retire(slot, why: "\(error)")
            return false
        }
    }

    /// nil when no slot can ever be handed out (all retired).
    private func checkout() async -> SandboxSlot? {
        if let s = free.popLast() { return s }
        if retired.count == slots.count { return nil }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func release(_ slot: SandboxSlot) {
        if !waiters.isEmpty { waiters.removeFirst().resume(returning: slot) } else { free.append(slot) }
    }

    private func retire(_ slot: SandboxSlot, why: String) {
        retired[slot.index] = why
        if retired.count == slots.count {
            for w in waiters { w.resume(returning: nil) }
            waiters.removeAll()
        }
    }

    /// Run off the actor (the runner blocks), with `stdinPath` opened read-only as stdin.
    static func spawn(_ argv: [String], in slot: SandboxSlot, stdinPath: String,
                      limits: RunLimits) async throws -> RunResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let fd = open(stdinPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else {
                    cont.resume(throwing: Runner.posixError("open \(stdinPath)"))
                    return
                }
                defer { close(fd) }
                cont.resume(with: Result { try Runner.run(argv, stdinFD: fd, limits: limits,
                                                          container: slot.containerData.path) })
            }
        }
    }
}

/// A non-blocking TCP listener on 127.0.0.1:<ephemeral>, to see whether a probe got through.
final class LoopbackListener {
    let fd: Int32
    let port: UInt16

    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && listen(fd, 4) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard ok else { Darwin.close(fd); return nil }
        self.fd = fd
        port = UInt16(bigEndian: addr.sin_port)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    func acceptedAny() -> Bool {
        let c = accept(fd, nil, nil)
        if c >= 0 { Darwin.close(c); return true }
        return false
    }

    func close() { Darwin.close(fd) }
}
