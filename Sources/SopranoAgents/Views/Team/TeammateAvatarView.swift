import AppKit
import SopranoAgentsCore

/// A teammate's avatar: the name's initial on a 16 % tint of an accent hue, in a circle. The
/// hue comes from the handle (`TeammateIdentity.colorIndex`), so it stays put when the name
/// changes and differs between teammates.
final class TeammateAvatarView: PaletteView {
    private var name = ""
    private var handle = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyPalette(palette)
    }

    func configure(name: String, handle: String) {
        guard name != self.name || handle != self.handle else { return }
        self.name = name
        self.handle = handle
        needsDisplay = true
    }

    override func applyPalette(_ palette: Palette) {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = palette.projectIconColors
        guard !colors.isEmpty else { return }
        let color = colors[TeammateIdentity.colorIndex(handle, count: colors.count)]
        let side = min(bounds.width, bounds.height)
        let circle = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        color.alphaScaled(by: 0.16).setFill()
        NSBezierPath(ovalIn: circle).fill()

        let font = Typography.ui(floor(side * 0.46), weight: .semibold)
        let text = NSAttributedString(string: TeammateIdentity.initial(name), attributes: [.font: font, .foregroundColor: color])
        let size = text.size()
        text.draw(at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2))
    }
}

/// How a teammate is drawn: its initial and its avatar hue.
enum TeammateIdentity {
    /// The first letter or digit of the name, uppercased ("?" when there is none).
    static func initial(_ name: String) -> String {
        guard let first = name.first(where: { $0.isLetter || $0.isNumber }) else { return "?" }
        return String(first).uppercased()
    }

    /// Index into `Palette.projectIconColors`, derived from the handle like project monograms.
    static func colorIndex(_ handle: String, count: Int) -> Int {
        ProjectIdentity.colorIndex(handle.isEmpty ? "teammate" : handle, count: count)
    }
}
