import SwiftUI

@main
struct NightSkyApp: App {
    @StateObject private var model = NightCaptureModel()

    var body: some Scene {
        WindowGroup {
            CaptureRootView(model: model)
                .preferredColorScheme(.dark)
        }
    }
}
