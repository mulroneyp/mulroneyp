import SwiftUI

@main
struct HandyFieldGuideApp: App {
    @StateObject private var model = GuideModel()

    var body: some Scene {
        WindowGroup {
            GuideRootView()
                .environmentObject(model)
                .tint(GuideColor.green)
        }
    }
}
