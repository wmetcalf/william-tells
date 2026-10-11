import Darwin
import Foundation

/// What one sandboxed scanner process did.
public struct RunResult: Sendable {
    public let exitCode: Int32          // -1 when killed by a signal
    public let killed: String?          // "timeout" / "memory" / "escaped" / nil
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
    /// timeout or when its footprint passes the cap. `container` is the App Sandbox container the
    /// child runs in: when the child exits, every process still in that container is killed too.
    public static func run(_ argv: [String], stdinFD: Int32, limits: RunLimits,
                           container: String? = nil) throws -> RunResult {
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
        // Everything in the slot's container counts toward the cap, so a child that left the
        // process group and tree (an intermediate + setsid) is still metered. Rescanned every
        // ~50 ms (it walks all of our processes); the group and tree every 5 ms.
        var inContainer: Set<pid_t> = []
        var tick = 0
        while true {
            let w = waitpid(pid, &status, WNOHANG)
            if w == pid { break }
            if w < 0 && errno != EINTR { break }
            if killed == nil {
                if Date() >= deadline {
                    killed = "timeout"
                } else if footprint(of: family(pid).union(inContainer)) > limits.maxFootprintBytes {
                    // The cap is for the whole job: a compromised scanner that forks can't spread
                    // its allocation across children to stay under it.
                    killed = "memory"
                }
                if killed != nil {
                    // Fresh, not the ~50 ms-old snapshot: a pid in it may have been reused.
                    killAll(family(pid).union(container.map { Set(members(container: $0)) } ?? []))
                    kill(-pid, SIGKILL)
                }
            }
            if let container, tick % 10 == 0 { inContainer = Set(members(container: container)) }
            tick += 1
            usleep(5_000)
        }
        // Anything the scanner left behind (it forks nothing, but a compromised one might) goes too.
        // A child that forked, setsid()ed and let the scanner exit is in neither the group nor the
        // tree any more, but it is still in the slot's container (and still runs the slot's binary
        // unless it exec'd something else), so it is found by those. A sweep that can't empty
        // the container (something keeps forking) fails the run.
        killAll(family(pid))
        kill(-pid, SIGKILL)
        // Only for a slot run: argv[0] is then the slot's own binary, never a shared one like
        // /bin/sh whose other users must not be swept.
        let swept = container.map { sweep(container: $0) && sweep(executable: argv[0]) } ?? true
        if killed == nil && !swept { killed = "escaped" }
        // Bounded: an escapee that survived the sweeps and holds the pipes must not hold this
        // worker. Output still open past the grace period means something escaped; the run fails.
        let drainBy = max(deadline, Date()).addingTimeInterval(2)
        let stdout = out.finish(by: drainBy), stderr = err.finish(by: drainBy)
        if killed == nil && (!stdout.complete || !stderr.complete) { killed = "escaped" }
        let exited = (status & 0x7f) == 0
        return RunResult(exitCode: exited ? (status >> 8) & 0xff : -1, killed: killed,
                         stdout: stdout.data, stdoutTruncated: stdout.truncated, stderr: stderr.data,
                         elapsedMs: Int(Date().timeIntervalSince(t0) * 1000))
    }

    /// `root`, its process group, and every descendant still parented under any of them.
    static func family(_ root: pid_t) -> Set<pid_t> {
        var out: Set<pid_t> = [root]
        out.formUnion(listPids(type: UInt32(PROC_PGRP_ONLY), arg: UInt32(root)))
        var frontier = Array(out)
        while let p = frontier.popLast() {
            for c in childPids(p) where !out.contains(c) {
                out.insert(c)
                frontier.append(c)
            }
        }
        return out
    }

    static func footprint(of pids: Set<pid_t>) -> UInt64 {
        pids.reduce(0) { $0 &+ footprint($1) }
    }

    static func killAll(_ pids: Set<pid_t>) {
        for p in pids where p > 1 { kill(p, SIGKILL) }
    }

    /// Kill every process whose executable is `executable` (a slot's scanner), and wait for them
    /// to go. Run before a slot is wiped or reused: a forked scanner that escaped its process
    /// group (setsid, then orphaned) still runs the slot's binary, so it is found by path.
    @discardableResult
    public static func sweep(executable: String) -> Bool {
        sweep { pidPath($0) == executable }
    }

    /// Kill every process of ours running in the App Sandbox container `container` (its `Data`
    /// directory). Sandbox and container survive fork and exec, so this finds an escapee even
    /// after it detached and exec'd another binary.
    @discardableResult
    public static func sweep(container: String) -> Bool {
        let want = canonical(container)
        return sweep { containerPath($0).map(canonical) == want }
    }

    /// Our processes (other than us) in `container`.
    static func members(container: String) -> [pid_t] {
        let want = canonical(container)
        let me = getpid()
        return listPids(type: UInt32(PROC_UID_ONLY), arg: getuid())
            .filter { $0 != me && containerPath($0).map(canonical) == want }
    }

    /// Kill matching processes until none are left. False when they are still there after
    /// ~1 s (something keeps forking): the caller must not treat the slot as clean.
    static func sweep(_ matches: (pid_t) -> Bool) -> Bool {
        let me = getpid()
        for _ in 0..<200 {
            let stray = listPids(type: UInt32(PROC_UID_ONLY), arg: getuid()).filter { $0 != me && matches($0) }
            if stray.isEmpty { return true }
            killAll(Set(stray))
            usleep(5_000)
        }
        return listPids(type: UInt32(PROC_UID_ONLY), arg: getuid()).allSatisfy { $0 == me || !matches($0) }
    }

    static func containerPath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        return sandbox_container_path_for_pid(pid, &buf, buf.count) == 0 ? String(cString: buf) : nil
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func listPids(type: UInt32, arg: UInt32) -> [pid_t] {
        let n = proc_listpids(type, arg, nil, 0)
        guard n > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(n) / MemoryLayout<pid_t>.size + 64)
        let got = buf.withUnsafeMutableBytes { proc_listpids(type, arg, $0.baseAddress, Int32($0.count)) }
        return Array(buf.prefix(max(0, Int(got)) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    static func childPids(_ pid: pid_t) -> [pid_t] {
        // The call fills only the buffer it is given: grow until the answer fits, so a scanner
        // with many children can't push some of them out of the accounting.
        var cap = 256
        while true {
            var buf = [pid_t](repeating: 0, count: cap)
            let got = Int(buf.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) })
            if got < cap || cap >= 1 << 16 { return Array(buf.prefix(max(0, min(got, cap)))).filter { $0 > 0 } }
            cap *= 4
        }
    }

    static func pidPath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
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

/// libsystem_sandbox: the container directory of a sandboxed process (0 on success).
@_silgen_name("sandbox_container_path_for_pid")
func sandbox_container_path_for_pid(_ pid: pid_t, _ buffer: UnsafeMutablePointer<CChar>, _ size: Int) -> Int32

/// Drains a pipe on its own thread, keeping at most `cap` bytes (the rest is read and dropped so
/// the child never blocks on a full pipe).
final class CappedReader: @unchecked Sendable {
    private let fd: Int32
    private let cap: Int
    private var data = Data()
    private var truncated = false
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopped = false

    init(fd: Int32, cap: Int) {
        self.fd = fd
        self.cap = cap
    }

    func start() {
        Thread.detachNewThread { [self] in
            var buf = [UInt8](repeating: 0, count: 64 << 10)
            while true {
                // Poll, so a writer that never closes can't park this thread in read() forever.
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 50)
                if lock.withLock({ stopped }) { break }
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                if ready < 0 { break }
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

    /// Wait for EOF until `deadline`; `complete` is false when the writer was still open then.
    func finish(by deadline: Date) -> (data: Data, truncated: Bool, complete: Bool) {
        let complete = done.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success
        if !complete {
            lock.withLock { stopped = true }
            done.wait()
        }
        return (data, truncated, complete)
    }
}
