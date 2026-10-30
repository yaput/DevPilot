import SwiftUI

/// Renders the Markdown DevPilot produces and receives: headings, lists, code blocks, quotes,
/// tables and paragraphs, with inline formatting. Not a full CommonMark renderer.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text):
            inline(text)
        case .listItem(let marker, let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).monospacedDigit().foregroundStyle(.secondary)
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * 8)
        case .quote(let text):
            inline(text)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 3) }
        case .code(let text), .table(let text):
            Text(text)
                .font(.callout.monospaced())
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }
}

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(marker: String, indent: Int, text: String)
    case quote(String)
    case code(String)
    case table(String)
    case rule

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        var table: [String] = []

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            if !table.isEmpty { blocks.append(.table(table.joined(separator: "\n"))) }
            paragraph = []
            table = []
        }

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }
            if trimmed.isEmpty {
                flush()
            } else if trimmed.hasPrefix("|") {
                if !paragraph.isEmpty { flush() }
                table.append(trimmed)
            } else if let match = trimmed.wholeMatch(of: /(#{1,6})\s+(.*)/) {
                flush()
                blocks.append(.heading(level: match.1.count, text: String(match.2)))
            } else if trimmed == "---" || trimmed == "***" {
                flush()
                blocks.append(.rule)
            } else if let match = line.wholeMatch(of: /(\s*)([-*+]|\d+[.)])\s+(.*)/) {
                flush()
                var marker = String(match.2)
                var text = String(match.3)
                if let box = text.wholeMatch(of: /\[([ xX])\]\s*(.*)/) {
                    marker = box.1 == " " ? "☐" : "☑"
                    text = String(box.2)
                } else if marker.count == 1 {
                    marker = "•"
                }
                blocks.append(.listItem(marker: marker, indent: match.1.count / 2, text: text))
            } else if trimmed.hasPrefix(">") {
                flush()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                if !table.isEmpty { flush() }
                paragraph.append(trimmed)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}
