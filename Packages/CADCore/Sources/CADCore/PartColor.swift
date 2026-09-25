import Foundation

/// Opaque, 8-bit sRGB design colour. It is not a printer/AMS slot or a material recipe.
public struct PartColor: Hashable, Codable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red; self.green = green; self.blue = blue
    }

    public init?(hex: String) {
        let bytes = Array(hex.utf8)
        guard bytes.count == 7, bytes[0] == 35,
              bytes.dropFirst().allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: UInt8((value >> 16) & 255), green: UInt8((value >> 8) & 255), blue: UInt8(value & 255))
    }

    public var hex: String { String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue)) }
    public static let defaultColor = PartColor(red: 166, green: 178, blue: 195)
}
