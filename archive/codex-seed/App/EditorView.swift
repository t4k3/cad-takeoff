import SwiftUI
import CADCore

struct EditorView: View {
    @Binding var document: CADDocument
    @State private var exportDocument: STLDocument?
    @State private var exporting = false
    @State private var errorMessage: String?
    @State private var cameraReset = UUID()

    private var result: Result<Mesh, Error> { Result { try PrimitiveMesher.build(document.model) } }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TAKEOFF CAD").font(.title2.bold())
                    Text("0.1 · Schizzo → Estrusione → STL").font(.caption).foregroundStyle(.secondary)
                }
                Form {
                    Picker("Profilo", selection: $document.model.profile) {
                        Text("Rettangolo").tag(ProfileKind.rectangle)
                        Text("Cerchio").tag(ProfileKind.circle)
                    }
                    dimension(document.model.profile == .circle ? "Diametro" : "Larghezza", value: $document.model.width)
                    if document.model.profile == .rectangle { dimension("Profondità", value: $document.model.depth) }
                    dimension("Estrusione Z", value: $document.model.height)
                    if document.model.profile == .circle {
                        Stepper("Segmenti: \(document.model.segments)", value: $document.model.segments, in: 16...256, step: 8)
                    }
                }
                Text("Quote in millimetri · 0,1–1000 mm\nUn profilo e un corpo per documento.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("STL: importa nello slicer in mm.\nIl file non contiene un'unità standard.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(minWidth: 260, idealWidth: 290, maxWidth: 340)
            VStack(spacing: 0) {
                switch result {
                case .success(let mesh):
                    HStack {
                        Label("SOLIDO", systemImage: "cube.transparent").font(.caption.bold())
                        Spacer()
                        Text("\(mesh.triangles.count) triangoli · \(mesh.signedVolume, specifier: "%.1f") mm³").font(.caption.monospacedDigit())
                    }.padding()
                    MetalViewport(mesh: mesh, resetID: cameraReset)
                        .overlay(alignment: .bottomLeading) {
                            Text("Trascina: orbita · Scorri: zoom · Z: estrusione")
                                .font(.caption).padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8)).padding()
                        }
                    Divider()
                    SketchView(model: document.model).frame(height: 190)
                case .failure(let error):
                    ContentUnavailableView("Quote non valide", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
                }
            }.frame(minWidth: 600)
        }
        .toolbar {
            Button("Vista iniziale", systemImage: "view.3d") { cameraReset = UUID() }
            Button("Esporta STL", systemImage: "square.and.arrow.up") { prepareExport() }
                .disabled({ if case .failure = result { return true }; return false }())
        }
        .fileExporter(isPresented: $exporting, document: exportDocument,
                      contentType: STLDocument.readableContentTypes[0], defaultFilename: "Takeoff-Part.stl") { outcome in
            if case .failure(let error) = outcome { errorMessage = error.localizedDescription }
        }
        .alert("Operazione non riuscita", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func dimension(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(label, value: value, format: .number.precision(.fractionLength(0...3)))
                .multilineTextAlignment(.trailing).frame(width: 88)
            Text("mm").foregroundStyle(.secondary)
        }
    }

    private func prepareExport() {
        do {
            let mesh = try result.get()
            exportDocument = STLDocument(data: try STLExporter.encode(mesh))
            exporting = true
        } catch { errorMessage = error.localizedDescription }
    }
}

