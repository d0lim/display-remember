import Darwin
import Foundation

public struct EngineResult: Equatable, Sendable {
    public let stdout: String
    public let stderr: String
    public let status: Int32

    public init(stdout: String, stderr: String, status: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
    }
}

public enum DisplayPlacerEngineError: LocalizedError {
    case unavailable(String)
    case invalidRequest(String)
    case timedOut(TimeInterval)
    case output(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail): return "Bundled displayplacer is unavailable: \(detail)"
        case .invalidRequest(let detail): return detail
        case .timedOut(let seconds): return "displayplacer exceeded its \(seconds)-second timeout and was stopped."
        case .output(let detail): return "Could not read displayplacer output: \(detail)"
        }
    }
}

/// Runs the complete bundled upstream engine without a shell or PATH lookup.
/// Every invocation has independent process and capture state.
public final class DisplayPlacerEngine: Sendable {
    public let executableURL: URL

    public init(executableURL: URL? = nil) throws {
        if let explicit = executableURL {
            self.executableURL = try Self.requireExecutable(explicit)
            return
        }
        if let explicit = ProcessInfo.processInfo.environment["DISPLAY_REMEMBER_ENGINE"], !explicit.isEmpty {
            self.executableURL = try Self.requireExecutable(URL(fileURLWithPath: explicit))
            return
        }

        let bundle = Bundle.main
        self.executableURL = try Self.resolveExecutable(
            bundleURL: bundle.bundleURL,
            applicationExecutableURL: bundle.executableURL,
            currentDirectoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        )
    }

    static func resolveExecutable(
        bundleURL: URL,
        applicationExecutableURL: URL?,
        currentDirectoryURL: URL
    ) throws -> URL {
        let bundle = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let executable = applicationExecutableURL?.standardizedFileURL.resolvingSymlinksInPath()
        var applicationBundle: URL?
        if let executable {
            let macOSDirectory = executable.deletingLastPathComponent()
            let contentsDirectory = macOSDirectory.deletingLastPathComponent()
            let enclosingBundle = contentsDirectory.deletingLastPathComponent()
            // Homebrew links the CLI outside the app; Bundle.main can describe
            // that link's directory instead of the actual application bundle.
            if macOSDirectory.lastPathComponent == "MacOS",
               contentsDirectory.lastPathComponent == "Contents",
               enclosingBundle.pathExtension == "app" {
                applicationBundle = enclosingBundle
            }
        }
        if applicationBundle == nil, bundle.pathExtension == "app" {
            applicationBundle = bundle
        }
        // A packaged app with a missing helper must not silently use another copy.
        if let applicationBundle {
            let bundled = applicationBundle.appendingPathComponent("Contents/Helpers/displayplacer")
            return try Self.requireExecutable(bundled)
        }

        var candidates = [bundle.appendingPathComponent("Contents/Helpers/displayplacer")]
        if let executable {
            let directory = executable.deletingLastPathComponent()
            candidates.append(directory.appendingPathComponent("displayplacer"))
            var ancestor = directory
            for _ in 0..<6 {
                if ancestor.lastPathComponent == ".build" {
                    candidates.append(ancestor.appendingPathComponent("helpers/displayplacer"))
                    break
                }
                ancestor.deleteLastPathComponent()
            }
        }
        let project = currentDirectoryURL
        if FileManager.default.fileExists(atPath: project.appendingPathComponent("Package.swift").path) {
            candidates.append(project.appendingPathComponent(".build/helpers/displayplacer"))
        }
        for candidate in candidates {
            if let found = try? Self.requireExecutable(candidate) {
                return found
            }
        }
        throw DisplayPlacerEngineError.unavailable("run scripts/build-engine.sh, or provide an explicit helper URL; system/Homebrew copies are not searched")
    }

    private static func requireExecutable(_ url: URL) throws -> URL {
        guard url.isFileURL else {
            throw DisplayPlacerEngineError.unavailable("the helper must be a local executable file")
        }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isExecutableFile(atPath: resolved.path) else {
            throw DisplayPlacerEngineError.unavailable(resolved.path)
        }
        return resolved
    }

    public func run(arguments: [String], timeout: TimeInterval = 30) throws -> EngineResult {
        guard timeout.isFinite, timeout > 0 else {
            throw DisplayPlacerEngineError.invalidRequest("The engine timeout must be finite and greater than zero.")
        }
        guard !arguments.contains(where: { $0.contains("\0") }) else {
            throw DisplayPlacerEngineError.invalidRequest("Engine arguments cannot contain NUL bytes.")
        }
        let output = try EnginePipe()
        let errors = try EnginePipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output.pipe
        process.standardError = errors.pipe
        try process.run()
        output.closeWriter()
        errors.closeWriter()

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var timeoutReached = false
        var killDeadline: TimeInterval?
        var outputDeadline: TimeInterval?
        var killed = false
        defer {
            if process.isRunning {
                // Also clean up a child if a pipe read fails before normal completion.
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }

        while true {
            try output.drain()
            try errors.drain()
            let now = ProcessInfo.processInfo.systemUptime
            if process.isRunning {
                if !timeoutReached, now >= deadline {
                    timeoutReached = true
                    process.terminate()
                    killDeadline = now + 0.25
                }
                if let killDeadline, now >= killDeadline, !killed {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    killed = true
                }
                if let killDeadline, killed, now >= killDeadline + 1 {
                    throw DisplayPlacerEngineError.timedOut(timeout)
                }
            } else {
                if output.isClosed && errors.isClosed { break }
                if outputDeadline == nil { outputDeadline = now + 0.5 }
                if now >= outputDeadline! {
                    // A grandchild can inherit a pipe after the helper exits. Do not
                    // block indefinitely waiting for that unrelated process's EOF.
                    if !timeoutReached {
                        throw DisplayPlacerEngineError.output("a descendant kept an output pipe open after the helper exited")
                    }
                    break
                }
            }
            var descriptors = [output.pollDescriptor, errors.pollDescriptor]
            let ready = descriptors.withUnsafeMutableBufferPointer {
                Darwin.poll($0.baseAddress, nfds_t($0.count), 20)
            }
            if ready < 0 && errno != EINTR {
                throw DisplayPlacerEngineError.output(String(cString: strerror(errno)))
            }
        }
        process.waitUntilExit()
        if timeoutReached { throw DisplayPlacerEngineError.timedOut(timeout) }
        return EngineResult(
            stdout: String(decoding: output.data, as: UTF8.self),
            stderr: String(decoding: errors.data, as: UTF8.self),
            status: process.terminationStatus
        )
    }
}

/// Nonblocking reads let one thread drain both streams, even when either exceeds
/// a pipe's capacity, while still enforcing the process deadline.
private final class EnginePipe {
    let pipe = Pipe()
    private(set) var data = Data()
    private(set) var isClosed = false
    private let descriptor: Int32

    init() throws {
        descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw DisplayPlacerEngineError.output(String(cString: strerror(errno)))
        }
    }

    deinit {
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }

    var pollDescriptor: pollfd {
        pollfd(fd: isClosed ? -1 : descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
    }

    func closeWriter() {
        try? pipe.fileHandleForWriting.close()
    }

    func drain() throws {
        guard !isClosed else { return }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        // Bound a turn so a continuously writing helper cannot starve the other
        // stream or prevent the timeout from being checked.
        for _ in 0..<16 {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: bytes.prefix(count))
            } else if count == 0 {
                isClosed = true
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else if errno != EINTR {
                throw DisplayPlacerEngineError.output(String(cString: strerror(errno)))
            }
        }
    }
}
