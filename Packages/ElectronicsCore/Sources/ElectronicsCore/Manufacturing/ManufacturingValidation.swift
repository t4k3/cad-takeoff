import Foundation

extension ElectronicsManufacturingImport {
    /// Also used on document decode and every historical state. Never trust serialized proposals.
    public static func requireIntegrity(_ package: ManufacturingPackage) throws {
        try Task.checkCancellation()
        try requireName(package.name)
        guard package.layers.count <= 9, package.drills.count <= 100_000,
              package.components.count <= 20_000, (1...1_000).contains(package.lots.count),
              package.sources.count <= 10_000, package.issues.count <= 20_000 else {
            throw failure("manufacturing_limit", "Pacchetto troppo grande: suddividere scheda o lotti.")
        }
        var ids: Set<UUID> = [package.id]
        func identity(_ id: UUID) throws {
            guard ids.insert(id).inserted else { throw failure("manufacturing_identity", "Identità duplicate nel pacchetto.", [id]) }
        }
        guard Set(package.layers.map(\.kind)).count == package.layers.count,
              [.profile, .topCopper, .bottomCopper].allSatisfy({ k in package.layers.contains { $0.kind == k } }) else {
            throw failure("manufacturing_layers", "Strati mancanti o duplicati nel pacchetto.")
        }
        var primitiveCount = 0, pointCount = 0, shapeCount = 0
        for layer in package.layers {
            try Task.checkCancellation(); try identity(layer.id); try requireName(layer.name)
            primitiveCount += layer.primitives.count
            guard primitiveCount <= 250_000 else { throw failure("manufacturing_limit", "Troppi oggetti Gerber.") }
            for primitive in layer.primitives {
                try identity(primitive.id)
                guard !primitive.shapes.isEmpty else { throw failure("manufacturing_geometry", "Oggetto Gerber senza geometria.", [primitive.id]) }
                for text in [primitive.netName, primitive.componentReference, primitive.pinNumber].compactMap({ $0 }) {
                    guard text.utf8.count <= 4096, !text.contains("\0") else {
                        throw failure("manufacturing_attribute", "Attributo Gerber non valido.", [primitive.id])
                    }
                }
                shapeCount += primitive.shapes.count
                guard shapeCount <= 1_000_000 else { throw failure("manufacturing_limit", "Troppe forme Gerber.") }
                for shape in primitive.shapes {
                    guard ElectronicsGeometry.valid(shape.radius), shape.radius >= 0, !shape.contours.isEmpty else {
                        throw failure("manufacturing_geometry", "Raggio o contorni Gerber non validi.", [primitive.id])
                    }
                    for contour in shape.contours {
                        pointCount += contour.count
                        guard pointCount <= 2_000_000 else { throw failure("manufacturing_limit", "Troppi vertici Gerber.") }
                        guard !contour.isEmpty, contour.allSatisfy(ElectronicsGeometry.valid),
                              shape.radius > 0 || contour.count >= 3 else {
                            throw failure("manufacturing_geometry", "Coordinate o contorno Gerber non validi.", [primitive.id])
                        }
                    }
                }
            }
        }
        for drill in package.drills {
            try identity(drill.id)
            guard ElectronicsGeometry.valid(drill.position), drill.end.map(ElectronicsGeometry.valid) ?? true,
                  drill.diameter.isFinite, drill.diameter > 0, drill.diameter <= 1000 else {
                throw failure("manufacturing_drill", "Foratura non valida.", [drill.id])
            }
        }
        var refs = Set<String>()
        for c in package.components {
            try identity(c.id); try requireName(c.reference)
            guard refs.insert(c.reference.uppercased()).inserted else {
                throw failure("manufacturing_reference", "Riferimento duplicato: \(c.reference).", [c.id])
            }
            for text in [c.value, c.footprint, c.lcscPartNumber].compactMap({ $0 }) {
                guard text.utf8.count <= 4096, !text.contains("\0") else {
                    throw failure("manufacturing_component", "Dati componente non validi.", [c.id])
                }
            }
            if let p = c.placement {
                guard p.reference.uppercased() == c.reference.uppercased(), ElectronicsGeometry.valid(p.position),
                      ElectronicsGeometry.validAngle(p.rotationDegrees) else {
                    throw failure("manufacturing_position", "Posizione componente non valida.", [c.id])
                }
            }
        }
        let componentIDs = Set(package.components.map(\.id))
        for lot in package.lots {
            try identity(lot.id); try requireName(lot.name)
            guard Set(lot.fittedComponentIDs).count == lot.fittedComponentIDs.count,
                  Set(lot.fittedComponentIDs).isSubset(of: componentIDs),
                  lot.bomSHA256.map(validHash) ?? true else {
                throw failure("manufacturing_lot", "Il lotto contiene componenti inesistenti, duplicati o una provenienza non valida.", [lot.id])
            }
        }
        guard package.activeLot != nil else { throw failure("manufacturing_lot", "Lotto attivo inesistente.") }
        for source in package.sources {
            guard !source.name.isEmpty, source.name.utf8.count <= 4096,
                  validHash(source.sha256), (0...128 * 1024 * 1024).contains(source.byteCount) else {
                throw failure("manufacturing_source", "Provenienza del pacchetto non valida.")
            }
        }
        guard try profileBounds(package.layers) == package.bounds else {
            throw failure("manufacturing_bounds", "Ingombro non coerente con il contorno Gerber.")
        }
        for issue in package.issues {
            guard issue.position.map(ElectronicsGeometry.valid) ?? true else { throw failure("manufacturing_issue", "Posizione diagnostica non valida.") }
        }
    }

    private static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
