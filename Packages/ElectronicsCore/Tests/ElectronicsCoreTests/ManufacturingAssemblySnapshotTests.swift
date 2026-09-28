import Foundation
import XCTest
@testable import ElectronicsCore

final class ManufacturingAssemblySnapshotTests: XCTestCase {
    private func id(_ value: Int) -> UUID {
        UUID(uuidString: "D4111000-0000-4000-8000-" + String(format: "%012x", value))!
    }
    private func component(_ number: Int, position: PCBPoint? = .init(), side: BoardSide = .top,
                           rotation: Double = 0, footprint: String = "R_0805",
                           binding: ManufacturingModelBinding? = nil) -> ManufacturingComponent {
        let reference = "R\(number)"
        var c = ManufacturingComponent(id: id(number), reference: reference, footprint: footprint,
            placement: position.map { .init(reference: reference, position: $0, rotationDegrees: rotation, side: side) })
        c.modelBinding = binding
        return c
    }
    private func package(_ components: [ManufacturingComponent], fitted: [UUID]? = nil,
                         thickness: Double? = nil, compoundProfile: Bool = false, halfWidth: Double = 20,
                         drills: [ManufacturingDrill] = []) -> ManufacturingPackage {
        let points: [PCBPoint] = [.init(-halfWidth,-15), .init(halfWidth,-15), .init(halfWidth,15), .init(-halfWidth,15)]
        // Gerber draws are separate simple-aperture primitives; grouping every
        // side into one compound aperture is not a supported routing contour.
        var outline = points.indices.map { i in
            ManufacturingPrimitive(id: id(6 + i), shapes: [
                .init(contours: [[points[i], points[(i + 1) % points.count]]], radius: 0.05)
            ])
        }
        if compoundProfile { outline = [.init(id: id(6), shapes: outline.flatMap(\.shapes))] }
        var result = ManufacturingPackage(id: id(1), name: "QA assemblata", layers: [
            .init(id: id(3), name: "Top", kind: .topCopper, primitives: []),
            .init(id: id(4), name: "Bottom", kind: .bottomCopper, primitives: []),
            .init(id: id(5), name: "Profile", kind: .profile, primitives: outline)
        ], drills: drills, components: components,
           lots: [.init(id: id(2), name: "Lotto", fittedComponentIDs: fitted ?? components.map(\.id))], activeLotID: id(2),
           sources: [], bounds: .init(minimum: .init(-halfWidth,-15), maximum: .init(halfWidth,15)))
        if let thickness { result.assemblySettings = .init(boardThickness: thickness) }
        return result
    }

    func testThicknessAssumptionIsExplicitAndDoesNotChangeSource() throws {
        let source = package([component(100)])
        let before = source
        let estimated = try ManufacturingAssemblySnapshot(package: source)
        XCTAssertEqual(estimated.boardThickness, 1.6)
        XCTAssertTrue(estimated.isBoardThicknessAssumed)
        XCTAssertTrue(estimated.issues.contains { $0.code == "assembly_thickness_assumed" && $0.subjectIDs == [source.id] })
        XCTAssertEqual(source, before)
        let specified = try ManufacturingAssemblySnapshot(package: package([component(100)], thickness: 2.3))
        XCTAssertEqual(specified.boardThickness, 2.3)
        XCTAssertFalse(specified.isBoardThicknessAssumed)
        XCTAssertFalse(specified.issues.contains { $0.code == "assembly_thickness_assumed" })
        XCTAssertFalse(specified.boardParts.isEmpty)
        XCTAssertEqual(try XCTUnwrap(specified.boardParts.flatMap(\.vertices).map(\.z).min()), 0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(specified.boardParts.flatMap(\.vertices).map(\.z).max()), 2.3, accuracy: 1e-12)
    }

    func testTopBottomArbitraryRotationsOffsetsAndWindingUseProperRigidTransform() throws {
        let model = try XCTUnwrap(ManufacturingPackageCatalog.model(key: "ftk.r0805.v1"))
        let binding = ManufacturingModelBinding(modelKey: model.key, offset: .init(0.7,-0.9,0.4),
            rotationDegrees: .init(13,-29,47), alignmentVerified: true)
        for side in [BoardSide.top, .bottom] {
            let c = component(100, position: .init(8,-4), side: side, rotation: 113, binding: binding)
            let source = package([c], thickness: 2.3)
            let snapshot = try ManufacturingAssemblySnapshot(package: source)
            let instance = try XCTUnwrap(snapshot.instances.first)
            XCTAssertEqual(instance.position, c.placement?.position)
            XCTAssertEqual(instance.parts.count, model.parts.count)
            XCTAssertTrue(instance.alignmentVerified)
            XCTAssertEqual(instance.quality, .approximate, "Alignment does not certify generic dimensions")
            let matrix = try XCTUnwrap(instance.transform)
            XCTAssertEqual(determinant(matrix), 1, accuracy: 1e-12)
            for (sourcePart, worldPart) in zip(model.parts, instance.parts) {
                XCTAssertEqual(sourcePart.indices, worldPart.indices)
                XCTAssertEqual(sourcePart.id, worldPart.id)
                XCTAssertEqual(sourcePart.material, worldPart.material)
                for (local, actual) in zip(sourcePart.vertices, worldPart.vertices) {
                    let expected = expected(local, binding: binding, placement: try XCTUnwrap(c.placement), thickness: 2.3)
                    XCTAssertEqual(actual.x, expected.x, accuracy: 1e-10)
                    XCTAssertEqual(actual.y, expected.y, accuracy: 1e-10)
                    XCTAssertEqual(actual.z, expected.z, accuracy: 1e-10)
                }
                XCTAssertGreaterThan(volume(sourcePart), 0)
                XCTAssertEqual(volume(sourcePart), volume(worldPart), accuracy: 1e-9)
                let polygon = try XCTUnwrap(instance.polygons.first { $0.partID == worldPart.id })
                for vertex in worldPart.vertices {
                    XCTAssertTrue(PCBGeometry.inside(.init(vertex.x, vertex.y), polygon.points))
                }
            }
            if let pin = model.pinOne {
                let actual = try XCTUnwrap(instance.pinOne)
                let expected = expected(pin, binding: binding, placement: try XCTUnwrap(c.placement), thickness: 2.3)
                XCTAssertEqual(actual.x, expected.x, accuracy: 1e-10)
                XCTAssertEqual(actual.y, expected.y, accuracy: 1e-10)
                XCTAssertEqual(actual.z, expected.z, accuracy: 1e-10)
            }
            XCTAssertEqual(source.components[0].placement, c.placement)
        }
    }

    func testUnalignedGenericModelsRemainExplicitAndMissingDataDoesNotInventGeometry() throws {
        let known = component(100)
        let unknown = component(101, position: .init(5,6), footprint: "Proprietary_NotInCatalog")
        let unplaced = component(102, position: nil)
        let snapshot = try ManufacturingAssemblySnapshot(package: package([known, unknown, unplaced]))
        XCTAssertEqual(snapshot.instances.count, 3)
        let instance = try XCTUnwrap(snapshot.instances.first { $0.id == known.id })
        XCTAssertEqual(instance.quality, .approximate)
        XCTAssertFalse(instance.alignmentVerified)
        XCTAssertTrue(snapshot.issues.contains { $0.code == "assembly_alignment_unverified" && $0.subjectIDs == [known.id] })
        let missing = try XCTUnwrap(snapshot.instances.first { $0.id == unknown.id })
        XCTAssertEqual(missing.quality, .missing)
        XCTAssertNil(missing.transform); XCTAssertNil(missing.bounds); XCTAssertNil(missing.pinOne)
        XCTAssertTrue(missing.parts.isEmpty); XCTAssertTrue(missing.polygons.isEmpty)
        XCTAssertEqual(missing.position, .init(5,6))
        XCTAssertEqual(snapshot.pick(point: .init(5,6), tolerance: 0).map(\.id), [unknown.id])
        XCTAssertTrue(snapshot.pick(point: .init(5.2,6), tolerance: 0.1).isEmpty)
        let absent = try XCTUnwrap(snapshot.instances.first { $0.id == unplaced.id })
        XCTAssertNil(absent.position); XCTAssertNil(absent.side); XCTAssertNil(absent.transform)
        XCTAssertTrue(absent.parts.isEmpty); XCTAssertTrue(absent.polygons.isEmpty)
        XCTAssertFalse(snapshot.pick(point: .init(), tolerance: 100).contains { $0.id == unplaced.id })
        XCTAssertFalse(snapshot.snapTargets(near: .init(), radius: 100).contains { $0.id == unplaced.id })
        XCTAssertTrue(snapshot.issues.contains { $0.code == "assembly_position_missing" && $0.subjectIDs == [unplaced.id] && $0.position == nil })
    }

    func testExplicitModelPinOneFollowsTheSameWorldTransformAndIsASnapTarget() throws {
        let model = try XCTUnwrap(ManufacturingPackageCatalog.model(key: "ftk.sot23-3.v1"))
        let localPin = try XCTUnwrap(model.pinOne)
        let binding = ManufacturingModelBinding(modelKey: model.key, offset: .init(-0.4,0.7,0.3),
            rotationDegrees: .init(-21,37,119))
        // Explicit assignment wins over the recognized R_0805 footprint suggestion.
        let c = component(100, position: .init(-7,8), side: .bottom, rotation: -63, binding: binding)
        let snapshot = try ManufacturingAssemblySnapshot(package: package([c], thickness: 1.2))
        let instance = try XCTUnwrap(snapshot.instances.first)
        XCTAssertEqual(instance.modelKey, model.key)
        let actual = try XCTUnwrap(instance.pinOne)
        let expected = expected(localPin, binding: binding, placement: try XCTUnwrap(c.placement), thickness: 1.2)
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-10)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-10)
        XCTAssertEqual(actual.z, expected.z, accuracy: 1e-10)
        XCTAssertTrue(snapshot.snapTargets(near: .init(actual.x, actual.y), radius: 1e-9, side: .bottom)
            .contains { $0.id == c.id && $0.kind == .vertex })
    }

    func testPickUsesWorldBodiesNotCPLCenterOrBoundingRectangle() throws {
        let binding = ManufacturingModelBinding(modelKey: "ftk.r0805.v1", offset: .init(5,0,0), rotationDegrees: .init(0,0,45))
        let c = component(100, binding: binding)
        let snapshot = try ManufacturingAssemblySnapshot(package: package([c]))
        XCTAssertEqual(snapshot.pick(point: .init(5,0), tolerance: 0).map(\.id), [c.id])
        XCTAssertTrue(snapshot.pick(point: .init(), tolerance: 0.1).isEmpty)
        let box = try XCTUnwrap(snapshot.instances.first?.bounds)
        XCTAssertTrue(snapshot.pick(point: box.minimum, tolerance: 0).isEmpty)
        XCTAssertEqual(snapshot.snapTargets(near: .init(), radius: 0).first?.kind, .componentCenter)
        let vertex = try XCTUnwrap(snapshot.instances.first?.polygons.first?.points.first)
        XCTAssertTrue(snapshot.snapTargets(near: vertex, radius: 1e-8).contains { $0.id == c.id && $0.kind == .vertex })
    }

    func testSideAndExcludedFiltersPreserveAllInstances() throws {
        let top = component(100), bottom = component(101, side: .bottom)
        let snapshot = try ManufacturingAssemblySnapshot(package: package([bottom, top], fitted: [top.id]))
        XCTAssertEqual(snapshot.instances.count, 2)
        XCTAssertEqual(snapshot.instances.filter(\.fitted).map(\.id), [top.id])
        XCTAssertEqual(snapshot.pick(point: .init(), tolerance: 0).map(\.id), [top.id])
        XCTAssertTrue(snapshot.pick(point: .init(), tolerance: 0, side: .bottom).isEmpty)
        XCTAssertEqual(snapshot.pick(point: .init(), tolerance: 0, side: .bottom, includeExcluded: true).map(\.id), [bottom.id])
        XCTAssertEqual(snapshot.pick(point: .init(), tolerance: 0, side: .top, includeExcluded: true).map(\.id), [top.id])
        XCTAssertFalse(snapshot.snapTargets(near: .init(), radius: 10, side: .bottom).contains { $0.id == bottom.id })
        XCTAssertEqual(snapshot.snapTargets(near: .init(), radius: 0, side: .bottom, includeExcluded: true).first?.id, bottom.id)
    }

    func testCapacitorPolygonsPaintBuriedTerminalsBeforeCanOnBothSidesAfterZRotation() throws {
        let model = try XCTUnwrap(ManufacturingPackageCatalog.model(key: "ftk.cp-elec-6.3x7.7.v1"))
        let binding = ManufacturingModelBinding(modelKey: model.key, offset: .init(0.2,-0.3,0.5),
                                               rotationDegrees: .init(0,0,19))
        let expectedOrder = ["terminal-1", "terminal-2", "base", "can-a", "can-b", "negative-stripe"]
        for side in [BoardSide.top, .bottom] {
            for angle in [0.0, 37, 137] {
                let c = component(100, position: .init(0.8,-1.7), side: side, rotation: angle, binding: binding)
                let snapshot = try ManufacturingAssemblySnapshot(package: package([c], thickness: 1.2))
                let instance = try XCTUnwrap(snapshot.instances.first), placement = try XCTUnwrap(c.placement)
                XCTAssertEqual(instance.polygons.map(\.partID), expectedOrder)
                XCTAssertEqual(instance.parts.map(\.id), model.parts.map(\.id), "Painter order must not reorder the 3D meshes")
                for (source, world) in zip(model.parts, instance.parts) {
                    XCTAssertEqual(source.indices, world.indices)
                    for (local, actual) in zip(source.vertices, world.vertices) {
                        let expected = expected(local, binding: binding, placement: placement, thickness: 1.2)
                        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-10)
                        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-10)
                        XCTAssertEqual(actual.z, expected.z, accuracy: 1e-10)
                    }
                }
                // These points belong to a terminal's projection, the base and the
                // can. The final filled polygon must depict the can, not buried metal.
                for x in [-2.35, 2.35] {
                    let world = expected(.init(x,0.1,0.05), binding: binding, placement: placement, thickness: 1.2)
                    let point = PCBPoint(world.x, world.y)
                    let covering = instance.polygons.filter { PCBGeometry.inside(point, $0.points) }
                    XCTAssertTrue(covering.contains { $0.partID.hasPrefix("terminal-") })
                    XCTAssertEqual(covering.last?.partID, x < 0 ? "negative-stripe" : "can-a")
                    XCTAssertEqual(snapshot.pick(point: point, tolerance: 0, side: side).map(\.id), [c.id])
                }
                let again = try ManufacturingAssemblySnapshot(package: package([c], thickness: 1.2), previous: snapshot)
                XCTAssertEqual(again.instances.first?.polygons, instance.polygons)
            }
        }
    }

    func testValidOffsetBeyondCPLCoordinateLimitRemainsSelectable() throws {
        let binding = ManufacturingModelBinding(modelKey: "ftk.r0805.v1", offset: .init(20,0,0))
        let c = component(100, position: .init(99_999,0), binding: binding)
        let snapshot = try ManufacturingAssemblySnapshot(package: package([c]))
        XCTAssertEqual(snapshot.pick(point: .init(100_019,0), tolerance: 0).map(\.id), [c.id])
        let vertex = try XCTUnwrap(snapshot.instances.first?.polygons.first?.points.first)
        XCTAssertTrue(snapshot.snapTargets(near: vertex, radius: 1e-8).contains { $0.id == c.id })
    }

    func testQueriesAreBoundedStableAndSourceSurvivesSerialization() throws {
        let source = package((100..<400).reversed().map { component($0, footprint: "Unknown") })
        let reopened = try JSONDecoder().decode(ManufacturingPackage.self, from: JSONEncoder().encode(source))
        let a = try ManufacturingAssemblySnapshot(package: source), b = try ManufacturingAssemblySnapshot(package: reopened)
        let picks = a.pick(point: .init(), tolerance: 0)
        XCTAssertEqual(picks.count, 256)
        XCTAssertEqual(picks.map(\.id), (100..<356).map(id))
        XCTAssertEqual(picks, b.pick(point: .init(), tolerance: 0))
        let snaps = a.snapTargets(near: .init(), radius: 0)
        XCTAssertEqual(snaps.count, 256)
        XCTAssertEqual(snaps.map(\.id), (100..<356).map(id))
        XCTAssertEqual(snaps, b.snapTargets(near: .init(), radius: 0))
        XCTAssertEqual(a.instances, b.instances)
        XCTAssertEqual(reopened, source)
    }

    func testMalformedQueriesReturnEmpty() throws {
        let snapshot = try ManufacturingAssemblySnapshot(package: package([component(100)]))
        for value in [-1.0, Double.nan, .infinity] {
            XCTAssertTrue(snapshot.pick(point: .init(), tolerance: value).isEmpty)
            XCTAssertTrue(snapshot.snapTargets(near: .init(), radius: value).isEmpty)
        }
        for point in [PCBPoint(.nan, 0), PCBPoint(0, .infinity)] {
            XCTAssertTrue(snapshot.pick(point: point, tolerance: 1).isEmpty)
            XCTAssertTrue(snapshot.snapTargets(near: point, radius: 1).isEmpty)
        }
    }

    func testUnsupportedProfileKeepsComponentBodiesAndReportsTheBoardFailure() throws {
        let c = component(100)
        let snapshot = try ManufacturingAssemblySnapshot(package: package([c], compoundProfile: true))
        XCTAssertTrue(snapshot.boardParts.isEmpty)
        XCTAssertFalse(try XCTUnwrap(snapshot.instances.first).parts.isEmpty)
        XCTAssertTrue(snapshot.issues.contains { $0.subjectIDs?.contains(id(6)) == true })
        XCTAssertEqual(snapshot.pick(point: .init(), tolerance: 0).map(\.id), [c.id])
    }

    func testPreviousSnapshotReusesBoardBuffersButRebuildsLotAndAlignment() throws {
        let source = package([component(100)])
        let previous = try ManufacturingAssemblySnapshot(package: source)
        var changed = source
        changed.components[0].modelBinding = .init(modelKey: "ftk.r0805.v1", offset: .init(5,0,0), alignmentVerified: true)
        changed.lots[0].fittedComponentIDs = []
        let cached = try ManufacturingAssemblySnapshot(package: changed, previous: previous)
        let fresh = try ManufacturingAssemblySnapshot(package: changed)
        XCTAssertEqual(cached.boardParts, fresh.boardParts)
        XCTAssertEqual(cached.instances, fresh.instances)
        XCTAssertEqual(cached.issues, fresh.issues)
        XCTAssertFalse(try XCTUnwrap(cached.instances.first).fitted)
        XCTAssertTrue(try XCTUnwrap(cached.instances.first).alignmentVerified)
        XCTAssertTrue(cached.pick(point: .init(5,0), tolerance: 0).isEmpty)
        XCTAssertEqual(cached.pick(point: .init(5,0), tolerance: 0, includeExcluded: true).map(\.id), [id(100)])
        XCTAssertTrue(cached.pick(point: .init(), tolerance: 0, includeExcluded: true).isEmpty)
        let oldPart = try XCTUnwrap(previous.boardParts.first), newPart = try XCTUnwrap(cached.boardParts.first)
        // Check reuse while both unsafe borrows are valid: equal geometry alone
        // would also pass if each offset preview unnecessarily triangulated again.
        oldPart.vertices.withUnsafeBufferPointer { old in
            newPart.vertices.withUnsafeBufferPointer { new in XCTAssertEqual(old.baseAddress, new.baseAddress) }
        }
        oldPart.indices.withUnsafeBufferPointer { old in
            newPart.indices.withUnsafeBufferPointer { new in XCTAssertEqual(old.baseAddress, new.baseAddress) }
        }
        XCTAssertEqual(source.components[0].modelBinding, nil)
        XCTAssertTrue(try XCTUnwrap(previous.instances.first).fitted)
        var explicit = source
        explicit.assemblySettings = .init(boardThickness: 1.6)
        let sameThickness = try ManufacturingAssemblySnapshot(package: explicit, previous: previous)
        XCTAssertFalse(sameThickness.isBoardThicknessAssumed)
        XCTAssertFalse(sameThickness.issues.contains { $0.code == "assembly_thickness_assumed" })
        XCTAssertEqual(sameThickness.boardParts, previous.boardParts)
    }

    func testPreviousBoardCacheInvalidatesForThicknessProfileDrillsAndIdentity() throws {
        let c = component(100), source = package([c])
        let previous = try ManufacturingAssemblySnapshot(package: source)
        let thicker = try ManufacturingAssemblySnapshot(package: package([c], thickness: 2.4), previous: previous)
        XCTAssertNotEqual(thicker.boardParts, previous.boardParts)
        XCTAssertEqual(thicker.boardParts.flatMap(\.vertices).map(\.z).max(), 2.4)
        let wider = try ManufacturingAssemblySnapshot(package: package([c], halfWidth: 21), previous: previous)
        XCTAssertNotEqual(wider.boardParts, previous.boardParts)
        XCTAssertEqual(wider.boardParts.flatMap(\.vertices).map(\.x).max(), 21)
        let drilled = try ManufacturingAssemblySnapshot(package: package([c], drills: [
            .init(id: id(500), position: .init(), diameter: 1, isPlated: true)
        ]), previous: previous)
        XCTAssertFalse(drilled.boardParts.isEmpty)
        XCTAssertNotEqual(drilled.boardParts, previous.boardParts)
        let other = ManufacturingPackage(id: id(99), name: source.name, layers: source.layers, drills: source.drills,
            components: source.components, lots: source.lots, activeLotID: source.activeLotID, sources: source.sources,
            bounds: source.bounds, issues: source.issues, assemblySettings: source.assemblySettings)
        let separate = try ManufacturingAssemblySnapshot(package: other, previous: previous)
        XCTAssertEqual(separate.boardParts, previous.boardParts)
        let first = try XCTUnwrap(previous.boardParts.first), second = try XCTUnwrap(separate.boardParts.first)
        first.vertices.withUnsafeBufferPointer { a in
            second.vertices.withUnsafeBufferPointer { b in XCTAssertNotEqual(a.baseAddress, b.baseAddress) }
        }
    }

    func testPreviousFailedBoardPreservesDiagnosticsAndCurrentPackageIsStillValidated() throws {
        let source = package([component(100)], compoundProfile: true)
        let previous = try ManufacturingAssemblySnapshot(package: source)
        var changed = source
        changed.lots[0].fittedComponentIDs = []
        let cached = try ManufacturingAssemblySnapshot(package: changed, previous: previous)
        let fresh = try ManufacturingAssemblySnapshot(package: changed)
        XCTAssertTrue(cached.boardParts.isEmpty)
        XCTAssertEqual(cached.issues, fresh.issues)
        XCTAssertEqual(cached.issues.filter { $0.code == "manufacturing_board_mesh" },
                       previous.issues.filter { $0.code == "manufacturing_board_mesh" })
        XCTAssertTrue(cached.issues.contains { $0.code == "manufacturing_board_mesh" && $0.subjectIDs?.isEmpty == false })
        changed.components[0].placement?.position.x = .nan
        XCTAssertThrowsError(try ManufacturingAssemblySnapshot(package: changed, previous: previous))
        let repaired = try ManufacturingAssemblySnapshot(package: package([component(100)]), previous: previous)
        XCTAssertFalse(repaired.boardParts.isEmpty)
        XCTAssertFalse(repaired.issues.contains { $0.code == "manufacturing_board_mesh" })
    }

    func testConstructionHonorsCancellation() async {
        let source = package([component(100)])
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ManufacturingAssemblySnapshot(package: source)
        }
        do { _ = try await task.value; XCTFail("Cancelled assembly must not complete") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    private func expected(_ local: PCBPoint3, binding: ManufacturingModelBinding,
                          placement: ManufacturingPlacement, thickness: Double) -> PCBPoint3 {
        let x = binding.rotationDegrees.x * .pi / 180, y = binding.rotationDegrees.y * .pi / 180,
            z = binding.rotationDegrees.z * .pi / 180, a = placement.rotationDegrees * .pi / 180
        let rx = PCBPoint3(local.x, cos(x) * local.y - sin(x) * local.z, sin(x) * local.y + cos(x) * local.z)
        let ry = PCBPoint3(cos(y) * rx.x + sin(y) * rx.z, rx.y, -sin(y) * rx.x + cos(y) * rx.z)
        var p = PCBPoint3(cos(z) * ry.x - sin(z) * ry.y + binding.offset.x,
                          sin(z) * ry.x + cos(z) * ry.y + binding.offset.y, ry.z + binding.offset.z)
        if placement.side == .bottom { p = .init(-p.x, p.y, -p.z) }
        return .init(cos(a) * p.x - sin(a) * p.y + placement.position.x,
                     sin(a) * p.x + cos(a) * p.y + placement.position.y,
                     p.z + (placement.side == .top ? thickness : 0))
    }
    private func determinant(_ m: [Double]) -> Double {
        m[0] * (m[5] * m[10] - m[6] * m[9]) - m[1] * (m[4] * m[10] - m[6] * m[8]) + m[2] * (m[4] * m[9] - m[5] * m[8])
    }
    private func volume(_ part: ManufacturingAssemblyPart) -> Double {
        let center = part.vertices.reduce(PCBPoint3()) { .init($0.x + $1.x, $0.y + $1.y, $0.z + $1.z) }
        let n = Double(part.vertices.count), origin = PCBPoint3(center.x / n, center.y / n, center.z / n)
        var result = 0.0
        for i in stride(from: 0, to: part.indices.count, by: 3) {
            let a = part.vertices[part.indices[i]], b = part.vertices[part.indices[i + 1]], c = part.vertices[part.indices[i + 2]]
            let u = PCBPoint3(a.x - origin.x, a.y - origin.y, a.z - origin.z)
            let v = PCBPoint3(b.x - origin.x, b.y - origin.y, b.z - origin.z)
            let w = PCBPoint3(c.x - origin.x, c.y - origin.y, c.z - origin.z)
            result += (u.x * (v.y * w.z - v.z * w.y) + u.y * (v.z * w.x - v.x * w.z) + u.z * (v.x * w.y - v.y * w.x)) / 6
        }
        return result
    }
}
