import SwiftUI

@main
struct WaterEjectApp: App {
    @State private var controller = EjectController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(controller)
                .preferredColorScheme(.dark)
        }
    }
}
