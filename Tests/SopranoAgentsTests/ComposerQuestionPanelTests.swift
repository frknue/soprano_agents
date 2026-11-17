import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

/// The composer's question panel stays as wide as the composer gives it, however long the
/// question or its options are: a wider panel would widen the window.
@MainActor
struct ComposerQuestionPanelTests {
    @Test func longOptionsWrapInsteadOfWideningThePanel() {
        let sentence = String(repeating: "Shorten the test list to two characters per test so it fits GA4's limit. ", count: 6)
        let question = UserInputQuestion(
            id: "q", header: "", question: "Fix for drop-off per version",
            options: [UserInputOption(label: sentence, description: sentence), UserInputOption(label: "Measurement v2")],
            allowsOther: true, initialSelection: ["Measurement v2"]
        )
        let panel = ComposerQuestionPanel()
        panel.configure(question: question, index: 0, total: 1, selected: ["Measurement v2"], enabled: true)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        panel.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            panel.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()

        #expect(panel.fittingSize.width < 600)
        #expect(panel.frame.width == 600)
        // Wrapped onto several lines rather than cut to one.
        #expect(panel.frame.height > 150)
    }
}
