import Foundation
import XCTest
@testable import ElectronicsCore

final class ManufacturingQueryTests: XCTestCase {
    private func id(_ value: Int) -> UUID {
        UUID(uuidString: "00000000-0000-4000-8000-" + String(format: "%012x", value))!
    }
    private var top: UUID { id(3) }
    private var bottom: UUID { id(4) }
    private func disk(_ center: PCBPoint, _ radius: Double, dark: Bool = true) -> ManufacturingShape {
        .init(contours: [[center]], radius: radius, isDark: dark)
    }
    private func disk(_ radius: Double, dark: Bool = true) -> ManufacturingShape {
        disk(.init(), radius, dark: dark)
    }
    private func square(_ half: Double) -> [PCBPoint] {
        [.init(-half, -half), .init(half, -half), .init(half, half), .init(-half, half)]
    }
    private func package(_ artwork: [ManufacturingPrimitive], bottom: [ManufacturingPrimitive] = [],
                         components: [ManufacturingComponent] = [], drills: [ManufacturingDrill] = []) -> ManufacturingPackage {
        let outline = square(50)
        let profile = ManufacturingPrimitive(id: id(6), shapes: outline.indices.map {
            .init(contours: [[outline[$0], outline[($0 + 1) % outline.count]]], radius: 0.05)
        })
        return .init(id: id(1), name: "QA manufacturing cursor", layers: [
            .init(id: top, name: "Top", kind: .topCopper, primitives: artwork),
            .init(id: self.bottom, name: "Bottom", kind: .bottomCopper, primitives: bottom),
            .init(id: id(5), name: "Profile", kind: .profile, primitives: [profile])
        ], drills: drills, components: components,
           lots: [.init(id: id(2), name: "Lotto", fittedComponentIDs: [])], activeLotID: id(2),
           sources: [], bounds: .init(minimum: .init(-50, -50), maximum: .init(50, 50)))
    }

    func testLayerClearErasesEarlierObjectsAndLaterDarkRestoresItsOwnIdentity() throws {
        let base = ManufacturingPrimitive(id: id(100), shapes: [disk(5)])
        let clear = ManufacturingPrimitive(id: id(101), shapes: [disk(2)], isDark: false)
        let restored = ManufacturingPrimitive(id: id(102), shapes: [disk(0.5)])
        let snapshot = try ManufacturingSnapshot(package: package([base, clear, restored]))
        XCTAssertEqual(snapshot.pick(point: .init(), tolerance: 0, layerIDs: [top]).map(\.id), [restored.id])
        XCTAssertTrue(snapshot.pick(point: .init(1, 0), tolerance: 0.1, layerIDs: [top]).isEmpty)
        XCTAssertEqual(snapshot.pick(point: .init(3, 0), tolerance: 0, layerIDs: [top]).map(\.id), [base.id])
        let nearClearEdge = snapshot.pick(point: .init(1.95, 0), tolerance: 0.1, layerIDs: [top])
        XCTAssertEqual(nearClearEdge.map(\.id), [base.id])
        XCTAssertEqual(try XCTUnwrap(nearClearEdge.first).distance, 0.05, accuracy: 1e-7)
    }

    func testApertureHoleDoesNotPunchThroughEarlierDarkObject() throws {
        let underlying = ManufacturingPrimitive(id: id(100), shapes: [disk(1)])
        let annulus = ManufacturingPrimitive(id: id(101), shapes: [disk(3), disk(2, dark: false)])
        let snapshot = try ManufacturingSnapshot(package: package([underlying, annulus]))
        XCTAssertEqual(snapshot.pick(point: .init(), tolerance: 0, layerIDs: [top]).map(\.id), [underlying.id])
        XCTAssertTrue(snapshot.pick(point: .init(1.5, 0), tolerance: 0.1, layerIDs: [top]).isEmpty)
        XCTAssertEqual(snapshot.pick(point: .init(2.5, 0), tolerance: 0, layerIDs: [top]).map(\.id), [annulus.id])
    }

    func testLocalMaskDarkCanRestoreMaterialAfterLocalClear() throws {
        let primitive = ManufacturingPrimitive(id: id(100), shapes: [disk(3), disk(2, dark: false), disk(0.5)])
        let snapshot = try ManufacturingSnapshot(package: package([primitive]))
        XCTAssertEqual(snapshot.pick(point: .init(), tolerance: 0, layerIDs: [top]).map(\.id), [primitive.id])
        XCTAssertTrue(snapshot.pick(point: .init(1, 0), tolerance: 0, layerIDs: [top]).isEmpty)
    }

    func testHoleInLayerClearPreservesEarlierMaterialInsideTheHole() throws {
        let base = ManufacturingPrimitive(id: id(100), shapes: [disk(5)])
        let clearRing = ManufacturingPrimitive(id: id(101), shapes: [disk(3), disk(1, dark: false)], isDark: false)
        let snapshot = try ManufacturingSnapshot(package: package([base, clearRing]))
        XCTAssertEqual(snapshot.pick(point: .init(), tolerance: 0, layerIDs: [top]).map(\.id), [base.id])
        XCTAssertTrue(snapshot.pick(point: .init(2, 0), tolerance: 0.1, layerIDs: [top]).isEmpty)
        XCTAssertEqual(snapshot.pick(point: .init(4, 0), tolerance: 0, layerIDs: [top]).map(\.id), [base.id])
    }

    func testEvenOddRegionHoleAndToleranceUseActualVisibleArea() throws {
        let region = ManufacturingPrimitive(id: id(100), shapes: [.init(contours: [square(5), square(1)], radius: 0)])
        let snapshot = try ManufacturingSnapshot(package: package([region]))
        XCTAssertTrue(snapshot.pick(point: .init(), tolerance: 0.5, layerIDs: [top]).isEmpty)
        XCTAssertEqual(snapshot.pick(point: .init(2, 0), tolerance: 0, layerIDs: [top]).map(\.id), [region.id])
        let nearHole = snapshot.pick(point: .init(0.9, 0), tolerance: 0.2, layerIDs: [top])
        XCTAssertEqual(nearHole.map(\.id), [region.id])
        XCTAssertEqual(try XCTUnwrap(nearHole.first).distance, 0.1, accuracy: 1e-7)
        XCTAssertTrue(snapshot.pick(point: .init(5.2, 5.2), tolerance: 0.25, layerIDs: [top]).isEmpty)
    }

    func testCapsuleAndRoundedPolygonDistanceKeepTheirRadius() throws {
        let capsule = ManufacturingPrimitive(id: id(100), shapes: [.init(contours: [[.init(-2, 0), .init(2, 0)]], radius: 1)])
        let rounded = ManufacturingPrimitive(id: id(101), shapes: [.init(contours: [square(2)], radius: 0.5)])
        let cap = try ManufacturingSnapshot(package: package([capsule]))
        XCTAssertTrue(cap.pick(point: .init(2.8, 0.8), tolerance: 0.1, layerIDs: [top]).isEmpty)
        XCTAssertEqual(cap.pick(point: .init(2.8, 0.8), tolerance: 0.2, layerIDs: [top]).map(\.id), [capsule.id])
        let rect = try ManufacturingSnapshot(package: package([rounded]))
        XCTAssertEqual(rect.pick(point: .init(2.3, 2.3), tolerance: 0, layerIDs: [top]).map(\.id), [rounded.id])
        XCTAssertTrue(rect.pick(point: .init(2.45, 2.45), tolerance: 0.1, layerIDs: [top]).isEmpty)
    }

    func testLayerFilterLeavesPlacementMarkersAndDrillsIndependent() throws {
        let copperTop = ManufacturingPrimitive(id: id(100), shapes: [disk(3)])
        let copperBottom = ManufacturingPrimitive(id: id(101), shapes: [disk(3)])
        let component = ManufacturingComponent(id: id(200), reference: "U1",
            placement: .init(reference: "U1", position: .init(), rotationDegrees: 90, side: .bottom))
        let missingPlacement = ManufacturingComponent(id: id(201), reference: "U2")
        let drill = ManufacturingDrill(id: id(300), position: .init(-1, 0), end: .init(1, 0), diameter: 1, isPlated: true)
        let snapshot = try ManufacturingSnapshot(package: package([copperTop], bottom: [copperBottom],
            components: [component, missingPlacement], drills: [drill]))
        let picks = snapshot.pick(point: .init(), tolerance: 0, layerIDs: [bottom])
        XCTAssertEqual(picks.map(\.kind), [.component, .drill, .primitive])
        XCTAssertEqual(picks.map(\.id), [component.id, drill.id, copperBottom.id])
        XCTAssertEqual(snapshot.pick(point: .init(), tolerance: 0, layerIDs: []).map(\.id), [component.id, drill.id])
        XCTAssertFalse(snapshot.pick(point: .init(0.2, 0), tolerance: 0.1).contains { $0.id == component.id })
        XCTAssertFalse(snapshot.pick(point: .init(), tolerance: 100).contains { $0.id == missingPlacement.id })
    }

    func testOffBoardComponentIsOnlyItsPlacementMarkerAndRemainsSelectable() throws {
        let component = ManufacturingComponent(id: id(200), reference: "J1",
            placement: .init(reference: "J1", position: .init(100, -200), rotationDegrees: 0, side: .top))
        let snapshot = try ManufacturingSnapshot(package: package([], components: [component]))
        XCTAssertEqual(snapshot.pick(point: .init(100, -200), tolerance: 0).map(\.id), [component.id])
        XCTAssertTrue(snapshot.pick(point: .init(101, -200), tolerance: 0.9).isEmpty)
        XCTAssertEqual(snapshot.snapTargets(near: .init(100, -200), radius: 0).map(\.id), [component.id])
    }

    func testSnapVerticesKeepIDsAndExcludeRemovedGeometry() throws {
        let region = ManufacturingPrimitive(id: id(100), shapes: [.init(contours: [square(2)], radius: 0)])
        let clear = ManufacturingPrimitive(id: id(101), shapes: [disk(.init(2, 2), 0.5)], isDark: false)
        let snapshot = try ManufacturingSnapshot(package: package([region, clear]))
        XCTAssertTrue(snapshot.snapTargets(near: .init(2, 2), radius: 0.1, layerIDs: [top]).isEmpty)
        let picks = snapshot.snapTargets(near: .init(-2, -2), radius: 0.1, layerIDs: [top])
        XCTAssertEqual(picks.map(\.id), [region.id])
        XCTAssertEqual(picks.map(\.position), [.init(-2, -2)])
        XCTAssertEqual(picks.map(\.kind), [.vertex])
        XCTAssertTrue(snapshot.snapTargets(near: .init(-2, -2), radius: 0.1, layerIDs: [bottom]).isEmpty)
    }

    func testDeterministicSortAndBoundedOutputSurviveSerialization() throws {
        let primitives = (100..<400).reversed().map { ManufacturingPrimitive(id: id($0), shapes: [disk(1)]) }
        let first = package(primitives)
        let reopened = try JSONDecoder().decode(ManufacturingPackage.self, from: JSONEncoder().encode(first))
        let a = try ManufacturingSnapshot(package: first), b = try ManufacturingSnapshot(package: reopened)
        let hits = a.pick(point: .init(), tolerance: 0, layerIDs: [top])
        XCTAssertEqual(hits.count, 256)
        XCTAssertEqual(hits.map(\.id), (100..<356).map(id))
        XCTAssertEqual(hits, b.pick(point: .init(), tolerance: 0, layerIDs: [top]))
        let snaps = a.snapTargets(near: .init(), radius: 0, layerIDs: [top])
        XCTAssertEqual(snaps.count, 256)
        XCTAssertEqual(snaps.map(\.id), (100..<356).map(id))
        XCTAssertEqual(snaps, b.snapTargets(near: .init(), radius: 0, layerIDs: [top]))
    }

    func testMalformedQueriesReturnEmptyAndMalformedGeometryIsRejected() throws {
        let primitive = ManufacturingPrimitive(id: id(100), shapes: [disk(1)])
        let snapshot = try ManufacturingSnapshot(package: package([primitive]))
        for radius in [-1.0, Double.nan, .infinity, 1_000_001] {
            XCTAssertTrue(snapshot.pick(point: .init(), tolerance: radius).isEmpty)
            XCTAssertTrue(snapshot.snapTargets(near: .init(), radius: radius).isEmpty)
        }
        for point in [PCBPoint(.nan, 0), .init(0, .infinity), .init(1_000_001, 0)] {
            XCTAssertTrue(snapshot.pick(point: point, tolerance: 1).isEmpty)
            XCTAssertTrue(snapshot.snapTargets(near: point, radius: 1).isEmpty)
        }
        let invalid = ManufacturingPrimitive(id: id(100), shapes: [disk(.init(.nan, 0), 1)])
        XCTAssertThrowsError(try ManufacturingSnapshot(package: package([invalid])))
        XCTAssertThrowsError(try ManufacturingSnapshot(package: package([primitive, primitive])))
    }

    func testClippedCornerToleranceIsConservativeRatherThanInventingMaterial() throws {
        // The nearest witnesses on both circles are removed; the only close material
        // is near their intersection. Conservative omission is part of this API.
        let disk = ManufacturingPrimitive(id: id(100), shapes: [self.disk(2)])
        let clear = ManufacturingPrimitive(id: id(101), shapes: [self.disk(.init(1, 0), 2)], isDark: false)
        let snapshot = try ManufacturingSnapshot(package: package([disk, clear]))
        XCTAssertTrue(snapshot.pick(point: .init(0.55, 1.9), tolerance: 0.08, layerIDs: [top]).isEmpty)
        XCTAssertEqual(snapshot.pick(point: .init(-1.5, 0), tolerance: 0, layerIDs: [top]).map(\.id), [disk.id])
    }

    func testConstructionHonorsCancellation() async {
        let fixture = package([])
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ManufacturingSnapshot(package: fixture)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled snapshot construction must not complete")
        } catch is CancellationError {
            // The caller can discard the pending preview without a late index.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
