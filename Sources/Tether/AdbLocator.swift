import Foundation

/// Finds the `adb` executable and remembers where it was found.
enum AdbLocator {
    private static let defaultsKey = "adbPath"

    private static var candidatePaths: [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "\(home)/Android/Sdk/platform-tools/adb",
        ]
    }

    /// Returns a usable adb path, or nil if adb can't be found.
    static func locate() -> String? {
        let fm = FileManager.default

        if let saved = UserDefaults.standard.string(forKey: defaultsKey),
           fm.isExecutableFile(atPath: saved) {
            return saved
        }

        if let fromPath = whichAdb(), fm.isExecutableFile(atPath: fromPath) {
            UserDefaults.standard.set(fromPath, forKey: defaultsKey)
            return fromPath
        }

        for path in candidatePaths where fm.isExecutableFile(atPath: path) {
            UserDefaults.standard.set(path, forKey: defaultsKey)
            return path
        }

        return nil
    }

    /// Resolve adb through the user's login shell so we pick up their PATH.
    private static func whichAdb() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let result = ProcessRunner.run(shell, ["-l", "-c", "command -v adb"])
        let path = result.outString.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
