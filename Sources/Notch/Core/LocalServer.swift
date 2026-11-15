import Foundation
import Network

/// Minimal HTTP/1.1 server on 127.0.0.1 only. Every POST needs the X-Notch-Token header
/// (from ~/.notch/token) so web pages can't reach it through the browser.
@MainActor
final class LocalServer {
    static let shared = LocalServer()

    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    }

    typealias Handler = @MainActor (Request) async -> (Int, Any)

    private var listener: NWListener?
    private var routes: [String: Handler] = [:]
    private(set) var running = false
    private(set) var lastError: String?

    static let token: String = {
        let url = Paths.home.appendingPathComponent("token")
        if let t = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        let t = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try? FileManager.default.createDirectory(at: Paths.home, withIntermediateDirectories: true)
        try? t.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return t
    }()

    func route(_ method: String, _ path: String, _ h: @escaping Handler) { routes[method + " " + path] = h }

    func start() {
        stop()
        guard Store.shared.config.netLocalAPI else { return }
        _ = Self.token          // make sure ~/.notch/token exists for scripts
        let port = NWEndpoint.Port(rawValue: UInt16(Store.shared.config.apiPort)) ?? 51515
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { c in
                c.start(queue: .main)
                MainActor.assumeIsolated { LocalServer.shared.receive(c, Data()) }
            }
            l.stateUpdateHandler = { s in
                MainActor.assumeIsolated {
                    if case .failed(let e) = s { LocalServer.shared.lastError = "\(e)"; LocalServer.shared.running = false }
                    if case .ready = s { LocalServer.shared.running = true; LocalServer.shared.lastError = nil }
                }
            }
            l.start(queue: .main)
            listener = l
        } catch { lastError = "\(error)" }
    }

    func stop() { listener?.cancel(); listener = nil; running = false }

    private func receive(_ c: NWConnection, _ acc: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, err in
            MainActor.assumeIsolated {
                var acc = acc
                if let data { acc.append(data) }
                if acc.count > 8 << 20 || err != nil { c.cancel(); return }
                if let req = Self.parse(acc) { LocalServer.shared.handle(req, c) }
                else if done { c.cancel() }
                else { LocalServer.shared.receive(c, acc) }
            }
        }
    }

    /// Returns a request once headers and the full Content-Length body have arrived.
    nonisolated static func parse(_ d: Data) -> Request? {
        guard let end = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: d[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = head.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        let body = d[end.upperBound...]
        guard body.count >= len else { return nil }
        let path = String(first[1]).split(separator: "?").first.map(String.init) ?? "/"
        return Request(method: String(first[0]), path: path, headers: headers, body: Data(body.prefix(len)))
    }

    private func handle(_ r: Request, _ c: NWConnection) {
        if r.method != "GET", r.headers["x-notch-token"] != Self.token {
            return reply(c, 401, ["error": "missing or wrong X-Notch-Token (see ~/.notch/token)"])
        }
        guard let h = routes[r.method + " " + r.path] else { return reply(c, 404, ["error": "not found"]) }
        Task { @MainActor in
            let (status, obj) = await h(r)
            self.reply(c, status, obj)
        }
    }

    private func reply(_ c: NWConnection, _ status: Int, _ obj: Any) {
        let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }
}
