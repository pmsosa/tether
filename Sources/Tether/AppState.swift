import Foundation
import AppKit
import Combine

/// Central observable state the menu binds to. Owns the poll timer and wires
/// user actions to the adb client and mount manager.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var devices: [Device] = []
    @Published private(set) var adbPath: String?
    @Published var autoDetect: Bool {
        didSet {
            UserDefaults.standard.set(autoDetect, forKey: Self.autoDetectKey)
            autoDetect ? startTimer() : stopTimer()
        }
    }

    private static let autoDetectKey = "autoDetect"
    private static let pollInterval: TimeInterval = 4

    private let mountManager = MountManager()
    private var timer: Timer?
    private var scanning = false

    var anyMounted: Bool {
        devices.contains { if case .mounted = $0.mount { return true } else { return false } }
    }

    init() {
        if UserDefaults.standard.object(forKey: Self.autoDetectKey) == nil {
            autoDetect = true
        } else {
            autoDetect = UserDefaults.standard.bool(forKey: Self.autoDetectKey)
        }
        adbPath = AdbLocator.locate()
        if autoDetect { startTimer() }
        Task { await refresh() }
    }

    // MARK: Discovery

    func recheckAdb() {
        adbPath = AdbLocator.locate()
        Task { await refresh() }
    }

    func refresh() async {
        guard let adbPath, !scanning else { return }
        scanning = true
        defer { scanning = false }

        let scanned = await Task.detached {
            AdbClient.listDevices(adbPath: adbPath)
        }.value

        // Preserve mount state across scans.
        let previousMounts = Dictionary(uniqueKeysWithValues: devices.map { ($0.serial, $0.mount) })
        devices = scanned.map { device in
            var d = device
            if let mount = previousMounts[device.serial] { d.mount = mount }
            return d
        }
    }

    // MARK: Mounting

    func mount(_ device: Device) {
        guard let adbPath else { return }
        setMount(device.serial, .mounting)
        Task {
            do {
                let url = try await mountManager.mount(device: device, adbPath: adbPath)
                setMount(device.serial, .mounted(url))
                NSWorkspace.shared.open(url)
            } catch {
                setMount(device.serial, .failed(error.localizedDescription))
            }
        }
    }

    func unmount(_ device: Device) {
        setMount(device.serial, .unmounting)
        Task {
            await mountManager.unmount(serial: device.serial)
            setMount(device.serial, .unmounted)
        }
    }

    func reveal(_ device: Device) {
        if let url = mountManager.mountPoint(for: device.serial) {
            NSWorkspace.shared.open(url)
        }
    }

    func quit() {
        Task {
            await mountManager.unmountAll()
            NSApp.terminate(nil)
        }
    }

    // MARK: Timer

    private func startTimer() {
        stopTimer()
        let t = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Mutation

    private func setMount(_ serial: String, _ state: MountState) {
        guard let idx = devices.firstIndex(where: { $0.serial == serial }) else { return }
        devices[idx].mount = state
    }
}
