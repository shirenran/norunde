import AppKit
import SwiftUI

struct LogView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let projectId: UUID

    @State private var autoScroll = true

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    var body: some View {
        let lines = viewModel.logs(for: projectId)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("日志")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("自动滚动", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                Button("清空") {
                    if let project = viewModel.projects.first(where: { $0.id == projectId }) {
                        viewModel.clearLogs(for: project)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if lines.isEmpty {
                            Text("暂无日志")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)
                        } else {
                            ForEach(lines) { line in
                                logRow(line)
                                    .id(line.id)
                            }
                        }
                        Color.clear.frame(height: 1).id("log-bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .onChange(of: viewModel.logRevision) { _, _ in
                    guard autoScroll else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo("log-bottom", anchor: .bottom)
                    }
                }
                .onAppear {
                    if autoScroll {
                        proxy.scrollTo("log-bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    private func logRow(_ line: LogLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.timeFormatter.string(from: line.timestamp))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)

            Text(attributedText(for: line))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.openURL, OpenURLAction { url in
                    NSWorkspace.shared.open(url)
                    return .handled
                })
        }
    }

    private func attributedText(for line: LogLine) -> AttributedString {
        let baseColor: Color = {
            switch line.stream {
            case .stdout: return .primary
            case .stderr: return .orange
            case .system: return .secondary
            }
        }()

        var attributed = AttributedString(line.text)
        attributed.foregroundColor = baseColor

        guard let detector = Self.linkDetector else { return attributed }

        let nsText = line.text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = detector.matches(in: line.text, options: [], range: fullRange)

        for match in matches {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: line.text),
                  let attrRange = Range(stringRange, in: attributed) else {
                continue
            }
            // Skip non-http(s) schemes that are noisy in logs (mailto etc. still ok if present).
            let scheme = url.scheme?.lowercased() ?? ""
            guard scheme == "http" || scheme == "https" else { continue }

            attributed[attrRange].link = url
            attributed[attrRange].foregroundColor = Color.accentColor
            attributed[attrRange].underlineStyle = .single
        }

        return attributed
    }
}
