import Foundation

/// Durable rescue state, independent of every synchronous WindowServer call.
/// A timeout stops automatic retries until a real wake/lid/topology change.
@MainActor
final class WatchdogSupervisor {
    private let worker: any DisplayTransactionRunning
    private let clock: () -> TimeInterval
    private let restored: () -> Void
    private(set) var snapshot: DisplaySnapshot
    private var seed: DisplayInfo?
    private let protectedExternals: Set<String>
    private(set) var recoveryRequested = false
    private(set) var hasDisabled = false
    private(set) var generation = 0
    private(set) var retryBlocked = false
    private var retryAt: TimeInterval = -.infinity
    private var activityEpoch = 0
    private var workerEnabling = false
    private var consecutiveRestored = 0
    private var lastConfirmation: TimeInterval = -.infinity
    private var lidClosed: Bool?
    private var sessionActive = true
    private var screensAwake = true
    private var systemAwake = true
    private var snapshotAfterTransaction = true
    private var awaitingVerification = false
    private var disabledConfirmed = false

    init(snapshot: DisplaySnapshot, worker: any DisplayTransactionRunning, seed: DisplayInfo? = nil,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         restored: @escaping () -> Void) {
        self.snapshot = snapshot
        self.seed = snapshot.builtIn ?? seed
        self.protectedExternals = snapshot.externalIdentities
        self.lidClosed = snapshot.lidClosed
        self.worker = worker
        self.clock = clock
        self.restored = restored
    }

    func requestDisable() {
        // Repeated IPC and wake observations must not overlap a child or
        // renew a failed transaction. A confirmed lease may be reapplied.
        guard !worker.isRunning, !retryBlocked, !awaitingVerification, clock() >= retryAt else { return }
        if hasDisabled && (!snapshotAfterTransaction || !disabledConfirmed || !snapshot.builtInIsRestored) { return }
        guard !recoveryRequested,
              lidClosed == false, sessionActive, screensAwake, systemAwake,
              snapshot.builtInIsRestored, snapshot.canDisable else {
            requestRestore()
            return
        }
        hasDisabled = true // A failed or cancelled call may partially apply.
        launch(on: false)
    }

    func requestRestore() {
        recoveryRequested = true
        if worker.isRunning && !workerEnabling { worker.cancel() }
    }

    func sessionChanged(active: Bool) {
        guard sessionActive != active else { return }
        sessionActive = active
        if active {
            systemAwake = true
            screensAwake = true
            allowRetry()
        } else { requestRestore() }
    }

    func screensChanged(awake: Bool) {
        guard screensAwake != awake || awake && !systemAwake else { return }
        screensAwake = awake
        if awake { systemAwake = true; allowRetry() }
        else { suspend(recover: false) }
    }

    func systemChanged(awake: Bool) {
        guard systemAwake != awake || awake && !screensAwake else { return }
        systemAwake = awake
        if awake { screensAwake = true; allowRetry() }
        else { suspend(recover: false) }
    }

    func lidChanged(closed: Bool?) {
        guard lidClosed != closed else { return }
        lidClosed = closed
        if closed == false {
            // Opening the physical lid is an independent wake indication even
            // when AppKit failed to deliver sleep/wake notifications.
            systemAwake = true
            screensAwake = true
            allowRetry()
        } else { suspend(recover: true) }
    }

    func externalRemoved() {
        requestRestore()
        // Repeated removal callbacks must not renew a timed-out transaction.
    }

    func observe(_ state: DisplaySnapshot?) {
        guard let state else { requestRestore(); return }
        if state.externalIdentities != snapshot.externalIdentities { allowRetry() }
        snapshot = state
        snapshotAfterTransaction = true
        awaitingVerification = false
        if let panel = state.builtIn { seed = panel }
        lidChanged(closed: state.lidClosed)
        if hasDisabled && protectedExternals.isDisjoint(with: state.externalIdentities) {
            requestRestore()
        }
        if hasDisabled && !worker.isRunning {
            if state.builtInIsOn && !disabledConfirmed { requestRestore() }
            if state.builtIn != nil && !state.builtInIsOn { disabledConfirmed = true }
        }
        if recoveryRequested && !worker.isRunning && state.builtInIsRestored {
            if clock() - lastConfirmation >= 0.4 {
                consecutiveRestored += 1
                lastConfirmation = clock()
            }
            if consecutiveRestored >= 2 { restored() }
        } else { consecutiveRestored = 0 }
    }

    func tick() {
        // If macOS reactivates the panel on wake, reapply through the same
        // bounded transaction while the protected external is still usable.
        if hasDisabled, !recoveryRequested, sessionActive, screensAwake, systemAwake,
           lidClosed == false, snapshotAfterTransaction, snapshot.canDisable,
           snapshot.builtInIsRestored, !protectedExternals.isDisjoint(with: snapshot.externalIdentities) {
            requestDisable()
        }
        guard recoveryRequested, !worker.isRunning, lidClosed == false,
              screensAwake, systemAwake, !retryBlocked, !awaitingVerification, clock() >= retryAt,
              !(snapshotAfterTransaction && snapshot.builtInIsRestored) else { return }
        launch(on: true)
    }

    private func suspend(recover: Bool) {
        // A confirmed disable survives sleep. An interrupted transaction has
        // uncertain effects and must retain rollback responsibility.
        if recover || worker.isRunning { recoveryRequested = true }
        // Sleep can interrupt an enable too. Stop only the disposable worker;
        // this supervisor and its remembered target survive until actual wake.
        if worker.isRunning { worker.cancel() }
    }

    private func allowRetry() {
        activityEpoch += 1
        retryBlocked = false
        awaitingVerification = false
        retryAt = clock() + 0.5
    }

    private func launch(on: Bool) {
        let launchedEpoch = activityEpoch
        workerEnabling = on
        if !on { disabledConfirmed = false }
        snapshotAfterTransaction = false
        generation += 1
        do {
            try worker.start(DisplayTransactionRequest(on: on, lastKnownBuiltIn: seed)) { [weak self] result in
                guard let self else { return }
                self.generation += 1
                // A wake/lid/topology transition can arrive before the cancelled
                // child is reaped. Its newer retry permission must survive the
                // old child's result, including its cooldown and timeout block.
                if self.activityEpoch == launchedEpoch {
                    self.retryAt = self.clock() + (result == .cancelled || !on && result == .completed ? 0 : 2)
                    if result == .timedOut || result == .deferred {
                        self.retryBlocked = true
                    }
                }
                self.awaitingVerification = on && result == .completed
                if result != .completed || !on && self.recoveryRequested {
                    self.requestRestore()
                }
            }
        } catch {
            requestRestore()
            retryBlocked = true
        }
    }
}
