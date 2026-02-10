import SwiftUI

@main
struct TahoeProxyApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .windowToolbarStyle(.unified)
    }
}
