import Foundation

/// The HTML `<form>` of an omp `form` dialog (`extension_ui_request` `method:"form"`, `html`):
/// what the `ask` tool sends since omp 19 instead of walking fields through `select`/`editor`.
///
/// Parsed into one field per control `name`: a radio group, a checkbox group (or lone checkbox),
/// a `<select>` (single or `multiple`), a text-like `<input>` (`text`, `email`, `url`, `number`,
/// `range`, `date`, …) or a `<textarea>`. Hidden inputs, buttons and submit controls are left to
/// omp ("Hidden inputs keep the form's own values"). A field's question is its fieldset's
/// `<legend>`, else its wrapping or `for=` `<label>` (text fields), else the `<p>` right before
/// it; the context blocks before it (`<p>`, `<li>`, `<pre>`, table rows, headings) lead its
/// question text. `data(answers:)` answers the dialog the way an HTML form submits: option
/// `value`s by control `name`, arrays for groups of two or more checkboxes / multi-selects, a
/// string that is no option value as a group's "Other" answer, numbers for `number`/`range`.
public struct OmpForm: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case radio
        case checkbox
        case select(multiple: Bool)
        /// An `<input>` with this `type` (lower-cased; "text" when absent).
        case input(type: String)
        case textarea
    }

    public struct Option: Sendable, Hashable {
        public var value: String
        public var label: String
        public var checked: Bool
        public var disabled: Bool
    }

    public struct Field: Sendable, Hashable {
        /// The question id: the control name, made unique when two fields share it.
        public var id: String
        public var name: String
        public var kind: Kind
        public var question: String
        public var options: [Option]
        /// A text field's starting value.
        public var value: String
        public var required: Bool

        /// The options the user can pick (disabled ones are refused by omp).
        public var choices: [Option] { options.filter { !$0.disabled } }

        /// Radio and checkbox groups of two or more options take a free-text "Other" answer,
        /// unless one of their options is already labelled "Other".
        public var allowsOther: Bool {
            switch kind {
            case .radio, .checkbox:
                options.count >= 2 && !options.contains { $0.label.caseInsensitiveCompare("Other") == .orderedSame }
            default:
                false
            }
        }

        /// Submits an array: a checkbox group or multi-select of two or more options.
        var submitsArray: Bool {
            switch kind {
            case .checkbox, .select(multiple: true): options.count >= 2
            default: false
            }
        }

        var isChoice: Bool {
            switch kind {
            case .radio, .checkbox, .select: true
            case .input, .textarea: false
            }
        }

        var allowsMultiple: Bool {
            switch kind {
            case .checkbox, .select(multiple: true): true
            default: false
            }
        }

        /// What the form starts with: the checked or selected options; a single `<select>`
        /// without one starts on its first option, as browsers do.
        var initialLabels: [String] {
            let checked = choices.filter(\.checked).map(\.label)
            if case .select(multiple: false) = kind, checked.isEmpty, let first = choices.first { return [first.label] }
            return allowsMultiple ? checked : Array(checked.prefix(1))
        }
    }

    public var fields: [Field]

    public init(fields: [Field]) {
        self.fields = fields
    }

    /// Parses `html`; nil when it holds no control the user can answer.
    public init?(html: String) {
        var parser = FormParser(html)
        let fields = parser.parse()
        guard !fields.isEmpty else { return nil }
        self.fields = fields
    }

    /// The dialog as questions, one per field, in form order.
    public func questions() -> [UserInputQuestion] {
        fields.map { field in
            if field.isChoice {
                return UserInputQuestion(
                    id: field.id,
                    header: "",
                    question: field.question,
                    options: field.choices.map { UserInputOption(label: $0.label) },
                    allowsMultiple: field.allowsMultiple,
                    allowsOther: field.allowsOther,
                    initialSelection: field.initialLabels
                )
            }
            return UserInputQuestion(
                id: field.id,
                header: "",
                question: field.question,
                options: [],
                allowsOther: true,
                initialText: field.value.isEmpty ? nil : field.value
            )
        }
    }

    /// The submitted form `data` for `answers` (question id → picked labels and/or free text).
    /// An unanswered field keeps its starting state; a required choice left empty falls back to
    /// it too, since omp fails the whole call on an invalid answer.
    public func data(answers: [String: [String]]) -> [String: JSONValue] {
        var data: [String: JSONValue] = [:]
        for field in fields where data[field.name] == nil {
            let given = answers[field.id]
            if field.isChoice {
                let choices = field.choices
                func values(_ entries: [String]) -> [String] {
                    var picked: [String] = []
                    var other: [String] = []
                    for entry in entries {
                        if let option = choices.first(where: { $0.label == entry }) {
                            if !picked.contains(option.value) { picked.append(option.value) }
                        } else {
                            let text = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !text.isEmpty { other.append(text) }
                        }
                    }
                    if field.allowsOther, !other.isEmpty { picked.append(other.joined(separator: "\n")) }
                    return picked
                }
                var picked = values(given ?? field.initialLabels)
                if picked.isEmpty, field.required { picked = values(field.initialLabels) }
                if field.submitsArray {
                    data[field.name] = .array(picked.map(JSONValue.string))
                } else if let first = picked.first {
                    data[field.name] = .string(first)
                }
                continue
            }
            let text = given.map { $0.joined(separator: "\n") } ?? field.value
            if case let .input(type) = field.kind, type == "number" || type == "range" {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let number = Double(trimmed) { data[field.name] = .number(number) }
                continue
            }
            data[field.name] = .string(text)
        }
        return data
    }
}

// MARK: - Parsing

/// A forgiving HTML reader for the form markup omp's `ask` tool emits: tags with quoted,
/// unquoted or bare attributes, void elements, comments, character references. No DOM: one pass
/// that tracks the fieldset, label, select, option, textarea and context block it is in.
private struct FormParser {
    private let chars: [Character]
    private var index = 0

    init(_ html: String) {
        chars = Array(html)
    }

    private struct Tag {
        var name: String
        var attributes: [String: String]
        var isClosing: Bool
    }

    private enum Token {
        case tag(Tag)
        case text(String)
    }

    private struct PendingField {
        var name: String
        var kind: OmpForm.Kind
        var question: String
        var context: [String]
        var options: [OmpForm.Option]
        var value: String
        var required: Bool
        var elementID: String?
    }

    mutating func parse() -> [OmpForm.Field] {
        var fields: [PendingField] = []
        var context: [String] = []          // blocks since the last field
        var legend: String?                 // the open fieldset's legend
        var fieldsetUsed = false            // its legend already led a field
        var labelFor: [String: String] = [:]   // `<label for=id>` → its text
        var labelTarget: String?               // the open label's `for`
        var optionIDs: [String: (field: Int, option: Int)] = [:]
        var labelText: String?              // text of the open <label>
        var labelControls: [Int] = []       // fields whose option or control the open label wraps
        var labelOption: (field: Int, option: Int)?
        var block: String?                  // text of the open context block
        var blockTag = ""
        var legendText: String?
        var select: Int?
        var option: (value: String?, selected: Bool, disabled: Bool, text: String)?
        var textarea: Int?
        var textareaText = ""
        var cell: [String] = []

        func clean(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        func field(named name: String, kind: OmpForm.Kind, in fields: [PendingField]) -> Int? {
            switch kind {
            case .radio, .checkbox:
                fields.lastIndex { $0.name == name && $0.kind == kind }
            default:
                nil
            }
        }

        func newField(name: String, kind: OmpForm.Kind, attributes: [String: String]) -> PendingField {
            var question = ""
            var lead = context
            if let legend, !fieldsetUsed {
                question = legend
            } else if legend == nil, kind.isGroupMember, let last = lead.popLast() {
                // A group's question is the `<p>` right before it.
                question = last
            }
            return PendingField(
                name: name,
                kind: kind,
                question: question,
                context: lead,
                options: [],
                value: attributes["value"] ?? "",
                required: attributes["required"] != nil,
                elementID: attributes["id"]
            )
        }

        while let token = next() {
            switch token {
            case let .text(raw):
                if textarea != nil { textareaText += raw; continue }
                if option != nil { option?.text += raw; continue }
                if legendText != nil { legendText! += raw; continue }
                if labelText != nil {
                    labelText! += raw
                    if let target = labelOption { fields[target.field].options[target.option].label += raw }
                    continue
                }
                if block != nil { block! += raw }
            case let .tag(tag):
                let name = tag.name
                let attributes = tag.attributes
                if tag.isClosing {
                    switch name {
                    case "legend":
                        legend = legendText.map(clean)
                        legendText = nil
                    case "fieldset":
                        legend = nil
                        fieldsetUsed = false
                    case "label":
                        let text = clean(labelText ?? "")
                        if let labelTarget { labelFor[labelTarget] = text }
                        for index in labelControls where !fields[index].kind.isGroupMember && fields[index].question.isEmpty {
                            fields[index].question = text
                        }
                        labelText = nil
                        labelControls = []
                        labelOption = nil
                    case "option":
                        if let open = option, let select {
                            let label = clean(open.text)
                            fields[select].options.append(OmpForm.Option(value: open.value ?? label, label: label, checked: open.selected, disabled: open.disabled))
                        }
                        option = nil
                    case "select":
                        select = nil
                    case "textarea":
                        if let textarea { fields[textarea].value = textareaText }
                        textarea = nil
                    case "p", "li", "pre", "h1", "h2", "h3", "h4", "h5", "h6", "caption", "dt", "dd":
                        if blockTag == name, let text = block.map(name == "pre" ? { $0.trimmingCharacters(in: .whitespacesAndNewlines) } : clean), !text.isEmpty {
                            context.append(name == "li" ? "• " + text : text)
                        }
                        if blockTag == name { block = nil; blockTag = "" }
                    case "td", "th":
                        if let text = block.map(clean) { cell.append(text) }
                        block = nil
                        blockTag = ""
                    case "tr":
                        let row = cell.filter { !$0.isEmpty }.joined(separator: " | ")
                        if !row.isEmpty { context.append(row) }
                        cell = []
                    default:
                        break
                    }
                    continue
                }
                switch name {
                case "fieldset":
                    legend = nil
                    fieldsetUsed = false
                case "legend":
                    legendText = ""
                case "label":
                    labelText = ""
                    labelControls = []
                    labelOption = nil
                    labelTarget = attributes["for"]
                case "p", "li", "pre", "h1", "h2", "h3", "h4", "h5", "h6", "caption", "dt", "dd":
                    if block == nil, labelText == nil, legendText == nil { block = ""; blockTag = name }
                case "td", "th":
                    block = ""
                    blockTag = name
                case "br":
                    if textarea == nil, block != nil { block! += " " }
                case "select":
                    guard let controlName = attributes["name"], !controlName.isEmpty else { continue }
                    let kind = OmpForm.Kind.select(multiple: attributes["multiple"] != nil)
                    var pending = newField(name: controlName, kind: kind, attributes: attributes)
                    pending.value = ""
                    fields.append(pending)
                    select = fields.count - 1
                    if labelText != nil { labelControls.append(fields.count - 1) }
                    fieldsetUsed = legend != nil
                    context = []
                case "option":
                    guard select != nil else { continue }
                    option = (attributes["value"], attributes["selected"] != nil, attributes["disabled"] != nil, "")
                case "textarea":
                    guard let controlName = attributes["name"], !controlName.isEmpty else { continue }
                    var pending = newField(name: controlName, kind: .textarea, attributes: attributes)
                    pending.value = ""
                    fields.append(pending)
                    textarea = fields.count - 1
                    textareaText = ""
                    if labelText != nil { labelControls.append(fields.count - 1) }
                    fieldsetUsed = legend != nil
                    context = []
                case "input":
                    let type = (attributes["type"] ?? "text").lowercased()
                    guard let controlName = attributes["name"], !controlName.isEmpty,
                          !["hidden", "submit", "button", "reset", "image", "file"].contains(type) else { continue }
                    switch type {
                    case "radio", "checkbox":
                        let kind: OmpForm.Kind = type == "radio" ? .radio : .checkbox
                        let target: Int
                        if let existing = field(named: controlName, kind: kind, in: fields) {
                            target = existing
                        } else {
                            fields.append(newField(name: controlName, kind: kind, attributes: attributes))
                            target = fields.count - 1
                            fieldsetUsed = legend != nil
                            context = []
                        }
                        fields[target].options.append(OmpForm.Option(
                            value: attributes["value"] ?? "on",
                            label: "",
                            checked: attributes["checked"] != nil,
                            disabled: attributes["disabled"] != nil
                        ))
                        if attributes["required"] != nil { fields[target].required = true }
                        let optionIndex = fields[target].options.count - 1
                        if labelText != nil {
                            labelOption = (target, optionIndex)
                        }
                        if let id = attributes["id"], !id.isEmpty { optionIDs[id] = (target, optionIndex) }
                    default:
                        fields.append(newField(name: controlName, kind: .input(type: type), attributes: attributes))
                        if labelText != nil { labelControls.append(fields.count - 1) }
                        fieldsetUsed = legend != nil
                        context = []
                    }
                default:
                    break
                }
            }
        }

        // `<label for=id>` outside the control: option labels and text-field questions.
        for (id, text) in labelFor {
            if let target = optionIDs[id], fields[target.field].options[target.option].label.isEmpty {
                fields[target.field].options[target.option].label = text
            } else if let index = fields.firstIndex(where: { $0.elementID == id }), fields[index].question.isEmpty {
                fields[index].question = text
            }
        }

        var used: [String: Int] = [:]
        return fields.compactMap { pending -> OmpForm.Field? in
            var options = pending.options.map { option -> OmpForm.Option in
                var option = option
                option.label = clean(option.label)
                if option.label.isEmpty { option.label = option.value }
                return option
            }
            // Labels identify options in the answers: keep them unique.
            var seen: Set<String> = []
            for index in options.indices {
                if seen.contains(options[index].label) { options[index].label += " (\(options[index].value))" }
                seen.insert(options[index].label)
            }
            if pending.kind.isGroupMember || pending.kind.isSelect, options.filter({ !$0.disabled }).isEmpty { return nil }
            let count = used[pending.name, default: 0] + 1
            used[pending.name] = count
            let question = pending.question.isEmpty ? pending.name : pending.question
            let text = (pending.context + [question]).joined(separator: "\n\n")
            return OmpForm.Field(
                id: count == 1 ? pending.name : "\(pending.name)#\(count)",
                name: pending.name,
                kind: pending.kind,
                question: text,
                options: options,
                value: pending.value,
                required: pending.required
            )
        }
    }

    // MARK: Tokens

    private mutating func next() -> Token? {
        guard index < chars.count else { return nil }
        if chars[index] == "<" {
            if starts(with: "<!--") {
                index += 4
                while index < chars.count, !starts(with: "-->") { index += 1 }
                index = min(index + 3, chars.count)
                return .text("")
            }
            if let tag = readTag() { return .tag(tag) }
            index += 1
            return .text("<")
        }
        var text = ""
        while index < chars.count, chars[index] != "<" {
            text.append(chars[index])
            index += 1
        }
        return .text(Self.decode(text))
    }

    private func starts(with prefix: String) -> Bool {
        var position = index
        for character in prefix {
            guard position < chars.count, chars[position] == character else { return false }
            position += 1
        }
        return true
    }

    private mutating func readTag() -> Tag? {
        var position = index + 1
        var isClosing = false
        if position < chars.count, chars[position] == "/" { isClosing = true; position += 1 }
        if position < chars.count, chars[position] == "!" || chars[position] == "?" {
            while position < chars.count, chars[position] != ">" { position += 1 }
            index = min(position + 1, chars.count)
            return Tag(name: "!", attributes: [:], isClosing: false)
        }
        var name = ""
        while position < chars.count, chars[position].isLetter || chars[position].isNumber || chars[position] == "-" {
            name.append(chars[position])
            position += 1
        }
        guard !name.isEmpty else { return nil }
        var attributes: [String: String] = [:]
        while position < chars.count {
            while position < chars.count, chars[position].isWhitespace || chars[position] == "/" { position += 1 }
            guard position < chars.count, chars[position] != ">" else { break }
            var key = ""
            while position < chars.count, !chars[position].isWhitespace, !"=>/".contains(chars[position]) {
                key.append(chars[position])
                position += 1
            }
            if key.isEmpty { position += 1; continue }
            while position < chars.count, chars[position].isWhitespace { position += 1 }
            var value = ""
            if position < chars.count, chars[position] == "=" {
                position += 1
                while position < chars.count, chars[position].isWhitespace { position += 1 }
                if position < chars.count, chars[position] == "\"" || chars[position] == "'" {
                    let quote = chars[position]
                    position += 1
                    while position < chars.count, chars[position] != quote {
                        value.append(chars[position])
                        position += 1
                    }
                    position += 1
                } else {
                    while position < chars.count, !chars[position].isWhitespace, chars[position] != ">" {
                        value.append(chars[position])
                        position += 1
                    }
                }
            }
            attributes[key.lowercased()] = Self.decode(value)
        }
        index = min(position + 1, chars.count)
        return Tag(name: name.lowercased(), attributes: attributes, isClosing: isClosing)
    }

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "hellip": "…", "mdash": "—", "ndash": "–", "rarr": "→", "larr": "←", "middot": "·",
        "euro": "€", "times": "×", "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö",
        "Uuml": "Ü", "szlig": "ß",
    ]

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            guard let semicolon = after.prefix(12).firstIndex(of: ";") else {
                result += "&"
                rest = after
                continue
            }
            let entity = after[..<semicolon]
            var replacement: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if entity.hasPrefix("#") {
                replacement = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = entities[String(entity)]
            }
            if let replacement {
                result += replacement
                rest = after[after.index(after: semicolon)...]
            } else {
                result += "&"
                rest = after
            }
        }
        return result + rest
    }
}

private extension OmpForm.Kind {
    var isGroupMember: Bool {
        switch self {
        case .radio, .checkbox: true
        default: false
        }
    }

    var isSelect: Bool {
        if case .select = self { return true }
        return false
    }
}
