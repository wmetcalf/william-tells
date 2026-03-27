import Foundation
import Vapor

// MARK: - Job Types

enum JobStatus: String, Codable {
    case queued
    case processing
    case completed
    case failed
}

struct JobResult: Codable {
    let scanReport: ScanReport?
    let batchResponse: BatchScanResponse?
}

struct Job: Codable {
    let id: UUID
    var status: JobStatus
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var result: JobResult?
    var error: String?
}

struct JobResponse: Content {
    let id: UUID
    let status: String
}

struct JobStatusResponse: Content {
    let id: UUID
    let status: String
    let createdAt: Date
    let startedAt: Date?
    let completedAt: Date?
    let result: JobResult?
    let error: String?
}

// MARK: - Job Store

actor JobStore {
    private var jobs: [UUID: Job] = [:]
    private let maxCompletedAge: TimeInterval = 3600 // evict completed jobs after 1 hour

    func create() -> UUID {
        evictStale()
        let id = UUID()
        jobs[id] = Job(
            id: id,
            status: .queued,
            createdAt: Date()
        )
        return id
    }

    private func evictStale() {
        let cutoff = Date().addingTimeInterval(-maxCompletedAge)
        jobs = jobs.filter { _, job in
            guard job.status == .completed || job.status == .failed else { return true }
            guard let completedAt = job.completedAt else { return true }
            return completedAt > cutoff
        }
    }

    func markProcessing(_ id: UUID) {
        jobs[id]?.status = .processing
        jobs[id]?.startedAt = Date()
    }

    func complete(_ id: UUID, result: JobResult) {
        jobs[id]?.status = .completed
        jobs[id]?.completedAt = Date()
        jobs[id]?.result = result
    }

    func fail(_ id: UUID, error: String) {
        jobs[id]?.status = .failed
        jobs[id]?.completedAt = Date()
        jobs[id]?.error = error
    }

    func get(_ id: UUID) -> Job? {
        return jobs[id]
    }
}

// MARK: - Scanner Pool

actor ScannerPool {
    private var available: [QRScannerEngine]
    private var waiters: [CheckedContinuation<QRScannerEngine, Never>] = []

    init(size: Int) {
        self.available = (0..<size).map { _ in QRScannerEngine() }
    }

    func checkout() async -> QRScannerEngine {
        if let engine = available.popLast() {
            return engine
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func checkin(_ engine: QRScannerEngine) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: engine)
        } else {
            available.append(engine)
        }
    }
}

// MARK: - Work Items

enum WorkItem: Sendable {
    case single(id: UUID, imageData: Data, config: MutationConfig, earlyExit: Bool)
    case batch(id: UUID, images: [(name: String, data: Data)], config: MutationConfig, earlyExit: Bool)
}

// MARK: - Job Queue

enum QueueError: Error, AbortError {
    case queueFull

    var status: HTTPResponseStatus { .tooManyRequests }
    var reason: String { "Too many pending jobs. Try again later." }
}

actor JobQueue {
    private let store: JobStore
    private let pool: ScannerPool
    private let stream: AsyncStream<WorkItem>
    private let continuation: AsyncStream<WorkItem>.Continuation
    private var pendingCount: Int = 0
    private let maxPending: Int

    init(store: JobStore, pool: ScannerPool, workerCount: Int = 8, maxPending: Int = 100) {
        self.store = store
        self.pool = pool
        self.maxPending = maxPending

        let (stream, continuation) = AsyncStream<WorkItem>.makeStream()
        self.stream = stream
        self.continuation = continuation

        // Spawn worker tasks — each references self to decrement pendingCount
        let queue = self
        for _ in 0..<workerCount {
            Task { [stream, store, pool] in
                for await item in stream {
                    let engine = await pool.checkout()

                    switch item {
                    case .single(let id, let imageData, let config, let earlyExit):
                        await store.markProcessing(id)
                        do {
                            let report = try await engine.scan(
                                imageData: imageData,
                                config: config,
                                earlyExit: earlyExit
                            )
                            await store.complete(id, result: JobResult(
                                scanReport: report,
                                batchResponse: nil
                            ))
                        } catch {
                            await store.fail(id, error: error.localizedDescription)
                        }

                    case .batch(let id, let images, let config, let earlyExit):
                        await store.markProcessing(id)
                        do {
                            var results: [BatchImageReport] = []
                            for (name, data) in images {
                                let start = ContinuousClock.now
                                let report = try await engine.scan(
                                    imageData: data,
                                    config: config,
                                    earlyExit: earlyExit
                                )
                                let elapsed = start.duration(to: .now)
                                let ms = Int(elapsed.components.seconds * 1000 +
                                    elapsed.components.attoseconds / 1_000_000_000_000_000)
                                results.append(BatchImageReport(
                                    id: name,
                                    report: report,
                                    durationMs: ms
                                ))
                            }
                            let batchResponse = BatchScanResponse(
                                results: results,
                                totalProcessed: results.count,
                                totalWithDetections: results.filter { !$0.report.detections.isEmpty }.count
                            )
                            await store.complete(id, result: JobResult(
                                scanReport: nil,
                                batchResponse: batchResponse
                            ))
                        } catch {
                            await store.fail(id, error: error.localizedDescription)
                        }
                    }

                    await pool.checkin(engine)
                    await queue.jobCompleted()
                }
            }
        }
    }

    func enqueue(_ item: WorkItem) throws {
        guard pendingCount < maxPending else {
            throw QueueError.queueFull
        }
        pendingCount += 1
        continuation.yield(item)
    }

    fileprivate func jobCompleted() {
        pendingCount -= 1
    }
}
