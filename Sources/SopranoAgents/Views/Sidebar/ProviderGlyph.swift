import AppKit
import SopranoAgentsCore

/// Provider marks: omp's "π" and OpenCode's framed block. Template images (tint with
/// `contentTintColor`).
@MainActor
enum ProviderGlyph {
    /// The mark at `size` points.
    static func image(for kind: ProviderKind, size: CGFloat = 14) -> NSImage {
        let key = "\(kind.rawValue)-\(size)-\(PaletteCenter.shared.palette.isDark)"
        if let cached = cache[key] { return cached }
        let image = switch kind {
        case .omp: renderPi(size: size)
        case .opencode: renderOpencode(size: size)
        }
        image.isTemplate = true
        image.accessibilityDescription = kind.displayName
        cache[key] = image
        return image
    }

    private static var cache: [String: NSImage] = [:]

    /// omp (oh-my-pi) has no vector mark: a bold "π" set in the system font, template-rendered.
    private static func renderPi(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let font = NSFont.systemFont(ofSize: size * 1.05, weight: .heavy)
            let text = NSAttributedString(string: "π", attributes: [.font: font, .foregroundColor: NSColor.black])
            let bounds = text.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading])
            text.draw(at: NSPoint(x: (rect.width - bounds.width) / 2, y: (rect.height - bounds.height) / 2 - size * 0.06))
            return true
        }
    }

    /// OpenCode's mark: an upright frame whose lower half holds a lighter block (half alpha, so
    /// the template tint keeps the two tones), drawn on whole points so it stays crisp at 14–20 pt.
    private static func renderOpencode(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let height = (rect.height * 0.8).rounded()
            let width = (height * 0.8).rounded()
            let stroke = max(1.5, (size * 0.11).rounded())
            let frame = NSRect(
                x: ((rect.width - width) / 2).rounded(),
                y: ((rect.height - height) / 2).rounded(),
                width: width,
                height: height
            )
            let inner = frame.insetBy(dx: stroke, dy: stroke)
            let path = NSBezierPath(rect: frame)
            path.append(NSBezierPath(rect: inner))
            path.windingRule = .evenOdd
            NSColor.black.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.5).setFill()
            NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: (inner.height / 2).rounded()).fill()
            return true
        }
    }
}
