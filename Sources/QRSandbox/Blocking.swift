import Foundation

/// Blocking work (process sweeps, container wipes, file writes and hashes) run on a GCD thread,
/// so it never holds one of the Swift concurrency pool's few threads (or an actor) while it waits.
public enum Blocking {
    public static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(with: Result { try body() }) }
        }
    }

    public static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: body()) }
        }
    }
}
