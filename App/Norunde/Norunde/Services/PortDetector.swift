import Foundation

/// Extract local dev URLs / ports from process logs (Vite / Next / webpack etc.).
enum PortDetector {
    struct Detection: Equatable, Sendable {
        var url: URL
        var port: Int?
        var host: String

        var display: String {
            if let port { return "\(host):\(port)" }
            return url.absoluteString
        }
    }

    /// Prefer localhost / 127.0.0.1 / 0.0.0.0 over LAN IPs; later lines win within same preference.
    static func detect(from lines: [String]) -> Detection? {
        var best: (score: Int, detection: Detection)?

        for text in lines {
            for url in extractURLs(in: text) {
                guard let host = url.host?.lowercased(), !host.isEmpty else { continue }
                let scheme = (url.scheme ?? "http").lowercased()
                guard scheme == "http" || scheme == "https" else { continue }

                var score = 10
                if host == "localhost" || host == "127.0.0.1" { score += 100 }
                else if host == "0.0.0.0" || host == "[::]" || host == "::" { score += 80 }
                else if host.hasPrefix("192.168.") || host.hasPrefix("10.") { score += 20 }

                let port = url.port ?? defaultPort(for: scheme)
                // Prefer common dev ports slightly.
                if let port, [3000, 3100, 5173, 8080, 4173, 8000].contains(port) {
                    score += 5
                }

                let openURL: URL = {
                    // 0.0.0.0 is not useful in a browser — rewrite to localhost.
                    if host == "0.0.0.0" || host == "[::]" || host == "::" {
                        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                        components?.host = "localhost"
                        if let rewritten = components?.url { return rewritten }
                    }
                    return url
                }()

                let detection = Detection(url: openURL, port: port, host: openURL.host ?? host)
                if best == nil || score >= best!.score {
                    best = (score, detection)
                }
            }
        }
        return best?.detection
    }

    static func detect(fromLogLines lines: [LogLine]) -> Detection? {
        detect(from: lines.map(\.text))
    }

    // MARK: - Private

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private static func extractURLs(in text: String) -> [URL] {
        var urls: [URL] = []

        // Fast path: NSDataDetector
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            detector.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                if let url = match?.url {
                    urls.append(url)
                }
            }
        }

        // Fallback regex for patterns detector sometimes misses in ANSI-ish lines
        if urls.isEmpty,
           let regex = try? NSRegularExpression(
            pattern: #"https?://[^\s\"'<>]+"#,
            options: [.caseInsensitive]
           ) {
            let ns = text as NSString
            let range = NSRange(location: 0, length: ns.length)
            regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let match, let r = Range(match.range, in: text) else { return }
                var raw = String(text[r])
                // Trim trailing punctuation common in logs
                while let last = raw.last, ".,);]".contains(last) {
                    raw.removeLast()
                }
                if let url = URL(string: raw) {
                    urls.append(url)
                }
            }
        }

        return urls
    }
}
