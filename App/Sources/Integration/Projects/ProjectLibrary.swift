import AppKit
import CADCore
import Foundation
import Observation
import UniformTypeIdentifiers

/// Local project library (T73): a root folder chosen by the user holds projects (sub-folders),
/// folders and designs (.ftk). Thumbnails live in `<folder>/.thumbnails/<design>.png`.
/// Also tracks the design currently open (file URL and saved revision).
@MainActor
@Observable
final class ProjectLibrary {
    struct Item: Identifiable, Hashable {
        let url: URL
        let isFolder: Bool
        let modified: Date
        var id: URL { url }
        var name: String { isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent }
        var thumbnailURL: URL {
            url.deletingLastPathComponent().appendingPathComponent(".thumbnails/\(url.lastPathComponent).png")
        }
    }

    static let designExtension = "ftk"
    private static let bookmarkKey = "projects.rootBookmark"
    private static let recentsKey = "projects.recents"

    private(set) var rootURL: URL?
    /// Bumped on every change on disk, so views re-read folder contents.
    private(set) var version = 0
    var showHome = true
    private(set) var currentURL: URL?
    private(set) var savedRevision: String?
    var lastError: String?

    init() { restoreRoot() }

    // MARK: Root folder (sandbox: security-scoped bookmark)

    private func restoreRoot() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return }
        rootURL = url
        if stale { storeBookmark(url) }
    }

    private func storeBookmark(_ url: URL) {
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Usa questa cartella"
        panel.message = "Scegli (o crea) la cartella dove CAD Takeoff terrà i tuoi progetti, ad esempio Documenti › CAD Takeoff."
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rootURL?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        rootURL = url
        storeBookmark(url)
        touch()
    }

    // MARK: Assemblies (components are referenced by their path under the root)

    /// Reads a component design by its root-relative path (safe off the main thread).
    var componentResolver: DesignEvaluator.ComponentResolver {
        let root = rootURL
        return { path in
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root?.appendingPathComponent(path)
            guard let url, let data = try? Data(contentsOf: url) else { return nil }
            return try? CADDocument.decode(data)
        }
    }

    /// Path to store in a ComponentRef: relative to the root when inside it, absolute otherwise.
    func componentPath(for url: URL) -> String {
        if let root = rootURL?.standardizedFileURL.path, url.standardizedFileURL.path.hasPrefix(root + "/") {
            return String(url.standardizedFileURL.path.dropFirst(root.count + 1))
        }
        return url.standardizedFileURL.path
    }

    func url(forComponent path: String) -> URL? {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : rootURL?.appendingPathComponent(path)
    }

    /// Every design under the root (for «Inserisci componente»), newest first.
    var allDesigns: [Item] {
        _ = version
        guard let root = rootURL,
              let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == Self.designExtension }
            .map { Item(url: $0, isFolder: false,
                        modified: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.modified > $1.modified }
    }

    // MARK: Reading

    var projects: [Item] { rootURL.map { contents(of: $0).filter(\.isFolder) } ?? [] }

    func contents(of folder: URL) -> [Item] {
        _ = version
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url -> Item? in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let isFolder = v?.isDirectory ?? false
            guard isFolder || url.pathExtension == Self.designExtension else { return nil }
            return Item(url: url, isFolder: isFolder, modified: v?.contentModificationDate ?? .distantPast)
        }
        .sorted { ($0.isFolder ? 0 : 1, $0.name.localizedLowercase) < ($1.isFolder ? 0 : 1, $1.name.localizedLowercase) }
    }

    /// Designs whose name contains `text`, anywhere under the root.
    func search(_ text: String) -> [Item] {
        _ = version
        guard let root = rootURL, !text.isEmpty,
              let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }
            .filter { $0.pathExtension == Self.designExtension && $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(text) }
            .map { Item(url: $0, isFolder: false,
                        modified: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.modified > $1.modified }
    }

    var recents: [Item] {
        _ = version
        return (UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []).compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
            return Item(url: url, isFolder: false, modified: d)
        }
    }

    /// Project a URL belongs to (first path component under the root).
    func project(of url: URL) -> String? {
        guard let root = rootURL?.standardizedFileURL.path, url.standardizedFileURL.path.hasPrefix(root + "/") else { return nil }
        return url.standardizedFileURL.path.dropFirst(root.count + 1).split(separator: "/").first.map(String.init)
    }

    // MARK: Changes on disk

    @discardableResult
    func newFolder(in parent: URL, name: String) -> URL? {
        run {
            let url = uniqueURL(parent.appendingPathComponent(clean(name)))
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }
    }

    func rename(_ item: Item, to newName: String) {
        run {
            let dest = item.url.deletingLastPathComponent()
                .appendingPathComponent(clean(newName) + (item.isFolder ? "" : ".\(Self.designExtension)"))
            guard dest != item.url else { return }
            guard !FileManager.default.fileExists(atPath: dest.path) else { throw LibraryError.exists(dest.lastPathComponent) }
            try FileManager.default.moveItem(at: item.url, to: dest)
            if !item.isFolder, FileManager.default.fileExists(atPath: item.thumbnailURL.path) {
                try? FileManager.default.moveItem(at: item.thumbnailURL, to: Item(url: dest, isFolder: false, modified: .now).thumbnailURL)
            }
            if currentURL == item.url { currentURL = dest }
            if let cur = currentURL, item.isFolder, cur.path.hasPrefix(item.url.path + "/") {
                currentURL = URL(fileURLWithPath: dest.path + cur.path.dropFirst(item.url.path.count))
            }
        }
    }

    func duplicate(_ item: Item) {
        run {
            let dest = uniqueURL(item.url.deletingLastPathComponent().appendingPathComponent(
                item.name + " copia" + (item.isFolder ? "" : ".\(Self.designExtension)")))
            try FileManager.default.copyItem(at: item.url, to: dest)
            if !item.isFolder, FileManager.default.fileExists(atPath: item.thumbnailURL.path) {
                try? FileManager.default.copyItem(at: item.thumbnailURL, to: Item(url: dest, isFolder: false, modified: .now).thumbnailURL)
            }
        }
    }

    /// Moves to the macOS Trash (recoverable), never deletes permanently.
    func trash(_ item: Item) {
        run {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            if !item.isFolder { try? FileManager.default.trashItem(at: item.thumbnailURL, resultingItemURL: nil) }
            if currentURL == item.url { currentURL = nil; savedRevision = nil }
        }
    }

    func reveal(_ item: Item) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    // MARK: Current design

    /// The design present at launch (not from a file) counts as clean until edited.
    func adoptInitialDesign(_ model: DesignModel) {
        if currentURL == nil, savedRevision == nil { savedRevision = model.designRevision }
    }

    func isDirty(_ model: DesignModel) -> Bool {
        savedRevision == nil ? !model.document.features.isEmpty : model.designRevision != savedRevision
    }

    var currentName: String { currentURL?.deletingPathExtension().lastPathComponent ?? "Senza titolo" }

    // MARK: Tabs (Fusion style: several designs open, one shown)

    struct Tab: Identifiable {
        let id = UUID()
        var url: URL?
        var savedRevision: String?
        /// The design while the tab is in the background (nil for the tab shown).
        var session: DesignModel.Session?
        var name: String { url?.deletingPathExtension().lastPathComponent ?? "Senza titolo" }
        var isDirty: Bool {
            guard let session else { return false }
            return savedRevision == nil ? !session.document.features.isEmpty : session.revision != savedRevision
        }
    }

    /// Open designs in tab order; the shown one is `activeTab` (its live state is in the model and
    /// in `currentURL`/`savedRevision`).
    private(set) var tabs: [Tab] = [Tab()]
    private(set) var activeTab: Tab.ID?

    private var activeIndex: Int {
        if activeTab == nil { activeTab = tabs.first?.id }
        return tabs.firstIndex { $0.id == activeTab } ?? 0
    }

    /// The shown tab is an untitled design with no changes (the one at launch, a new one): opening
    /// a file reuses it instead of leaving an empty tab behind.
    private func activeIsPristine(_ model: DesignModel) -> Bool {
        currentURL == nil && !isDirty(model)
    }

    /// Parks the shown design in its tab and makes a new tab the shown one (model state unchanged:
    /// the caller loads or creates the design for it).
    private func pushNewTab(_ model: DesignModel) {
        model.willSwitchDesign()
        let i = activeIndex
        tabs[i].url = currentURL; tabs[i].savedRevision = savedRevision; tabs[i].session = model.captureSession()
        let tab = Tab()
        tabs.insert(tab, at: i + 1)
        activeTab = tab.id
    }

    /// Shows another open design.
    func activate(_ id: Tab.ID, model: DesignModel) {
        guard id != activeTab, model.loading == nil, let j = tabs.firstIndex(where: { $0.id == id }), let session = tabs[j].session else {
            showHome = false; return
        }
        model.willSwitchDesign()
        let i = activeIndex
        tabs[i].url = currentURL; tabs[i].savedRevision = savedRevision; tabs[i].session = model.captureSession()
        currentURL = tabs[j].url; savedRevision = tabs[j].savedRevision
        tabs[j].session = nil
        activeTab = id
        model.restoreSession(session)
        showHome = false
    }

    /// The tab's X: asks to save changes, then shows the neighbour (or the Home when it was the last).
    func closeTab(_ id: Tab.ID, model: DesignModel) {
        guard model.loading == nil else { return }
        if id != activeTab { activate(id, model: model) }
        guard id == activeTab, confirmDiscard(model) else { return }
        let i = activeIndex
        if tabs.count == 1 {
            model.newDesign()
            model.statusMessage = "Pronto"
            currentURL = nil
            savedRevision = model.designRevision
            tabs = [Tab()]; activeTab = tabs[0].id
            showHome = true
            return
        }
        let next = tabs[i + 1 < tabs.count ? i + 1 : i - 1]
        model.willSwitchDesign()
        tabs.remove(at: i)
        currentURL = next.url; savedRevision = next.savedRevision
        if let n = tabs.firstIndex(where: { $0.id == next.id }) { tabs[n].session = nil }
        activeTab = next.id
        if let session = next.session { model.restoreSession(session) }
        showHome = false
    }

    /// Quitting: every design with changes asks to be saved (Annulla stops the quit).
    func confirmDiscardAll(_ model: DesignModel) -> Bool {
        for tab in tabs where tab.id != activeTab && tab.isDirty {
            activate(tab.id, model: model)
            guard confirmDiscard(model) else { return false }
        }
        return confirmDiscard(model)
    }

    /// New empty design saved right away in `folder`, then opened (in a new tab).
    func newDesign(in folder: URL, model: DesignModel) {
        if !activeIsPristine(model) { pushNewTab(model) }
        run {
            let url = uniqueURL(folder.appendingPathComponent("Nuovo disegno.\(Self.designExtension)"))
            model.newDesign()
            try model.write(to: url)
            markSaved(url, model: model)
            showHome = false
        }
    }

    func open(_ url: URL, model: DesignModel) {
        guard model.loading == nil else { return }
        // Already open: show its tab.
        if url == currentURL { showHome = false; return }
        if let tab = tabs.first(where: { $0.url == url && $0.id != activeTab }) { activate(tab.id, model: model); return }
        // A new tab, unless the shown one is an untouched empty design.
        let previous = activeTab
        if !activeIsPristine(model) { pushNewTab(model) }
        // Read and evaluated in the background (progress bar); the Home stays until it is ready.
        model.loadInBackground(from: url) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.markCurrent(url, model: model)
                // Thumbnail only if missing or older than the file (opening does not change it).
                let thumb = Item(url: url, isFolder: false, modified: .now).thumbnailURL
                let fileDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let thumbDate = (try? thumb.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if thumbDate < fileDate { self.writeThumbnail(for: model, design: url) }
                self.showHome = false
            case let .failure(error):
                self.lastError = error.localizedDescription
                // Back to the design that was shown (the new tab is dropped).
                if let previous, previous != self.activeTab, let tab = self.activeTab {
                    self.activate(previous, model: model)
                    self.tabs.removeAll { $0.id == tab }
                }
                model.statusMessage = "Apertura non riuscita: \(error.localizedDescription)"
            }
        }
    }

    func openWithPanel(model: DesignModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [DesignModel.ftkType, .json]
        panel.directoryURL = currentURL?.deletingLastPathComponent() ?? rootURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url, model: model)
    }

    /// ⌘W: closes the shown design's tab.
    func closeDesign(model: DesignModel) {
        closeTab(activeTab ?? tabs[0].id, model: model)
    }

    /// ⌘N: a new untitled design in a new tab.
    func newUntitled(model: DesignModel) {
        if !activeIsPristine(model) { pushNewTab(model) }
        model.newDesign()
        currentURL = nil
        savedRevision = model.designRevision
        showHome = false
    }

    /// ⌘S: saves in place, or asks where (inside the library) the first time.
    @discardableResult
    func save(model: DesignModel) -> Bool {
        model.finishPendingEdits()
        guard let url = currentURL else { return saveAs(model: model) }
        return run { try write(model, to: url) } != nil
    }

    @discardableResult
    func saveAs(model: DesignModel) -> Bool {
        model.finishPendingEdits()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [DesignModel.ftkType]
        panel.nameFieldStringValue = currentName + ".\(Self.designExtension)"
        panel.directoryURL = currentURL?.deletingLastPathComponent() ?? projects.first?.url ?? rootURL
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return run { try write(model, to: url) } != nil
    }

    private func write(_ model: DesignModel, to url: URL) throws {
        try model.write(to: url)
        markSaved(url, model: model)
        model.statusMessage = "Salvato \(url.deletingPathExtension().lastPathComponent)"
    }

    private func markSaved(_ url: URL, model: DesignModel) {
        markCurrent(url, model: model)
        writeThumbnail(for: model, design: url)
    }

    /// The design now open is this file, clean.
    private func markCurrent(_ url: URL, model: DesignModel) {
        currentURL = url
        savedRevision = model.designRevision
        var r = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        r.removeAll { $0 == url.path }
        r.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(r.prefix(12)), forKey: Self.recentsKey)
        touch()
    }

    /// Drawn in the background from the bodies already evaluated (never a second evaluation).
    private func writeThumbnail(for model: DesignModel, design: URL) {
        let thumb = Item(url: design, isFolder: false, modified: .now).thumbnailURL
        let parts = model.evaluation().bodies.filter(\.isVisible).map { ($0.mesh, $0.source.color) }
        Task.detached(priority: .utility) { [weak self] in
            try? FileManager.default.createDirectory(at: thumb.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let png = ThumbnailRenderer.png(parts: parts) { try? png.write(to: thumb, options: .atomic) }
            else { try? FileManager.default.removeItem(at: thumb) }
            await MainActor.run { self?.touch() }
        }
    }

    /// Unsaved changes: Save / Don't save / Cancel. Also used when quitting.
    func confirmDiscard(_ model: DesignModel) -> Bool {
        model.finishPendingEdits()
        guard isDirty(model) else { return true }
        let alert = NSAlert()
        alert.messageText = "Salvare le modifiche a «\(currentName)»?"
        alert.informativeText = "Se non salvi, le modifiche andranno perse."
        alert.addButton(withTitle: "Salva")
        alert.addButton(withTitle: "Non salvare")
        alert.addButton(withTitle: "Annulla")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(model: model)
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    // MARK: Helpers

    enum LibraryError: LocalizedError {
        case exists(String)
        var errorDescription: String? {
            switch self { case let .exists(n): "Esiste già un elemento chiamato «\(n)»." }
        }
    }

    private func touch() { version += 1 }

    @discardableResult
    private func run<T>(_ body: () throws -> T) -> T? {
        do { let r = try body(); lastError = nil; touch(); return r }
        catch { lastError = error.localizedDescription; touch(); return nil }
    }

    private func clean(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return n.isEmpty ? "Senza nome" : n
    }

    private func uniqueURL(_ url: URL) -> URL {
        var candidate = url, n = 2
        let ext = url.pathExtension, base = url.deletingPathExtension().lastPathComponent, dir = url.deletingLastPathComponent()
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        return candidate
    }
}
