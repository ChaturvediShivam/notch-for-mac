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
    static let home = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".notch", isDirectory: true)
}
