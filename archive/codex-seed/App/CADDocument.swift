import SwiftUI
import UniformTypeIdentifiers
import CADCore

extension UTType {
    static let takeoffCAD = UTType(exportedAs: "pro.takeoff.cad.document", conformingTo: .json)
}

struct CADDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.takeoffCAD] }
    var model = CADModel()
    init() {}
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        model = try CADModel.decode(data)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try model.encoded())
    }
}

struct STLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "stl") ?? .data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

