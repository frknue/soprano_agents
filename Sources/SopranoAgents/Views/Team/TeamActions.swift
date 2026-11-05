import AppKit
import SopranoAgentsCore

/// Teammate actions shared by the sidebar's Team section, the chat header and the commands: the
/// New / Edit Teammate dialog, delete, and a teammate's action menu. A teammate is a thread
/// (`AgentThread.teammate`), so opening one is `ThreadActions.open`.
@MainActor
enum TeamActions {
    static func newTeammate(engine: AgentEngine, state: WorkspaceState, window: NSWindow?) {
        TeammateDialog.present(.create, engine: engine, state: state, in: window)
    }

    static func edit(_ threadID: String, engine: AgentEngine, state: WorkspaceState, window: NSWindow?) {
        guard engine.thread(threadID)?.teammate != nil else { return }
        TeammateDialog.present(.edit(threadID: threadID), engine: engine, state: state, in: window)
    }

    /// Confirms, then deletes the teammate's thread (the engine removes its omp export and memory).
    static func delete(_ threadID: String, engine: AgentEngine, state: WorkspaceState, window: NSWindow?) {
        guard let thread = engine.thread(threadID), let teammate = thread.teammate else { return }
        Task { @MainActor in
            let confirmed = await Dialogs.confirm(
                title: "Delete teammate “\(teammate.name)”?",
                message: "This permanently deletes \(teammate.name)’s conversation and memory. Threads can no longer message @\(teammate.handle).",
                confirmTitle: "Delete Teammate",
                isDestructive: true,
                in: window
            )
            guard confirmed else { return }
            ThreadActions.leave(thread, state: state)
            await engine.deleteThread(threadID)
        }
    }

    /// A teammate's action menu: Find in thread (when open), Edit Teammate…, Mark unread, Copy,
    /// Delete Teammate…. Thread-only actions (pin, settle, rename, archive) do not apply.
    static func menu(for threadID: String, engine: AgentEngine, state: WorkspaceState, window: NSWindow?) -> NSMenu? {
        guard let thread = engine.thread(threadID), let teammate = thread.teammate else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false

        if state.selectedThreadID == threadID,
           let controller = window?.windowController as? MainWindowController,
           CommandRegistry.shared.command("chat.find") != nil {
            menu.addItem(ActionMenuItem("Find in thread", symbol: SidebarSymbol.textSearch) {
                controller.perform("chat.find")
            })
            menu.addItem(.separator())
        }
        menu.addItem(ActionMenuItem("Edit Teammate…", symbol: SidebarSymbol.pencil) {
            edit(threadID, engine: engine, state: state, window: window)
        })
        menu.addItem(ActionMenuItem("Mark unread", symbol: SidebarSymbol.mailOpen) {
            engine.markUnread(threadID)
        })

        menu.addItem(.separator())
        let copyItem = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
        copyItem.image = NSImage.symbol(Icon.copy, size: 13)
        let copyMenu = NSMenu()
        copyMenu.autoenablesItems = false
        copyMenu.addItem(ActionMenuItem("Handle", symbol: "at") { ThreadActions.copy("@\(teammate.handle)") })
        let path = engine.workingDirectory(for: thread)
        copyMenu.addItem(ActionMenuItem("Path", symbol: "folder") { ThreadActions.copy(path) })
        copyMenu.addItem(ActionMenuItem("Thread ID", symbol: SidebarSymbol.hash) { ThreadActions.copy(threadID) })
        copyItem.submenu = copyMenu
        menu.addItem(copyItem)

        menu.addItem(.separator())
        let delete = ActionMenuItem("Delete Teammate…", symbol: SidebarSymbol.trash) {
            TeamActions.delete(threadID, engine: engine, state: state, window: window)
        }
        delete.attributedTitle = NSAttributedString(string: "Delete Teammate…", attributes: [
            .foregroundColor: PaletteCenter.shared.palette.errorForeground,
            .font: NSFont.menuFont(ofSize: 0),
        ])
        menu.addItem(delete)
        return menu
    }
}
