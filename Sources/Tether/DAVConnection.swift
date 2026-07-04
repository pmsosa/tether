import Foundation
import Network

/// Parses a single HTTP/1.1 request off an NWConnection, hands it to the
/// server, writes the response, and closes. One request per connection keeps
/// the parser simple; `mount_webdav` opens fresh connections as needed.
final class DAVConnection {
    private let conn: NWConnection
    private unowned let server: WebDAVServer
    private var buffer = Data()
    private var handled = false
    private var queue: DispatchQueue = .main

    init(conn: NWConnection, server: WebDAVServer) {
        self.conn = conn
        self.server = server
    }

    func start(on queue: DispatchQueue) {
        self.queue = queue
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        conn.start(queue: queue)
        receive()
    }

    /// Cancel the socket and drop the server's strong reference to us.
    private func finish() {
        conn.cancel()
        queue.async { [weak self] in
            guard let self else { return }
            self.server.release(self)
        }
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.tryHandle()
            }
            if self.handled { return }
            if isComplete || error != nil {
                self.finish()
                return
            }
            self.receive()
        }
    }

    /// Attempt to parse a complete request from the buffer. Returns without
    /// action if more bytes are still needed.
    private func tryHandle() {
        guard !handled else { return }
        let sep = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: sep) else { return }

        let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else {
            handled = true
            respond(.status(400))
            return
        }

        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { handled = true; respond(.status(400)); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { handled = true; respond(.status(400)); return }

        let method = String(parts[0]).uppercased()
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        if available < contentLength { return } // wait for the rest of the body

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = buffer.subdata(in: bodyStart..<bodyEnd)

        handled = true
        let request = DAVRequest(method: method, path: path, headers: headers, body: body)
        server.handle(request) { [weak self] response in
            self?.respond(response)
        }
    }

    private func respond(_ response: DAVResponse) {
        let contentLength = response.contentLengthOverride ?? response.body.count

        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        var headers = response.headers
        headers.removeValue(forKey: "Content-Length-Hint")
        headers["Content-Length"] = String(contentLength)
        headers["Connection"] = "close"
        headers["Server"] = "Tether"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        var out = Data(head.utf8)
        out.append(response.body)

        conn.send(content: out, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    private static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 207: return "Multi-Status"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}
