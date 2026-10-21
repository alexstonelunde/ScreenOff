# Architecture

ScreenOff is a macOS accessory application with one reusable settings window. It creates no status or Dock item and has no package dependency, network client, telemetry, privileged service or system extension.

## Display control and process boundaries

There are two long-lived executables and a short-lived transaction process:

- `DisplayController` owns the preference, SwiftUI state, display policy and login registration. It reads topology, requests changes through `RecoveryGuard`, and verifies the result. It never executes a display-configuration transaction, including during error handling, sleep, quit and CLI recovery.
- `RecoveryGuard` starts `ScreenOffWatchdog`, requires a READY response before requesting a disable, and sends a main-run-loop heartbeat every second. It remembers a positively identified built-in display for recovery-only handoff. A retired supervisor must finish before another can start.
- `ScreenOffWatchdog` is the durable rescue supervisor. Its main run loop processes IPC, lock/session events, display/system sleep, and an independent IOKit lid check every 750 ms. Read-only WindowServer queries run on a separate serial queue; a slow query cannot block lid events or worker cancellation.
- `DisplayTransaction` starts a child using the same helper executable's `--transaction` mode. Only this disposable process calls the private configuration API. A three-second deadline kills and reaps a stuck child. Sleep or lid closure can cancel it earlier. The supervisor itself is never killed to cancel a transaction, and a new child cannot start before its predecessor is reaped.
- `WatchdogSupervisor` contains the testable recovery state machine. Recovery remains armed until two separated observations confirm an online, active built-in display with the lid open.

The private anonymous pipe protocol uses byte 1 for heartbeat, 2 for restore, and 3 for disable. Restore wins if both commands arrive together. EOF, parent death, eight awake seconds without heartbeat, loss of console ownership, lid closure, or removal of a protected external requests recovery. Locking the same user’s console preserves the lease. A completed disable also survives sleep; an interrupted transaction requests rollback. Pipe EOF cancels its read source and does not spin. A separate private pipe supplies a JSON request to each transaction child. No sockets, elevated helpers or permanent launch daemons are installed.

## Lock, sleep and recovery

Locking with Touch ID no longer requests restoration solely because the screen is locked. Both the controller and supervisor check the console’s owner UID and on-console flag separately from the lock flag. Only this user’s console can authorize disabling, including at the lock screen. Switching users or losing console ownership still requests recovery. The OFF preference and its independent recovery lease remain intact while locked.

Display sleep and system sleep preserve a confirmed disable and suspend configuration attempts. They cancel an in-flight transaction with rollback responsibility, without blocking the event loop. Lid closure also requests recovery, deferred until reopening. IOKit lid sensing does not require a responsive WindowServer connection. Opening the lid independently rearms recovery, even without AppKit wake/unlock events. The transaction child independently rechecks the lid and display sleep state before configuring anything; disabling additionally requires the same user’s on-console session; it may be locked.

A timed-out transaction is **not retried continuously**. The supervisor retains its recovery obligation but waits for a real lid, sleep/wake, session or external-topology transition before trying again. Duplicate notifications and repeated restore commands cannot renew this permission. A worker that observes sleep before the supervisor similarly defers until a transition. Ordinary nonblocking errors have a two-second cooldown. A successful enable waits for fresh verification rather than repeatedly spawning children if a read-only query is stuck.

Each transaction captures the activity epoch at launch. If a qualifying transition grants a new retry before the previous child's completion is delivered, that older completion cannot reinstate its timeout/deferred inhibition or overwrite the newer retry deadline. The previous child still has to exit before a replacement starts, and a replacement's own failure can inhibit further attempts. Successful restoration still requires fresh verification.

`SessionResumeState` separates console availability, screen sleep, system sleep and lid state. After an unavailable-to-available console cycle, the UI waits for restoration, an available external, the previous helper's exit, and two seconds of settling before reapplying the saved preference. A retained lease stays armed through lock and sleep. Duplicate wake events do not repeatedly clear failure inhibition. Manual recovery holds retain priority. An external topology change or explicit user choice can also reapply the preference.

A positive system-wake or screen-wake event reconciles both awake flags, including when its own flag was already awake but the other dimension still recorded sleep. The watchdog runtime also resumes its heartbeat lease and invalidates older query replies for that reconciliation. Wholly unchanged duplicates remain no-ops; polling the same console owner does not itself wake sleeping state. Explicit UI recovery uses the same system-wake reconciliation while retaining its manual recovery hold and the lid/console safeguards.

Lock/unlock uses the distributed `com.apple.screenIsLocked` and `com.apple.screenIsUnlocked` notifications. Workspace sleep/wake and user-session changes are separate observations. The controller's existing two-second evaluation and the helper's asynchronous queries read `CGSessionCopyCurrentDictionary` as a missed-event fallback. Lock notification names and the runtime lock key are undocumented details. See [Apple's screen-wake notification](https://developer.apple.com/documentation/appkit/nsworkspace/screensdidwakenotification) and the notification registrations in [Hammerspoon](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/caffeinate/libcaffeinate_watcher.m).

## Hardware boundary

1. Enumerate online and software-disabled displays. Prefer a currently identified built-in ID. Remember positively identified panel information in memory and pass it to the transaction process.
2. `BuiltInRecoveryTarget` allows the remembered ID only for enabling a missing panel, with the lid open and no usable external. Refuse an ID currently assigned to another display. A fresh built-in ID always wins. Never disable using the fallback.
3. Before disabling, require an active external, open lid, same user’s on-console session (locked or unlocked), and no mirroring. Unknown lid state is unsafe. Recheck lid state immediately before the transaction and defer if all online displays are asleep.
4. Dynamically resolve `SLSConfigureDisplayEnabled` / `CGSConfigureDisplayEnabled`. Begin, configure and complete the change in the disposable worker; cancel a configuration that fails before commit.
5. Disable using `forAppOnly`; enable using `forSession`, so restoration survives the recovery process's exit. Neither path uses `permanently`. Brightness, gamma, resolutions, mirroring relationships and external enabled flags are unchanged.
6. Verify topology independently. Function return codes alone never confirm recovery. A failed or partly applied disable retains the rescue obligation.

**Process exit is not a recovery mechanism.** An open-lid hardware probe on the affected macOS build showed that exiting the process that committed a private `forAppOnly` disable did not restore the panel. The implementation therefore always retains an independent enable/recovery path. Apple documents application-scoped lifetime for public display configuration, but that did not establish rollback for this private operation on the tested system.

## Interface and energy

`SettingsView` has one positive preference: ON uses both displays, OFF automatically disables the built-in with an external. It is the inverse of the existing `automaticDisplayOff` default, so earlier preferences are preserved. The obsolete `hideStatusItem` default is ignored. Automatic mode uses `SMAppService.mainApp` login registration.

`AppDelegate` creates one reusable window. Spotlight/Finder reopening returns to that window and process. Closing it leaves display control running. Foreground launches open settings; login launches and `--background` stay quiet. The window fits its content and is constrained to the screen. `LSUIElement` and the accessory activation policy prevent a Dock icon; no status item exists.

The window uses `primary`, `managed`, `fullScreenNone` and `hidesOnDeactivate`. It hides when another application takes focus, including a Stage Manager group switch. This also applies outside Stage Manager; it is automatic dismissal of an accessory window, not a claim of ordinary Stage Manager group membership. See [Apple's Stage Manager overview](https://developer.apple.com/videos/play/wwdc2022/10074/) and [hidesOnDeactivate](https://developer.apple.com/documentation/appkit/nswindow/hidesondeactivate).

Unchanged topology and notices do not publish SwiftUI updates. Closed-lid waiting has no progress animation. Window sizing is coalesced and skipped for invisible windows. Controller, heartbeat and helper timers allow coalescing. The helper does not query WindowServer or create transaction processes while it knows the lid is closed or the displays/system are asleep. There are no sleep-prevention assertions and no changes to the user's power settings.

## Limitations

Online/active state indicates a display link, not that a person can see the monitor. Some docks and monitors on another input keep reporting an active link. Entries without vendor/model identity and the observed `unkn`/`virt` headless placeholder (vendor `0x756E6B6E`, model `0x76697274`) cannot authorize disabling. Other virtual displays that present hardware identity may still count as external.

Apple does not publish the display-disconnect API. Symbol availability does not prove ABI compatibility. A bounded client process prevents an indefinite client-side call and CPU loop; it cannot guarantee recovery from a failure inside WindowServer, the kernel or display firmware. Physical closed-lid behavior remains controlled by macOS. A successful topology check is not an electrical power measurement. See [Verification](Verification.md) for the exact tested scenarios and remaining physical-validation limits.

## CLI

- `--diagnose`: read-only OS, symbol availability and topology JSON.
- `--recover`: asks an existing UI to hold the panel on, then observes recovery within one monotonic twelve-second budget. All display snapshots, including the initial seed observation, run in disposable `ScreenOffWatchdog --snapshot` children. Nonblocking output collection and child-exit polling are bounded by the remaining budget; a stalled reader can be killed without waiting for its WindowServer query. If no UI owns recovery, the command requests a restore-only supervisor with an early acceptance acknowledgement before hardware queries. That accepted supervisor remains responsible after the CLI exits and exposes no disable-command channel. The CLI never configures displays directly and does not kill the durable supervisor to cancel an observation. `--diagnose` remains a separate synchronous read-only command.
- `--hardware-test`: explicitly exercises the same supervised disable/enable path with an open lid and active external. Quit the ordinary app first.
- `--restore-on-launch`: temporary manual-on hold that preserves the saved preference until the next explicit mode selection.
- `--background`: suppresses only the initial settings window.

## Persistent display-role overrides

`DisplayRoleController` reads connected external vendor/product IDs and saved recovery records. `DisplayRoleSettingsView` groups identical models, shows pending restart status using `kern.boottime`, and keeps disconnected recovery targets available. Test/preview instances show a disabled fixture and never request administrator approval. The UI reports configuration, not verified Night Shift output.

A separate ad-hoc signed `ScreenOffDisplayRole` executable performs one explicit administrator operation through macOS’s `do shell script … with administrator privileges` prompt. It accepts only an action and numeric vendor/product IDs, derives all paths internally, and validates that exclusion targets a connected external model. It neither calls the display-disabling API nor installs a daemon. Restore uses the saved model record and supports disconnected monitors.

The helper rejects symlinks, non-root-owned or group/world-writable directories/files, and multiply linked files. A nonblocking file lock serializes operations. Plist replacement is atomic. Before applying an exclusion, the helper records the original dictionary; a failed apply can be retried without replacing the original. Restore changes only the role and identity fields added by ScreenOff, preserves later unrelated edits, and refuses conflicting role changes. Records remain after restoration to retain restart status and support interrupted operations. The helper requires root ownership but never accepts an arbitrary source file or destination path.

Role overrides are persistent and may affect True Tone and other behavior governed by the television role. They do not participate in the built-in display watchdog or login registration. Exiting the app does not restore an override; the user restores it explicitly before uninstalling.

## Sleep preservation and wake observations

System sleep pauses the heartbeat lease. A genuine wake grants the parent the normal eight seconds to send a fresh heartbeat; duplicate wake callbacks do not reset this deadline. Parent death and pipe EOF remain recovery triggers during sleep. An in-flight display query keeps its single-reader ownership but receives the normal timeout from wake; a sleep gap alone does not count as a stalled WindowServer read.

Display-query replies carry the supervisor transaction generation and an activity generation. Replies from before a sleep/wake or lid transition are discarded, so a stale asleep topology cannot authorize a new disable or falsely trigger unplug recovery. Removal callbacks during known display/system sleep are validated by fresh topology after wake. Awake external removal still requests recovery immediately.

The supervisor remembers whether a disable was actually observed. Reapplying requires a previously confirmed lease and a fresh, active built-in panel with the original protected external still present. An API success without observed disabling requests recovery instead of spawning repeated disable calls. Missing built-in enumeration with a still-active protected external can retain the lease; recovery still uses the remembered panel ID after unplug. macOS controls panel activation during wake, so absence of a visible flash requires hardware verification.
