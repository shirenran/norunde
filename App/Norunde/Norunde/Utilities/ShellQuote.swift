import Foundation

enum ShellQuote {
    /// Quote a string so it is safe as a single argument in a zsh/bash command.
    static func quote(_ value: String) -> String {
        if value.isEmpty {
            return "''"
        }
        // Prefer single quotes; escape embedded single quotes with '\'' pattern.
        if !value.contains("'") {
            return "'\(value)'"
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
