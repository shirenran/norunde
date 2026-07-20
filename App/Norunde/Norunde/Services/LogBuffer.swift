import Foundation

enum LogStream: String, Codable, Equatable {
    case stdout
    case stderr
    case system
}

struct LogLine: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let stream: LogStream
    let text: String

    init(id: UUID = UUID(), timestamp: Date = Date(), stream: LogStream, text: String) {
        self.id = id
        self.timestamp = timestamp
        self.stream = stream
        self.text = text
    }
}

/// Ring buffer of recent log lines for one project.
final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [LogLine] = []
    private let capacity: Int

    init(capacity: Int = 2000) {
        self.capacity = max(1, capacity)
    }

    func append(stream: LogStream, text: String, timestamp: Date = Date()) {
        let chunks = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lock.lock()
        defer { lock.unlock() }
        for (index, chunk) in chunks.enumerated() {
            // Skip trailing empty fragment from split when text ends with \n
            if index == chunks.count - 1 && chunk.isEmpty && text.hasSuffix("\n") {
                continue
            }
            if chunk.isEmpty && chunks.count > 1 {
                // keep empty lines that appear between newlines
            }
            lines.append(LogLine(timestamp: timestamp, stream: stream, text: chunk))
            if lines.count > capacity {
                lines.removeFirst(lines.count - capacity)
            }
        }
    }

    func appendSystem(_ text: String) {
        append(stream: .system, text: text)
    }

    func clear() {
        lock.lock()
        lines.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func snapshot() -> [LogLine] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return lines.count
    }
}
