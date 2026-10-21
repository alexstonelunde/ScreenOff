import AppKit
import Combine

/// Exercise the production controller with an asynchronous recovery fixture with injected
/// hardware. These tests never issue a real display transaction.
final class FakeDisplayHardware: DisplayHardwareAccess {
    let supported = true
    let resolvedSymbol: String? = "fake"
    var state: DisplaySnapshot
    var readFails = false
    var enableFails = false
    var disableFails = false
    var activationDelayed = false
    var simulateHeadlessRecovery = false
    var recoveryTarget = BuiltInRecoveryTarget()
    var recoveredIDs: [UInt32] = []
    var afterDisable: (() -> Void)?
    var afterEnable: (() -> Void)?
    var calls: [(on: Bool, recovery: Bool)] = []
    var helperIsExecuting = false
    var mainEnableCalls = 0
    var helperEnableCalls = 0

    init(_ state: DisplaySnapshot = fixture()) { self.state = state }
    func snapshot() throws -> DisplaySnapshot {
        if readFails { throw DisplayFailure.verification }
        recoveryTarget.observe(state)
        return state
    }
    func setBuiltIn(on: Bool, recovery: Bool) throws {
        calls.append((on, recovery))
        if on {
            if helperIsExecuting { helperEnableCalls += 1 }
            else { mainEnableCalls += 1 }
        }
        if on { afterEnable?() }
        if simulateHeadlessRecovery, state.builtIn == nil,
           let id = recoveryTarget.resolve(in: state, on: on, recovery: recovery) {
            recoveredIDs.append(id)
            state.displays.removeAll { !$0.hasHardwareIdentity }
            state.displays.append(DisplayInfo(id: id, identity: "builtin", builtIn: true,
                                             online: true, active: true, mirrored: false))
            return
        }
        guard state.builtIn != nil else { throw DisplayFailure.noBuiltIn }
        if on && enableFails { throw DisplayFailure.verification }
        if !on && disableFails { throw DisplayFailure.verification }
        if !on || (!state.lidClosed && !activationDelayed) {
            state.displays = state.displays.map {
                guard $0.builtIn else { return $0 }
                return DisplayInfo(id: $0.id, identity: $0.identity, builtIn: true,
                                   online: on, active: on, mirrored: false)
            }
        }
        if !on { afterDisable?() }
    }
    func recover() -> Bool { fatalError("Controller must use the verified asynchronous path") }
}

@MainActor
final class FakeRecoveryGuard: RecoveryGuarding {
    var isRunning = false
    var canStart = true
    var starts: [Bool] = []
    var restoreRequests = 0
    var stops = 0
    var startFails = false
    var hardware: FakeDisplayHardware?
    var engine = SimulatedRecovery(retryDelay: 0)
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var automaticallyStep = true
    var retryDelay: TimeInterval = 0
    func start(restoring: Bool) throws {
        if startFails { throw DisplayFailure.watchdog }
        starts.append(restoring)
        isRunning = true
        engine = SimulatedRecovery(retryDelay: retryDelay)
    }
    func requestRestore() {
        restoreRequests += 1
        engine.request()
        if automaticallyStep { step() }
    }
    func step() {
        guard isRunning, let hardware else { return }
        hardware.helperIsExecuting = true
        defer { hardware.helperIsExecuting = false }
        _ = engine.step(using: hardware, now: clock())
    }
    func requestDisable() {
        guard isRunning, !engine.requested else { return }
        try? hardware?.setBuiltIn(on: false, recovery: false)
    }
    func remember(_ snapshot: DisplaySnapshot) {}
    func stop() { stops += 1; isRunning = false }
}

func fixture(on: Bool = true, present: Bool = true, lid: Bool = false,
             externals: [String] = ["desk"], active: Bool? = nil,
             builtInID: UInt32 = 1, externalActive: Bool = true) -> DisplaySnapshot {
    var displays = present ? [DisplayInfo(id: builtInID, identity: "builtin", builtIn: true,
                                         online: on, active: active ?? on, mirrored: false)] : []
    displays += externals.enumerated().map {
        DisplayInfo(id: UInt32($0.offset + 2), identity: $0.element, builtIn: false,
                    online: true, active: externalActive, mirrored: false)
    }
    return DisplaySnapshot(displays: displays, lidClosed: lid)
}

@main
@MainActor
enum RecoveryControllerTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String,
                       file: StaticString = #file, line: UInt = #line) {
        checks += 1
        guard value() else { fatalError("FAIL: \(message)", file: file, line: line) }
    }

    static func make(_ hardware: FakeDisplayHardware = FakeDisplayHardware(),
                     _ suppliedGuard: FakeRecoveryGuard? = nil,
                     recoveryRetryDelay: TimeInterval = 0,
                     recoveryClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                     sessionProbe: (() -> Bool?)? = nil)
        -> (DisplayController, FakeDisplayHardware, FakeRecoveryGuard) {
        let guardProcess = suppliedGuard ?? FakeRecoveryGuard()
        guardProcess.hardware = hardware
        guardProcess.engine = SimulatedRecovery(retryDelay: recoveryRetryDelay)
        guardProcess.retryDelay = recoveryRetryDelay
        guardProcess.clock = recoveryClock
        let controller = DisplayController(testing: true, hardware: hardware,
                                           guardProcess: guardProcess, automaticPreference: true,
                                           verificationDelay: 0, recoveryRetryDelay: recoveryRetryDelay,
                                           recoveryClock: recoveryClock, sessionProbe: sessionProbe)
        hardware.afterDisable = { expect(guardProcess.isRunning, "helper ready before disabling") }
        return (controller, hardware, guardProcess)
    }

    static func disabled() async -> (DisplayController, FakeDisplayHardware, FakeRecoveryGuard) {
        let (controller, hardware, guardProcess) = make()
        await controller.testEvaluate()
        expect(!hardware.state.builtInIsOn && controller.testRecoveryPending,
               "automatic off takes recovery responsibility")
        expect(guardProcess.starts == [false], "normal disable starts armed helper")
        return (controller, hardware, guardProcess)
    }

    static func main() async {
        if CommandLine.arguments.contains("--wake-regression") {
            await testMissingScreenWake()
            print("PASS: \(checks) missing-screen-wake controller checks")
            return
        }
        if CommandLine.arguments.contains("--emergency-wake-regression") {
            await testEmergencyWithStaleScreenSleep()
            print("PASS: \(checks) emergency wake controller checks")
            return
        }
        if CommandLine.arguments.contains("--resume-state-regression") {
            testResumeActivityReconciliation()
            print("PASS: \(checks) resume activity reconciliation checks")
            return
        }
        if CommandLine.arguments.contains("--night-probe") {
            await nightProbe()
            return
        }
        // The only UI switch expresses a persistent positive preference, not
        // the current panel state. Old automatic=true maps to switch OFF.
        do {
            let (controller, hardware, helper) = make(FakeDisplayHardware(fixture(externals: [])))
            expect(!controller.usesBuiltInWithExternal, "existing automatic preference maps to OFF")
            controller.setUsesBuiltInWithExternal(false)
            await controller.testEvaluate()
            expect(hardware.calls.isEmpty && hardware.state.builtInIsOn,
                   "OFF without an external saves intent and keeps the only display on")
            hardware.state = fixture()
            await controller.testEvaluate()
            expect(!hardware.state.builtInIsOn && helper.isRunning,
                   "attaching an external applies the saved OFF preference")
            controller.setUsesBuiltInWithExternal(true)
            await controller.testEvaluate()
            expect(controller.usesBuiltInWithExternal && hardware.state.builtInIsRestored,
                   "ON immediately restores the panel and disables automation")
            hardware.state = fixture(externals: ["another-monitor"])
            await controller.testEvaluate()
            expect(hardware.state.builtInIsOn && hardware.calls.filter { !$0.on }.count == 1,
                   "ON survives external topology changes")
        }
        do {
            let (controller, hardware, _) = make()
            controller.setBuiltIn(on: true) // Safe update/recovery override.
            await controller.testEvaluate()
            controller.setUsesBuiltInWithExternal(false)
            await controller.testEvaluate()
            expect(!hardware.state.builtInIsOn, "explicit OFF clears a temporary recovery override")
            controller.setUsesBuiltInWithExternal(true)
            await controller.testEvaluate()
        }
        do {
            let hardware = FakeDisplayHardware()
            let helper = FakeRecoveryGuard()
            let controller = DisplayController(testing: true, hardware: hardware,
                                               guardProcess: helper, previewOnly: true)
            controller.setUsesBuiltInWithExternal(false)
            await controller.testEvaluate()
            controller.setUsesBuiltInWithExternal(true)
            await controller.testEvaluate()
            expect(hardware.calls.isEmpty && helper.starts.isEmpty,
                   "clicking preview controls never starts display transactions or a helper")
        }
        // Physical unplug can temporarily remove BOTH displays from enumeration.
        do {
            let (controller, hardware, helper) = await disabled()
            hardware.state = fixture(present: false, externals: [])
            for _ in 0..<20 { await controller.testEvaluate() }
            expect(controller.testRecoveryPending && controller.testRecoveryRequested,
                   "missing panel never cancels restoration, even after many polls")
            expect(helper.stops == 0 && helper.isRunning, "missing panel keeps helper alive")
            expect(helper.restoreRequests > 0, "controller tells helper to recover")
            hardware.state = fixture(on: false, externals: [], builtInID: 99)
            await controller.testEvaluate()
            expect(hardware.state.builtInIsRestored, "returning panel with changed ID is restored")
            await controller.testEvaluate() // Observe the helper's completed transaction.
            expect(!controller.testRecoveryPending && helper.stops == 1,
                   "release only after actual restoration")
            expect(hardware.calls.dropFirst().allSatisfy { $0.on && $0.recovery },
                   "every recovery transaction enables with session lifetime")
        }
        do {
            let (controller, hardware, helper) = await disabled()
            hardware.state = fixture(on: false, lid: true, externals: [])
            controller.testSleep()
            await controller.testEvaluate()
            expect(controller.testRecoveryPending && helper.stops == 0,
                   "sleep and closed lid do not release helper")
            expect(!hardware.state.builtInIsRestored, "closed lid is not confirmation")
            hardware.state = fixture(on: false, externals: [])
            // Deliberately omit didWake: a missed wake callback must not block recovery.
            await controller.testEvaluate()
            await controller.testEvaluate()
            expect(hardware.state.builtInIsRestored && !controller.testRecoveryPending,
                   "opening lid restores even without a wake notification")
        }
        do {
            let (controller, hardware, helper) = await disabled()
            hardware.state = fixture(on: false, externals: [])
            hardware.enableFails = true
            for _ in 0..<10 { await controller.testEvaluate() }
            expect(controller.testRecoveryPending && helper.stops == 0,
                   "API failures retain responsibility")
            // Reconnection does not cancel a recovery already in progress.
            hardware.state = fixture(on: false)
            hardware.enableFails = false
            await controller.testEvaluate()
            expect(hardware.state.builtInIsRestored, "recovery survives reconnection")
            await controller.testEvaluate()
            expect(hardware.state.builtInIsRestored, "no immediate automatic redisable after recovery")
        }
        do {
            let (controller, hardware, helper) = await disabled()
            hardware.state = fixture(on: true, externals: [], active: false)
            hardware.activationDelayed = true
            await controller.testEvaluate()
            expect(controller.testRecoveryPending && helper.stops == 0,
                   "online but inactive panel is not recovered")
            hardware.activationDelayed = false
            await controller.testEvaluate()
            await controller.testEvaluate()
            expect(!controller.testRecoveryPending, "active state completes recovery")
        }
        do {
            let (controller, hardware, helper) = await disabled()
            helper.isRunning = false
            await controller.testEvaluate()
            expect(helper.starts == [false, true], "dead helper replaced in restore-only mode")
            expect(hardware.state.builtInIsRestored, "helper loss restores despite automatic off")
        }
        do {
            let (controller, hardware, helper) = make(FakeDisplayHardware(fixture(on: false)))
            await controller.testEvaluate()
            expect(helper.starts == [true], "startup with orphaned off panel starts recovery helper")
            expect(hardware.state.builtInIsRestored, "startup restores orphaned off panel")
        }
        for flag: CGDisplayChangeSummaryFlags in [.removeFlag, .disabledFlag] {
            let (controller, hardware, _) = await disabled()
            // Snapshot deliberately keeps the stale active external entry.
            controller.displaysChanged(displayID: 2, flags: flag)
            await controller.testEvaluate()
            expect(hardware.state.builtInIsRestored,
                   "explicit external removal wins over stale online display list")
        }
        do {
            let (controller, hardware, _) = await disabled()
            hardware.state = fixture(on: false, externals: ["temporary-headless"])
            await controller.testEvaluate()
            expect(hardware.state.builtInIsRestored,
                   "new placeholder does not substitute for protected external")
        }
        do {
            var state = fixture(externals: [])
            state.displays.append(DisplayInfo(id: 12, identity: "headless", builtIn: false,
                                               online: true, active: true, mirrored: false,
                                               hasHardwareIdentity: false))
            let (controller, hardware, helper) = make(FakeDisplayHardware(state))
            await controller.testEvaluate()
            expect(hardware.calls.isEmpty && helper.starts.isEmpty,
                   "headless entry cannot authorize disabling the only physical panel")
        }
        do {
            let (controller, hardware, helper) = await disabled()
            hardware.readFails = true
            await controller.testEvaluate()
            expect(controller.testRecoveryPending && helper.stops == 0,
                   "unreadable topology preserves protection")
            hardware.readFails = false
            await controller.testEvaluate()
            expect(hardware.state.builtInIsRestored, "read failure latches recovery")
        }
        do {
            let helper = FakeRecoveryGuard()
            helper.startFails = true
            let (controller, hardware, _) = make(FakeDisplayHardware(), helper)
            await controller.testEvaluate()
            expect(hardware.calls.isEmpty, "failed helper startup forbids off transaction")
        }
        do {
            let (controller, hardware, _) = make()
            hardware.afterDisable = { hardware.state = fixture(on: false, externals: []) }
            await controller.testEvaluate()
            expect(hardware.state.builtInIsRestored, "unplug during off verification triggers rollback")
            await controller.testEvaluate()
            expect(!controller.testRecoveryPending, "rollback confirmation releases obligation")
        }
        do {
            let (controller, hardware, _) = await disabled()
            hardware.state = fixture() // macOS reactivated the panel without a restore request.
            await controller.testEvaluate()
            expect(hardware.calls.filter { !$0.on }.count == 2 && !hardware.state.builtInIsOn,
                   "macOS reactivation is reapplied through the existing helper")
        }
        do {
            let (controller, hardware, helper) = await disabled()
            hardware.state = fixture(present: false, externals: [])
            let confirmed = await controller.stop()
            expect(!confirmed && helper.restoreRequests > 0 && helper.stops == 1,
                   "quit with unavailable panel hands recovery to helper via command and EOF")
        }
        testResumeActivityReconciliation()
        await testMissingScreenWake()
        await testEmergencyWithStaleScreenSleep()
        await testRecordedHotplug()
        await testNightRecovery()
        await testFailedLockedWake()
        await testLockedPreference()
        await testConsoleReturnRecovery()
        await testRecoveryOwnership()
        print("PASS: \(checks) controller and persistent-recovery checks (simulated hardware only)")
    }

    static func testResumeActivityReconciliation() {
        var activity = SessionResumeState()
        activity.setScreensAwake(false, now: 0)
        activity.setSystemAwake(false, now: 1)
        activity.setSessionActive(true, now: 2)
        expect(activity.suspended, "unchanged console ownership cannot wake sleeping displays")
        activity.setSystemAwake(true, now: 3)
        expect(!activity.suspended, "system wake repairs both awake dimensions without a screen-wake callback")
        expect(!activity.ready(now: 4.9), "reconciled system wake preserves settling")
        activity.setSystemAwake(true, now: 4)
        activity.setScreensAwake(true, now: 4.5)
        expect(activity.ready(now: 5), "unchanged duplicate wake cannot postpone a pending resume")
        activity.consume()
        activity.setSystemAwake(true, now: 6)
        activity.setScreensAwake(true, now: 6)
        expect(!activity.pending, "duplicate wake cannot grant another consumed resume opportunity")
        activity.setSystemAwake(false, now: 7)
        activity.setScreensAwake(true, now: 8) // Already true; system flag contradicts it.
        expect(!activity.suspended && activity.ready(now: 10),
               "screen wake repairs stale system sleep despite unchanged own flag")
        activity.setLidOpen(false, now: 11)
        activity.setSystemAwake(true, now: 12)
        expect(activity.suspended && !activity.ready(now: 20), "positive wake does not override closed lid")
        activity.setLidOpen(true, now: 21)
        activity.setSessionActive(false, now: 22)
        activity.setScreensAwake(false, now: 23)
        activity.setSystemAwake(true, now: 24)
        expect(activity.suspended && !activity.ready(now: 30), "positive wake does not override console ownership")
    }

    static func testMissingScreenWake() async {
        var now: TimeInterval = 0
        let (controller, hardware, helper) = make(recoveryClock: { now }, sessionProbe: { true })
        await controller.testEvaluate()
        controller.testScreens(awake: false)
        controller.testSleep()
        await controller.testEvaluate()
        let originalCalls = hardware.calls.count
        hardware.state = fixture() // macOS reactivated the panel during sleep.
        now = 1
        await controller.testEvaluate() // Owner polling is deliberately unchanged.
        expect(hardware.calls.count == originalCalls, "same-owner polling cannot wake sleeping controller")
        controller.testWake() // No screensDidWake notification follows.
        await controller.testEvaluate()
        expect(hardware.state.builtInIsOn, "system wake waits for resume settling before reapplying OFF")
        now = 4
        controller.testFinishSettling()
        await controller.testEvaluate()
        expect(!hardware.state.builtInIsOn && helper.starts == [false] && helper.restoreRequests == 0,
               "system wake without screen wake reapplies OFF using the retained helper")
        for _ in 0..<10 {
            now += 3
            controller.testWake()
            controller.testScreens(awake: true)
            controller.testFinishSettling()
            await controller.testEvaluate()
        }
        expect(hardware.calls.count == originalCalls + 1,
               "duplicate wake cannot add transactions after successful resume")
    }

    static func testEmergencyWithStaleScreenSleep() async {
        for wakeFirst in [false, true] {
            var now: TimeInterval = 0
            let (controller, hardware, helper) = make(recoveryClock: { now })
            await controller.testEvaluate()
            controller.testScreens(awake: false)
            controller.testSleep()
            await controller.testEvaluate()
            if wakeFirst { controller.testWake(); await controller.testEvaluate() }
            expect(!hardware.state.builtInIsOn && helper.restoreRequests == 0,
                   "sleeping controller retains disabled panel before explicit recovery")
            controller.testEmergencyRestore()
            await controller.testEvaluate()
            // This fixture completes restoration immediately. The regression
            // proves controller delegation, not a real helper waking without
            // any of its own wake notifications.
            expect(helper.restoreRequests > 0,
                   "explicit emergency recovery forwards despite stale screen-sleep flag: wakeFirst=\(wakeFirst)")
            expect(hardware.mainEnableCalls == 0, "emergency recovery stays delegated to its separate helper")
            await controller.testEvaluate()
            controller.testSleep()
            controller.testWake()
            now = 10
            controller.testFinishSettling()
            await controller.testEvaluate()
            expect(hardware.state.builtInIsRestored && hardware.calls.filter { !$0.on }.count == 1,
                   "subsequent wake preserves the explicit emergency recovery hold")
        }
    }

    static func testRecoveryOwnership() async {
        var lidClock: TimeInterval = 0
        let (lidController, lidHardware, _) = make(recoveryClock: { lidClock })
        await lidController.testEvaluate()
        lidHardware.state = fixture(on: false, lid: true)
        await lidController.testEvaluate()
        expect(lidHardware.mainEnableCalls == 0 && lidHardware.helperEnableCalls == 0,
               "lid closure alone arms recovery without configuration commands")
        lidHardware.state = fixture(on: false) // External stays connected and awake.
        await lidController.testEvaluate()
        await lidController.testEvaluate()
        expect(lidHardware.state.builtInIsRestored, "lid opening first completes helper recovery")
        lidClock = 3
        lidController.testFinishSettling()
        await lidController.testEvaluate()
        expect(!lidHardware.state.builtInIsOn,
               "lid reopening reapplies OFF even without sleep or lock notifications")

        let (controller, hardware, helper) = await disabled()
        helper.automaticallyStep = false // Model a helper waiting on WindowServer.
        hardware.state = fixture(on: false, externals: [])
        hardware.calls = []
        for _ in 0..<100 {
            controller.displaysChanged(displayID: 2, flags: .removeFlag)
            await controller.testEvaluate()
        }
        expect(hardware.mainEnableCalls == 0 && hardware.calls.isEmpty,
               "live restoring helper never competes with a main-process enable")
        expect(controller.testRecoveryPending && !controller.busy,
               "waiting on the helper preserves recovery without UI animation")
        helper.step()
        await controller.testEvaluate()
        expect(hardware.helperEnableCalls == 1 && hardware.mainEnableCalls == 0,
               "helper is the only process that performs restoration")
        expect(!controller.testRecoveryPending && hardware.state.builtInIsRestored,
               "main releases recovery after observing the helper's result")

        let (retiring, pending, oldHelper) = await disabled()
        oldHelper.isRunning = false
        oldHelper.canStart = false // A predecessor still owns a rescue lease.
        pending.state = fixture(on: false, externals: [])
        for _ in 0..<20 { await retiring.testEvaluate() }
        expect(pending.mainEnableCalls == 0 && oldHelper.starts == [false],
               "retiring helper blocks both local recovery and replacement startup")
        oldHelper.canStart = true
        await retiring.testEvaluate()
        expect(pending.state.builtInIsRestored && pending.mainEnableCalls == 0,
               "replacement helper takes ownership only after predecessor exits")

        let (fallback, orphan, brokenHelper) = await disabled()
        brokenHelper.isRunning = false
        brokenHelper.startFails = true
        orphan.state = fixture(on: false, lid: true, externals: [])
        for _ in 0..<20 { await fallback.testEvaluate() }
        expect(orphan.mainEnableCalls == 0, "failed helper cannot force closed-lid configuration")
        orphan.state = fixture(on: false, externals: [])
        await fallback.testEvaluate()
        expect(orphan.mainEnableCalls == 0 && fallback.testRecoveryPending,
               "failed helper startup never enters an unbounded UI configuration fallback")
        brokenHelper.startFails = false
        await fallback.testEvaluate()
        expect(orphan.state.builtInIsRestored, "available replacement helper resumes recovery")

        let (sleeping, duringSleep, sleeper) = await disabled()
        sleeper.automaticallyStep = false
        sleeping.testSleep()
        expect(duringSleep.mainEnableCalls == 0 && sleeper.restoreRequests == 0,
               "willSleep preserves confirmed disabling without reconfiguring WindowServer")
        let confirmed = await sleeping.stop()
        expect(!confirmed && duringSleep.mainEnableCalls == 0 && sleeper.stops == 1,
               "quit hands pending recovery to the helper without racing or killing it")
    }

    static func nightProbe() async {
        let (controller, hardware, _) = await disabled()
        hardware.state = fixture(on: false, lid: true)
        hardware.enableFails = true
        hardware.calls = []
        var publications = 0
        let observation = controller.objectWillChange.sink { publications += 1 }
        hardware.afterEnable = {
            // An unsuccessful WindowServer transaction can still deliver a
            // configuration callback. Bound the old-version feedback loop.
            guard hardware.calls.count < 20_000 else { return }
            Task { @MainActor in controller.displaysChanged(displayID: 1, flags: .setModeFlag) }
        }
        let begin = ProcessInfo.processInfo.systemUptime
        controller.requestEvaluation()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        hardware.afterEnable = nil
        await controller.testEvaluate()
        print("NIGHT PROBE: \(hardware.calls.count) enable calls, \(publications) UI publications in \(ProcessInfo.processInfo.systemUptime - begin) seconds (simulated closed lid / API errors)")
        withExtendedLifetime(observation) {}
    }

    static func testLockedPreference() async {
        for sleepKind in ["none", "display", "system"] {
            var now: TimeInterval = 0
            let (controller, hardware, helper) = make(recoveryClock: { now })
            await controller.testEvaluate()
            controller.testLock()
            await controller.testEvaluate()
            expect(!hardware.state.builtInIsOn && helper.restoreRequests == 0,
                   "lock retains the confirmed OFF preference: \(sleepKind)")
            let initialCalls = hardware.calls.count
            if sleepKind == "display" { controller.testScreens(awake: false) }
            if sleepKind == "system" { controller.testSleep() }
            if sleepKind != "none" {
                for _ in 0..<20 { now += 1_440; await controller.testEvaluate() }
                expect(hardware.calls.count == initialCalls && helper.restoreRequests == 0,
                       "locked sleep never proactively enables the panel: \(sleepKind)")
                controller.testScreens(awake: true)
                controller.testWake()
                now += 3
                controller.testFinishSettling()
                await controller.testEvaluate()
                expect(!hardware.state.builtInIsOn && hardware.calls.count == initialCalls,
                       "locked wake with preserved OFF state needs no transaction: \(sleepKind)")
            }
            hardware.state = fixture() // macOS reactivated the built-in while still locked.
            await controller.testEvaluate()
            expect(!hardware.state.builtInIsOn && helper.starts == [false] && helper.restoreRequests == 0,
                   "locked reactivation reapplies OFF without retiring its rescue helper: \(sleepKind)")
            controller.testUnlock()
            await controller.testEvaluate()
            expect(!hardware.state.builtInIsOn && helper.restoreRequests == 0,
                   "unlock does not flash the already disabled panel: \(sleepKind)")
            hardware.state = fixture(on: false, externals: [])
            await controller.testEvaluate()
            expect(hardware.state.builtInIsRestored && helper.restoreRequests > 0,
                   "locked/unlocked unplug restores the only usable display: \(sleepKind)")
        }
        do {
            let (controller, hardware, helper) = await disabled()
            controller.testLock()
            hardware.state = fixture(on: false, present: false)
            await controller.testEvaluate()
            expect(helper.restoreRequests == 0 && helper.isRunning,
                   "a disabled panel missing from enumeration retains its protected external lease")
            hardware.state = fixture(on: false, present: false, externals: [])
            await controller.testEvaluate()
            expect(controller.testRecoveryRequested && helper.restoreRequests > 0,
                   "missing panel still requests remembered-ID recovery after unplug")
        }
        do {
            let (controller, hardware, helper) = await disabled()
            controller.testLock()
            controller.testSession(active: false) // Switch user or log out.
            expect(hardware.state.builtInIsRestored && helper.restoreRequests > 0,
                   "losing console ownership still restores immediately")
        }
        do {
            let (controller, hardware, helper) = await disabled()
            controller.testLock()
            controller.setUsesBuiltInWithExternal(true)
            await controller.testEvaluate()
            expect(hardware.state.builtInIsRestored && helper.restoreRequests > 0,
                   "explicit ON overrides a retained locked lease")
        }
    }

    static func testFailedLockedWake() async {
        var now: TimeInterval = 0
        let (controller, hardware, helper) = make(recoveryClock: { now })
        await controller.testEvaluate()
        controller.testLock()
        controller.testSleep()
        controller.testWake()
        now = 3
        controller.testFinishSettling()
        hardware.state = fixture() // Helper recovered after its wake reapply failed.
        helper.isRunning = false
        await controller.testEvaluate()
        for _ in 0..<20 {
            now += 3
            controller.testWake() // Duplicate notification cannot renew a retry ticket.
            controller.testFinishSettling()
            await controller.testEvaluate()
        }
        expect(hardware.state.builtInIsOn && hardware.calls.filter { !$0.on }.count == 1,
               "unexpected wake helper failure cannot reuse a stale resume ticket to disable again")
    }

    static func testConsoleReturnRecovery() async {
        // The original external UUID never changes, so the old policy would
        // stay inhibited after the helper restored during a lock/sleep cycle.
        for trigger in ["console-leave", "display-sleep", "system-sleep"] {
            var now: TimeInterval = 0
            let (controller, hardware, helper) = make(recoveryClock: { now })
            await controller.testEvaluate()
            controller.testSession(active: false)
            if trigger == "display-sleep" { controller.testScreens(awake: false) }
            if trigger == "system-sleep" { controller.testSleep() }
            hardware.state = fixture() // macOS or the independent helper restored it.
            await controller.testEvaluate()
            now = 60
            controller.testFinishSettling()
            controller.testScreens(awake: true)
            controller.testWake()
            await controller.testEvaluate()
            expect(hardware.state.builtInIsOn, "wake while outside the owner console cannot disable: \(trigger)")
            controller.testSession(active: true)
            await controller.testEvaluate()
            expect(hardware.state.builtInIsOn, "console return waits for link settling: \(trigger)")
            helper.canStart = false
            now += 3
            controller.testFinishSettling()
            await controller.testEvaluate()
            expect(hardware.state.builtInIsOn && controller.notice == nil,
                   "retiring helper delays resumption without permanent failure: \(trigger)")
            helper.canStart = true
            await controller.testEvaluate()
            expect(!hardware.state.builtInIsOn && helper.isRunning && helper.starts == [false, false],
                   "console return reapplies OFF with a new ready helper on unchanged external: \(trigger)")
            expect(!controller.usesBuiltInWithExternal, "console return preserves the saved switch: \(trigger)")
        }
        do {
            var now: TimeInterval = 0
            var active = false
            let (controller, hardware, _) = make(recoveryClock: { now }, sessionProbe: { active })
            await controller.testEvaluate()
            expect(hardware.calls.isEmpty, "cold launch outside the owner console never disables")
            active = true // Both distributed notifications were missed.
            await controller.testEvaluate()
            expect(hardware.calls.isEmpty, "polled unlock also waits for settling")
            now = 3
            await controller.testEvaluate()
            expect(!hardware.state.builtInIsOn, "existing poll detects unlock without extra timers")
        }
        for useBoth in [false, true] {
            var now: TimeInterval = 0
            let (controller, hardware, _) = make(recoveryClock: { now })
            await controller.testEvaluate()
            controller.testSession(active: false)
            hardware.state = fixture(externals: [])
            await controller.testEvaluate()
            if useBoth { controller.setUsesBuiltInWithExternal(true) }
            controller.testSession(active: true)
            now = 5
            controller.testFinishSettling()
            await controller.testEvaluate()
            expect(hardware.state.builtInIsOn, "unlock without external keeps the only screen on")
            hardware.state = fixture()
            await controller.testEvaluate()
            expect(hardware.state.builtInIsOn == useBoth,
                   "external returning after unlock respects the latest preference")
        }
        do {
            var now: TimeInterval = 0
            let (controller, hardware, _) = make(recoveryClock: { now })
            await controller.testEvaluate()
            controller.testSession(active: false)
            hardware.state = fixture()
            await controller.testEvaluate()
            controller.testSession(active: true)
            now = 3
            controller.testFinishSettling()
            hardware.disableFails = true
            await controller.testEvaluate()
            for _ in 0..<100 {
                now += 5
                controller.testSession(active: true)
                controller.testScreens(awake: true)
                controller.testWake()
                controller.testFinishSettling()
                await controller.testEvaluate()
            }
            expect(hardware.calls.filter { !$0.on }.count == 2 && hardware.state.builtInIsOn,
                   "failed automatic resume stays inhibited despite duplicate wake/unlock events")
        }
        do {
            var now: TimeInterval = 0
            let (controller, hardware, _) = make(recoveryClock: { now })
            await controller.testEvaluate()
            controller.setBuiltIn(on: true) // Explicit emergency/update hold.
            await controller.testEvaluate()
            controller.testSession(active: false)
            controller.testSession(active: true)
            now = 10
            controller.testFinishSettling()
            await controller.testEvaluate()
            expect(hardware.state.builtInIsOn && hardware.calls.filter { !$0.on }.count == 1,
                   "unlock never clears an explicit manual recovery hold")
        }
        do {
            var now: TimeInterval = 0
            let (controller, hardware, helper) = make(recoveryClock: { now })
            await controller.testEvaluate()
            controller.testSession(active: false)
            expect(hardware.state.builtInIsRestored, "console leave immediately requests restoration")
            await controller.testEvaluate()
            controller.testSession(active: true)
            now = 3
            controller.testFinishSettling()
            await controller.testEvaluate()
            helper.isRunning = false
            await controller.testEvaluate()
            now = 20
            controller.testFinishSettling()
            await controller.testEvaluate()
            expect(hardware.state.builtInIsOn && hardware.calls.filter { !$0.on }.count == 2,
                   "completed short lock leaves no stale resume ticket for a later helper fault")
        }
    }

    static func testNightRecovery() async {
        var now: TimeInterval = 0
        let (controller, hardware, helper) = make(recoveryRetryDelay: 2, recoveryClock: { now })
        await controller.testEvaluate()
        hardware.state = fixture(on: false, lid: true, externalActive: false)
        hardware.enableFails = true
        hardware.calls = []
        var publications = 0
        let observation = controller.objectWillChange.sink { publications += 1 }
        await controller.testEvaluate()
        let settledPublications = publications
        // Eight hours awake on mains power, lid shut, monitor connected.
        for tick in 1...14_400 {
            now = Double(tick) * 2
            controller.displaysChanged(displayID: 1, flags: .setModeFlag)
            await controller.testEvaluate()
        }
        expect(hardware.calls.isEmpty, "closed lid allows no configuration calls during eight hours")
        expect(publications == settledPublications && !controller.busy,
               "unchanged closed-lid waiting emits no UI updates or progress animation")
        expect(helper.isRunning && controller.testRecoveryPending,
               "quiet overnight waiting keeps the rescue obligation")
        // No willSleep/didWake callback: this Mac never slept overnight.
        hardware.enableFails = false
        hardware.state = fixture(on: false, externals: [])
        await controller.testEvaluate()
        await controller.testEvaluate()
        expect(hardware.state.builtInIsRestored && !controller.testRecoveryPending,
               "opening lid and removing cable restores without a system wake event")
        withExtendedLifetime(observation) {}

        let (retrying, failing, _) = make(recoveryRetryDelay: 2, recoveryClock: { now })
        await retrying.testEvaluate()
        failing.state = fixture(on: false, externals: [])
        failing.enableFails = true
        failing.calls = []
        await retrying.testEvaluate()
        for _ in 0..<100 {
            retrying.displaysChanged(displayID: 1, flags: .setModeFlag)
            await retrying.testEvaluate()
        }
        expect(failing.calls.count == 1, "open-lid API failures cannot self-trigger a hot retry loop")
        now += 2
        await retrying.testEvaluate()
        expect(failing.calls.count == 2, "pending recovery retries after the bounded cooldown")
        failing.enableFails = false
        failing.state = fixture(on: false, externals: [], builtInID: 99)
        await retrying.testEvaluate()
        expect(failing.state.builtInIsRestored, "newly detected panel bypasses cooldown immediately")

        let (closing, changing, retained) = make(recoveryRetryDelay: 2)
        await closing.testEvaluate()
        changing.calls = []
        changing.afterEnable = { changing.state = fixture(on: false, lid: true, externalActive: false) }
        closing.setUsesBuiltInWithExternal(true)
        await closing.testEvaluate()
        for _ in 0..<50 { await closing.testEvaluate() }
        expect(changing.calls.count == 1 && !closing.busy && retained.isRunning,
               "closing lid during verification stops polling and repeated enables")
        let quitRestored = await closing.stop()
        expect(!quitRestored && retained.stops == 1,
               "quit with closed lid hands off recovery without claiming restoration")
    }

    static func recordedHeadlessState() -> DisplaySnapshot {
        // Exact topology shape observed during the failed physical unplug:
        // no ID 1, one active "unkn"/"virt" placeholder, offline alias ID 3.
        DisplaySnapshot(displays: [
            DisplayInfo(id: 13, identity: "placeholder", builtIn: false, online: true,
                        active: true, mirrored: false, hasHardwareIdentity:
                            DisplayHardwareIdentity.isUsableExternal(vendor: 1970170734, model: 1986622068)),
            DisplayInfo(id: 3, identity: "offline-alias", builtIn: false, online: false,
                        active: false, mirrored: false)
        ], lidClosed: false)
    }

    static func testRecordedHotplug() async {
        let headless = recordedHeadlessState()
        expect(headless.externalDisplays.isEmpty, "recorded unkn/virt placeholder is not an external monitor")
        expect(DisplayHardwareIdentity.isUsableExternal(vendor: 25001, model: 45061), "real monitor remains usable")
        expect(!DisplayHardwareIdentity.isUsableExternal(vendor: 0, model: 12), "missing vendor remains excluded")
        var locator = BuiltInRecoveryTarget()
        expect(locator.resolve(in: headless, on: true, recovery: true) == nil, "never invent a built-in ID")
        locator.observe(fixture())
        locator.observe(headless)
        expect(locator.resolve(in: headless, on: true, recovery: true) == 1,
               "remembered built-in ID survives complete removal from enumeration")
        expect(locator.resolve(in: headless, on: false, recovery: true) == nil, "remembered ID can never disable")
        expect(locator.resolve(in: headless, on: true, recovery: false) == nil, "fallback is recovery-only")
        var closed = headless
        closed.lidClosed = true
        expect(locator.resolve(in: closed, on: true, recovery: true) == nil, "do not force a hidden panel with closed lid")
        expect(locator.resolve(in: fixture(present: false), on: true, recovery: true) == nil,
               "do not reuse remembered ID with a physical external still active")
        var reused = headless
        reused.displays.append(DisplayInfo(id: 1, identity: "different-display", builtIn: false,
                                           online: false, active: false, mirrored: false))
        expect(locator.resolve(in: reused, on: true, recovery: true) == nil, "reject an ID now assigned to another record")
        locator.observe(fixture(builtInID: 99))
        expect(locator.resolve(in: fixture(builtInID: 99), on: true, recovery: true) == 99,
               "fresh built-in identification always wins")
        expect(locator.resolve(in: headless, on: true, recovery: true) == 99, "update remembered ID after re-enumeration")

        let (controller, hardware, helper) = await disabled()
        hardware.simulateHeadlessRecovery = true
        hardware.state = headless
        await controller.testEvaluate()
        expect(hardware.recoveredIDs == [1] && hardware.state.builtInIsRestored,
               "production controller recovers recorded unplug topology via remembered target")
        await controller.testEvaluate()
        expect(!controller.testRecoveryPending && helper.stops == 1, "release after headless recovery is confirmed")

    }
}
