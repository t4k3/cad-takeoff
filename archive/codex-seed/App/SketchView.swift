import SwiftUI
import CADCore

/// Orthographic XY preview of the numerically dimensioned sketch.
struct SketchView: View {
    let model: CADModel
    var body: some View {
        Canvas { context, size in
            let depth = model.profile == .circle ? model.width : model.depth
            let scale = min((size.width - 120) / model.width, (size.height - 65) / depth)
            let rect = CGRect(x: (size.width-model.width*scale)/2, y: (size.height-depth*scale)/2,
                              width: model.width*scale, height: depth*scale)
            var axes = Path()
            axes.move(to: .init(x: 0, y: size.height/2)); axes.addLine(to: .init(x: size.width, y: size.height/2))
            axes.move(to: .init(x: size.width/2, y: 0)); axes.addLine(to: .init(x: size.width/2, y: size.height))
            context.stroke(axes, with: .color(.gray.opacity(0.25)), style: .init(lineWidth: 1, dash: [4,4]))
            let shape = model.profile == .circle ? Path(ellipseIn: rect) : Path(rect)
            context.fill(shape, with: .color(.cyan.opacity(0.1)))
            context.stroke(shape, with: .color(.cyan), lineWidth: 2)
            let label = model.profile == .circle ? "Ø \(model.width.formatted()) mm" : "\(model.width.formatted()) × \(model.depth.formatted()) mm"
            context.draw(Text(label).font(.caption.monospacedDigit()), at: .init(x: size.width/2, y: size.height-14))
        }
        .overlay(alignment: .topLeading) { Text("SCHIZZO XY · QUOTE NUMERICHE").font(.caption.bold()).padding() }
        .accessibilityLabel("Schizzo sul piano XY")
    }
}
