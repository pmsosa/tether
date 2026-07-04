import Foundation
import Network

/// A minimal WebDAV server that exposes an Android device's filesystem (via
/// `adb`) so macOS's built-in `mount_webdav` can mount it as a Finder volume.
/// Binds to loopback only and serves one request per connection.
final class WebDAVServer {
    let adb: AdbClient
    let root: String            // device path exposed as the volume root, e.g. "/sdcard"

    private var listener: NWListener?
    private let controlQueue = DispatchQueue(label: "tether.webdav.control")
    private let workQueue = DispatchQueue(label: "tether.webdav.work", attributes: .concurrent)
    private(set) var port: UInt16 = 0

    // Strong references to in-flight connections (keyed by identity), so they
    // aren't deallocated while awaiting I/O. Mutated only on controlQueue.
    private var connections: [ObjectIdentifier: DAVConnection] = [:]

    func retain(_ c: DAVConnection) { connections[ObjectIdentifier(c)] = c }
    func release(_ c: DAVConnection) { connections.removeValue(forKey: ObjectIdentifier(c)) }

    init(adbPath: String, serial: String, rootPath: String) {
        self.adb = AdbClient(adbPath: adbPath, serial: serial)
        self.root = rootPath
    }

    // MARK: Lifecycle

    /// Starts the listener on an ephemeral loopback port. Blocks until ready.
    func start() throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: 0)!
        )

        let listener = try NWListener(using: params)
        self.listener = listener

        let sem = DispatchSemaphore(value: 0)
        var startError: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: sem.signal()
            case .failed(let e): startError = e; sem.signal()
            case .cancelled: sem.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            let dav = DAVConnection(conn: conn, server: self)
            self.retain(dav)
            dav.start(on: self.controlQueue)
        }
        listener.start(queue: controlQueue)

        _ = sem.wait(timeout: .now() + 8)
        if let startError { throw startError }
        guard let p = listener.port?.rawValue else {
            throw AdbError(message: "WebDAV server failed to acquire a port")
        }
        port = p
        return p
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: Request routing

    /// Handle a parsed request on the work queue, then invoke `completion`.
    func handle(_ req: DAVRequest, completion: @escaping (DAVResponse) -> Void) {
        workQueue.async { [weak self] in
            guard let self else { completion(.status(503)); return }
            completion(self.route(req))
        }
    }

    private func route(_ req: DAVRequest) -> DAVResponse {
        let devicePath = mapToDevice(req.path)
        switch req.method {
        case "OPTIONS": return options()
        case "PROPFIND": return propfind(req, devicePath: devicePath)
        case "GET", "HEAD": return get(req, devicePath: devicePath, includeBody: req.method == "GET")
        case "PUT": return put(req, devicePath: devicePath)
        case "MKCOL": return adb.mkdir(devicePath) ? .status(201) : .status(409)
        case "DELETE": return adb.remove(devicePath) ? .status(204) : .status(404)
        case "MOVE": return moveOrCopy(req, from: devicePath, copy: false)
        case "COPY": return moveOrCopy(req, from: devicePath, copy: true)
        case "LOCK": return lock(req)
        case "UNLOCK": return .status(204)
        case "PROPPATCH": return proppatch(req, devicePath: devicePath)
        default: return .status(405)
        }
    }

    // MARK: Path mapping

    /// Map a WebDAV request path onto a device path under `root`.
    private func mapToDevice(_ webPath: String) -> String {
        var p = webPath
        if let q = p.firstIndex(of: "?") { p = String(p[..<q]) }
        p = p.removingPercentEncoding ?? p
        while p.hasPrefix("/") { p.removeFirst() }
        while p.hasSuffix("/") { p.removeLast() }
        return p.isEmpty ? root : "\(root)/\(p)"
    }

    // MARK: Verb handlers

    private func options() -> DAVResponse {
        DAVResponse(status: 200, headers: [
            "DAV": "1, 2",
            "MS-Author-Via": "DAV",
            "Allow": "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, MKCOL, MOVE, COPY, LOCK, UNLOCK",
        ], body: Data())
    }

    private func get(_ req: DAVRequest, devicePath: String, includeBody: Bool) -> DAVResponse {
        guard let entry = adb.stat(devicePath) else { return .status(404) }
        if entry.isDir { return .status(403) }
        var headers = [
            "Content-Type": "application/octet-stream",
            "Last-Modified": Self.httpDate(entry.modified),
        ]
        if includeBody {
            guard let data = adb.read(devicePath) else { return .status(404) }
            return DAVResponse(status: 200, headers: headers, body: data)
        } else {
            headers["Content-Length-Hint"] = String(entry.size)
            var resp = DAVResponse(status: 200, headers: headers, body: Data())
            resp.contentLengthOverride = entry.size
            return resp
        }
    }

    private func put(_ req: DAVRequest, devicePath: String) -> DAVResponse {
        adb.write(req.body, to: devicePath) ? .status(201) : .status(500)
    }

    private func moveOrCopy(_ req: DAVRequest, from: String, copy: Bool) -> DAVResponse {
        guard let dest = req.headers["destination"] else { return .status(400) }
        let destPath = mapToDevice(destinationPath(dest))
        let ok = copy ? adb.copy(from, to: destPath) : adb.move(from, to: destPath)
        return ok ? .status(201) : .status(409)
    }

    /// Extract the path portion from a Destination header (may be a full URL).
    private func destinationPath(_ destination: String) -> String {
        if let url = URL(string: destination), url.host != nil {
            return url.path
        }
        return destination
    }

    private func lock(_ req: DAVRequest) -> DAVResponse {
        // We don't implement real locking; return a synthetic token so Finder
        // proceeds with writes.
        let token = "opaquelocktoken:\(UUID().uuidString)"
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock>\
        <D:locktype><D:write/></D:locktype>\
        <D:lockscope><D:exclusive/></D:lockscope>\
        <D:depth>infinity</D:depth>\
        <D:timeout>Second-3600</D:timeout>\
        <D:locktoken><D:href>\(token)</D:href></D:locktoken>\
        </D:activelock></D:lockdiscovery></D:prop>
        """
        return DAVResponse(status: 200, headers: [
            "Content-Type": "application/xml; charset=\"utf-8\"",
            "Lock-Token": "<\(token)>",
        ], body: Data(xml.utf8))
    }

    private func proppatch(_ req: DAVRequest, devicePath: String) -> DAVResponse {
        // Accept and ignore property writes (Finder sets timestamps, etc.).
        let href = xmlEscape(req.path)
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:"><D:response><D:href>\(href)</D:href>\
        <D:propstat><D:status>HTTP/1.1 200 OK</D:status></D:propstat>\
        </D:response></D:multistatus>
        """
        return DAVResponse(status: 207, headers: [
            "Content-Type": "application/xml; charset=\"utf-8\"",
        ], body: Data(xml.utf8))
    }

    private func propfind(_ req: DAVRequest, devicePath: String) -> DAVResponse {
        guard let selfEntry = adb.stat(devicePath) else { return .status(404) }

        let depth = req.headers["depth"] ?? "1"
        var responses = [responseXML(href: req.path, entry: selfEntry, isSelf: true)]

        if selfEntry.isDir && depth != "0" {
            let baseHref = req.path.hasSuffix("/") ? req.path : req.path + "/"
            for child in adb.list(devicePath) {
                let childHref = baseHref + percentEncode(child.name)
                responses.append(responseXML(href: childHref, entry: child, isSelf: false))
            }
        }

        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        \(responses.joined(separator: "\n"))
        </D:multistatus>
        """
        return DAVResponse(status: 207, headers: [
            "Content-Type": "application/xml; charset=\"utf-8\"",
        ], body: Data(xml.utf8))
    }

    private func responseXML(href: String, entry: RemoteEntry, isSelf: Bool) -> String {
        var href = href
        if entry.isDir && !href.hasSuffix("/") { href += "/" }
        let resourceType = entry.isDir ? "<D:collection/>" : ""
        let displayName = xmlEscape(entry.name.isEmpty ? "/" : entry.name)
        return """
        <D:response>
          <D:href>\(xmlEscape(href))</D:href>
          <D:propstat>
            <D:prop>
              <D:resourcetype>\(resourceType)</D:resourcetype>
              <D:getcontentlength>\(entry.size)</D:getcontentlength>
              <D:getlastmodified>\(Self.httpDate(entry.modified))</D:getlastmodified>
              <D:creationdate>\(Self.isoDate(entry.modified))</D:creationdate>
              <D:displayname>\(displayName)</D:displayname>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
        """
    }

    // MARK: Formatting helpers

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "GMT")
        return f
    }()

    static func httpDate(_ date: Date) -> String { httpDateFormatter.string(from: date) }
    static func isoDate(_ date: Date) -> String { isoDateFormatter.string(from: date) }
}

// MARK: - Request/response value types

struct DAVRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct DAVResponse {
    var status: Int
    var headers: [String: String]
    var body: Data
    var contentLengthOverride: Int?

    init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func status(_ code: Int) -> DAVResponse { DAVResponse(status: code) }
}

// MARK: - XML / encoding helpers

func xmlEscape(_ s: String) -> String {
    var out = s
    out = out.replacingOccurrences(of: "&", with: "&amp;")
    out = out.replacingOccurrences(of: "<", with: "&lt;")
    out = out.replacingOccurrences(of: ">", with: "&gt;")
    out = out.replacingOccurrences(of: "\"", with: "&quot;")
    return out
}

func percentEncode(_ segment: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove("/")
    return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
}
