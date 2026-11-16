import Foundation

/// Lock file in ~/.notch, held for the life of the process (the OS releases it on exit or crash).
enum SingleInstance {
    private static var fd: Int32 = -1

    static func acquire() -> Bool {
        let dir = Paths.home
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fd = open(dir.appendingPathComponent("notch.lock").path, O_CREAT | O_RDWR, 0o644)
        if fd < 0 { return true }               // can't lock: run anyway rather than never start
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }
}

enum Paths {
    /// ~/.notch holds transcripts, clipboard history and the API token: owner-only (0700).
    static let home: URL = {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".notch", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: u.path)
        return u
    }()
}
