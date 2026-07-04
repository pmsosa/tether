import SwiftUI

@main
struct TetherApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(state: state)
        } label: {
            Image(systemName: state.anyMounted ? "iphone.badge.checkmark" : "iphone")
        }
        .menuBarExtraStyle(.menu)

        Window("About Tether", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Set Up ADB", id: "setup") {
            SetupView(state: state)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
