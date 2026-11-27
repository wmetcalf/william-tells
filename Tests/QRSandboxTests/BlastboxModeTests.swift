import Foundation
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
    }

    @Test func anOkDocumentWithANonzeroExitIsNotATrustedResult() throws {
        let output = try JSONDecoder().decode(ScanOutput.self, from: fixture("scan.json"))
        guard case .engineError(let code, _) = BlastboxMode.outcome(of: output, exit: .failure) else {
            Issue.record("expected engineError"); return
        }
        #expect(code == "scanner_failed")
    }
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
        let code = await runBlastbox(ArraySlice([path.path] + extra), env: env, write: { out.append($0); return true })
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
        let (_, flagWins) = try await run(["--config-json", #"{"scales":[1]}"#], env: ["WTQRK_CONFIG": "garbage"])
        #expect(flagWins?["status"] as? String == "ok")
    }

    @Test func aFailedWriteIsAFailureExit() async throws {
        let png = try #require(ScanJob.qrPNG("x"))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("bb-\(UUID().uuidString).png")
        try png.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let code = await runBlastbox([path.path], env: [:], write: { _ in false })
        #expect(code == .failure)
    }
}
