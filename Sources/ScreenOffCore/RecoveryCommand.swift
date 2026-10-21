import Foundation
import Darwin

/// Only these two capabilities are used by the CLI: observe, or accept an
/// enable-only recovery obligation. Neither accepts transaction commands.
enum RecoveryHelperRequest {
    case snapshot
    case restore(seed: DisplayInfo?)

    static func parse(_ arguments: [String], parent: Int32) -> RecoveryHelperRequest? {
        guard arguments.count >= 2, let claimedParent = Int32(arguments[1]),
              claimedParent > 1, claimedParent == parent else { return nil }
        if arguments[0] == "--snapshot" { return arguments.count == 2 ? .snapshot : nil }
        guard arguments[0] == "--restore-watch" else { return nil }
        if arguments.count == 2 { return .restore(seed: nil) }
        guard arguments.count == 4, arguments[2] == "--seed",
              let data = Data(base64Encoded: arguments[3]), data.count < 16_384,
              let seed = try? JSONDecoder().decode(DisplayInfo.self, from: data),
              seed.builtIn, seed.id != 0 else { return nil }
        return .restore(seed: seed)
    }
}

enum RecoveryProcessResult {
    case exited(Data), accepted(Process), timedOut, failed
}

/// Collects only bounded, nonblocking output. A hung read or a child that has
/// closed stdout but not exited cannot hold this caller beyond its deadline.
/// The restore supervisor is durable; only disposable readers may be killed.
enum RecoveryProcess {
    static let acceptance = Data("ACCEPTED\n".utf8)
    private static let maximumOutput = 1_048_576

    static func run(executable: URL, arguments: [String], deadline: TimeInterval,
                    acceptingRestore: Bool = false, environment: [String: String]? = nil) -> RecoveryProcessResult {
        func remaining() -> TimeInterval { deadline - ProcessInfo.processInfo.systemUptime }
        guard remaining() > 0 else { return .timedOut }
        let child = Process()
        let replies = Pipe()
        let output = replies.fileHandleForReading
        let descriptor = output.fileDescriptor
        // This descriptor must not be inherited by another helper, or keep an
        // obsolete reader alive. Nonblocking reads include partial/malformed output.
        guard fcntl(descriptor, F_SETFD, fcntl(descriptor, F_GETFD) | FD_CLOEXEC) != -1,
              fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1 else {
            try? output.close(); try? replies.fileHandleForWriting.close()
            return .failed
        }
        child.executableURL = executable
        child.arguments = arguments
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = replies
        child.standardError = FileHandle.nullDevice
        // Foundation reaps asynchronously; no waitUntilExit is permitted here.
        child.terminationHandler = { _ in }
        defer {
            if !acceptingRestore, child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
            try? output.close()
            try? replies.fileHandleForWriting.close()
        }
        guard remaining() > 0 else { return .timedOut }
        do { try child.run() } catch { return .failed }
        try? replies.fileHandleForWriting.close()
        var data = Data()
        var eof = false
        var bytes = [UInt8](repeating: 0, count: 4096)
        while remaining() > 0 {
            if !eof {
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count > 0 {
                    data.append(contentsOf: bytes.prefix(count))
                    if acceptingRestore {
                        // The helper may already have appended its normal READY
                        // reply. Acceptance alone confirms the restore obligation.
                        if data.starts(with: acceptance) { return .accepted(child) }
                        if !acceptance.starts(with: data) { return .failed }
                    } else if data.count > maximumOutput { return .failed }
                    continue
                }
                if count == 0 { eof = true }
                else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { return .failed }
            }
            if eof && !child.isRunning {
                guard !acceptingRestore, child.terminationReason == .exit, child.terminationStatus == 0 else { return .failed }
                return .exited(data)
            }
            let milliseconds = Int32(max(0, min(20, remaining() * 1000)))
            guard milliseconds > 0 else { continue }
            if eof { _ = poll(nil, 0, milliseconds) }
            else {
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pollDescriptor, 1, milliseconds)
                if ready < 0 && errno != EINTR { return .failed }
            }
        }
        return .timedOut
    }
}

enum RecoveryCommandResult: Equatable {
    case restored, timedOut, observationFailed, helperUnavailable, supervisorFailed

    var message: String {
        switch self {
        case .restored: return "Built-in display restored."
        case .timedOut:
            return "Recovery was not confirmed within 12 seconds. Any recovery supervisor already started will continue. Close and reopen the lid, or reconnect the external display."
        case .observationFailed:
            return "Display observations failed; recovery could not be confirmed. Any recovery supervisor already started will continue."
        case .helperUnavailable:
            return "The recovery helper is unavailable or did not acknowledge startup. Recovery could not be confirmed."
        case .supervisorFailed:
            return "The recovery supervisor exited unsuccessfully before restoration could be confirmed. Close and reopen the lid, or reconnect the external display."
        }
    }
}

/// The CLI never constructs DisplayHardware. The first probe, restore handoff,
/// later probes and polling delays share this single monotonic deadline.
struct RecoveryCommand {
    let executable: URL
    var timeout: TimeInterval = 12
    var queryTimeout: TimeInterval = 2
    var interval: TimeInterval = 0.2
    var environment: [String: String]? = nil

    func run(notify: () -> Void, ownerIsRunning: () -> Bool) -> RecoveryCommandResult {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        func remaining() -> TimeInterval { deadline - ProcessInfo.processInfo.systemUptime }
        notify()
        guard remaining() > 0 else { return .timedOut }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return .helperUnavailable }
        var supervisor: Process?
        var seed: DisplayInfo?
        var observed = false
        var readerFailed = false
        while remaining() > 0 {
            // Acceptance is a handoff, not a promise that the supervisor can
            // never fail. Keep its handle until CLI exit and report lost rescue.
            if let supervisor, !supervisor.isRunning,
               supervisor.terminationReason != .exit || supervisor.terminationStatus != 0 {
                return .supervisorFailed
            }
            let queryDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + max(0, queryTimeout))
            let result = RecoveryProcess.run(executable: executable, arguments: ["--snapshot", String(getpid())],
                                             deadline: queryDeadline, environment: environment)
            switch result {
            case .exited(let data):
                if let snapshot = try? JSONDecoder().decode(DisplaySnapshot.self, from: data),
                   snapshot.displays.count <= 4096,
                   snapshot.displays.allSatisfy({ $0.id != 0 }),
                   Set(snapshot.displays.map(\.id)).count == snapshot.displays.count,
                   snapshot.displays.filter(\.builtIn).count <= 1 {
                    observed = true
                    if let panel = snapshot.builtIn { seed = panel }
                    if snapshot.builtInIsRestored { return .restored }
                } else { readerFailed = true }
            case .failed: readerFailed = true
            case .timedOut, .accepted: break
            }
            guard remaining() > 0 else { break }
            if supervisor == nil && !ownerIsRunning() {
                guard remaining() > 0 else { break }
                var arguments = ["--restore-watch", String(getpid())]
                if let seed, let data = try? JSONEncoder().encode(seed) {
                    arguments += ["--seed", data.base64EncodedString()]
                }
                // An early acknowledgement is independent of WindowServer
                // readiness. Closing the pipe never cancels accepted restoration.
                let handoff = RecoveryProcess.run(executable: executable, arguments: arguments,
                    deadline: deadline, acceptingRestore: true, environment: environment)
                guard case .accepted(let accepted) = handoff else { return .helperUnavailable }
                supervisor = accepted
            }
            let pause = min(max(0, interval), remaining())
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
        }
        return observed || !readerFailed ? .timedOut : .observationFailed
    }
}
