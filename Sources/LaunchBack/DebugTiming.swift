import Foundation

enum DebugTiming {
    /// Synchronous file I/O on the main thread — compiled out of release
    /// builds so it never sits on the toggle path users actually feel.
    static func mark(_ label: String) {
        #if DEBUG
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
        #endif
    }
}
