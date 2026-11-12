import SwiftUI

enum NightColor {
    static let background = Color.black
    static let text = Color(red: 0.90, green: 0.42, blue: 0.36)
    static let muted = Color(red: 0.62, green: 0.32, blue: 0.28)
    static let faint = Color(red: 0.40, green: 0.20, blue: 0.18)
}

enum NightCopy {
    static let setupHeading = "Set the phone down"
    static let setupBody = "Place the phone face down on a flat surface with a clear view of the night sky. The rear camera points at the sky, so the screen faces the surface."
    static let countdownHint = "Exposure starts when this reaches zero."
    static let capturingHint = "Face down. Rear camera toward the sky."
    static let safeToPickUp = "Safe to pick up"
}

struct SetupInstruction: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NightCopy.setupHeading)
                .font(.title.weight(.semibold))
                .foregroundStyle(NightColor.text)
            Text(NightCopy.setupBody)
                .font(.title3.weight(.medium))
                .foregroundStyle(NightColor.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct NightButton: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 64)
                .foregroundStyle(NightColor.text)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(NightColor.text, lineWidth: 1.5)
                )
        }
        .buttonStyle(NightPressStyle())
    }
}

struct NightPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

func nightClock(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval.rounded(.down)))
    return String(format: "%d:%02d", total / 60, total % 60)
}

func nightSeconds(_ interval: TimeInterval) -> String {
    if interval >= 10 {
        return "\(Int(interval.rounded()))s"
    }
    return String(format: "%.1fs", interval)
}
