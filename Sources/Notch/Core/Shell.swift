import Foundation

enum Shell {
    /// Runs a process off the main thread, returns stdout decoded as UTF-8 (rule 6).
    @discardableResult
    static func run(_ path: String, _ args: [String], input: String? = nil) async -> (status: Int32, out: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
                let inPipe = Pipe()
                if input != nil { p.standardInput = inPipe }
                do { try p.run() } catch { cont.resume(returning: (-1, "")); return }
                if let input { inPipe.fileHandleForWriting.write(Data(input.utf8)); try? inPipe.fileHandleForWriting.close() }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    @discardableResult
    static func osascript(_ script: String) async -> (status: Int32, out: String) {
        await run("/usr/bin/osascript", ["-e", script])
    }
}

enum Keychain {
    private static let service = "com.shivam.notch"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true]
        var r: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    static func set(_ account: String, _ value: String?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = q; add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum Net {
    static func json(_ url: URL, headers: [String: String] = [:]) async throws -> Any {
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.setValue("Mozilla/5.0 (Macintosh) Notch", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let (data, _) = try await URLSession.shared.data(for: r)
        return try JSONSerialization.jsonObject(with: data)
    }
}

/// Tiny helpers for walking untyped JSON.
extension Optional where Wrapped == Any {
    subscript(_ k: String) -> Any? { (self as? [String: Any])?[k] }
    subscript(_ i: Int) -> Any? { guard let a = self as? [Any], a.indices.contains(i) else { return nil }; return a[i] }
    var str: String? { self as? String }
    var num: Double? { (self as? NSNumber)?.doubleValue ?? (self as? String).flatMap(Double.init) }
    var arr: [Any] { self as? [Any] ?? [] }
}
