import Foundation

final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    private let queue = DispatchQueue(label: "solixmenu.logger", qos: .utility)
    private let dateFormatter = ISO8601DateFormatter()
    private var fileHandle: FileHandle?
    private var fileLoggingEnabled: Bool

    private init() {
        fileLoggingEnabled = UserDefaults.standard.bool(forKey: AppSettingsKeys.debugLogEnabled)
        if fileLoggingEnabled {
            queue.async { [weak self] in
                self?.openFileHandleIfNeeded()
            }
        }
    }

    static func log(_ message: String) {
        shared.log(message)
    }

    func setFileLoggingEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.fileLoggingEnabled = enabled
            if enabled {
                self.openFileHandleIfNeeded()
            } else {
                self.closeFileHandle()
            }
        }
    }

    private func log(_ message: String) {
        NSLog("%@", message)
        queue.async { [weak self] in
            guard let self, self.fileLoggingEnabled else { return }
            self.openFileHandleIfNeeded()
            guard let data = self.formatLine(message).data(using: .utf8) else { return }
            self.fileHandle?.seekToEndOfFile()
            self.fileHandle?.write(data)
        }
    }

    private func formatLine(_ message: String) -> String {
        let timestamp = dateFormatter.string(from: Date())
        return "[\(timestamp)] \(message)\n"
    }

    private func openFileHandleIfNeeded() {
        guard fileHandle == nil else { return }
        guard let url = logFileURL() else { return }
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
    }

    private func closeFileHandle() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func logFileURL() -> URL? {
        guard
            let library = FileManager.default.urls(
                for: .libraryDirectory,
                in: .userDomainMask
            ).first
        else {
            return nil
        }
        let folder =
            library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("SolixMenu", isDirectory: true)
        return folder.appendingPathComponent("SolixMenu.log")
    }
}
