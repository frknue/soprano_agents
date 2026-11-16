import AppKit

/// `/theme.css` for the web app: the palette in force as CSS variables named after the
/// `Palette` properties in kebab-case (`messageSurface` → `--message-surface`), plus
/// `color-scheme`.
enum RemoteTheme {
    static func css(_ palette: Palette) -> String {
        var colors: [(String, NSColor)] = [
            ("background", palette.background),
            ("foreground", palette.foreground),
            ("card", palette.card),
            ("popover", palette.popover),
            ("secondary", palette.secondary),
            ("muted", palette.muted),
            ("accent", palette.accent),
            ("border", palette.border),
            ("input", palette.input),
            ("muted-foreground", palette.mutedForeground),
            ("secondary-label", palette.secondaryLabel),
            ("placeholder", palette.placeholder),
            ("primary", palette.primary),
            ("primary-foreground", palette.primaryForeground),
            ("message-surface", palette.messageSurface),
            ("message-foreground", palette.messageForeground),
            ("sidebar", palette.sidebar),
            ("sidebar-foreground", palette.sidebarForeground),
            ("sidebar-muted-foreground", palette.sidebarMutedForeground),
            ("sidebar-row-active", palette.sidebarRowActive),
            ("sidebar-row-selected", palette.sidebarRowSelected),
            ("sidebar-border", palette.sidebarBorder),
            ("error", palette.error),
            ("error-foreground", palette.errorForeground),
            ("warning", palette.warning),
            ("warning-foreground", palette.warningForeground),
            ("success", palette.success),
            ("success-foreground", palette.successForeground),
            ("info", palette.info),
            ("info-foreground", palette.infoForeground),
            ("input-foreground", palette.inputForeground),
            ("merged-foreground", palette.mergedForeground),
            ("diff-addition-foreground", palette.diffAdditionForeground),
            ("diff-deletion-foreground", palette.diffDeletionForeground),
            ("diff-addition-background", palette.diffAdditionBackground),
            ("diff-deletion-background", palette.diffDeletionBackground),
            ("diff-addition-word", palette.diffAdditionWord),
            ("diff-deletion-word", palette.diffDeletionWord),
            ("code-background", palette.codeBackground),
            ("terminal-background", palette.terminalBackground),
            ("terminal-foreground", palette.terminalForeground),
            ("terminal-cursor", palette.terminalCursor),
            ("terminal-selection", palette.terminalSelection),
        ]
        for (index, color) in palette.terminalANSI.prefix(16).enumerated() {
            colors.append(("terminal-ansi-\(index)", color))
        }
        var lines = [":root {", "  color-scheme: \(palette.isDark ? "dark" : "light");"]
        for (name, color) in colors { lines.append("  --\(name): \(cssColor(color));") }
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    /// `#rrggbb`, or `rgba(r, g, b, a)` when not opaque (sRGB).
    static func cssColor(_ color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? NSColor.black
        func byte(_ value: CGFloat) -> Int { Int((max(0, min(1, value)) * 255).rounded()) }
        let (r, g, b) = (byte(srgb.redComponent), byte(srgb.greenComponent), byte(srgb.blueComponent))
        if srgb.alphaComponent >= 0.999 { return String(format: "#%02x%02x%02x", r, g, b) }
        return String(format: "rgba(%d, %d, %d, %.3f)", r, g, b, srgb.alphaComponent)
    }
}
