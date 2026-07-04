import Foundation

/// Owns the lifecycle of each mounted device: a WebDAV server + a
/// `mount_webdav` volume under ~/Tether/<name>.
@MainActor
final class MountManager {
    private struct Mount {
        let server: WebDAVServer
        let mountPoint: URL
    }

    private var mounts: [String: Mount] = [:]

    /// The device path exposed as the volume root.
    private let rootPath = "/sdcard"

    func mountPoint(for serial: String) -> URL? { mounts[serial]?.mountPoint }

    /// Mount a device and return the local mount point URL.
    func mount(device: Device, adbPath: String) async throws -> URL {
        if let existing = mounts[device.serial] { return existing.mountPoint }

        let server = WebDAVServer(adbPath: adbPath, serial: device.serial, rootPath: rootPath)
        let port = try await Task.detached { try server.start() }.value

        let name = Self.sanitize(device.displayName)
        let mountPoint = Self.mountBase().appendingPathComponent(name)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let url = "http://127.0.0.1:\(port)/"
        let result = await Task.detached {
            ProcessRunner.run("/sbin/mount_webdav", ["-v", name, url, mountPoint.path])
        }.value

        guard result.ok else {
            server.stop()
            let detail = result.errString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AdbError(message: detail.isEmpty
                ? "mount_webdav exited with code \(result.status)"
                : detail)
        }

        mounts[device.serial] = Mount(server: server, mountPoint: mountPoint)
        return mountPoint
    }

    func unmount(serial: String) async {
        guard let mount = mounts[serial] else { return }
        let path = mount.mountPoint.path
        _ = await Task.detached {
            let r = ProcessRunner.run("/sbin/umount", [path])
            if !r.ok {
                _ = ProcessRunner.run("/usr/sbin/diskutil", ["unmount", "force", path])
            }
        }.value
        mount.server.stop()
        mounts.removeValue(forKey: serial)
    }

    func unmountAll() async {
        for serial in Array(mounts.keys) {
            await unmount(serial: serial)
        }
    }

    // MARK: Helpers

    private static func mountBase() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Tether")
    }

    private static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\0")
        let cleaned = name.components(separatedBy: bad).joined(separator: "-")
        return cleaned.isEmpty ? "device" : cleaned
    }
}
