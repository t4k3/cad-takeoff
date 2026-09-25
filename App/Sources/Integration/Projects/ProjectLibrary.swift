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
    /// Sketches of the open design, saved in the same file.
    @ObservationIgnored var sketches: SketchStore?
    private var savedSketchRevision = 0
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
        panel.message = "Scegli (o crea) la cartella dove Fusion Takeoff terrà i tuoi progetti, ad esempio Documenti › Fusion Takeoff."
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rootURL?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        rootURL = url
        storeBookmark(url)
        touch()
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
        if currentURL == nil, savedRevision == nil { savedRevision = model.designRevision; savedSketchRevision = sketches?.revision ?? 0 }
    }

    func isDirty(_ model: DesignModel) -> Bool {
        (savedRevision == nil ? !model.document.features.isEmpty : model.designRevision != savedRevision)
            || (sketches.map { $0.revision != savedSketchRevision } ?? false)
    }

    var currentName: String { currentURL?.deletingPathExtension().lastPathComponent ?? "Senza titolo" }

    /// New empty design saved right away in `folder`, then opened.
    func newDesign(in folder: URL, model: DesignModel) {
        guard confirmDiscard(model) else { return }
        run {
            let url = uniqueURL(folder.appendingPathComponent("Nuovo disegno.\(Self.designExtension)"))
            model.newDesign()
            sketches?.reset()
            try model.write(to: url, sketches: sketches)
            markSaved(url, model: model)
            showHome = false
        }
    }

    func open(_ url: URL, model: DesignModel) {
        guard url != currentURL || !isDirty(model) else { showHome = false; return }
        guard confirmDiscard(model) else { return }
        run {
            try model.load(from: url, sketches: sketches)
            markSaved(url, model: model)
            showHome = false
        }
    }

    func openWithPanel(model: DesignModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [DesignModel.ftkType, .json]
        panel.directoryURL = currentURL?.deletingLastPathComponent() ?? rootURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url, model: model)
    }

    func newUntitled(model: DesignModel) {
        guard confirmDiscard(model) else { return }
        model.newDesign()
        sketches?.reset()
        currentURL = nil
        savedRevision = model.designRevision
        savedSketchRevision = sketches?.revision ?? 0
        showHome = false
    }

    /// ⌘S: saves in place, or asks where (inside the library) the first time.
    @discardableResult
    func save(model: DesignModel) -> Bool {
        guard let url = currentURL else { return saveAs(model: model) }
        return run { try write(model, to: url) } != nil
    }

    @discardableResult
    func saveAs(model: DesignModel) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [DesignModel.ftkType]
        panel.nameFieldStringValue = currentName + ".\(Self.designExtension)"
        panel.directoryURL = currentURL?.deletingLastPathComponent() ?? projects.first?.url ?? rootURL
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return run { try write(model, to: url) } != nil
    }

    private func write(_ model: DesignModel, to url: URL) throws {
        try model.write(to: url, sketches: sketches)
        markSaved(url, model: model)
        model.statusMessage = "Salvato \(url.deletingPathExtension().lastPathComponent)"
    }

    private func markSaved(_ url: URL, model: DesignModel) {
        currentURL = url
        savedRevision = model.designRevision
        savedSketchRevision = sketches?.revision ?? 0
        writeThumbnail(for: model.document, design: url)
        var r = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        r.removeAll { $0 == url.path }
        r.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(r.prefix(12)), forKey: Self.recentsKey)
        touch()
    }

    private func writeThumbnail(for doc: CADDocument, design: URL) {
        let thumb = Item(url: design, isFolder: false, modified: .now).thumbnailURL
        try? FileManager.default.createDirectory(at: thumb.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let png = ThumbnailRenderer.png(for: doc) { try? png.write(to: thumb, options: .atomic) }
        else { try? FileManager.default.removeItem(at: thumb) }
    }

    /// Unsaved changes: Save / Don't save / Cancel.
    private func confirmDiscard(_ model: DesignModel) -> Bool {
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
