import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Caches the blurred wallpaper background across every toggle-open of the
/// overlay, computed off the main thread.
///
/// Without this, the overlay recomputed its background from scratch on
/// every single open, and — worse — `NSCIImageRep` only actually *runs* the
/// Gaussian blur pipeline the first time the image is drawn, which happens
/// exactly when the overlay's `NSImageView` appears on screen. That meant
/// every toggle synchronously froze the open/close zoom animation on the
/// main thread for over a full second (measured ~1.0s for a 4K wallpaper).
/// Rendering explicitly into a concrete `CGImage` via a `CIContext`, once,
/// on a background queue, and reusing the cached result removes that cost
/// from the interactive path entirely — only the very first open (before
/// the cache has ever been populated) falls back to an instant system blur
/// while the real background renders in the background.
@MainActor
final class WallpaperBackgroundCache {
    static let shared = WallpaperBackgroundCache()

    private var cachedImage: NSImage?
    private var isComputing = false
    private let ciContext = CIContext(options: nil)
    private var lastPrewarmedScreen: NSScreen?
    private var wallpaperChangeSource: DispatchSourceFileSystemObject?
    private var pendingChangeWorkItem: DispatchWorkItem?
    // Belt-and-suspenders alongside the file watcher below: `watchWallpaperStore`
    // depends on a private, undocumented file path that's only confirmed
    // correct for the macOS versions it was directly inspected against — if
    // it's wrong for some other version (or Apple moves the file again),
    // the watcher silently never fires (`open` just returns -1) and the
    // cache would never invalidate at all. Comparing against the *public*
    // `NSWorkspace.desktopImageURL(for:)` every time `prewarm` is called —
    // i.e. every toggle-open — can't be broken by a macOS version mismatch
    // the same way, so it catches a changed static wallpaper even if the
    // file watcher above never worked. (It can't see a change *between* two
    // procedural/animated wallpapers, which both report the same generic
    // system fallback URL — the file watcher, when it does work, is what
    // covers that case.)
    private var lastKnownWallpaperURL: URL?
    // Same idea, for appearance: a Dynamic Desktop wallpaper (or a picture
    // with distinct Light/Dark variants) renders a genuinely different
    // image when the system switches appearance even though the file path
    // itself never changes — so the URL check above alone can't catch it.
    private var lastKnownIsDark: Bool?

    private static let wallpaperStorePath = NSString(
        string: "~/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
    ).expandingTildeInPath

    private init() {
        // A long-running Launcher session should notice when the wallpaper
        // changes instead of keeping a stale cached background until the
        // app is quit and relaunched. There's no *documented* public
        // notification for this — an earlier version of this code guessed
        // at a plausible-sounding distributed notification name
        // ("com.apple.desktopBackgroundChanged"), but that string doesn't
        // actually exist anywhere in the system frameworks (confirmed via
        // `strings` on WallpaperAgent/Dock/CoreServices), so it silently
        // never fired — the cache was never actually invalidating. Watching
        // WallpaperAgent's own on-disk state file instead is verifiable:
        // its `LastSet`/`LastUse` timestamps are confirmed (by direct
        // inspection) to update the moment the wallpaper changes, static or
        // procedural alike, so a filesystem watcher on it is reliable
        // regardless of what notification (if any) WallpaperAgent posts.
        watchWallpaperStore()
        watchAppearanceChanges()
    }

    /// A system-wide (not per-app) light/dark switch — whether by schedule,
    /// manual toggle, or Night Shift-style automation — doesn't touch the
    /// wallpaper *file* at all for a Dynamic Desktop or Light/Dark-paired
    /// picture, so `watchWallpaperStore` alone won't necessarily catch it.
    /// `AppleInterfaceThemeChangedNotification` is the long-standing
    /// (unofficial but very widely relied-upon) distributed notification
    /// macOS posts on exactly this change.
    private func watchAppearanceChanges() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.cachedImage = nil
            if let screen = self.lastPrewarmedScreen {
                self.prewarm(for: screen)
            }
        }
    }

    private func currentAppearanceIsDark() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func watchWallpaperStore() {
        let fd = open(Self.wallpaperStorePath, O_EVTONLY)
        guard fd >= 0 else { return }

        // Plists are typically written via write-to-temp-then-atomic-rename,
        // which orphans whatever file descriptor was watching the original
        // path — `.rename`/`.delete` catch that so watching can be
        // re-established against the new inode, not just `.write` for
        // in-place modifications.
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.wallpaperChangeSource?.cancel()
            self.watchWallpaperStore()

            // A single logical wallpaper change can touch this file more
            // than once in quick succession (e.g. a temp-file write
            // followed by the atomic rename over the original) — without
            // coalescing, each one independently invalidated the cache and
            // kicked off its own full render, doubling up on an already
            // expensive-ish operation for no visual benefit (confirmed via
            // `vmmap`: a real run showed two full sets of blur-pipeline
            // buffers alive at once). Debouncing collapses a burst of
            // events into exactly one re-render.
            self.pendingChangeWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.cachedImage = nil
                if let screen = self.lastPrewarmedScreen {
                    self.prewarm(for: screen)
                }
            }
            self.pendingChangeWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        wallpaperChangeSource = source
    }

    /// Returns the cached, already-rendered background if one is ready.
    /// `nil` on the very first call (or right after a wallpaper change) —
    /// callers should show an instant fallback in that case while
    /// `prewarm` finishes in the background.
    func cachedBackground() -> NSImage? {
        cachedImage
    }

    private var pendingCompletions: [@MainActor (NSImage) -> Void] = []

    /// Kicks off background rendering if nothing is cached yet and no
    /// computation is already in flight. `completion` (if given) fires on
    /// the main actor once a fresh image is ready — immediately, if one is
    /// already cached.
    func prewarm(for screen: NSScreen, completion: (@MainActor (NSImage) -> Void)? = nil) {
        lastPrewarmedScreen = screen

        let currentURL = NSWorkspace.shared.desktopImageURL(for: screen)
        let currentIsDark = currentAppearanceIsDark()
        if let lastKnownWallpaperURL, currentURL != lastKnownWallpaperURL {
            cachedImage = nil
        }
        if let lastKnownIsDark, currentIsDark != lastKnownIsDark {
            cachedImage = nil
        }
        lastKnownWallpaperURL = currentURL
        lastKnownIsDark = currentIsDark

        if let cachedImage {
            completion?(cachedImage)
            return
        }

        if let completion {
            pendingCompletions.append(completion)
        }
        // A caller arriving while a render is already in flight (e.g. a
        // toggle-open landing right after a wallpaper-change invalidation
        // kicked off its own re-render) used to just drop its completion
        // here and never hear back at all — silently leaving whatever was
        // on screen stale until some *later*, unrelated event happened to
        // trigger another render. Queuing it above instead means every
        // caller gets notified once the in-flight render actually finishes,
        // no matter how many are waiting on the same one.
        guard !isComputing else { return }
        isComputing = true

        // Resolve everything that touches AppKit objects here, on the main
        // thread, before hopping off — only the actual Core Image/Core
        // Graphics number-crunching below needs to happen in the background.
        let screenFrame = screen.frame
        let targetPixelSize = CGSize(
            width: screenFrame.width * screen.backingScaleFactor,
            height: screenFrame.height * screen.backingScaleFactor
        )
        let wallpaperURL = NSWorkspace.shared.desktopImageURL(for: screen)
        let context = ciContext

        Task.detached(priority: .userInitiated) {
            let image = Self.renderBackground(
                wallpaperURL: wallpaperURL,
                screenFrame: screenFrame,
                targetPixelSize: targetPixelSize,
                context: context
            )
            await MainActor.run {
                self.isComputing = false
                let waiting = self.pendingCompletions
                self.pendingCompletions.removeAll()
                guard let image else { return }
                self.cachedImage = image
                waiting.forEach { $0(image) }
            }
        }
    }

    // MARK: - Rendering (runs off the main thread)

    private nonisolated static func renderBackground(
        wallpaperURL: URL?,
        screenFrame: NSRect,
        targetPixelSize: CGSize,
        context: CIContext
    ) -> NSImage? {
        if let ciImage = staticWallpaperImage(from: wallpaperURL, targetPixelSize: targetPixelSize) {
            return blurredAndTinted(ciImage, targetPixelSize: targetPixelSize, context: context)
        }
        if let ciImage = liveDesktopSnapshotImage(screenFrame: screenFrame) {
            return blurredAndTinted(ciImage, targetPixelSize: targetPixelSize, context: context)
        }
        return nil
    }

    /// Most desktop pictures are a plain image file, which `NSWorkspace`
    /// hands back directly — reading and blurring that ourselves gives an
    /// exact color match with zero risk of any other real window bleeding
    /// through, since nothing is being live-composited. macOS's newer
    /// procedural wallpapers (e.g. the animated "Sequoia" gradient style,
    /// confirmed via ~/Library/Application Support/com.apple.wallpaper/
    /// Store/Index.plist using a `com.apple.wallpaper.choice.*` provider
    /// instead of a file) have no such backing image — `desktopImageURL`
    /// just returns a generic system fallback file in that case, which
    /// would render the wrong picture entirely, so that's treated the same
    /// as "no file available."
    private nonisolated static func staticWallpaperImage(from url: URL?, targetPixelSize: CGSize) -> CIImage? {
        guard let url, url.lastPathComponent != "DefaultDesktop.heic" else { return nil }

        // Video-based dynamic wallpapers (macOS's "Aerial"-style landscapes,
        // e.g. the bundled "Tahoe Day.mov") report a plain file URL too, but
        // it's a movie, not an image. These cycle continuously regardless of
        // light/dark mode, so there's no single frame — light, dark, or
        // otherwise — that's ever reliably "correct" to freeze on; falling
        // through to a live desktop snapshot (below, via returning `nil`
        // here) always matches whatever's actually on screen instead of
        // guessing.
        if url.pathExtension.lowercased() == "mov" {
            return nil
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        // A Dynamic Desktop picture — or a picture with distinct Light/Dark
        // variants — is a *single* file containing multiple embedded
        // images; which one macOS is actually showing depends on time of
        // day and/or current appearance, encoded in private per-image
        // metadata this doesn't attempt to parse. Blindly reading index 0
        // (as this used to) always grabbed the light/first-in-file frame,
        // which is why dark mode never rendered correctly. A plain
        // single-image file (`count == 1`) has no such ambiguity — only
        // multi-frame files fall through to the live snapshot below, which
        // reflects whichever frame is actually currently on screen without
        // needing to decode which one that is.
        let imageCount = CGImageSourceGetCount(source)
        guard imageCount == 1 else { return nil }

        // Wallpaper source files can be dramatically higher resolution than
        // the screen (observed: a 6016×6016 source backing a 2560×1440
        // display — 25× more pixels than ever get shown). `CIImage(
        // contentsOf:)` decodes the file at full resolution regardless, and
        // it turns out downscaling *after* that with `.transformed(by:)`
        // doesn't avoid the cost — Core Image's render graph still
        // materializes the full-size source internally before applying the
        // transform (confirmed via `vmmap`: a 138MB IOSurface at the full
        // 6016×6016 size was still allocated even with a scale-down
        // transform applied downstream). `CGImageSourceCreateThumbnailAtIndex`
        // decodes and downsamples in one step instead — for a tiled format
        // like HEIC it never materializes the full-resolution bitmap at
        // all, which is the only way to actually avoid paying for those
        // pixels rather than just discarding them after the fact.
        let maxPixelSize = max(targetPixelSize.width, targetPixelSize.height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return CIImage(contentsOf: url)
        }
        return CIImage(cgImage: cgImage)
    }

    /// Grabs a real screenshot of just the desktop-picture layer — the
    /// backmost window on screen, owned by the Dock process, sitting below
    /// every real app window — so procedural/animated wallpapers (which
    /// have no file to read) show their actual live colors instead of a
    /// generic stand-in image, without capturing any other app's window
    /// (nothing else is *below* the desktop picture to accidentally
    /// include). Requires Screen Recording permission; returns `nil`
    /// without one (silently — never prompts here) so the caller can fall
    /// back further.
    private nonisolated static func liveDesktopSnapshotImage(screenFrame: NSRect) -> CIImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }

        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        let desktopWindow = windowList.first { info in
            guard info[kCGWindowOwnerName as String] as? String == "Dock",
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer < 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"]
            else { return false }
            return width >= screenFrame.width && height >= screenFrame.height
        }

        guard let windowID = desktopWindow?[kCGWindowNumber as String] as? CGWindowID,
              let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, .bestResolution)
        else { return nil }

        return CIImage(cgImage: cgImage)
    }

    private nonisolated static func blurredAndTinted(_ ciImage: CIImage, targetPixelSize: CGSize, context: CIContext) -> NSImage? {
        // Wallpaper *source* images can be dramatically higher resolution
        // than the actual screen — one observed case was a 6016×6016 source
        // for a 2560×1440 display, over 25× more pixels than ever get shown.
        // Blurring destroys fine detail anyway, so processing at full source
        // resolution bought nothing but cost a lot: `vmmap` on a real run
        // showed Core Image allocating dozens of IOSurface buffers up to
        // 138MB each for that single blur, pushing the app's resident memory
        // over 800MB. Downscaling to the screen's actual pixel size *before*
        // blurring — still comfortably more resolution than a heavily
        // blurred, blended-with-content backdrop needs — cuts that by
        // roughly the same 25× factor, before any of the actually-expensive
        // blur work happens.
        // Only ever scales *down* (never up, for a source already at or
        // below screen resolution — e.g. the live-snapshot path, which is
        // already close to native screen pixels) — and the blur radius
        // scales down by the same factor, so the on-screen blur strength
        // looks the same as it always did rather than suddenly changing for
        // whichever path happens to need downscaling this time.
        let scale = min(min(targetPixelSize.width / ciImage.extent.width, targetPixelSize.height / ciImage.extent.height), 1)
        let downscaled = scale < 1
            ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : ciImage

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = downscaled.clampedToExtent()
        blur.radius = Float(90 * scale)
        guard let blurred = blur.outputImage?.cropped(to: downscaled.extent) else { return nil }

        let tint = CIFilter.colorControls()
        tint.inputImage = blurred
        tint.brightness = -0.06
        tint.saturation = 1.05
        guard let finalImage = tint.outputImage else { return nil }

        // Rendering explicitly into a concrete `CGImage` here — rather than
        // wrapping the still-lazy `finalImage` in an `NSCIImageRep` — is
        // what actually does the expensive work now, off the main thread,
        // instead of leaving it to fire the first time an `NSImageView`
        // draws it later on the main thread.
        guard let cgImage = context.createCGImage(finalImage, from: downscaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
