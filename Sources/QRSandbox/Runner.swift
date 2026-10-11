import Darwin
import Foundation

/// What one sandboxed scanner process did.
public struct RunResult: Sendable {
    public let exitCode: Int32          // -1 when killed by a signal
    public let killed: String?          // "timeout" / "memory" / nil
    public let stdout: Data
    public let stdoutTruncated: Bool
    public let stderr: Data
    public let elapsedMs: Int
}

public struct RunLimits: Sendable {
    public var timeoutSeconds: Double
    /// Physical footprint cap, polled (RLIMIT_AS is not enforced on Darwin).
    public var maxFootprintBytes: UInt64
    public var maxStdoutBytes: Int
    public var maxStderrBytes: Int

    public init(timeoutSeconds: Double = 60, maxFootprintBytes: UInt64 = 2 << 30,
                maxStdoutBytes: Int = 4 << 20, maxStderrBytes: Int = 64 << 10) {
        self.timeoutSeconds = timeoutSeconds
        self.maxFootprintBytes = maxFootprintBytes
        self.maxStdoutBytes = maxStdoutBytes
        self.maxStderrBytes = maxStderrBytes
    }
}

public enum Runner {
    /// Spawn `argv` with `stdinFD` as its stdin and a minimal environment, in its own process
    /// group. The child sees no other fd of ours (POSIX_SPAWN_CLOEXEC_DEFAULT). Kills the group on
    /// timeout or when its footprint passes the cap.
    public static func run(_ argv: [String], stdinFD: Int32, limits: RunLimits) throws -> RunResult {
        var outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { throw posixError("pipe") }
        defer { for fd in outPipe + errPipe where fd >= 0 { close(fd) } }

        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_adddup2(&fa, stdinFD, 0)
        posix_spawn_file_actions_adddup2(&fa, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fa, errPipe[1], 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                              | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all); sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)

        // App Sandbox gives the process its container as HOME/TMPDIR; pass nothing else of ours.
        let env = ["PATH=/usr/bin:/bin", "LANG=en_US.UTF-8"]
        var pid: pid_t = 0
        let t0 = Date()
        let rc = withCStrings(argv) { cargv in
            withCStrings(env) { cenv in posix_spawn(&pid, argv[0], &fa, &attr, cargv, cenv) }
        }
        guard rc == 0 else { throw posixError("posix_spawn \(argv[0])", code: rc) }
        close(outPipe[1]); outPipe[1] = -1
        close(errPipe[1]); errPipe[1] = -1

        let out = CappedReader(fd: outPipe[0], cap: limits.maxStdoutBytes)
        let err = CappedReader(fd: errPipe[0], cap: limits.maxStderrBytes)
        out.start(); err.start()

        var killed: String?
        var status: Int32 = 0
        let deadline = t0.addingTimeInterval(limits.timeoutSeconds)
        while true {
            let w = waitpid(pid, &status, WNOHANG)
            if w == pid { break }
            if w < 0 && errno != EINTR { break }
            if killed == nil {
                if Date() >= deadline {
                    killed = "timeout"
                } else if footprint(pid) > limits.maxFootprintBytes {
                    killed = "memory"
                }
                if killed != nil { kill(-pid, SIGKILL); kill(pid, SIGKILL) }
            }
            usleep(5_000)
        }
        // Anything left in the group (the scanner forks nothing, but be sure) goes too.
        kill(-pid, SIGKILL)
        let stdout = out.finish(), stderr = err.finish()
        let exited = (status & 0x7f) == 0
        return RunResult(exitCode: exited ? (status >> 8) & 0xff : -1, killed: killed,
                         stdout: stdout.data, stdoutTruncated: stdout.truncated, stderr: stderr.data,
                         elapsedMs: Int(Date().timeIntervalSince(t0) * 1000))
    }

    static func footprint(_ pid: pid_t) -> UInt64 {
        var info = rusage_info_v2()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        return rc == 0 ? info.ri_phys_footprint : 0
    }

    static func posixError(_ what: String, code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(code)))"])
    }

    static func withCStrings<R>(_ strings: [String],
                                _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
        var ptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        ptrs.append(nil)
        defer { for p in ptrs { free(p) } }
        return body(ptrs)
    }
}

/// Drains a pipe on its own thread, keeping at most `cap` bytes (the rest is read and dropped so
/// the child never blocks on a full pipe).
final class CappedReader: @unchecked Sendable {
    private let fd: Int32
    private let cap: Int
    private var data = Data()
    private var truncated = false
    private let done = DispatchSemaphore(value: 0)

    init(fd: Int32, cap: Int) {
        self.fd = fd
        self.cap = cap
    }

    func start() {
        Thread.detachNewThread { [self] in
            var buf = [UInt8](repeating: 0, count: 64 << 10)
            while true {
                let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                let room = cap - data.count
                if room > 0 { data.append(buf, count: min(n, room)) }
                if n > room { truncated = true }
            }
            done.signal()
        }
    }

    func finish() -> (data: Data, truncated: Bool) {
        done.wait()
        return (data, truncated)
    }
}
