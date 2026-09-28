import Foundation
import XCTest
@testable import ElectronicsCore

final class ManufacturingPackageCatalogTests: XCTestCase {
    private func component(_ footprint: String?, reference: String = "X1", value: String? = nil,
                           lcsc: String? = nil) -> ManufacturingComponent {
        .init(id: UUID(uuidString: "CA0B355A-DDB0-4A31-9A18-7C40AD36F2CA")!, reference: reference,
              value: value, footprint: footprint, lcscPartNumber: lcsc)
    }

    func testEveryPartIsFiniteClosedConnectedAndOutwardCCW() throws {
        XCTAssertEqual(ManufacturingPackageCatalog.models.count, 15)
        for model in ManufacturingPackageCatalog.models {
            XCTAssertFalse(model.parts.isEmpty, model.key)
            XCTAssertEqual(Set(model.parts.map(\.id)).count, model.parts.count, model.key)
            for part in model.parts {
                let context = "\(model.key)/\(part.id)"
                XCTAssertTrue(part.vertices.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, context)
                XCTAssertEqual(part.indices.count % 3, 0, context)
                XCTAssertTrue(part.indices.allSatisfy { part.vertices.indices.contains($0) }, context)
                guard part.indices.allSatisfy({ part.vertices.indices.contains($0) }) else { continue }
                let center = part.vertices.reduce(PCBPoint3()) { .init($0.x+$1.x,$0.y+$1.y,$0.z+$1.z) }
                let centroid = PCBPoint3(center.x/Double(part.vertices.count),center.y/Double(part.vertices.count),center.z/Double(part.vertices.count))
                var edges: [String: (count: Int, balance: Int)] = [:]
                var neighbors: [Int: Set<Int>] = [:]
                for index in stride(from: 0, to: part.indices.count, by: 3) {
                    let ids = Array(part.indices[index..<(index+3)])
                    let a = part.vertices[ids[0]], b = part.vertices[ids[1]], c = part.vertices[ids[2]]
                    let normal = cross(subtract(b,a),subtract(c,a))
                    XCTAssertGreaterThan(dot(normal,normal), 1e-20, context)
                    let midpoint = PCBPoint3((a.x+b.x+c.x)/3,(a.y+b.y+c.y)/3,(a.z+b.z+c.z)/3)
                    XCTAssertGreaterThan(dot(normal,subtract(midpoint,centroid)), 1e-12, context)
                    for k in 0..<3 {
                        let first = ids[k], second = ids[(k+1)%3]
                        let key = "\(min(first,second))/\(max(first,second))"
                        let previous = edges[key] ?? (0,0)
                        edges[key] = (previous.count+1,previous.balance+(first < second ? 1 : -1))
                        neighbors[first, default: []].insert(second); neighbors[second, default: []].insert(first)
                    }
                }
                XCTAssertTrue(edges.values.allSatisfy { $0.count == 2 && $0.balance == 0 }, context)
                XCTAssertEqual(part.vertices.count - edges.count + part.indices.count/3, 2, context)
                XCTAssertGreaterThan(volume(part), 1e-10, context)
                var pending = [0], visited: Set<Int> = []
                while let vertex = pending.popLast() {
                    if visited.insert(vertex).inserted { pending.append(contentsOf: neighbors[vertex] ?? []) }
                }
                XCTAssertEqual(visited.count, part.vertices.count, context)
            }
        }
    }

    func testVersionedLookupAndSerializationAreDeterministic() throws {
        let models = ManufacturingPackageCatalog.models
        XCTAssertEqual(models, ManufacturingPackageCatalog.models)
        XCTAssertEqual(Set(models.map(\.key)).count, models.count)
        for model in models {
            XCTAssertTrue(model.key.hasSuffix(".v1"))
            XCTAssertEqual(ManufacturingPackageCatalog.model(key: model.key), model)
            XCTAssertEqual(model.quality, .approximate)
            XCTAssertTrue(model.source.contains("non verificat"), model.key)
            XCTAssertTrue(model.source.contains("CPL"), model.key)
            XCTAssertEqual(try JSONDecoder().decode(ManufacturingPackageModel.self, from: JSONEncoder().encode(model)), model)
        }
        XCTAssertNil(ManufacturingPackageCatalog.model(key: "ftk.r0805.v2"))
        XCTAssertNil(ManufacturingPackageCatalog.model(key: "R_0805"))
    }

    func testWholeFootprintResolutionAndNoSupplierOrValueGuessing() throws {
        let exact: [(String,String)] = [("R0805","ftk.r0805.v1"), ("C0805","ftk.c0805.v1"),
            ("R_0805","ftk.r0805.v1"), ("C_0805","ftk.c0805.v1"),
            ("R_1210","ftk.r1210.v1"), ("C_1210","ftk.c1210.v1"),
            ("CP_Elec_6.3x7.7","ftk.cp-elec-6.3x7.7.v1"), ("SOT-23","ftk.sot23-3.v1"),
            ("SOT-23-3","ftk.sot23-3.v1"), ("SOT-23-6","ftk.sot23-6.v1"),
            ("D_SOD-923","ftk.sod923.v1"), ("D_SOD-323","ftk.sod323.v1"), ("D_SOD-123","ftk.sod123.v1"),
            ("D_Zener_DO-214AC-2","ftk.sma.v1"), ("PinHeader_1x02_P2.54mm_Vertical","ftk.pinheader-1x02-p2.54.v1"),
            ("PinHeader_1x03_P2.54mm_Vertical","ftk.pinheader-1x03-p2.54.v1"),
            ("PinHeader_1x04_P2.54mm_Vertical","ftk.pinheader-1x04-p2.54.v1"),
            ("PinHeader_2x03_P2.54mm_Vertical","ftk.pinheader-2x03-p2.54.v1")]
        for (footprint,key) in exact {
            XCTAssertEqual(ManufacturingPackageCatalog.suggestedModel(for: component(footprint))?.key, key)
            XCTAssertEqual(ManufacturingPackageCatalog.suggestedModel(for: component("Library:"+footprint.lowercased()))?.key, key)
        }
        for unknown in ["", "0805", "DO-214AC_SMB", "SMA_SMB", "LM1117", "C_0805_REV_UNKNOWN", "D_SOD-123F", "SOT-23-5", "PinHeader_1x04_P2.54mm_Horizontal", "PinHeader_1x04_P2.54mm_Vertical_SMD_Pin1Left"] {
            XCTAssertNil(ManufacturingPackageCatalog.suggestedModel(for: component(unknown, value: "SOT-23", lcsc: "C10429")), unknown)
        }
        XCTAssertNil(ManufacturingPackageCatalog.suggestedModel(for: component(nil, value: "R_0805", lcsc: "C115309")))
    }

    func testChipDimensionsAndNonOverlappingTerminalVolumes() throws {
        let resistor = try XCTUnwrap(ManufacturingPackageCatalog.model(key: "ftk.r0805.v1"))
        let capacitor = try XCTUnwrap(ManufacturingPackageCatalog.model(key: "ftk.c1210.v1"))
        let r = bounds(resistor.parts.flatMap(\.vertices)), c = bounds(capacitor.parts.flatMap(\.vertices))
        XCTAssertEqual(r.0, .init(-1,-0.625,0))
        XCTAssertEqual(r.1, .init(1,0.625,0.5))
        XCTAssertEqual(c.0, .init(-1.6,-1.25,0))
        XCTAssertEqual(c.1, .init(1.6,1.25,2))
        XCTAssertEqual(resistor.parts.reduce(0) { $0 + volume($1) }, 2*1.25*0.5, accuracy: 1e-12)
        XCTAssertEqual(capacitor.parts.reduce(0) { $0 + volume($1) }, 3.2*2.5*2, accuracy: 1e-12)
        XCTAssertEqual(resistor.parts.filter { $0.material == .metal }.count, 2)
        XCTAssertNil(resistor.pinOne, "A nonpolar resistor must not imply a pin-1 orientation.")
        XCTAssertNil(capacitor.pinOne)
        for i in resistor.parts.indices { for j in resistor.parts.indices where j > i {
            let a = bounds(resistor.parts[i].vertices), b = bounds(resistor.parts[j].vertices)
            let overlaps = min(a.1.x,b.1.x)-max(a.0.x,b.0.x) > 1e-10 && min(a.1.y,b.1.y)-max(a.0.y,b.0.y) > 1e-10 && min(a.1.z,b.1.z)-max(a.0.z,b.0.z) > 1e-10
            XCTAssertFalse(overlaps)
        } }
    }

    func testElectrolyticSectorVolumesFormOneCanWithoutDuplicatedStripe() throws {
        let model = try XCTUnwrap(ManufacturingPackageCatalog.model(key: "ftk.cp-elec-6.3x7.7.v1"))
        let can = model.parts.filter { ["can-a","can-b","negative-stripe"].contains($0.id) }
        XCTAssertEqual(can.count, 3)
        let actual = can.reduce(0) { $0 + volume($1) }
        let polygonArea = 48*0.5*3.15*3.15*sin(2*Double.pi/48)
        XCTAssertEqual(actual, polygonArea*(7.7-0.4), accuracy: 1e-10)
        XCTAssertLessThan(abs(actual / (.pi*3.15*3.15*7.3) - 1), 0.003)
        XCTAssertEqual(model.pinOne, .init(2.35,0,0.1))
        XCTAssertEqual(bounds(can.flatMap(\.vertices)).1.z, 7.7, accuracy: 1e-12)
    }

    func testHeaderIsCenteredWithTruePitchAndSeparateThroughHoleTails() throws {
        let model = try XCTUnwrap(ManufacturingPackageCatalog.model(key: "ftk.pinheader-2x03-p2.54.v1"))
        let body = try XCTUnwrap(model.parts.first { $0.id == "insulator" })
        let b = bounds(body.vertices)
        XCTAssertEqual(b.0.x, -2.54, accuracy: 1e-12)
        XCTAssertEqual(b.1.x, 2.54, accuracy: 1e-12)
        XCTAssertEqual(b.0.y, -3.81, accuracy: 1e-12)
        XCTAssertEqual(b.1.y, 3.81, accuracy: 1e-12)
        XCTAssertEqual(model.pinOne, .init(-1.27,2.54,2.5))
        let metal = model.parts.filter { $0.material == .metal }
        XCTAssertEqual(metal.count, 12)
        let all = bounds(metal.flatMap(\.vertices))
        XCTAssertEqual(all.0.z, -3, accuracy: 1e-12)
        XCTAssertEqual(all.1.z, 8.5, accuracy: 1e-12)
        for part in metal {
            let extent = bounds(part.vertices)
            XCTAssertTrue(extent.1.z <= 0 || extent.0.z >= 2.5, "Hidden metal inside plastic must not duplicate its volume.")
        }
    }

    func testSOTThreeAndSixTerminalsHaveDifferentGeometryAndWitnesses() throws {
        for count in [3,6] {
            let model = try XCTUnwrap(ManufacturingPackageCatalog.model(key: "ftk.sot23-\(count).v1"))
            XCTAssertEqual(model.parts.filter { $0.material == .metal }.count, count)
            let pin = try XCTUnwrap(model.pinOne)
            XCTAssertLessThan(pin.x, 0)
            XCTAssertEqual(pin.y, 0.95, accuracy: 1e-12)
            XCTAssertEqual(model.parts.filter { $0.material == .polarity }.count, 1)
        }
    }

    private func bounds(_ points: [PCBPoint3]) -> (PCBPoint3,PCBPoint3) {
        (.init(points.map(\.x).min()!,points.map(\.y).min()!,points.map(\.z).min()!),
         .init(points.map(\.x).max()!,points.map(\.y).max()!,points.map(\.z).max()!))
    }
    private func subtract(_ a: PCBPoint3, _ b: PCBPoint3) -> PCBPoint3 { .init(a.x-b.x,a.y-b.y,a.z-b.z) }
    private func cross(_ a: PCBPoint3, _ b: PCBPoint3) -> PCBPoint3 { .init(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x) }
    private func dot(_ a: PCBPoint3, _ b: PCBPoint3) -> Double { a.x*b.x+a.y*b.y+a.z*b.z }
    private func volume(_ part: ManufacturingAssemblyPart) -> Double {
        stride(from: 0, to: part.indices.count, by: 3).reduce(0) { value, i in
            value + dot(part.vertices[part.indices[i]],cross(part.vertices[part.indices[i+1]],part.vertices[part.indices[i+2]]))/6
        }
    }
}
