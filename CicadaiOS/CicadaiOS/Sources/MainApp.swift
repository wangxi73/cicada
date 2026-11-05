import SwiftUI

@main
struct CicadaiOSApp: App {
    var body: some Scene {
        WindowGroup {
            CicadaRootView()
                .preferredColorScheme(.light)
        }
    }
}
