import Foundation
import Testing
@testable import DevPilotCore

struct ADFConverterTests {
    func doc(_ content: JSONValue...) -> JSONValue {
        .object(["type": "doc", "version": 1, "content": .array(content)])
    }

    func node(_ type: String, attrs: [String: JSONValue]? = nil, _ content: JSONValue...) -> JSONValue {
        var object: [String: JSONValue] = ["type": .string(type), "content": .array(content)]
        if let attrs { object["attrs"] = .object(attrs) }
        return .object(object)
    }

    func text(_ value: String, marks: [String] = []) -> JSONValue {
        .object(["type": "text", "text": .string(value), "marks": .array(marks.map { .object(["type": .string($0)]) })])
    }

    @Test func nestedListsAreIndented() {
        let adf = doc(node("bulletList",
            node("listItem", node("paragraph", text("one")), node("orderedList", node("listItem", node("paragraph", text("nested"))))),
            node("listItem", node("paragraph", text("two")))
        ))
        #expect(ADFConverter.markdown(from: adf) == "- one\n  1. nested\n- two")
    }

    @Test func codeBlocksKeepLanguageAndText() {
        let adf = doc(node("codeBlock", attrs: ["language": "swift"], text("let x = 1")))
        #expect(ADFConverter.markdown(from: adf) == "```swift\nlet x = 1\n```")
    }

    @Test func tablesBecomeMarkdownTables() {
        let adf = doc(node("table",
            node("tableRow", node("tableHeader", node("paragraph", text("Plan"))), node("tableHeader", node("paragraph", text("Limit")))),
            node("tableRow", node("tableCell", node("paragraph", text("Free"))), node("tableCell", node("paragraph", text("100/min"))))
        ))
        #expect(ADFConverter.markdown(from: adf) == "| Plan | Limit |\n| --- | --- |\n| Free | 100/min |")
    }

    @Test func inlineNodesKeepTheirText() {
        let adf = doc(node("paragraph",
            text("bold", marks: ["strong"]), text(" "), text("old", marks: ["strike"]),
            .object(["type": "hardBreak"]),
            .object(["type": "status", "attrs": ["text": "BLOCKED"]]),
            .object(["type": "inlineCard", "attrs": ["url": "https://example.com/x"]])
        ))
        #expect(ADFConverter.markdown(from: adf) == "**bold** ~~old~~\n[BLOCKED]https://example.com/x")
    }

    @Test func unknownNodesFallBackToTheirContent() {
        let adf = doc(
            node("futureBlock", node("paragraph", text("inside future block"))),
            .object(["type": "futureInline", "attrs": ["text": "attr text"]])
        )
        #expect(ADFConverter.markdown(from: adf) == "inside future block\n\nattr text")
    }

    @Test func mediaBecomesPlaceholder() {
        let adf = doc(node("mediaSingle", .object(["type": "media", "attrs": ["alt": "screenshot.png"]])))
        #expect(ADFConverter.markdown(from: adf) == "[attachment: screenshot.png]")
    }

    @Test func nilAndPlainStrings() {
        #expect(ADFConverter.markdown(from: nil) == "")
        #expect(ADFConverter.markdown(from: .string("plain")) == "plain")
    }
}

struct AcceptanceCriteriaExtractorTests {
    @Test(arguments: [
        "## Acceptance Criteria\n- A\n- B\n\n## Notes\nignored",
        "**Acceptance criteria:**\n* A\n* B\n**Out of scope**\nignored",
        "Intro\n\nAcceptance Criteria:\n1. A\n2. B\n# Next",
        "### acceptance criteria\n- [ ] A\n- [x] B",
    ])
    func extractsUnderHeading(markdown: String) {
        #expect(AcceptanceCriteriaExtractor.extract(fromMarkdown: markdown) == ["A", "B"])
    }

    @Test func inlineCriterionAfterColon() {
        #expect(AcceptanceCriteriaExtractor.extract(fromMarkdown: "Acceptance criteria: works offline") == ["works offline"])
    }

    @Test func noHeadingMeansNoCriteria() {
        #expect(AcceptanceCriteriaExtractor.extract(fromMarkdown: "Search should be better.").isEmpty)
    }
}

struct APIDateTests {
    @Test func parsesJiraAndShortcutFormats() {
        #expect(APIDate.parse("2026-10-27T10:15:30.123+0900") == Date(timeIntervalSince1970: 1_793_063_730.123))
        #expect(APIDate.parse("2026-10-28T01:15:30Z") == Date(timeIntervalSince1970: 1_793_150_130))
        #expect(APIDate.parse("2026-10-28T01:15:30.500Z") == Date(timeIntervalSince1970: 1_793_150_130.5))
        #expect(APIDate.parse("yesterday") == nil)
    }
}
