import Foundation

/// Built-in model catalogs: what the app offers before a provider's first probe replaces it with
/// the live catalog (omp `get_available_models`, OpenCode `GET /api/model`).
public enum ProviderCatalog {
    /// Before the first probe a provider offers only "its configured default".
    public static func fallback(_ kind: ProviderKind) -> [ProviderModel] {
        [ProviderModel(slug: ModelSelection.configuredDefaultModel, name: defaultModelName(kind), isDefault: true)]
    }

    /// "omp default", "OpenCode default": the CLI's configured model before its name is known.
    public static func defaultModelName(_ kind: ProviderKind) -> String {
        "\(kind.displayName) default"
    }

    /// Labels for thinking levels (omp) and model variants (OpenCode).
    public static func effortLabel(_ id: String) -> String {
        switch id {
        case "minimal": "Minimal"
        case "low": "Low"
        case "medium": "Medium"
        case "high": "High"
        case "xhigh": "Extra High"
        case "max": "Max"
        default: id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    public static func effortOption(_ ids: [String], default defaultID: String, label: String = "Reasoning") -> ModelOption {
        ModelOption(
            id: ModelOptionID.effort,
            label: label,
            kind: .select,
            choices: ids.map { ModelOptionChoice(id: $0, label: effortLabel($0)) },
            defaultValue: defaultID
        )
    }

    /// Display name for a selection, falling back to the slug.
    public static func displayName(for selection: ModelSelection, in status: ProviderStatus?) -> String {
        if let model = (status?.models ?? fallback(selection.provider)).first(where: { $0.slug == selection.model }) {
            return model.name
        }
        return selection.model == ModelSelection.configuredDefaultModel ? defaultModelName(selection.provider) : selection.model
    }
}
