import Foundation

/// A user-presentable error from adb/mount operations.
struct AdbError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Transport: Equatable {
    case usb
    case wifi(host: String, port: Int)

    /// Short label shown next to the device name.
    var label: String {
        switch self {
        case .usb: return "USB"
        case .wifi(let host, _): return host
        }
    }
}

enum DeviceState: Equatable {
    case ready          // "device" — authorized and usable
    case unauthorized   // waiting for the on-phone RSA prompt
    case offline        // seen but not responding
}

enum MountState: Equatable {
    case unmounted
    case mounting
    case mounted(URL)
    case unmounting
    case failed(String)
}

struct Device: Identifiable, Equatable {
    let serial: String
    let transport: Transport
    let state: DeviceState
    let model: String?
    var mount: MountState = .unmounted

    var id: String { serial }

    /// A human-friendly name: the reported model, else the serial.
    var displayName: String {
        if let model, !model.isEmpty {
            return model.replacingOccurrences(of: "_", with: " ")
        }
        return serial
    }
}
