import Foundation
import Network

/// Minimal HTTP/1.1 file server for the HLS output. The AirPlay receiver (Apple TV / smart TV) downloads
/// the stream from here directly, so it listens on all interfaces, not only on localhost.
public final class HLSServer {
    public struct Response {
        var status: Int
        var contentType: String
        var body: Data

        static func notFound() -> Response { Response(status: 404, contentType: "text/plain", body: Data("Not found".utf8)) }
    }

    /// Returns the response for a file name (path without leading slash and query).
    public var handler: ((String) -> Response?)?
    public private(set) var port: UInt16 = 0

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "hls.server", attributes: .concurrent)

    public init() {}

    public func start() throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure = error; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut { throw PlayerError.server(loc("timed out")) }
        if let failure { throw PlayerError.server(failure.localizedDescription) }
        guard let port = listener.port?.rawValue else { throw PlayerError.server("nincs port") }
        self.listener = listener
        self.port = port
        return port
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(conn, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if error != nil || isComplete || buffer.count > 64 * 1024 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buffer)
            }
        }
    }

    private func respond(_ conn: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            send(conn, Response(status: 405, contentType: "text/plain", body: Data()), head: false, range: nil)
            return
        }
        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var range: String?
        for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") {
            range = line.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
        }
        let response = handler?(path) ?? .notFound()
        if path.hasSuffix(".m3u8") || path.hasSuffix(".vtt") || path.hasPrefix("init") || response.status != 200 {
            let ua = lines.first { $0.lowercased().hasPrefix("user-agent:") }?.dropFirst(11).trimmingCharacters(in: .whitespaces) ?? "-"
            Log.write("http \(conn.endpoint) \(parts[0]) /\(path) -> \(response.status) [\(ua)]")
        }
        send(conn, response, head: parts[0] == "HEAD", range: range)
    }

    private func send(_ conn: NWConnection, _ response: Response, head: Bool, range: String?) {
        var status = response.status
        var body = response.body
        var headers = [
            "Content-Type: \(response.contentType)",
            "Accept-Ranges: bytes",
            "Cache-Control: no-cache",
            "Access-Control-Allow-Origin: *",
            "Connection: close",
        ]
        if status == 200, let range, let r = Self.parseRange(range, length: body.count) {
            status = 206
            headers.append("Content-Range: bytes \(r.lowerBound)-\(r.upperBound - 1)/\(body.count)")
            body = body.subdata(in: r)
        }
        headers.append("Content-Length: \(body.count)")
        let reason = [200: "OK", 206: "Partial Content", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "Error"
        var out = Data("HTTP/1.1 \(status) \(reason)\r\n\(headers.joined(separator: "\r\n"))\r\n\r\n".utf8)
        if !head { out.append(body) }
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    static func parseRange(_ header: String, length: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes="), length > 0 else { return nil }
        let spec = header.dropFirst("bytes=".count).split(separator: ",").first ?? ""
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard bounds.count == 2 else { return nil }
        switch (bounds[0], bounds[1]) {
        case let (start?, end?) where start <= end && start < length: return start..<min(end + 1, length)
        case let (start?, nil) where start < length: return start..<length
        case let (nil, suffix?) where suffix > 0: return max(length - suffix, 0)..<length
        default: return nil
        }
    }

    /// IPv4 address of the active Wi-Fi/Ethernet interface; the AirPlay receiver must be able to reach it.
    public static func lanAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var candidates: [(name: String, ip: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }
            candidates.append((name, ip))
        }
        // en* are Wi-Fi/Ethernet; utun/bridge/awdl are VPNs and peer-to-peer links the TV can't reach.
        return (candidates.first { $0.name.hasPrefix("en") } ?? candidates.first { !$0.name.hasPrefix("utun") })?.ip
    }
}
