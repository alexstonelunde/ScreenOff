import AppKit
import SwiftUI
import Combine
import Darwin
import CoreServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: DisplayController?
    private var contentObservation: AnyCancellable?
    private var settingsWindow: NSWindow?
    private var settingsHost: NSHostingController<SettingsView>?
    private var terminationStarted = false
    private let previewOnly: Bool
    private let restoreOnLaunch: Bool
    private let backgroundLaunch: Bool
    private var launchedAtLogin = false

    static var showSettingsNotification: Notification.Name {
        Notification.Name((Bundle.main.bundleIdentifier ?? "com.gevorg.screenoff") + ".showSettings")
    }

    init(previewOnly: Bool = false, restoreOnLaunch: Bool = false,
         backgroundLaunch: Bool = false) {
        self.previewOnly = previewOnly
        self.restoreOnLaunch = restoreOnLaunch
        self.backgroundLaunch = backgroundLaunch
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAtLogin = Self.isLoginLaunch()
    }

    private static func isLoginLaunch() -> Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = DisplayController(testing: previewOnly, previewOnly: previewOnly)
        self.controller = controller
        contentObservation = controller.objectWillChange
            .debounce(for: .milliseconds(20), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard self?.settingsWindow?.isVisible == true else { return }
                self?.resizeSettingsWindow()
        }
        if !previewOnly {
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(openSettings), name: Self.showSettingsNotification, object: nil)
            // A safe update/recovery launch preserves the saved automatic
            // switch while keeping the panel on until an explicit user choice.
            if restoreOnLaunch { controller.setBuiltIn(on: true) }
            controller.start()
        }
        if !previewOnly && !backgroundLaunch && !launchedAtLogin && !Self.isLoginLaunch() {
            DispatchQueue.main.async { [weak self] in self?.showSettingsWindow() }
        }
    }

    @objc private func openSettings() { showSettingsWindow() }

    private func showSettingsWindow() {
        guard let controller, !terminationStarted else { return }
        if !previewOnly {
            controller.updateLoginNotice()
            controller.requestEvaluation()
        }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(controller: controller,
                                                                  quit: { NSApp.terminate(nil) }))
            host.sizingOptions = [.preferredContentSize]
            settingsHost = host
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 374, height: 300),
                                  styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "ScreenOff"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            // Agent apps can remain outside Stage Manager sets even with a
            // primary window. Hide this short-lived settings UI when another
            // app takes focus; display control keeps running in the background.
            window.hidesOnDeactivate = true
            // Prefer ordinary window management. moveToActiveSpace would
            // explicitly give this window auxiliary behavior in Stage Manager.
            window.collectionBehavior = [.primary, .managed, .fullScreenNone]
            window.contentViewController = host
            settingsWindow = window
            resizeSettingsWindow()
            window.center()
        }
        guard let window = settingsWindow else { return }
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.resizeSettingsWindow() }
    }

    private func resizeSettingsWindow() {
        guard let window = settingsWindow, let host = settingsHost else { return }
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let current = window.contentLayoutRect.size
        guard abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5 else { return }
        let top = window.frame.maxY
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
        window.setFrame(window.constrainFrameRect(window.frame, to: window.screen), display: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationStarted else { return .terminateLater }
        terminationStarted = true
        settingsWindow?.orderOut(nil)
        DistributedNotificationCenter.default().removeObserver(self)
        Task {
            _ = await controller?.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

#if INTERFACE_TEST
extension AppDelegate {
    var testSettingsWindow: NSWindow? { settingsWindow }
}
#else
@main
enum ScreenOffApp {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        let arguments = CommandLine.arguments
        if arguments.contains("--diagnose") {
            let hardware = DisplayHardware()
            do {
                let snapshot = try hardware.snapshot()
                let data = try JSONEncoder().encode(snapshot)
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
                print("ScreenOff \(version) | \(ProcessInfo.processInfo.operatingSystemVersionString)")
                print("Disconnect API: \(hardware.resolvedSymbol ?? "unavailable")")
                print(String(decoding: data, as: UTF8.self))
                exit(hardware.supported ? 0 : 2)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        if arguments.contains("--recover") {
            guard let executable = Bundle.main.executableURL?
                .deletingLastPathComponent().appendingPathComponent("ScreenOffWatchdog") else {
                fputs("The recovery helper could not be located.\n", stderr)
                exit(1)
            }
            let result = RecoveryCommand(executable: executable).run(notify: {
                DistributedNotificationCenter.default().postNotificationName(
                    DisplayController.recoverNotification, object: nil, userInfo: nil, deliverImmediately: true)
            }, ownerIsRunning: {
                // Let a running UI app and its helper own display transactions.
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.gevorg.screenoff").contains {
                    $0.processIdentifier != getpid() && !$0.isTerminated
                }
            })
            print(result.message)
            exit(result == .restored ? 0 : 1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if arguments.contains("--hardware-test") {
            Task { @MainActor in
                let controller = DisplayController(testing: true)
                do {
                    try await controller.hardwareTest()
                    exit(0)
                } catch {
                    fputs("FAIL: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            app.run()
            return
        }
        // A second launch should open the existing settings window, never compete over
        // display state or start a second automation controller.
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != getpid() }) {
            DistributedNotificationCenter.default().postNotificationName(
                AppDelegate.showSettingsNotification, object: nil, userInfo: nil, deliverImmediately: true)
            other.activate(options: [])
            return
        }
        let delegate = AppDelegate(restoreOnLaunch: arguments.contains("--restore-on-launch"),
                                   backgroundLaunch: arguments.contains("--background"))
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
