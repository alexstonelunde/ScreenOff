import Foundation

@MainActor
final class ControlledTransaction: DisplayTransactionRunning {
    var isRunning = false
    var requests: [DisplayTransactionRequest] = []
    var cancellations = 0
    var failsToStart = false
    private var completion: ((DisplayTransactionResult) -> Void)?
    func start(_ request: DisplayTransactionRequest, completion: @escaping (DisplayTransactionResult) -> Void) throws {
        precondition(!isRunning)
        if failsToStart { throw DisplayFailure.watchdog }
        requests.append(request)
        isRunning = true
        self.completion = completion
    }
    func cancel() {
        guard isRunning else { return }
        cancellations += 1
        // Reaping is deliberately separate: no new child may start until then.
    }
    func finish(_ result: DisplayTransactionResult = .completed) {
        precondition(isRunning)
        isRunning = false
        let callback = completion
        completion = nil
        callback?(result)
    }
}

private func state(on: Bool = true, lid: Bool = false, external: Bool = true,
                   present: Bool = true, active: Bool? = nil, id: UInt32 = 1) -> DisplaySnapshot {
    var displays: [DisplayInfo] = present ? [DisplayInfo(id: id, identity: "panel", builtIn: true,
        online: on, active: active ?? on, mirrored: false)] : []
    if external { displays.append(DisplayInfo(id: 2, identity: "desk", builtIn: false, online: true,
        active: true, mirrored: false)) }
    return DisplaySnapshot(displays: displays, lidClosed: lid)
}

@main @MainActor
enum SupervisorTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String,
                       file: StaticString = #file, line: UInt = #line) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(message)", file: file, line: line) }
    }
    static func testLateCompletion() {
        for result in [DisplayTransactionResult.deferred, .timedOut] {
            for transition in ["system", "screens", "lid", "console", "topology", "none"] {
                var now: TimeInterval = 0
                let worker = ControlledTransaction()
                let s = WatchdogSupervisor(snapshot: state(on: false), worker: worker,
                    clock: { now }, restored: {})
                s.requestRestore()
                s.tick()
                expect(worker.requests.count == 1, "initial recovery starts: \(transition)/\(result)")
                if transition == "system" { s.systemChanged(awake: false); s.systemChanged(awake: true) }
                if transition == "screens" { s.screensChanged(awake: false); s.screensChanged(awake: true) }
                if transition == "lid" { s.lidChanged(closed: true); s.lidChanged(closed: false) }
                if transition == "console" { s.sessionChanged(active: false); s.sessionChanged(active: true) }
                if transition == "topology" { s.observe(state(on: false, external: false)) }
                // Unchanged positive notifications are not new activity.
                s.systemChanged(awake: true)
                s.screensChanged(awake: true)
                s.sessionChanged(active: true)
                now = 1
                s.requestRestore()
                s.tick()
                expect(worker.isRunning && worker.requests.count == 1,
                       "new activity cannot overlap the unreaped worker: \(transition)/\(result)")
                worker.finish(result)
                if transition == "none" {
                    expect(s.retryBlocked, "late completion without new activity remains inhibited: \(result)")
                    for _ in 0..<20 {
                        now += 3
                        s.systemChanged(awake: true)
                        s.screensChanged(awake: true)
                        s.sessionChanged(active: true)
                        s.requestRestore()
                        s.tick()
                    }
                    expect(worker.requests.count == 1, "duplicates cannot renew inhibited completion: \(result)")
                    continue
                }
                expect(!s.retryBlocked, "older \(result) cannot revoke newer \(transition) retry permission")
                s.tick()
                expect(worker.requests.count == 2 && worker.requests.last?.on == true,
                       "new activity survives old completion and permits recovery: \(transition)/\(result)")
                s.tick()
                expect(worker.requests.count == 2, "replacement recovery remains serialised: \(transition)/\(result)")
                worker.finish(result)
                now += 10
                s.tick()
                expect(s.retryBlocked && worker.requests.count == 2,
                       "new attempt can inhibit itself until another transition: \(transition)/\(result)")
            }
        }
    }

    static func testCrossDimensionWake() {
        var now: TimeInterval = 0
        let worker = ControlledTransaction()
        let s = WatchdogSupervisor(snapshot: state(on: false), worker: worker,
            clock: { now }, restored: {})
        s.requestRestore()
        s.tick()
        worker.finish(.timedOut)
        s.systemChanged(awake: false) // No screensDidSleep notification arrived.
        s.sessionChanged(active: true) // Same-owner polling cannot wake a sleeping Mac.
        now = 3
        s.tick()
        expect(s.retryBlocked && worker.requests.count == 1,
               "same-owner observation cannot repair sleep flags or renew recovery")
        s.screensChanged(awake: true) // Its own flag is already true.
        expect(!s.retryBlocked, "screen wake reconciles stale system sleep and permits recovery")
        s.tick()
        expect(worker.requests.count == 1, "cross-dimension wake preserves the settling delay")
        now += 1
        s.tick()
        expect(worker.requests.count == 2, "screen wake alone resumes after missing screen-sleep notification")
        worker.finish(.timedOut)
        for _ in 0..<20 {
            now += 3
            s.screensChanged(awake: true)
            s.systemChanged(awake: true)
            s.tick()
        }
        expect(s.retryBlocked && worker.requests.count == 2,
               "fully unchanged wake notifications cannot renew retries")
    }

    static func main() {
        if CommandLine.arguments.contains("--late-completion") {
            testLateCompletion()
            print("PASS: \(checks) late-completion and serialisation checks")
            return
        }
        if CommandLine.arguments.contains("--cross-wake") {
            testCrossDimensionWake()
            print("PASS: \(checks) cross-dimension wake checks")
            return
        }
        testLateCompletion()
        testCrossDimensionWake()
        // Exact reported sequence, including closing the lid while enable is
        // stuck and unplugging before any recovery confirmation is available.
        for restoreFinishedBeforeClosing in [false, true] {
            var now: TimeInterval = 0
            var confirmations = 0
            let worker = ControlledTransaction()
            let supervisor = WatchdogSupervisor(snapshot: state(), worker: worker,
                clock: { now }, restored: { confirmations += 1 })
            supervisor.requestDisable()
            expect(worker.requests.count == 1 && !worker.requests[0].on, "supervised disable")
            worker.finish()
            supervisor.observe(state(on: false))
            supervisor.sessionChanged(active: false) // Console ownership lost, still open.
            supervisor.tick()
            expect(worker.requests.last?.on == true, "console loss starts restoration before lid closure")
            if restoreFinishedBeforeClosing {
                worker.finish()
                supervisor.observe(state())
            }
            supervisor.lidChanged(closed: true)
            if !restoreFinishedBeforeClosing {
                expect(worker.cancellations > 0 && worker.isRunning, "closed lid cancels stalled enable")
                supervisor.tick()
                expect(worker.requests.count == 2, "no replacement until old worker is reaped")
                worker.finish(.cancelled)
            }
            supervisor.screensChanged(awake: false)
            supervisor.systemChanged(awake: false)
            supervisor.externalRemoved()
            supervisor.observe(state(on: false, lid: true, external: false, present: false))
            for tick in 1...38_400 {
                now = 3 + Double(tick) * 0.75
                supervisor.tick()
            }
            expect(worker.requests.count == 2 && confirmations == 0,
                   "eight hours closed/headless has zero additional transactions and no false confirmation")
            // Opening must work without AppKit wake or unlock notifications.
            supervisor.lidChanged(closed: false)
            supervisor.observe(state(on: false, external: false, present: false))
            now += 1
            supervisor.tick()
            expect(worker.requests.count == 3 && worker.requests.last?.on == true,
                   "lid opening alone resumes enable after locked unplug")
            expect(worker.requests.last?.lastKnownBuiltIn?.id == 1,
                   "isolated recovery retains the verified ID when the panel disappears")
            worker.finish()
            supervisor.observe(state(external: false))
            expect(confirmations == 0, "first restored snapshot is insufficient")
            now += 0.75
            supervisor.observe(state(external: false))
            expect(confirmations == 1, "two fresh active observations complete rescue")
        }
        do {
            var now: TimeInterval = 0
            let worker = ControlledTransaction()
            let s = WatchdogSupervisor(snapshot: state(), worker: worker, clock: { now }, restored: {})
            s.requestDisable()
            s.sessionChanged(active: false)
            expect(worker.cancellations == 1, "console loss cancels a disable before its API returns")
            s.tick()
            expect(worker.requests.count == 1, "cancelled disable remains serialized until reaped")
            worker.finish(.cancelled)
            now = 3
            s.tick() // No new snapshot: initial online state is now stale.
            expect(worker.requests.count == 2 && worker.requests.last?.on == true,
                   "stale pre-disable online snapshot cannot suppress rollback")
        }
        do {
            var now: TimeInterval = 0
            let worker = ControlledTransaction()
            let s = WatchdogSupervisor(snapshot: state(on: false), worker: worker, clock: { now }, restored: {})
            s.requestRestore()
            s.tick()
            worker.finish(.timedOut)
            expect(s.retryBlocked && s.recoveryRequested, "timeout preserves obligation and blocks retry storms")
            let initial = worker.requests.count
            for tick in 1...14_400 {
                now = Double(tick) * 2
                s.requestRestore()
                s.externalRemoved()
                s.systemChanged(awake: true)
                s.screensChanged(awake: true)
                s.sessionChanged(active: true)
                s.observe(state(on: false))
                s.tick()
            }
            expect(worker.requests.count == initial, "duplicate callbacks cannot restart a timed-out API all night")
            s.systemChanged(awake: false)
            s.systemChanged(awake: true)
            now += 1
            s.tick()
            expect(worker.requests.count == initial + 1, "real sleep/wake permits one fresh recovery attempt")
        }
        for sleepKind in ["display", "system", "lid", "unknown-lid"] {
            var now: TimeInterval = 0
            let worker = ControlledTransaction()
            let s = WatchdogSupervisor(snapshot: state(on: false), worker: worker, clock: { now }, restored: {})
            s.requestRestore()
            if sleepKind == "display" { s.screensChanged(awake: false) }
            if sleepKind == "system" { s.systemChanged(awake: false) }
            if sleepKind == "lid" { s.lidChanged(closed: true) }
            if sleepKind == "unknown-lid" { s.lidChanged(closed: nil) }
            for tick in 0..<100 { now = Double(tick) * 2; s.tick() }
            expect(worker.requests.isEmpty, "no configuration while \(sleepKind)")
        }
        for unsafe in ["inactive-console", "sleeping", "lid", "missing", "external", "mirroring"] {
            let worker = ControlledTransaction()
            var snapshot = state(external: unsafe != "external", present: unsafe != "missing")
            if unsafe == "mirroring" {
                snapshot.displays[0] = DisplayInfo(id: 1, identity: "panel", builtIn: true,
                    online: true, active: true, mirrored: true)
            }
            let s = WatchdogSupervisor(snapshot: snapshot, worker: worker, restored: {})
            if unsafe == "inactive-console" { s.sessionChanged(active: false) }
            if unsafe == "sleeping" { s.screensChanged(awake: false) }
            if unsafe == "lid" { s.lidChanged(closed: true) }
            s.requestDisable()
            expect(worker.requests.isEmpty, "refuse disable with \(unsafe)")
        }
        do {
            var now: TimeInterval = 0
            let worker = ControlledTransaction()
            let s = WatchdogSupervisor(snapshot: state(on: false), worker: worker, clock: { now }, restored: {})
            s.requestRestore()
            s.tick()
            worker.finish(.deferred) // Worker saw display sleep before AppKit did.
            for _ in 0..<100 { now += 3; s.tick() }
            expect(worker.requests.count == 1, "worker sleep preflight cannot trigger a launch loop")
            s.sessionChanged(active: false)
            s.sessionChanged(active: true)
            now += 1
            s.observe(state(on: false, id: 99))
            s.tick()
            expect(worker.requests.count == 2 && worker.requests.last?.lastKnownBuiltIn?.id == 99,
                   "console return rearms recovery and updates a newly discovered panel ID")
        }
        do {
            var now: TimeInterval = 0
            let worker = ControlledTransaction()
            let s = WatchdogSupervisor(snapshot: state(on: false), worker: worker, clock: { now }, restored: {})
            s.requestRestore()
            s.tick()
            worker.finish(.failed)
            for _ in 0..<100 { s.requestRestore(); s.tick() }
            expect(worker.requests.count == 1, "API errors have a cooldown despite repeated IPC")
            now = 2
            s.tick()
            expect(worker.requests.count == 2, "nonblocking ordinary error retries after cooldown")
        }
        do {
            var now: TimeInterval = 0
            let worker = ControlledTransaction()
            worker.failsToStart = true
            let s = WatchdogSupervisor(snapshot: state(on: false), worker: worker, clock: { now }, restored: {})
            s.requestRestore()
            s.tick()
            expect(s.retryBlocked, "worker launch failure cannot become a rapid process spawn loop")
            worker.failsToStart = false
            s.lidChanged(closed: true)
            s.lidChanged(closed: false)
            now = 1
            s.tick()
            expect(worker.requests.count == 1 && worker.requests[0].on, "recovery survives a worker launch failure")
        }
        // A lock keeps ownership of the same console; a completed disable
        // survives display sleep and system sleep without any enable request.
        for kind in ["display", "system"] {
            var now: TimeInterval = 0
            let worker = ControlledTransaction()
            let s = WatchdogSupervisor(snapshot: state(), worker: worker, clock: { now }, restored: {})
            s.requestDisable()
            worker.finish()
            s.observe(state(on: false))
            s.sessionChanged(active: true) // Lock notification: ownership unchanged.
            if kind == "display" { s.screensChanged(awake: false) }
            else { s.systemChanged(awake: false) }
            for tick in 1...38_400 { now = Double(tick) * 0.75; s.tick() }
            expect(!s.recoveryRequested && worker.requests.count == 1,
                   "confirmed disable stays off through locked eight-hour \(kind) sleep")
            if kind == "display" { s.screensChanged(awake: true) }
            else { s.systemChanged(awake: true) }
            now += 1
            s.observe(state(on: false))
            s.tick()
            expect(worker.requests.count == 1, "wake without panel reactivation performs no transaction")
            s.observe(state()) // Simulate macOS reactivating the panel.
            s.tick()
            expect(worker.requests.count == 2 && worker.requests.last?.on == false && !s.recoveryRequested,
                   "macOS reactivation is reapplied using the same protected lease")
            for _ in 0..<10 { s.requestDisable(); s.tick() }
            expect(worker.requests.count == 2, "duplicate reapply requests never overlap a child")
            worker.finish()
            s.observe(state(on: false))
            s.tick()
            expect(worker.requests.count == 2, "confirmed reapply does not spawn a transaction loop")
            s.externalRemoved()
            s.observe(state(on: false, external: false))
            now += 1
            s.tick()
            expect(worker.requests.count == 3 && worker.requests.last?.on == true,
                   "external unplug still restores while the owner console is locked")
        }
        do {
            let worker = ControlledTransaction()
            let s = WatchdogSupervisor(snapshot: state(), worker: worker, restored: {})
            s.requestDisable()
            worker.finish()
            s.observe(state(on: false))
            s.observe(state())
            s.tick()
            worker.finish() // An API success that never actually disables the panel.
            s.observe(state())
            s.tick()
            expect(s.recoveryRequested && worker.requests.count == 2,
                   "unverified reapply fails toward recovery instead of endlessly disabling")
        }
        do {
            var now: TimeInterval = 0
            let worker = ControlledTransaction()
            let s = WatchdogSupervisor(snapshot: state(), worker: worker, clock: { now }, restored: {})
            s.requestDisable()
            s.systemChanged(awake: false)
            expect(worker.cancellations == 1 && s.recoveryRequested,
                   "sleep interrupts an unfinished disable with rollback responsibility")
            worker.finish(.cancelled)
            s.systemChanged(awake: true)
            now = 1
            s.tick()
            expect(worker.requests.count == 2 && worker.requests.last?.on == true,
                   "uncertain interrupted disable restores on wake")
        }
        do {
            var now: TimeInterval = 0
            let worker = ControlledTransaction()
            let s = WatchdogSupervisor(snapshot: state(), worker: worker, clock: { now }, restored: {})
            s.requestDisable()
            worker.finish()
            s.observe(state(on: false))
            s.screensChanged(awake: false)
            s.systemChanged(awake: false)
            s.lidChanged(closed: true)
            s.externalRemoved()
            s.observe(state(on: false, lid: true, external: false, present: false))
            for tick in 1...38_400 { now = Double(tick) * 0.75; s.tick() }
            expect(worker.requests.count == 1 && s.recoveryRequested,
                   "locked close-lid unplug waits without transactions throughout the night")
            s.lidChanged(closed: false)
            s.observe(state(on: false, external: false, present: false))
            now += 1
            s.tick()
            expect(worker.requests.count == 2 && worker.requests.last?.on == true && worker.requests.last?.lastKnownBuiltIn?.id == 1,
                   "lid opening alone restores the remembered panel after locked unplug")
        }
        print("PASS: \(checks) production supervisor checks, including locked clamshell unplug and eight-hour simulations")
    }
}
