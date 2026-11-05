import AppKit
import SopranoAgentsCore

/// Team module: create, edit and delete teammates (the sidebar's Team section, the chat header's
/// teammate menu). Teammates are threads, so selecting and navigating them are thread commands.
@MainActor
enum TeamCommands {
    static var all: [AppCommand] {
        [
            AppCommand(
                id: "team.new",
                title: "New Teammate…",
                description: "Create a long-lived teammate to chat with and delegate to",
                category: .thread,
                icon: "person.badge.plus"
            ) { context in
                guard let engine = context.engine, let state = context.state else { return }
                TeamActions.newTeammate(engine: engine, state: state, window: context.window)
            },
            AppCommand(
                id: "team.edit",
                title: "Edit Teammate…",
                description: "Change the selected teammate's name, handle, role or instructions",
                category: .thread,
                icon: SidebarSymbol.pencil,
                isEnabled: { selectedTeammate($0) != nil }
            ) { context in
                guard let engine = context.engine, let state = context.state, let thread = selectedTeammate(context) else { return }
                TeamActions.edit(thread.id, engine: engine, state: state, window: context.window)
            },
            AppCommand(
                id: "team.delete",
                title: "Delete Teammate…",
                description: "Delete the selected teammate with its conversation and memory",
                category: .thread,
                icon: SidebarSymbol.trash,
                isEnabled: { selectedTeammate($0) != nil }
            ) { context in
                guard let engine = context.engine, let state = context.state, let thread = selectedTeammate(context) else { return }
                TeamActions.delete(thread.id, engine: engine, state: state, window: context.window)
            },
        ]
    }

    /// The selected thread when it is a teammate's.
    private static func selectedTeammate(_ context: CommandContext) -> AgentThread? {
        guard let thread = context.thread, thread.teammate != nil else { return nil }
        return thread
    }
}
