import Foundation

/// A user-defined (or auto-seeded) grouping of apps, shown as a single
/// folder icon in the grid — mirrors classic Launchpad folders. Membership
/// is stored by app identifier (matches `AppInfo.id`) rather than by
/// position, so a folder survives the live app list being re-sorted or
/// re-scanned underneath it.
struct AppFolder: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var appIDs: [String]

    init(id: UUID = UUID(), name: String, appIDs: [String]) {
        self.id = id
        self.name = name
        self.appIDs = appIDs
    }
}

/// Persists user-created folders to disk (JSON in Application Support, next
/// to nothing else — this app has no other on-disk state besides
/// `AppQueryEngine`'s unrelated icon-path cache) and exposes the mutations
/// the grid's drag-and-drop and folder-detail UI need.
@MainActor
final class FolderStore: ObservableObject {
    @Published private(set) var folders: [AppFolder] = []

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.bored.launcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("folders.json")
    }()

    // Guards the one-time default-Utilities seed (below) so it only ever
    // runs once per install rather than on every app-list refresh —
    // otherwise a user who deletes the folder, or drags every app back out
    // of it, would just watch it reappear the next time Spotlight's
    // monitor fires.
    private static let seededUtilitiesKey = "com.bored.launcher.seededUtilitiesFolder"

    init() {
        folders = Self.load()
    }

    // MARK: - Folder creation

    /// Classic Launchpad's own gesture: drag one loose app onto another
    /// (neither already foldered) to spin up a brand new folder holding
    /// both. Either side may itself already belong to some other folder —
    /// in that case it's pulled out of it first.
    @discardableResult
    func createFolder(combining draggedID: String, with targetID: String, defaultName: String) -> AppFolder? {
        guard draggedID != targetID else { return nil }
        for index in folders.indices {
            folders[index].appIDs.removeAll { $0 == draggedID || $0 == targetID }
        }
        dissolveEmptyOrSingleton()
        let folder = AppFolder(name: defaultName, appIDs: [targetID, draggedID])
        folders.append(folder)
        save()
        return folder
    }

    /// Drops `appID` into `folderID`, pulling it out of whatever other
    /// folder (if any) it was previously in — an app only ever lives in one
    /// folder at a time.
    func moveApp(_ appID: String, intoFolder folderID: UUID) {
        for index in folders.indices {
            folders[index].appIDs.removeAll { $0 == appID }
        }
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        if !folders[index].appIDs.contains(appID) {
            folders[index].appIDs.append(appID)
        }
        dissolveEmptyOrSingleton()
        save()
    }

    /// Removes `appID` from whatever folder currently holds it, dropping it
    /// back to the top-level grid.
    func removeApp(_ appID: String) {
        for index in folders.indices {
            folders[index].appIDs.removeAll { $0 == appID }
        }
        dissolveEmptyOrSingleton()
        save()
    }

    func rename(_ folderID: UUID, to newName: String) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folders[index].name = trimmed
        save()
    }

    /// A folder that drops to zero apps (its last app was uninstalled, or
    /// dragged out) or exactly one app (classic Launchpad dissolves rather
    /// than leaving a single-icon folder around) disappears, and that app
    /// simply shows at the top level again.
    private func dissolveEmptyOrSingleton() {
        folders.removeAll { $0.appIDs.count <= 1 }
    }

    // MARK: - Default "Utilities" folder

    /// Runs once per install. If the system Utilities apps Launcher
    /// already discovers (Activity Monitor, Disk Utility, Terminal, and so
    /// on — anything under `/System/Applications/Utilities`) aren't already
    /// sorted into some folder, group them the way classic Launchpad ships
    /// out of the box. Safe to call repeatedly (e.g. every time the live
    /// app list updates) — it only ever does anything the first time.
    func seedUtilitiesFolderIfNeeded(from apps: [AppInfo]) {
        guard !UserDefaults.standard.bool(forKey: Self.seededUtilitiesKey) else { return }

        let alreadyFoldered = Set(folders.flatMap { $0.appIDs })
        let utilityIDs = apps
            .filter { $0.bundleURL.path.hasPrefix("/System/Applications/Utilities/") }
            .map(\.id)
            .filter { !alreadyFoldered.contains($0) }

        // Apps still trickling in from the live Spotlight gather — wait for
        // a batch that actually has the Utilities folder's worth of apps in
        // it before deciding there's nothing to seed, rather than locking
        // in an empty seed off a half-populated first result.
        guard !apps.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: Self.seededUtilitiesKey)
        guard utilityIDs.count >= 2 else { return }

        folders.append(AppFolder(name: "Utilities", appIDs: utilityIDs))
        save()
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private static func load() -> [AppFolder] {
        guard let data = try? Data(contentsOf: fileURL),
              let folders = try? JSONDecoder().decode([AppFolder].self, from: data)
        else { return [] }
        return folders
    }
}
