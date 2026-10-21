# ScreenOff 1.3.3 RC1 — fork prerelease

App version **1.3.3**, build **14**. Release tag: `v1.3.3-rc.1`.

This release candidate in [alexstonelunde/ScreenOff](https://github.com/alexstonelunde/ScreenOff) includes the four recovery corrections from [PR #1](https://github.com/alexstonelunde/ScreenOff/pull/1):

- A delayed transaction result cannot revoke retry permission granted by a newer wake, lid, console or topology transition.
- Positive wake notifications reconcile the watchdog's screen/system state and heartbeat handling while unchanged duplicate notifications retain the existing retry limits.
- System wake and explicit recovery can clear the controller's stale screen-sleep state so it can forward recovery requests.
- `--recover` isolates every display observation in a disposable helper and shares one twelve-second budget across initial observation, restore handoff and later observations. A live restore supervisor survives the command's exit.

Verification for the recovery corrections comprises **565 passing automated checks**, an Apple Silicon build targeting macOS 13 or later, bundle/signature/plist verification, a read-only helper smoke check and independent review with no outstanding findings. See [Verification](Verification.md) for test boundaries and limitations.

Physical sleep/wake acceptance on the Belkin Dual 4K Thunderbolt 3/LG UltraFine setup remains to be performed. This prerelease does not establish the cause of the blank external monitor while the lid is closed. An independent helper that misses all its own wake notifications may still need a recognised wake or lid transition. The private macOS display API and the existing lid, console and external-display safety checks remain relevant.

## Installation and acceptance

1. Download `ScreenOff-1.3.3-arm64.dmg` from the [RC1 prerelease](https://github.com/alexstonelunde/ScreenOff/releases/tag/v1.3.3-rc.1).
2. Open the old ScreenOff settings and quit using the power button. Drag the new app into Applications and replace the old app, then reopen it.
3. Confirm Finder's Get Info reports version 1.3.3 and build 14 is present in the app's `Contents/Info.plist`.
4. With the lid open and an external monitor connected, check OFF, lock/wake and external-unplug recovery. Separately test the closed-lid Belkin/LG sleep/wake sequence and confirm that opening the lid restores an image if the external link fails.

The app is ad-hoc signed and is not notarised. If macOS blocks launch, attempt to open it and use System Settings → Privacy & Security → Open Anyway. Optional Night Shift exclusions are persistent model-specific overrides; restore them and restart before uninstalling.

Release assets include the DMG, application ZIP, source ZIP and `SHA256SUMS.txt`. Keep this release marked as a prerelease until the affected hardware acceptance checks are completed.
