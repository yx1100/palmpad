import Foundation

/// Plain-text log plus a status snapshot in ~/Library/Logs/MTM, readable from a terminal while debugging.
enum Log {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MTM")
    private static let q = DispatchQueue(label: "mtm.log", qos: .utility)
    private static let file: FileHandle? = {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mtm.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        q.async { file?.write(Data(line.utf8)) }
    }

    static func status(_ values: [String: Any]) {
        q.async {
            guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) else { return }
            try? data.write(to: dir.appendingPathComponent("status.json"), options: .atomic)
        }
    }
}
