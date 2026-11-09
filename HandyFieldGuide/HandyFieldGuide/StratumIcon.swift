import SwiftUI

struct StratumIcon: View {
    var id: String
    var size: CGFloat = 36

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width, canvasSize.height) / 64
            var base = context
            base.scaleBy(x: scale, y: scale)
            let color = GraphicsContext.Shading.color(GuideColor.green)
            switch id {
            case "ground":
                ground(&base, color)
            case "low":
                low(&base, color)
            case "mid":
                mid(&base, color)
            case "sky":
                sky(&base, color)
            default:
                canopy(&base, color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func ground(_ context: inout GraphicsContext, _ color: GraphicsContext.Shading) {
        var ground = Path()
        ground.addRect(CGRect(x: 4, y: 50, width: 56, height: 3.2))
        context.fill(ground, with: color)
        var grass = Path()
        grass.move(to: CGPoint(x: 8, y: 50))
        grass.addQuadCurve(to: CGPoint(x: 14, y: 50), control: CGPoint(x: 11, y: 38))
        grass.addQuadCurve(to: CGPoint(x: 22, y: 50), control: CGPoint(x: 18, y: 34))
        grass.addQuadCurve(to: CGPoint(x: 30, y: 50), control: CGPoint(x: 26, y: 40))
        context.fill(grass, with: color)
        bird(&context, at: CGPoint(x: 46, y: 40), color: color, paper: false)
    }

    private func low(_ context: inout GraphicsContext, _ color: GraphicsContext.Shading) {
        var ground = Path()
        ground.addRect(CGRect(x: 6, y: 52, width: 52, height: 3))
        context.fill(ground, with: color)
        var shrub = Path()
        shrub.move(to: CGPoint(x: 8, y: 50))
        shrub.addQuadCurve(to: CGPoint(x: 56, y: 50), control: CGPoint(x: 32, y: 22))
        shrub.closeSubpath()
        context.fill(shrub, with: color)
        bird(&context, at: CGPoint(x: 34, y: 36), color: .color(GuideColor.paper), paper: true)
    }

    private func mid(_ context: inout GraphicsContext, _ color: GraphicsContext.Shading) {
        var trunk = Path()
        trunk.addRect(CGRect(x: 30, y: 34, width: 4, height: 24))
        context.fill(trunk, with: color)
        var crown = Path()
        crown.addEllipse(in: CGRect(x: 18, y: 16, width: 28, height: 28))
        context.fill(crown, with: color)
        var ground = Path()
        ground.addRect(CGRect(x: 6, y: 58, width: 52, height: 3))
        context.fill(ground, with: color)
        bird(&context, at: CGPoint(x: 48, y: 30), color: color, paper: false)
    }

    private func canopy(_ context: inout GraphicsContext, _ color: GraphicsContext.Shading) {
        var trunk = Path()
        trunk.addRect(CGRect(x: 30, y: 26, width: 4, height: 34))
        context.fill(trunk, with: color)
        var crown = Path()
        crown.addEllipse(in: CGRect(x: 19, y: 5, width: 26, height: 26))
        context.fill(crown, with: color)
        var ground = Path()
        ground.addRect(CGRect(x: 6, y: 60, width: 52, height: 3))
        context.fill(ground, with: color)
        bird(&context, at: CGPoint(x: 38, y: 16), color: .color(GuideColor.paper), paper: true)
    }

    private func sky(_ context: inout GraphicsContext, _ color: GraphicsContext.Shading) {
        var horizon = Path()
        horizon.addRect(CGRect(x: 6, y: 54, width: 52, height: 2.4))
        context.fill(horizon, with: color)
        var wing = Path()
        wing.move(to: CGPoint(x: 12, y: 28))
        wing.addQuadCurve(to: CGPoint(x: 32, y: 22), control: CGPoint(x: 20, y: 14))
        wing.addQuadCurve(to: CGPoint(x: 52, y: 28), control: CGPoint(x: 44, y: 14))
        wing.addQuadCurve(to: CGPoint(x: 32, y: 26), control: CGPoint(x: 44, y: 20))
        wing.addQuadCurve(to: CGPoint(x: 12, y: 28), control: CGPoint(x: 20, y: 20))
        wing.closeSubpath()
        context.fill(wing, with: color)
        var body = Path()
        body.addEllipse(in: CGRect(x: 28, y: 20, width: 8, height: 8))
        context.fill(body, with: color)
    }

    private func bird(_ context: inout GraphicsContext, at center: CGPoint, color: GraphicsContext.Shading, paper: Bool) {
        var body = Path()
        body.addEllipse(in: CGRect(x: center.x - 3.2, y: center.y - 3.2, width: 6.4, height: 6.4))
        context.fill(body, with: color)
        var beak = Path()
        beak.move(to: CGPoint(x: center.x + 2.4, y: center.y - 0.8))
        beak.addLine(to: CGPoint(x: center.x + 9, y: center.y + 0.6))
        beak.addLine(to: CGPoint(x: center.x + 2.6, y: center.y + 2.2))
        beak.closeSubpath()
        context.fill(beak, with: color)
        if paper {
            var legs = Path()
            legs.move(to: CGPoint(x: center.x, y: center.y + 3))
            legs.addLine(to: CGPoint(x: center.x, y: center.y + 8))
            context.stroke(legs, with: color, lineWidth: 1.6)
        }
    }
}

struct StratumLegend: View {
    var strata: [StratumInfo]

    var body: some View {
        // Kept for detail / info sheets. The home screen suppresses these long
        // descriptions and opens them from the Zone “i” button instead.
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(strata) { item in
                HStack(alignment: .top, spacing: 8) {
                    StratumIcon(id: item.id, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label)
                            .font(.subheadline.weight(.semibold))
                        Text(item.hint)
                            .font(.caption)
                            .foregroundStyle(GuideColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .background(GuideColor.card)
                .overlay {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(GuideColor.line, lineWidth: 1)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
