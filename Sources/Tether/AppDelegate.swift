import AppKit

/// Ensures device volumes are unmounted no matter how the app exits:
///  • Cmd-Q / logout / shutdown → `applicationShouldTerminate` unmounts first.
///  • SIGTERM / SIGINT (`kill <pid>`, Ctrl-C) → sweep mounts, then exit.
///  • SIGKILL / crash / power loss → uncatchable, but the next launch sweeps
///    the leftover volumes (see AppState startup).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
    }

    /// Cmd-Q, logout, and shutdown route through here. Defer termination until
    /// the volumes are unmounted.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState = AppState.shared, appState.hasMounts else { return .terminateNow }
        Task { @MainActor in
            await appState.unmountAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            // Ignore the default action so our dispatch source handles it.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                MountManager.sweepStaleMounts()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
