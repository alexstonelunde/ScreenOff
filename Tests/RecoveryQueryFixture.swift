import Foundation
import Darwin

// A native process fixture with no AppKit, CoreGraphics or display mutations.
@main enum RecoveryQueryFixture {
    static func main() throws {
        signal(SIGPIPE, SIG_IGN)
        guard let directory = ProcessInfo.processInfo.environment["RECOVERY_FIXTURE_DIRECTORY"],
              let mode = ProcessInfo.processInfo.environment["RECOVERY_FIXTURE_MODE"] else { exit(64) }
        let root = URL(fileURLWithPath: directory)
        func record(_ name: String, _ value: String) throws {
            try value.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func output(_ data: Data) { try? FileHandle.standardOutput.write(contentsOf: data) }
        func stall() -> Never { while true { pause() } }
        guard let request = RecoveryHelperRequest.parse(Array(CommandLine.arguments.dropFirst()),
                                                        parent: getppid()) else { exit(64) }
        switch request {
        case .restore(let seed):
            try record("supervisor.pid", String(getpid()))
            let starts = (try? String(contentsOf: root.appendingPathComponent("supervisors"), encoding: .utf8)).flatMap(Int.init) ?? 0
            try record("supervisors", String(starts + 1))
            if let seed { try JSONEncoder().encode(seed).write(to: root.appendingPathComponent("seed.json")) }
            if mode == "accept-hang" { stall() }
            if mode == "invalid-ack" { output(Data("INVALID\n".utf8)); stall() }
            if mode == "early-exit" { exit(1) }
            if mode == "fragmented-ack" {
                output(RecoveryProcess.acceptance.prefix(2))
                usleep(20_000)
                output(RecoveryProcess.acceptance.dropFirst(2))
            } else { output(RecoveryProcess.acceptance) }
            if mode == "accepted-then-failed" { exit(1) }
            if mode == "supervisor-completes" { exit(0) }
            // Outlives the parent command, even when the reply pipe closes.
            stall()
        case .snapshot:
            let countFile = root.appendingPathComponent("queries")
            let count = ((try? String(contentsOf: countFile, encoding: .utf8)).flatMap(Int.init) ?? 0) + 1
            try record("queries", String(count))
            try record("query.\(count).pid", String(getpid()))
            if mode == "initial-hang" && count == 1 { stall() }
            if mode == "later-hang" && count > 1 { stall() }
            if mode == "shared-budget" {
                if count == 1 { usleep(80_000) } else { stall() }
            }
            if mode == "malformed" { output(Data("not a snapshot".utf8)); exit(0) }
            if mode == "oversized" { output(Data(repeating: 65, count: 2_000_000)); stall() }
            if mode == "partial" { output(Data("{\"displays\":".utf8)); stall() }
            if mode == "closed-output" { try FileHandle.standardOutput.close(); stall() }
            let restored = mode == "restored" || mode == "failed" || mode == "snapshot-then-hang"
                || ((mode == "restores-later" || mode == "no-built-in" || mode == "supervisor-completes") && count > 1)
                || (mode == "disappearing-panel" && count > 2)
            var panel = DisplayInfo(id: 42, identity: "fixture-panel", builtIn: true,
                                    online: restored, active: restored, mirrored: false)
            if mode == "zero-id" {
                panel = DisplayInfo(id: 0, identity: "invalid", builtIn: true,
                                    online: true, active: true, mirrored: false)
            }
            let displays = (mode == "no-built-in" && count == 1) || (mode == "disappearing-panel" && count == 2)
                ? [DisplayInfo(id: 99, identity: "external", builtIn: false, online: true, active: true, mirrored: false)]
                : [panel]
            output(try JSONEncoder().encode(DisplaySnapshot(displays: displays, lidClosed: false)))
            if mode == "snapshot-then-hang" { stall() }
            exit(mode == "failed" ? 1 : 0)
        }
    }
}
