import AppKit
import SopranoAgentsCore

/// The New / Edit Teammate dialog: an `OverlayWindow` card like `Dialogs`, with Name and Handle
/// side by side (the handle follows `Teammate.suggestedHandle(from:)` of the name until the user
/// edits it, validated live by `Teammate.handleProblem`), Role, Instructions, Home folder (a
/// project's root or the teammate's own folder) and "Also make available to terminal omp".
/// Saving calls `engine.createTeammate` / `updateTeammate`; a thrown error shows above the
/// buttons and keeps the dialog open. Return in a field or ⌘↩ saves, Escape cancels.
@MainActor
final class TeammateDialog: NSObject, NSTextViewDelegate {
    enum Mode: Equatable {
        case create
        case edit(threadID: String)
    }

    static let width: CGFloat = 512
    /// The value of "Own folder (no project)" in the Home folder menu.
    private static let ownFolder = ""

    private let engine: AgentEngine
    private let state: WorkspaceState
    private let mode: Mode
    private let window = OverlayWindow()
    private weak var parentWindow: NSWindow?

    private let nameField: InputField
    private let handleField: InputField
    private let handleNote = ThemedLabel("", size: Typography.smallSize, wrapping: true) { $0.mutedForeground }
    private let roleField: InputField
    private let instructions = TeammateInstructionsBox()
    private let homeFolder: SelectButton
    private let exportSwitch: SwitchControl
    private let exportNote = ThemedLabel("", size: Typography.smallSize, wrapping: true) { $0.mutedForeground }
    private let errorLabel = ThemedLabel("", size: Typography.smallSize, wrapping: true) { $0.errorForeground }
    private let saveButton: TextButton
    /// The user typed a handle of their own: the name no longer drives it.
    private var handleEdited: Bool

    /// The dialog on screen, if any (one at a time).
    private(set) static weak var current: TeammateDialog?

    /// Shows the dialog over `window`. Edit prefills from `engine.teammateDraft`; a teammate that
    /// is gone opens nothing.
    static func present(_ mode: Mode, engine: AgentEngine, state: WorkspaceState, in window: NSWindow?) {
        guard let host = Dialogs.host(for: window) else { return }
        current?.cancel()
        let draft: TeammateDraft
        switch mode {
        case .create:
            draft = TeammateDraft(name: "", handle: "", role: "", instructions: "", projectID: nil, exportsToOmp: true)
        case let .edit(threadID):
            guard let existing = engine.teammateDraft(threadID) else { return }
            draft = existing
        }
        let dialog = TeammateDialog(mode: mode, draft: draft, engine: engine, state: state)
        current = dialog
        dialog.show(over: host)
    }

    private init(mode: Mode, draft: TeammateDraft, engine: AgentEngine, state: WorkspaceState) {
        self.engine = engine
        self.state = state
        self.mode = mode
        handleEdited = mode != .create
        nameField = InputField(value: draft.name, placeholder: "CTO")
        handleField = InputField(value: draft.handle, placeholder: "cto", monospaced: true)
        roleField = InputField(value: draft.role, placeholder: "Owns architecture and code review")
        var options = engine.projects.map { SelectOption(title: $0.title, value: $0.id) }
        options.append(SelectOption(title: "Own folder (no project)", value: Self.ownFolder, separatorBefore: !options.isEmpty))
        let selectedProject = draft.projectID.flatMap { id in engine.projects.contains { $0.id == id } ? id : nil } ?? Self.ownFolder
        homeFolder = SelectButton(options: options, selected: selectedProject, width: 280, accessibilityLabel: "Home folder")
        exportSwitch = SwitchControl(isOn: draft.exportsToOmp, label: "Also make available to terminal omp")
        saveButton = TextButton(mode == .create ? "Create Teammate" : "Save", variant: .primary, size: .regular)
        super.init()
        instructions.text = draft.instructions
    }

    // MARK: Building

    private func show(over parent: NSWindow) {
        parentWindow = parent
        window.owner = self
        window.autorecalculatesKeyViewLoop = true
        let card = OverlayCardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        window.backdrop.addSubview(card)
        let preferredWidth = card.widthAnchor.constraint(equalToConstant: Self.width)
        preferredWidth.priority = .overlayPreferred
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: window.backdrop.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: window.backdrop.centerYAnchor),
            preferredWidth,
            card.widthAnchor.constraint(lessThanOrEqualTo: window.backdrop.widthAnchor, constant: -32),
        ])
        build(in: card.content)
        window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        window.onClose = { [weak self] in
            guard let self, Self.current === self else { return }
            Self.current = nil
        }
        validate()
        window.present(over: parent, focus: nameField.field)
    }

    private func build(in container: NSView) {
        let isCreate = mode == .create
        let title = ThemedLabel(isCreate ? "New Teammate" : "Edit Teammate", size: 16, weight: .semibold)
        let message = ThemedLabel(
            "A long-lived agent you chat with here. Your threads and other teammates can message it by its handle.",
            wrapping: true
        ) { $0.mutedForeground }

        nameField.onChange = { [weak self] _ in self?.nameChanged() }
        handleField.onChange = { [weak self] _ in self?.handleChanged() }
        for field in [nameField, handleField, roleField] {
            field.onCommand = { [weak self] selector in
                guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
                self?.submit()
                return true
            }
        }
        instructions.textView.delegate = self
        instructions.placeholder = "How it works, what it decides, what it should always check…"
        exportSwitch.onToggle = { [weak self] _ in self?.validate() }

        let nameColumn = Self.labeled("Name", nameField)
        let handleColumn = Self.labeled("Handle", handleField)
        let identityRow = NSStackView(views: [nameColumn, handleColumn])
        identityRow.orientation = .horizontal
        identityRow.alignment = .top
        identityRow.distribution = .fillEqually
        identityRow.spacing = 12

        let exportLabel = ThemedLabel("Also make available to terminal omp", size: Typography.rowSize)
        let exportRow = NSStackView(views: [exportSwitch, exportLabel])
        exportRow.orientation = .horizontal
        exportRow.alignment = .centerY
        exportRow.spacing = 8

        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6
        body.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        let rows: [NSView] = [
            title, message,
            identityRow, handleNote,
            Self.labeled("Role", roleField),
            Self.labeled("Instructions", instructions),
            Self.labeled("Home folder", homeFolder, fillsWidth: false),
            exportRow, exportNote,
            errorLabel,
        ]
        for row in rows { body.addArrangedSubview(row) }
        body.setCustomSpacing(8, after: title)
        body.setCustomSpacing(18, after: message)
        body.setCustomSpacing(4, after: identityRow)
        body.setCustomSpacing(14, after: handleNote)
        body.setCustomSpacing(14, after: rows[4])
        body.setCustomSpacing(14, after: rows[5])
        body.setCustomSpacing(16, after: rows[6])
        body.setCustomSpacing(4, after: exportRow)
        body.setCustomSpacing(12, after: exportNote)
        for view in [message, identityRow, handleNote, rows[4], rows[5], rows[6], exportNote, errorLabel] {
            view.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -48).isActive = true
        }
        for label in [message, handleNote, exportNote, errorLabel] {
            label.preferredMaxLayoutWidth = Self.width - 48
        }
        instructions.heightAnchor.constraint(equalToConstant: 88).isActive = true
        errorLabel.isHidden = true

        let footer = DialogFooterView()
        let cancel = TextButton("Cancel", variant: .outline, size: .regular)
        cancel.onClick = { [weak self] in self?.cancel() }
        saveButton.onClick = { [weak self] in self?.submit() }
        let buttons = NSStackView(views: [cancel, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        for view in [body, footer, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        container.addSubview(body)
        container.addSubview(footer)
        footer.addSubview(buttons)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: container.topAnchor),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.topAnchor.constraint(equalTo: body.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            buttons.topAnchor.constraint(equalTo: footer.topAnchor, constant: 16),
            buttons.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -16),
            buttons.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -24),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: footer.leadingAnchor, constant: 24),
        ])
    }

    /// A field under its label ("Name", 13 medium); the field spans the column unless it has a
    /// fixed width of its own (`SelectButton`).
    private static func labeled(_ label: String, _ field: NSView, fillsWidth: Bool = true) -> NSView {
        let title = ThemedLabel(label, size: Typography.rowSize, weight: .medium)
        let stack = NSStackView(views: [title, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        field.translatesAutoresizingMaskIntoConstraints = false
        if fillsWidth { field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    // MARK: Validation

    private var trimmedName: String { nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var handle: String { handleField.stringValue.trimmingCharacters(in: .whitespaces) }

    /// Handles of the other teammates (the edited one keeps its own).
    private var takenHandles: Set<String> {
        let editedID: String? = if case let .edit(threadID) = mode { threadID } else { nil }
        return Set(engine.team.filter { $0.id != editedID }.compactMap { $0.teammate?.handle })
    }

    private func nameChanged() {
        if !handleEdited {
            handleField.stringValue = Teammate.suggestedHandle(from: nameField.stringValue)
        }
        validate()
    }

    private func handleChanged() {
        // Clearing the handle hands it back to the name.
        handleEdited = !handleField.stringValue.isEmpty
        validate()
    }

    /// Why Save is disabled; nil when the teammate can be saved.
    private var problem: String? {
        if let handleProblem = Teammate.handleProblem(handle, taken: takenHandles) { return handleProblem }
        if trimmedName.isEmpty { return "Give the teammate a name." }
        return nil
    }

    private func validate() {
        let handleProblem = Teammate.handleProblem(handle, taken: takenHandles)
        // An untouched, empty form shows no complaint; Save stays disabled until it is filled in.
        let quiet = handle.isEmpty && trimmedName.isEmpty
        if let handleProblem, !quiet {
            handleNote.stringValue = handleProblem
            handleNote.role = { $0.errorForeground }
        } else {
            handleNote.stringValue = handle.isEmpty
                ? "Your threads and teammates message it by this handle."
                : "Your threads and teammates message it as @\(handle)."
            handleNote.role = { $0.mutedForeground }
        }
        let shownHandle = handleProblem == nil ? handle : "<handle>"
        exportNote.stringValue = "Writes ~/.omp/agent/agents/\(shownHandle).md; terminal omp starts a fresh copy without this teammate’s memory."
        exportNote.alphaValue = exportSwitch.isOn ? 1 : 0.6
        saveButton.isEnabled = problem == nil
    }

    // MARK: Actions

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let stroke = KeyStroke(event: event) else { return false }
        if stroke.key == "\u{1B}", !stroke.ctrl, !stroke.meta, !stroke.option {
            cancel()
            return true
        }
        if stroke.key == "\r", stroke.meta, !stroke.ctrl, !stroke.option {
            submit()
            return true
        }
        return false
    }

    /// Tab leaves the instructions for the next field (it never inserts a tab character).
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            window.selectNextKeyView(nil)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            window.selectPreviousKeyView(nil)
            return true
        default:
            return false
        }
    }

    private func submit() {
        validate()
        guard problem == nil else { return }
        let project = homeFolder.selectedValue
        let draft = TeammateDraft(
            name: trimmedName,
            handle: handle,
            role: roleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            instructions: instructions.text.trimmingCharacters(in: .whitespacesAndNewlines),
            projectID: project == Self.ownFolder ? nil : project,
            exportsToOmp: exportSwitch.isOn
        )
        let result: TeammateSaveResult
        do {
            switch mode {
            case .create: result = try engine.createTeammate(draft)
            case let .edit(threadID): result = try engine.updateTeammate(threadID, draft)
            }
        } catch {
            errorLabel.stringValue = error.localizedDescription
            errorLabel.isHidden = false
            return
        }
        let parent = parentWindow
        close()
        if mode == .create {
            ThreadActions.open(result.threadID, engine: engine, state: state)
        }
        if let warning = result.warning {
            Task { @MainActor in
                await Dialogs.alert(title: "Teammate saved", message: warning, in: parent)
            }
        }
    }

    private func cancel() {
        close()
    }

    private func close() {
        if Self.current === self { Self.current = nil }
        window.dismiss()
    }
}

/// The Instructions field: a multi-line text view a few lines tall that scrolls, in the input
/// box style (`border-input`, `bg-background`, dark `bg-input/32`).
final class TeammateInstructionsBox: PaletteView {
    let textView = PlaceholderTextView(frame: NSRect(x: 0, y: 0, width: 462, height: 88))
    private let scrollView = NSScrollView()

    var text: String {
        get { textView.string }
        set { textView.string = newValue }
    }

    var placeholder: String {
        get { textView.placeholder }
        set { textView.placeholder = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.lg
        layer?.borderWidth = 1
        textView.font = Typography.ui(Typography.bodySize)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 7)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Instructions")
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (palette.isDark ? palette.input.withAlphaComponent(palette.input.alphaComponent * 0.32) : palette.background).cgColor
        layer?.borderColor = palette.input.cgColor
        textView.textColor = palette.foreground
        textView.insertionPointColor = palette.foreground
        textView.needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
    }
}
