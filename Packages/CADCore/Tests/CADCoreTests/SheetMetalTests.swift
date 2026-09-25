import Foundation
import Testing
@testable import CADCore

@Suite struct SheetMetalTests {
    private func rule(k: Double = 0.4) throws -> SheetMetalRule {
        try .init(name: "Fixture, non calibrata", thickness: 2, insideRadius: 3, kFactor: k)
    }
    private func base() throws -> SheetMetalPart {
        try .init(name: "Staffa L", rule: rule(), width: 40, baseLength: 60)
    }
    private func bracket(direction: SheetMetalBendDirection = .up, segments: Int = 24) throws -> SheetMetalPart {
        try base().addingFlange(.init(length: 30, angleDegrees: 90, direction: direction, bendSegments: segments))
    }

    @Test func baseIsAClosedPlateWithExactFlatOutline() throws {
        let part = try base(), result = try SheetMetalEngine.rebuild(part)
        try result.foldedBody.validate()
        #expect(result.foldedBody.vertices.count == 8 && result.foldedBody.faces.count == 6)
        #expect(result.foldedBody.mesh.bounds?.min == Vec3(-60, -20, 0))
        #expect(result.foldedBody.mesh.bounds?.max == Vec3(0, 20, 2))
        #expect(abs(result.foldedBody.mesh.volume - 4800) < 1e-8)
        #expect(result.flatPattern.bendZones.isEmpty)
        #expect(result.flatPattern.developedLength == 60 && result.flatPattern.blankArea == 2400)
        #expect(result.flatPattern.isCurrent(for: part))
        #expect(MeshValidator.validate(result.foldedBody.mesh).isWatertight)
        #expect(MeshValidator.validate(result.flatPattern.mesh).isWatertight)
    }

    @Test func rightAngleBracketMatchesSectionAndNeutralLength() throws {
        let part = try bracket(), result = try SheetMetalEngine.rebuild(part)
        let body = result.foldedBody, flat = result.flatPattern
        // Straight dimensions are 60 and 30 from tangencies. R=3, t=2, K=0.4.
        let allowance = Double.pi / 2 * 3.8
        #expect(abs(flat.developedLength - (90 + allowance)) < 1e-12)
        #expect(flat.bendZones.count == 1 && flat.bendZones[0].startX == 0)
        #expect(abs(flat.bendZones[0].centerX - allowance / 2) < 1e-12)
        #expect(body.mesh.bounds?.min == Vec3(-60, -20, 0))
        #expect(abs(body.mesh.bounds!.max.x - 5) < 1e-12)
        #expect(abs(body.mesh.bounds!.max.z - 35) < 1e-12)
        let chordArea = 24 * sin(.pi / 48) * (25.0 - 9.0) / 2
        #expect(abs(body.mesh.volume - 40 * (2 * 90 + chordArea)) < 1e-7)
        #expect(abs(flat.mesh.volume - 40 * 2 * flat.developedLength) < 1e-8)
        #expect(abs(body.maximumSurfaceDeviation - 5 * (1 - cos(.pi / 96))) < 1e-14)
        // The two annular arcs have radial thickness 2 at their vertices.
        let positions = body.vertices.map(\.position)
        #expect(positions.contains { abs($0.x - 3) < 1e-12 && abs($0.z - 5) < 1e-12 })
        #expect(positions.contains { abs($0.x - 5) < 1e-12 && abs($0.z - 5) < 1e-12 })
        try body.validate()
        #expect(MeshValidator.validate(body.mesh).isWatertight)
        let data = try ThreeMFExporter.archive(parts: [.init(id: part.id, name: part.name, mesh: body.mesh)])
        #expect(data.starts(with: [0x50, 0x4b, 0x03, 0x04]))
    }

    @Test func downBendPreservesWindingAndFlatGeometry() throws {
        let up = try SheetMetalEngine.rebuild(bracket())
        let down = try SheetMetalEngine.rebuild(bracket(direction: .down))
        try down.foldedBody.validate()
        #expect(abs(up.foldedBody.mesh.volume - down.foldedBody.mesh.volume) < 1e-8)
        #expect(abs(down.foldedBody.mesh.bounds!.min.z + 33) < 1e-12)
        #expect(abs(down.foldedBody.mesh.bounds!.max.z - 2) < 1e-12)
        #expect(up.flatPattern.outline == down.flatPattern.outline)
        #expect(down.flatPattern.bendZones[0].direction == .down)
    }

    @Test func flatLengthDoesNotDependOnDisplayTessellation() throws {
        let part = try bracket(segments: 8)
        let coarse = try SheetMetalEngine.rebuild(part)
        let finePart = try part.editingFlange(.init(length: 30, angleDegrees: 90, bendSegments: 60))
        let fine = try SheetMetalEngine.rebuild(finePart)
        #expect(coarse.flatPattern.developedLength == fine.flatPattern.developedLength)
        #expect(coarse.foldedBody.maximumSurfaceDeviation > fine.foldedBody.maximumSurfaceDeviation)
        let analytic = 40 * (180 + Double.pi / 4 * 16)
        #expect(abs(fine.foldedBody.mesh.volume - analytic) < abs(coarse.foldedBody.mesh.volume - analytic))
    }

    @Test func savedOperationsReplayWithStableOperationIDs() throws {
        let original = try bracket()
        let reopened = try SheetMetalPart.decode(original.encoded())
        #expect(original == reopened)
        let before = try SheetMetalEngine.rebuild(original)
        let after = try SheetMetalEngine.rebuild(reopened)
        #expect(before.foldedBody.mesh == after.foldedBody.mesh)
        #expect(before.flatPattern == after.flatPattern)
        let resized = try original.editingBase(width: 55, length: 80)
        #expect(resized.operations.map(\.id) == original.operations.map(\.id))
        #expect(resized.revision == original.revision + 1)
        let edited = try resized.editingFlange(.init(length: 15, angleDegrees: 45))
        #expect(edited.operations[1].id == original.operations[1].id)
        #expect(try SheetMetalEngine.rebuild(edited).flatPattern.developedLength > 95)
    }

    @Test func suppressionAndRollbackKeepOriginalHistory() throws {
        let part = try bracket()
        let suppressed = try part.suppressingFlange(true)
        #expect(suppressed.operations.count == 2 && suppressed.operations[1].isSuppressed)
        #expect(try SheetMetalEngine.rebuild(suppressed).flatPattern.developedLength == 60)
        #expect(try suppressed.suppressingFlange(true) == suppressed)
        let restored = try suppressed.suppressingFlange(false)
        #expect(try SheetMetalEngine.rebuild(restored).foldedBody.mesh == SheetMetalEngine.rebuild(part).foldedBody.mesh)
        let rolled = try part.rolledBack(through: part.operations[0].id)
        #expect(rolled.operations.count == 1 && part.operations.count == 2)
        #expect(rolled.operations[0].id == part.operations[0].id)
        #expect(try SheetMetalEngine.rebuild(rolled).foldedBody.faces.count == 6)
        #expect(throws: SheetMetalError.self) { try part.rolledBack(through: UUID()) }
    }

    @Test func ruleChangesInvalidateDerivedPatternAndAffectGeometry() throws {
        let part = try bracket(), old = try SheetMetalEngine.rebuild(part)
        let changedRule = try part.rule.revised(thickness: 3, insideRadius: 4, kFactor: 0.5)
        let changed = try part.replacingRule(changedRule)
        let rebuilt = try SheetMetalEngine.rebuild(changed)
        #expect(changedRule.id == part.rule.id && changedRule.revision == part.rule.revision + 1)
        #expect(rebuilt.flatPattern.ruleRevision == changedRule.revision)
        #expect(!old.flatPattern.isCurrent(for: changed) && rebuilt.flatPattern.isCurrent(for: changed))
        #expect(abs(rebuilt.flatPattern.developedLength - (90 + .pi / 2 * 5.5)) < 1e-12)
        #expect(abs(rebuilt.foldedBody.mesh.bounds!.max.z - 37) < 1e-12)
        #expect(throws: SheetMetalError.staleFlatPattern) { try SheetMetalDXF.export(old.flatPattern, for: changed) }
        let reused = try SheetMetalRule(id: part.rule.id, revision: part.rule.revision, name: "bad", thickness: 3, insideRadius: 3, kFactor: 0.4)
        #expect(throws: SheetMetalError.self) { try part.replacingRule(reused) }
    }

    @Test func dxfSeparatesCutBendAndTangentLayers() throws {
        for direction in [SheetMetalBendDirection.up, .down] {
            let part = try bracket(direction: direction), flat = try SheetMetalEngine.rebuild(part).flatPattern
            let dxf = try SheetMetalDXF.export(flat, for: part)
            #expect(dxf.contains("9\n$INSUNITS\n70\n4\n"))
            #expect(dxf.contains("0\nLWPOLYLINE\n100\nAcDbEntity\n8\nCUT\n"))
            #expect(dxf.contains("90\n4\n70\n1\n"))
            #expect(dxf.contains("8\n\(direction == .up ? "BEND_UP" : "BEND_DOWN")\n100\nAcDbLine"))
            #expect(dxf.components(separatedBy: "0\nLINE\n").count - 1 == 3)
            #expect(dxf.hasSuffix("0\nEOF\n"))
        }
        let plate = try base(), flat = try SheetMetalEngine.rebuild(plate).flatPattern
        #expect(try !SheetMetalDXF.export(flat, for: plate).contains("0\nLINE\n"))
    }

    @Test func invalidInputNeverProducesAPartOrSilentCorrection() throws {
        for value in [Double.nan, .infinity, -1, 0, 0.001, 10_001] {
            #expect(throws: SheetMetalError.self) { try SheetMetalRule(name: "x", thickness: value, insideRadius: 3, kFactor: 0.4) }
            #expect(throws: SheetMetalError.self) { try base().editingBase(width: value, length: 40) }
        }
        for k in [Double.nan, .infinity, -0.001, 1.001] {
            #expect(throws: SheetMetalError.self) { try rule(k: k) }
        }
        for angle in [Double.nan, .infinity, -90, 0, 4.99, 135.01, 180] {
            #expect(throws: SheetMetalError.self) { try base().addingFlange(.init(length: 20, angleDegrees: angle)) }
        }
        #expect(throws: SheetMetalError.self) { try bracket().addingFlange(.init(length: 10, angleDegrees: 90)) }
        #expect(throws: SheetMetalError.self) { try base().addingFlange(.init(length: 10, angleDegrees: 90, bendSegments: Int.max)) }
    }

    @Test func alteredAndFutureDocumentsAreRejectedOrInvalidatePattern() throws {
        let part = try bracket(), flat = try SheetMetalEngine.rebuild(part).flatPattern
        var object = try JSONSerialization.jsonObject(with: part.encoded()) as! [String: Any]
        object["version"] = 99
        #expect(throws: SheetMetalError.self) { try SheetMetalPart.decode(JSONSerialization.data(withJSONObject: object)) }
        object["version"] = 1
        var storedRule = object["rule"] as! [String: Any]
        storedRule["thickness"] = 4
        object["rule"] = storedRule
        let altered = try SheetMetalPart.decode(JSONSerialization.data(withJSONObject: object))
        #expect(altered.revision == part.revision && !flat.isCurrent(for: altered))
        #expect(throws: SheetMetalError.staleFlatPattern) { try SheetMetalDXF.export(flat, for: altered) }
        storedRule["kFactor"] = 2; object["rule"] = storedRule
        // Also reject invalid values decoded via the standard synthesized Codable path at rebuild.
        let invalid = try JSONDecoder().decode(SheetMetalPart.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: SheetMetalError.self) { try SheetMetalEngine.rebuild(invalid) }
    }

    @Test func parameterSweepKeepsClosedGeometryAndAnalyticFlatLength() throws {
        for angle in [15.0, 45, 90, 120, 135] {
            for direction in [SheetMetalBendDirection.up, .down] {
                for k in [0.0, 0.5, 1] {
                    let p = try SheetMetalPart(name: "Sweep", rule: rule(k: k), width: 12, baseLength: 18)
                        .addingFlange(.init(length: 9, angleDegrees: angle, direction: direction, bendSegments: 12))
                    let r = try SheetMetalEngine.rebuild(p)
                    try r.foldedBody.validate()
                    #expect(MeshValidator.validate(r.foldedBody.mesh).isWatertight)
                    #expect(abs(r.flatPattern.developedLength - (27 + angle * .pi / 180 * (3 + k * 2))) < 1e-12)
                }
            }
        }
    }
}
