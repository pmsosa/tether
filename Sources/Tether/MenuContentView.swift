import SwiftUI

/// The contents of the menu-bar dropdown (rendered as a native menu).
struct MenuContentView: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if state.adbPath == nil {
            Text("ADB not found")
            Button("Set up ADB…") { open("setup") }
            Divider()
        } else {
            deviceSection
            Divider()
        }

        Button("Refresh") {
            Task { await state.refresh() }
        }
        .keyboardShortcut("r")

        Toggle("Auto-detect", isOn: $state.autoDetect)

        Divider()

        Button("About Tether") { open("about") }
        Button("Quit Tether") { state.quit() }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private var deviceSection: some View {
        if state.devices.isEmpty {
            Text("No devices found")
        } else {
            ForEach(state.devices) { device in
                deviceRow(device)
            }
        }
    }

    @ViewBuilder
    private func deviceRow(_ device: Device) -> some View {
        let title = "\(device.displayName)  (\(device.transport.label))"
        switch device.state {
        case .unauthorized:
            Text("\(device.displayName) — unauthorized (check phone)")
        case .offline:
            Text("\(device.displayName) — offline")
        case .ready:
            switch device.mount {
            case .unmounted:
                Menu(title) {
                    Button("Mount") { state.mount(device) }
                }
            case .mounting:
                Text("\(device.displayName) — Mounting…")
            case .mounted:
                Menu("\(title)  ✓") {
                    Button("Show in Finder") { state.reveal(device) }
                    Button("Unmount") { state.unmount(device) }
                }
            case .unmounting:
                Text("\(device.displayName) — Unmounting…")
            case .failed(let message):
                Menu("\(device.displayName) — failed") {
                    Text(message)
                    Button("Try again") { state.mount(device) }
                }
            }
        }
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
