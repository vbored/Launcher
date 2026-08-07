import AppKit
import Foundation

/// A single launchable application, ready for display in the grid.
struct AppInfo: Identifiable, Hashable, @unchecked Sendable {
    let id: String // bundle identifier, falls back to path for identifier-less bundles
    let name: String
    let bundleURL: URL
    let icon: NSImage

    static func == (lhs: AppInfo, rhs: AppInfo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Holds the current app list so the grid can be shown immediately and
/// updates live as `AppQueryEngine`'s background monitor detects installs
/// or removals — no manual rescan needed.
@MainActor
final class AppStore: ObservableObject {
    @Published var apps: [AppInfo] = []
}

/// Keeps `AppStore.apps` continuously in sync with what's actually
/// installed, using a persistent Spotlight query rather than a one-shot
/// filesystem scan. `NSMetadataQuery` posts a notification every time its
/// result set changes, so installing or deleting an app updates the grid
/// automatically — including while the overlay is already open — with no
/// need to reopen Launcher for the list to catch up. Confirmed end to end
/// by installing and removing a real test app while monitoring: both showed
/// up within seconds, with no relaunch.
@MainActor
final class AppQueryEngine {
    static let shared = AppQueryEngine()

    private let searchPaths: [String] = {
        var paths = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices/Applications",
        ]
        paths.append(FileManager.default.homeDirectoryForCurrentUser.path + "/Applications")
        return paths
    }()

    private var query: NSMetadataQuery?
    private var backgroundActivityToken: NSObjectProtocol?
    private var fallbackTimer: Timer?

    nonisolated private static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.bored.launcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("apps.json")
    }()

    // Every refresh spawns a `Task` to do the (slow-ish) icon-loading
    // enrichment concurrently with whatever Spotlight notification arrives
    // next. Without tracking and cancelling the previous one, a slower
    // *older* task can finish after a newer one and clobber `store.apps`
    // with stale data — an out-of-order-completion race that briefly looked
    // exactly like the live monitor not working at all.
    private var enrichmentTask: Task<Void, Never>?

    // Spotlight's own `NSMetadataQuery` gather is not instant — a *fresh*
    // process always starts this from zero, which is exactly what "opening
    // the app also takes time to load the apps" describes: the grid shows
    // immediately (that part's already fast), but sits empty for however
    // long this first gather takes. `hasReceivedLiveResults` lets the
    // cache-priming path below know whether it's still safe to populate
    // `store.apps` — once the real gather has answered even once, cached
    // data is never allowed to overwrite it.
    private var hasReceivedLiveResults = false

    /// Starts the persistent monitor. Call once, at launch; safe to call
    /// again (a no-op) if a monitor is already running.
    func startMonitoring(store: AppStore) {
        guard query == nil else { return }

        // Uses Spotlight's existing index instead of walking the
        // filesystem. A plain recursive directory walk both misses
        // symlinked bundles — `/Applications/Safari.app` has pointed into a
        // system cryptex since Sonoma, and was silently dropped by
        // `FileManager`'s enumerator — and can get stuck traversing huge
        // non-app folders some dev tools drop into `/Applications` (MAMP's
        // bundled Apache/PHP/MySQL tree alone is over 56,000 files deep,
        // contributing zero real apps, and was the dominant cost in every
        // scan). Spotlight already resolves the former correctly and only
        // indexes actual application bundles, sidestepping both problems.
        //
        // Built (and its observers registered) before the cache-priming
        // task below, but not `start()`-ed until inside that task — see the
        // comment down there for why.
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemContentType == 'com.apple.application-bundle'")
        // Custom path-array scopes work fine for a one-shot gather, but
        // live-update notifications didn't fire reliably against them in
        // testing. The predefined local-computer scope keeps live updates
        // working; the predicate still filters down to application bundles,
        // and `refresh` filters again down to just `searchPaths` below.
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        self.query = query

        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self] _ in
            self?.refresh(query: query, into: store)
        }

        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [weak self] _ in
            self?.refresh(query: query, into: store)
        }

        // Without this, macOS App Naps this process once it's backgrounded
        // (an `.accessory` app with its window hidden looks exactly like an
        // idle background app to the OS), which risks throttling the live
        // Spotlight monitor. No natural end point, so it's never balanced
        // with `endActivity` — it should last the app's whole lifetime.
        backgroundActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Keep the Spotlight app monitor live-updating in the background"
        )

        // Show last session's app list immediately, before Spotlight has
        // gathered anything — it's re-verified (icons freshly re-loaded,
        // not reused from disk) rather than trusted blindly, and gets
        // replaced the moment the live query actually answers, so a stale
        // cache (an app installed/removed since last run) only shows
        // briefly instead of leaving the grid empty the whole time.
        //
        // `Task.detached`, not a plain `Task` — a plain `Task` here inherits
        // this method's `MainActor` context, and profiling (temporary
        // instrumentation) showed it sitting queued for ~290ms before
        // actually running: the main run loop was still busy with the
        // overlay's own open animation at the exact moment this got
        // scheduled, and a MainActor-bound `Task` has to wait its turn
        // behind that. None of this work — reading the cache file, loading
        // icons — needs the main actor at all until the very last step, so
        // detaching it entirely sidesteps that contention.
        //
        // Starting Spotlight's own gather (`query.start()`, below) also
        // happens from inside this same task now, rather than on a fixed
        // timer independent of it: on a cache-less run — first-ever launch,
        // or right after this app's bundle identifier changed and the cache
        // location moved with it — there's nothing for a head start to
        // protect, and unconditionally waiting a quarter second anyway was
        // pure dead time stacked directly on top of an already-empty grid,
        // which is exactly what "slow to show apps" describes. Only the
        // genuinely-has-a-cache path still gives it that head start.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let cachedPaths = Self.loadCachedPaths() else {
                await MainActor.run { query.start() }
                return
            }

            let urls = cachedPaths.map { URL(fileURLWithPath: $0) }
            let infos = await Self.loadAll(urls: urls)
            await MainActor.run {
                guard let self, !self.hasReceivedLiveResults, !infos.isEmpty else { return }
                store.apps = infos
            }

            // `query.start()` itself is what kicks off Spotlight's actual
            // on-disk gather — and profiling showed it competing with the
            // cache-priming work above for disk I/O when both start at
            // once: loading the *same* 126 apps' icons took 86ms in
            // isolation, but 300-700ms when racing this. This short,
            // deliberate head start lets the cache path — what the user
            // actually sees first — finish largely undisturbed before
            // Spotlight's heavier gather ramps up. Delaying live results by
            // a couple hundred milliseconds is imperceptible when a cache
            // is already on screen; it's only free when there's nothing
            // being protected, which is why the no-cache branch above skips
            // it entirely instead of applying it unconditionally.
            try? await Task.sleep(nanoseconds: 250_000_000)
            await MainActor.run { query.start() }
        }

        // Belt-and-suspenders re-read on a timer, independent of whether an
        // update notification fires. Cheap — it's just a `resultCount` read
        // against the query's already-live index, not a fresh filesystem or
        // Spotlight query — and it guarantees the grid can never drift for
        // more than 20 seconds even in some edge case the notification path
        // doesn't cover.
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refresh(query: query, into: store)
        }
    }

    private func refresh(query: NSMetadataQuery, into store: AppStore) {
        // Bracketing the read with disable/enable is NSMetadataQuery's
        // documented way to snapshot results without the index mutating
        // them out from under you mid-read.
        query.disableUpdates()
        let urls: [URL] = (0..<query.resultCount).compactMap { index in
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  // Local-computer scope (needed for live updates — see
                  // above) returns every indexed app anywhere, including one
                  // sitting in ~/Downloads or on a mounted disk image.
                  // Restrict back down to the standard install locations
                  // classic Launchpad actually draws from.
                  searchPaths.contains(where: path.hasPrefix)
            else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        query.enableUpdates()

        enrichmentTask?.cancel()
        enrichmentTask = Task {
            let infos = await Self.loadAll(urls: urls)
            guard !Task.isCancelled else { return }
            self.hasReceivedLiveResults = true
            store.apps = infos
            Self.saveCachedPaths(infos.map { $0.bundleURL.path })
        }
    }

    nonisolated private static func loadCachedPaths() -> [String]? {
        guard let data = try? Data(contentsOf: cacheURL),
              let paths = try? JSONDecoder().decode([String].self, from: data),
              !paths.isEmpty
        else { return nil }
        return paths
    }

    nonisolated private static func saveCachedPaths(_ paths: [String]) {
        guard let data = try? JSONEncoder().encode(paths) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func loadAll(urls: [URL]) async -> [AppInfo] {
        var seenIdentifiers = Set<String>()
        var results: [AppInfo] = []

        await withTaskGroup(of: AppInfo?.self) { group in
            for url in urls {
                group.addTask { loadAppInfo(at: url) }
            }
            for await info in group {
                guard let info else { continue }
                if seenIdentifiers.insert(info.id).inserted {
                    results.append(info)
                }
            }
        }

        return results.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // Deliberately `nonisolated`: this does synchronous plist/icon I/O and
    // is called concurrently from a `TaskGroup` for every installed app.
    // Leaving it MainActor-isolated (inherited from the class by default)
    // would serialize every one of those calls onto the main thread despite
    // the surrounding concurrency, which is exactly the mistake that made
    // large `/Applications` folders slow to scan before.
    nonisolated private static func loadAppInfo(at url: URL) -> AppInfo? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }

        // `LSBackgroundOnly` means the app has no UI at all to launch into —
        // a pure background agent, worth excluding. `LSUIElement` only means
        // "no Dock icon by default"; Apple uses it on plenty of apps classic
        // Launchpad still shows (Screenshot, Docker, Mission Control, Time
        // Machine), so filtering on it excluded real apps, not just clutter.
        if let backgroundOnly = info["LSBackgroundOnly"] as? Bool, backgroundOnly {
            return nil
        }

        let identifier = (info["CFBundleIdentifier"] as? String) ?? url.path
        let displayName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent

        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 128, height: 128)

        return AppInfo(id: identifier, name: displayName, bundleURL: url, icon: image)
    }
}
