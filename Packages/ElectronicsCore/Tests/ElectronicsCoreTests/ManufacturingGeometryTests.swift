import Foundation
import XCTest
@testable import ElectronicsCore

final class ManufacturingGeometryTests: XCTestCase {
    private let header = "%FSLAX46Y46*%%MOMM*%%LPD*%"
    private func gerber(_ body: String, name: String = "test.gtl", prefix: String? = nil) throws -> ManufacturingLayer {
        let value = try GerberReader.read(Data(((prefix ?? header) + body + "M02*").utf8), name: name)
        return try XCTUnwrap(value)
    }
    private func drill(_ body: String, units: String = "METRIC", name: String = "board-PTH.drl") throws -> [ManufacturingDrill] {
        try ExcellonReader.read(Data(("M48\n\(units)\nT1C0.8\n%\nG90\nG05\nT1\n" + body + "\nM30\n").utf8), name: name)
    }

    func testModalCoordinatesAperturesAndStableIDs() throws {
        let body = "%ADD10C,2*%%ADD11R,4X2*%%ADD12O,4X2*%D10*X10000000Y-20000000D03*X20000000D03*D11*D03*D12*X30000000D03*"
        let layer = try gerber(body), again = try gerber(body)
        XCTAssertEqual(layer, again)
        XCTAssertEqual(layer.kind, .topCopper)
        XCTAssertEqual(layer.primitives.count, 4)
        XCTAssertEqual(layer.primitives[0].shapes[0].contours, [[.init(10,-20)]])
        XCTAssertEqual(layer.primitives[0].shapes[0].radius, 1)
        XCTAssertEqual(layer.primitives[2].shapes[0].contours, [[.init(18,-21), .init(22,-21), .init(22,-19), .init(18,-19)]])
        XCTAssertEqual(layer.primitives[3].shapes[0].contours, [[.init(29,-20), .init(31,-20)]])
        XCTAssertEqual(Set(layer.primitives.map(\.id)).count, 4)
        XCTAssertEqual(try JSONDecoder().decode(ManufacturingLayer.self, from: JSONEncoder().encode(layer)), layer)
    }

    func testImperialAndTrailingZeroCoordinateFormats() throws {
        let inch = try gerber("%ADD10C,0.1*%D10*X10000Y-20000D03*", prefix: "%FSLAX24Y24*%%MOIN*%")
        XCTAssertEqual(inch.primitives[0].shapes[0].contours[0][0].x, 25.4, accuracy: 1e-12)
        XCTAssertEqual(inch.primitives[0].shapes[0].radius, 1.27, accuracy: 1e-12)
        let trailing = try gerber("%ADD10C,1*%D10*X12Y-3D03*", prefix: "%FSTAX24Y24*%%MOMM*%")
        XCTAssertEqual(trailing.primitives[0].shapes[0].contours[0][0], .init(12,-30))
    }

    func testClearHoleIsLocalAndLayerPolarityIsIndependent() throws {
        let layer = try gerber("%ADD10C,4X2*%D10*X0Y0D03*%LPC*%X5000000Y0D03*")
        XCTAssertTrue(layer.primitives[0].isDark)
        XCTAssertFalse(layer.primitives[1].isDark)
        for primitive in layer.primitives {
            XCTAssertEqual(primitive.shapes.map(\.isDark), [true,false])
            XCTAssertEqual(primitive.shapes.map(\.radius), [2,1])
        }
        let mask = try gerber("%TF.FileFunction,Soldermask,Bot*%%TF.FilePolarity,Negative*%%ADD10C,1*%D10*X0Y0D03*", name: "unknown.gbr")
        XCTAssertEqual(mask.kind, .bottomMask)
        XCTAssertTrue(mask.primitives[0].isDark, "Negative solder mask describes openings, no complement of an unbounded plane.")
    }

    func testMacroArithmeticRotationAndFlatVectorEnds() throws {
        let macro = "%AMTest*$2=($1+1)/2*1,1,$2,0,0*20,1,1,-2,0,2,0,90*4,0,4,-0.1,-0.1,0.1,-0.1,0.1,0.1,-0.1,0.1,-0.1,-0.1,0*%"
        let layer = try gerber(macro + "%ADD10Test,3*%D10*X10000000Y20000000D03*")
        let shapes = layer.primitives[0].shapes
        XCTAssertEqual(shapes.count, 3)
        XCTAssertEqual(shapes[0].radius, 1)
        XCTAssertEqual(shapes[1].radius, 0, "Macro vector lines have flat, not round, ends.")
        let points = shapes[1].contours[0]
        XCTAssertEqual(points.map(\.x).min()!, 9.5, accuracy: 1e-10)
        XCTAssertEqual(points.map(\.x).max()!, 10.5, accuracy: 1e-10)
        XCTAssertEqual(points.map(\.y).min()!, 18, accuracy: 1e-10)
        XCTAssertEqual(points.map(\.y).max()!, 22, accuracy: 1e-10)
        XCTAssertFalse(shapes[2].isDark)
    }

    func testNestedRegionContoursUnionInsteadOfCreatingAnUnrequestedHole() throws {
        let layer = try gerber("G36*X0Y0D02*X10000000Y0D01*X10000000Y10000000D01*X0Y10000000D01*X0Y0D01*X2000000Y2000000D02*X8000000Y2000000D01*X8000000Y8000000D01*X2000000Y8000000D01*X2000000Y2000000D01*G37*")
        XCTAssertEqual(layer.primitives.count, 1)
        XCTAssertEqual(layer.primitives[0].shapes.count, 2)
        XCTAssertTrue(layer.primitives[0].shapes.allSatisfy(\.isDark))
        XCTAssertTrue(layer.primitives[0].shapes.allSatisfy { $0.contours.count == 1 })
        XCTAssertEqual(layer.primitives[0].shapes[0].radius, 0)
    }

    func testQuarterAndFullCircleArcsRespectSagBudget() throws {
        let layer = try gerber("%ADD10C,0.2*%D10*X10000000Y0D02*G75*G03X0Y10000000I-10000000J0D01*G02X0Y10000000I0J-10000000D01*")
        XCTAssertEqual(layer.primitives.count, 2)
        let first = layer.primitives[0].shapes, circle = layer.primitives[1].shapes
        XCTAssertEqual(first.first?.contours.first?.first, .init(10,0))
        XCTAssertEqual(first.last?.contours.first?.last, .init(0,10))
        XCTAssertEqual(circle.first?.contours.first?.first, circle.last?.contours.first?.last)
        for shape in first + circle {
            let p = shape.contours[0], midpoint = PCBPoint((p[0].x+p[1].x)/2,(p[0].y+p[1].y)/2)
            XCTAssertLessThanOrEqual(10-hypot(midpoint.x,midpoint.y), 0.01 + 1e-10)
        }
    }

    func testX2ObjectAttributesAndDeletion() throws {
        let layer = try gerber("G04 #@! TF.FileFunction,Copper,L2,Bot*%ADD10C,1*%D10*G04 #@! TO.P,R1,2*%TO.N,Net-\\u0041*%X0Y0D03*%TD.P*%%TO.C,R2*%X1000000Y0D03*%TD*%X2000000Y0D03*")
        XCTAssertEqual(layer.kind, .bottomCopper)
        XCTAssertEqual(layer.primitives[0].componentReference, "R1")
        XCTAssertEqual(layer.primitives[0].pinNumber, "2")
        XCTAssertEqual(layer.primitives[0].netName, "Net-A")
        XCTAssertEqual(layer.primitives[1].componentReference, "R2")
        XCTAssertNil(layer.primitives[1].pinNumber)
        XCTAssertNil(layer.primitives[2].netName)
    }

    func testUnknownOrUnsupportedFilesDoNotBecomePartialSuccessfulLayers() throws {
        let invalid = ["%SRX2Y2I10J10*%", "%AB D10*%", "%LMX*%", "%LR90*%", "%LS2*%", "G91*", "G74*", "%ADD10C,-1*%", "%ADD10C,1X2*%", "%AMBad*6,1,2,3*%%ADD10Bad*%", "G36*X0Y0D02*X100Y0D01*G37*", "%ADD10R,1X1*%D10*X0Y0D02*X1000000D01*", "%TO.N,NetA,NetB*%"]
        for body in invalid { XCTAssertThrowsError(try gerber(body), body) }
        XCTAssertThrowsError(try gerber("", name: "unknown.gbr"))
        XCTAssertThrowsError(try gerber("%TF.FileFunction,Copper,L2,Inr*%"))
        XCTAssertThrowsError(try gerber("%TF.FilePolarity,Negative*%"))
        XCTAssertThrowsError(try GerberReader.read(Data((header + "%ADD10C,1*%").utf8), name: "test.gtl"))
        XCTAssertNil(try GerberReader.read(Data((header + "%TF.FileFunction,Drillmap*%M02*").utf8), name: "map.gbr"))
    }

    func testDrillsSlotsUnitsAndPlating() throws {
        let result = try drill("X1.0Y-2.0\nX3.0\nX4.0Y5.0G85X6.0Y5.0")
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].position, .init(1,-2))
        XCTAssertEqual(result[1].position, .init(3,-2))
        XCTAssertEqual(result[2].end, .init(6,5))
        XCTAssertTrue(result.allSatisfy(\.isPlated))
        XCTAssertEqual(result, try drill("X1.0Y-2.0\nX3.0\nX4.0Y5.0G85X6.0Y5.0"))
        let inch = try drill("X1.0Y2.0", units: "INCH", name: "board-NPTH.drl")
        XCTAssertFalse(inch[0].isPlated)
        XCTAssertEqual(inch[0].diameter, 20.32, accuracy: 1e-12)
        XCTAssertEqual(inch[0].position, .init(25.4,50.8))
        let slot = try drill("G00X1.0Y2.0\nM15\nG01X3.0Y4.0\nM16\nG05\nX5.0Y6.0")
        XCTAssertEqual(slot.count, 2)
        XCTAssertEqual(slot[0].end, .init(3,4))
        XCTAssertNil(slot[1].end)
    }

    func testDrillAttributesAndInvalidOrAmbiguousFormats() throws {
        let file = "M48\n; #@! TF.FileFunction,NonPlated,1,2,NPTH\nMETRIC\nT1C1.0\n%\nT1\nX1.0Y2.0\nM30\n"
        let result = try ExcellonReader.read(Data(file.utf8), name: "holes.drl")
        XCTAssertFalse(result[0].isPlated)
        for body in ["X1000Y2000", "G91\nX1.0Y2.0", "R3X1.0Y2.0", "G02X1.0Y2.0I1.0J0", "X1.0Y2.0\nT99", "X1.0Y2.0G85X1.0Y2.0"] {
            XCTAssertThrowsError(try drill(body), body)
        }
        XCTAssertThrowsError(try drill("X1.0Y2.0", name: "ambiguous.drl"))
        XCTAssertThrowsError(try drill("X1.0Y2.0", units: "METRIC,TZ,000.000"))
    }

    func testCancellationStopsBeforeReturningGeometry() async throws {
        let input = Data((header + "%ADD10C,1*%D10*X0Y0D03*M02*").utf8)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try GerberReader.read(input, name: "test.gtl")
        }
        do { _ = try await task.value; XCTFail("Cancellation must throw") }
        catch is CancellationError { }
    }
}
