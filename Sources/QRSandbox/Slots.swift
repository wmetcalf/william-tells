import Foundation

// App Sandbox slots for `wtqrk-scan`.
//
// macOS applies App Sandbox at exec time, from the executable's code signature: a binary signed
// with `com.apple.security.app-sandbox` (and carrying an embedded Info.plist, which wtqrk-scan
// links in) starts sandboxed no matter who launches it. No `sandbox-exec`, no launchd, no XPC:
// launchd throttles XPC services that exit within 10 s of launch, so an XPC service cannot give
// every image a fresh process; a directly spawned sandboxed tool can.
//
// The sandbox's container (~/Library/Containers/<signing identifier>/Data) is keyed by the
// SIGNING IDENTIFIER. Concurrent scans must not share one, so each slot is an APFS clone of the
// scanner re-signed (ad hoc -- free, no Apple Developer account) under its own identifier.
// Signing happens on this Mac at prepare time, so the slot always matches the installed binary.

public struct SandboxSlot: Sendable, Equatable {
    public let index: Int
    public let identifier: String
    public let executable: URL

    /// The container's data directory: the sandboxed process's HOME, TMPDIR and caches.
    public var containerData: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(identifier)/Data", isDirectory: true)
    }
}

public enum SandboxError: Error, CustomStringConvertible {
    case scannerMissing(String)
    case codesignFailed(String)
    case notSandboxed(String)

    public var description: String {
        switch self {
        case .scannerMissing(let s): return "scanner binary not found: \(s)"
        case .codesignFailed(let s): return "codesign failed: \(s)"
        case .notSandboxed(let s): return "slot is not App-Sandboxed: \(s)"
        }
    }
}

public enum SlotProvisioner {
    static let entitlements = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>com.apple.security.app-sandbox</key><true/>
    </dict></plist>
    """

    /// Default slot root: `~/Library/Application Support/wtqrk/slots`, or `$WTQRK_SLOT_ROOT`.
    public static func defaultRoot() -> URL {
        if let env = ProcessInfo.processInfo.environment["WTQRK_SLOT_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/wtqrk/slots", isDirectory: true)
    }

    /// Clone `scanner` into `root/slot-<i>/wtqrk-scan` for each index and ad-hoc sign it with the
    /// App Sandbox entitlement under `<prefix>.slot<i>`. Re-signs only when the source changed.
    public static func prepare(scanner: URL, root: URL, indices: [Int],
                               identifierPrefix: String = "io.github.wmetcalf.wtqrk-scan")
        throws -> [SandboxSlot]
    {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: scanner.path) else {
            throw SandboxError.scannerMissing(scanner.path)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let ent = root.appendingPathComponent("app-sandbox.entitlements")
        try Data(entitlements.utf8).write(to: ent, options: .atomic)
        let sourceStamp = try stamp(of: scanner)

        return try indices.map { i in
            let dir = root.appendingPathComponent("slot-\(i)", isDirectory: true)
            let exe = dir.appendingPathComponent("wtqrk-scan")
            let stampFile = dir.appendingPathComponent("source.stamp")
            let slot = SandboxSlot(index: i, identifier: "\(identifierPrefix).slot\(i)", executable: exe)
            if (try? String(contentsOf: stampFile, encoding: .utf8)) == sourceStamp,
               (try? verify(slot)) != nil {
                return slot
            }
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try cloneFile(from: scanner, to: exe)
            try codesign(["-f", "-s", "-", "-i", slot.identifier, "--entitlements", ent.path, exe.path])
            try verify(slot)
            try sourceStamp.write(to: stampFile, atomically: true, encoding: .utf8)
            return slot
        }
    }

    /// Fail unless the slot's signature carries its identifier and the App Sandbox entitlement.
    @discardableResult
    public static func verify(_ slot: SandboxSlot) throws -> SandboxSlot {
        let out = try codesign(["-dv", "--entitlements", "-", "--xml", slot.executable.path],
                               captureStderr: true)
        guard out.contains("Identifier=\(slot.identifier)\n") else {
            throw SandboxError.notSandboxed("\(slot.executable.path): identifier is not \(slot.identifier)")
        }
        guard out.contains("<key>com.apple.security.app-sandbox</key><true/>") else {
            throw SandboxError.notSandboxed("\(slot.executable.path) lacks com.apple.security.app-sandbox")
        }
        return slot
    }

    static func stamp(of url: URL) throws -> String {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (a[.size] as? Int) ?? -1
        let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(size)|\(mtime)\n"
    }

    static func cloneFile(from src: URL, to dst: URL) throws {
        // clonefile(2): copy-on-write on APFS; fall back to a copy elsewhere.
        if clonefile(src.path, dst.path, 0) != 0 {
            try FileManager.default.copyItem(at: src, to: dst)
        }
    }

    @discardableResult
    static func codesign(_ args: [String], captureStderr: Bool = false) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = captureStderr ? out : Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw SandboxError.codesignFailed("codesign \(args.joined(separator: " ")): \(text)")
        }
        return text
    }
}

/// Container hygiene. The host is NOT sandboxed, so it can empty and refill a slot's container.
public enum Container {
    public struct UncleanError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Remove everything inside `data` (not `data` itself: the container's own metadata lives
    /// beside it and is protected), and PROVE it is empty. The scanner owns these files, so a
    /// compromised one can lock them (chmod 000 dirs, `uchg` immutable flags) to leave state for
    /// the next image; those get unlocked and removed, and anything still there is an error --
    /// the caller retires the slot rather than reuse a dirty container. A missing `data` is
    /// clean (the sandbox creates it on first launch).
    public static func wipe(_ data: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: data.path) else { return }
        for e in try fm.contentsOfDirectory(atPath: data.path) {
            let path = data.appendingPathComponent(e).path
            if (try? fm.removeItem(atPath: path)) == nil {
                unlock(path)
                try? fm.removeItem(atPath: path)
            }
        }
        let left = try fm.contentsOfDirectory(atPath: data.path)
        guard left.isEmpty else {
            throw UncleanError(description: "could not empty \(data.path): \(left.prefix(5))")
        }
    }

    /// Clear user flags and restore owner permissions under `path`, never following symlinks.
    static func unlock(_ path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        _ = lchflags(path, 0)
        if (st.st_mode & S_IFMT) == S_IFDIR {
            _ = chmod(path, 0o700)
            for e in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                unlock(path + "/" + e)
            }
        } else if (st.st_mode & S_IFMT) != S_IFLNK {
            _ = chmod(path, 0o600)
        }
    }

    /// Clone `seed`'s contents into `data` (copy-on-write; symlinks copied as links, never
    /// followed). `seed` comes from a trusted self-test run, never from job input.
    public static func seed(_ data: URL, from seed: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: seed.path) else { return }
        try? fm.createDirectory(at: data, withIntermediateDirectories: true)
        for e in entries {
            let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW)
            _ = copyfile(seed.appendingPathComponent(e).path, data.appendingPathComponent(e).path,
                         nil, flags)
        }
    }

    /// Replace `dest` with a copy of `data`'s contents.
    public static func capture(_ data: URL, to dest: URL) {
        let fm = FileManager.default
        unlock(dest.path)
        try? fm.removeItem(at: dest)
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        seed(dest, from: data)
    }
}
