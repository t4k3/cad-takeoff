import AppKit
import SwiftUI

/// Home dashboard (T73): local projects → folders → designs, like Fusion's Data Panel.
struct HomeView: View {
    @Environment(ProjectLibrary.self) private var library
    @Environment(DesignModel.self) private var model
    @Environment(CircuitModel.self) private var circuits
    @Environment(WorkspaceState.self) private var workspace
    @State private var project: URL?
    @State private var path: [URL] = []           // folders below the project
    @State private var query = ""
    @State private var renaming: ProjectLibrary.Item?
    @State private var newName = ""
    @State private var creatingFolder = false
    @State private var creatingProject = false

    private var folder: URL? { path.last ?? project }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 230)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
        }
        .background(Theme.Palette.canvas)
        .onAppear { if project == nil { project = library.project(of: library.currentURL ?? URL(fileURLWithPath: "/")).flatMap { name in library.projects.first { $0.name == name }?.url } } }
        .alert("Rinomina", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nome", text: $newName)
            Button("Rinomina") { if let r = renaming { library.rename(r, to: newName) }; renaming = nil }
            Button("Annulla", role: .cancel) { renaming = nil }
        }
        .alert(creatingProject ? "Nuovo progetto" : "Nuova cartella", isPresented: Binding(get: { creatingFolder || creatingProject }, set: { if !$0 { creatingFolder = false; creatingProject = false } })) {
            TextField("Nome", text: $newName)
            Button("Crea") {
                if creatingProject, let root = library.rootURL {
                    if let url = library.newFolder(in: root, name: newName) { project = url; path = [] }
                } else if let f = folder { library.newFolder(in: f, name: newName) }
                creatingFolder = false; creatingProject = false
            }
            Button("Annulla", role: .cancel) { creatingFolder = false; creatingProject = false }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "house.fill").foregroundStyle(Theme.Palette.accent)
                Text("Home").font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(12)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sidebarRow("Recenti", symbol: "clock", selected: project == nil) { project = nil; path = [] }
                    Text("PROGETTI").font(.system(size: 9.5, weight: .semibold)).tracking(0.5)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
                    ForEach(library.projects) { p in
                        sidebarRow(p.name, symbol: "folder.fill", selected: project == p.url) { project = p.url; path = [] }
                            .contextMenu { itemMenu(p) }
                    }
                    Button { newName = "Nuovo progetto"; creatingProject = true } label: {
                        Label("Nuovo progetto", systemImage: "plus").font(Theme.Typeface.body)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.Palette.accent)
                    .disabled(library.rootURL == nil)
                }
            }
            Spacer()
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Cartella dei progetti").font(.caption2).foregroundStyle(Theme.Palette.textSecondary)
                Text(library.rootURL?.path.replacingOccurrences(of: ProjectLibraryHome.path, with: "~") ?? "non scelta")
                    .font(.system(size: 10.5, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                Button("Cambia cartella…") { library.chooseRoot(); project = nil; path = [] }.controlSize(.small)
                Divider().padding(.vertical, 4)
                Text("Da Fusion 360").font(.caption2).foregroundStyle(Theme.Palette.textSecondary)
                Button("Installa add-in…") { model.statusMessage = FusionAddInInstaller.installWithPanel() }
                    .controlSize(.small)
                    .help("Aggiunge a Fusion il comando «Esporta per CAD Takeoff»: salva il disegno come .ftk in una cartella dei progetti, anche a ogni salvataggio")
                Button("Importa STL/3MF…") { library.showHome = false; model.importMeshWithPanel() }.controlSize(.small)
                Divider().padding(.vertical, 4)
                Text("CAD Takeoff \(AppVersion.short)")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.Palette.textSecondary)
                    .help(AppVersion.long).textSelection(.enabled)
                Text("compilata il \(AppVersion.buildDate)").font(.caption2).foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(12)
        }
        .background(Theme.Palette.panel)
    }

    private func sidebarRow(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.textSecondary).frame(width: 16)
                Text(title).font(Theme.Typeface.body).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.Palette.accent.opacity(0.16) : .clear).padding(.horizontal, 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            breadcrumb
            Spacer()
            TextField("Cerca pezzi e circuiti", text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
            Button { newName = "Nuova cartella"; creatingFolder = true } label: { Label("Nuova cartella", systemImage: "folder.badge.plus") }
                .disabled(folder == nil)
            // Nuovo: a part or a circuit, chosen here (circuits no longer go through a part).
            Menu {
                Button { newPart() } label: { Label("Pezzo 3D", systemImage: "cube") }
                Button { newCircuit() } label: { Label("Circuito", systemImage: "cpu") }
            } label: {
                Label("Nuovo", systemImage: "plus.square")
            } primaryAction: { newPart() }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .disabled(folder == nil)
            .help(folder == nil ? "Scegli prima un progetto" : "Crea in questa cartella un pezzo 3D (clic) o, dal menu, un circuito")
            // Back to what was open: the circuit when CIRCUITI was shown (or only a circuit is open).
            if circuits.document != nil, workspace.tab == .circuits || (library.currentURL == nil && model.document.features.isEmpty) {
                Button { library.showHome = false; workspace.tab = .circuits } label: { Label("Torna al circuito «\(circuits.title)»", systemImage: "cpu") }
                    .keyboardShortcut(.cancelAction)
            } else if library.currentURL != nil || !model.document.features.isEmpty {
                Button { library.showHome = false } label: { Label("Torna a «\(library.currentName)»", systemImage: "cube") }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 16).frame(height: 52)
        .background(Theme.Palette.panel)
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            if let project {
                crumb(project.lastPathComponent) { path = [] }
                ForEach(path.indices, id: \.self) { i in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.Palette.textSecondary)
                    crumb(path[i].lastPathComponent) { path = Array(path.prefix(i + 1)) }
                }
            } else {
                Text(query.isEmpty ? "Recenti" : "Risultati").font(.system(size: 14, weight: .semibold))
            }
        }
    }

    private func crumb(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 14, weight: .semibold)) }.buttonStyle(.plain)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if library.rootURL == nil {
            onboarding
        } else {
            let items: [ProjectLibrary.Item] = !query.isEmpty ? library.search(query)
                : (folder.map { library.contents(of: $0) } ?? library.recents)
            if items.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: project == nil ? "clock" : "folder")
                } description: { Text(emptyHint) } actions: {
                    if library.projects.isEmpty {
                        Button("Crea il primo progetto") { newName = "Il mio progetto"; creatingProject = true }
                            .buttonStyle(.borderedProminent)
                    } else if folder != nil {
                        HStack {
                            Button("Nuovo pezzo 3D") { newPart() }
                            Button("Nuovo circuito") { newCircuit() }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 230), spacing: 16)], spacing: 16) {
                        ForEach(items) { item in
                            ItemCard(item: item, isCurrent: item.url == library.currentURL || item.url == circuits.url,
                                     subtitle: project == nil ? library.project(of: item.url) : nil)
                                .onTapGesture(count: 2) { open(item) }
                                .contextMenu { itemMenu(item) }
                        }
                    }
                    .padding(20)
                }
            }
            if let err = library.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill").font(.caption)
                    .foregroundStyle(Theme.Palette.danger).padding(8)
            }
        }
    }

    private var emptyTitle: String {
        if !query.isEmpty { return "Nessun disegno trovato" }
        if library.projects.isEmpty { return "Nessun progetto" }
        return project == nil ? "Nessun disegno recente" : "Cartella vuota"
    }

    private var emptyHint: String {
        if !query.isEmpty { return "Nessun disegno contiene «\(query)» nel nome." }
        if library.projects.isEmpty { return "Un progetto raccoglie le parti e gli assiemi di un lavoro, con le sue cartelle." }
        return project == nil ? "I disegni aperti o salvati di recente compariranno qui." : "Crea un disegno o una cartella con i pulsanti in alto."
    }

    private var onboarding: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.gearshape").font(.system(size: 44)).foregroundStyle(Theme.Palette.accent)
            Text("Dove vuoi tenere i tuoi progetti?").font(.title3.weight(.semibold))
            Text("CAD Takeoff organizza i disegni in progetti e cartelle in una cartella del tuo Mac, ad esempio Documenti › CAD Takeoff. Puoi cambiarla quando vuoi.")
                .multilineTextAlignment(.center).foregroundStyle(Theme.Palette.textSecondary).frame(maxWidth: 420)
            Button("Scegli la cartella…") { library.chooseRoot() }.buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func itemMenu(_ item: ProjectLibrary.Item) -> some View {
        Button(item.isFolder ? "Apri cartella" : "Apri") { open(item) }
        Button("Rinomina…") { newName = item.name; renaming = item }
        Button("Duplica") { library.duplicate(item) }
        Button("Mostra nel Finder") { library.reveal(item) }
        Divider()
        Button("Sposta nel Cestino", role: .destructive) {
            if project == item.url { project = nil; path = [] }
            library.trash(item)
        }
    }

    private func open(_ item: ProjectLibrary.Item) {
        if item.isFolder {
            if project == nil || !(item.url.path.hasPrefix(project!.path)) { project = item.url; path = [] }
            else if item.url != project { path.append(item.url) }
        } else if item.isCircuit {
            library.openCircuit(item.url, circuits: circuits) { [workspace] in workspace.tab = .circuits }
        } else {
            library.open(item.url, model: model)
            if workspace.tab == .circuits { workspace.tab = .solid }
        }
    }

    private func newPart() {
        guard let f = folder else { return }
        library.newDesign(in: f, model: model)
        if workspace.tab == .circuits { workspace.tab = .solid }
    }

    private func newCircuit() {
        guard let f = folder else { return }
        library.newCircuit(in: f, circuits: circuits)
        if !library.showHome { workspace.tab = .circuits }
    }
}

enum ProjectLibraryHome {
    static var path: String { String(cString: getpwuid(getuid()).pointee.pw_dir) }
}

/// One design or folder in the grid.
private struct ItemCard: View {
    let item: ProjectLibrary.Item
    let isCurrent: Bool
    let subtitle: String?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Theme.Palette.panelRaised
                if item.isFolder {
                    Image(systemName: "folder.fill").font(.system(size: 54)).foregroundStyle(Theme.Palette.sketch.opacity(0.8))
                } else if item.isCircuit {
                    Image(systemName: "cpu").font(.system(size: 48)).foregroundStyle(Theme.Palette.accent.opacity(0.8))
                } else if let img = NSImage(contentsOf: item.thumbnailURL) {
                    Image(nsImage: img).resizable().scaledToFit().padding(8)
                } else {
                    Image(systemName: "cube.transparent").font(.system(size: 44)).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .frame(height: 130)
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if isCurrent { Circle().fill(Theme.Palette.accent).frame(width: 6, height: 6).help("Aperto ora") }
                    Text(item.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                Text((subtitle.map { "\($0) · " } ?? "") + item.modified.formatted(.relative(presentation: .named)))
                    .font(.caption2).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(Theme.Palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isCurrent ? Theme.Palette.accent : hovering ? Theme.Palette.accent.opacity(0.5) : Theme.Palette.separator,
                                                                   lineWidth: isCurrent ? 2 : 1))
        .shadow(color: .black.opacity(hovering ? 0.18 : 0.06), radius: hovering ? 8 : 3, y: 2)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .help(item.isFolder ? "Doppio clic per aprire la cartella" : item.isCircuit ? "Doppio clic per aprire il circuito in CIRCUITI" : "Doppio clic per aprire il disegno")
    }
}
