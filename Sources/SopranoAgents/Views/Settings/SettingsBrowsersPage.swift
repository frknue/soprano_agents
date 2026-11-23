import AppKit
import SopranoAgentsCore

/// Settings › Browsers: external Chromium-family browser profiles over Chrome DevTools Protocol
/// (CDP — never WebKit), workspace routing rules, and live launch/status controls.
extension SettingsController {
    func browsersPage(_ form: SettingsForm) -> [NSView] {
        let browsers = center.settings.browsers
        let defaults = BrowserSettings()

        func reset(_ key: String, isDefault: Bool) -> (() -> Void)? {
            isDefault ? nil : { [weak self] in self?.remove(["browsers", key]) }
        }

        let enabledToggle = form.toggle(browsers.enabled, label: "Enable AI browsers") { [weak self] isOn in
            self?.write(isOn, at: ["browsers", "enabled"])
        }
        let devtoolsToggle = form.toggle(browsers.includeChromeDevtoolsMcp, label: "Include Chrome DevTools MCP", enabled: browsers.enabled) { [weak self] isOn in
            self?.write(isOn, at: ["browsers", "includeChromeDevtoolsMcp"])
        }

        var generalRows: [NSView] = [
            form.row(
                "Enable AI browsers",
                description: "Share external Chromium-family browser profiles over CDP (127.0.0.1:<port>) across omp, Codex, Claude Code, Antigravity and OpenCode. Never embeds WebKit.",
                reset: reset("enabled", isDefault: browsers.enabled == defaults.enabled),
                control: enabledToggle
            ),
            form.row(
                "Include Chrome DevTools MCP",
                description: "Also inject chrome-devtools-mcp pointing at the resolved profile's CDP port for non-omp sessions.",
                reset: reset("includeChromeDevtoolsMcp", isDefault: browsers.includeChromeDevtoolsMcp == defaults.includeChromeDevtoolsMcp),
                control: devtoolsToggle
            ),
        ]

        if !browsers.profiles.isEmpty {
            var options = [SelectOption(title: "First profile (\(browsers.profiles[0].label))", value: "")]
            for (index, profile) in browsers.profiles.enumerated() {
                options.append(SelectOption(title: "\(profile.label) (:\(profile.port))", value: profile.id, separatorBefore: index == 0))
            }
            let defaultPicker = form.select(options, selected: browsers.defaultProfile ?? "", width: 224, label: "Default profile") { [weak self] value in
                if value.isEmpty { self?.remove(["browsers", "defaultProfile"]) } else { self?.write(value, at: ["browsers", "defaultProfile"]) }
            }
            generalRows.append(form.row(
                "Default profile",
                description: "Profile used when no workspace rule or external resolver matches.",
                reset: reset("defaultProfile", isDefault: browsers.defaultProfile == nil),
                control: defaultPicker
            ))
        }

        var sections: [NSView] = [
            form.section(
                "Chromium CDP browsers",
                note: "Agents open background tabs in your configured Chromium profiles (Chrome, Chrome Beta, Chromium, Brave) and close only tabs they created.",
                generalRows
            ),
        ]

        if browsers.profiles.isEmpty {
            let addStarter = form.button("Add default profile", size: .xs) { [weak self] in
                guard let self else { return }
                let starter: [[String: Any]] = [[
                    "id": "default",
                    "label": "Default",
                    "port": 9333,
                ]]
                self.write(true, at: ["browsers", "enabled"])
                self.write(starter, at: ["browsers", "profiles"])
            }
            let editButton = form.button("Edit settings.json", size: .xs) { [weak self] in
                self?.center.openInEditor()
            }
            sections.append(form.section("Profiles", [
                form.row(
                    "No browser profiles configured",
                    description: "Add a Chromium profile (id and local CDP port) here or under \"browsers.profiles\" in settings.json.",
                    control: form.group([addStarter, editButton], spacing: 8)
                ),
            ]))
        } else {
            var controlsByProfile: [String: (status: ThemedLabel, button: TextButton)] = [:]
            let profileRows = browsers.profiles.map { profile -> NSView in
                let statusLabel = ThemedLabel("Checking…", size: Typography.smallSize, weight: .medium, role: { $0.mutedForeground })
                let actionButton = form.button("Launch", size: .xs) { [weak self] in
                    guard let engine = self?.engine else { return }
                    statusLabel.stringValue = "Launching…"
                    Task { @MainActor in
                        do {
                            let status = try await engine.launchBrowserProfile(profile.id, initialURL: "about:blank")
                            statusLabel.stringValue = status.isRunning ? (status.browserVersion ?? "Running") : "Started"
                        } catch {
                            statusLabel.stringValue = error.localizedDescription
                        }
                    }
                }
                controlsByProfile[profile.id] = (statusLabel, actionButton)
                let dataDir = (profile.resolvedUserDataDirectory() as NSString).abbreviatingWithTildeInPath
                return form.row(
                    profile.label,
                    description: "\(profile.cdpURL) · \(dataDir)",
                    control: form.group([statusLabel, actionButton], spacing: 10)
                )
            }
            let capturedControls = controlsByProfile
            Task { @MainActor [weak self] in
                guard let engine = self?.engine else { return }
                let statuses = await engine.probeBrowserProfiles()
                for status in statuses {
                    guard let pair = capturedControls[status.profileID] else { continue }
                    if status.isRunning {
                        pair.status.stringValue = status.browserVersion ?? "Running"
                        pair.button.title = "Open tab"
                    } else {
                        pair.status.stringValue = "Stopped"
                        pair.button.title = "Launch"
                    }
                }
            }
            sections.append(form.section("Profiles", profileRows))
        }

        let rulesDescription = browsers.rules.isEmpty
            ? "No path or git-remote rules configured. Add \"browsers.rules\" in settings.json to route repos to specific profiles."
            : browsers.rules.map { rule in
                let matchers = rule.pathPrefixes + rule.projectNames + rule.gitRemoteSubstrings
                return "\(rule.profileID): \(matchers.joined(separator: ", "))"
            }.joined(separator: " · ")

        let resolverDescription = browsers.resolverCommand.map { $0.joined(separator: " ") }
            ?? "Not configured. Set \"browsers.resolverCommand\" in settings.json to delegate profile lookup to an external script."
        let mcpDescription = browsers.customMcpCommand.map { spec -> String in
            switch spec.transport {
            case let .stdio(command, _, _): "\(spec.name): \(command)"
            case let .http(url, _): "\(spec.name): \(url)"
            }
        } ?? "Built-in CDP browser MCP (SopranoAgents mcp browser). Set \"browsers.customMcpCommand\" in settings.json to override."

        sections.append(form.section("Routing & MCP", [
            form.row(
                "Routing rules (\(browsers.rules.count))",
                description: rulesDescription,
                control: form.button("Edit settings.json", size: .xs) { [weak self] in self?.center.openInEditor() }
            ),
            form.row("External resolver", description: resolverDescription),
            form.row("Browser MCP server", description: mcpDescription),
        ]))

        return sections
    }
}
