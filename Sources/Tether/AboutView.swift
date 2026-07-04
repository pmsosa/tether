import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text("Tether")
                .font(.title2.bold())
            VStack(spacing: 2) {
                Text("Made by Pedro")
                Text("2026")
                Text("BSD-3-Clause License")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: 280)
    }
}

struct SetupView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Up ADB")
                .font(.title3.bold())
            Text("Tether needs the Android Debug Bridge (adb) to talk to your device. Install it with Homebrew:")
                .foregroundStyle(.secondary)
            Text("brew install --cask android-platform-tools")
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text("Then enable USB debugging on your phone (Settings → Developer options) and reconnect.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Re-check") { state.recheckAdb() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
