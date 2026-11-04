import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

struct ComposerModelChoiceTests {
    private let opus = ProviderModel(
        slug: "anthropic/claude-opus-5-5",
        name: "Claude Opus 5.5 · anthropic",
        options: [
            ProviderCatalog.effortOption(["off", "low", "medium", "high", "xhigh", "max"], default: "high"),
            ModelOption(id: ModelOptionID.fastMode, label: "Fast mode", kind: .boolean, defaultValue: "false"),
        ]
    )
    private let haiku = ProviderModel(
        slug: "anthropic/claude-haiku-5-5",
        name: "Claude Haiku 5.5 · anthropic",
        options: [ProviderCatalog.effortOption(["low", "medium"], default: "medium")]
    )
    private var status: ProviderStatus { ProviderStatus(kind: .omp, health: .ready, models: [opus, haiku]) }

    @Test func pickingAnotherModelKeepsOnlyTheOptionValuesItSupports() {
        let current = ModelSelection(provider: .omp, model: opus.slug, options: ["effort": "xhigh", "fastMode": "true"])
        #expect(ModelChoice.selecting(haiku, of: .omp, from: current) == ModelSelection(provider: .omp, model: haiku.slug))

        let medium = ModelSelection(provider: .omp, model: opus.slug, options: ["effort": "medium", "fastMode": "true"])
        #expect(ModelChoice.selecting(haiku, of: .omp, from: medium).options == ["effort": "medium"])
        #expect(ModelChoice.selecting(opus, of: .omp, from: medium) == medium)
    }

    @Test func pickingAnOpencodeModelSwitchesTheSelectionsProvider() {
        let opencodeOpus = ProviderModel(
            slug: "claude-agent/opus",
            name: "Opus 5.5 · claude-agent",
            options: [ProviderCatalog.effortOption(["low", "medium", "high"], default: "high")]
        )
        let current = ModelSelection(provider: .omp, model: opus.slug, options: ["effort": "medium", "fastMode": "true"])
        let picked = ModelChoice.selecting(opencodeOpus, of: .opencode, from: current)
        #expect(picked == ModelSelection(provider: .opencode, model: "claude-agent/opus", options: ["effort": "medium"]))

        let opencode = ProviderStatus(kind: .opencode, health: .ready, models: [opencodeOpus])
        #expect(ModelChoice.model(for: picked, status: opencode) == opencodeOpus)
        #expect(ModelChoice.chipTitle(ModelSelection.default(for: .opencode), status: nil) == "OpenCode default")
    }

    @Test func aThreadWithTurnsKeepsItsAgentWhileDraftsAndEmptyThreadsMaySwitch() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let selection = ModelSelection(provider: .opencode, model: "claude-agent/opus")
        var thread = AgentThread(id: "t", projectID: nil, title: "T", createdAt: now, modelSelection: selection)
        #expect(ModelChoice.lockedProvider(of: nil) == nil)
        #expect(ModelChoice.lockedProvider(of: thread) == nil)

        thread.turns = [Turn(ordinal: 1, userMessage: UserMessage(text: "Hi", createdAt: now), modelSelection: selection, status: .completed, startedAt: now)]
        let locked = ModelChoice.lockedProvider(of: thread)
        #expect(locked == .opencode)
        #expect(ModelChoice.lockReason(.opencode, lockedTo: locked) == nil)
        #expect(ModelChoice.lockReason(.omp, lockedTo: locked) == "This thread runs on OpenCode; start a new thread to use omp.")
        #expect(ModelChoice.lockReason(.omp, lockedTo: nil) == nil)
    }

    @Test func unknownOptionsAndInvalidValuesAreDropped() {
        let options = ModelChoice.supportedOptions(["effort": "turbo", "fastMode": "yes", "serviceTier": "flex", "verbosity": "low"], for: opus)
        #expect(options.isEmpty)
    }

    @Test func aProbedCatalogReplacesTheFallbackOnceItHasModels() {
        let live = ProviderModel(slug: "anthropic/claude-opus-6", name: "Claude Opus 6 · anthropic", isDefault: true)
        let probed = ProviderStatus(kind: .omp, health: .ready, models: [live])
        #expect(ModelChoice.models(for: .omp, status: probed) == [live])
        #expect(ModelChoice.model(for: ModelSelection(provider: .omp, model: live.slug), status: probed) == live)
        #expect(ModelChoice.models(for: .omp, status: ProviderStatus(kind: .omp)) == ProviderCatalog.fallback(.omp))
        #expect(ModelChoice.models(for: .omp, status: nil) == ProviderCatalog.fallback(.omp))
        #expect(ModelChoice.models(for: .opencode, status: nil) == ProviderCatalog.fallback(.opencode))
    }

    @Test func theModelChipTitleNamesTheModelAndTheEffortInEffect() {
        let explicit = ModelSelection(provider: .omp, model: opus.slug, options: ["effort": "low"])
        #expect(ModelChoice.chipTitle(explicit, status: status) == "Claude Opus 5.5 · anthropic · Low")

        let implicit = ModelSelection(provider: .omp, model: haiku.slug)
        #expect(ModelChoice.chipTitle(implicit, status: status) == "Claude Haiku 5.5 · anthropic · Medium")

        let fast = ModelSelection(provider: .omp, model: opus.slug, options: ["effort": "xhigh", "fastMode": "true"])
        #expect(ModelChoice.chipTitle(fast, status: status) == "Claude Opus 5.5 · anthropic · Extra High · Fast")

        #expect(ModelChoice.chipTitle(ModelSelection.default(for: .omp), status: nil) == "omp default")
    }

    @Test func anEffortTheModelDoesNotOfferFallsBackToItsDefault() {
        let selection = ModelSelection(provider: .omp, model: haiku.slug, options: ["effort": "max"])
        #expect(ModelChoice.effectiveEffort(selection, model: haiku) == "medium")
    }

    @Test func anUnknownModelKeepsItsSlugNameAndExplicitEffort() {
        let selection = ModelSelection(provider: .omp, model: "openrouter/qwen/qwen3-coder", options: ["effort": "high"])
        #expect(ModelChoice.chipTitle(selection, status: nil) == "openrouter/qwen/qwen3-coder · High")
    }
}
