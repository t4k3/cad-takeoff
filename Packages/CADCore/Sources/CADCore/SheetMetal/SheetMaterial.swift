import Foundation

// Sheet materials and press-brake bending rules (T79). Values are typical workshop figures for
// AIR BENDING on a press brake with standard V dies — a sound starting point, not a calibration:
// the shop's own tooling table always wins (the part can override radius and K).
//
// - V die: about 8×t up to 3 mm, 10×t up to 10 mm, 12×t above, rounded to a standard opening.
// - Inside radius in air bending ≈ a fraction of the V opening (≈16% mild steel, ≈21% stainless,
//   ≈15% aluminium), never below the material's minimum r/t (e.g. 6082-T6 cracks below ~3t).
// - K-factor from DIN 6935: correction k = 0.65 + 0.5·log10(r/t) (max 1), neutral axis K = k/2.
// - Minimum flange (outside length at 90°) ≈ 0.7·V + t/2: the flange must rest on both die shoulders.

public struct SheetMaterial: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// g/cm³.
    public let density: Double
    /// Commercial thicknesses stocked in mm.
    public let thicknesses: [Double]
    /// Inside radius as a fraction of the V-die opening (air bending).
    public let radiusOverV: Double
    /// Smallest inside radius the material takes without cracking, as a multiple of t.
    public let minimumRadiusRatio: Double
    /// Short workshop note shown next to the choice.
    public let note: String

    public static let all: [SheetMaterial] = [
        .init(id: "dc01", name: "Acciaio DC01 (laminato a freddo)", density: 7.85,
              thicknesses: [0.5, 0.6, 0.8, 1, 1.2, 1.5, 2, 2.5, 3], radiusOverV: 0.16, minimumRadiusRatio: 0.5,
              note: "Lamiera nera da piega, ottima formabilità"),
        .init(id: "dx51d", name: "Acciaio zincato DX51D+Z", density: 7.85,
              thicknesses: [0.5, 0.6, 0.8, 1, 1.2, 1.5, 2, 2.5, 3], radiusOverV: 0.16, minimumRadiusRatio: 1,
              note: "Zincato a caldo: raggi ≥ t per non crepare lo zinco"),
        .init(id: "s235", name: "Acciaio S235JR (laminato a caldo)", density: 7.85,
              thicknesses: [2, 3, 4, 5, 6, 8, 10], radiusOverV: 0.16, minimumRadiusRatio: 1,
              note: "Spessori da carpenteria"),
        .init(id: "aisi304", name: "Inox AISI 304", density: 7.93,
              thicknesses: [0.5, 0.6, 0.8, 1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6], radiusOverV: 0.21, minimumRadiusRatio: 1,
              note: "Più ritorno elastico: raggi e forze maggiori"),
        .init(id: "aisi316", name: "Inox AISI 316", density: 8.0,
              thicknesses: [0.8, 1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6], radiusOverV: 0.21, minimumRadiusRatio: 1,
              note: "Inox per ambienti aggressivi, piega come il 304"),
        .init(id: "al5754", name: "Alluminio 5754 H111", density: 2.66,
              thicknesses: [0.5, 0.8, 1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6], radiusOverV: 0.15, minimumRadiusRatio: 1,
              note: "La lega di alluminio da piega"),
        .init(id: "al6082", name: "Alluminio 6082 T6", density: 2.70,
              thicknesses: [1, 1.5, 2, 3, 4, 5, 6], radiusOverV: 0.15, minimumRadiusRatio: 3,
              note: "Stato T6 duro: piega con raggio ≥ 3t, meglio 5754 se va piegato"),
        .init(id: "cuzn37", name: "Ottone CuZn37", density: 8.44,
              thicknesses: [0.5, 0.8, 1, 1.5, 2, 3], radiusOverV: 0.14, minimumRadiusRatio: 0.5,
              note: "Ottone da deformazione a freddo"),
        .init(id: "cu", name: "Rame Cu-ETP", density: 8.94,
              thicknesses: [0.5, 0.8, 1, 1.5, 2, 3], radiusOverV: 0.13, minimumRadiusRatio: 0.5,
              note: "Molto duttile"),
    ]

    public static func named(_ id: String) -> SheetMaterial? { all.first { $0.id == id } }

    /// Standard V-die openings (mm).
    public static let vDies: [Double] = [4, 6, 8, 10, 12, 16, 20, 24, 30, 35, 40, 50, 60, 80, 100, 120]

    public func vDie(thickness t: Double) -> Double {
        let target = t <= 3 ? 8 * t : (t <= 10 ? 10 * t : 12 * t)
        let usable = Self.vDies.filter { $0 >= 6 * t - 1e-9 }
        return usable.min { abs($0 - target) < abs($1 - target) } ?? max(target, Self.vDies.last!)
    }

    public func insideRadius(thickness t: Double) -> Double {
        let r = max(radiusOverV * vDie(thickness: t), minimumRadiusRatio * t)
        return (r * 10).rounded(.up) / 10
    }

    /// Neutral-axis K-factor from DIN 6935 for a given inside radius.
    public static func kFactor(insideRadius r: Double, thickness t: Double) -> Double {
        guard r > 0, t > 0 else { return 0.33 }
        let k = min(1, 0.65 + 0.5 * log10(r / t))
        return max(0.2, min(0.5, k / 2))
    }

    /// Shortest flange the press brake can bend (outside length at 90°).
    public func minimumFlange(thickness t: Double) -> Double {
        ((0.7 * vDie(thickness: t) + t / 2) * 2).rounded(.up) / 2
    }
}
