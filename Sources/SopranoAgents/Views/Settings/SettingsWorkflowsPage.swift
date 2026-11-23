import AppKit
import SopranoAgentsCore

/// Settings › Workflows: opt-in cross-provider post-turn advisor reviews, auto-recaps, and
/// `/review-with` documentation.
extension SettingsController {
    func workflowsPage(_ form: SettingsForm) -> [NSView] {
        let workflows = center.settings.workflows
        let defaults = WorkflowSettings()

        func reset(_ key: String, isDefault: Bool) -> (() -> Void)? {
            isDefault ? nil : { [weak self] in self?.remove(["workflows", key]) }
        }

        let advisorToggle = form.toggle(workflows.advisorEnabled, label: "Enable post-turn advisor") { [weak self] isOn in
            self?.write(isOn, at: ["workflows", "advisorEnabled"])
        }

        let effectiveProvider = workflows.advisorProvider ?? center.settings.textGenerationProvider
        var providerOptions = [SelectOption(title: "Follow text generation (\(center.settings.textGenerationProvider.displayName))", value: "")]
        for (index, kind) in ProviderKind.allCases.enumerated() {
            providerOptions.append(SelectOption(title: kind.displayName, value: kind.rawValue, separatorBefore: index == 0))
        }
        let providerSelect = form.select(providerOptions, selected: workflows.advisorProvider?.rawValue ?? "", width: 224, label: "Advisor agent") { [weak self] value in
            if value.isEmpty {
                self?.remove(["workflows", "advisorProvider"])
                self?.remove(["workflows", "advisorModel"])
            } else {
                self?.write(value, at: ["workflows", "advisorProvider"])
                self?.remove(["workflows", "advisorModel"])
            }
        }

        let modelField = form.field(
            workflows.advisorModel ?? "",
            placeholder: "\(effectiveProvider.displayName) default",
            width: 224,
            identifier: "workflows.advisorModel",
            mono: true
        ) { [weak self] value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { self?.remove(["workflows", "advisorModel"]) } else { self?.write(trimmed, at: ["workflows", "advisorModel"]) }
        }

        let promptField = form.field(
            workflows.advisorPrompt,
            placeholder: "Check regressions, edge cases, and tests",
            width: 288,
            identifier: "workflows.advisorPrompt"
        ) { [weak self] value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { self?.remove(["workflows", "advisorPrompt"]) } else { self?.write(trimmed, at: ["workflows", "advisorPrompt"]) }
        }

        let recapToggle = form.toggle(workflows.autoRecapEnabled, label: "Auto-recap turns") { [weak self] isOn in
            self?.write(isOn, at: ["workflows", "autoRecapEnabled"])
        }

        return [
            form.section(
                "Post-turn advisor",
                note: "Opt-in second opinion: after any completed turn that edits files, a reviewer model inspects the diff and appends advisory notes without touching the agent's context.",
                [
                    form.row(
                        "Enable post-turn advisor",
                        description: "Run an automatic cross-provider diff review after turns that change files.",
                        reset: reset("advisorEnabled", isDefault: workflows.advisorEnabled == defaults.advisorEnabled),
                        control: advisorToggle
                    ),
                    form.row(
                        "Advisor agent",
                        description: "Provider CLI used for automatic post-turn reviews.",
                        reset: reset("advisorProvider", isDefault: workflows.advisorProvider == nil),
                        control: providerSelect
                    ),
                    form.row(
                        "Advisor model",
                        description: "Optional model slug for \(effectiveProvider.displayName); leave blank for its default model.",
                        reset: reset("advisorModel", isDefault: workflows.advisorModel == nil),
                        control: modelField
                    ),
                    form.row(
                        "Review criteria",
                        description: "Optional checklist or focus rules appended to both automatic advisor runs and /review-with.",
                        reset: reset("advisorPrompt", isDefault: workflows.advisorPrompt.isEmpty),
                        control: promptField
                    ),
                ]
            ),
            form.section("Summaries & on-demand reviews", [
                form.row(
                    "Auto-recap turns",
                    description: "Append a concise 2–3 bullet recap card after turns that change files.",
                    reset: reset("autoRecapEnabled", isDefault: workflows.autoRecapEnabled == defaults.autoRecapEnabled),
                    control: recapToggle
                ),
                form.row(
                    "On-demand cross-provider review",
                    description: "Send /review-with <provider>[/<model>] [focus] in any thread (for example /review-with codex or /review-with claude/opus check error handling) to get an advisory review card on the latest turn."
                ),
            ]),
        ]
    }
}
