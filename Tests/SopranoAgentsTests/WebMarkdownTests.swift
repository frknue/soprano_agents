import AppKit
import JavaScriptCore
import Testing

/// The phone web app's Markdown renderer (`Remote/Web/js/markdown.js`), run in JavaScriptCore:
/// agent output must never become markup or a script link, and no input may make it loop.
struct WebMarkdownTests {
    /// The module's functions as globals (it has no imports; `export` is dropped).
    private static func context() throws -> JSContext {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SopranoAgents/Remote/Web/js/markdown.js")
        let source = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "export function", with: "function")
        let context = try #require(JSContext())
        context.evaluateScript(source)
        #expect(context.exception == nil)
        return context
    }

    private func render(_ context: JSContext, _ function: String, _ text: String) -> String {
        context.objectForKeyedSubscript(function).call(withArguments: [text]).toString()
    }

    @Test func placeholderDelimitersInAgentOutputCannotMakeAPlaceholderExpandItself() throws {
        let context = try Self.context()

        let output = render(context, "inline", "`x\u{0}0\u{0}` and \u{0}1\u{0}")

        #expect(output == "<code>x\u{FFFD}0\u{FFFD}</code> and \u{FFFD}1\u{FFFD}")
    }

    @Test func markupAndScriptLinksStayText() throws {
        let context = try Self.context()

        let html = render(context, "renderMarkdown", "<img src=x onerror=alert(1)> [a](javascript:alert(1)) [b](https://ok.example/\"x)")

        #expect(!html.contains("<img"))
        #expect(!html.contains("href=\"javascript"))
        #expect(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
        #expect(!html.contains("\"x\""))
    }
}
