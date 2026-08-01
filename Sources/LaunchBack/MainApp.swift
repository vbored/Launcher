import AppKit
import SwiftUI

@main
struct LauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No visible scene of our own — everything is driven by AppDelegate
        // through LaunchpadOverlayWindow. Settings{} keeps SwiftUI's App
        // lifecycle happy without creating a stray window.
        Settings { EmptyView() }
    }
}

/// Ties together app discovery, the overlay window(s), and the global
/// hotkey, and makes a second launch of the bundle act as a toggle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayWindow: LaunchpadOverlayWindow?
    private var hotkeyManager: HotkeyManager?
    private var isVisible = false
    private let appStore = AppStore()
    private let folderStore = FolderStore()

    // Apple's own (now-vestigial) Launchpad.app shim toggles by posting this
    // exact distributed notification — observed via `strings` on
    // /System/Applications/Launchpad.app/Contents/MacOS/Launchpad. Listening
    // for it too means any leftover system trigger for "toggle Launchpad"
    // (an F4 remap, `tell application "Launchpad" to activate`, etc.) also
    // opens Launcher, at no cost if nothing ever posts it.
    private static let legacyLaunchpadToggleName = Notification.Name("com.apple.launchpad.toggle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar-less background utility

        // Apps with no visible windows are eligible for macOS's "Automatic
        // Termination" — the OS can silently *quit the whole process* to
        // reclaim memory during a long idle period (confirmed via `log
        // show`: this process was tagged
        // `_kLSApplicationWouldBeTerminatedByTALKey=1`, i.e. eligible).
        // Launcher has no visible window almost all the time by design —
        // it's a background accessory app waiting for a hotkey — so it's
        // squarely in the category this targets. If macOS kills it,
        // Launch Services silently relaunches it from scratch the next
        // time the hotkey/reopen fires, paying the *full* cold-start cost
        // again (process startup, Spotlight re-gathering apps from zero,
        // an empty wallpaper cache) — which is exactly what "takes a long
        // time to show apps after not using it for a while" would look
        // like from the outside, even though every optimization elsewhere
        // assumes the already-warmed-up process is still the one
        // responding. Opting out keeps this one persistent instance alive
        // and ready regardless of idle time.
        ProcessInfo.processInfo.disableAutomaticTermination(
            "Background hotkey listener must stay resident to respond instantly"
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleDistributedToggle),
            name: Self.legacyLaunchpadToggleName,
            object: nil
        )

        hotkeyManager = HotkeyManager { [weak self] in self?.toggle() }

        // Show first, before anything that doesn't actually gate the first
        // frame — profiling a cold launch (via temporary instrumentation)
        // showed `AppQueryEngine.shared.startMonitoring` alone added ~17ms
        // ahead of the window even appearing, for work whose result isn't
        // needed until *after* the grid is already on screen (it renders
        // empty and fills in live regardless of when monitoring starts).
        // Every millisecond ahead of `show()` here is pure, avoidable delay
        // on the one moment users are actually staring at a blank screen.
        show()

        // Starts a persistent Spotlight monitor once; from here on
        // `appStore.apps` stays in sync with installs/removals on its own.
        AppQueryEngine.shared.startMonitoring(store: appStore)

        // Only matters for procedural/animated wallpapers with no backing
        // image file (see `LaunchpadOverlayWindow.liveDesktopSnapshot`).
        // `CGRequestScreenCaptureAccess()` blocks on its system prompt, so
        // it's deferred until just after the very first `show()` instead of
        // sitting ahead of it — the first appearance always uses whatever's
        // already available (falling back to a live blur if needed), and if
        // the user grants access, later toggles pick up the accurate
        // snapshot automatically.
        DispatchQueue.main.async {
            CGRequestScreenCaptureAccess()
        }
    }

    // `LSMultipleInstancesProhibited` in Info.plist is what makes this fire:
    // it tells Launch Services never to spawn a second process for this
    // bundle ID, and instead call this on the already-running instance
    // whenever the user tries to open the app again (double-click, Dock
    // click, `open` from Terminal). Without that key, this delegate method
    // is simply never invoked — which is exactly why re-opening used to do
    // nothing until the app was quit first.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        toggle()
        return true
    }

    @objc private func handleDistributedToggle() {
        DebugTiming.mark("handleDistributedToggle entered")
        toggle()
    }

    private func toggle() {
        isVisible ? hide() : show()
    }

    private func show() {
        DebugTiming.mark("AppDelegate.show() entered")
        guard !isVisible, let screen = Self.targetScreen() else { return }
        DebugTiming.mark("targetScreen resolved")

        // The exact same closure goes to both the SwiftUI content (tap to
        // dismiss, onExitCommand) and the window itself (its own Escape-key
        // monitor) — one authoritative dismissal path no matter which of
        // them triggers it, so `isVisible`/`overlayWindow` never drift out
        // of sync with what's actually on screen.
        let dismissAction: () -> Void = { [weak self] in self?.hide() }

        // Reusing the same `LaunchpadOverlayWindow` instance across toggles
        // (rather than allocating a brand new full-screen buffered
        // `NSWindow` every single time) is what actually made toggle-open
        // feel slow: window allocation isn't free, and it was happening on
        // every hotkey press even though almost nothing about the window
        // itself — its frame, its background container, its cached
        // wallpaper image — ever changes between opens on the same screen.
        // Only when the target screen genuinely changes (moved the mouse
        // to a different display since the last open) does a fresh window
        // sized for it get built.
        let window: LaunchpadOverlayWindow
        if let existing = overlayWindow, existing.matches(screen: screen) {
            window = existing
        } else {
            window = LaunchpadOverlayWindow(screen: screen)
            overlayWindow = window
        }
        window.show(with: GridView(store: appStore, folderStore: folderStore, onDismiss: dismissAction), onDismiss: dismissAction)
        isVisible = true
    }

    private func hide() {
        // The window itself is left alive and simply ordered out/faded by
        // `dismiss()` — not discarded — so the next `show()` can reuse it
        // instead of paying for a fresh `NSWindow` allocation. See the
        // comment in `show()`.
        overlayWindow?.dismiss()
        isVisible = false
    }

    /// Every screen dimension the overlay uses (window frame, grid layout,
    /// icon sizing, wallpaper render target) already derives dynamically
    /// from whichever `NSScreen` gets passed in here — there's no hardcoded
    /// resolution anywhere, so this alone is what determines "does the app
    /// correctly fit the machine it's running on."
    ///
    /// `NSScreen.main` specifically means "the screen containing the key
    /// window" — and this app has no key window almost all the time (it's a
    /// background accessory app that only briefly becomes key while the
    /// grid itself is open), so it's `nil` on every fresh launch and every
    /// toggle-open, silently falling through to `NSScreen.screens.first`.
    /// That's not "the current screen" by any real definition — it's just
    /// array order, which on a multi-monitor setup doesn't necessarily
    /// match the display the user is actually sitting in front of.
    /// Finding whichever screen contains the mouse cursor instead matches
    /// how macOS's own full-screen overlays (Mission Control, Launchpad)
    /// behave — opening on the display you're actively using — with
    /// `.main`/`.screens.first` as fallbacks for the (rare) case the cursor
    /// position can't be resolved to a screen at all.
    private static func targetScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}
