# Verification

## Automated checks

`bash Scripts/test.sh` runs 271 checks: 54 policy/lease checks, 168 controller and recovery-target checks with simulated hardware, 38 checks of the production supervisor, and 11 checks of real subprocess timeout, cancellation, serialization and restart. The subprocess fixture imports no AppKit or CoreGraphics and cannot change a display. Old synchronous-watchdog tests were replaced by supervisor/process-boundary tests; the controller uses an explicitly named recovery simulation.

`bash Scripts/build.sh` compiles both executables, produces the icon and app bundle, verifies the code signature with `codesign --verify --deep --strict`, and lints Info.plist.

## Version 1.3.2: lock, closed lid and unplug recovery

The user reported: external connected, built-in disabled, Touch ID lock, lid closed, external disconnected, then no usable wake and a forced reset. Reports on the affected M1 MacBook Pro (macOS 27 beta, build 26A5425a) record two button resets. This does not establish a kernel panic.

Local unified logs captured a **single** recovery helper entering `SLSCompleteDisplayConfigurationWithOption` after display-sleep notifications and emitting roughly 1.45 million messages waiting for a previous reconfiguration across two helper instances. Therefore the 1.3.1 rule excluding concurrent main/helper enables did not bound a system call inside one helper. Its blocked main run loop could not process its pipe or lid/wake events.

Version 1.3.2 requests restoration as soon as the session locks. The main app and durable helper never execute a configuration transaction; a disposable child does, with a three-second deadline. Sleep/lid transitions can cancel that child while the supervisor retains the verified panel ID. A timed-out call waits for a real activity/topology transition before retrying. Closed-lid and sleeping-display waiting sends no configuration commands. Read-only helper queries are separated from its event loop. The old synchronous CLI/UI fallback was removed too.

The production supervisor tests cover the exact event order with both prompt and stuck restoration, closing the lid during a transaction, reaping before replacement, a missing/headless panel after unplug, reopening without AppKit wake/unlock callbacks, cached target handoff, eight hours with the lid closed, and eight hours of duplicate callbacks after a timeout. Real subprocess checks prove a deliberately non-returning child is killed/reaped and a subsequent recovery child can run. All 271 checks pass. These are simulations and process-liveness checks, not a physical forced-reset reproduction.

A separate guarded hardware probe tested whether process exit could undo a private application-scoped disable. With an open lid and active external, the panel was disabled, its owner exited, and the panel did **not** return within the observation window. Explicit open-lid recovery succeeded. That rejected mechanism is not used by this release.

The initial 1.3.2 guarded hardware check refused to disable because both physical displays were online but inactive/asleep. After the user unlocked the desktop with the lid open and external connected, the installed app passed the production guarded off/on check: the panel became offline with the external active, then returned online. A separate physical test sent disable through the supervisor, closed its heartbeat pipe and confirmed independent restoration while the parent remained alive. Restore command, EOF and restore-only startup also passed with the built-in already on. All 15 native interface checks passed, and GitHub CI passed on macOS 15.

The 1.3.2 app is installed; both executable hashes match the signed package and the saved automatic preference is preserved. DMG verification and ZIP integrity checks passed. Automatic operation resumed after the ordinary hardware checks; read-only diagnostics confirmed built-in OFF with one active external. The README screenshot is unchanged.

**Owner follow-up, September 9, 2026:** after installing ScreenOff 1.3.2, the owner confirmed that the fix worked and the reported wake failure was resolved. The owner also merged PR #5. This is user-reported validation on the affected Mac. The earlier read-only lock observer reached its deadline without recording a lock transition, so no instrumented replay of the complete lock → close lid → unplug sequence is claimed. The automated and separately observed open-lid checks remain documented above.

## Version 1.3.1: avoid overlapping recovery configurations

The user reported a 12-hour Energy Impact value of 456.11 after leaving the Mac with its lid closed for several hours. The installed 1.3.0 main process had accumulated 36 minutes 42.64 seconds of CPU time in approximately 4 hours 29 minutes. A later five-second sample showed it mostly idle; current idle behavior did not explain the earlier accumulated work.

A system resource report captured both the 1.3.0 main process and its helper inside `DisplayHardware.setBuiltIn` and `SLSCompleteDisplayConfigurationWithOption`. The main process was reached through both recovery transition and failure handling. Its unified log contained 195,382 “Waiting for previous reconfig to complete” messages. These observations identified overlapping recovery calls during display reconfiguration, a path the earlier single-process callback-loop test did not exercise.

Restoration is now delegated to the live or retiring helper. The main app observes completion and attempts local recovery only if no helper owns it and replacement startup fails. Sleep handling and quit also delegate; restore commands are sent at most once per helper. Closed-lid recovery issues zero configuration commands, with another lid check at the hardware boundary. Lid reopening creates a settling/resume opportunity even if the Mac never slept. The CLI recovery command observes an existing owner before attempting standalone recovery.

All 357 policy/controller/recovery checks pass, including stalled-helper ownership, repeated removal events, retiring-helper exclusion, fallback recovery, shutdown handoff, a simulated eight-hour closed lid and reopening without sleep notifications. The two-second night probe reports zero enable calls and two UI publications. All 15 native window checks also passed.

The new delegated recovery path passed a physical guarded disable/enable test on the target Mac: the built-in display became offline with the external active, then returned online. The helper also passed restore-command, pipe-EOF and restore-argument integration checks with the built-in already active. The final build includes an additional simulated regression for lid reopening without system sleep. These are bounded checks, not a full overnight energy measurement.

The installed 1.3.1 executables match the packaged binaries and the saved automatic preference remains enabled. The existing README screenshot is preserved.

**Physical closed-lid follow-up passed in the installed 1.3.1 app.** With the external monitor connected and active, the user closed the lid and later reopened it. During 108.60 measured closed-lid seconds, the main process and helper accumulated 0.14 CPU seconds in total: approximately 0.129% of one CPU. Four-second samples of each process were dominated by run-loop waiting and contained no display-configuration frames. A targeted unified-log query found none of the previous reconfiguration-wait messages in the new processes.

After reopening, the original helper exited, a new helper armed, and read-only diagnostics confirmed the built-in display offline/inactive with one external active, matching the saved OFF preference. This was a short physical lid-close/open check with an awake external display, not a full night with the external display asleep and not a measurement of battery wattage.

## Version 1.3.0: English interface and documentation

All 330 policy/controller/recovery checks and all 15 native interface checks pass after translating application text. Display-control behavior, recovery, login preferences and window lifecycle are unchanged. The interface harness uses isolated preview applications and performs no physical display transactions. No new physical cable-removal or lock/unlock test is claimed for this translation update.

The app declares English as its development region and only supported localization. Settings, status and error messages, login instructions, tooltips and accessibility labels are in English. The installation guide, current documentation, historical release-note documents and contribution templates were translated. Packaging creates fresh app and DMG staging directories so obsolete resources cannot survive a rebuild.

The current project audit found no Cyrillic characters in 52 text files or their filenames. The native settings screenshot was regenerated and visually inspected. The installed app's accessibility tree exposed English labels for the laptop image, single display switch, status, quit button and help, along with English native window controls.

The signed 1.3.0 app replaced the entire installed bundle after the old app and recovery helper exited normally. Both installed executable hashes match the packaged app; the saved automatic preference remained enabled (the positive UI switch remained off). Code-signature verification, DMG checksum and ZIP integrity checks passed. Bundle resources and ZIP contents contain the English installation guide with no obsolete language resource; DMG staging contains “Read Before Installing.txt.” Historical Git commits and older release archives are preserved; English app downloads start with 1.3.0.

## Version 1.2.2: dismiss settings when switching applications

The user reported that the accessory app's settings window remained on screen when switching Stage Manager groups. The first installed candidate (1.2.1, not published) removed `moveToActiveSpace` and unconditional front ordering, and set `primary`, `managed`, and `fullScreenNone`. The user confirmed that this alone did not fix the issue. Stage Manager was enabled on the target Mac.

Version 1.2.2 additionally uses native `hidesOnDeactivate`. Settings is removed from the screen when another application becomes active; this also applies to ordinary focus changes, including within a Stage Manager group. Reopening through Spotlight/LaunchServices restores the same window. This is automatic dismissal of the accessory window, not normal Stage Manager group membership. No polling, Dock icon or display-control change is introduced.

All 15 native interface checks passed with Stage Manager enabled. An isolated second application takes focus, and the harness checks that ScreenOff's preview is inactive and its window is no longer visible according to AppKit's occlusion state. Reopening through LaunchServices returns the same PID and window, makes it key and visible again, and the fixture terminates normally. A direct `NSApplication.deactivate()` without a focus recipient was unsuitable for this test: the application immediately became active again. The two-app check exercises actual focus handoff, without controlling physical displays or changing the user's preferences.

The signed 1.2.2 app was installed after the old app and recovery helper exited normally. Its executable hash matches the packaged app and the automatic preference was preserved. DMG checksum and ZIP integrity verification passed.

## Version 1.2.0: window-only interface

The status item, popover, visibility preference implementation and their geometry tests were removed. The settings window now contains one display preference, current status and quit. It cannot be minimized into the Dock. The app retains `LSUIElement` and accessory activation, background login behavior, window reuse and LaunchServices reopening.

All 330 policy/controller/recovery checks pass; display control and the watchdog are unchanged from 1.1.2. All 11 native interface checks pass in an isolated preview application: background launch without visible windows, no Dock item, LaunchServices reopening the same process, foreground/key settings, no status-bar window, no minimization, complete content sizing, continued background lifetime after closing, and repeated reopening of the same window. These UI checks perform no display transactions. Earlier physical recovery and lock/unlock validation remains recorded below; no new physical cable or lock test is claimed for this UI change.

The installed 1.2.0 window was visually checked and its accessibility tree exposed exactly one display switch, quit and the native window controls, with no visibility button or status menu. The saved automatic preference remained enabled (the positive UI switch remained OFF), and the window reported only the external display working. The old app and helper exited normally before replacement. The installed executable hash matches the packaged app; signature, DMG checksum and ZIP integrity verification passed.

## Version 1.1.2: automatic mode after unlock

The user reported that the built-in stayed on after locking with Touch ID, leaving the Mac locked, and unlocking. Read-only diagnostics confirmed an active built-in and the same active external, while the preference remained OFF. The controller used permanent failure inhibition for recovery and did not observe lock/unlock or display sleep/wake; waking therefore could leave the saved automatic mode inhibited indefinitely.

Thirty-eight additional checks exercise the production controller with fake hardware and a monotonic clock. They cover lock without system sleep, screen sleep, system sleep, a wake event before unlock, settling, delayed exit of the old helper, the same external UUID throughout, launch while locked, missed notifications detected by the existing poll, unplug during lock, reconnect after unlock, latest switch preference, failed resume followed by 100 duplicate events, explicit manual recovery holds, and a short lock that never restored the panel. Resume performs at most one automatic attempt per observed inactive/active cycle; a later unrelated helper failure must not inherit a stale resume request.

The previous eight-hour closed-lid regression and recorded headless cable recovery tests pass. The two-second night probe still reports one enable call and two UI publications. Actual lock/unlock validation is recorded separately from these simulated checks.

All 11 native interface checks passed, including hidden-icon reopening through LaunchServices; all four popover checks passed with a 2.5-point gap on the current monitor configuration. The 1.1.2 app was installed with the user's preferences preserved. Code-signature verification, DMG verification and ZIP integrity checks passed.

**Physical lock/unlock validation passed in the installed 1.1.2 app.** With the preference OFF and the external connected, the user locked the Mac using Touch ID, waited for the external to sleep, and unlocked it. A separate read-only observer recorded the built-in OFF before locking, the active external count dropping to zero while locked, and the built-in ON with one active external immediately after unlock. About two to three seconds later, the built-in was OFF again. The user confirmed the automatic disabling worked. The observer issued no display transactions and exited after confirming the result.

## Version 1.1.1: overnight energy use

The user reported a 12-hour energy score of 771.55 after leaving the Mac on mains power, lid closed and external monitor connected but asleep. The Mac was configured to remain awake. Read-only process inspection found 150 minutes 38 seconds of CPU time accumulated by the 1.1.0 main process over about 7.5 hours. A sample taken after the lid was open showed it mostly idle; it cannot reconstruct the overnight call stacks.

A deterministic reproducer uses the production controller with fake display hardware: a closed lid, failed enable calls, and configuration callbacks emitted by those attempts. It has no real display transactions. Over a two-second run, 1.1.0 issued **20,004 enable calls and 60,012 ObservableObject publications** before/after the probe's deliberate 20,000-call feedback cap. Version 1.1.1 issued **one enable call and two publications**. This demonstrates the removed feedback path, not a measured wattage or overnight battery saving.

Sixteen additional controller/helper checks pass. A virtual eight-hour sequence holds the lid closed and external connected but inactive, without system sleep/wake events. Each recovery process attempts once, keeps its obligation, and restores when the lid opens. Unchanged waiting emits no additional UI publications or progress animation. Further cases cover callback storms with an open lid, cooldown expiry, immediate recovery with a newly detected panel, closure during verification, and quit handing off a pending closed-lid recovery. Semantic tests use zero retry delay where time is irrelevant; scheduling regressions use the real two-second interval with an injected monotonic clock.

All eleven native interface checks and four popover positioning checks passed. No new full overnight physical run has been performed; the eight-hour sequence uses a virtual clock. The remembered-display-ID cable recovery regressions continue to pass.

The actual 1.1.1 helper passed restore-command, pipe-EOF and restore-argument integration checks with the built-in already active (no disable requested by those checks). The signed 1.1.1 app was installed and its executable hash matched the packaged app. During a 45.27-second idle observation after launch, with the lid open, the main process used 0.01 CPU seconds and the armed helper used 0.03 CPU seconds: about 0.09% of one CPU in total. This short idle measurement is distinct from the simulated overnight regression. DMG checksum, ZIP integrity and code-signature verification passed.

Reproduce the two-second probe after running the normal tests:

```sh
.build/recovery-tests --night-probe
```

The 12-hour value is historical average impact, not watts or current consumption, and is not expected to reset immediately after updating. See [Apple's Activity Monitor guide](https://support.apple.com/en-my/guide/activity-monitor/actmntr43697/mac).

## Version 1.1.0: one preference and an optional status item

- Nine additional controller checks pass with injected hardware: migration of the old automatic preference to the inverse UI value, selecting OFF without an external, applying it after attachment, immediate restoration on ON, persistence of ON across topology changes, clearing a temporary recovery override, and preview controls never starting display transactions or helpers.
- `bash Scripts/test-interface.sh` passed 11 native checks in an isolated preview app bundle. They cover saved visibility, hidden background startup, a real LaunchServices reopen to the same PID, opening settings without returning the icon, fitting the content, closing/reusing the window, returning the icon, opening its popover, and hiding from the open popover. The latter caught an AppKit animated-close issue: the popover now closes synchronously before its status-item anchor is removed.
- The native menu was rendered and visually inspected: one display-preference switch, one hide/show button, status, Spotlight instructions and quit. The native settings-window bounds were checked against the complete content size. SwiftUI did not expose its child accessibility tree to the in-process test on this OS, so control count is verified visually rather than claimed as an automated accessibility check.
- All four native popover positioning checks passed with a 2.0-point gap on this Mac.
- The hardware transaction and watchdog recovery implementation from 1.0.3 is unchanged. The new UI tests never issue physical display transactions. The prior user-confirmed cable-removal result remains the hardware evidence; this UI release does not claim a new physical unplug, sleep or login test.

## Version 1.0.1: menu positioning

- 19 additional geometry checks pass for growing/shrinking menu content, display edges, and monitors above, below, left and right of the primary screen.
- `bash Scripts/test-popover.sh` uses the actual AppDelegate/NSPopover in preview mode. All four stages passed on this Mac: initial presentation, content growth, content shrink, and reopening. Each measured a 2.0-point gap between the status button and the top of the native popover window.
- Preview mode does not start or evaluate the display controller and does not change preferences. The test menu stays open across focus changes so activity in another app cannot interrupt the frame measurements; production retains normal transient-menu behavior.
- All 54 original policy/watchdog checks continue to pass (73 pure checks total). The display switching implementation is unchanged in this patch.

## Version 1.0.2: unplug and lid recovery

The user reported that removing the monitor cable from the Mac or dock left the built-in disabled, even after closing/opening the lid. Code inspection found premature release when the built-in disappeared from enumeration, unverified release before sleep, a lid-closed false success, and a helper that exited after bounded unsuccessful recovery. These paths now retain the restoration obligation.

- The production `DisplayController` is tested against temporary loss of both displays, repeated API/read failures, changed built-in IDs, inactive-but-online panels, sleep without a wake callback, lid closure, helper death, orphaned disabled panels on startup, stale active lists after remove/disable events, temporary headless displays, unplug during the off transaction, and reconnection during recovery.
- The production `WatchdogRecovery` is tested across 100 unavailable-panel polls, lid closure, repeated API errors, transient loss during verification, and already-restored panels. It must not finish until two separate observations confirm an online/active built-in with an open lid. A redundant enable is not required for a panel already confirmed active.
- `bash Scripts/test-restore-only.sh` passed against the actual 1.0.2 helper for explicit restore command, pipe EOF while the parent remains alive, and `--restore` startup. Each helper exited successfully and the built-in was confirmed active. No disable command was sent. This validates IPC and completion, not physical hotplug recovery.
- `bash Scripts/test-popover.sh` passed all four native AppKit stages again. The measured gap was 2.5 points for initial show, growth, shrink and reopen with the current display configuration.
- Before developing this fix, `--recover` successfully restored the user's disabled panel; a separate read-only diagnostic confirmed it online and active. Development and validation of 1.0.2 did not deliberately disable it again.

At the time of the 1.0.2 release, physical cable removal, lid closure and sleep had not been repeated. The subsequent physical unplug test still failed, leading to the hardware investigation and correction below. The simulated regressions alone had not established end-to-end hotplug recovery.

## Version 1.0.3: recorded hardware failure and working recovery

Physical unplug was reproduced with the user on this M1 Mac, with the built-in switch off and automatic mode on. Both a live AppKit observer and independent fresh diagnostic processes recorded the same result:

1. Before unplugging: built-in ID 1 was offline; external ID 2 was online/active.
2. After unplugging: ID 1 disappeared from the **private** `SLSGetDisplayList` as well. WindowServer created an active headless placeholder with vendor 1970170734/model 1986622068 (`unkn`/`virt`). An offline alias ID 3 remained, without the built-in flag.
3. Version 1.0.2 retained its recovery obligation, but could never resolve the missing built-in target. Repeating enumeration alone could not fix this. The public `CGRestorePermanentDisplayConfiguration()` was also tested and did not restore the panel; it is not part of the fix.
4. A restore-only diagnostic enabled the last positively identified built-in ID 1, even though it was absent from the current private list. Begin/configure/commit all returned success. ID 1 returned online/active before the external was reconnected. The user confirmed seeing the built-in screen turn on.

The production fix remembers only a positively identified built-in ID in memory. A current built-in ID always wins. The remembered-ID fallback can only enable, with the lid open, no usable external, and no other current record assigned that ID. The observed virtual placeholder is excluded from usable externals. Regression tests replay the recorded topology through the real controller and watchdog recovery engine, and reject reuse for disabling, a closed lid, another physical external, conflicting IDs, and missing identity history.

**Final application validation passed:** ScreenOff 1.0.3 was installed in `/Applications` and started with `--restore-on-launch`. All temporary diagnostic/recovery processes were stopped. The user then disabled the built-in with the first switch, left automatic mode enabled, and physically removed the cable. The user confirmed that the built-in turned on in the actual application. This is end-to-end confirmation of the reported scenario on this Mac/dock. Sleep, closed-lid sequences, other Macs and other docks remain separate manual checks.

## Earlier hardware validation (1.0.0)

Target: MacBook Pro (M1), macOS 27.0 beta, build 26A5425a. Read-only probing found both SLS/CGS disconnect and display-list symbols, an online built-in panel, and one active external display.

Passed on this Mac:

- The real guarded transaction disabled the built-in panel, removed it from the online display list and left the external display active.
- The panel remained disabled for two seconds, then returned online through the same transaction path used by the menu switch.
- The independent helper restored the built-in panel after its heartbeat pipe was closed while the parent process stayed alive. This verifies actual recovery from a second process, not merely WindowServer's automatic cleanup after the controlling process exits.
- The menu's accessibility tree exposed two switches and the quit button. The native view was rendered and visually checked; the documented preview is in `Menu.png`.
- Both application binaries were compiled for arm64 with a macOS 13 deployment target; ad-hoc signatures and Info.plist validation passed.
- The packaged DMG passed `hdiutil verify`; its ZIP passed `unzip -tq`. A final repeat of the live probe was refused after the laptop lid was closed, as required by the safety guard; the earlier successful open-lid hardware tests are the basis of the switching result above.

The integration harness runs a full `NSApplication` event loop. A plain synchronous loop can retain stale CoreGraphics state after a different process changes display configuration and falsely report that a successful recovery failed. The helper also maintains a proper application event loop. Anonymous pipe handles use close-on-exec for parent-only ends.

## Manual regression checklist

- Unplug the last external while built-in is off; the built-in must return.
- Reconnect with automatic mode enabled; the built-in must turn off after settling.
- Turn the single preference ON; the built-in must restore and stay on across external reconnections. Turn it OFF again to resume automatic disabling.
- Lock and wake with the same external attached; the confirmed OFF preference should remain applied without ScreenOff proactively restoring the built-in. If macOS reactivates the panel, verify supervised reapplication.
- Sleep and wake with an external attached; preserve a confirmed disable. An interrupted transaction still requires rollback before further disabling.
- Close/open the lid; the pending restoration must survive and complete once the panel becomes active.
- Quit while off; the built-in must return and the helper must exit.
- Remove external during a transition; the built-in must recover.
- Restart macOS with the preference OFF and login approval granted; ScreenOff must start without opening settings or creating icons in the menu bar or Dock.
- Close settings, then open ScreenOff through Spotlight; settings must reappear without a second process or icons in the menu bar or Dock.
- Try a mirrored layout; the app must leave it unchanged and explain the prerequisite.

These physical hotplug, sleep and login scenarios require manual hardware interaction; unit checks alone do not establish them.

## Night Shift exclusion development checks (2026-10-03)

- `bash Scripts/build.sh`: passed outside the execution sandbox, including helper signing and bundle verification. The sandbox blocked `iconutil`; no build-script workaround was needed.
- `bash Scripts/test.sh`: 299 checks passed outside the execution sandbox. This includes 21 plist/role checks and seven read-only helper boundary checks. The sandbox does not expose `kern.boottime`; the unsandboxed boot-identity check passed.
- Native settings render: 374 × 395 pt with one preview monitor; visually inspected for complete content and readable controls.
- `bash Scripts/test-interface.sh`: failed at “reopen brings settings to the foreground.” A separate app built from the original HEAD versions of App, SettingsView, DisplayController and RecoveryGuard failed at the same assertion on this host. Full focus/reopening UI verification remains incomplete.
- No administrator override was applied to a physical monitor. Post-restart Night Shift output, True Tone exclusion and hardware compatibility are unverified.

### Manual monitor verification

1. Quit the previously installed ScreenOff and open the new local build. Keep the built-in display enabled and connect the external monitor.
2. In macOS enable Night Shift and observe both displays. Enable the external monitor’s own eye-care mode.
3. In ScreenOff, enable the monitor under “Exclude from Night Shift,” approve the system administrator prompt, and restart when convenient.
4. Enable Night Shift again. Confirm that the built-in screen changes warmth while the external screen keeps only its hardware eye-care effect. Check the external monitor’s normal resolution, refresh rate and HDR behavior as the television role may affect compatibility.
5. Disconnect/reconnect and sleep/wake; confirm the exclusion persists. Verify ordinary built-in-display disabling and recovery still work.
6. Turn the exclusion switch off (restoration is available even with the monitor disconnected), restart, and confirm the original macOS behavior returns. Restore exclusions before uninstalling.

## Lock and sleep preservation development checks (2026-10-03)

- `bash Scripts/test.sh`: 369 checks passed. Coverage includes owner-console versus switched-user/unknown sessions, lock retention, eight-hour display/system sleep with no enable transaction, wake without a transaction when OFF survives, supervised reapplication if macOS reactivates the panel, failure inhibition, interrupted-worker rollback, and locked close-lid unplug recovery using the remembered panel ID.
- `bash Scripts/build.sh`: passed, including code signing and bundle verification.
- A read-only probe on the host returned `Own console available: true` for the unlocked owner session. Actual locked-session dictionary behavior is not yet verified.
- The installed app was replaced after the old recovery helper exited; the previous version was backed up under `/private/tmp`. Native UI confirmed the existing OFF preference, external-only operation and the existing Night Shift exclusion remained selected.
- Physical lock, sleep/wake, fast user switching and unplug during lock were not driven automatically. Zero-flash wake behavior remains unverified; simulated success is not a hardware guarantee.

Manual acceptance: with the lid open and external monitor active, turn “Use built-in display” OFF, lock using Control-Command-Q, and confirm the panel stays off. Let the Mac sleep, wake while still locked, and check for any flash. Confirm unplugging the external restores the built-in lock screen. Then repeat lock → close lid → unplug → open lid, and verify the remembered-panel recovery. A failure should leave recovery armed or keep the built-in screen enabled, rather than repeatedly launching disable transactions.

## Owner-reported validation (2026-10-03)

After applying the Night Shift exclusion, the owner reported that it appeared to work and requested installation of the new build. After installing the lock/sleep preservation build, the owner reported that it works as well. These reports confirm the owner’s observed behavior on the affected Mac; they do not establish that every manual regression scenario above, fast user switching, role restoration or zero-flash wake was explicitly tested. Agent-driven physical verification was limited to graceful replacement and the installed app returning to external-only mode with the existing exclusion selected.

## Recovery audit corrections (2026-10-21, fork development)

The fork corrects four code-level recovery findings: an older transaction completion overwriting a newer activity transition's retry permission, stale watchdog system-sleep state after a partial wake-notification sequence, stale controller screen-sleep state after system wake, and synchronous WindowServer observations escaping the CLI recovery deadline.

- `bash Scripts/test.sh`: **565 checks passed** — 54 policy/rule checks, 230 controller/recovery checks, 128 supervisor checks, 11 real transaction-subprocess checks, 21 display-role checks, 7 read-only helper-boundary checks, 15 session/heartbeat checks and 99 bounded recovery-command checks.
- Regression tests were observed failing before the relevant fixes. Late deferred/timed-out completion covers newer screen/system wake, lid opening, console return and topology change, plus unchanged-activity inhibition and worker serialisation controls. Wake tests cover a missing screen-sleep or screen-wake notification, unchanged owner polling during sleep, duplicate callbacks, explicit emergency recovery and manual holds.
- The explicit emergency regression verifies controller delegation through a simulated helper. It does not prove that a real helper can recover after missing all of its own wake notifications: ordinary restore IPC intentionally does not wake sleeping state. A further recognised wake/lid transition may still be required in that pre-existing case.
- Harmless native subprocesses exercise initially stalled and subsequently stalled observations, one shared deadline, bounded partial/malformed/oversized output, a process that closes stdout without exiting, supervisor handoff/exit failures, positive seed provenance, UI ownership exclusion, successful independent confirmation, and a durable helper surviving the actual fixture CLI parent's exit. Fixtures do not link display-control hardware or perform display transactions.
- `bash Scripts/build.sh`: passed for arm64 with the macOS 13 deployment target, including deep/strict signature verification and bundle plist validation. The built helper's read-only `--snapshot` mode also returned valid topology JSON after validating its direct parent; no display transaction was requested.
- The recovery command's twelve-second monotonic budget covers its initial query, restore handoff, later queries and polling delays. WindowServer queries are isolated in disposable processes. This is not a hard real-time guarantee against pathological blocking in OS process creation or scheduler delays. `--diagnose` remains a separate synchronous read-only command.

No app installation, preferences, physical display changes, lock/sleep actions, or Night Shift overrides were performed for these corrections. Native interface/focus automation was not rerun because the settings-window and normal-launch behaviour are unchanged. These checks do **not** establish that the user's closed-lid Belkin Dual 4K Thunderbolt 3/LG UltraFine failure is fixed. Physical sleep/wake, dock reconnection and lid-opening acceptance checks remain necessary on the affected setup.
