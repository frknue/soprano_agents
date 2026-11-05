import AppKit
import SopranoAgentsCore

/// Callbacks a Team section row raises; the sidebar controller owns the behavior.
@MainActor
struct SidebarTeamActions {
    var select: (String) -> Void
    /// Double-click: the Edit Teammate dialog (teammates have no inline rename).
    var edit: (String) -> Void
    var menu: (String) -> NSMenu?
}

/// "Team  2  ＋": the Team section's header (shelf style, not collapsible); ＋ opens New Teammate.
final class SidebarTeamHeaderCell: PaletteView {
    private let titleLabel = NSTextField.label("Team", size: Typography.smallSize, weight: .medium)
    private let countLabel = NSTextField.label("", size: Typography.smallSize)
    let addButton = RowActionButton(symbol: SidebarSymbol.plus, symbolSize: 11, accessibility: "New teammate")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        countLabel.font = Typography.tabular(Typography.smallSize)
        for view in [titleLabel, countLabel, addButton] as [NSView] { addSubview(view) }
        applyPalette(palette)
    }

    func configure(count: Int) {
        countLabel.stringValue = count > 0 ? "\(count)" : ""
        countLabel.isHidden = count == 0
        setAccessibilityLabel("Team \(count)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let left = SidebarLayout.contentInset + 2 + 8
        let right = bounds.width - SidebarLayout.contentInset - 2
        let height: CGFloat = 32
        let titleSize = titleLabel.intrinsicContentSize
        titleLabel.frame = NSRect(x: left - 2, y: (height - titleSize.height) / 2, width: ceil(titleSize.width) + 4, height: titleSize.height)
        let addWidth = addButton.fittingWidth
        addButton.frame = NSRect(x: right - addWidth, y: (height - 20) / 2, width: addWidth, height: 20)
        let countSize = countLabel.intrinsicContentSize
        countLabel.frame = NSRect(x: addButton.frame.minX - 4 - ceil(countSize.width) - 4, y: (height - countSize.height) / 2, width: ceil(countSize.width) + 4, height: countSize.height)
    }

    override func applyPalette(_ palette: Palette) {
        titleLabel.textColor = palette.sidebarMutedForeground
        countLabel.textColor = palette.sidebarMutedForeground
    }
}

/// The empty Team section's one-line hint (`text-xs text-muted-foreground/60`).
final class SidebarTeamHintCell: PaletteView {
    static let message = "Create a teammate to chat with and delegate to"
    private let label = NSTextField.label(SidebarTeamHintCell.message, size: Typography.smallSize)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = Self.message
        addSubview(label)
        applyPalette(palette)
    }

    override func layout() {
        super.layout()
        let left = SidebarLayout.contentInset + SidebarLayout.rowInset
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: left - 2, y: (bounds.height - size.height) / 2 - 2, width: max(0, bounds.width - left - SidebarLayout.contentInset), height: size.height)
    }

    override func applyPalette(_ palette: Palette) {
        label.textColor = palette.mutedForeground.alphaScaled(by: 0.6)
    }
}

/// A teammate (`h-11 px-2.5`): avatar, name over role, status pill or relative time; hover swaps
/// the slot for "⋯". Click opens its thread, double-click edits it, right-click shows its menu.
final class SidebarTeammateCell: InteractiveView {
    private(set) var row: SidebarTeammateRow?
    var actions: SidebarTeamActions?
    private var now = Date()
    private let surface = NSView()
    private let avatar = TeammateAvatarView()
    private let nameLabel = NSTextField.label("", size: Typography.bodySize, weight: .medium)
    private let roleLabel = NSTextField.label("", size: Typography.smallSize)
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField.label("", size: Typography.smallSize, weight: .medium)
    private let timeLabel = NSTextField.label("", size: Typography.smallSize)
    private let moreButton = RowActionButton(symbol: SidebarSymbol.ellipsis, accessibility: "Teammate actions")
    private let jumpBadge = JumpHintBadge()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        surface.wantsLayer = true
        surface.layer?.cornerRadius = Radius.md
        statusLabel.font = Typography.tabular(Typography.smallSize, weight: .medium)
        timeLabel.font = Typography.tabular(Typography.smallSize)
        timeLabel.alignment = .right
        for view in [surface, avatar, nameLabel, roleLabel, statusIcon, statusLabel, timeLabel, moreButton, jumpBadge] as [NSView] {
            addSubview(view)
        }
        jumpBadge.isHidden = true
        moreButton.isHidden = true
        moreButton.onClick = { [weak self] in self?.showMoreMenu() }
        setAccessibilityRole(.row)
    }

    /// The jump hint ("⌃1") while ⌃ is held; nil hides it.
    var jumpHint: String? {
        didSet {
            jumpBadge.text = jumpHint ?? ""
            jumpBadge.isHidden = jumpHint == nil
            needsLayout = true
        }
    }

    func configure(_ row: SidebarTeammateRow, now: Date) {
        self.row = row
        self.now = now
        avatar.configure(name: row.name, handle: row.handle)
        nameLabel.stringValue = row.name
        roleLabel.stringValue = row.role.isEmpty ? "@\(row.handle)" : row.role
        toolTip = row.role.isEmpty ? "\(row.name) (@\(row.handle))" : "\(row.name) (@\(row.handle)) — \(row.role)"
        setAccessibilityLabel(row.name)
        applyPalette(palette)
    }

    /// Updates the live duration or relative time only.
    func refreshTime(_ now: Date) {
        self.now = now
        refreshStatus()
    }

    private func refreshStatus() {
        guard let row else { return }
        let palette = palette
        let hovering = isHovered
        if let pill = SidebarStatusPill.of(row.status) {
            statusIcon.image = NSImage.symbol(pill.symbol, size: 12.5)
            statusLabel.stringValue = pill.text(now: now)
            statusIcon.contentTintColor = palette.color(for: pill.tone)
            statusLabel.textColor = palette.color(for: pill.tone)
            statusIcon.isHidden = hovering
            statusLabel.isHidden = hovering
            timeLabel.isHidden = true
        } else {
            timeLabel.stringValue = DurationText.relative(row.activityDate, now: now)
            statusIcon.isHidden = true
            statusLabel.isHidden = true
            timeLabel.isHidden = hovering
        }
        moreButton.isHidden = !hovering
        needsLayout = true
    }

    private var surfaceRect: NSRect {
        NSRect(x: SidebarLayout.contentInset, y: 1, width: bounds.width - SidebarLayout.contentInset * 2, height: bounds.height - 2)
    }

    override func layout() {
        super.layout()
        let surface = surfaceRect
        self.surface.frame = surface
        let left = surface.minX + SidebarLayout.rowInset
        let right = surface.maxX - SidebarLayout.rowInset
        avatar.frame = NSRect(x: left, y: surface.midY - 12, width: 24, height: 24)
        let textLeft = avatar.frame.maxX + 10
        let line1 = surface.minY + 4
        let line2 = line1 + 19

        var slotLeft = right
        if !moreButton.isHidden {
            let width = moreButton.fittingWidth
            moreButton.frame = NSRect(x: right + 4 - width, y: line1, width: width, height: 20)
            slotLeft = moreButton.frame.minX
        }
        if !statusLabel.isHidden {
            let size = statusLabel.intrinsicContentSize
            let width = ceil(size.width) + 4
            statusLabel.frame = NSRect(x: right + 2 - width, y: line1 + (20 - size.height) / 2, width: width, height: size.height)
            statusIcon.frame = NSRect(x: statusLabel.frame.minX + 2 - 4 - 16, y: line1 + 2, width: 16, height: 16)
            slotLeft = statusIcon.frame.minX
        }
        if !timeLabel.isHidden {
            let size = timeLabel.intrinsicContentSize
            let width = max(32, ceil(size.width) + 4)
            timeLabel.frame = NSRect(x: right + 2 - width, y: line1 + (20 - size.height) / 2, width: width, height: size.height)
            slotLeft = timeLabel.frame.minX
        }
        let nameSize = nameLabel.intrinsicContentSize
        nameLabel.frame = NSRect(x: textLeft - 2, y: line1 + (20 - nameSize.height) / 2, width: max(0, slotLeft - 6 - textLeft + 4), height: nameSize.height)
        let roleSize = roleLabel.intrinsicContentSize
        roleLabel.frame = NSRect(x: textLeft - 2, y: line2 + (16 - roleSize.height) / 2, width: max(0, right - textLeft + 4), height: roleSize.height)

        if !jumpBadge.isHidden {
            let size = jumpBadge.fittingSize
            jumpBadge.frame = NSRect(x: surface.maxX - 6 - size.width, y: surface.midY - 10, width: size.width, height: 20)
        }
    }

    override func applyPalette(_ palette: Palette) {
        guard let row else { return }
        let fill: NSColor = row.isSelected ? palette.sidebarRowActive : isHovered ? palette.sidebarRowHover : .clear
        surface.layer?.backgroundColor = fill.cgColor
        surface.layer?.borderWidth = row.isSelected && !palette.isDark ? 1 : 0
        surface.layer?.borderColor = palette.sidebarBorder.alphaScaled(by: 0.7).cgColor
        nameLabel.textColor = palette.sidebarForeground
        roleLabel.textColor = palette.secondaryLabel
        timeLabel.textColor = palette.secondaryLabel
        // Hover changes come through here too (`InteractiveView`): the slot swaps for "⋯".
        refreshStatus()
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        super.mouseUp(with: event)
        guard inside, let row else { return }
        if event.clickCount >= 2 {
            actions?.edit(row.threadID)
        } else {
            actions?.select(row.threadID)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let row else { return nil }
        return actions?.menu(row.threadID)
    }

    private func showMoreMenu() {
        guard let row, let menu = actions?.menu(row.threadID) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: moreButton.frame.minX, y: moreButton.frame.maxY + 4), in: self)
    }
}
