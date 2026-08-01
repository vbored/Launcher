import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Either a plain app or a folder of apps, as shown in the grid — lets
/// `pages` mix the two the same way classic Launchpad does, sorted together
/// by display name.
private enum LaunchItem: Identifiable, Hashable {
    case app(AppInfo)
    case folder(AppFolder)

    var id: String {
        switch self {
        case .app(let app): return app.id
        case .folder(let folder): return "folder:\(folder.id.uuidString)"
        }
    }

    var sortName: String {
        switch self {
        case .app(let app): return app.name
        case .folder(let folder): return folder.name
        }
    }
}

/// Full-screen, paginated app grid. `TabView`'s `.page` style is iOS-only,
/// so paging is built from a horizontal `ScrollView` with native
/// `.scrollTargetBehavior(.paging)` snapping (macOS 14+), which also gets
/// trackpad two-finger swipe for free. A custom dot row mirrors the classic
/// Launchpad page indicator, and a top search field live-filters the grid.
struct GridView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var folderStore: FolderStore
    let onDismiss: () -> Void

    @State private var currentPage: Int?
    @State private var launchingID: String?
    @State private var hoveredID: String?
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    // The folder currently open in the detail overlay, if any. Looked up
    // live from `folderStore.folders` by id wherever it's needed (rather
    // than held as a snapshot) so removing/adding apps while the folder is
    // open updates it immediately instead of showing stale contents.
    @State private var openFolderID: UUID?

    // Captured from the grid's own `GeometryReader` so the folder-detail
    // overlay (a ZStack sibling, outside that GeometryReader) can size its
    // icons and panel proportionally to the same screen instead of using
    // fixed point values — a fixed size looked fine on the screen it was
    // eyeballed against and comically small on a larger display.
    @State private var gridContainerSize: CGSize = .zero

    // `pages` used to be a computed property, re-filtering and re-chunking
    // the entire app list on *every* SwiftUI body evaluation — which fires
    // on every hover event and every scroll-position tick while paging.
    // Redoing that work dozens of times a second while swiping was the
    // actual cause of the slow/glitchy transitions: recomputed here once,
    // only when the underlying data (`store.apps`, `searchText`,
    // `folderStore.folders`) actually changes, instead of on every render.
    @State private var pages: [[LaunchItem]] = []

    private let columns = 7
    private let rows = 5

    // SwiftUI's plain `withAnimation { }` uses the implicit default spring
    // (~0.55s, fairly loose), which reads as noticeably sluggish next to
    // classic Launchpad's snappy page-flip — and next to the native
    // trackpad-swipe paging above, which uses its own quick system physics.
    // Using the same explicit, quick curve everywhere a page change is
    // triggered programmatically (mouse-drag release, page-dot tap) keeps
    // every path feeling consistent and fast.
    fileprivate static let pageChangeAnimation: Animation = .easeOut(duration: 0.28)

    /// Column width and icon size for a grid laid out across `contentWidth`
    /// with `columns` columns — the exact formula the main paged grid uses,
    /// pulled out so the folder-detail overlay can compute the identical
    /// icon size for the same screen instead of a separately-tuned
    /// constant that only happened to look right on one reference display.
    private static func mainGridMetrics(contentWidth: CGFloat, columns: Int) -> (cellWidth: CGFloat, iconSize: CGFloat) {
        let horizontalSpacing: CGFloat = 32
        let cellWidth = (contentWidth - horizontalSpacing * CGFloat(columns - 1)) / CGFloat(columns)
        // 0.45 undershot next to the reference once rendered — bumped to
        // 0.55, with the cap raised to match so it doesn't get clipped back
        // down on typical screen widths.
        let iconSize = min(max(cellWidth * 0.55, 64), 140)
        return (cellWidth, iconSize)
    }

    var body: some View {
        ZStack {
            // Anything not covered by an icon dismisses the overlay on tap.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 20) {
                SearchField(text: $searchText, isFocused: $searchFocused)
                    .padding(.top, 28)

                GeometryReader { geo in
                    // Classic Launchpad's centered, "framed" look (content at
                    // ~68% of screen width, matched off a reference
                    // screenshot) used to be done with horizontal padding
                    // applied *inside* each page. That put each page's own
                    // margin inside its own scroll-content slot, so
                    // mid-transition — with two adjacent pages each partially
                    // visible — both pages' margins landed in the middle of
                    // the screen at once: a ~32%-wide blank gap between the
                    // outgoing and incoming icons (confirmed frame-by-frame
                    // in a user-provided recording). Constraining the
                    // ScrollView itself to that 68% width instead, and
                    // sizing pages to fill it exactly with zero padding,
                    // moves the margin outside the scrollable area entirely
                    // — it's just static background on either side that
                    // never moves, and adjacent pages slide directly flush
                    // against each other with no gap.
                    let contentWidth = geo.size.width * 0.68

                    VStack(spacing: 20) {
                        ScrollView(.horizontal) {
                            // Plain `HStack`, not `LazyHStack`: a Mac's page
                            // count is small (even a heavily-loaded machine
                            // rarely exceeds 8-10 pages of 35 apps each), and
                            // laziness was costing more than it saved —
                            // pages just outside the lazy-load window could
                            // still be settling their layout while a fast
                            // swipe reached them, which is what produced the
                            // brief "two pages' icons visible at once"
                            // glitch. Laying out every page up front avoids
                            // that entirely, at negligible memory cost.
                            HStack(spacing: 0) {
                                ForEach(Array(pages.enumerated()), id: \.offset) { index, pageApps in
                                    pageGrid(pageApps, containerWidth: contentWidth, containerHeight: geo.size.height)
                                        .containerRelativeFrame(.horizontal)
                                        .id(index)
                                }
                            }
                            .scrollTargetLayout()
                            .background(ScrollbarHider())
                        }
                        .frame(width: contentWidth)
                        .scrollTargetBehavior(QuickPagingBehavior())
                        .scrollPosition(id: $currentPage)
                        .scrollIndicators(.hidden)
                        .scrollDisabled(pages.count <= 1)
                        // Trackpad two-finger swipe already works above for
                        // free via the ScrollView's native paging. Plain
                        // mouse click-drag needs separate handling since
                        // AppKit doesn't route that to scroll views at all —
                        // but a SwiftUI `DragGesture` composed alongside the
                        // ScrollView (via `.simultaneousGesture`) turned out
                        // to *also* intermittently respond to trackpad pans,
                        // racing the ScrollView's own native snap decision
                        // and producing exactly the "pages overlapping"
                        // glitch reported during testing — two independent
                        // systems both animating to a (sometimes different)
                        // final page. A raw local event monitor watching
                        // only genuine `leftMouseDown`/`leftMouseUp` sees
                        // nothing when a trackpad is swiped (that arrives as
                        // `.scrollWheel` events instead), so it can't
                        // conflict by construction.
                        .background(
                            MouseDragPager { translation in
                                let threshold: CGFloat = 80
                                let page = currentPage ?? 0
                                if translation < -threshold {
                                    withAnimation(Self.pageChangeAnimation) { currentPage = min(page + 1, pages.count - 1) }
                                } else if translation > threshold {
                                    withAnimation(Self.pageChangeAnimation) { currentPage = max(page - 1, 0) }
                                }
                            }
                        )

                        if pages.count > 1 {
                            PageIndicator(count: pages.count, currentPage: $currentPage)
                        }
                    }
                    // Constraining the ScrollView to `contentWidth` makes it
                    // (and this whole VStack, which sizes to its widest
                    // child) narrower than the GeometryReader itself — and
                    // GeometryReader places a narrower child at its
                    // top-leading corner, not centered, which left all the
                    // now-unused width as blank space on the right instead
                    // of splitting it evenly on both sides. Explicitly
                    // filling and centering within the GeometryReader's full
                    // width restores the centered, framed look.
                    .frame(maxWidth: .infinity)
                    .onAppear { gridContainerSize = geo.size }
                    .onChange(of: geo.size) { gridContainerSize = geo.size }
                }
            }

            // Drawn above the grid, its own scrim intercepting taps so the
            // grid underneath doesn't also react to them. Kept as a
            // sibling in this outer ZStack (rather than nested inside the
            // GeometryReader above) so it's sized to the whole overlay, not
            // just the 68%-wide framed content area.
            if let folderID = openFolderID, let folder = folderStore.folders.first(where: { $0.id == folderID }) {
                let gridContentWidth = gridContainerSize.width * 0.68
                let (_, folderIconSize) = Self.mainGridMetrics(
                    contentWidth: gridContentWidth,
                    columns: columns
                )
                FolderDetailView(
                    folder: folder,
                    apps: apps(in: folder),
                    iconSize: folderIconSize,
                    gridContentWidth: gridContentWidth,
                    launchingID: launchingID,
                    onLaunch: { launch($0) },
                    onRemove: { appID in
                        folderStore.removeApp(appID)
                        recomputePages()
                    },
                    onRename: { newName in folderStore.rename(folder.id, to: newName) },
                    onClose: { openFolderID = nil }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
                .zIndex(10)
            }
        }
        .onAppear {
            appsByID = Dictionary(uniqueKeysWithValues: store.apps.map { ($0.id, $0) })
            folderStore.seedUtilitiesFolderIfNeeded(from: store.apps)
            recomputePages()
        }
        .onChange(of: store.apps) {
            appsByID = Dictionary(uniqueKeysWithValues: store.apps.map { ($0.id, $0) })
            folderStore.seedUtilitiesFolderIfNeeded(from: store.apps)
            recomputePages()
        }
        .onChange(of: folderStore.folders) { recomputePages() }
        .onChange(of: searchText) {
            currentPage = 0
            recomputePages()
        }
        .onExitCommand {
            if openFolderID != nil {
                openFolderID = nil
            } else if !searchText.isEmpty {
                searchText = ""
            } else {
                onDismiss()
            }
        }
    }

    /// Rebuilt only when `store.apps` itself changes (not on every folder
    /// edit or search keystroke) and reused by `apps(in:)` — building this
    /// fresh on every call was the actual cost: `apps(in:)` runs once per
    /// *folder icon rendered*, so on a grid with several folders spread
    /// across pages, the naive version was rebuilding an O(n) dictionary
    /// out of the entire app list several times over on every single
    /// render pass.
    @State private var appsByID: [String: AppInfo] = [:]

    /// Resolves a folder's stored app identifiers against the live app
    /// list, in the folder's own stored order. An identifier whose app was
    /// since uninstalled simply drops out (no explicit cleanup needed —
    /// `FolderStore` doesn't know or care about apps it's never told to
    /// remove).
    private func apps(in folder: AppFolder) -> [AppInfo] {
        folder.appIDs.compactMap { appsByID[$0] }
    }

    private func recomputePages() {
        let perPage = max(columns * rows, 1)
        let newPages: [[LaunchItem]]

        if searchText.isEmpty {
            // Top level shows every app not currently tucked inside a
            // folder, plus one icon per folder, sorted together by name —
            // matching classic Launchpad's alphabetical-with-folders-mixed-in
            // layout rather than pinning folders to a fixed position.
            //
            // `store.apps` already arrives sorted by name (see
            // `AppQueryEngine.loadAll`), and filtering preserves that order
            // — so re-sorting the whole (often 100+ item) app list here on
            // every recompute was pure waste; a locale-aware string compare
            // per element adds up on the main thread and was making every
            // app-list refresh and folder edit feel a beat slower than it
            // needed to. Folders are typically a handful at most, so only
            // sorting *them* and then doing an O(n) merge against the
            // already-sorted apps gets the identical interleaved order for
            // a fraction of the cost.
            let folderedIDs = Set(folderStore.folders.flatMap { $0.appIDs })
            let topApps: [LaunchItem] = store.apps
                .filter { !folderedIDs.contains($0.id) }
                .map { .app($0) }
            let folderItems: [LaunchItem] = folderStore.folders
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { .folder($0) }

            var items: [LaunchItem] = []
            items.reserveCapacity(topApps.count + folderItems.count)
            var i = 0, j = 0
            while i < topApps.count, j < folderItems.count {
                if topApps[i].sortName.localizedStandardCompare(folderItems[j].sortName) != .orderedDescending {
                    items.append(topApps[i]); i += 1
                } else {
                    items.append(folderItems[j]); j += 1
                }
            }
            items.append(contentsOf: topApps[i...])
            items.append(contentsOf: folderItems[j...])

            newPages = stride(from: 0, to: items.count, by: perPage).map {
                Array(items[$0..<min($0 + perPage, items.count)])
            }
        } else {
            // While searching, match against every app regardless of
            // folder membership — including apps tucked inside a folder,
            // since the whole point of search is not needing to remember
            // which folder something's in — and show them flat.
            let matches = store.apps
                .filter { $0.name.localizedCaseInsensitiveContains(searchText) }
                .map { LaunchItem.app($0) }
            newPages = stride(from: 0, to: matches.count, by: perPage).map {
                Array(matches[$0..<min($0 + perPage, matches.count)])
            }
        }
        // The live app-list monitor can update `store.apps` several times in
        // quick succession while it's still settling (initial gather, then
        // follow-up updates) — each one reshuffles which app lands on which
        // page. Without this, SwiftUI implicitly cross-fades the `ForEach`
        // between the old and new page contents, which for a brief moment
        // visibly overlapped two different apps' labels at the same grid
        // position. Disabling animation for this specific assignment makes
        // it a clean, instant swap instead.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pages = newPages
        }
    }

    /// Icons scale with the available cell width instead of a fixed size,
    /// so they fill their grid cell the way classic Launchpad's do rather
    /// than looking small and lost on wide/high-column-count screens.
    ///
    /// `containerWidth` here is already the narrowed, framed content width
    /// (the caller constrains the ScrollView itself to ~68% of the screen)
    /// — this just fills it edge to edge, with no additional margin of its
    /// own, so adjacent pages sit flush against each other with no gap
    /// during a swipe.
    @ViewBuilder
    private func pageGrid(_ pageItems: [LaunchItem], containerWidth: CGFloat, containerHeight: CGFloat) -> some View {
        let horizontalSpacing: CGFloat = 32
        let (cellWidth, iconSize) = Self.mainGridMetrics(contentWidth: containerWidth, columns: columns)

        // Row spacing was a fixed 32pt regardless of available height, so 5
        // rows never filled the space — everything stayed top-aligned with
        // a big dead gap before the page dots instead of extending closer
        // to them like real Launchpad's. Deriving it from `containerHeight`
        // the same way column width is derived from `containerWidth` makes
        // the 5 rows actually fill the vertical space.
        let topInset: CGFloat = 40
        let bottomReserve: CGFloat = 48 // room for the page-dot row below
        let labelHeight: CGFloat = 16
        let iconLabelGap: CGFloat = 8
        let rowContentHeight = iconSize + iconLabelGap + labelHeight
        let availableForRows = max(containerHeight - topInset - bottomReserve, rowContentHeight * CGFloat(rows))
        let rowPitch = availableForRows / CGFloat(rows)
        let verticalSpacing = max(rowPitch - rowContentHeight, horizontalSpacing)

        // The tap-to-dismiss catcher lives here (on the grid content) and
        // not on the ScrollView above: stacking a plain `.onTapGesture`
        // directly alongside the ScrollView's `.simultaneousGesture(
        // DragGesture)` reliably broke rendering (confirmed by bisection —
        // the whole overlay stopped compositing at all, even though every
        // Swift-level call still returned normally). Putting it on a
        // separate, more deeply nested view avoids the conflict entirely,
        // and still covers the gaps between icons — the vast majority of
        // the "empty" area a user would actually click.
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: horizontalSpacing), count: columns),
            spacing: verticalSpacing
        ) {
            ForEach(pageItems) { item in
                Group {
                    switch item {
                    case .app(let app):
                        AppIconView(
                            app: app,
                            iconSize: iconSize,
                            labelWidth: cellWidth,
                            isHovered: hoveredID == app.id,
                            isLaunching: launchingID == app.id
                        )
                        .onHover { hoveredID = $0 ? app.id : nil }
                        .onTapGesture { launch(app) }
                        // Only loose apps are draggable — dragging an
                        // existing folder isn't supported (reordering
                        // folders isn't the ask here; grouping apps is).
                        // The payload is just the bundle identifier as
                        // plain text, read back out in `handleDrop`.
                        .onDrag { NSItemProvider(object: app.id as NSString) }
                    case .folder(let folder):
                        FolderIconView(
                            folder: folder,
                            previewApps: apps(in: folder),
                            iconSize: iconSize,
                            labelWidth: cellWidth,
                            isHovered: hoveredID == item.id
                        )
                        .onHover { hoveredID = $0 ? item.id : nil }
                        .onTapGesture { openFolderID = folder.id }
                    }
                }
                // Every icon — app or folder — is a valid drop target: an
                // app dropped on another app spins up a new folder, an app
                // dropped on a folder joins it.
                .onDrop(of: [.text], isTargeted: nil) { providers in
                    handleDrop(providers: providers, onto: item)
                }
            }
        }
        .padding(.top, topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
    }

    /// Reads the dragged app's identifier back out of the drop's
    /// `NSItemProvider` and, once resolved, either folds it into an
    /// existing folder or spins up a brand new one — classic Launchpad's
    /// "drag one app onto another" gesture. Returns `true` immediately (to
    /// accept the drop visually); the actual mutation happens
    /// asynchronously once the identifier finishes loading.
    private func handleDrop(providers: [NSItemProvider], onto target: LaunchItem) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { reading, _ in
            guard let draggedID = reading as? String else { return }
            Task { @MainActor in
                performDrop(draggedID: draggedID, target: target)
            }
        }
        return true
    }

    private func performDrop(draggedID: String, target: LaunchItem) {
        switch target {
        case .app(let targetApp):
            guard draggedID != targetApp.id else { return }
            withAnimation(Self.pageChangeAnimation) {
                _ = folderStore.createFolder(combining: draggedID, with: targetApp.id, defaultName: "New Folder")
            }
        case .folder(let targetFolder):
            guard !targetFolder.appIDs.contains(draggedID) else { return }
            withAnimation(Self.pageChangeAnimation) {
                folderStore.moveApp(draggedID, intoFolder: targetFolder.id)
            }
        }
    }

    private func launch(_ app: AppInfo) {
        guard launchingID == nil else { return }
        launchingID = app.id

        NSWorkspace.shared.openApplication(
            at: app.bundleURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: onDismiss)
    }
}

private struct SearchField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))

            TextField("", text: $text, prompt: Text("Search").foregroundStyle(.white.opacity(0.55)))
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .font(.system(size: 13))
                .focused(isFocused)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(width: 240)
        .background(Capsule().fill(.white.opacity(0.14)))
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        .onAppear { isFocused.wrappedValue = true }
    }
}

/// Apple's stock `.paging` scroll target behavior seems to require a fairly
/// large drag distance (or a very fast velocity) to commit to changing
/// pages — fine for a continuous trackpad drag, but a Magic Mouse's swipe
/// gesture is a short, quick flick rather than a sustained drag, and often
/// doesn't clear that bar. The result: the swipe registers, but the page
/// snaps right back to where it started instead of advancing, reading as
/// "slow to respond" — the first swipe seems to do nothing, and it takes a
/// second, more deliberate one to actually move. This behavior commits to
/// the next/previous page on either a smaller drag distance (roughly a
/// sixth of the page width) *or* a fast-enough flick regardless of distance
/// travelled, so a short, fast swipe (Magic Mouse) and a longer, slower
/// drag (trackpad) both reliably change pages on the first try.
private struct QuickPagingBehavior: ScrollTargetBehavior {
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let pageWidth = context.containerSize.width
        guard pageWidth > 0, context.contentSize.width > pageWidth else { return }

        let originalOffset = context.originalTarget.rect.minX
        let proposedOffset = target.rect.minX
        let velocity = context.velocity.dx

        let currentPage = (originalOffset / pageWidth).rounded()
        var destinationPage = currentPage

        let distanceThreshold = pageWidth / 6
        let velocityThreshold: CGFloat = 200

        if proposedOffset - originalOffset > distanceThreshold || velocity > velocityThreshold {
            destinationPage = currentPage + 1
        } else if originalOffset - proposedOffset > distanceThreshold || velocity < -velocityThreshold {
            destinationPage = currentPage - 1
        }

        let maxOffset = context.contentSize.width - pageWidth
        target.rect.origin.x = min(max(destinationPage * pageWidth, 0), maxOffset)
    }
}

/// Detects genuine mouse click-drag-release sequences via a raw local event
/// monitor rather than SwiftUI's `DragGesture`. Trackpad two-finger swipes
/// arrive as `.scrollWheel` events, never `.leftMouseDown`/`.leftMouseUp`, so
/// this can't ever fire for one — unlike `DragGesture` composed alongside a
/// `ScrollView`, which was found to sometimes respond to trackpad pans too,
/// racing the ScrollView's own native paging. The monitor only observes
/// events (always returning them unmodified), so it never blocks normal
/// clicks on icons, the search field, or page dots.
private struct MouseDragPager: NSViewRepresentable {
    let onSwipe: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSwipe: onSwipe)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        private let onSwipe: (CGFloat) -> Void
        private var monitor: Any?
        private var startPoint: NSPoint?

        init(onSwipe: @escaping (CGFloat) -> Void) {
            self.onSwipe = onSwipe
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                guard let self else { return event }
                switch event.type {
                case .leftMouseDown:
                    self.startPoint = event.locationInWindow
                case .leftMouseUp:
                    if let start = self.startPoint {
                        self.onSwipe(event.locationInWindow.x - start.x)
                    }
                    self.startPoint = nil
                default:
                    break
                }
                return event
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}

/// `.scrollIndicators(.hidden)` only suppresses the modern overlay
/// scroller; when the system-wide "Show scroll bars: Always" preference is
/// on, AppKit falls back to a legacy `NSScroller` that ignores it. This
/// reaches into the `ScrollView`'s backing `NSScrollView` and turns the
/// scroller off directly so no track/thumb is ever drawn.
private struct ScrollbarHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { hideScrollers(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        hideScrollers(from: nsView)
    }

    private func hideScrollers(from view: NSView) {
        guard let scrollView = view.enclosingScrollView else { return }
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
    }
}

private struct PageIndicator: View {
    let count: Int
    @Binding var currentPage: Int?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == (currentPage ?? 0) ? Color.white : Color.white.opacity(0.35))
                    .frame(width: 7, height: 7)
                    .onTapGesture {
                        withAnimation(GridView.pageChangeAnimation) { currentPage = index }
                    }
            }
        }
        .padding(.bottom, 24)
    }
}

private struct AppIconView: View {
    let app: AppInfo
    let iconSize: CGFloat
    let labelWidth: CGFloat
    let isHovered: Bool
    let isLaunching: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: app.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
                .scaleEffect(isLaunching ? 0.85 : (isHovered ? 1.08 : 1.0))
                .opacity(isLaunching ? 0.4 : 1.0)
                .animation(.spring(response: 0.28, dampingFraction: 0.6), value: isHovered)
                .animation(.easeOut(duration: 0.18), value: isLaunching)

            Text(app.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: labelWidth)
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        }
        .contentShape(Rectangle())
    }
}

/// A folder's grid icon: a translucent rounded "tray" holding up to 9 of
/// its apps' actual icons in a mini 3x3 preview, the same idea as classic
/// Launchpad's folder stack.
private struct FolderIconView: View {
    let folder: AppFolder
    let previewApps: [AppInfo]
    let iconSize: CGFloat
    let labelWidth: CGFloat
    let isHovered: Bool

    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous)
                .fill(.white.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous)
                        .stroke(.white.opacity(0.22), lineWidth: 1)
                )
                .overlay(miniGrid.padding(iconSize * 0.13))
                .frame(width: iconSize, height: iconSize)
                .scaleEffect(isHovered ? 1.08 : 1.0)
                .animation(.spring(response: 0.28, dampingFraction: 0.6), value: isHovered)

            Text(folder.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: labelWidth)
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        }
        .contentShape(Rectangle())
    }

    private var miniGrid: some View {
        let shown = Array(previewApps.prefix(9))
        let miniColumns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)
        return LazyVGrid(columns: miniColumns, spacing: 3) {
            ForEach(shown) { app in
                Image(nsImage: app.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
    }
}

/// The expanded, centered panel shown when a folder is tapped — its own
/// scrim behind it closes just the folder (not the whole overlay) on tap,
/// mirroring classic Launchpad's folder-open behavior. The folder's name is
/// directly editable; hovering an app inside reveals a small remove button
/// that drops it back to the top-level grid.
private struct FolderDetailView: View {
    let folder: AppFolder
    let apps: [AppInfo]
    let iconSize: CGFloat
    // The main grid's own width, as a floor for the panel below — real
    // Launchpad's folder card is a big, dominant piece of the screen
    // regardless of how few apps are in the folder; sizing purely off
    // column-count × iconSize (the previous approach) meant a folder with
    // only a handful of apps rendered a noticeably small, almost
    // apologetic little card instead.
    let gridContentWidth: CGFloat
    let launchingID: String?
    let onLaunch: (AppInfo) -> Void
    let onRemove: (String) -> Void
    let onRename: (String) -> Void
    let onClose: () -> Void

    @State private var nameText: String = ""
    @FocusState private var nameFocused: Bool
    @State private var hoveredID: String?

    // 7, not 5 — matches classic Launchpad's own folder grid, and reaching
    // a wider fixed column count is what actually gets the panel up to a
    // "large like the original" footprint rather than a fixed multiplier
    // on top of the same column count the main grid already used.
    private let columns = 7
    private var gridSpacing: CGFloat { iconSize * 0.3 }
    private var labelWidth: CGFloat { iconSize * 1.2 }
    private var panelPadding: CGFloat { iconSize * 0.4 }
    private var titleFontSize: CGFloat { max(20, iconSize * 0.22) }
    private var removeButtonFontSize: CGFloat { max(15, iconSize * 0.16) }
    private var panelMaxWidth: CGFloat {
        let contentDriven = CGFloat(columns) * iconSize + CGFloat(columns - 1) * gridSpacing + panelPadding * 2
        // Never smaller than ~72% of the main grid's own width (capped so
        // it doesn't run edge-to-edge on an ultra-wide display), and never
        // smaller than what the icons themselves need if that's larger —
        // e.g. a folder that somehow has enormous icons on a tiny screen.
        let screenFloor = min(gridContentWidth * 0.72, 1100)
        return max(contentDriven, screenFloor)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)

            VStack(spacing: panelPadding * 0.55) {
                TextField("Folder Name", text: $nameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: titleFontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .focused($nameFocused)
                    .onSubmit { nameFocused = false }
                    .frame(maxWidth: panelMaxWidth * 0.6)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columns),
                    spacing: gridSpacing
                ) {
                    ForEach(apps) { app in
                        ZStack(alignment: .topLeading) {
                            AppIconView(
                                app: app,
                                iconSize: iconSize,
                                labelWidth: labelWidth,
                                isHovered: hoveredID == app.id,
                                isLaunching: launchingID == app.id
                            )
                            .onHover { hoveredID = $0 ? app.id : nil }
                            .onTapGesture { onLaunch(app) }

                            if hoveredID == app.id {
                                Button {
                                    hoveredID = nil
                                    onRemove(app.id)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.55))
                                        .font(.system(size: removeButtonFontSize))
                                }
                                .buttonStyle(.plain)
                                .offset(x: -6, y: -6)
                            }
                        }
                    }
                }
            }
            .padding(panelPadding)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(.white.opacity(0.15), lineWidth: 1)
            )
            .frame(maxWidth: panelMaxWidth)
        }
        .onAppear { nameText = folder.name }
        // Fires on every route out of the folder — background tap, Escape
        // (handled up in `GridView.onExitCommand`, which just clears
        // `openFolderID` and lets this view disappear), or opening a
        // different folder — so a typed rename is never silently lost
        // regardless of how the panel closed.
        .onDisappear { onRename(nameText) }
    }
}

