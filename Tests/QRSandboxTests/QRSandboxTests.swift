import Foundation
import Testing
@testable import QRSandbox

// MARK: - untrusted output validation

@Suite struct ValidatorTests {
    func doc(_ dets: String = #"[{"payload":"https://x","symbology":"VNBarcodeSymbologyQR","confidence":1,"boundingBox":{"x":0.1,"y":0.1,"width":0.8,"height":0.8}}]"#,
             extra: String = "") -> Data {
        Data(#"{"schema":"wtqrk.scan/1","ok":true,"mode":"default","compute":"auto","report":{"imageDimensions":{"width":390,"height":390},"mutationsTried":0,"detections":\#(dets)}\#(extra)}"#.utf8)
    }

    @Test func acceptsAWellFormedScan() throws {
        guard case .ok(let scan, let warnings) = try ScanOutputValidator.parse(doc()) else {
            Issue.record("expected ok"); return
        }
        #expect(scan.detections.map(\.payload) == ["https://x"])
        #expect(scan.imageWidth == 390 && scan.mutationsTried == 0 && warnings.isEmpty)
    }

    @Test func scannerReportedFailureIsPassedThrough() throws {
        let d = Data(#"{"schema":"wtqrk.scan/1","ok":false,"error":{"code":"invalid_image","message":"nope"}}"#.utf8)
        guard case .failed(let code, let message) = try ScanOutputValidator.parse(d) else {
            Issue.record("expected failed"); return
        }
        #expect(code == "invalid_image" && message == "nope")
    }

    @Test func rejectsMalformedOrHostileOutput() {
        let bad: [Data] = [
            Data("not json".utf8),
            Data(#"{"schema":"other/1","ok":true}"#.utf8),
            doc(#"[{"payload":7}]"#),
            doc(#"[{"payload":"x","symbology":"QR","confidence":2,"boundingBox":{"x":0,"y":0,"width":1,"height":1}}]"#),
            doc(#"[{"payload":"x","symbology":"QR","confidence":true,"boundingBox":{"x":0,"y":0,"width":1,"height":1}}]"#),
            doc(#"[{"payload":"x","symbology":"QR","confidence":1,"boundingBox":{"x":1e309,"y":0,"width":1,"height":1}}]"#),
            doc("{}"),
            Data(repeating: 0x20, count: ScanOutputValidator.maxStdoutBytes + 1),
        ]
        for d in bad {
            #expect(throws: (any Error).self) { try ScanOutputValidator.parse(d) }
        }
    }

    @Test func boundsDetectionsAndPayloads() throws {
        let one = #"{"payload":"\#(String(repeating: "A", count: 5000))","symbology":"QR","confidence":1,"boundingBox":{"x":0,"y":0,"width":1,"height":1}}"#
        let many = "[" + Array(repeating: one, count: 300).joined(separator: ",") + "]"
        guard case .ok(let scan, let warnings) = try ScanOutputValidator.parse(doc(many)) else {
            Issue.record("expected ok"); return
        }
        #expect(scan.detections.count == ScanOutputValidator.maxDetections)
        #expect(scan.detections[0].payload.count == ScanOutputValidator.maxPayloadChars)
        #expect(Set(warnings.map(\.code)) == ["detections_truncated", "payload_truncated"])
    }

    @Test func configIsStrict() throws {
        #expect(try ScanOutputValidator.canonicalConfig(#"{"scales":[1,2]}"#) == #"{"scales":[1,2]}"#)
        for raw in [#"{"evil":[1]}"#, #"{"scales":[true]}"#, #"{"scales":"1"}"#, "[]",
                    #"{"scales":[1,2,3,4,5,6,7,8,9,10,11]}"#] {
            #expect(throws: (any Error).self) { try ScanOutputValidator.canonicalConfig(raw) }
        }
    }
}

// MARK: - real sandboxed scans (need a built wtqrk-scan)

/// `.build/<config>/wtqrk-scan`, or `$WTQRK_SCAN_BIN`.
func scannerBinary() -> URL? {
    if let env = ProcessInfo.processInfo.environment["WTQRK_SCAN_BIN"] { return URL(fileURLWithPath: env) }
    let pkg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    for config in ["release", "debug"] {
        let u = pkg.appendingPathComponent(".build/\(config)/wtqrk-scan")
        if FileManager.default.isExecutableFile(atPath: u.path) { return u }
    }
    return nil
}

func render(_ message: String, in dir: URL) throws -> URL {
    let out = dir.appendingPathComponent("\(UUID().uuidString).png")
    let p = Process()
    p.executableURL = scannerBinary()
    p.arguments = ["render-qr", message, out.path]
    try p.run(); p.waitUntilExit()
    return out
}

@Suite(.serialized, .enabled(if: scannerBinary() != nil, "build wtqrk-scan first (swift build -c release)"))
struct SandboxedScannerTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wtqrk-test-\(UUID().uuidString)")

    @Test func scansInAConfinedFreshSandbox() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // A test-only identifier range so tests never touch a real worker's slot containers.
        let scanner = try SandboxedScanner(scanner: scannerBinary()!, slotIndices: [900, 901], root: root)
        let gate = await scanner.selfTest()
        #expect(gate.ok, "\(gate.detail)")

        let message = "https://qrsandbox.test/\(UUID().uuidString)"
        let png = try render(message, in: root)
        guard case .ok(let scan, _, _) = await scanner.scan(path: png.path, maxBytes: 1 << 20,
                                                            heavy: false, configJSON: nil) else {
            Issue.record("expected a decoded QR"); return
        }
        #expect(scan.detections.map(\.payload) == [message])

        // Concurrent scans land in different slots (containers).
        async let a = scanner.scan(path: png.path, maxBytes: 1 << 20, heavy: false, configJSON: nil)
        async let b = scanner.scan(path: png.path, maxBytes: 1 << 20, heavy: true, configJSON: nil)
        for r in await [a, b] {
            guard case .ok(let s, _, _) = r else { Issue.record("concurrent scan failed: \(r)"); continue }
            #expect(s.detections.map(\.payload) == [message])
        }
        // Containers are left empty after every job.
        for slot in scanner.slots {
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: slot.containerData.path)) ?? []).isEmpty)
        }
    }

    @Test func garbageIsRejectedNotAnEngineError() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let scanner = try SandboxedScanner(scanner: scannerBinary()!, slotIndices: [902], root: root)
        let r = await scanner.scan(data: Data(repeating: 0x41, count: 512), heavy: false, configJSON: nil)
        guard case .rejected(let code, _) = r else { Issue.record("expected rejected, got \(r)"); return }
        #expect(code == "invalid_image")
        let big = await scanner.scan(path: try render("x", in: root).path, maxBytes: 10, heavy: false,
                                     configJSON: nil)
        guard case .rejected(let c2, _) = big else { Issue.record("expected too_large, got \(big)"); return }
        #expect(c2 == "too_large")
    }

    @Test func sweepByContainerFindsTheSlotsProcesses() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let slot = try SlotProvisioner.prepare(scanner: scannerBinary()!, root: root, indices: [904])[0]
        // A sandboxed scanner parked on a stdin that never closes, found only by its container.
        let p = Process()
        p.executableURL = slot.executable
        p.arguments = ["scan", "-"]
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        defer { try? stdin.fileHandleForWriting.close() }
        var found = false
        for _ in 0..<200 where !found {        // the container exists once the sandbox is up
            found = Runner.containerPath(p.processIdentifier) != nil
            if !found { usleep(10_000) }
        }
        #expect(found)
        Runner.sweep(container: slot.containerData.path)
        p.waitUntilExit()
        #expect(p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGKILL)
    }

    @Test func aSlotWithoutTheSandboxEntitlementIsRefused() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let slot = try SlotProvisioner.prepare(scanner: scannerBinary()!, root: root, indices: [903])[0]
        try SlotProvisioner.codesign(["-f", "-s", "-", "-i", slot.identifier, slot.executable.path])
        #expect(throws: SandboxError.self) { try SlotProvisioner.verify(slot) }
        // ...and prepare() notices and re-signs it.
        let again = try SlotProvisioner.prepare(scanner: scannerBinary()!, root: root, indices: [903])[0]
        #expect((try? SlotProvisioner.verify(again)) != nil)
    }
}

// MARK: - container hygiene + stray processes

@Suite struct HygieneTests {
    @Test func wipeUnlocksWhatAScannerCouldLock() throws {
        let fm = FileManager.default
        let data = fm.temporaryDirectory.appendingPathComponent("wtqrk-wipe-\(UUID().uuidString)")
        defer { Container.unlock(data.path); try? fm.removeItem(at: data) }
        let locked = data.appendingPathComponent("Library/locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        let f = locked.appendingPathComponent("immutable")
        try Data("x".utf8).write(to: f)
        #expect(chflags(f.path, UInt32(UF_IMMUTABLE)) == 0)   // what a scanner can do to its own files
        #expect(chmod(locked.path, 0o000) == 0)
        try fm.createSymbolicLink(atPath: data.appendingPathComponent("link").path,
                                  withDestinationPath: "/etc/hosts")
        try Container.wipe(data)
        #expect(try fm.contentsOfDirectory(atPath: data.path).isEmpty)
        #expect(fm.fileExists(atPath: "/etc/hosts"))           // the link was removed, not followed
    }

    @Test func aSymlinkedContainerIsNotFollowed() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("wtqrk-symlink-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let victim = base.appendingPathComponent("victim")
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: victim.appendingPathComponent("precious"))
        let data = base.appendingPathComponent("Data")
        try fm.createSymbolicLink(at: data, withDestinationURL: victim)
        #expect(throws: Container.UncleanError.self) { try Container.wipe(data) }
        #expect(fm.fileExists(atPath: victim.appendingPathComponent("precious").path))
    }

    @Test func aMissingContainerIsClean() throws {
        try Container.wipe(URL(fileURLWithPath: "/nonexistent/wtqrk-\(UUID().uuidString)"))
    }

    @Test func sweepKillsStraysRunningTheSlotBinary() throws {
        let exe = FileManager.default.temporaryDirectory.appendingPathComponent("wtqrk-stray-\(UUID().uuidString)")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: exe.path)
        defer { try? FileManager.default.removeItem(at: exe) }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["60"]
        try p.run()
        Runner.sweep(executable: exe.path)
        p.waitUntilExit()
        #expect(p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGKILL)
    }

    @Test func anEscapeeHoldingThePipesCannotHangTheRun() throws {
        // The child detaches (new session), execs another binary and lets its parent exit while
        // still holding stdout/stderr: not in the group, not in the tree, not the same binary.
        let tag = "wtqrk-escapee-\(UUID().uuidString)"
        defer { _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pkill"), arguments: ["-f", tag]) }
        let t0 = Date()
        let r = try Runner.run(["/bin/sh", "-c",
                                "/usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec { \"/bin/sleep\" } \"\(tag)\", \"30\"' & /bin/sleep 0.5"],
                               stdinFD: open("/dev/null", O_RDONLY), limits: RunLimits(timeoutSeconds: 1))
        #expect(Date().timeIntervalSince(t0) < 10)
        #expect(r.killed == "escaped")
        #expect(StaticScannerOutcome.isEngineError(r))
    }
}

enum StaticScannerOutcome {
    static func isEngineError(_ r: RunResult) -> Bool {
        if case .engineError(let code, _) = SandboxedScanner.outcome(r) { return code == "scanner_killed" }
        return false
    }
}
