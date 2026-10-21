import Foundation
import Darwin

@main enum RecoveryCommandTests {
    static var checks = 0
    static var failures = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { failures += 1; fputs("FAIL: \(message)\n", stderr) }
    }
    final class Scenario {
        let root: URL
        let mode: String
        init(_ mode: String) throws {
            self.mode = mode
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        var environment: [String: String] {
            ["RECOVERY_FIXTURE_DIRECTORY": root.path, "RECOVERY_FIXTURE_MODE": mode]
        }
        func value(_ name: String) -> String? { try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
        var queryPIDs: [Int32] {
            ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
                .filter { $0.hasPrefix("query.") && $0.hasSuffix(".pid") }.compactMap { value($0).flatMap(Int32.init) }
        }
        var supervisorPID: Int32? { value("supervisor.pid").flatMap(Int32.init) }
        func readersExited() -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while queryPIDs.contains(where: { kill($0, 0) == 0 }) && ProcessInfo.processInfo.systemUptime < deadline {
                usleep(5_000)
            }
            return queryPIDs.allSatisfy { kill($0, 0) != 0 }
        }
        deinit {
            for pid in queryPIDs + [supervisorPID].compactMap({ $0 }) { _ = kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: root)
        }
    }
    static func main() throws {
        signal(SIGPIPE, SIG_IGN)
        // This test-only entrypoint is a real CLI parent which exits after its
        // budget. Its helpers are the inert fixture, never the bundled watchdog.
        if CommandLine.arguments[1] == "--fixture-parent" {
            let executable = URL(fileURLWithPath: CommandLine.arguments[2])
            let result = RecoveryCommand(executable: executable, timeout: 0.3, queryTimeout: 0.08,
                interval: 0.01, environment: ProcessInfo.processInfo.environment)
                .run(notify: {}, ownerIsRunning: { false })
            exit(result == .timedOut ? 0 : 1)
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        func command(_ scenario: Scenario, timeout: TimeInterval = 0.35,
                     queryTimeout: TimeInterval = 0.12) -> RecoveryCommand {
            RecoveryCommand(executable: executable, timeout: timeout, queryTimeout: queryTimeout,
                            interval: 0.01, environment: scenario.environment)
        }
        for mode in ["initial-hang", "later-hang", "shared-budget"] {
            let scenario = try Scenario(mode)
            let start = ProcessInfo.processInfo.systemUptime
            var notifications = 0
            let result = command(scenario).run(notify: { notifications += 1 }, ownerIsRunning: { false })
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            expect(result == .timedOut, "\(mode): reports timeout")
            expect(elapsed < 0.6, "\(mode): total deadline includes every read and startup (\(elapsed)s)")
            expect(elapsed >= 0.30, "\(mode): uses one complete observation budget")
            expect(notifications == 1, "\(mode): sends same-user notification once")
            expect(scenario.supervisorPID != nil, "\(mode): restoration starts despite stalled observation")
            expect(scenario.supervisorPID.map { kill($0, 0) == 0 } == true,
                   "\(mode): independent supervisor survives command timeout")
            expect(scenario.readersExited(), "\(mode): disposable readers are killed and reaped")
        }
        do {
            let scenario = try Scenario("initial-hang")
            let parent = Process()
            parent.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            parent.arguments = ["--fixture-parent", executable.path]
            parent.environment = scenario.environment
            parent.standardOutput = FileHandle.nullDevice
            parent.standardError = FileHandle.nullDevice
            try parent.run()
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while parent.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(5_000) }
            expect(!parent.isRunning, "fixture CLI parent exits within its own budget")
            if parent.isRunning { _ = kill(parent.processIdentifier, SIGKILL) }
            else { expect(parent.terminationStatus == 0, "fixture CLI parent timed out as intended") }
            expect(scenario.supervisorPID.map { kill($0, 0) == 0 } == true,
                   "acknowledged supervisor survives actual CLI parent process exit")
            expect(scenario.readersExited(), "CLI process exit leaves no disposable readers")
        }
        for mode in ["restored", "restores-later", "no-built-in"] {
            let scenario = try Scenario(mode)
            let result = command(scenario, timeout: 1).run(notify: {}, ownerIsRunning: { false })
            expect(result == .restored, "\(mode): successful observation confirms restoration")
            expect(scenario.readersExited(), "\(mode): successful readers are reaped")
            if mode == "restored" {
                expect(scenario.supervisorPID == nil, "already-restored panel needs no supervisor")
            } else {
                expect(scenario.supervisorPID.map { kill($0, 0) == 0 } == true, "successful command preserves durable helper")
                let data = try? Data(contentsOf: scenario.root.appendingPathComponent("seed.json"))
                let seed = data.flatMap { try? JSONDecoder().decode(DisplayInfo.self, from: $0) }
                expect(mode == "no-built-in" ? seed == nil : seed?.id == 42,
                       "seed is retained only from a positively identified built-in panel")
            }
        }
        do {
            let scenario = try Scenario("later-hang")
            let result = command(scenario).run(notify: {}, ownerIsRunning: { true })
            expect(result == .timedOut, "existing UI owner still gets bounded observation")
            expect(scenario.supervisorPID == nil, "running UI owner prevents competing recovery supervisor")
            expect(scenario.readersExited(), "owner path reader is cleaned up")
        }
        for mode in ["malformed", "failed", "oversized", "zero-id"] {
            let scenario = try Scenario(mode)
            let result = command(scenario).run(notify: {}, ownerIsRunning: { true })
            expect(result == .observationFailed, "\(mode): invalid reader result cannot claim success")
            expect(scenario.readersExited(), "\(mode): rejected reader is killed/reaped without waiting on stdout")
        }
        for mode in ["partial", "closed-output", "snapshot-then-hang"] {
            let scenario = try Scenario(mode)
            let start = ProcessInfo.processInfo.systemUptime
            let result = command(scenario).run(notify: {}, ownerIsRunning: { true })
            expect(result == .timedOut, "\(mode): incomplete pipe/exit cannot claim success")
            expect(ProcessInfo.processInfo.systemUptime - start < 0.6, "\(mode): output and process exit both bounded")
            expect(scenario.readersExited(), "\(mode): reader is cleaned up")
        }
        do {
            let scenario = try Scenario("supervisor-completes")
            let result = command(scenario, timeout: 1).run(notify: {}, ownerIsRunning: { false })
            expect(result == .restored, "normal supervisor exit still allows independent restoration verification")
            expect(scenario.value("supervisors") == "1", "completed supervisor is not restarted while verifying")
            expect(scenario.readersExited(), "completed recovery leaves no observation workers")
        }
        do {
            let scenario = try Scenario("fragmented-ack")
            let result = command(scenario).run(notify: {}, ownerIsRunning: { false })
            expect(result == .timedOut, "partial acknowledgement is collected without blocking")
            expect(scenario.value("supervisors") == "1", "fragmented acknowledgement accepts exactly one supervisor")
            expect(scenario.supervisorPID.map { kill($0, 0) == 0 } == true, "acknowledged fragmented handoff remains alive")
        }
        do {
            let scenario = try Scenario("accepted-then-failed")
            let start = ProcessInfo.processInfo.systemUptime
            let result = command(scenario, timeout: 1).run(notify: {}, ownerIsRunning: { false })
            expect(result == .supervisorFailed,
                   "accepted supervisor failure is reported rather than silently waiting to time out")
            expect(ProcessInfo.processInfo.systemUptime - start < 0.5, "failed supervision is detected promptly")
            expect(scenario.readersExited(), "failed supervision leaves no observation workers")
        }
        for mode in ["accept-hang", "invalid-ack", "early-exit"] {
            let scenario = try Scenario(mode)
            let start = ProcessInfo.processInfo.systemUptime
            let result = command(scenario).run(notify: {}, ownerIsRunning: { false })
            expect(result == .helperUnavailable, "\(mode): unacknowledged handoff is reported")
            expect(ProcessInfo.processInfo.systemUptime - start < 0.6, "\(mode): handoff cannot overrun command deadline")
            expect(scenario.value("queries") == "1", "\(mode): no new work after failed handoff/deadline")
            if mode != "early-exit" {
                expect(scenario.supervisorPID.map { kill($0, 0) == 0 } == true,
                       "\(mode): even unconfirmed rescue process is never killed by CLI")
            }
        }
        do {
            let scenario = try Scenario("restored")
            var ownersChecked = 0
            let result = command(scenario, timeout: 0).run(notify: {}, ownerIsRunning: { ownersChecked += 1; return false })
            expect(result == .timedOut, "expired deadline returns timeout")
            expect(scenario.queryPIDs.isEmpty && scenario.supervisorPID == nil && ownersChecked == 0,
                   "expired deadline starts no query, owner lookup or supervisor")
        }
        do {
            let scenario = try Scenario("initial-hang")
            var ownersChecked = 0
            let result = command(scenario, timeout: 0.12, queryTimeout: 1).run(notify: {}, ownerIsRunning: {
                ownersChecked += 1; return false
            })
            expect(result == .timedOut, "initial query cannot exceed the remaining total budget")
            expect(scenario.value("queries") == "1" && scenario.supervisorPID == nil && ownersChecked == 0,
                   "exhausting the deadline in a query starts no further work")
            expect(scenario.readersExited(), "deadline exhaustion cleans up the current reader")
        }
        do {
            let scenario = try Scenario("later-hang")
            let result = command(scenario, timeout: 0.1).run(notify: {}, ownerIsRunning: {
                usleep(150_000); return false
            })
            expect(result == .timedOut && scenario.supervisorPID == nil,
                   "a deadline exhausted during the owner check cannot launch a new supervisor")
            expect(scenario.value("queries") == "1", "expired owner check cannot launch another query")
        }
        do {
            let scenario = try Scenario("disappearing-panel")
            var checks = 0
            let result = command(scenario, timeout: 1).run(notify: {}, ownerIsRunning: {
                checks += 1; return checks == 1
            })
            let data = try? Data(contentsOf: scenario.root.appendingPathComponent("seed.json"))
            let seed = data.flatMap { try? JSONDecoder().decode(DisplayInfo.self, from: $0) }
            expect(result == .restored && checks == 2, "observe existing owner before taking over its absence")
            expect(seed?.id == 42, "later missing panel preserves the earlier verified seed")
            expect(scenario.readersExited(), "takeover observations are reaped")
        }
        do {
            let missing = RecoveryCommand(executable: URL(fileURLWithPath: "/missing/ScreenOffWatchdog"))
            expect(missing.run(notify: {}, ownerIsRunning: { false }) == .helperUnavailable,
                   "missing helper returns a useful failure")
        }
        helperValidation()
        // Protect the real entrypoint: fixture tests must not conceal a direct parent query.
        if CommandLine.arguments.count > 2 {
            let app = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
            let branch = app.components(separatedBy: "if arguments.contains(\"--recover\") {")[1]
                .components(separatedBy: "        let app = NSApplication.shared")[0]
            expect(!branch.contains(".snapshot(") && !branch.contains("DisplayHardware("),
                   "--recover parent contains no WindowServer snapshot or hardware construction")
            expect(branch.contains("RecoveryCommand("), "--recover uses tested command orchestration")
        }
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) bounded recovery subprocess, handoff, validation and integration checks (no display changes)")
        exit(failures == 0 ? 0 : 1)
    }
    static func helperValidation() {
        let parent = getpid()
        expect(RecoveryHelperRequest.parse(["--snapshot", String(parent)], parent: parent) != nil, "snapshot accepts direct parent")
        expect(RecoveryHelperRequest.parse(["--snapshot", "1"], parent: 1) == nil, "init cannot claim worker ownership")
        expect(RecoveryHelperRequest.parse(["--snapshot", String(parent + 1)], parent: parent) == nil, "wrong parent rejected")
        expect(RecoveryHelperRequest.parse(["--snapshot", String(parent), "--seed", "unused"], parent: parent) == nil,
               "read-only mode rejects extra arguments")
        expect(RecoveryHelperRequest.parse(["--restore-watch", String(parent)], parent: parent) != nil, "restore-only mode accepted")
        expect(RecoveryHelperRequest.parse(["--restore-watch", String(parent), "--disable"], parent: parent) == nil,
               "restore-only mode cannot request disabling")
        expect(RecoveryHelperRequest.parse(["--restore-watch", String(parent), "--seed", "invalid"], parent: parent) == nil,
               "malformed seed rejected")
        for (builtIn, id, valid) in [(false, UInt32(42), false), (true, UInt32(0), false), (true, UInt32(42), true)] {
            let seed = DisplayInfo(id: id, identity: "fixture", builtIn: builtIn, online: false, active: false, mirrored: false)
            let encoded = try! JSONEncoder().encode(seed).base64EncodedString()
            expect((RecoveryHelperRequest.parse(["--restore-watch", String(parent), "--seed", encoded], parent: parent) != nil) == valid,
                   "seed requires positive built-in identity and nonzero ID")
        }
    }
}
