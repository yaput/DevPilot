import Foundation

/// Converts Atlassian Document Format to Markdown, keeping every piece of text it can find.
/// Unknown node types fall back to their children or their `text` attribute, so new ADF
/// features degrade to plain text instead of disappearing.
public enum ADFConverter {
    public static func markdown(from document: JSONValue?) -> String {
        guard let document else { return "" }
        if let text = document.string { return text }  // Some fields are plain strings.
        return blocks(document["content"]?.array ?? [])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func blocks(_ nodes: [JSONValue]) -> String {
        nodes.map(block).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func block(_ node: JSONValue) -> String {
        let content = node["content"]?.array ?? []
        let attrs = node["attrs"]
        switch node["type"]?.string {
        case "paragraph":
            return inline(content)
        case "heading":
            let level = max(1, min(6, Int(attrs?["level"]?.number ?? 2)))
            return String(repeating: "#", count: level) + " " + inline(content)
        case "bulletList":
            return list(content) { _ in "- " }
        case "orderedList":
            let start = Int(attrs?["order"]?.number ?? 1)
            return list(content) { "\(start + $0). " }
        case "taskList":
            return content.map { item in
                let done = item["attrs"]?["state"]?.string == "DONE"
                return (done ? "- [x] " : "- [ ] ") + inline(item["content"]?.array ?? [])
            }.joined(separator: "\n")
        case "decisionList":
            return content.map { "- " + inline($0["content"]?.array ?? []) }.joined(separator: "\n")
        case "codeBlock":
            let language = attrs?["language"]?.string ?? ""
            return "```\(language)\n\(content.compactMap { $0["text"]?.string }.joined())\n```"
        case "blockquote":
            return quote(blocks(content))
        case "panel":
            let kind = attrs?["panelType"]?.string.map { $0.capitalized + ": " } ?? ""
            return quote("**\(kind)**" + blocks(content))
        case "rule":
            return "---"
        case "table":
            return table(content)
        case "expand", "nestedExpand":
            let title = attrs?["title"]?.string ?? ""
            return (title.isEmpty ? "" : "**\(title)**\n\n") + blocks(content)
        case "mediaSingle", "mediaGroup", "media":
            let name = attrs?["alt"]?.string ?? content.first?["attrs"]?["alt"]?.string
            return "[attachment\(name.map { ": \($0)" } ?? "")]"
        default:
            if !content.isEmpty {
                return content.contains(where: isBlock) ? blocks(content) : inline(content)
            }
            return inlineNode(node)
        }
    }

    private static func list(_ items: [JSONValue], marker: (Int) -> String) -> String {
        items.enumerated().map { index, item in
            let parts = (item["content"]?.array ?? []).map(block).filter { !$0.isEmpty }
            let prefix = marker(index)
            let indent = String(repeating: " ", count: prefix.count)
            let body = parts.joined(separator: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .map { $0.offset == 0 ? String($0.element) : indent + $0.element }
                .joined(separator: "\n")
            return prefix + body
        }.joined(separator: "\n")
    }

    private static func table(_ rows: [JSONValue]) -> String {
        var lines: [String] = []
        for (index, row) in rows.enumerated() {
            let cells = (row["content"]?.array ?? []).map { cell in
                blocks(cell["content"]?.array ?? [])
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "|", with: "\\|")
            }
            lines.append("| " + cells.joined(separator: " | ") + " |")
            if index == 0 {
                lines.append("|" + String(repeating: " --- |", count: max(cells.count, 1)))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func quote(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
    }

    private static func inline(_ nodes: [JSONValue]) -> String {
        nodes.map(inlineNode).joined()
    }

    private static func inlineNode(_ node: JSONValue) -> String {
        let attrs = node["attrs"]
        switch node["type"]?.string {
        case "text":
            return applyMarks(node["text"]?.string ?? "", marks: node["marks"]?.array ?? [])
        case "hardBreak":
            return "\n"
        case "mention":
            let text = attrs?["text"]?.string ?? "someone"
            return text.hasPrefix("@") ? text : "@" + text
        case "emoji":
            return attrs?["text"]?.string ?? attrs?["shortName"]?.string ?? ""
        case "inlineCard", "blockCard", "embedCard":
            return attrs?["url"]?.string ?? ""
        case "date":
            guard let raw = attrs?["timestamp"]?.string, let millis = Double(raw) else { return "" }
            return Date(timeIntervalSince1970: millis / 1000).formatted(.iso8601.year().month().day())
        case "status":
            return "[\(attrs?["text"]?.string ?? "")]"
        default:
            if let content = node["content"]?.array, !content.isEmpty {
                return content.contains(where: isBlock) ? blocks(content) : inline(content)
            }
            return attrs?["text"]?.string ?? node["text"]?.string ?? ""
        }
    }

    private static func applyMarks(_ text: String, marks: [JSONValue]) -> String {
        guard !text.isEmpty else { return text }
        return marks.reduce(text) { result, mark in
            switch mark["type"]?.string {
            case "code": "`\(result)`"
            case "strong": "**\(result)**"
            case "em": "*\(result)*"
            case "strike": "~~\(result)~~"
            case "link": mark["attrs"]?["href"]?.string.map { "[\(result)](\($0))" } ?? result
            default: result
            }
        }
    }

    private static let blockTypes: Set<String> = [
        "paragraph", "heading", "bulletList", "orderedList", "taskList", "decisionList", "codeBlock",
        "blockquote", "panel", "rule", "table", "expand", "nestedExpand", "mediaSingle", "mediaGroup",
    ]

    private static func isBlock(_ node: JSONValue) -> Bool {
        node["type"]?.string.map(blockTypes.contains) ?? false
    }
}

public enum AcceptanceCriteriaExtractor {
    /// Finds an "Acceptance criteria" heading (Markdown heading, bold line or `Label:`) and returns
    /// the lines under it up to the next heading, with list and checkbox markers removed.
    public static func extract(fromMarkdown markdown: String) -> [String] {
        let lines = markdown.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { headingLabel($0)?.hasPrefix("acceptance criteria") == true }) else {
            return []
        }
        var criteria: [String] = []
        if let colon = lines[start].firstIndex(of: ":") {
            let inlineRest = lines[start][lines[start].index(after: colon)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: "* ").union(.whitespaces))
            if !inlineRest.isEmpty { criteria.append(inlineRest) }
        }
        for line in lines[(start + 1)...] {
            if isHeading(line) { break }
            let item = stripListMarker(line)
            if !item.isEmpty { criteria.append(item) }
        }
        return criteria
    }

    /// Splits free text (e.g. a dedicated Jira field) into one criterion per non-empty line.
    public static func items(fromText text: String) -> [String] {
        text.components(separatedBy: .newlines).map(stripListMarker).filter { !$0.isEmpty }
    }

    private static func isHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { return true }
        // A line that is entirely bold, e.g. "**Notes**" or "**Out of scope:**".
        return trimmed.count > 4 && trimmed.hasPrefix("**") && (trimmed.hasSuffix("**") || trimmed.hasSuffix("**:"))
    }

    /// "## Acceptance Criteria", "**Acceptance criteria:**", "Acceptance Criteria: x" → "acceptance criteria…".
    private static func headingLabel(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let label = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#*_ "))
        guard !label.isEmpty else { return nil }
        let lowered = label.lowercased()
        return isHeading(trimmed) || lowered.hasPrefix("acceptance criteria") ? lowered : nil
    }

    private static func stripListMarker(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if let match = text.firstMatch(of: /^(?:[-*+•]|\d+[.)])\s+/) {
            text.removeSubrange(match.range)
        }
        if let match = text.firstMatch(of: /^\[[ xX]\]\s*/) {
            text.removeSubrange(match.range)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
