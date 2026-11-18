import Darwin
import SwiftUI

/// Published total length, and the sparrow-to-ostrich comparison drawn on the size section.
enum BirdSize {
    struct Anchor: Identifiable {
        var id: String
        var label: String
        var lengthCm: Double
        var glyph: BirdGlyph.Kind
    }

    /// Familiar birds on one scale, smallest to largest.
    /// Lengths are published midpoints: house sparrow 16 cm (typical; range 14–18),
    /// Common / Indian myna 23–26, rock dove 30–35, American crow 40–53, mallard 50–65,
    /// great blue heron head-to-tail 91–137. The ostrich mark is male standing height
    /// 2.1–2.75 m, the figure used for that bird. Every species mark uses total length.
    static let anchors: [Anchor] = [
        Anchor(id: "sparrow", label: "Sparrow", lengthCm: 16, glyph: .sparrow),
        Anchor(id: "myna", label: "Myna", lengthCm: 24.5, glyph: .myna),
        Anchor(id: "pigeon", label: "Pigeon", lengthCm: 32.5, glyph: .pigeon),
        Anchor(id: "crow", label: "Crow", lengthCm: 46.5, glyph: .crow),
        Anchor(id: "duck", label: "Duck", lengthCm: 57.5, glyph: .duck),
        Anchor(id: "heron", label: "Heron", lengthCm: 114, glyph: .heron),
        Anchor(id: "ostrich", label: "Ostrich", lengthCm: 242, glyph: .ostrich),
    ]

    static func hasLength(_ species: Species) -> Bool {
        // Require a printable length line so the list/detail never show an empty "Length" row.
        midpoint(species.lengthCm) != nil && !line(for: species.lengthCm).isEmpty
    }

    /// One wording for every bird that has a length: "Length 14–18 cm" or "Length 16 cm".
    /// Empty string when unknown — callers must hide Size / Length via `hasLength`.
    static func line(for species: Species) -> String {
        line(for: species.lengthCm)
    }

    static func line(for lengthCm: [Double]) -> String {
        let values = lengthCm.filter { $0 > 0 }.sorted()
        guard let low = values.first, let high = values.last else { return "" }
        if abs(high - low) < 0.05 {
            return "Length \(format(low)) cm"
        }
        return "Length \(format(low))–\(format(high)) cm"
    }

    static func comparison(for lengthCm: [Double]) -> String {
        guard let mid = midpoint(lengthCm) else { return "" }
        let sparrow = anchors[0].lengthCm
        let ostrich = anchors[anchors.count - 1].lengthCm
        if mid < sparrow * 0.85 {
            return "Smaller than a sparrow"
        }
        if mid > ostrich * 1.12 {
            return "Larger than an ostrich"
        }
        let nearest = anchors.min { lhs, rhs in
            abs(Darwin.log(lhs.lengthCm / mid)) < abs(Darwin.log(rhs.lengthCm / mid))
        } ?? anchors[0]
        let ratio = mid / nearest.lengthCm
        if (0.85...1.18).contains(ratio) {
            return "About \(nearest.label.lowercased())-sized"
        }
        if let below = anchors.last(where: { $0.lengthCm <= mid }),
           let above = anchors.first(where: { $0.lengthCm >= mid }),
           below.id != above.id {
            return "Between \(article(below.label)) and \(article(above.label))"
        }
        return "About \(nearest.label.lowercased())-sized"
    }

    static func accessibilityText(for lengthCm: [Double]) -> String {
        let spoken = line(for: lengthCm).replacingOccurrences(of: "–", with: " to ")
        let place = comparison(for: lengthCm)
        return "\(spoken). \(place), on a scale from a sparrow to an ostrich."
    }

    /// 0...1 across the evenly spaced anchor pictures. Log-scaled inside each gap
    /// so the mark lines up with the bird it falls between.
    static func unitPosition(cm: Double) -> Double {
        let points = anchors.map(\.lengthCm)
        let count = Double(points.count)
        guard count > 1 else { return 0.5 }
        if cm <= points[0] {
            return 0.5 / count
        }
        if cm >= points[points.count - 1] {
            return (count - 0.5) / count
        }
        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            if cm <= end {
                let span = Darwin.log(end / start)
                let t = span == 0 ? 0 : Darwin.log(cm / start) / span
                return (Double(index) + t + 0.5) / count
            }
        }
        return (count - 0.5) / count
    }

    static func glyphHeight(_ anchor: Anchor) -> CGFloat {
        switch anchor.id {
        case "sparrow": return 18
        case "myna": return 24
        case "pigeon": return 28
        case "crow": return 34
        case "duck": return 38
        case "heron": return 52
        case "ostrich": return 68
        default: return 28
        }
    }

    static func glyphWidth(_ anchor: Anchor) -> CGFloat {
        switch anchor.id {
        case "heron": return 26
        case "ostrich": return 34
        case "duck": return 30
        default: return glyphHeight(anchor) * 0.85
        }
    }

    private static func midpoint(_ lengthCm: [Double]) -> Double? {
        let values = lengthCm.filter { $0 > 0 }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func format(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.05 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.1f", value)
    }

    private static func article(_ label: String) -> String {
        let lower = label.lowercased()
        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
        if let first = lower.first, vowels.contains(first) {
            return "an \(lower)"
        }
        return "a \(lower)"
    }
}

struct BirdSizeScale: View {
    var lengthCm: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(BirdSize.anchors) { anchor in
                    BirdGlyph(kind: anchor.glyph)
                        .fill(GuideColor.green)
                        .frame(width: BirdSize.glyphWidth(anchor), height: BirdSize.glyphHeight(anchor))
                        .frame(maxWidth: .infinity, alignment: .bottom)
                        .accessibilityHidden(true)
                }
            }
            Rectangle()
                .fill(GuideColor.line)
                .frame(height: 1)
                .accessibilityHidden(true)
            HStack(spacing: 0) {
                ForEach(BirdSize.anchors) { anchor in
                    Text(anchor.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(GuideColor.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)

            marker
                .accessibilityHidden(true)

            Text(BirdSize.comparison(for: lengthCm))
                .font(.subheadline)
                .foregroundStyle(GuideColor.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BirdSize.accessibilityText(for: lengthCm))
    }

    private var marker: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let values = lengthCm.filter { $0 > 0 }.sorted()
            let low = values.first ?? 0
            let high = values.last ?? low
            let start = BirdSize.unitPosition(cm: low) * width
            let end = BirdSize.unitPosition(cm: high) * width
            let mid = BirdSize.unitPosition(cm: (low + high) / 2) * width
            let barWidth = max(8, abs(end - start))
            let barLeft = min(min(start, end), max(0, width - barWidth))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(GuideColor.line)
                    .frame(height: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                Capsule()
                    .fill(GuideColor.rust.opacity(0.9))
                    .frame(width: barWidth, height: 5)
                    .offset(x: barLeft)
                    .frame(maxHeight: .infinity, alignment: .center)
                Circle()
                    .fill(GuideColor.rust)
                    .frame(width: 11, height: 11)
                    .offset(x: min(max(0, mid - 5.5), max(0, width - 11)))
            }
        }
        .frame(height: 14)
    }
}

struct BirdGlyph: Shape {
    enum Kind {
        case sparrow, myna, pigeon, crow, duck, heron, ostrich
    }

    var kind: Kind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        func ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat) {
            path.addEllipse(in: CGRect(
                x: rect.minX + (cx - rx) * rect.width,
                y: rect.minY + (cy - ry) * rect.height,
                width: rx * 2 * rect.width,
                height: ry * 2 * rect.height
            ))
        }
        func poly(_ points: [(CGFloat, CGFloat)]) {
            guard let first = points.first else { return }
            path.move(to: pt(first.0, first.1))
            for point in points.dropFirst() {
                path.addLine(to: pt(point.0, point.1))
            }
            path.closeSubpath()
        }

        switch kind {
        case .sparrow, .myna, .crow:
            let bulk: CGFloat = kind == .crow ? 1.12 : (kind == .myna ? 1.05 : 1)
            poly([(0.04, 0.46), (0.32, 0.40), (0.30, 0.58)])
            ellipse(cx: 0.42, cy: 0.50, rx: 0.20 * bulk, ry: 0.15 * bulk)
            ellipse(cx: 0.64, cy: 0.40, rx: 0.11 * bulk, ry: 0.11 * bulk)
            poly([(0.72, 0.38), (0.96, 0.42), (0.72, 0.46)])
            poly([(0.36, 0.62), (0.40, 0.62), (0.38, 0.96), (0.34, 0.96)])
            poly([(0.48, 0.62), (0.52, 0.62), (0.54, 0.96), (0.50, 0.96)])
        case .pigeon:
            poly([(0.10, 0.48), (0.30, 0.42), (0.28, 0.56)])
            ellipse(cx: 0.46, cy: 0.52, rx: 0.24, ry: 0.18)
            ellipse(cx: 0.68, cy: 0.40, rx: 0.10, ry: 0.10)
            poly([(0.76, 0.38), (0.90, 0.41), (0.76, 0.45)])
            poly([(0.40, 0.66), (0.44, 0.66), (0.42, 0.96), (0.38, 0.96)])
            poly([(0.54, 0.66), (0.58, 0.66), (0.60, 0.96), (0.56, 0.96)])
        case .duck:
            poly([(0.08, 0.58), (0.22, 0.46), (0.24, 0.62)])
            ellipse(cx: 0.46, cy: 0.58, rx: 0.26, ry: 0.16)
            ellipse(cx: 0.70, cy: 0.46, rx: 0.11, ry: 0.11)
            poly([(0.78, 0.44), (0.98, 0.48), (0.98, 0.54), (0.78, 0.52)])
            poly([(0.40, 0.70), (0.44, 0.70), (0.42, 0.96), (0.38, 0.96)])
            poly([(0.56, 0.70), (0.60, 0.70), (0.62, 0.96), (0.58, 0.96)])
        case .heron:
            poly([(0.34, 0.58), (0.38, 0.58), (0.30, 0.98), (0.26, 0.98)])
            poly([(0.48, 0.58), (0.52, 0.58), (0.58, 0.98), (0.54, 0.98)])
            ellipse(cx: 0.42, cy: 0.50, rx: 0.16, ry: 0.12)
            poly([(0.50, 0.46), (0.58, 0.28), (0.66, 0.22), (0.62, 0.16), (0.52, 0.30), (0.46, 0.44)])
            ellipse(cx: 0.66, cy: 0.16, rx: 0.07, ry: 0.06)
            poly([(0.72, 0.14), (0.98, 0.17), (0.72, 0.20)])
        case .ostrich:
            poly([(0.30, 0.55), (0.36, 0.55), (0.28, 0.98), (0.22, 0.98)])
            poly([(0.46, 0.55), (0.52, 0.55), (0.58, 0.98), (0.52, 0.98)])
            ellipse(cx: 0.40, cy: 0.48, rx: 0.20, ry: 0.14)
            poly([(0.08, 0.50), (0.24, 0.42), (0.22, 0.56)])
            poly([(0.52, 0.42), (0.62, 0.18), (0.70, 0.10), (0.64, 0.06), (0.56, 0.16), (0.48, 0.40)])
            ellipse(cx: 0.70, cy: 0.08, rx: 0.07, ry: 0.055)
            poly([(0.76, 0.07), (0.96, 0.10), (0.76, 0.13)])
        }
        return path
    }
}
