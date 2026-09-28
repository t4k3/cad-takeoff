import Foundation
import XCTest
@testable import ElectronicsCore

final class ManufacturingInputTests: XCTestCase {
    func testBOMGroupedReferencesQuotesUTF8AndOmittedParts() throws {
        let source = "\u{feff}Designator,Footprint,Quantity,Value,LCSC Part #,DNP\r\n\"C1, C2\",C_0805,2,\"100nF, \\\"low\\\"\",C89258,no\r\nR1,R_0603,1,10k,,yes\r\n"
            .replacingOccurrences(of: "\\\"", with: "\"\"")
        let result = try ManufacturingTables.bom(Data(source.utf8))
        XCTAssertEqual(result.map(\.reference), ["C1", "C2", "R1"])
        XCTAssertEqual(result[0].value, "100nF, \"low\"")
        XCTAssertEqual(result[0].lcscPartNumber, "C89258")
        XCTAssertTrue(result[1].fitted)
        XCTAssertFalse(result[2].fitted)
        XCTAssertNil(result[2].lcscPartNumber)
        XCTAssertEqual(try JSONDecoder().decode([ManufacturingBOMEntry].self, from: JSONEncoder().encode(result)), result)
    }

    func testBOMSemicolonRFCMultilineAndFittedAliases() throws {
        let source = "\r\n\nReferences;Package;Qty;Comment;LCSC Part Number;Fitted;DNP\n\"R1,R2\";R0603;2;\"line 1\nline 2\";c123;true;false\nJ1;Conn;1;Boot;;not fitted;true\n"
        let result = try ManufacturingTables.bom(Data(source.utf8))
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].value, "line 1\nline 2")
        XCTAssertEqual(result[0].lcscPartNumber, "C123")
        XCTAssertFalse(result[2].fitted)
    }

    func testBOMRejectsQuantityMismatchDuplicatesAndUnknownPopulationFlags() {
        for source in [
            "Designator,Footprint,Quantity,Value\n\"R1,R2\",R,1,10k\n",
            "Designator,Footprint,Value\nR1,R,10k\nr1,R,10k\n",
            "Designator,Footprint,Value,DNP\nR1,R,10k,maybe\n",
            "Designator,Footprint,Value,Fitted\nR1,R,10k,\n",
            "Designator,Footprint,Value,DNP,Fitted\nR1,R,10k,true,true\n",
            "Designator,Footprint,Value,LCSC Part #\nR1,R,10k,other123\n"
        ] { XCTAssertThrowsError(try ManufacturingTables.bom(Data(source.utf8)), source) }
    }

    func testCSVRejectsMalformedQuotingHeaderAmbiguityAndWrongWidth() {
        for source in [
            "Designator,Footprint,Value\nR1,R,\"never closed\n",
            "Designator,Footprint,Value\nR1,R,\"closed\"extra\n",
            "Designator,Footprint,Value\nR1,R,un\"quoted\n",
            "Designator,Footprint,Value\nR1,R,10k,extra\n",
            "Designator,Footprint,VALUE,Value\nR1,R,10k,10k\n",
            "Designator,Reference,Footprint,Value\nR1,R1,R,10k\n",
            "Designator,Footprint,Value\n",
            "Designator,Footprint,Value\nR1,,10k\n"
        ] { XCTAssertThrowsError(try ManufacturingTables.bom(Data(source.utf8)), source) }
        XCTAssertThrowsError(try ManufacturingTables.bom(Data([0xff, 0xfe])))
    }

    func testPositionsKeepNegativeSourceCoordinatesAndBottomRotation() throws {
        let source = "Designator,Mid X,Mid Y,Rotation,Layer\nC1,158.3,-96.2,90.0,top\nT1,-12.5 mm,3.25mm,-450,bottom\n"
        let result = try ManufacturingTables.positions(Data(source.utf8))
        XCTAssertEqual(result[0], .init(reference: "C1", position: .init(158.3, -96.2), rotationDegrees: 90, side: .top))
        XCTAssertEqual(result[1], .init(reference: "T1", position: .init(-12.5, 3.25), rotationDegrees: -450, side: .bottom))
        XCTAssertEqual(try JSONDecoder().decode([ManufacturingPlacement].self, from: JSONEncoder().encode(result)), result)
    }

    func testPositionsRejectAmbiguousUnitsSidesAndNonfiniteCoordinates() {
        let header = "Designator,Mid X,Mid Y,Rotation,Layer\n"
        for row in ["R1,1 inch,2,0,top", "R1,nan,2,0,top", "R1,1e999,2,0,top",
                    "R1,1000001,2,0,top", "R1,1,2,inf,top", "R1,1,2,0,middle",
                    "R1,1,2,0,top\nr1,2,3,0,top"] {
            XCTAssertThrowsError(try ManufacturingTables.positions(Data((header + row).utf8)), row)
        }
        XCTAssertThrowsError(try ManufacturingTables.positions(Data("Designator,X,Y,Rotation,Layer,Units\nR1,1,2,0,top,inches".utf8)))
    }

    func testZIPStoredDeflateAndDataDescriptorsAreReadInMemory() throws {
        for method in [UInt16(0), UInt16(8)] {
            for descriptor in [false, true] {
                let archive = zip([.init(name: "board/F_Cu.gbr", content: Data("G04 test*\nM02*\n".utf8), method: method, descriptor: descriptor)])
                let result = try ManufacturingArchive.read(archive)
                XCTAssertEqual(result, [.init(name: "board/F_Cu.gbr", data: Data("G04 test*\nM02*\n".utf8))])
            }
        }
        let unsigned = zip([.init(name: "a.gbr", descriptor: true, descriptorSignature: false)])
        XCTAssertEqual(try ManufacturingArchive.read(unsigned).first?.data, Data("M02*".utf8))
        let empty = zip([.init(name: "empty.txt", content: Data(), method: 8)])
        XCTAssertEqual(try ManufacturingArchive.read(empty).first?.data, Data())
    }

    func testZIPSupportsRealHuffmanDEFLATEStream() throws {
        // Independent raw DEFLATE vector (zlib): "hello hello hello\n".
        let packed: [UInt8] = [0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0xc8, 0x40, 0x90, 0x5c, 0x00]
        let archive = zip([.init(name: "sample.gbr", content: Data("hello hello hello\n".utf8), method: 8, packedOverride: Data(packed))])
        XCTAssertEqual(try ManufacturingArchive.read(archive).first?.data, Data("hello hello hello\n".utf8))
    }

    func testZIPRejectsTraversalSymlinkDuplicateAndCRCFailure() {
        for name in ["../escape.gbr", "/absolute.gbr", "folder/../file.gbr", "folder\\file.gbr", "C:file.gbr", "folder//file.gbr"] {
            XCTAssertThrowsError(try ManufacturingArchive.read(zip([.init(name: name)])), name)
        }
        XCTAssertThrowsError(try ManufacturingArchive.read(zip([.init(name: "a.gbr", mode: 0xa1ff)])))
        XCTAssertThrowsError(try ManufacturingArchive.read(zip([.init(name: "a.gbr"), .init(name: "A.GBR")])))
        var damaged = zip([.init(name: "a.gbr", content: Data("abc".utf8))])
        damaged[30 + "a.gbr".utf8.count] ^= 1
        XCTAssertThrowsError(try ManufacturingArchive.read(damaged))
    }

    func testZIPRejectsSizeLiesEncryptionUnsupportedMethodsAndTruncation() {
        let original = zip([.init(name: "a.gbr", content: Data("abc".utf8))])
        let central = original.count - 22 - 46 - "a.gbr".utf8.count
        for offset in [6, central + 8] {
            var encrypted = original; encrypted[offset] |= 1
            XCTAssertThrowsError(try ManufacturingArchive.read(encrypted))
        }
        var sizeLie = original
        sizeLie[central + 24] = 4
        XCTAssertThrowsError(try ManufacturingArchive.read(sizeLie))
        var bomb = original
        for offset in [central + 24, central + 25, central + 26, central + 27] { bomb[offset] = 0xff }
        XCTAssertThrowsError(try ManufacturingArchive.read(bomb))
        var method = original; method[8] = 99; method[central + 10] = 99
        XCTAssertThrowsError(try ManufacturingArchive.read(method))
        for count in [0, 1, 21, 31, original.count - 1] {
            XCTAssertThrowsError(try ManufacturingArchive.read(Data(original.prefix(count))))
        }
        let extraPacked = Data([1, 3, 0, 0xfc, 0xff, 97, 98, 99, 0])
        XCTAssertThrowsError(try ManufacturingArchive.read(zip([.init(name: "a.gbr", content: Data("abc".utf8), method: 8, packedOverride: extraPacked)])))
    }

    private struct Entry {
        var name: String
        var content = Data("M02*".utf8)
        var method: UInt16 = 0
        var descriptor = false
        var descriptorSignature = true
        var mode: UInt16 = 0x81a4
        var packedOverride: Data?
    }
    private func zip(_ entries: [Entry]) -> Data {
        var output = Data(), central = Data()
        func u16(_ value: UInt16, _ bytes: inout Data) {
            bytes.append(UInt8(truncatingIfNeeded: value)); bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func u32(_ value: UInt32, _ bytes: inout Data) {
            u16(UInt16(truncatingIfNeeded: value), &bytes); u16(UInt16(truncatingIfNeeded: value >> 16), &bytes)
        }
        for entry in entries {
            let name = Data(entry.name.utf8), local = UInt32(output.count), crc = checksum(entry.content)
            let flags: UInt16 = entry.descriptor ? 8 : 0
            var packed = entry.content
            if entry.method == 8 {
                packed = Data([1]); u16(UInt16(entry.content.count), &packed)
                u16(~UInt16(entry.content.count), &packed); packed.append(entry.content)
            }
            if let bytes = entry.packedOverride { packed = bytes }
            u32(0x04034b50, &output); u16(20, &output); u16(flags, &output); u16(entry.method, &output)
            u32(0, &output); u32(entry.descriptor ? 0 : crc, &output)
            u32(entry.descriptor ? 0 : UInt32(packed.count), &output)
            u32(entry.descriptor ? 0 : UInt32(entry.content.count), &output)
            u16(UInt16(name.count), &output); u16(0, &output); output.append(name); output.append(packed)
            if entry.descriptor {
                if entry.descriptorSignature { u32(0x08074b50, &output) }
                u32(crc, &output)
                u32(UInt32(packed.count), &output); u32(UInt32(entry.content.count), &output)
            }
            u32(0x02014b50, &central); u16(0x0314, &central); u16(20, &central)
            u16(flags, &central); u16(entry.method, &central); u32(0, &central); u32(crc, &central)
            u32(UInt32(packed.count), &central); u32(UInt32(entry.content.count), &central)
            u16(UInt16(name.count), &central); u16(0, &central); u16(0, &central)
            u16(0, &central); u16(0, &central); u32(UInt32(entry.mode) << 16, &central)
            u32(local, &central); central.append(name)
        }
        let centralOffset = UInt32(output.count)
        output.append(central); u32(0x06054b50, &output); u16(0, &output); u16(0, &output)
        u16(UInt16(entries.count), &output); u16(UInt16(entries.count), &output)
        u32(UInt32(central.count), &output); u32(centralOffset, &output); u16(0, &output)
        return output
    }
    private func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb8_8320) }
        }
        return crc ^ 0xffff_ffff
    }
}
