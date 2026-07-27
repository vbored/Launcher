import AppKit
import SwiftUI

/// A borderless, fully transparent window that sits above the Dock and menu
/// bar, hosting the SwiftUI grid on top of a blurred backdrop matching the
/// desktop wallpaper.
@MainActor
final class LaunchpadOverlayWindow: NSWindow {
    private var keyMonitor: Any?
    private let backgroundContainer = NSView()
    private var backgroundImageView: NSImageView?
    private var fallbackBlurView: NSVisualEffectView?
    private var hostingView: NSView?
    private let targetFrame: NSRect
    private let ownerScreen: NSScreen
    private var onRequestDismiss: (() -> Void)?
    // False only until the very first background image (real or fallback
    // blur) has been installed. Distinguishes "nothing shown yet, needs a
    // fallback while the real one renders" from "something's already
    // showing, so just wait for the update rather than flashing back to a
    // generic blur every time `refreshBackground` re-checks."
    private var hasDisplayedBackground = false

    // Bumped on every `show()`/`dismiss()` call and captured by `dismiss()`'s
    // animation completion handler. Reusing one window instance across
    // toggles (rather than a fresh window per toggle) means a fast
    // close-then-reopen can call `show()` again before the *previous*
    // `dismiss()`'s ~0.18s fade-out animation has finished — without this
    // check, that old completion handler would still fire afterward and
    // tear down state the new `show()` had already re-armed (wiping out
    // its `onRequestDismiss`, ripping its freshly-mounted hosting view back
    // out from under it). Comparing against the current token lets a
    // completion handler recognize it's stale and simply no-op.
    private var operationToken = 0

    /// A slightly inset, centered version of `targetFrame` — the animation
    /// starts (on show) or ends (on dismiss) here, so the whole overlay
    /// gently grows into place / shrinks away instead of just cross-fading,
    /// the same "zoom" feel classic Launchpad opens with.
    private var zoomedOutFrame: NSRect {
        let scale: CGFloat = 0.97
        let dx = targetFrame.width * (1 - scale) / 2
        let dy = targetFrame.height * (1 - scale) / 2
        return targetFrame.insetBy(dx: dx, dy: dy)
    }

    init(screen: NSScreen) {
        targetFrame = screen.frame
        ownerScreen = screen
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // One level above the menu bar so the overlay covers the Dock too.
        level = .mainMenu + 1
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        animationBehavior = .none

        backgroundContainer.frame = screen.frame
        backgroundContainer.autoresizingMask = [.width, .height]
        refreshBackground(for: screen)

        contentView = backgroundContainer
    }

    /// Installs whatever background is currently available, and asks the
    /// cache for an update. Called once from `init` and again on every
    /// `show(with:)` — that second call site is what actually lets a
    /// wallpaper change reach an already-open (reused-across-toggles)
    /// window: `init` alone only ever runs once per screen for the whole
    /// app session, so a cache invalidation that happened while this window
    /// already existed would otherwise have nowhere to deliver its result.
    private func refreshBackground(for screen: NSScreen) {
        let cache = WallpaperBackgroundCache.shared

        // Only fall back to the generic blur if nothing has ever been shown
        // yet — once a real (or even fallback) background is up, re-running
        // this on a later `show()` should wait quietly for `prewarm`'s
        // completion rather than flashing back to the placeholder while a
        // post-wallpaper-change re-render is in flight.
        if !hasDisplayedBackground, cache.cachedBackground() == nil {
            addFallbackBlur()
            hasDisplayedBackground = true
        }

        cache.prewarm(for: screen) { [weak self] wallpaper in
            self?.addBackgroundImage(wallpaper)
            self?.hasDisplayedBackground = true
        }
    }

    private func addBackgroundImage(_ image: NSImage) {
        let imageView = NSImageView(frame: backgroundContainer.bounds)
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleAxesIndependently
        imageView.image = image
        // `.below` (not `.above`) — this can arrive *after* `show()` has
        // already mounted the SwiftUI grid content on top (the fallback
        // blur render is instant, but the real background can finish while
        // the window's already visible), so it must slot in behind
        // whatever's already there rather than covering it.
        backgroundContainer.addSubview(imageView, positioned: .below, relativeTo: nil)
        backgroundImageView?.removeFromSuperview()
        backgroundImageView = imageView
        fallbackBlurView?.removeFromSuperview()
        fallbackBlurView = nil
    }

    private func addFallbackBlur() {
        let blurView = NSVisualEffectView(frame: backgroundContainer.bounds)
        blurView.autoresizingMask = [.width, .height]
        blurView.material = .fullScreenUI
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        backgroundContainer.addSubview(blurView)
        fallbackBlurView = blurView
    }

    /// Mounts `rootView` into the window and brings it on screen. `onDismiss`
    /// is the *same* closure passed to the SwiftUI content for its own
    /// tap-to-dismiss handling — routing the Escape key through it too
    /// (rather than this window calling its own `dismiss()` directly) keeps
    /// whichever object owns this window (e.g. `AppDelegate`, tracking
    /// visibility state) in sync no matter which path closed the overlay.
    /// Escape previously called `dismiss()` directly here, which animated
    /// the window closed perfectly fine but never told `AppDelegate` it had
    /// happened — leaving it still believing the overlay was visible, so
    /// the *next* toggle (hotkey, reopen) would try to hide an
    /// already-hidden window and silently do nothing, looking exactly like
    /// a hung/unresponsive app.
    func show(with rootView: some View, onDismiss: @escaping () -> Void) {
        DebugTiming.mark("LaunchpadOverlayWindow.show(with:) entered")
        operationToken += 1
        onRequestDismiss = onDismiss

        // See `refreshBackground` — `init` alone only ever runs once per
        // screen for this window's whole lifetime (it's reused across
        // toggles), so this is what actually lets a wallpaper change that
        // happened while the window already existed reach the screen: a
        // no-op if the cache still matches what's already displayed, an
        // instant swap if a freshly re-rendered image is ready and waiting.
        refreshBackground(for: ownerScreen)

        // Defensive: if a previous `dismiss()`'s fade-out animation hasn't
        // finished yet (fast close-then-reopen), its hosting view is still
        // attached — the `operationToken` check in `dismiss()`'s completion
        // handler will skip *its* cleanup once this newer `show()` has run,
        // so without this, that old view would linger under the new one
        // indefinitely rather than just for the remainder of the fade.
        hostingView?.removeFromSuperview()
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = backgroundContainer.bounds
        hosting.autoresizingMask = [.width, .height]
        backgroundContainer.addSubview(hosting)
        hostingView = hosting
        DebugTiming.mark("hosting view mounted")

        alphaValue = 0
        setFrame(zoomedOutFrame, display: false)
        DebugTiming.mark("after setFrame(zoomedOutFrame)")
        // `activate(ignoringOtherApps:)` is asynchronous, so even calling
        // it before ordering the window doesn't reliably win the race:
        // `makeKeyAndOrderFront` can still run before LaunchBack is
        // actually marked active, and AppKit then places the window
        // *beneath* whichever app is still active (confirmed via
        // `log show`: "ordered front from a non-active application and
        // may order beneath the active application's windows" — the
        // overlay silently existed off-screen from the user's POV).
        // `orderFrontRegardless()` is the documented way to force a
        // window to the front of its level regardless of app activation
        // state, so use that instead of `makeKeyAndOrderFront`.
        NSApp.activate(ignoringOtherApps: true)
        DebugTiming.mark("after NSApp.activate")
        orderFrontRegardless()
        DebugTiming.mark("after orderFrontRegardless")
        makeKey()

        // Classic Launchpad hides the Dock outright while active instead of
        // leaving it on screen, so do the same.
        NSApp.presentationOptions.insert(.hideDock)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(targetFrame, display: true)
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Escape
                self.onRequestDismiss?()
                return nil
            }
            // LaunchBack has no Dock icon and no menu bar (`.accessory`
            // activation policy, by design — it's meant to be invisible
            // until summoned), so there's normally no "Quit" anywhere a
            // user could find without opening Activity Monitor. `⌘Q` is the
            // one quit gesture every Mac user already knows regardless of
            // whether there's a menu to trigger it from, so honor it
            // directly while the grid is open — the one moment the app has
            // any UI at all to be listening from.
            if event.keyCode == 12, event.modifierFlags.contains(.command) { // ⌘Q
                NSApp.terminate(nil)
                return nil
            }
            return event
        }
    }

    /// Fades out, tears down the hosted content, and orders the window out.
    func dismiss() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }

        NSApp.presentationOptions.remove(.hideDock)

        operationToken += 1
        let token = operationToken

        NSAnimationContext.runAnimationGroup({ [zoomedOutFrame] context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
            animator().setFrame(zoomedOutFrame, display: true)
        }, completionHandler: { [weak self] in
            // If a newer `show()` (or another `dismiss()`) has run since
            // this one started, this completion is stale — the window is
            // back on screen with fresh state, and tearing anything down
            // now would rip that out from under it instead of cleaning up
            // this call's own leftovers.
            guard let self, self.operationToken == token else { return }
            self.orderOut(nil)
            self.hostingView?.removeFromSuperview()
            self.hostingView = nil
            self.onRequestDismiss = nil
        })
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Whether this window is already sized for `screen` and can be shown
    /// again as-is. Used by `AppDelegate` to reuse the same window instance
    /// across toggles rather than tearing down and reallocating a
    /// full-screen buffered `NSWindow` (plus its background container and
    /// wallpaper image view) on every single open — real, measurable
    /// overhead that a fresh `LaunchpadOverlayWindow` used to pay on every
    /// toggle even though almost all of it (the window itself, the cached
    /// wallpaper backing) never actually changes between opens on the same
    /// screen.
    func matches(screen: NSScreen) -> Bool {
        screen.frame == targetFrame
    }
}
