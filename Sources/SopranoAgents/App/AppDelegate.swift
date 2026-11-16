import AppKit
import SopranoAgentsCore

/// Normal launch: settings → palette → commands → menus → engine → main window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var windowController: MainWindowController?
    private(set) var engine: AgentEngine?
    private var menuController: MainMenuController?
    private var notifier: ThreadNotifier?
    private var remote: RemoteAccess?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.installApplicationIcon()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsCenter.shared
        settings.start()
        PaletteCenter.shared.apply(setting: settings.settings.theme)
        ThemeCenter.shared.startDrivingApplicationAppearance()

        AllCommands.registerAll()
        settings.reloadKeymap()

        let menu = MainMenuController(windowController: { [weak self] in self?.windowController })
        menu.install()
        menuController = menu

        // Accounts first: `start()` writes omp's account overlay before the engine's first probe
        // spawns omp. Only the real launch does this; tests and the snapshot harness keep the
        // inert or fixture source.
        AccountsCenter.source = AccountsController.shared
        AccountsController.shared.start()

        let engine = EngineFactory.live(settings: settings.settings.engineSettings)
        self.engine = engine

        settings.addObserver(self) { [weak self] in
            let current = SettingsCenter.shared.settings
            PaletteCenter.shared.apply(setting: current.theme)
            EngineFactory.executablePaths.update(current.engineSettings)
            self?.engine?.settings = current.engineSettings
            self?.menuController?.install()
            self?.remote?.apply(current.remote)
        }

        let controller = MainWindowController(engine: engine)
        windowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let poster = UserNotificationPoster.make { [weak self] threadID in self?.openThread(threadID) }
        let remote = RemoteAccess(engine: engine, dataDirectory: AppPaths.dataDirectory())
        self.remote = remote
        remote.apply(settings.settings.remote)
        notifier = ThreadNotifier(engine: engine, poster: poster, remote: WebPushPoster(access: remote))

        Task { await engine.refreshProviders() }
    }

    /// A notification was clicked: show the window on that thread.
    private func openThread(_ threadID: String) {
        guard let controller = windowController else { return }
        controller.state.select(.thread(threadID))
        controller.bringForward()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// With phone access on, the app keeps running without a window so the phone can reach it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(remote?.isEnabled ?? false)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController?.bringForward() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let engine else { return .terminateNow }
        Task { @MainActor in
            await engine.shutdown()
            self.remote?.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    static func installApplicationIcon() {
        let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            ?? AppResources.bundle.url(forResource: "AppIcon", withExtension: "icns")
        if let url, let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
    }
}
