import Foundation
import CryptoKit
import Testing
import QRScanCore
@testable import QRSandbox
@testable import wtqrk_scan

@Suite struct BlastboxModeTests {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/blastbox-mode")
    static let sha = String(repeating: "ab", count: 32)
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])

    func fixture(_ name: String) throws -> Data { try Data(contentsOf: Self.dir.appendingPathComponent(name)) }

    func parsed(_ d: Data) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: d) as? NSDictionary)
    }

    @Test func theEnvelopeForTheFixtureScanEqualsTheCommittedExpectedJSON() throws {
        let output = try JSONDecoder().decode(ScanOutput.self, from: fixture("scan.json"))
        let outcome = BlastboxMode.outcome(of: output, exit: .ok)
        let line = try BlastboxMode.line(outcome: outcome, inputSHA256: Self.sha, head: Self.png)
        #expect(line.last == 0x0A && line.dropLast().contains(0x0A) == false)   // exactly one line
        #expect(try parsed(line) == parsed(fixture("expected-envelope.json")))
    }

    @Test func aFailedScanIsRejectedForBadInputAndAnEngineErrorOtherwise() throws {
        func failed(_ code: String) -> ScanOutput {
            ScanOutput(schema: scanSchema, ok: false, mode: "default", compute: nil, report: nil,
                       error: ScanErrorBody(code: code, message: "m"))
        }
        func status(_ o: ScanOutcome) throws -> String {
            let line = try BlastboxMode.line(outcome: o, inputSHA256: Self.sha, head: Data())
            return try #require(parsed(line)["status"] as? String)
        }
        #expect(try status(BlastboxMode.outcome(of: failed("invalid_image"), exit: .badInput)) == "rejected")
        #expect(try status(BlastboxMode.outcome(of: failed("bad_config"), exit: .badConfig)) == "rejected")
        #expect(try status(BlastboxMode.outcome(of: failed("scan_failed"), exit: .failure)) == "engine_error")
        // The scanner's own code is carried, as the push path does.
        guard case .rejected(let rc, _) = BlastboxMode.outcome(of: failed("invalid_image"), exit: .badInput),
              case .engineError(let ec, _) = BlastboxMode.outcome(of: failed("scan_failed"), exit: .failure)
        else { Issue.record("unexpected outcome"); return }
        #expect(rc == "invalid_image" && ec == "scan_failed")
    }

    @Test func anOkDocumentWithANonzeroExitIsNotATrustedResult() throws {
        let output = try JSONDecoder().decode(ScanOutput.self, from: fixture("scan.json"))
        guard case .engineError(let code, _) = BlastboxMode.outcome(of: output, exit: .failure) else {
            Issue.record("expected engineError"); return
        }
        #expect(code == "scanner_failed")
    }
}

/// The real known-QR decode gate, minus the sandbox requirement (`swift test` is unsandboxed).
func unsandboxedSelfTest(_ c: ComputePreference) async -> (ok: Bool, detail: String) {
    await blastboxSelfTest(c, requireSandbox: false)
}

@Suite struct BlastboxCLITests {
    /// Runs `blastbox` on a rendered QR with an injected env; returns (exit, parsed envelope).
    func run(_ extra: [String] = [], env: [String: String]) async throws -> (ScanExit, NSDictionary?) {
        let png = try #require(ScanJob.qrPNG("https://example.test/cli"))
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("blastbox-cli-\(UUID().uuidString).png")
        try png.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        var out = Data()
        let code = await runBlastbox(ArraySlice([path.path] + extra), env: env, write: { out.append($0); return true },
                                     selfTest: unsandboxedSelfTest)
        return (code, try? JSONSerialization.jsonObject(with: out) as? NSDictionary)
    }
    func mode(_ e: NSDictionary?) -> String? {
        ((e?["payload"] as? NSDictionary)?["fields"] as? NSDictionary)?["mode"] as? String
    }

    @Test func envModeIsAFallbackAndAFlagWins() async throws {
        let (c1, e1) = try await run(env: ["WTQRK_MODE": "heavy"])
        #expect(c1 == .ok && e1?["status"] as? String == "ok" && mode(e1) == "heavy")
        let (_, e2) = try await run(["--heavy"], env: [:])
        #expect(mode(e2) == "heavy")
        let (_, e3) = try await run(env: [:])
        #expect(mode(e3) == "default")
    }

    @Test func aTrailingNewlineInWTQRKModeIsStripped() async throws {
        let (c, e) = try await run(env: ["WTQRK_MODE": "heavy\n"])
        #expect(c == .ok && mode(e) == "heavy")
    }

    @Test func aBadEnvConfigIsARejectedEnvelopeWithExitZero() async throws {
        let (c, e) = try await run(env: ["WTQRK_CONFIG": "garbage"])
        #expect(c == .ok && e?["status"] as? String == "rejected")
        let (_, flagWins) = try await run(["--config-json", #"{"scales":[1]}"#], env: ["WTQRK_CONFIG": #"{"scales":[2]}"#])
        #expect(flagWins?["status"] as? String == "ok")
        // A malformed env param is rejected even when a flag overrides it (as the push path does).
        let (_, overridden) = try await run(["--config-json", #"{"scales":[1]}"#], env: ["WTQRK_CONFIG": "garbage"])
        #expect(overridden?["status"] as? String == "rejected")
    }

    /// Runs `blastbox` on `bytes` written to a temp file; returns (exit, raw output).
    func runOn(_ bytes: Data, _ extra: [String] = [], env: [String: String] = [:],
               mode: Int16? = nil) async throws -> (ScanExit, Data) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("bb-\(UUID().uuidString).bin")
        try bytes.write(to: path)
        if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path.path) }
        defer { try? FileManager.default.removeItem(at: path) }
        var out = Data()
        let code = await runBlastbox(ArraySlice([path.path] + extra), env: env, write: { out.append($0); return true },
                                     selfTest: unsandboxedSelfTest)
        return (code, out)
    }

    @Test func aTooLargeInputCarriesItsRealSHA256SoTheTrustGateAcceptsIt() async throws {
        let bytes = Data((0..<100).map { UInt8($0) })
        let (c, out) = try await runOn(bytes, ["--max-bytes", "10"])
        let e = try #require(try JSONSerialization.jsonObject(with: out) as? NSDictionary)
        let want = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(c == .ok && e["status"] as? String == "rejected")
        #expect(e["input_sha256"] as? String == want)
    }

    @Test func aMalformedMaxBytesIsAUsageErrorNotASilentDefault() async throws {
        for bad in ["10MB", "0", "-1", "99999999999999999999"] {
            let (c, out) = try await runOn(Data([1, 2, 3]), ["--max-bytes", bad])
            #expect(c == .usage && out.isEmpty, "--max-bytes \(bad)")
        }
    }

    @Test func aBadEnvModeIsRejectedEvenWhenTheHeavyFlagIsGiven() async throws {
        let (c, e) = try await run(["--heavy"], env: ["WTQRK_MODE": "evil"])
        #expect(c == .ok && e?["status"] as? String == "rejected")
    }

    @Test func anUnreadableFileIsRejectedLikeTheScanPath() async throws {
        guard getuid() != 0 else { return }       // root reads a 000 file
        let (c, out) = try await runOn(Data([1, 2, 3]), env: [:], mode: 0o000)
        let e = try #require(try JSONSerialization.jsonObject(with: out) as? NSDictionary)
        #expect(c == .ok && e["status"] as? String == "rejected")
    }

    @Test func aFailedSelfTestIsASealedEngineErrorAndTheInputIsNeverScanned() async throws {
        var scanned = false
        var out = Data()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("bb-\(UUID().uuidString).png")
        try #require(ScanJob.qrPNG("x")).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let code = await runBlastbox([path.path], env: [:], write: { out.append($0); return true },
                                     selfTest: { _ in (false, "vision denied") },
                                     scan: { r in scanned = true; return await blastboxScan(r) })
        let e = try #require(try JSONSerialization.jsonObject(with: out) as? NSDictionary)
        let w = try #require((e["warnings"] as? [NSDictionary])?.first)
        #expect(code == .ok && e["status"] as? String == "engine_error" && !scanned)
        #expect(w["code"] as? String == "self_test_failed")
    }

    @Test func theScanGetsTheDefaultBudgetAndTheFlagConfig() async throws {
        var seen: BlastboxScanRequest?
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("bb-\(UUID().uuidString).png")
        try #require(ScanJob.qrPNG("x")).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        _ = await runBlastbox([path.path, "--config-json", #"{"scales":[1]}"#],
                              env: ["WTQRK_CONFIG": #"{"scales":[2]}"#, "WTQRK_MODE": "heavy"],
                              write: { _ in true }, selfTest: { _ in (true, "") },
                              scan: { r in seen = r; return await blastboxScan(r) })
        let r = try #require(seen)
        #expect(r.budget <= ScanJob.budget(forTimeout: 120) && r.budget > ScanJob.budget(forTimeout: 120) - 5 && r.heavy)
        #expect(r.configJSON == (try ScanOutputValidator.canonicalConfig(#"{"scales":[1]}"#)))
    }

    @Test func aSymlinkToARegularImageIsScannedLikeTheScanPath() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.png"), link = dir.appendingPathComponent("link.png")
        try #require(ScanJob.qrPNG("https://example.test/link")).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        var out = Data()
        let code = await runBlastbox([link.path], env: [:], write: { out.append($0); return true },
                                     selfTest: unsandboxedSelfTest)
        let e = try #require(try JSONSerialization.jsonObject(with: out) as? NSDictionary)
        #expect(code == .ok && e["status"] as? String == "ok")
    }

    @Test func aFIFOIsRejectedWithoutBlocking() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("bb-\(UUID().uuidString).fifo")
        try #require(mkfifo(path.path, 0o600) == 0)
        defer { try? FileManager.default.removeItem(at: path) }
        var out = Data()
        let code = await runBlastbox([path.path], env: [:], write: { out.append($0); return true },
                                     selfTest: unsandboxedSelfTest)
        let e = try #require(try JSONSerialization.jsonObject(with: out) as? NSDictionary)
        #expect(code == .ok && e["status"] as? String == "rejected")
    }

    @Test func theSelfTestsTimeComesOutOfTheScanBudget() async throws {
        var seen: BlastboxScanRequest?
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("bb-\(UUID().uuidString).png")
        try #require(ScanJob.qrPNG("x")).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        _ = await runBlastbox([path.path, "--budget-ms", "10000"], env: [:], write: { _ in true },
                              selfTest: { _ in try? await Task.sleep(nanoseconds: 1_500_000_000); return (true, "") },
                              scan: { r in seen = r; return await blastboxScan(r) })
        let r = try #require(seen)
        #expect(r.budget <= 8.6 && r.budget >= 1)
    }

    @Test func theSelfTestFailsWhenThisProcessIsNotSandboxed() async throws {
        // `swift test` runs unsandboxed: the push path's gate refuses that, so this one must too.
        let gate = await blastboxSelfTest(.auto)
        #expect(!gate.ok && gate.detail.contains("not sandboxed"))
        #expect(await blastboxSelfTest(.auto, requireSandbox: false).ok)
    }

    @Test func aSandboxCheckErrorIsNotSandboxed() {
        #expect(sandboxCheckSaysSandboxed(1))
        #expect(!sandboxCheckSaysSandboxed(0) && !sandboxCheckSaysSandboxed(-1))
    }

    @Test func aSubSecondBudgetIsHonoured() async throws {
        var seen: BlastboxScanRequest?
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("bb-\(UUID().uuidString).png")
        try #require(ScanJob.qrPNG("x")).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        _ = await runBlastbox([path.path, "--budget-ms", "200"], env: [:], write: { _ in true },
                              selfTest: { _ in (true, "") },
                              scan: { r in seen = r; return await blastboxScan(r) })
        let r = try #require(seen)
        #expect(r.budget <= 0.2 && r.budget > 0)
    }

    @Test func aFailedWriteIsAFailureExit() async throws {
        let png = try #require(ScanJob.qrPNG("x"))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("bb-\(UUID().uuidString).png")
        try png.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let code = await runBlastbox([path.path], env: [:], write: { _ in false }, selfTest: unsandboxedSelfTest)
        #expect(code == .failure)
    }
}
