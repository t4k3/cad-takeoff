import AppKit
import SwiftUI

/// Welcome window in the Strophe style: brand and actions on the left, recent designs on the
/// right, over a soft accent gradient. It is its own window (FusionTakeoffApp, id «welcome»),
/// sized 1032×672 like a welcome splash.
struct HomeView: View {
    @Environment(ProjectLibrary.self) private var library
    @Environment(DesignModel.self) private var model
    @Environment(CircuitModel.self) private var circuits
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.openWindow) private var openWindow
    @State private var project: URL?
    @State private var path: [URL] = []           // folders below the project
    @State private var renaming: ProjectLibrary.Item?
    @State private var newName = ""
    @State private var creatingFolder = false
    @State private var creatingProject = false
    @State private var query = ""
    /// The checkbox at the bottom left: the welcome window opens at every launch.
    @AppStorage("welcome.showAtLaunch") private var showAtLaunch = true

    private var folder: URL? { path.last ?? project }

    var body: some View {
        HStack(spacing: 0) {
            actionsPanel
                .frame(minWidth: 460, idealWidth: 540, maxWidth: 560)
            Rectangle().fill(Theme.Palette.separator.opacity(0.45)).frame(width: 1)
            libraryPane
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
        // The welcome window has no title bar: use the whole 672pt, with the X in the corner.
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) { closeButton.padding(14) }
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

    /// Strophe's welcome backdrop: the accent in the top-left, fading into the canvas.
    private var background: some View {
        ZStack {
            Theme.Palette.canvas
            LinearGradient(colors: [Theme.Palette.accent.opacity(0.18),
                                    Theme.Palette.canvas],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(.regularMaterial)
        }
        .ignoresSafeArea()
    }

    // MARK: Actions column

    private var actionsPanel: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 14) {
                brandMark
                VStack(alignment: .leading, spacing: 4) {
                    Text("CAD Takeoff")
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(String(localized: "\(AppVersion.short) · build \(AppVersion.build)"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .help(AppVersion.long)
                        .textSelection(.enabled)
                }
            }
            VStack(spacing: 10) {
                actionButton("Nuovo disegno",
                             subtitle: folder == nil ? "Scegli prima un progetto" : "Crea un nuovo disegno 3D in questa cartella",
                             symbol: "plus.square.on.square", disabled: folder == nil) { newPart() }
                actionButton("Nuovo circuito",
                             subtitle: folder == nil ? "Scegli prima un progetto" : "Crea un nuovo circuito elettronico in questa cartella",
                             symbol: "cpu", disabled: folder == nil) { newCircuit() }
                actionButton("Apri…", subtitle: "Apri un disegno o un circuito dal disco",
                             symbol: "folder") {
                    library.openWithPanel(model: model)
                    // The workspace window is not open at launch (the welcome is): bring it up.
                    if !library.showHome { openWindow(id: "workspace") }
                }
                actionButton("Scegli cartella…",
                             subtitle: "Scegli (o crea) la cartella dove CAD Takeoff tiene i tuoi progetti",
                             symbol: "folder.badge.gearshape") { library.chooseRoot(); project = nil; path = [] }
            }
            Spacer(minLength: 8)
            HStack(spacing: 12) {
                moreMenu
                Toggle(isOn: $showAtLaunch) {
                    Text("Mostra questa finestra all'avvio")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .toggleStyle(.checkbox)
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 44)
        .padding(.vertical, 34)
    }

    private var brandMark: some View {
        Group {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon).resizable().scaledToFill()
            } else {
                ZStack {
                    Theme.Palette.panelRaised
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 46, weight: .regular))
                        .foregroundStyle(Theme.Palette.accent)
                }
            }
        }
        .frame(width: 104, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous)
            .stroke(Color.white.opacity(0.18), lineWidth: 1))
        .shadow(color: Theme.Palette.accent.opacity(0.28), radius: 21, y: 10)
    }

    private func actionButton(_ title: LocalizedStringKey, subtitle: LocalizedStringKey, symbol: String,
                              disabled: Bool = false, action: @escaping () -> Void) -> some View {
        HomeActionButton(title: title, subtitle: subtitle, systemImage: symbol,
                         disabled: disabled, action: action)
    }

    private var closeButton: some View {
        Button { library.showHome = false } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.Palette.panelRaised))
                .overlay(Circle().strokeBorder(Theme.Palette.separator))
        }
        .buttonStyle(.plain)
        .help("Chiudi la finestra di benvenuto")
    }

    private var moreMenu: some View {
        Menu {
            Button { newName = String(localized: "Nuova cartella"); creatingFolder = true } label: {
                Label("Nuova cartella", systemImage: "folder.badge.plus")
            }
            .disabled(folder == nil)
            Button { newName = String(localized: "Nuovo progetto"); creatingProject = true } label: {
                Label("Nuovo progetto", systemImage: "folder.badge.plus")
            }
            .disabled(library.rootURL == nil)
            Divider()
            Button { model.statusMessage = FusionAddInInstaller.installWithPanel() } label: {
                Label("Installa add-in…", systemImage: "puzzlepiece.extension")
            }
            Button { library.showHome = false; model.importMeshWithPanel() } label: {
                Label("Importa STL/3MF…", systemImage: "square.and.arrow.down")
            }
            Divider()
            Button { library.chooseRoot(); project = nil; path = [] } label: {
                Label("Cambia cartella…", systemImage: "folder.badge.gearshape")
            }
        } label: {
            Label("Altro", systemImage: "ellipsis")
                .font(.system(size: 12))
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .help("Altre azioni: cartelle, add-in di Fusion, importazione")
    }

    // MARK: Library pane

    private var libraryPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            libraryBar
            content
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The thin bar above the list: project breadcrumb on the left, search and actions on the right.
    private var libraryBar: some View {
        HStack(spacing: 8) {
            projectMenu
            if project != nil {
                ForEach(path.indices, id: \.self) { i in
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                    crumb(path[i].lastPathComponent) { path = Array(path.prefix(i + 1)) }
                }
            }
            Spacer(minLength: 8)
            TextField(String(localized: "Cerca pezzi e circuiti"), text: $query)
                .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 170)
            Button { newName = String(localized: "Nuova cartella"); creatingFolder = true } label: {
                Label("Nuova cartella", systemImage: "folder.badge.plus")
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .disabled(folder == nil)
            .help("Crea una cartella in quella aperta")
            // Esc goes back to what is open: the circuit in CIRCUITI, or the current design.
            if circuits.document != nil, workspace.tab == .circuits || (library.currentURL == nil && model.document.features.isEmpty) {
                Button { library.showHome = false; workspace.tab = .circuits } label: {
                    Label("Torna al circuito «\(circuits.title)»", systemImage: "cpu")
                }
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .help("Torna al circuito «\(circuits.title)» (Esc)")
            } else if library.currentURL != nil || !model.document.features.isEmpty {
                Button { library.showHome = false } label: {
                    Label("Torna a «\(library.currentName)»", systemImage: "cube")
                }
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .help("Torna a «\(library.currentName)» (Esc)")
            }
        }
        .frame(height: 36)
    }

    /// «Recenti» or a project, then the folders opened inside it.
    private var projectMenu: some View {
        Menu {
            Button { project = nil; path = [] } label: { Label("Recenti", systemImage: "clock") }
            if !library.projects.isEmpty {
                Divider()
                ForEach(library.projects) { p in
                    Button(LocalizedStringKey(p.name)) { project = p.url; path = [] }
                }
            }
            Divider()
            Button { newName = String(localized: "Nuovo progetto"); creatingProject = true } label: {
                Label("Nuovo progetto", systemImage: "plus")
            }
            .disabled(library.rootURL == nil)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: project == nil ? "clock" : "folder.fill")
                Text(project?.lastPathComponent ?? String(localized: "Recenti"))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.Palette.textPrimary)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .help("Scegli il progetto da mostrare: Recenti o uno dei tuoi progetti")
    }

    private func crumb(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 13)) }.buttonStyle(.plain)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if library.rootURL == nil {
            onboarding
        } else {
            let items = currentItems
            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(items) { item in
                            HomeItemRow(item: item,
                                        isCurrent: item.url == library.currentURL || item.url == circuits.url,
                                        subtitle: project == nil ? library.project(of: item.url) : nil,
                                        onOpen: { open(item) }) { itemMenu(item) }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
            if let err = library.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill").font(.caption)
                    .foregroundStyle(Theme.Palette.danger).padding(8)
            }
        }
    }

    private var currentItems: [ProjectLibrary.Item] {
        if !query.isEmpty { return library.search(query) }
        return folder.map { library.contents(of: $0) } ?? library.recents
    }

    private var emptyTitle: LocalizedStringKey {
        if !query.isEmpty { return "Nessun disegno trovato" }
        if library.projects.isEmpty { return "Nessun progetto" }
        return project == nil ? "Nessun disegno recente" : "Cartella vuota"
    }

    private var emptyHint: LocalizedStringKey {
        if !query.isEmpty { return LocalizedStringKey("Nessun disegno contiene «\(query)» nel nome.") }
        if library.projects.isEmpty { return "Un progetto raccoglie le parti e gli assiemi di un lavoro, con le sue cartelle." }
        return project == nil ? "I disegni aperti o salvati di recente compariranno qui." : "Crea un disegno o una cartella con i pulsanti in alto."
    }

    /// Strophe-style empty state: icon, title and hint, aligned to the top of the list.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: query.isEmpty ? (project == nil ? "clock.arrow.circlepath" : "folder") : "magnifyingglass")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(emptyTitle).font(.headline).foregroundStyle(Theme.Palette.textPrimary)
            Text(emptyHint).font(.subheadline).foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if library.projects.isEmpty {
                Button("Crea il primo progetto") { newName = String(localized: "Il mio progetto"); creatingProject = true }
                    .buttonStyle(.borderedProminent).controlSize(.small).padding(.top, 4)
            } else if folder != nil {
                HStack(spacing: 8) {
                    Button("Nuovo pezzo 3D") { newPart() }.controlSize(.small)
                    Button("Nuovo circuito") { newCircuit() }.controlSize(.small)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 8)
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
            Text("Dove vuoi tenere i tuoi progetti?").font(.headline).foregroundStyle(Theme.Palette.textPrimary)
            Text("CAD Takeoff organizza i disegni in progetti e cartelle in una cartella del tuo Mac, ad esempio Documenti › CAD Takeoff. Puoi cambiarla quando vuoi.")
                .font(.subheadline).foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Scegli la cartella…") { library.chooseRoot() }
                .buttonStyle(.borderedProminent).controlSize(.small).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 8)
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
            openWindow(id: "workspace")
            library.openCircuit(item.url, circuits: circuits) { [workspace] in workspace.tab = .circuits }
        } else {
            openWindow(id: "workspace")
            library.open(item.url, model: model)
            if workspace.tab == .circuits { workspace.tab = .solid }
        }
    }

    private func newPart() {
        guard let f = folder else { return }
        openWindow(id: "workspace")
        library.newDesign(in: f, model: model)
        if workspace.tab == .circuits { workspace.tab = .solid }
    }

    private func newCircuit() {
        guard let f = folder else { return }
        openWindow(id: "workspace")
        library.newCircuit(in: f, circuits: circuits)
        if !library.showHome { workspace.tab = .circuits }
    }
}

enum ProjectLibraryHome {
    static var path: String { String(cString: getpwuid(getuid()).pointee.pw_dir) }
}

/// Strophe's welcome action: icon, title with a subtitle, chevron; a card that brightens on hover.
private struct HomeActionButton: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let systemImage: String
    var disabled = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }

                Spacer(minLength: 12)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 58)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isHovering ? Theme.Palette.hover.opacity(2) : Theme.Palette.panelRaised))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.Palette.separator.opacity(isHovering ? 1 : 0.55), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { isHovering = $0 }
    }
}

/// One design or folder in the recent list.
private struct HomeItemRow<MenuContent: View>: View {
    let item: ProjectLibrary.Item
    let isCurrent: Bool
    let subtitle: String?
    let onOpen: () -> Void
    let menu: MenuContent

    @State private var isHovering = false

    init(item: ProjectLibrary.Item, isCurrent: Bool, subtitle: String?, onOpen: @escaping () -> Void,
         @ViewBuilder menu: () -> MenuContent) {
        self.item = item
        self.isCurrent = isCurrent
        self.subtitle = subtitle
        self.onOpen = onOpen
        self.menu = menu()
    }

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text((subtitle.map { "\($0) · " } ?? "") + item.modified.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if isCurrent {
                Circle().fill(Theme.Palette.accent).frame(width: 6, height: 6).help("Aperto ora")
            }
            Menu { menu } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .opacity(isHovering || isCurrent ? 1 : 0.6)
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isHovering ? Theme.Palette.hover.opacity(2) : Theme.Palette.panelRaised.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(isCurrent ? Theme.Palette.accent.opacity(0.8)
                  : Theme.Palette.separator.opacity(isHovering ? 1 : 0.45),
                  lineWidth: isCurrent ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpen() }
        .onHover { isHovering = $0 }
        .help(item.isFolder ? "Doppio clic per aprire la cartella" : item.isCircuit ? "Doppio clic per aprire il circuito in CIRCUITI" : "Doppio clic per aprire il disegno")
    }

    @ViewBuilder private var icon: some View {
        if item.isFolder {
            Image(systemName: "folder.fill").font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Palette.sketch)
        } else if item.isCircuit {
            Image(systemName: "cpu").font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
        } else {
            Image(systemName: "cube.transparent").font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
        }
    }
}

/// The welcome window as its own scene (FusionTakeoffApp, id «welcome»): borderless like a
/// splash, and it closes itself when Home is dismissed from elsewhere (⌘⇧H, opening a design,
/// or the X button).
struct WelcomeWindow: View {
    @Environment(ProjectLibrary.self) private var library
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        HomeView()
            .frame(width: 1032, height: 672)
            .background(WindowChrome())
            .onChange(of: library.showHome) { _, show in
                if !show { dismissWindow(id: "welcome") }
            }
            .onDisappear {
                if library.showHome { library.showHome = false }
            }
    }
}

/// Chrome of the welcome window: no title, hidden traffic lights, draggable background.
private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.styleMask.insert(.fullSizeContentView)
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
            // At launch only one window: the Home hides the empty workspace the WindowGroup
            // opens behind it, or closes itself when the user asked to start in the workspace.
            // Opening Home later (⇧⌘H) leaves the workspace alone.
            MainActor.assumeIsolated {
                guard !AppDelegate.arrangedLaunchWindows else { return }
                AppDelegate.arrangedLaunchWindows = true
                let showWelcome = UserDefaults.standard.object(forKey: "welcome.showAtLaunch") as? Bool ?? true
                if showWelcome {
                    for other in NSApp.windows where other !== window && other.canBecomeMain {
                        other.orderOut(nil)
                    }
                } else {
                    window.close()
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
