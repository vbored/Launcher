import Foundation

enum DebugTiming {
    static func mark(_ label: String) {
        let epoch = Date().timeIntervalSince1970
        let line = String(format: "%.4f  %@\n", epoch, label)
        guard let data = line.data(using: .utf8) else { return }
        let path = "/tmp/launcher_toggle_timing.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
