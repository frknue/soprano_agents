import AppKit
import CoreImage
import SopranoAgentsCore

/// Settings › Phone: phone access (`remote.*`), the pairing link with its QR code, paired
/// devices, and what keeps the Mac reachable.
extension SettingsController {
    func phonePage(_ form: SettingsForm) -> [NSView] {
        let settings = center.settings.remote
        let defaults = AppSettings.Remote()
        let access = RemoteAccess.current
        func reset(_ key: String, isDefault: Bool) -> (() -> Void)? {
            isDefault ? nil : { [weak self] in self?.remove(["remote", key]) }
        }
        func toggle(_ key: String, _ isOn: Bool, label: String, enabled: Bool = true) -> SwitchControl {
            form.toggle(isOn, label: label, enabled: enabled) { [weak self] value in self?.write(value, at: ["remote", key]) }
        }

        let (statusText, isProblem) = Self.phoneStatus(access?.state, enabled: settings.enabled)
        var accessRows = [form.row(
            "Phone access",
            description: statusText,
            descriptionRole: isProblem ? { $0.warningForeground } : nil,
            reset: reset("enabled", isDefault: settings.enabled == defaults.enabled),
            control: settings.enabled && isProblem
                ? form.group([form.button("Retry") { access?.republish() }, toggle("enabled", settings.enabled, label: "Phone access")])
                : toggle("enabled", settings.enabled, label: "Phone access")
        )]
        if let access, settings.enabled, let link = access.pairingLink {
            accessRows.append(form.row(
                "Pair a phone",
                description: """
                Scan the code with the phone's camera to open the web app. To keep it on the Home Screen, \
                choose Share › Add to Home Screen in Safari, open it from there and paste the pairing link \
                when it asks (Copy pairing link, then paste on the phone). Each link pairs one device; a \
                new one appears here after each pairing.
                """,
                control: form.group([
                    Self.qrCodeView(for: link.absoluteString),
                    NSStackView.vertical([
                        form.button("Copy pairing link", symbol: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link.absoluteString, forType: .string)
                        },
                        form.button("New pairing link", variant: .ghost) { access.rotatePairingCode() },
                    ]),
                ], spacing: 12)
            ))
        }

        var sections = [form.section("Phone access", note: "Continue threads from your phone: Soprano Agents serves a web app that only devices on your tailnet can reach.", accessRows)]

        if let access {
            let devices = access.store.devices.sorted { $0.pairedAt > $1.pairedAt }
            let now = Date()
            let rows = devices.isEmpty
                ? [form.row("No paired devices", description: "A phone appears here once it opens the pairing link.")]
                : devices.map { device in
                    let seen = device.lastSeenAt.map { "last seen \(DurationText.relative($0, now: now))" } ?? "not seen since pairing"
                    return form.row(
                        device.name,
                        description: "Paired \(DurationText.relative(device.pairedAt, now: now)) · \(seen)",
                        control: form.button("Revoke", variant: .destructiveOutline) { access.revoke(deviceID: device.id) }
                    )
                }
            sections.append(form.section("Paired devices", rows))
        }

        let port = form.field(String(settings.port), placeholder: String(defaults.port), width: 90, identifier: "remote.port", mono: true) { [weak self] value in
            self?.writePort(value, key: "port")
        }
        let httpsPort = form.field(String(settings.httpsPort), placeholder: String(defaults.httpsPort), width: 90, identifier: "remote.httpsPort", mono: true) { [weak self] value in
            self?.writePort(value, key: "httpsPort")
        }
        sections.append(form.section("Keep it reachable", [
            form.row(
                "Push notifications",
                description: "Notify paired phones when a thread finishes, fails, or needs input or approval while you are away from the Mac. Turn them on in the web app's settings on the phone.",
                reset: reset("push", isDefault: settings.push == defaults.push),
                control: toggle("push", settings.push, label: "Push notifications", enabled: settings.enabled)
            ),
            form.row(
                "Open at login",
                description: access?.state.loginItemProblem ?? "Start Soprano Agents when you log in. With phone access on, closing the window keeps it running.",
                descriptionRole: access?.state.loginItemProblem == nil ? nil : { $0.warningForeground },
                reset: reset("launchAtLogin", isDefault: settings.launchAtLogin == defaults.launchAtLogin),
                control: toggle("launchAtLogin", settings.launchAtLogin, label: "Open at login", enabled: settings.enabled)
            ),
            form.row(
                "Keep awake",
                description: "Keep the Mac from sleeping while it runs on power. Closing the lid still puts it to sleep.",
                reset: reset("preventSleep", isDefault: settings.preventSleep == defaults.preventSleep),
                control: toggle("preventSleep", settings.preventSleep, label: "Keep awake", enabled: settings.enabled)
            ),
            form.row(
                "Ports",
                description: "The local server port (127.0.0.1 only) and the HTTPS port Tailscale Serve publishes it on.",
                reset: reset("port", isDefault: settings.port == defaults.port && settings.httpsPort == defaults.httpsPort).map { action in
                    { [weak self] in
                        action()
                        self?.remove(["remote", "httpsPort"])
                    }
                },
                control: form.group([port, httpsPort])
            ),
        ]))
        return sections
    }

    private func writePort(_ value: String, key: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            remove(["remote", key])
        } else if let port = Int(trimmed), (1...65535).contains(port) {
            write(port, at: ["remote", key])
        } else {
            render(resetScroll: false)
        }
    }

    /// The access row's description and whether it reports a problem.
    static func phoneStatus(_ state: RemoteAccess.State?, enabled: Bool) -> (String, Bool) {
        guard enabled else { return ("Off. Turn it on to reach your threads from your phone.", false) }
        guard let state else { return ("Phone access starts with the app.", false) }
        switch state.server {
        case .off, .starting:
            return ("Starting…", false)
        case let .failed(message):
            return ("The server could not start: \(message)", true)
        case .running:
            break
        }
        switch state.tailscale {
        case nil:
            return ("Publishing on your tailnet…", false)
        case let .published(url):
            return ("Open \(url.absoluteString) on any device in your tailnet.", false)
        case .notInstalled:
            return ("Install Tailscale on this Mac and your phone to reach the web app.", true)
        case let .notConnected(message):
            return ("Tailscale is not connected: \(message)", true)
        case let .conflict(message), let .failed(message):
            return (message, true)
        }
    }

    /// A 132 pt QR code of `text`: dark modules on a light field in either appearance (phone
    /// cameras read inverted codes poorly), from the palette's foreground and background.
    static func qrCodeView(for text: String) -> NSView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 132),
            view.heightAnchor.constraint(equalToConstant: 132),
        ])
        view.setAccessibilityLabel("Pairing QR code")
        let palette = PaletteCenter.shared.palette
        guard let filter = CIFilter(name: "CIQRCodeGenerator"), let colors = CIFilter(name: "CIFalseColor") else { return view }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let (dark, light) = palette.isDark ? (palette.background, palette.foreground) : (palette.foreground, palette.background)
        colors.setValue(CIColor(color: dark) ?? CIColor.black, forKey: "inputColor0")
        colors.setValue(CIColor(color: light) ?? CIColor.white, forKey: "inputColor1")
        colors.setValue(filter.outputImage, forKey: kCIInputImageKey)
        guard let output = colors.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return view }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        view.image = image
        return view
    }
}

private extension NSStackView {
    static func vertical(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }
}
