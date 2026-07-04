import Foundation

/// Result of running an external process.
struct ProcessResult {
    let status: Int32
    let out: Data
    let err: Data

    var outString: String { String(data: out, encoding: .utf8) ?? "" }
    var errString: String { String(data: err, encoding: .utf8) ?? "" }
    var ok: Bool { status == 0 }
}

/// Minimal synchronous process runner. Reads stdout/stderr concurrently to
/// avoid pipe-buffer deadlocks. Never call this on the main thread.
enum ProcessRunner {
    static func run(_ launchPath: String, _ args: [String], input: Data? = nil) -> ProcessResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        var inPipe: Pipe?
        if input != nil {
            let p = Pipe()
            proc.standardInput = p
            inPipe = p
        }

        do {
            try proc.run()
        } catch {
            return ProcessResult(status: -1, out: Data(), err: Data(error.localizedDescription.utf8))
        }

        if let input, let inPipe {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }

        // Drain stderr on a background queue while we read stdout, so neither
        // pipe can fill its buffer and stall the child.
        let errQueue = DispatchQueue(label: "process.stderr")
        var errData = Data()
        errQueue.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile() }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        errQueue.sync {}

        return ProcessResult(status: proc.terminationStatus, out: outData, err: errData)
    }
}

/// Quote a string for safe use inside a single remote shell command.
func singleQuoted(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
