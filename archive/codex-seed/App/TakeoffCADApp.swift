import SwiftUI

@main
struct TakeoffCADApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: CADDocument()) { file in
            EditorView(document: file.$document)
                .frame(minWidth: 980, minHeight: 640)
        }
    }
}

