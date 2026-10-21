import AppKit
import CoreGraphics
import Darwin

/// All access to the mutable hardware cache is confined to this serial queue.
private final class DisplayQuerySource: @unchecked Sendable {
    private let hardware: DisplayHardware
    private let queue = DispatchQueue(label: "com.gevorg.screenoff.display-queries", qos: .utility)
    init(seed: DisplayInfo?) { hardware = DisplayHardware(recoverySeed: seed) }
    func read(_ completion: @escaping @Sendable (DisplaySnapshot?, Bool?) -> Void) {
        queue.async {
            completion(try? self.hardware.snapshot(), DisplayEnvironment.sessionAvailable())
        }
    }
}

@MainActor
final class WatchdogRuntime: NSObject {
    let parent: Int32
    private let transaction: DisplayTransaction
    private let seed: DisplayInfo?
    private let queries: DisplayQuerySource
    private var supervisor: WatchdogSupervisor?
    private var reader: DispatchSourceRead?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var pendingRestore: Bool
    private var heartbeatLease = WatchdogHeartbeat(now: ProcessInfo.processInfo.systemUptime)
    private var pipeOpen = true
    private var queryStarted: TimeInterval?
    private var screensAwake = true
    private var systemAwake = true
    private var sessionActive = true
    private var protectedIDs: Set<UInt32> = []
    private var previousLid: Bool?
    private var activityGeneration = 0

    init(parent: Int32, restoring: Bool, seed: DisplayInfo?) {
        self.parent = parent
        self.pendingRestore = restoring
        self.seed = seed
        self.queries = DisplayQuerySource(seed: seed)
        self.transaction = DisplayTransaction(executable: URL(fileURLWithPath: CommandLine.arguments[0]))
    }

    func start(acceptingCommands: Bool = true) {
        observeActivity()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard CGDisplayRegisterReconfigurationCallback(displayChanged, context) == .success else { exit(69) }
        if acceptingCommands {
            let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
            source.setEventHandler { [weak self] in self?.readCommands() }
            source.resume()
            reader = source
        } else {
            // Detached CLI recovery has no command channel and can only restore.
            pipeOpen = false
            restore()
        }
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        query()
    }

    private func readCommands() {
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = read(STDIN_FILENO, &bytes, bytes.count)
        if count > 0 {
            let commands = bytes.prefix(count)
            if commands.contains(1) { heartbeatLease.receive(now: ProcessInfo.processInfo.systemUptime) }
            // Recovery always wins when both requests arrive together.
            if commands.contains(2) { restore() }
            if commands.contains(3) && !pendingRestore { supervisor?.requestDisable() }
        } else if count == 0 || errno != EINTR {
            pipeOpen = false
            reader?.cancel()
            restore()
        }
        tick()
    }

    private func restore() { pendingRestore = true; supervisor?.requestRestore() }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let lid = DisplayEnvironment.lidClosed()
        if previousLid == true && lid == false {
            screensAwake = true
            systemAwake = true
            resumed()
        }
        if previousLid != lid { activityGeneration += 1 }
        previousLid = lid
        supervisor?.lidChanged(closed: lid)
        if getppid() != parent || kill(parent, 0) != 0 || !pipeOpen || heartbeatLease.expired(now: now) {
            restore()
        }
        if screensAwake && systemAwake, let started = queryStarted, now - started > 4 { restore() }
        // An unknown lid state fails closed. No WindowServer query or change
        // is necessary during clamshell/display/system sleep.
        if lid == false && screensAwake && systemAwake { query() }
        supervisor?.tick()
    }

    private func query() {
        guard queryStarted == nil, !transaction.isRunning else { return }
        queryStarted = ProcessInfo.processInfo.systemUptime
        let generation = supervisor?.generation ?? 0
        let activity = activityGeneration
        queries.read { [weak self] state, active in
            DispatchQueue.main.async {
                guard let self else { return }
                self.queryStarted = nil
                guard activity == self.activityGeneration, self.screensAwake, self.systemAwake,
                      DisplayEnvironment.lidClosed() == false else { self.tick(); return }
                if self.supervisor == nil {
                    guard let state else { exit(69) }
                    self.protectedIDs = Set(state.externalDisplays.map(\.id))
                    self.supervisor = WatchdogSupervisor(snapshot: state, worker: self.transaction,
                        seed: self.seed, restored: { exit(0) })
                    self.sessionActive = active == true
                    self.supervisor?.sessionChanged(active: self.sessionActive)
                    self.supervisor?.screensChanged(awake: self.screensAwake)
                    self.supervisor?.systemChanged(awake: self.systemAwake)
                    if self.pendingRestore { self.supervisor?.requestRestore() }
                    // A closed reply pipe must not crash a still-needed rescue
                    // process after its parent's startup deadline expires.
                    _ = Array("READY\n".utf8).withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
                } else if generation == self.supervisor?.generation && !self.transaction.isRunning,
                          self.screensAwake && self.systemAwake, DisplayEnvironment.lidClosed() == false {
                    let available = active == true
                    if available != self.sessionActive {
                        self.sessionActive = available
                        self.supervisor?.sessionChanged(active: available)
                        if available { self.screensAwake = true; self.systemAwake = true; self.resumed() }
                        else { self.restore() }
                    }
                    self.supervisor?.observe(state)
                }
                self.supervisor?.lidChanged(closed: DisplayEnvironment.lidClosed())
                self.supervisor?.tick()
            }
        }
    }

    func displayRemoved(_ id: UInt32) {
        // Sleeping links may disappear temporarily; validate them on wake.
        guard screensAwake, systemAwake else { return }
        if protectedIDs.contains(id) { restore(); supervisor?.externalRemoved() }
    }

    private func observeActivity() {
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, awake) in [(NSWorkspace.screensDidSleepNotification, false),
                              (NSWorkspace.screensDidWakeNotification, true)] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let waking = awake && (!self.screensAwake || !self.systemAwake)
                    if awake != self.screensAwake || waking { self.activityGeneration += 1 }
                    self.screensAwake = awake
                    if awake { self.systemAwake = true }
                    if waking { self.resumed() }
                    self.supervisor?.screensChanged(awake: awake)
                    self.tick()
                }
            })
        }
        for (name, awake) in [(NSWorkspace.willSleepNotification, false),
                              (NSWorkspace.didWakeNotification, true)] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let waking = awake && (!self.systemAwake || !self.screensAwake)
                    if awake != self.systemAwake || waking { self.activityGeneration += 1 }
                    self.systemAwake = awake
                    self.heartbeatLease.systemChanged(awake: awake, now: ProcessInfo.processInfo.systemUptime)
                    if awake { self.screensAwake = true }
                    if waking { self.resumed() }
                    self.supervisor?.systemChanged(awake: awake)
                    self.tick()
                }
            })
        }
        for name in [NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.consoleChanged() }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(locked), name: Notification.Name("com.apple.screenIsLocked"),
                                object: nil, suspensionBehavior: .deliverImmediately)
        distributed.addObserver(self, selector: #selector(unlocked), name: Notification.Name("com.apple.screenIsUnlocked"),
                                object: nil, suspensionBehavior: .deliverImmediately)
    }

    private func resumed() {
        let now = ProcessInfo.processInfo.systemUptime
        heartbeatLease.systemChanged(awake: true, now: now)
        // A read suspended by sleep is still the sole in-flight read. Grant it
        // the normal deadline after wake, rather than declaring a sleep gap a hang.
        if queryStarted != nil { queryStarted = now }
    }

    private func consoleChanged() {
        let confirmed = DisplayEnvironment.sessionAvailable() ?? false
        let returning = confirmed && !sessionActive
        sessionActive = confirmed
        supervisor?.sessionChanged(active: confirmed)
        if returning { screensAwake = true; systemAwake = true; resumed() }
        if !confirmed { restore() }
        tick()
    }
    @objc private func locked() { consoleChanged() }
    @objc private func unlocked() { consoleChanged() }
}

private let displayChanged: CGDisplayReconfigurationCallBack = { id, flags, context in
    guard let context, !flags.contains(.beginConfigurationFlag),
          !flags.intersection([.removeFlag, .disabledFlag]).isEmpty else { return }
    let runtime = Unmanaged<WatchdogRuntime>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in runtime.displayRemoved(id) }
}

@main
enum WatchdogApp {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        let arguments = CommandLine.arguments
        guard arguments.count >= 3, let parent = Int32(arguments[2]), parent > 1,
              getppid() == parent else { exit(64) }
        // Read-only probes run in a disposable process, including the first
        // recovery observation. No WindowServer query executes in the CLI parent.
        if arguments[1] == "--snapshot" || arguments[1] == "--restore-watch" {
            guard let request = RecoveryHelperRequest.parse(Array(arguments.dropFirst()), parent: getppid()) else { exit(64) }
            switch request {
            case .snapshot:
                do {
                    let data = try JSONEncoder().encode(DisplayHardware().snapshot())
                    try FileHandle.standardOutput.write(contentsOf: data)
                    exit(0)
                } catch { exit(1) }
            case .restore(let seed):
                let app = NSApplication.shared
                app.setActivationPolicy(.prohibited)
                let runtime = WatchdogRuntime(parent: parent, restoring: true, seed: seed)
                // Ownership and the enable-only obligation are established before
                // acknowledging. The following startup/query may block, but the
                // supervisor survives closed pipes and the CLI's bounded exit.
                _ = RecoveryProcess.acceptance.withUnsafeBytes {
                    Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count)
                }
                runtime.start(acceptingCommands: false)
                withExtendedLifetime(runtime) { app.run() }
                return
            }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        if arguments[1] == "--transaction" {
            guard arguments.count == 3 else { exit(64) }
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard input.count < 16_384, let request = try? JSONDecoder().decode(DisplayTransactionRequest.self, from: input)
            else { exit(64) }
            DispatchQueue.main.async {
                do {
                    let hardware = DisplayHardware(recoverySeed: request.lastKnownBuiltIn)
                    try hardware.setBuiltIn(on: request.on, recovery: request.on)
                    exit(0)
                } catch DisplayFailure.lidClosed { exit(75) }
                  catch DisplayFailure.displaysAsleep { exit(75) }
                  catch DisplayFailure.sessionInactive { exit(75) }
                  catch { exit(1) }
            }
            app.run()
            return
        }
        guard arguments[1] == "--watch" else { exit(64) }
        var restoring = false
        var seed: DisplayInfo?
        var index = 3
        while index < arguments.count {
            if arguments[index] == "--restore" { restoring = true }
            else if arguments[index] == "--seed", index + 1 < arguments.count,
                    let data = Data(base64Encoded: arguments[index + 1]),
                    let decoded = try? JSONDecoder().decode(DisplayInfo.self, from: data), decoded.builtIn {
                seed = decoded
                index += 1
            } else { exit(64) }
            index += 1
        }
        let runtime = WatchdogRuntime(parent: parent, restoring: restoring, seed: seed)
        runtime.start()
        withExtendedLifetime(runtime) { app.run() }
    }
}
