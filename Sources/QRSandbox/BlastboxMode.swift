import Foundation
import QRScanCore

// `wtqrk-scan blastbox`: the scan document -> blastbox envelope step, run INSIDE the caller's
// sandbox. The scan has just parsed a hostile image in this very process, so everything it
// produced goes through the same validation the sandbox host applies to a child's stdout
// (`ScanOutputValidator.parse`) before `BlastboxEnvelope` turns it into the sealed document.

public enum BlastboxMode {
    /// What the sandbox host's `SandboxedScanner.outcome` makes of a scanner run, for a scan done
    /// in-process: the document must validate, and exit codes 2 and 3 (unusable input / config)
    /// are `rejected`, every other failure an `engine_error`.
    public static func outcome(of output: ScanOutput, exit: ScanExit) -> ScanOutcome {
        do {
            let doc = try JSONEncoder().encode(output)
            switch try ScanOutputValidator.parse(doc) {
            case .ok(let scan, let warnings):
                guard exit == .ok else {
                    return .engineError(code: "scanner_failed",
                                        message: "scan reported ok but exited rc=\(exit.rawValue)")
                }
                return .ok(scan, warnings: warnings, elapsedMs: 0)
            case .failed(let code, let message):
                return exit == .badInput || exit == .badConfig
                    ? .rejected(code: code, message: message)
                    : .engineError(code: code, message: message)
            }
        } catch {
            return .engineError(code: "bad_scanner_output", message: "\(error)")
        }
    }

    /// The one-line `metadata.json` document (sorted keys, no slash escaping, trailing newline).
    public static func line(outcome: ScanOutcome, inputSHA256: String, head: Data) throws -> Data {
        var data = try BlastboxEnvelope.metadataJSON(
            BlastboxEnvelope.envelope(outcome: outcome, inputSHA256: inputSHA256, head: head))
        data.append(0x0A)
        return data
    }
}
