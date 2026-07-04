import Foundation

/// A parsed entry from a remote directory listing.
struct RemoteEntry {
    let name: String
    let isDir: Bool
    let size: Int
    let modified: Date
}

/// A top-level storage volume on the device (internal storage or a removable
/// card), presented as a folder at the root of the mounted volume.
struct StorageVolume {
    let name: String   // friendly name shown in Finder
    let path: String   // device path, e.g. /storage/emulated/0
}

/// Thin wrapper over the `adb` binary. All calls are blocking; run them off the
/// main thread. Instances are cheap value types keyed by an adb path + serial.
struct AdbClient {
    let adbPath: String

    // MARK: Device discovery

    /// Runs `adb devices -l` and returns the parsed device list.
    static func listDevices(adbPath: String) -> [Device] {
        let result = ProcessRunner.run(adbPath, ["devices", "-l"])
        guard result.ok else { return [] }
        return parseDevices(result.outString)
    }

    static func parseDevices(_ output: String) -> [Device] {
        var devices: [Device] = []
        let lines = output.split(separator: "\n").map(String.init)
        for line in lines.dropFirst() { // first line is "List of devices attached"
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 2 else { continue }

            let serial = fields[0]
            let state: DeviceState
            switch fields[1] {
            case "device": state = .ready
            case "unauthorized": state = .unauthorized
            default: state = .offline
            }

            var model: String?
            for field in fields.dropFirst(2) where field.hasPrefix("model:") {
                model = String(field.dropFirst("model:".count))
            }

            devices.append(Device(
                serial: serial,
                transport: transport(for: serial),
                state: state,
                model: model
            ))
        }
        return devices
    }

    /// A serial of the form `1.2.3.4:5555` is a WiFi (TCP) connection.
    static func transport(for serial: String) -> Transport {
        let parts = serial.split(separator: ":")
        if parts.count == 2,
           let port = Int(parts[1]),
           parts[0].split(separator: ".").count == 4,
           parts[0].allSatisfy({ $0.isNumber || $0 == "." }) {
            return .wifi(host: String(parts[0]), port: port)
        }
        return .usb
    }

    // MARK: Remote filesystem operations

    private var base: [String] { ["-s", serial] }
    let serial: String

    init(adbPath: String, serial: String) {
        self.adbPath = adbPath
        self.serial = serial
    }

    /// Run a shell command on the device, returning stdout bytes.
    func shell(_ command: String) -> ProcessResult {
        ProcessRunner.run(adbPath, base + ["shell", command])
    }

    /// Discover the device's storage volumes. Internal storage is
    /// `/storage/emulated/0`; removable cards / USB drives appear as sibling
    /// entries under `/storage` (named by their volume id). `/sdcard` is just a
    /// symlink to internal storage, which is why it doesn't show the card.
    func discoverVolumes() -> [StorageVolume] {
        let internalVolume = StorageVolume(name: "Internal storage", path: "/storage/emulated/0")
        var others: [StorageVolume] = []
        let result = shell("ls --color=never /storage")
        if result.ok {
            for raw in result.outString.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let entry = raw.trimmingCharacters(in: .whitespaces)
                if entry.isEmpty || entry == "self" || entry == "emulated" { continue }
                others.append(StorageVolume(name: "SD Card (\(entry))", path: "/storage/\(entry)"))
            }
        }
        return [internalVolume] + others
    }

    /// Stat a single path (the entry itself, via `ls -lad`).
    func stat(_ path: String) -> RemoteEntry? {
        let result = shell("ls -ladL --color=never \(singleQuoted(path))")
        guard result.ok else { return nil }
        for line in result.outString.split(separator: "\n") {
            if let entry = Self.parseLsLine(String(line), fallbackName: (path as NSString).lastPathComponent) {
                return entry
            }
        }
        return nil
    }

    /// List the children of a directory.
    func list(_ path: String) -> [RemoteEntry] {
        let result = shell("ls -laL --color=never \(singleQuoted(path))")
        guard result.ok else { return [] }
        var entries: [RemoteEntry] = []
        for rawLine in result.outString.split(separator: "\n") {
            let line = String(rawLine)
            if line.hasPrefix("total ") { continue }
            guard let entry = Self.parseLsLine(line, fallbackName: nil) else { continue }
            if entry.name == "." || entry.name == ".." { continue }
            entries.append(entry)
        }
        return entries
    }

    /// Read a file's contents.
    func read(_ path: String) -> Data? {
        let result = ProcessRunner.run(adbPath, base + ["exec-out", "cat \(singleQuoted(path))"])
        return result.ok ? result.out : nil
    }

    /// Write bytes to a file by pushing a temp file with `adb push`.
    func write(_ data: Data, to path: String) -> Bool {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-\(UUID().uuidString)")
        do {
            try data.write(to: tmp)
        } catch {
            return false
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let result = ProcessRunner.run(adbPath, base + ["push", tmp.path, path])
        return result.ok
    }

    func mkdir(_ path: String) -> Bool { shell("mkdir \(singleQuoted(path))").ok }
    func remove(_ path: String) -> Bool { shell("rm -rf \(singleQuoted(path))").ok }
    func move(_ from: String, to: String) -> Bool {
        shell("mv \(singleQuoted(from)) \(singleQuoted(to))").ok
    }
    func copy(_ from: String, to: String) -> Bool {
        shell("cp -r \(singleQuoted(from)) \(singleQuoted(to))").ok
    }

    // MARK: ls parsing

    private static let lsDateFormatters: [DateFormatter] = {
        ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"].map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            f.dateFormat = fmt
            return f
        }
    }()

    /// Parse a single `ls -l` line. Expected columns:
    /// perms links owner group size date time name...
    static func parseLsLine(_ line: String, fallbackName: String?) -> RemoteEntry? {
        let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard cols.count >= 8 else { return nil }
        let perms = cols[0]
        guard let firstChar = perms.first, "dlbcps-".contains(firstChar) else { return nil }

        let size = Int(cols[4]) ?? 0
        let dateStr = "\(cols[5]) \(cols[6])"
        var modified = Date(timeIntervalSince1970: 0)
        for f in lsDateFormatters {
            if let d = f.date(from: dateStr) { modified = d; break }
        }

        var name = cols[7...].joined(separator: " ")
        // Strip symlink target: "link -> /target"
        if let range = name.range(of: " -> ") {
            name = String(name[..<range.lowerBound])
        }
        if name.isEmpty { name = fallbackName ?? "" }

        let isDir = perms.hasPrefix("d")
        return RemoteEntry(name: name, isDir: isDir, size: size, modified: modified)
    }
}
