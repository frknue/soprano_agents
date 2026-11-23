import AppKit
import SopranoAgentsCore

/// Provider marks: omp's "π", OpenCode's framed block and Antigravity's arch. Template images
/// (tint with `contentTintColor`).
@MainActor
enum ProviderGlyph {
    /// The mark at `size` points.
    static func image(for kind: ProviderKind, size: CGFloat = 14) -> NSImage {
        let key = "\(kind.rawValue)-\(size)-\(PaletteCenter.shared.palette.isDark)"
        if let cached = cache[key] { return cached }
        let image = switch kind {
        case .omp: renderPi(size: size)
        case .opencode: renderOpencode(size: size)
        case .antigravity: renderArch(size: size)
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

    /// Antigravity's mark: an arch rising from two feet to a rounded apex, stroked with round
    /// caps.
    private static func renderArch(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let stroke = max(1.6, size * 0.15)
            let inset = stroke / 2 + size * 0.08
            let bottom = rect.minY + inset
            let top = rect.maxY - inset
            let left = rect.minX + inset
            let right = rect.maxX - inset
            let path = NSBezierPath()
            path.move(to: NSPoint(x: left, y: bottom))
            path.curve(
                to: NSPoint(x: rect.midX, y: top),
                controlPoint1: NSPoint(x: left + (rect.midX - left) * 0.35, y: bottom + (top - bottom) * 0.55),
                controlPoint2: NSPoint(x: rect.midX - size * 0.12, y: top)
            )
            path.curve(
                to: NSPoint(x: right, y: bottom),
                controlPoint1: NSPoint(x: rect.midX + size * 0.12, y: top),
                controlPoint2: NSPoint(x: right - (right - rect.midX) * 0.35, y: bottom + (top - bottom) * 0.55)
            )
            path.lineWidth = stroke
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
    }
}
