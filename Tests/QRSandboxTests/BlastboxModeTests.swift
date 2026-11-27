import Foundation
import Testing
import QRScanCore
@testable import QRSandbox

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
