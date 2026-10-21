import AppKit
import Combine
import CoreGraphics
import ServiceManagement

@MainActor
final class DisplayController: ObservableObject {
    @Published private(set) var snapshot = DisplaySnapshot(displays: [], lidClosed: false)
    @Published private(set) var automatic = false
    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    @Published private(set) var loginNotice: String?
    let hardware: any DisplayHardwareAccess
    private let guardProcess: any RecoveryGuarding
    private let verificationDelay: UInt64
    private var policy: DisplayPolicy
    private let preferences: UserDefaults
    private let testing: Bool
    private let previewOnly: Bool
    private var recoveryAttempts: RecoveryAttemptGate
    private let recoveryClock: () -> TimeInterval
    private var timer: Timer?
    private var evaluation: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var activity = SessionResumeState()
    private let sessionProbe: () -> Bool?
    private var manualRecoveryHold = false
    private var stopping = false
    private var notBefore = Date.distantPast
    private var hasDisabled = false
    private var recoveryRequested = false
    private var protectedExternalIdentities: Set<String> = []
    private var protectedExternalIDs: Set<UInt32> = []
    private var registeredCallback = false
    static let recoverNotification = Notification.Name("com.gevorg.screenoff.restore")

    init(preferences: UserDefaults = .standard, testing: Bool = false,
         hardware: any DisplayHardwareAccess = DisplayHardware(),
         guardProcess: (any RecoveryGuarding)? = nil,
         automaticPreference: Bool? = nil, verificationDelay: UInt64 = 150_000_000,
         previewOnly: Bool = false, recoveryRetryDelay: TimeInterval = 2,
         recoveryClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sessionProbe: (() -> Bool?)? = nil) {
        self.hardware = hardware
        self.guardProcess = guardProcess ?? RecoveryGuard()
        self.verificationDelay = verificationDelay
        self.preferences = preferences
        self.testing = testing
        self.previewOnly = previewOnly
        self.recoveryAttempts = RecoveryAttemptGate(retryDelay: recoveryRetryDelay)
        self.recoveryClock = recoveryClock
        self.sessionProbe = sessionProbe ?? (testing ? { nil } : { Self.readSessionActive() ?? false })
        let saved = automaticPreference ?? (!testing && preferences.bool(forKey: "automaticDisplayOff"))
        policy = DisplayPolicy(automatic: saved)
        automatic = saved
        if !hardware.supported {
            notice = DisplayFailure.unavailable("the display-disabling API").localizedDescription
        }
        snapshot = (try? hardware.snapshot()) ?? snapshot
        self.guardProcess.remember(snapshot)
    }

    var displayRolePreviewOnly: Bool { testing || previewOnly }

    var canToggle: Bool {
        hardware.supported && !busy && !recoveryRequested && !snapshot.lidClosed && snapshot.builtIn != nil
            && (!snapshot.builtInIsOn || snapshot.canDisable)
    }

    /// Preserve the existing saved preference, with a positive UI meaning:
    /// ON = use both displays; OFF = automatically disable the built-in.
    var usesBuiltInWithExternal: Bool { !automatic }

    func setUsesBuiltInWithExternal(_ enabled: Bool) {
        setAutomatic(!enabled)
    }

    var statusText: String {
        if let notice { return notice }
        if busy { return "Switching displays…" }
        if snapshot.lidClosed { return "MacBook lid is closed" }
        if snapshot.builtIn == nil { return "Built-in display not found" }
        if snapshot.displays.contains(where: { $0.online && $0.mirrored }) {
            return "Turn off display mirroring in macOS to disable this screen"
        }
        if snapshot.externalDisplays.isEmpty { return "No external monitor; MacBook display is on" }
        return snapshot.builtInIsOn ? "Built-in display is on" : "Only the external display is active"
    }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        registeredCallback = CGDisplayRegisterReconfigurationCallback(displayChanged, context) == .success
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestEvaluation() }
        }
        timer.tolerance = 0.5
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.prepareForSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.activity.setSystemAwake(true, now: self.recoveryClock())
                self.notBefore = Date().addingTimeInterval(4)
                self.requestEvaluation()
            }
        })
        for (name, awake) in [(NSWorkspace.screensDidSleepNotification, false),
                              (NSWorkspace.screensDidWakeNotification, true)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanged(awake: awake) }
            })
        }
        for (name, active) in [(NSWorkspace.sessionDidResignActiveNotification, false),
                               (NSWorkspace.sessionDidBecomeActiveNotification, true)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sessionChanged(active: active) }
            })
        }
        // Locking with Touch ID does not necessarily put the Mac to sleep or
        // switch user sessions. Observe lock notifications as a separate path.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(sessionLocked),
                                name: Notification.Name("com.apple.screenIsLocked"), object: nil,
                                suspensionBehavior: .deliverImmediately)
        distributed.addObserver(self, selector: #selector(sessionUnlocked),
                                name: Notification.Name("com.apple.screenIsUnlocked"), object: nil,
                                suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(emergencyRestore),
                                                            name: Self.recoverNotification, object: nil)
        updateLoginNotice()
        requestEvaluation()
    }

    func displaysChanged(displayID: UInt32? = nil, flags: CGDisplayChangeSummaryFlags = []) {
        if let displayID, hasDisabled, activity.systemAwake, activity.screensAwake,
           protectedExternalIDs.contains(displayID),
           !flags.intersection([.removeFlag, .disabledFlag]).isEmpty {
            // An explicit removal wins even if CoreGraphics still exposes an
            // old active list or creates a temporary headless virtual display.
            recoveryRequested = true
            guardProcess.requestRestore()
        }
        // Let link training and WindowServer reconfiguration settle. The helper
        // independently restores immediately if the last external disappears.
        notBefore = max(notBefore, Date().addingTimeInterval(0.8))
        requestEvaluation()
    }

    func setBuiltIn(on: Bool) {
        guard !busy, !recoveryRequested || on else { return }
        policy.setManual(on: on)
        manualRecoveryHold = on
        activity.consume()
        notice = nil
        notBefore = .distantPast
        requestEvaluation()
    }

    func setAutomatic(_ enabled: Bool) {
        manualRecoveryHold = false
        policy.setAutomatic(enabled)
        automatic = enabled
        if !testing { preferences.set(enabled, forKey: "automaticDisplayOff") }
        notice = nil
        // Login registration follows the mode that requires background work.
        // Preview/test instances never register login items or save preferences.
        if testing {
            notBefore = .distantPast
            requestEvaluation()
            return
        }
        do {
            if enabled && SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled && SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            updateLoginNotice()
        } catch {
            loginNotice = "To start at login, add ScreenOff in System Settings → General → Login Items."
        }
        notBefore = .distantPast
        requestEvaluation()
    }

    func updateLoginNotice() {
        guard automatic, !testing else { loginNotice = nil; return }
        switch SMAppService.mainApp.status {
        case .enabled: loginNotice = nil
        case .requiresApproval:
            loginNotice = "Allow ScreenOff in System Settings → General → Login Items."
        default:
            loginNotice = "To keep working after a restart, add ScreenOff to Login Items in macOS."
        }
    }

    func requestEvaluation() {
        guard !previewOnly, !stopping, evaluation == nil else { return }
        evaluation = Task { [weak self] in
            guard let self else { return }
            defer { self.evaluation = nil }
            do {
                // Poll console ownership; a lock does not relinquish this user’s session.
                if let active = self.sessionProbe() {
                    self.activity.setSessionActive(active, now: self.recoveryClock())
                    if !active && self.hasDisabled {
                        self.recoveryRequested = true
                        self.guardProcess.requestRestore()
                    }
                }
                // Do not query WindowServer while physical displays are asleep.
                // Lid sensing remains independent so recovery can resume on open.
                if !self.testing {
                    self.activity.setLidOpen(DisplayEnvironment.lidClosed() == false, now: self.recoveryClock())
                    if !self.activity.lidOpen && self.hasDisabled {
                        self.recoveryRequested = true
                        self.guardProcess.requestRestore()
                    }
                    guard self.activity.systemAwake, self.activity.screensAwake, self.activity.lidOpen else { return }
                }
                self.updateSnapshot(try self.hardware.snapshot())
                if !self.activity.lidOpen && self.hasDisabled {
                    self.recoveryRequested = true
                    self.guardProcess.requestRestore()
                }
                // Tests use simulated snapshots to detect lid transitions even during sleep.
                guard self.activity.systemAwake, self.activity.screensAwake else { return }
                if self.activity.ready(now: self.recoveryClock()), !self.manualRecoveryHold,
                   !self.hasDisabled, !self.recoveryRequested,
                   self.snapshot.builtInIsRestored, self.snapshot.canDisable,
                   self.guardProcess.canStart, Date() >= self.notBefore {
                    self.activity.consume()
                    self.policy.setAutomatic(self.automatic)
                    self.updateNotice(nil)
                }
                let policyDesired = self.policy.wantsBuiltInOn(for: self.snapshot)
                // A known disabled panel may disappear from enumeration while
                // the protected external is still active. Keep its existing lease.
                let keepMissingPanelOff = self.hasDisabled && self.automatic && !self.policy.inhibited
                    && self.snapshot.builtIn == nil && !self.snapshot.externalDisplays.isEmpty
                    && !self.snapshot.displays.contains(where: { $0.online && $0.mirrored })
                let desired = keepMissingPanelOff ? false : policyDesired
                if !self.hasDisabled && self.snapshot.builtIn != nil &&
                    !self.snapshot.builtInIsOn && !self.snapshot.lidClosed {
                    // A previous process or a sleep transition may have left
                    // the panel off. Adopt recovery responsibility immediately.
                    self.hasDisabled = true
                    self.recoveryRequested = true
                    self.policy.stopAfterFailure()
                }
                guard self.hardware.supported else { return }
                if self.hasDisabled {
                    if desired || !self.activity.sessionActive || self.snapshot.lidClosed ||
                        self.protectedExternalIdentities.isDisjoint(with: self.snapshot.externalIdentities) {
                        self.recoveryRequested = true
                    }
                    if !self.guardProcess.isRunning {
                        let unexpectedExit = !self.recoveryRequested
                        self.recoveryRequested = true
                        self.policy.stopAfterFailure()
                        if unexpectedExit && self.activity.sessionActive { self.activity.consume() }
                    }
                }
                if self.recoveryRequested {
                    self.policy.stopAfterFailure()
                    if self.snapshot.builtInIsRestored {
                        self.releaseGuard()
                        return
                    }
                    _ = self.delegateRecovery()
                    self.showRecoveryNotice()
                    return
                }
                guard !self.activity.suspended, Date() >= self.notBefore else { return }
                if self.activity.pending && !self.activity.ready(now: self.recoveryClock()) { return }
                if self.activity.pending && self.hasDisabled && !self.snapshot.builtInIsOn {
                    // The display stayed off throughout a short lock cycle.
                    self.activity.consume()
                }
                if !desired && self.snapshot.builtInIsOn && self.hasDisabled {
                    // Keep the existing recovery lease when macOS reactivates the panel.
                    self.activity.consume()
                    self.guardProcess.requestDisable()
                    return
                }
                if !desired && self.snapshot.builtInIsOn {
                    // A restoring predecessor must finish before a new helper
                    // can arm; waiting is not a permanent watchdog failure.
                    guard self.guardProcess.canStart else { return }
                    try await self.transition(on: false)
                }
            } catch {
                await self.handleFailure(error)
            }
        }
    }

    private func transition(on: Bool) async throws {
        busy = true
        defer { busy = false }
        if !on {
            activity.consume()
            manualRecoveryHold = false
            try guardProcess.start(restoring: false)
            hasDisabled = true // Even a failed transaction may need rollback.
            protectedExternalIdentities = snapshot.externalIdentities
            protectedExternalIDs = Set(snapshot.externalDisplays.map(\.id))
        }
        if on { _ = delegateRecovery() }
        else { guardProcess.requestDisable() }
        for _ in 0..<12 {
            try await Task.sleep(nanoseconds: verificationDelay)
            updateSnapshot(try hardware.snapshot())
            if on && snapshot.lidClosed {
                recoveryAttempts.waitForOpenLid()
                recoveryRequested = true
                guardProcess.requestRestore()
                showRecoveryNotice()
                throw DisplayFailure.lidClosed
            }
            if !on && (stopping || activity.suspended || recoveryRequested || snapshot.lidClosed || snapshot.externalDisplays.isEmpty) {
                throw DisplayFailure.noExternal
            }
            if on ? snapshot.builtInIsRestored : (snapshot.builtIn != nil && !snapshot.builtInIsOn) {
                if on { releaseGuard() }
                return
            }
        }
        throw DisplayFailure.verification
    }

    private func releaseGuard() {
        guard snapshot.builtInIsRestored else { return }
        guardProcess.stop()
        hasDisabled = false
        recoveryRequested = false
        recoveryAttempts.reset()
        protectedExternalIdentities = []
        protectedExternalIDs = []
        notBefore = max(notBefore, Date().addingTimeInterval(2))
        updateNotice(nil)
    }

    /// A retiring helper still owns recovery even after its pipe was closed.
    /// The UI never falls back to a synchronous configuration: that call can
    /// block indefinitely, including inside an apparently bounded retry loop.
    private func delegateRecovery() -> Bool {
        if guardProcess.isRunning {
            guardProcess.requestRestore()
            return true
        }
        guard guardProcess.canStart else { return true }
        guard recoveryAttempts.shouldAttempt(in: snapshot, now: recoveryClock()) else { return false }
        do {
            try guardProcess.start(restoring: true)
            guardProcess.requestRestore()
            return true
        } catch {
            return false
        }
    }

    private func updateSnapshot(_ value: DisplaySnapshot) {
        // Closing the lid on mains power need not emit sleep/lock events.
        // Reopening still needs to reapply the saved external-display mode.
        activity.setLidOpen(!value.lidClosed, now: recoveryClock())
        guardProcess.remember(value)
        if snapshot != value { snapshot = value }
    }

    private func updateNotice(_ value: String?) {
        if notice != value { notice = value }
    }

    private func showRecoveryNotice() {
        updateNotice(snapshot.lidClosed
            ? "Display recovery will continue when you open the lid."
            : "Restoring the built-in display…")
    }

    private func handleFailure(_ error: Error) async {
        policy.stopAfterFailure()
        // Verification failure must actively undo any partially applied disable.
        // Keep the helper alive if restoration does not complete.
        if hasDisabled {
            recoveryRequested = true
            if let state = try? hardware.snapshot() { updateSnapshot(state) }
            if !snapshot.builtInIsRestored { _ = delegateRecovery() }
            showRecoveryNotice()
        } else {
            updateNotice(error.localizedDescription)
        }
        if let state = try? hardware.snapshot() { updateSnapshot(state) }
    }

    private func prepareForSleep() {
        activity.setSystemAwake(false, now: recoveryClock())
        // The independent helper preserves a completed disable and pauses its
        // worker during sleep. An in-flight transition rolls back on cancellation.
    }

    @objc private func emergencyRestore() {
        policy.stopAfterFailure()
        manualRecoveryHold = true
        activity.setSystemAwake(true, now: recoveryClock())
        activity.consume()
        if hasDisabled { recoveryRequested = true }
        notice = nil
        notBefore = .distantPast
        requestEvaluation()
    }

    private static func readSessionActive() -> Bool? {
        DisplayEnvironment.sessionAvailable()
    }

    private func sessionChanged(active: Bool) {
        // Session-resign notifications may accompany locking. Prefer actual
        // console ownership; absent evidence still fails toward restoration.
        let confirmed = sessionProbe() ?? active
        activity.setSessionActive(confirmed, now: recoveryClock())
        if !confirmed && hasDisabled {
            recoveryRequested = true
            guardProcess.requestRestore()
        }
        requestEvaluation()
    }

    private func screensChanged(awake: Bool) {
        activity.setScreensAwake(awake, now: recoveryClock())
        requestEvaluation()
    }

    @objc private func sessionLocked() { sessionChanged(active: true) }
    @objc private func sessionUnlocked() { sessionChanged(active: true) }

    func stop() async -> Bool {
        stopping = true
        timer?.invalidate()
        if registeredCallback {
            CGDisplayRemoveReconfigurationCallback(displayChanged, Unmanaged.passUnretained(self).toOpaque())
        }
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        DistributedNotificationCenter.default().removeObserver(self)
        // Cancel an in-flight disable before awaiting UI verification.
        if hasDisabled { recoveryRequested = true; guardProcess.requestRestore() }
        if let evaluation { await evaluation.value }
        if hasDisabled {
            recoveryRequested = true
            guardProcess.requestRestore()
            do { try await transition(on: true) }
            catch { guardProcess.stop(); return false }
        }
        releaseGuard()
        return true
    }

    /// Explicit integration probe; never used during normal launch. It exercises
    /// the same guarded transaction and verification path as the menu switch.
    func hardwareTest() async throws {
        snapshot = try hardware.snapshot()
        guard !snapshot.lidClosed else { throw DisplayFailure.lidClosed }
        guard snapshot.builtInIsOn, snapshot.canDisable else { throw DisplayFailure.noExternal }
        do {
            try await transition(on: false)
            print("PASS: built-in display is offline; external display remains active")
            try await Task.sleep(nanoseconds: 2_000_000_000)
            try await transition(on: true)
            print("PASS: built-in display restored and online")
        } catch {
            guardProcess.requestRestore()
            guardProcess.stop()
            throw error
        }
    }
}

private let displayChanged: CGDisplayReconfigurationCallBack = { displayID, flags, context in
    guard !flags.contains(.beginConfigurationFlag), let context else { return }
    let controller = Unmanaged<DisplayController>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in controller.displaysChanged(displayID: displayID, flags: flags) }
}

#if CONTROLLER_TEST
extension DisplayController {
    func testEvaluate() async {
        requestEvaluation()
        if let evaluation { await evaluation.value }
    }
    func testEmergencyRestore() { emergencyRestore() }
    func testSleep() { prepareForSleep() }
    func testSession(active: Bool) { sessionChanged(active: active) }
    func testLock() { sessionLocked() }
    func testUnlock() { sessionUnlocked() }
    func testScreens(awake: Bool) { screensChanged(awake: awake) }
    func testWake() { activity.setSystemAwake(true, now: recoveryClock()); requestEvaluation() }
    func testFinishSettling() { notBefore = .distantPast }
    var testRecoveryPending: Bool { hasDisabled }
    var testRecoveryRequested: Bool { recoveryRequested }
}
#endif
