# Soprano Agents architecture

Soprano Agents is a native macOS GUI for coding agents in the Soprano family, `omp` (oh-my-pi),
OpenCode and Google's Antigravity CLI, colored by Soprano's themes: a thread inbox on the left, a
centered chat lane with a floating composer, collapsible work logs, per-turn diffs from hidden git
checkpoints, a terminal drawer and a right panel. Swift 6 + programmatic AppKit (no SwiftUI, no
storyboards), SPM, macOS 14+. The app talks to the `omp` CLI directly, to OpenCode's own
background service over its HTTP API and to `agy acp` over ACP; it runs no server of its own.

## Toolchain

```bash
export DEVELOPER_DIR=/Library/Developer/CommandLineTools PATH="/opt/homebrew/opt/swift/bin:$PATH"
swift build
swift test
.build/debug/SopranoAgents snapshot --out /tmp/shot.png --fixture demo [--appearance dark]
```

`ld: warning: building for macOS-14.0 …` link warnings are expected.

## Modules and ownership

| Path | Module | Contents |
|---|---|---|
| `Sources/SopranoAgentsCore/Models/` | Contract | Domain types: `Project`, `AgentThread`, `Turn`, `TurnItem(Kind)`, approvals, user input, `ModelSelection`, `ProviderStatus`, `ThreadStatus`/`InboxSection`, `DurationText`, `JSONValue`. Foundation only. |
| `Sources/SopranoAgentsCore/Providers/ProviderSession.swift` | Contract | `ProviderDriver`, `ProviderSession`, `ProviderEvent`, `SessionConfig`, `TurnInput`. |
| `Sources/SopranoAgentsCore/Providers/` (rest) | Providers | `LineProcess` (stdio JSON-lines transport); the omp driver, session, RPC client and event mapper; the OpenCode driver, server connection (`OpencodeServer`), session, protocol and event mapper; the Antigravity driver, session, protocol and event mapper on `AcpClient` (ACP JSON-RPC); `LineDiff`; model catalog, `generateJSON`. |
| `Sources/SopranoAgentsCore/Engine/` | Engine | `AgentEngine` (state owner, observers, inbox lifecycle), `AgentEngine+Turns.swift` (sessions, sending, steering, queue, approvals, checkpoints, revert, diffs, titles, git actions), `AgentEngine+Files.swift` (workspace files) and `AgentEngine+Usage.swift` (usage history for the statistics board). `EngineTypes.swift` is contract. |
| `Sources/SopranoAgentsCore/Files/` | Files | `WorkspaceFileService` (contract), `WorkspaceFileContent`, `WorkspaceFilePath` (the one escape check), `LiveWorkspaceFileService`. |
| `Sources/SopranoAgentsCore/Resources/` | Resources | `ResourceModels` (`ResourceSettings`, `SharedSkill`, `SharedCommand`, `SharedRule`, `SharedMCPServer`, `ResolvedResources`), `ResourceCatalog` (discovery across `~/.config/soprano-agents/`, `~/.agents/skills`, `extraDirectories`, project overrides, `importMcpFiles`, inline `mcpServers`; per-provider MCP filtering, system-prompt appendix, shared command/skill prompt expansion). |
| `Sources/SopranoAgentsCore/Usage/UsageStatistics.swift` | Contract | `UsageStatisticsService`, `UsagePeriod` (buckets), `UsageGroup`, `UsageTotals`, metric/part enums. |
| `Sources/SopranoAgentsCore/Usage/` (rest) | Usage | `UsageHistory` / `UsageSummary` (bucketing, model filter, breakdowns), `UsageFolderName` (omp's session folder names), `OmpUsageStatistics` (`omp stats` sync + read-only `stats.db` query). |
| `Sources/SopranoAgentsCore/Store/` | Engine | `JSONFileThreadStore`. |
| `Sources/SopranoAgentsCore/Git/GitService.swift` | Contract | `GitService`, `SourceControlWriter`, status/branch/action value types. |
| `Sources/SopranoAgentsCore/Git/` (rest) | Git | `GitRunner` (the only place that spawns git), `LiveGitService` (checkpoints, diffs, status, branches, worktrees, commit/push/PR via `gh`), parsers. |
| `Sources/SopranoAgents/Theme/` | Shared kit | `Palette` + `PaletteCenter`, `Typography`, `Metrics`, `Radius`, `Icon`, `PaletteView`, `InteractiveView`, `GhostIconButton`, `TextButton`, `KbdView`. |
| `Sources/SopranoAgents/Shell/`, `App/`, `Views/Palette/`, `Views/Settings/`, `Notifications/`, `Commands/AppCommand.swift`, `ShellCommands.swift` | Shell | App delegate, menus, window, workspace layout, `WorkspaceState`, settings (`SettingsCenter`, resolver, template), keymap + router, `Dialogs`, command palette, settings screen, notifications, snapshot harness. |
| `Sources/SopranoAgents/Remote/` (Swift), `Remote/Web/` (web app), `App/ServeCommand.swift`, `Views/Settings/SettingsPhonePage.swift` | Remote | Phone access: `RemoteAccess` (lifecycle, login item, keep awake, push poster), `HTTPServer`, `RemoteAPI`, `RemoteStore` (pairing, devices, VAPID, subscriptions), `RemoteTerminals`, `RemoteTheme`, `TailscaleServe`, `WebPush`; the PWA; Settings › Phone; the `serve` harness. |
| `Sources/SopranoAgents/Views/Sidebar/`, `Views/Chat/ChatHeaderView.swift`, `SidebarCommands.swift` | Sidebar | Thread inbox (with subagent rows under their thread's card, `SubagentActions`), the Team section (`SidebarTeamCells`), chat header + title-bar toggles. |
| `Sources/SopranoAgents/Views/Team/`, `Commands/TeamCommands.swift` | Team | `TeamActions` (New / Edit / Delete Teammate, the teammate menu), `TeammateDialog`, `TeammateAvatarView`. |
| `Sources/SopranoAgents/Views/Timeline/`, `TimelineCommands.swift` | Timeline | Message timeline, Markdown renderer, work log, cards. |
| `Sources/SopranoAgents/Views/Composer/`, `ComposerCommands.swift` | Composer | Composer, pickers, context meter + card, `/` command menu, side-question panel, draft hero + context strip. |
| `Sources/SopranoAgents/Views/Panels/`, `PanelCommands.swift` | Panels | Right panel (tabs, launcher; Diff, Files explorer, file viewer and terminal surfaces), terminal drawer, `ThreadTerminalStore` (every terminal of the window), Thread details card (editor, scripts, branch, git actions). |
| `Sources/SopranoAgents/Views/Accounts/`, `Views/Settings/SettingsAccountsPage.swift`, `Commands/AccountCommands.swift`, `Fixtures/AccountFixtures.swift` | Accounts | `AccountsSource` / `AccountsCenter` (the UI's only door to accounts), sidebar account button, usage card, Settings → Accounts, account fixtures. |
| `Sources/SopranoAgents/Views/Statistics/`, `Commands/StatisticsCommands.swift`, `Fixtures/FixtureUsageStatistics.swift` | Statistics | Statistics board (header, periods, Cost/Tokens, tiles, stacked chart, model/project/agent breakdowns), `StatisticsFormat`, fixture usage history. |
| `Sources/SopranoAgents/Fixtures/` | Shell | `DemoFixtures` scenarios + `FixtureGitService` and `FixtureWorkspaceFiles` for snapshots and UI tests. |
| `Sources/SopranoAgents/Vendored/` | — | Copied from Soprano by `scripts/sync-soprano-chrome.sh`, including `Vendored/Accounts/` (Soprano's accounts layer: `AccountsController` and its account managers, `AccountLaunchState`, `UsageAPI`). **Never edit.** |

Modules talk only through the contracts: views read `AgentEngine` state and call its methods;
UI state goes through `WorkspaceState`; commands through `CommandRegistry`. A view never talks to
a provider and never spawns git: read-only git queries (status, branches) go through
`engine.environment.git`, every write through an engine method. The only processes the UI layer
starts itself are terminal shells (SwiftTerm, drawer and right-panel tabs) and `NSWorkspace` opens (editor, Finder, URLs).

## Seams

### `AgentEngine` (Core/Engine)
`@MainActor`, the single owner of projects, threads, provider sessions and provider statuses.
Views read `projects`, `threads`, `thread(_:)`, `project(_:)`, `status(of:)`, `settings` and observe
`EngineEvent` with `engine.addObserver(self) { [weak self] event in … }`:

- `.projectsChanged`, `.threadListChanged` (add/remove, title, section, status pill, branch),
  `.threadChanged(threadID:)` (turns/queue/settings), `.itemChanged(threadID:turnID:itemID:)`
  (streaming deltas: re-render just that row), `.providersChanged`, `.commandsChanged` (re-read
  the command lists), `.subagentChanged(threadID:subagentID:)` (a subagent's runs or items,
  streaming too), `.subagentListChanged(threadID:)` (a subagent added, or its status or activity
  line changed: the sidebar), `.sideQuestionsChanged(threadID:)` (a side question asked,
  streaming, finished, or the history read).
- Mutations: `addProject`, `removeProject`, `rename`, `setPinned`, `setSettled`, `setArchived`,
  `markVisited`, `markUnread`, `setModelSelection`, `setRuntimeMode`,
  `launchThread`, `send`, `interrupt`, `respond`, `answer`, `dismissUserInput`, `sendQueuedNow`,
  `cancelQueued`, `revert`, `turnDiff`, `regenerateTitle`, `deleteThread`, `gitStatus`,
  `runGitAction`, `importAttachment`, `refreshProviders`, `shutdown`, `canCompact`, `compact`,
  `rememberCommands`, `loadCommands(forThread:)`, `loadCommands(forDraft:projectID:)`,
  `steerSubagent`, `cancelSubagent`, `askSideQuestion`, `cancelSideQuestion`,
  `loadSideQuestions`, `restoreSideQuestions`, `createTeammate`, `updateTeammate`. Reads:
  `subagent(_:_:)`, `sideQuestions(_:)`, `team`, `teammateThread(handle:)`, `teammateDraft(_:)`,
  `workingDirectory(of:)`, `workspaceKeys`, `workspaceLocation`,
  `workspaceFiles`, `readWorkspaceFile`, `workspaceFileURL` (all by `WorkspaceRef`: `.thread(id)`
  or `.draft(projectID:)`, the project root a "Current checkout" thread will use; `key` is the
  UI's per-workspace dictionary key), `commands(forThread:)`, `commands(forDraft:projectID:)`,
  `usageHistory(_:sync:)`, `usageFolderTitles()`.
  Contracts in the doc comments of `AgentEngine.swift`, `AgentEngine+Turns.swift`,
  `AgentEngine+Files.swift`, `AgentEngine+Workspace.swift`, `AgentEngine+Commands.swift`,
  `AgentEngine+SideQuestions.swift`, `AgentEngine+Team.swift` and `AgentEngine+Usage.swift`.

Engine behavior:
- Workspace: an agent only ever runs in the thread's working directory. Projectless threads get
  `<data>/scratch/<id>` created; any other missing folder (deleted worktree, moved or removed
  project) fails the turn with `EngineError.workspaceMissing` before anything spawns, and the
  provider sessions refuse a missing cwd too. A new-worktree thread owns its planned worktree
  path from launch, so during setup or after a failed setup nothing falls back to the project root.
- Turns recovered after a crash cancel their pending approvals and questions.
- One `ProviderSession` per thread, created lazily on first send (resumes `providerThreadID`
  after relaunch), closed on delete/shutdown. A thread runs on the provider of its
  `modelSelection`; `setModelSelection` with another provider forgets `providerThreadID` and
  `contextUsage`, and the next send closes the old provider's session and starts the new one's
  (the composer only offers that while the thread has no turns). Commands are kept per provider.
  Provider events fold into the open turn
  (`AgentThread.openTurn`, the last turn while `.running`): `itemUpdated` replaces by id, deltas
  append, approvals/user input become items, `turnCompleted` finishes the turn and starts the
  next queued message. Items arriving without an open turn are dropped, except an `advisory`,
  which joins the last turn.
- Yielded turns: `turnYielded(outcome, error)` (see omp below) sets `Turn.yieldedAt`
  (persisted; a failed yield also sets `failureMessage`): the answer is final, so
  `AgentThread.activeTurn`/`isRunning` skip the turn (no Working pill, Stop, "Working for" row,
  steering or approval bar; Edit from here and archive allowed), its live items settle, its
  checkpoint is captured, and a queued message starts after a completed yield. The turn stays
  open: `turnResumed` (background work woke the agent) clears `yieldedAt`, sets `resumedAt`
  (answers before it stop counting as the last word for the timeline's "Thinking"; cleared when
  the turn ends) and, on the first wake, `wokenAt` (kept: the timeline shows every answer of a
  woken turn instead of folding later ones as checks), and the run streams into it; `turnCompleted` ends it at
  `completedAt = yieldedAt` (or now after a resumed run).
  Anything that starts new work first ends the yielded turn (`releaseYieldedTurn`): `send`,
  `sendQueuedNow`, the queue, `compact`, `revert` call `ProviderSession.releaseYieldedTurn()`
  (default no-op), wait up to `EngineRuntime.yieldReleaseTimeout` (5 s) for its
  `turnCompleted`, else end it locally with its yielded outcome (`Turn.yieldedStatus`); then the
  message starts a new turn (never a steer, never interrupted). Session end, app quit and crash
  recovery also end a yielded turn with its yielded outcome. The timeline shows a yielded turn
  as finished plus a muted "Background work still running…" row (`.backgroundWork`).
- Checkpoints: before turn N, if `CheckpointRef.ref(thread, N-1)` is missing, capture it; after
  turn N ends (completed or interrupted), capture `ref(thread, N)` and store
  `TurnCheckpoint(files:)` from `changedFiles(ref(N-1), ref(N))`. Not a repo → status `.missing`.
- Turn diff N = `diff(ref(N-1), ref(N))`; thread diff = `diff(ref(0), ref(last))`.
- Revert to before turn N: interrupt guard, provider `rollback(beforeTurn:providerTurnID:)` for
  the earliest turn ≥ N that has a `providerTurnID` (none → no provider call, the conversation
  already ends there), optional `restoreCheckpoint(ref(N-1))`, delete refs ≥ N, drop turns ≥ N,
  return turn N's user message.
- Titles: first message → title seed (first 50 chars + "...") immediately, then
  `textGenerationModel` via `ProviderDriver.generateJSON` with the title prompt in
  `TextGeneration`.
- New worktree: branch `<branchPrefix>/<8 hex>` from the base branch at
  `<worktreesDirectory>/<repo>/<branch with / → ->`, renamed in the background to a generated name
  (`<branchPrefix>/<fragment>`).
- Persistence: every change goes through `ThreadStore` (JSON file per thread under
  `<data>/threads/`, projects in `<data>/projects.json`, atomic, coalesced writes). Streaming
  deltas are not written on every token; the store coalesces.
- Data root: `AppPaths.dataDirectory()` = `~/Library/Application Support/<bundle name>`
  (`SOPRANO_AGENTS_DATA_DIR` overrides). Attachments in `<data>/attachments/<uuid>/<name>`
  (passed to sessions as an additional directory); scratch threads work in `<data>/scratch/<thread>`.
- Workspace files (`EngineEnvironment.files`, default `LiveWorkspaceFileService`): in a git repo
  `ls-files -z --cached --others --exclude-standard` (searchable files; deleted ones are dropped)
  plus `ls-files -z --others --ignored --exclude-standard --directory` for the explorer's dimmed
  ignored entries (whole ignored folders as one "path/" entry, read one level at a time by
  `listDirectory` when opened, ≤ 5 000 entries); elsewhere a walk skipping `.git`, `node_modules`, `.build`, `DerivedData` (≤ 20 000
  files). Reads resolve symlinks and refuse anything outside the working directory; text up to
  2 MiB, images by extension up to 20 MiB, NUL or invalid UTF-8 = binary.
- Context: every `tokenUsage` event sets the latest turn's usage and `AgentThread.contextUsage`
  (persisted; `TokenUsage.fraction` = used / window). An "Edit from here" rewind sets it to the
  last kept turn's usage.
- Compaction: text that is exactly `/compact` (no attachments) runs as a compaction turn via
  `ProviderSession.compact()`. It needs a conversation and an idle thread, or `.queue`; messages
  sent during it are queued. The provider's notice (or error) lands in that turn.
- Commands: `ProviderEvent.commands([ProviderCommand])` lists are deduplicated by `insertText`,
  sorted (commands A–Z, then skills A–Z), kept per thread, and remembered per provider and
  workspace for drafts (a worktree thread's list also counts for its project; all scratch threads
  share one). Text starting with `/` reaches the provider with its first characters intact. A
  menu with nothing to list (no session this run) asks the provider driver
  (`ProviderDriver.commands(directory:)`, each provider and workspace once per run, answered or
  not; scratch threads read the shared scratch root); omp answers from a
  throwaway `omp --mode rpc --no-session --no-lsp` (`get_available_commands`, about 0.5 s).
- Subagents: `ProviderEvent.subagent(id:, SubagentEvent)` folds into `AgentThread.subagents`
  (persisted, start order; `AgentEngine+Subagents.swift`): `.updated` merges reported facts
  (agent, assignment, model, latest intent, status; a status other than running ends its open
  run), `.runStarted(message:)` appends a run (`Turn`, the waking message as its user message),
  `.message` adds a steer to the open run, item and delta events fold into the open run like a
  thread's, `.runEnded` ends it. `steerSubagent` / `cancelSubagent` need a running subagent and
  the thread's live session (the message shows up when the subagent reports it). The session's
  end aborts running subagents; a crash-recovered thread loads them aborted. Identity: the
  provider's id (`Subagent.name`) is unique only within one omp session, so an event goes to the
  latest subagent of that name unless its reported transcript or starting tool call differs from
  the known one; then it gets a new entry (`Subagent.id` "Reader#2", `providerID` "Reader").
  Views select and address subagents by `id`; messages and Stop reach omp by `name`. "Edit from
  here" drops the subagents its rewound turns started.
- Side questions (`AgentEngine+SideQuestions.swift`, omp's `/btw`): `askSideQuestion(thread,
  question:, topicID:)` asks about the thread's conversation (a new topic, or a follow-up in
  one) beside any running turn; the answer never joins the conversation or the timeline. It needs
  a conversation (a live session or one to resume, which it starts like `send`) and refuses while
  another side question runs or starts. `cancelSideQuestion` also stops one still starting
  (`ThreadRuntime.isAskingSideQuestion`): before the session is up or omp took it, the ask throws
  `CancellationError` and nothing is asked; a topic omp started after a cancel that found nothing
  is cancelled right away. Never the thread's turn. Topics (`SideQuestion`: first exchange plus follow-ups, each with
  question, streamed answer, status, error) live in `ThreadRuntime.sideQuestions` (newest first,
  not persisted: omp keeps the history beside the session). `ProviderEvent.sideQuestion`
  replaces a topic, `.sideQuestionDelta` appends to a running topic's latest answer; the ask's
  own answer only adds a topic or follow-up not reported yet, so it never rolls back streamed
  text. `loadSideQuestions` reads the provider's history (resuming the session for a thread with
  a conversation and none this run; read once without a live session, again with one unless a
  side question runs); `restoreSideQuestions` merges the read into the list without rolling a
  known topic back (the read may predate events: a topic it lacks stays; the known copy wins with
  more follow-ups, when finished where the read still runs, or when it streamed further) and
  seeds the snapshot fixtures. `isStartingSideQuestion` reports an ask not reported yet (its
  changes announce `.sideQuestionsChanged`). The session's end marks a running topic
  interrupted; a new conversation id (a rewind's fork or new session) forgets the list.
- Typing aids (`AgentEngine+TextAssist.swift`, `EngineEnvironment.textAssistants`, one
  `TextAssistant` per provider for the whole run, closed at shutdown): `textAssistPreferences`
  (`TextAssistPreferences`: typo detection, autocorrect, word completion; no assistant = marks on,
  the rest off), `predictWord(provider, text:, cursor:)` (ghost-text suffix for the word ending at
  the UTF-16 `cursor`, nil when nothing applies; cancelling the caller abandons it) and
  `reportWordCompletion(…, accepted:)`. They work without a conversation, so drafts have them.
  `OmpTextAssistant` (built in `EngineFactory`) reads omp's `spelling.typoDetection`,
  `spelling.autocorrect` and `spelling.autocomplete` from `omp config list --json` (about 60 ms,
  fresh per call) and predicts with `predict_word {text, cursor}` → `{suffix}` /
  `predict_word_feedback {text, cursor, suggestion, accepted}` on one long-lived helper
  `omp --mode rpc --no-session --no-extensions --no-skills --no-rules --no-lsp` in the home folder,
  started by the first prediction (about 0.7 s cold, then under a millisecond; omp's text-predict
  daemon does the work, honors `spelling.autocomplete`, answers one request at a time and a
  superseded waiting one null; a request waits up to 155 s, omp's own budget for a cold daemon,
  unless the next keystroke cancels it). A helper that exits restarts with the next prediction, one that
  fails to start is not retried for 30 s, one idle for 10 minutes is stopped; feedback never starts it.
- Team (`AgentEngine+Team.swift`, `TeamTools.swift`, `Models/Team.swift`): a teammate is a
  thread carrying `AgentThread.teammate` (name, unique `handle`, role, instructions,
  `exportsToOmp`); its conversation, model, runtime mode, approvals and checkpoints are the
  thread's, its home folder the thread's working directory (a project root, or its scratch
  folder). Teammates stay on omp (`setModelSelection` ignores another provider), never sit in an
  inbox section, and `deleteThread` removes their files. `createTeammate` makes the empty thread
  on the default omp model; `updateTeammate` re-validates and, when persona or home changed, sets
  `ThreadRuntime.relaunchRequested` so the next turn's `ensureSession` starts a new process
  (resuming) between turns. Every omp conversation's `SessionConfig` comes from
  `sessionConfig(for:)`: `hostTools` = `TeamTools.definitions` (nothing for a normal thread while
  the team is empty; a teammate always gets `team_list`, `team_activity`, `team_create`,
  `team_update` and `team_delete`, `team_message` once others exist; the `to` enum lists the
  other handles, so `refreshTeamTools`
  re-sends them to every live omp session when the team changes). A teammate also gets
  `<data>/team/<thread>/persona.md` (`--append-system-prompt`: who it is, its instructions, the
  team rules) and `memory.yml` (`--config`: omp's Mnemopi memory backend with `scoping: global`
  and its own `memory/mnemopi.db`, so each teammate keeps a private long-term memory), both
  rewritten at every launch. Messages to a teammate reach omp with a header
  (`TeamTools.providerText`: "[Thu 2026-11-05 14:02 · from the user's thread “…”]", plus a
  reminder that the final answer is the reply; slash commands unchanged). Host tool calls
  (`ProviderEvent.hostToolCall`) are served in `runtime.hostToolTasks` and answered with
  `ProviderSession.finishHostTool`; `hostToolCancelled` or the session's end cancels them.
  `team_message {to, message}` delivers a `UserMessage` with `sender` through `deliver(…, mode:
  .queue)` (its own turn, queued behind running work, never a steer) and waits in
  `runtime.teamWaits` until that turn ends or yields (`resolveTeamWaits`, after the turn's
  checkpoint so the reply names its changed files; `TeamTools.reply`); a withdrawn message, a
  deleted teammate or a failed turn answers with an error. It refuses messaging oneself and a
  teammate that waits (directly or through others) on the caller. Cancelling the call withdraws
  the queued message or interrupts the turn working on it. `team_list` reports handle, role,
  status and home; `team_activity {teammate?, since?, until?}` lists the turns a teammate's
  thread started in the period (sender, request, answer, changed files, team messages it sent).
  `team_create {name, role, instructions?, handle?, home?}` (served only for a teammate) runs
  `createTeammate` like the dialog: the handle defaults to `suggestedHandle(name)`, `home` names a
  project by path or unique title (default: its own folder), validation errors come back as the
  tool's error, and the caller can message the new teammate as soon as the result returns.
  `team_update {teammate, name?, handle?, role?, instructions?, home?}` runs `updateTeammate` with
  only the passed fields changed (`home: own` = its own folder). `team_delete {teammate}` runs
  `deleteThread`; a teammate can't delete itself. All three are served only for a teammate.
  With `EngineEnvironment.ompAgentsDirectory` set (the app: `~/.omp/agent/agents`; tests and
  fixtures: nil) an opted-in teammate is also written to `<handle>.md` as an omp task agent
  (`TeamTools.ompAgentFile`, marked with its thread id; a file without that mark is never
  overwritten or deleted: the save returns a `warning`); handle changes, opting out and deletion
  move or remove it.

### Providers (Core/Providers)
`ProviderDriver` creates `ProviderSession`s, probes the CLI (`probe()` → version, health,
models), declares `ProviderCapabilities` (steering, rollback, Plan mode, native subagents, side
questions, MCP injection, system-prompt append, host tools), runs one-shot `generateJSON`, and
lists commands without a conversation (`commands(directory:)`). `OmpDriver`, `CodexDriver`,
`ClaudeDriver`, `AntigravityDriver` and `OpencodeDriver` implement it, one per `ProviderKind`
(`.omp`, `.codex`, `.claude`, `.antigravity`, `.opencode`; declaration order is display order); the
seam keeps the engine testable against a fake driver. `SessionConfig.mcpServers` carries OS-agnostic `MCPServerSpec`
definitions for session-level injection, and `TurnInput.interactionMode` (`.standard` / `.plan`)
drives Plan mode for providers that support it.

**Codex** — OpenAI's Codex CLI as an app-server (`codex app-server --stdio`), one process per
thread, speaking JSON-RPC 2.0 over `AcpClient` (path from `EngineSettings.codexPath` or PATH;
`AccountLaunchBridge.codexAdjustments()` injects `CODEX_HOME` for the chosen Codex CLI account).
Handshake: `initialize` (with `capabilities.experimentalApi:true`) → `initialized` notification →
`thread/resume` (for `providerThreadID`, falling back to `thread/start`) or `thread/start` (`cwd`,
`model`, `approvalPolicy`, `sandbox`, optional `developerInstructions` from `systemPromptFile`),
then `skills/list` for `/skill:<name>` menu entries. `SessionConfig.mcpServers` are passed as `-c
mcp_servers.<name>…` TOML overrides. Turns: `turn/start` with `input` (`text`, native `skill`
blocks for leading `/skill:<name>`, `localImage` blocks for image attachments), `approvalPolicy`,
`sandboxPolicy`, `model`, `effort`, `serviceTier:"fast"` (Fast Mode) and `collaborationMode`
(`"plan"` / `"default"` for Plan mode). Steer = `turn/steer {threadId, expectedTurnId, input}`;
Interrupt = `turn/interrupt` (5 s fallback grace); Compaction = `thread/compact/start`; Rollback =
`thread/rollback {threadId, numTurns}`. Approvals (`item/commandExecution/requestApproval`,
`item/fileChange/requestApproval`) and structured questions (`item/tool/requestUserInput`) arrive
as JSON-RPC server requests; `.fullAccess` auto-approves all, `.autoAcceptEdits` auto-approves file
changes. Events (`CodexEventMapper`): `item/agentMessage/delta`, `item/plan/delta`,
`item/reasoning/*`, `item/commandExecution/outputDelta`, `item/started|completed` (`agentMessage`,
`plan`, `reasoning`, `commandExecution`, `fileChange` with unified diffs, `mcpToolCall`,
`dynamicToolCall`, `collabAgentToolCall`, `webSearch`, `imageView`, `contextCompaction`),
`turn/plan/updated`, `thread/tokenUsage/updated`, `thread/compacted`, `turn/completed`. Probe:
`codex --version` plus a throwaway app-server for `account/read` and paginated `model/list`.
`generateJSON` runs an ephemeral read-only thread with `outputSchema`. Traces:
`Fixtures/codex-tool-turn.jsonl`.

**Claude Code** — Anthropic's Claude Code CLI (`claude --print --verbose --output-format
stream-json --input-format stream-json --include-partial-messages --permission-prompt-tool stdio
--forward-subagent-text --allow-dangerously-skip-permissions`), one process per thread over
`LineProcess` (path from `EngineSettings.claudePath` or PATH). Handshake: `control_request`
`initialize` → receives version, account plan, model catalog (with `supportedEffortLevels` and
`supportsFastMode`) and `/` commands/skills; `session_id` arrives on `system/init`. `SessionConfig.mcpServers`
are written to a per-session temp `--mcp-config` file and removed on close; `systemPromptFile` uses
`--append-system-prompt-file`. Before each turn, model and permission/Plan mode changes apply in
place (`set_model`, `set_permission_mode`: `plan`, `default`, `acceptEdits`, `auto`,
`bypassPermissions`). Turns send a `user` frame (text + base64 images up to 10 MB); steering sends
an additional `user` frame; Stop sends `control_request` `interrupt` (5 s fallback grace); `/compact`
runs Claude's native compaction. Approvals and `AskUserQuestion` arrive as `control_request`
`can_use_tool` and are answered via `control_response`. Events (`ClaudeEventMapper`): `stream_event`
text/thinking deltas, `assistant` tool uses (`Bash`, `Edit`/`MultiEdit`/`Write` diffs via `LineDiff`,
`Read`, `Grep`/`Glob`, `WebSearch`, `Task`/`Agent` subagents routed by `parent_tool_use_id`,
`TodoWrite`, MCP tools), `user` `tool_result`s, `system/compact_boundary` and `commands_changed`,
and `result` usage (`modelUsage.*.contextWindow`) + completion. Probe: `claude --version`,
`claude auth status`, and a short-lived `initialize` handshake. `generateJSON` runs `claude --print
--output-format json --json-schema … --no-session-persistence --tools "" --effort low`. Traces:
`Fixtures/claude-tool-turn.jsonl`.

**omp** (oh-my-pi) — `omp --mode rpc-ui --cwd <cwd> --approval-mode <mode>
[--model <provider/id>] [--thinking <level>] [--resume <session file>]`, one process per thread
(path from `EngineSettings.ompPath` or PATH; never `--no-ui`, which makes approvals fail closed).
omp's RPC (docs: `omp://rpc.md`) is JSONL, not JSON-RPC: commands `{id?, type, …}`, responses
`{type:"response", id, command, success, data|error}`, events in between. Handshake: wait for
`ready`, `negotiate_protocol {protocolVersion:2}` (large frames then arrive as base64
`rpc_chunk` sequences, reassembled by `OmpFrameDecoder`), `set_ask_dialog {enabled:true}` (a
build that rejects it keeps the `select`/`editor` fallback),
`set_event_filter {messageUpdates:"delta"}`, `get_state` (its `sessionFile` is the thread's
`providerThreadID`; a saved file that no longer exists starts fresh). Model slugs are
`provider/id`; `default` (`ModelSelection.configuredDefaultModel`) means omp's configured model (no
`--model`; after a `--resume`, which restores the session's saved model, `set_model` to the model
a throwaway `omp --mode rpc --no-session` in the thread's folder reports). Model, thinking and
fast-mode changes go to the live process (`set_model {provider, modelId}`, `set_thinking_level`,
`set_fast_mode`); a runtime-mode change relaunches with `--resume`. Runtime mode → approval mode: approval-required → `always-ask`, auto-accept-edits →
`write`, auto → `always-ask-cached`, full-access → `yolo`. Turns: `prompt {message, images?,
streamingBehavior:"steer"}` (attachment paths listed in the text; "steer" only matters when a
background job's run is live, where a plain `prompt` is refused); the turn ends at `prompt_result`
with the same id (extension runs such as auto-double-check happen before it), `completed` /
`aborted|interrupted|cancelled` → interrupted / else failed, or at the prompt's own ack when it
carries `agentInvoked:false` (a builtin slash command that ran locally; `OmpClient` also hands
that ack to the frame stream, so it ends the turn behind the command's `command_output` frames,
which become one final assistant message: Markdown kept, other multi-line text fenced, ANSI
escapes dropped; output after a prompt's ack, from builtins omp runs in the background such as
`/compact` and `/handoff`, is dropped while idle or during an agent turn, but frames carry no
prompt id, so one that arrives while a later slash command awaits its ack joins that command's
output). When the turn ends the session reads
`get_entries` and reports, via `turnStarted`, the first entry on the current branch after the
previous turn's tip (re-read at start and after a rewind) as the turn's `providerTurnID`: position,
not text, since omp rewrites skill invocations, templates and `^model` mentions. A turn whose start
cannot be located (entries unreadable, tip off the branch) gets `omp-unresolved`, which rollback
refuses instead of guessing; a turn that added nothing (local command) gets no id. A completed or failed `prompt_result`
with `sessionSettled:false` (async bash/task/eval jobs still running) yields the turn
(`turnYielded`, then `get_state` for the context fill) and holds the prompt: its dialogs and
interrupt stay live, a run those jobs wake (`agent_start`, `turn_start` or streamed text; not
the job's own `tool_execution_update`s on its call) reports `turnResumed` and streams into the
turn, and that run's terminal `agent_end` yields again. `session_settled` ends the held prompt
with its outcome (anchor, context fill, `turnCompleted`). `releaseYieldedTurn()` does the same
right away without sending anything to omp (the jobs keep running; a later `session_settled`
finds no held prompt and is ignored; runs they wake after that stream into whatever turn is
open, or are dropped). Settlement, Stop and release share one guarded ending, so a late anchor
never lands on the next turn. Stop ends the turn at once: an aborted `prompt_result`, any
`prompt_result` after Stop was pressed, or Stop while only background work is left (`abort`
does not stop background jobs). Steer = `steer`; from a non-yielded `prompt_result` on (while
the anchor and context fill are read) the session refuses steers (`noActiveTurn`) and the engine
queues the message, which starts the next turn once this one completes. Stop marks the turn
`stopRequestedAt` ("Stopping…") until it ends. Frames are parsed like `JSON.parse`: lone
surrogate escapes become U+FFFD instead of dropping the frame. Interrupt = `abort`. Host UI
arrives as `extension_ui_request`: a `select` titled `Allow tool:
<tool>\n<details>` is an approval (accept → `Approve Once` or `Approve`, acceptForSession → the
`… for this session` label or `Approve File`, decline → `Deny`, cancel → `cancelled:true`, all
answered as `extension_ui_response {id, value}`); other `select`, `confirm`, `input`, `editor` and
`ask` become user-input requests (answers `value`, `confirmed`, `answers[{id, selectedOptions,
customInput?}]`, dismissed → `cancelled:true`); `cancel {targetId}` withdraws one; `notify` is a
notice; dialogs arriving after the turn ended are cancelled. The `ask` tool walks an HTML form
field by field (`OmpUIRequest`): a radio group is a `select` with `selectionMarker:"radio"`, a
checkbox group one with `selectionMarker:"checkbox"`, `checkedIndices` and `markableCount` that
omp re-sends after every toggle until its trailing "Done selecting" action; both end their
marked rows with "Other (type your own)", whose pick is followed by an `input`; text fields are
`editor` with `prefill`. Each field shows as one question (choices only, the checked radio or
boxes preselected as `initialSelection`, the Other row as free text, `prefill` as
`initialText`); `OmpSession` sends the answer's first reply and answers the dialogs that follow
it from the rest (`OmpUIRequest.replies(to:)`: toggles of what changed, Other then the text,
the done action) without showing them, but only that field's own dialogs
(`OmpUIRequest.isFollowUp`: its `select` again with the same marker, options and question, or an
`input`/`editor` titled with its question; never an approval). Other dialogs in between are
shown; a `cancel` or the turn's end drops the rest. Events (`OmpEventMapper`):
`message_update` text/thinking deltas (item ids `<messageId>:<contentIndex>`, prefixed after a
relaunch), `tool_execution_start|update|end` → bash → command, write/edit/apply_patch/ast_edit →
fileChange (edit diffs converted from omp's line-numbered format; without one, a running call and a
write show the code their arguments carry, `OmpEditPreview`: write content as one numbered hunk
marked `FileChange.isFullContent`, hashline/apply_patch/sloppy/replace/patch edits as
unpositioned hunks), `toolcall_start|delta|end` of a write/edit/apply_patch call → that same
fileChange item while the model still streams it (partial argument JSON closed by
`OmpEditPreview.partialObject`, re-read on a new line, then every 1/64 of its size as it grows;
held until the earlier calls of its message ran), read/grep/glob/find → toolCall, web_search
→ webSearch, task → subagent, todo → "Updated tasks", ask → none, others → toolCall titled by
`intent`; assistant `usage` → token usage; an assistant `message_end` with `stopReason:"stop"`
marks its text final (the timeline drops "Thinking" under it and keeps every final answer out of
the closed fold; a resume keeps the flag, `Turn.resumedAt` brings "Thinking" back); an
advisor review (`message_end` of `role:"custom"`, `customType:"advisor"`, `details.notes[{note,
severity, advisor}]`) → `advisory` (one timeline row per note, never in the "Worked for" fold; one
arriving after the turn ended joins the latest turn); compaction/retry → notices. In a completed
turn that background work never woke (`Turn.wokenAt`, kept after the turn ends), an advisory or
an auto-double-check notice right after an answer that follows the first final answer (no steer
after it) starts the checks: `TimelineBuilder` keeps that first answer as the answer, and one
`checks` row under it (closed by default, `TimelineExpansion.checks`; open while Find has a query)
names each check and up to four lines of the reply's opening prose (`openingProse`), hiding
everything after the answer but errors and failed work after the last message. omp's final recap
(the first final answer after the last `auto-recap` notice that got one) is the one exception: it stays visible
below the `checks` row and carries the changed files (else the first answer does); reviews after
it stay in the checks, but a final answer after it (a reply to a review once omp's two recaps are
used) stays visible below it as the latest word, and no recap counts as a check's reply. Subagents: `set_subagent_subscription {level:"events"}` after the
handshake (`try?`: older builds show none); `OmpSubagentMapper` folds `subagent_lifecycle`
(status), `subagent_progress` (assignment, `lastIntent`, `resolvedModelIdentity`; repeats are
dropped) and `subagent_event` (the subagent's own session events: `agent_start` opens a run,
reported with the first `user` or `custom` message; `irc:incoming` messages read "From <agent>:
…", advisor reviews become one `advisory` (never opening a run: a pending run is named "Advisor
review", an idle subagent's review joins its last run), other custom messages notices; assistant
messages get a synthesized `messageId`
since subagent events carry none, then go through a per-subagent `OmpEventMapper`; tool
updates after a tool's end are dropped; `agent_end` ends the run, `stopReason` aborted →
interrupted, error → failed). `steer_subagent {subagentId, message}`, `cancel_subagent
{subagentId}`. A restart or the process's end reports running subagents aborted. Side questions:
`btw {question, recordId?}` (a follow-up names its topic; omp writes the started `btw_record`
before the response, then `btw_delta {recordId, delta}` frames and the finished `btw_record`),
`btw_cancel`, `get_btw_history` (`records`, newest first); a `BtwHistoryRecord` (`id`,
`question`, `answer`, `status` running/complete/cancelled/error/interrupted, `createdAt`/`updatedAt`
in epoch ms, `error?`, `followUps?`) becomes a `SideQuestion` (`OmpProtocol.sideQuestion`). omp's
command list has no `btw` under RPC. A restart or the process's end reports the running topic
interrupted with the answer streamed so far. Rollback before a turn: `get_entries`, the
turn's entry (its `providerTurnID`; turns recorded as `prompt-N` count user-authored, non-steering
user messages), then `fork {entryId}` of the last `message` entry before it on the current
branch, or `new_session` when none; the new `sessionFile` becomes the conversation id.
`navigate_tree` is not used: it only moves the leaf in memory and the next `--resume` restores
the old tip. No Plan mode (omp's RPC has no plan-mode switch). Probe:
`omp --version` plus a short-lived `omp --mode rpc --no-session --no-extensions --no-skills
--no-rules --no-lsp` for `get_state` and `get_available_models` (≈730 models: first `default`
named "<model> · configured", then "<name> · <provider>", effort = "off" + `thinking.efforts`).
The composer's model picker has an agent column (omp π, OpenCode's mark; `ProviderGlyph`) and
shows the first 80 matches of a multi-word search plus a "N more" row per agent. Picking another
agent's model switches a draft or a thread without turns (`ModelChoice.lockedProvider`); a thread
with turns keeps its agent.
Traces: `Tests/SopranoAgentsTests/Fixtures/omp-ask-write-edit-bash.jsonl`, `omp-builtin-yield.jsonl`
(`/context`, then an async bash job that yields, wakes the agent and settles), `omp-subagent.jsonl`
(a detached `sonic` subagent steered mid-run that gets a background-job notice and completes).
Teammates and host tools: `SessionConfig.systemPromptFile` → `--append-system-prompt <file>`,
`configOverlays` → `--config <file>` after the app's own; `hostTools` go out as `set_host_tools
{tools:[{name, label, description, parameters, loadMode:"essential"}]}` in the handshake (after
`set_subagent_subscription`, `try?`) and on `setHostTools`. omp asks with `host_tool_call {id,
toolCallId, toolName, arguments}` (before the call's `tool_execution_start`) → `hostToolCall`;
`finishHostTool` answers `host_tool_result {id, result:{content:[{type:"text", text}]},
isError?}` once per pending call; `host_tool_cancel {targetId}` → `hostToolCancelled`, and a
restart or the process's end cancels every pending call. The mapper titles `team_message` calls
"Message to <handle>" (category subagent, input = the message, output = the reply).

**OpenCode** — OpenCode 2.x's v2 HTTP API (`GET /openapi.json` on the server describes it) on
OpenCode's background service (`opencode serve --service`), the server the `opencode` TUI and CLI
share, so a thread's session also shows up there (path from `EngineSettings.opencodePath` or
PATH). `OpencodeServer` (one per driver) connects through the CLI, which finds the service and
starts it when it is down: `opencode api server.info` (`urls[0]`), `opencode api server.pair` (a
one-time code), redeemed at `GET <url>/auth/connect/<code>` for a token; requests send HTTP Basic
`opencode:<token>`, and a 401 or a refused connection pairs again once. Errors become
`ProviderError.rpc` with the server's `message`. `GET /api/event` is the server-sent event stream
(`{type, data}` per `data:` line, first `server.connected`); `OpencodeTransport` is the seam the
session tests fake. A folder OpenCode has not loaded yet answers empty lists for a moment, so
`/api/command` and `/api/model` are asked again for up to 1.5 s.
`OpencodeSession` per thread: open the stream, read `GET /api/model` + `/api/model/default`
(context windows, the configured model), resume `providerThreadID` (`GET /api/session/{id}`, the
`ses_…` id; 404 starts fresh) or `POST /api/session {location:{directory}, permissions, model}`.
Model slugs are `providerID/modelID` (split at the first `/`), `default` = OpenCode's configured
model; the effort option is the model's `variants` plus `default`. Before each turn the session
switches in place: `POST …/model {model:{id, providerID, variant}}`, `PATCH …{permissions}`.
Runtime mode → session permission rules (checked after the agent's own, last match wins):
approval-required asks for `edit`, `shell`, `external_directory`; auto-accept-edits allows `edit`
and asks for the other two; auto adds none; full-access allows `edit`, `shell`,
`external_directory`, `read`, `webfetch`, `websearch` (configured denies stay). Turns: `POST
…/prompt {text, files?, skills?}` (images as `file://` attachments, every path listed in the
text), a listed slash command `POST …/command {name, text}`, `/skill:<id> …` a prompt with that
skill attached. The session's next `session.inbox.enqueued` is the turn's user message: its id is
the `providerTurnID`. `session.execution.succeeded|failed|interrupted` ends the turn; events while
no turn of this app runs (another client driving the session) are ignored. Steer = `prompt
{delivery:"steer"}`; Stop = `POST …/interrupt` (`interrupted:false`: nothing ran at that moment;
after up to 1 s for a late end event, that same turn ends as interrupted, never a newer one).
`close()` interrupts what runs and closes the stream; a `close()` while `start` or a turn's model
and permission switch waits stops it there (no prompt is sent; a session created meanwhile is
deleted). The stream's end is `sessionEnded`.
Events (`OpencodeEventMapper`, item ids `<assistantMessageID>:text|reasoning:<ordinal>` and the
tool call id): text/reasoning deltas and `…ended`; `session.tool.called|success|failed` → shell →
command (`metadata.exit`; live output polled from `GET /api/shell/{shellID}/output?cursor=` twice a
second once `session.tool.progress` names the shell), edit/write/patch → fileChange
(`metadata.files[{file, patch, status}]` hunks; those paths are relative to OpenCode's project
root, so a one-file tool's absolute input path names the file; while running the input's code via
`OmpEditPreview`), read, glob/grep/list → search, websearch, subagent → subagent, todowrite →
"Updated tasks", question → none; a `permission.rejected` failure is declined, `aborted`
interrupted. `session.step.ended {finish, tokens}` → context fill (input + output + cache read +
write against `limit.context`), `finish:"stop"` marks the text final; compaction/retry → notices.
Approvals: `permission.asked` (of the session or a subagent's) → `approvalRequested` (shell and
edit approvals show the tool call's whole command line or absolute path), answered at `POST
/api/session/{owner}/permission/{id}/reply`: accept → `once`, acceptForSession → `always`,
decline → `reject` with a message (the agent carries on), cancel → `reject` (stops the run and
its other requests). Questions: `form.created` → `userInputRequested` (string/multiselect/
boolean/number fields; hidden and external ones left out), `POST …/form/{id}/reply {answer}`
(labels → option values), dismissed → `DELETE …/form/{id}`. `permission.replied`,
`form.replied|cancelled` from elsewhere withdraw them; the turn's end withdraws the rest.
Subagents: sessions created during a turn of this app with this one (or one of its subagents) as
`parentID`, named by their
`slug`; their events go through their own mapper (`session.inbox.enqueued` opens a run, the
assignment's "You are a subagent…" preface dropped; the execution's end ends it, status
completed/failed/aborted); the parent's `session.tool.progress {metadata.sessionID}` links the
starting tool call. Messages → `POST /api/session/{child}/prompt {delivery:"steer"}`, Stop → its
`interrupt`. A subagent a message woke after the turn keeps its live output; its approvals are
declined and its questions cancelled (nobody would see them, as omp cancels such dialogs).
Side questions: `POST …/generate {prompt}` (`OpencodeProtocol.sideQuestionPrompt`, follow-ups
carry the topic's earlier exchanges); OpenCode keeps no side-question history, so the driver's
`OpencodeSideQuestionStore` keeps this app run's topics per session id (a resumed session finds
them). Rollback: `POST …/revert/stage {messageID, files:false}` then
`POST …/revert/commit`. Probe: `opencode --version` plus the catalog (first `default` "<model> ·
configured", then "<name> · <providerID>"; none → unauthenticated). Traces:
`Fixtures/opencode-tool-turn.jsonl`, `opencode-edit-turn.jsonl`, `opencode-permission-turn.jsonl`
(reject all), `opencode-decline-turn.jsonl`, `opencode-question-turn.jsonl`,
`opencode-subagent-turn.jsonl`, `opencode-compaction.jsonl` (OpenCode 2.2.5).

**Antigravity** — Google's Antigravity CLI as an ACP agent: `agy acp --gemini-dir <data>/antigravity
--app-data-dir antigravity-acp`, one process per thread, with agy's own agent, system prompt and
tools (omp's `antigravity-cli` provider instead puts omp's prompt and tools on agy, which Google
answers with `429 RESOURCE_EXHAUSTED` for some of omp's instructions). Path from
`EngineSettings.antigravityPath`, else PATH and the tool directories, else the newest
`~/.omp/antigravity-cli/bin/<version>/agy` omp downloaded. The app keeps its own profile
(`AntigravityProtocol.profileDirectory`): its Google sign-in, conversations and settings never
touch `~/.gemini` or omp's. Children get `GEMINI_HOME=<profile>`, `SSH_CONNECTION` (agy 1.5 then
stores the sign-in in a file under the profile instead of one shared keychain entry),
`AGY_ACP_FORCE_FILE_STORAGE=1`, `AGY_CLI_DISABLE_AUTO_UPDATE=1`, and no `GEMINI_API_KEY` /
`GOOGLE_*` credential variables. Sign-in is `agy acp … --login` in the terminal drawer (Settings ›
Providers › Antigravity › Google account): it prints a Google link, the user pastes back the code
the callback page shows, the token lands in `antigravity-acp/antigravity-oauth-token`; that file
is what "signed in" means.
`AcpClient` speaks ACP: JSON-RPC 2.0 lines, requests matched by numeric id (`error` →
`ProviderError.rpc`), notifications and the agent's own requests (`session/request_permission`)
handed on in arrival order; other agent requests get `-32601`. An `ordered` request
(`session/prompt`) also puts its response on that stream, so the turn ends only after the updates
agy wrote before the answer have been read. `AntigravitySession`: `initialize`
(protocol 1, no client file system or terminal), `session/load {sessionId, cwd, mcpServers}` for
`providerThreadID` (the history replay is ignored; an unknown session starts fresh) or
`session/new {cwd, mcpServers}` (`_meta.antigravity.systemPrompt.append` carries
`SessionConfig.systemPromptFile` when agy offers it, and `mcpServers` carries shared MCP servers
converted by `AntigravityProtocol.mcpServers`). The ACP session id is the conversation id.
The selection goes in with `session/set_config_option` before each turn, only on change: `model`
(slugs are agy's ids such as `gemini-4-neon`; `default` = the model agy picked for the new
session), `thought_level` (the effort option) and `mode` (approval-required → `default`,
auto-accept-edits → `accept-edits`, auto and full-access → `auto`; full access also answers every
permission request itself). Turns: `session/prompt` (text with attachment paths, images up to
10 MB as image blocks); its answer, read in order behind the turn's updates, ends the turn it
answers (`cancelled` → interrupted, `refusal` → failed, an error → failed, else completed; a late
answer to a turn Stop already ended is ignored). No steering over ACP: `steer` refuses with `noActiveTurn`, so
follow-ups queue. Stop = `session/cancel` (open permission requests answered `cancelled`); a turn
agy has not ended 5 s later ends as interrupted and that agy is terminated (`sessionEnded`), so its
unanswered prompt and late updates never reach the next turn; the next message resumes the
conversation in a new process. `/compact` runs agy's command as a turn, its
usage report (the summary call, not the context fill) skipped, then a "Context compacted" notice.
Rollback refuses (agy cannot rewind an ACP conversation; each turn reports
`antigravity-turn-<n>` so Edit from here reaches the refusal), and there are no subagents or side
questions. Events (`AntigravityEventMapper`, message and thought ids `t<turn>/message-<n>`, tool
rows by `toolCallId`): `agent_message_chunk` → assistant text (a tool call or thought starts the
next message; the turn's last one is its answer), `agent_thought_chunk` → reasoning,
`tool_call`/`tool_call_update` merged → `execute` command (`rawInput.CommandLine`,
`rawOutput.output` without agy's "Created At…" preamble, `exit_code`), `edit`/`delete`/`move`
file change (`diff` content old/new text → `LineDiff` hunks), `read` "Read <path>", `search`,
other tools by agy's title; `plan` → one "Updated the plan" row; `usage_update {used, size}` →
context fill; `available_commands_update` → commands (`/<name> `). Approvals: `session/
request_permission` → `approvalRequested` (kind and detail from the tool call: command line or
file path); accept → the `allow_once` option, acceptForSession → `allow_always` (else
`allow_once`), decline → `reject_once`, cancel → `cancelled` plus Stop. Probe: `agy --version`;
no sign-in → unauthenticated; else a throwaway `session/new` in an empty temporary folder gives
the catalog (first `default` "<model> · default", then every `model` option value; efforts from
`models.availableModels` `<model>-<effort>` ids) and the plan (`_meta.antigravity.tier.name`,
shown after the version). Traces: `Fixtures/antigravity-tool-turn.jsonl` (read, approved edit and
command), `antigravity-decline-cancel.jsonl` (declined command, then a cancelled turn), agy
1.5.14, `>>` lines sent and `<<` lines received.

Context, compaction and commands:
- omp: `get_available_commands` after the handshake, then `available_commands_update`
  (`{name, source, aliases?, description?, input?{hint}, subcommands?}`); skills are
  `skill:<name>`; badges builtin → Built-in, skill → Skill, extension → Extension, mcp_prompt →
  MCP, custom/file → Custom. After each turn `get_state` → `contextUsage {tokens, contextWindow}`.
  `compact` is sent without a waiter (its response then arrives after `manual_compaction_end`),
  which gives the notice (committed / skip reason / cancelled) or an error; then `get_state` and
  `get_entries` (the compaction entry becomes the turn id). A skip ("Already compacted") is a
  failed response but the turn completes.
- OpenCode: `GET /api/command` (`/<name> `; names with `:` are MCP prompts) and `GET /api/skill`
  (`/skill:<id> `) at start and after a turn once `command.updated`/`skill.updated` arrived.
  `POST …/compact` runs as a turn (`session.compaction.ended` → notice, the compaction's inbox
  id becomes the turn id); the context fill updates with the next step.
- Antigravity: `available_commands_update` at session start and after changes; `/compact` is
  agy's own command run as a turn.
- Traces: `omp-commands-compact.jsonl`, `opencode-compaction.jsonl`.

Text generation: omp `-p --no-session --no-tools --no-extensions --no-skills --no-rules
--no-context-files --no-lsp [--model <provider/id>] --thinking low` (prompt plus schema on stdin,
first JSON object of stdout); OpenCode `POST /api/experimental/generate/text {prompt, model?}`
(no session, no tools; first JSON object of `data.text`); Antigravity a throwaway `agy acp`
session in an empty temporary folder (permission requests declined; first JSON object of the
streamed answer). `textGeneration.provider` picks the agent. 180 s timeout.

### Accounts (`Vendored/Accounts`, `Views/Accounts`)
Soprano's accounts layer is vendored unchanged. `AccountsController.shared.start()` runs only in
`AppDelegate`, before the engine is built: it writes omp's preference overlay into
`AccountLaunchState`. The app lists only omp's Claude and Codex logins (`AccountListID.ompClaude`,
`.ompCodex`, in that order); the controller's other lists stay unused. Views read and act only
through `AccountsCenter.source` (`AccountsSource`: snapshot, observers, refresh, add,
reauthenticate, cancel, select, remove, dismiss); the app installs the controller, tests and the
snapshot harness use `FixtureAccountsSource`, so no account CLI, Keychain read or usage request
runs there. Launch seam: drivers and sessions take `launchAdjustments: @Sendable () ->
ProviderLaunchAdjustments` (environment over the app's, arguments before the provider's) and read
it on every spawn (sessions, probes, text generation). `EngineFactory` injects
`AccountLaunchBridge.ompAdjustments(state:)`: omp gets `--config <Application Support>/<bundle
id>/omp-accounts.yml` once a preference exists. The account list is in UserDefaults
`soprano-accounts` (separate from Soprano's); Keychain items and omp's logins are shared with
Soprano.

### Usage statistics (Core/Usage)
`EngineEnvironment.usage: UsageStatisticsService` reads the agent's recorded usage;
`OmpUsageStatistics` is the live one. omp keeps one row per model request (tokens, API-equivalent
cost per token kind, agent kind, session folder) in `~/.omp/stats.db` (`PI_CONFIG_DIR` moves
`~/.omp` under home, joined as omp joins it), ingested from its session files by `omp stats`.
`sync()` runs `omp stats --summary` (120 s timeout, output ignored); `groups(since:granularity:)`
opens the database read-only and sums `messages` since the period's start per local hour (24h;
keyed by the epoch second the local hour starts, so a clock change's repeated hour stays two) or
local day, provider/model, `agent_type` and `folder` (`stop_reason = 'error'` = failed;
unpriced as omp counts it: tokens, zero cost, `xai-oauth` or `cost_unpriced`; cache savings =
`cost_no_cache_input` − the cached prompt cost of the rows that report it). No database = no
history; a missing table or column is `UsageStatisticsError.database`.
`engine.usageHistory(period, sync:)` reads even when the sync failed (`UsageHistory.syncError`)
and returns a `UsageHistory` whose `summary(model:)` folds the groups into chart buckets
(`UsagePeriod.buckets`: the last 24 hours as 25 hourly bars, the first holding the part of its hour inside the window; 7 / 30 / 90 calendar days ending today, All weekly from the first
request, monthly beyond 26 weeks), totals and model / folder / agent breakdowns; the model filter
narrows everything except the model list. `usageFolderTitles()` maps the stats folders of project
roots and thread working directories to project titles. `UsageFolderName.encode` follows omp:
the `realpath` of the directory (`/tmp` → `/private/tmp`), named `-tmp-<relative>` under the
temporary directory, `-<relative>` under home, else `--<absolute>--` (`/ \ :` → `-`), which
omp-stats stores with a leading `--` and every later `--` as `/` (`/private-tmp-x/`). The
snapshot harness and tests use `FixtureUsageStatistics` / scratch databases; nothing reads the
user's `stats.db` there.

### Git (Core/Git)
`LiveGitService: GitService`. All git through `GitRunner` (`git --no-pager -c core.quotepath=false
-c color.ui=never -C <cwd> …`, `GIT_TERMINAL_PROMPT=0`, extended PATH). Checkpoints never touch the
user's index or HEAD: temp index `GIT_INDEX_FILE=<git-common-dir>/soprano-agents-index-<uuid>`
(copied from the real index when HEAD exists, `read-tree --reset HEAD`), `add -A -- .`,
`write-tree`, `commit-tree <tree> [-p HEAD] -m "soprano-agents checkpoint <ref>"`, `update-ref
<ref> <commit>`, committer/author "Soprano Agents" <soprano-agents@users.noreply.github.com>.
Diffs: `git diff --no-color --no-ext-diff --no-textconv -M [--ignore-all-space] <a>^{commit}
<b>^{commit}` (numstat for `changedFiles`). Restore: `git restore --source <commit> --worktree
--staged -- .`, `git clean -fd -- .`, `git reset --quiet -- .`. `status` (changed files with line
counts) and `workingTreeDiff` stage into the same kind of scratch index, so untracked files count
and `.gitignore` is respected. `DiffParser.parse(_:)` turns a patch into `FileDiff`s for the right
panel. Worktrees live at `<dir>/<repo>/<branch with / → ->` (names over 40 characters: 23 + `-` +
16 hex of SHA-256), branched `--no-track` from the base, which is recorded as
`branch.<b>.soprano-agents-merge-base` (the PR base). Commit/push/PR is a stacked
action flow (push = `git push -- <remote> HEAD:refs/heads/<b>` + upstream config); PRs via
`gh pr create`; open PR lookup via `gh pr view --json` (4 s deadline, failures ignored).

### `WorkspaceState` (Shell)
UI state: `selection` (`.draft(projectID:)`, `.thread(id)` or `.subagent(threadID:subagentID:)`:
the timeline shows the subagent's runs via `Subagent.timelineThread`, not editable; the composer
messages it (Stop stops it; model, permissions and attachments hide); the header reads `project /
thread / Reader · sonic`, the thread title opens the thread; `selectedThreadID` is the owning
thread, `selectedSubagentID` the subagent) and its `workspace` (`WorkspaceRef`;
nil for a projectless draft, which has no folder), panel visibility (sidebar, thread details card,
terminal drawer, right panel, statistics board), the right-panel tabs per workspace key (`RightPanelSurface`:
`.diff`, `.files`, `.file(path)`, `.terminal(sessionID)`; `rightPanelSurfaces`, the active
`rightPanelSurface` — nil = "Open a surface" launcher —, `showRightPanel(_:)`,
`closeRightPanelTab(_:key:)`, `pruneRightPanelTabs(keeping:)`, `moveDraftTabs(projectID:to:)`),
diff scope + focused path, sidebar project filter and search text, and `restoreComposer(with:)` /
`takeComposerRestore()` ("Edit from here" hands the user message back to the composer). Observe
`Change` (`.selection`, `.panels`, `.filter`, `.composerRestore`); a selection switch changes the
active tab too. `isStatisticsVisible` (`setStatisticsVisible`) closes on `select` (also of the
selected thread; selections the app makes itself, a launched draft becoming its thread or a
removed thread or project falling back to a draft, pass `closingStatistics: false`) and whenever
the terminal, right panel, a diff or the thread details open. Toggle commands for a surface
under the board (⌘J, ⌘L, ⇧⌘B, ⌘D, ⇧⌘F, Maximize) show it instead of hiding it
(`toggledVisibility`). Composer and timeline commands that show or focus something in the chat
column (Focus Composer, the pickers, Compact, Find in Thread, Jump to Latest, Expand / Collapse
All) get it through `WorkspaceViewController.revealChat()`, which closes the board first. A board
that had focus hands it to the composer, or to a maximized right panel, when it closes; while it
shows, `ComposerViewController.focusEditor()` does nothing, so background selections keep the
keyboard on the board.

### Regions (view controllers)
`WorkspaceViewController` lays out sidebar | chat column | right panel (resizable rails, widths
in an injectable `UserDefaults`). `ChatViewController` stacks header (52 pt), timeline, the
floating composer (centered, ≤ 736 pt, 20 pt above the terminal drawer; vertically centered for
drafts), the terminal drawer, and the Thread details card (top-right, 280 pt). The header's
location chip (right-aligned before the title-bar toggles) shows `WorkspaceLocation.title`
(`repo/sub/folder`, the `~` path outside git, "Scratch") and the branch, tooltip with kind and
full path, click toggles the thread details; it reloads on workspace, folder, branch or running
changes and app activation, squeezes to 160 pt before the breadcrumb, and hides below that.
A teammate's thread (`AgentThread.teammate`) reads avatar · name · role (muted, truncating first)
instead of project / title; its title menu is `TeamActions.menu` and double-click opens Edit
Teammate (no inline rename); the location chip shows its home folder.
`RightPanelViewController` hosts the tab strip ("+" = native menu: Terminal, Files, Diff), the
launcher (`T`/`F`/`D` while it has focus; Terminal and Files need a workspace, so only a
projectless draft disables them) and one controller per surface kind: `DiffSurfaceViewController`
(drafts always show Uncommitted), `FilesSurfaceViewController` (explorer, search, context menu),
`FileViewerViewController` (breadcrumbs, line numbers, syntax colors, images; `.md`/`.markdown`
tabs open in `MarkdownReaderView`, Soprano's Markdown reader on the timeline renderer:
`MarkdownStyle.document` sets New York 16/26 in a ≤ 920 pt column with ruled h2 headings and
heading anchors, image-only paragraphs become image blocks loaded through
`engine.readWorkspaceFile`, and `MarkdownReaderLink` resolves links — relative and `/`-rooted
paths open file tabs inside the workspace, `#anchor` scrolls, http(s)/mailto go to the browser,
anything else is refused; the eye button or `rightPanel.toggleMarkdownPreview` shows the source,
which ⌘F also switches to for its find bar; files over
`FileViewerViewController.maximumPreviewBytes` (128 KB) open as source, the reader lays out the
whole document on the main thread),
`TerminalSurfaceViewController` (focus region `.terminal`). Terminals, Files and the drawer work
in a project draft (the project root); when the draft starts a "Current checkout" thread, its
tabs and running terminals move to that thread (`ComposerViewController.onDraftLaunched`).

Region controllers keep `init(engine:state:)`, except `RightPanelViewController`, which also takes
the drawer's `ThreadTerminalStore`: one store owns every terminal of the window (sessions per
workspace key with a `.drawer`/`.panel` placement and shared "Terminal N" numbering, SwiftTerm
views, shells), so a panel terminal's exit, a deleted thread or project and app quit end shells
in one place. Contracts the
container relies on: `TimelineViewController.bottomInset` (space the composer covers),
`ComposerViewController.onHeightChange` and `focusEditor()`, `ChatViewController.terminalDrawerHeight`.
Region controllers that take keyboard focus adopt `FocusRegionController`.

The composer footer shows a context meter (`ContextMeterView`, 16 pt ring left of send/stop) for
`thread.contextUsage`: a muted full track under a foreground arc below 70%, `warning` from 70%, `error` from 90%, hidden for drafts and
unknown usage, tooltip `Context: 62.4k / 200k tokens (31%)`. Clicking it opens a child-window card
(`ContextMeterCardContent`) with the usage bar, `62.4k of 200k tokens used · 31%` and "Compact
conversation" (`engine.compact`, enabled by `engine.canCompact`; failures are alerts). The `/`
command menu (`SlashCommandMenuContent`) is a passive `ComposerPopover` (never key; clicks on the
composer pass through) anchored above the composer at its width. It opens while the caret is in a
line-start token starting with `/` (`SlashToken`), lists
`engine.commands(forThread:)` / `commands(forDraft:projectID:)` plus the app's `/compact` row when
the thread can compact and the provider has none, filtered by `SlashCommandFilter` (name prefix,
then name substring, then description substring), and re-lists on `.commandsChanged`. An empty
list calls `engine.loadCommands(…)` first, so a thread without a session this run (or a draft)
fills in once the provider answers. The editor
keeps focus and hands ↑/↓, Enter, Tab and Escape to the menu first (`menuKeyHandler`): Enter/Tab
replace the token with `insertText` (keeping what follows), Escape hides the menu until the caret
leaves the token, Enter never sends while it shows (with nothing to pick it closes the menu). It
closes on send, focus loss, thread switch and when another of the app's windows becomes key
(palette, dialog, settings); app deactivation keeps it. Text the composer sets itself never opens
it; the editor has the system's inline predictions and text completion off.

Typing aids (`ComposerTextAssist.swift`), read from `engine.textAssistPreferences` at start and
whenever the app becomes active, as omp's terminal composer has them: with typo detection the
editor marks misspellings and grammar problems with the macOS dictionaries (continuous spelling
and grammar checking; the right-click menu offers corrections), except in code — inline `code`,
``` and ~~~ fences, and words that read as code or references (`ComposerProse`: `/`, `\`, `.`, `_`, `:`,
brackets and other symbols inside, digits, an inner capital after a lowercase letter, a leading
`-`, `/`, `@`, `#`, `$` or `~`; `*emphasis*` stays prose); a grammar mark touching such a word goes too. Autocorrect follows
`spelling.autocorrect`. Word completion (`ComposerWordCompletion`) asks
`engine.predictWord` on every edit while nothing is selected, a letter precedes the caret and
nothing follows it on its line (not while the `/` menu shows or text is being composed), and
draws the suffix after the caret in the placeholder color (`ComposerTextView.ghostText`). Tab
inserts it plus a space, → inserts it alone (both report it accepted); typing letters that
follow it keeps showing the rest until the provider answers again, typing that diverges reports
it typed past. Moving the caret, losing focus or text the composer sets clears it.

The side-question panel (`SideQuestionPanelContent`, omp's `/btw`) is a key-taking
`ComposerPopover` above the composer at its width, for the selected thread (also while one of
its subagents is selected; never a draft, which gets an alert). `thread.sideQuestion` (⇧⌘I)
opens it (Escape or × closes it), a message that is `/btw` opens it and `/btw <question>` asks right away (the `/`
menu lists the app's `/btw` row for threads; attachments stay in the composer). Without a
selected topic it lists the thread's topics newest first (question, status or the answer's
first line, "N questions", relative time; ↑/↓, Enter or a click opens one) or a hint, and the
field asks a new question; a topic shows each question with its answer as assistant Markdown
("Thinking…" until text streams, Cancelled / Interrupted / Failed lines) and the field asks a
follow-up; ‹ goes back to the list. Stop (and Escape) cancels a running answer, else Escape
closes; Copy copies the topic's latest answer. Opening it reads the history
(`engine.loadSideQuestions`; errors show in the panel), and a question that fails shows its
error there and goes back into the field. The transcript scrolls past 360 pt and follows the
stream while scrolled to its end. Closing the panel never cancels the answer; a panel opened
again shows Stop while a question from the earlier one is still starting. `/btw` also works while
the agent asks a question: it is never sent as the answer.

The sidebar footer ends with the account button after the gear and the statistics button
(`AccountButton`, `person.crop.circle`): muted while every headline Claude and Codex login's
tightest window is below 70%, `warning` from 70%, `error` from 90%; its tooltip lists each
headline login's windows and resets. Clicking it or `usage.open` toggles the usage card
(child window): per provider, per account list, each login with its 5h/7d bars, percent and
reset, plus Refresh and "Manage Accounts…" (Settings → Accounts).

The statistics board (`StatisticsViewController`, toggled by `statistics.toggle` and the chart
button next to the sidebar's gear) covers the chat column and the right panel, which stay
loaded underneath; it takes key focus (Esc closes, `C` / `T` Cost / Tokens, `1`–`5` the period)
without being a focus region, so window shortcuts keep working. Header: "Statistics", period
control (24h · 7d · 30d · 90d · All, default 7d), Refresh, Close; a sidebar toggle while the
sidebar is hidden. Content (≤ 960 pt): Cost / Tokens, a model-filter chip, four tiles (Cost:
estimated cost, cache savings, requests, per request; Tokens: total, input, output, cache read),
the stacked chart (cache read, cache write, input, output; hover shows the bar in the title
line), Models (share bar, requests, cache hit rate, value; click filters), Projects (top 8 plus
"N more") and Agents, and a footnote. Opening and Refresh sync omp's history, a period switch
only reads (or takes over a running sync). A failed read shows an error with Retry above the
last data of the same period (another period's data is dropped); a failed sync shows a notice
above what was recorded before it.

### Commands (`Commands/AppCommand.swift`)
Every user action is an `AppCommand` registered once at launch from its module's
`…Commands.all` (`ShellCommands`, `SidebarCommands`, `TeamCommands`, `TimelineCommands`, `ComposerCommands`,
`PanelCommands`, `AccountCommands`, `StatisticsCommands`). Commands are the single source for key bindings, the palette, menus and
buttons, and the snapshot harness runs them with `--perform <id>`. `CommandContext` carries
`engine`, `state`, `workspace`, `window`, `focus`, `isTextInput`, and `thread` (selected).

### Settings (`Shell/AppEnvironment.swift`, `SettingsResolution.swift`, `SettingsFile.swift`)
`~/.config/soprano-agents/settings.json` (JSONC, `SOPRANO_AGENTS_CONFIG` overrides), live
reloaded; bad values become warnings. Keys: `theme`, `agents.{defaultProvider, defaultModel,
defaultRuntimeMode}`, `providers.{ompPath, opencodePath, antigravityPath}`, `textGeneration.{provider, model,
titles}`, `worktrees.{directory, branchPrefix}`, `projects.directories`,
`chat.{followUp, width, workLog}`, `notifications.{enabled, sound}`, `remote.{enabled, port,
httpsPort, launchAtLogin, preventSleep, push}`, `editor.app`,
`keybindings.{prefixKey, prefixTimeoutMs, bindings}`. `defaultProvider` /
`textGeneration.provider` are `omp`, `opencode` or `antigravity` (default omp); a model setting names a model of
that agent, absent = that agent's configured model. `AppSettings.engineSettings` feeds
`AgentEngine.settings`. Window geometry, panel widths and per-thread UI state stay in
`UserDefaults`.

### Remote access: phone web app (`Sources/SopranoAgents/Remote/`)

The app serves its own web app so threads can be continued from a phone. It is on by default
(`remote.enabled`) and reaches the phone only through the tailnet:

- `RemoteServer` (Network.framework `NWListener`) listens on `127.0.0.1:<remote.port>` (default
  47261), plain HTTP/1.1, one request per connection (`Connection: close`), except the
  server-sent event streams, which stay open. It never binds another interface. Before reading a
  body it asks `RemoteAPI.admission` from the head: static files get none, `/api/pair` 4 KB,
  every other `/api/` route needs a paired token (checked off the main actor through
  `RemoteStore.tokens`; 401 otherwise) and gets 1 MB, uploads 25 MB (a chunked body's encoding
  may be at most twice that plus 16 KB of framing, a size line 1 KB). At most 64 connections are
  open; one silent for 20 s before its request is complete is dropped, and every request must be
  complete within 15 s of connecting however steadily it trickles (only a paired device's upload
  over 1 MB is exempt and ends only when silent). Every response carries
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer` and `X-Frame-Options: DENY`;
  HTML pages a Content Security Policy (scripts, connections and workers from the app's origin
  only, no frames, plugins or form posts); attachments a sandbox policy, and anything but images
  is served as `application/octet-stream`.
- `TailscaleServe` publishes it with `tailscale serve --bg --https=<remote.httpsPort>
  http://127.0.0.1:<port>` (default 443) and reads the device's MagicDNS name from
  `tailscale status --json` for the URL (`https://<name>.<tailnet>.ts.net/`). It never replaces
  a serve config on that HTTPS port that points elsewhere (Settings shows the conflict) and turns
  its own off when remote access is disabled. A failed publish (Tailscale not running yet, a
  conflict) or server start (port taken) is retried after 5, 15, 30, then every 60 s while remote
  access is on; Settings › Phone's Retry publishes at once. Changes run in order: a new server
  waits until the old one released its port, a publish until the previous unpublish finished
  (and an unpublish until a publish still in flight finished). Tailscale Serve terminates TLS, so the origin is
  HTTPS (needed for the service worker, Web Push and WebCrypto).
- Pairing: Settings → Phone shows the URL, a QR code and "Copy pairing link"
  (`https://<host>/#pair=<code>`); the code (32 random bytes, base64url) works once: pairing or
  "New pairing link" replaces it. The web app redeems it (`POST /api/pair`) for a device token (32 random bytes),
  kept in `localStorage` and sent as `Authorization: Bearer <token>`; the server stores only its
  SHA-256 with the device name and dates in `<app data>/remote.json` (Settings lists devices,
  Revoke drops one with its push subscriptions, which belong to the device that made them, and
  ends its open event and terminal streams). Every `/api/*` route except `/api/pair` needs a valid token (401 otherwise);
  static files and `/theme.css` need none.
- `RemoteAPI` maps HTTP to `AgentEngine` (the only state it touches; it behaves like a view).
  `RemoteTerminals` runs the phone's own shells (SwiftTerm `LocalProcess`, headless) in a
  thread's working directory, separate from the Mac's terminal views, with a 256 KB scrollback
  replayed to every new output stream. `WebPush` (VAPID, RFC 8291 `aes128gcm`, RFC 8292) sends
  push messages to subscribed devices.
- Lifecycle: with remote access on, closing the last window keeps the app running,
  `remote.launchAtLogin` registers the installed app as a login item (`SMAppService.mainApp`),
  and `remote.preventSleep` holds a "prevent idle system sleep" assertion while on AC power.
  A closed lid still sleeps the Mac.
- Push (`remote.push`): when a thread turns Done, Failed, Approval or Input (the same alerts as
  `ThreadNotifier`) while the Mac's user is away (the app is not active, or no input for 2
  minutes), every subscribed device gets `{title, body, threadID}`. Subscriptions answered 404
  or 410 are dropped; only Apple, Google, Mozilla and Microsoft push service hosts are accepted.

The web app (`Remote/Web/`, copied into the resource bundle) is plain HTML, CSS and ES modules
without a build step; `vendor/` holds xterm.js and its fit addon. It is a PWA
(`manifest.webmanifest`, `sw.js`): installable to the home screen, cached shell, push. Colors come
from `/theme.css`, generated from the palette in force (CSS variables named after `Palette`
properties, kebab-case: `--background`, `--foreground`, `--card`, `--muted`, `--muted-foreground`,
`--secondary-label`, `--border`, `--primary`, `--primary-foreground`, `--accent`,
`--message-surface`, `--message-foreground`, `--sidebar`, `--error`, `--warning`, `--success`,
`--info`, `--diff-addition-*`, `--diff-deletion-*`, `--code-background`, `--terminal-*`,
`--terminal-ansi-0` … `-15`, plus `color-scheme`).

**HTTP API** (JSON bodies, dates ISO 8601, errors `{"error": "<message>"}` with a 4xx/5xx
status). Domain values are the Core models' `Codable` JSON: `Project`, `AgentThread`, `Turn`,
`TurnItem`, `ProviderStatus`, `ModelSelection`. Enums with associated values encode as
`{"<case>": {<labels>}}`, unlabeled payloads as `{"<case>": {"_0": …}}` (e.g. item kind
`{"command": {"_0": {"command": "ls", "output": "…", "exitCode": 0}}}`,
`{"assistantMessage": {"text": "…", "isFinal": true}}`).

`ThreadSummary`: `{id, projectID, title, status: "approval"|"input"|"working"|"failed"|"done"|
"idle", workingSince, section: "pinned"|"working"|"blocked"|"failed"|"done"|"idle"|"settled"|
"team", pinned, settled, activityDate, updatedAt, branch, worktree: Bool, model:
ModelSelection, runtimeMode, isRunning, preview, teammate}` (`preview`: the last final answer or
else the last user message, ≤ 160 characters; `teammate`: the teammate's name or null).
Archived threads are left out.

| Route | Does |
|---|---|
| `POST /api/pair {code, name}` | → `{token}`; 403 for an unknown code. |
| `GET /api/state` | → `{projects, threads: [ThreadSummary], providers, defaults: {model, runtimeMode}, runtimeModes: [{id, title, summary}], host, version}`. |
| `GET /api/events` | Server-sent events (see below). |
| `GET /api/threads/{id}` | → `{thread: AgentThread, summary: ThreadSummary}`. |
| `POST /api/threads {projectID, text, model, runtimeMode, workspace, attachments?}` | `workspace`: `{"kind": "projectRoot"}` or `{"kind": "newWorktree", "baseBranch": "main"}`; `attachments`: upload ids → `{threadID}`. |
| `PATCH /api/threads/{id} {title?, pinned?, settled?, archived?}` | → 204. |
| `POST /api/threads/{id}/visited` | Marks the thread seen (clears Done/Failed). |
| `POST /api/threads/{id}/messages {text, mode, attachments?}` | `mode`: `automatic` (start or steer), `steer`, `queue`; `attachments`: upload ids (`text` may then be empty). |
| `POST /api/attachments` | Raw file bytes, `Content-Type`, `X-Filename` (percent-encoded; folders dropped) → `Attachment` (stored by `importAttachment`, kept in memory until a message sends it; ≤ 25 MB). |
| `GET /api/attachments/{id}` | The bytes of an unsent upload or of any message's attachment. |
| `POST /api/threads/{id}/interrupt` | Stop. |
| `POST /api/threads/{id}/approvals/{approvalID} {decision}` | `accept`, `acceptForSession`, `decline`, `cancel`. |
| `POST /api/threads/{id}/inputs/{requestID} {answers}` | `answers`: question id → labels or free text. `DELETE` dismisses. |
| `POST /api/threads/{id}/queue/{messageID}/send`, `DELETE …/queue/{messageID}` | Send a queued message now / drop it. |
| `GET /api/threads/{id}/diff?turn=<ordinal>` | → `{diff}` (unified); without `turn` the whole thread. |
| `GET /api/threads/{id}/git` | → `{isRepository, branch, isDefaultBranch, hasRemote, hasUpstream, ahead, behind, files: [{path, additions, deletions}], pullRequest: {number, url, title, state} \| null}`. |
| `POST /api/threads/{id}/git {action, commitMessage?, featureBranch?}` | `action`: `commit`, `push`, `create_pr`, `commit_push`, `commit_push_pr` → `{title, detail, pullRequestURL}` (waits for the action). |
| `GET /api/projects/{id}/branches` | → `{current, branches: [String]}` (local branches). |
| `GET /api/threads/{id}/terminals` | → `{terminals: [{id, threadID, title, running}]}`. |
| `POST /api/threads/{id}/terminals {cols, rows}` | → the new terminal. |
| `GET /api/terminals/{id}/output` | SSE: `output {data: base64}` (the scrollback first), `exit {code}`. |
| `POST /api/terminals/{id}/input {data}`, `…/resize {cols, rows}`, `DELETE /api/terminals/{id}` | Keystrokes (UTF-8 text), size, close. |
| `GET /api/push/key` | → `{publicKey}` (VAPID, base64url uncompressed P-256). |
| `POST /api/push/subscriptions {endpoint, keys: {p256dh, auth}}`, `DELETE … {endpoint}` | Subscribe / unsubscribe this device. |

`GET /api/events` (`text/event-stream`; the web app reads it with `fetch`, since `EventSource`
cannot send the token) sends `event: <name>` / `data: <json>`: `state` (the `/api/state` body)
first, then `threads {threads}` (summaries after list or thread changes, coalesced 150 ms),
`thread {threadID}` (that thread changed: refetch it if shown, coalesced 150 ms), `item
{threadID, turnID, item}` (a streaming item's latest value, coalesced 100 ms), `projects
{projects}`, `providers {providers}`, `terminals {threadID, terminals}`, and a `: ping` comment
every 15 s.

## Keyboard model

The router is an `NSEvent` local monitor (Soprano's model): ⌃A prefix mode, scopes by
`FocusRegion` (`sidebar`, `timeline`, `composer`, `terminal`, `rightPanel`, `settings`), chords
without ⌘/⌃ never fire in text input, ⌥ chords pass through (German layouts), a region-scoped
binding beats a global one. Shortcuts that would need ⌥ use ⌃⌘ instead.

### Default bindings

| Command id | Title | Scope | Keys | Owner |
|---|---|---|---|---|
| `palette.open` | Command Palette | global | `cmd+k`, `cmd+p` | Shell |
| `settings.open` | Settings | global | `cmd+,` | Shell |
| `settings.openFile` | Open settings.json | global | — | Shell |
| `view.toggleSidebar` | Toggle Sidebar | global | `cmd+e` | Shell |
| `view.toggleThreadDetails` | Toggle Thread Details | not terminal | `cmd+shift+b` | Shell |
| `view.toggleTerminal` | Toggle Terminal Drawer | global | `cmd+j` | Shell |
| `view.toggleRightPanel` | Toggle Right Panel | global | `cmd+l` | Shell |
| `chat.new` | New Thread | not terminal | `cmd+n`, `cmd+shift+o` | Sidebar |
| `chat.newLocal` | New Thread in Current Project | not terminal | `cmd+shift+n` | Sidebar |
| `chat.newWithoutProject` | New Thread Without a Project | not terminal | `cmd+ctrl+n` | Sidebar |
| `project.open` | Open Project… | global | `cmd+shift+k` | Sidebar |
| `thread.previous` / `thread.next` | Previous / Next Thread | global | `cmd+shift+[` / `cmd+shift+]` | Sidebar |
| `thread.jump.1`…`9` | Go to Thread N | global | `ctrl+1`…`ctrl+9` | Sidebar |
| `thread.settle` | Settle Thread | not terminal | `cmd+shift+s` | Sidebar |
| `thread.pin` | Pin Thread | not terminal | `cmd+shift+p` | Sidebar |
| `thread.rename` | Rename Thread | sidebar | — (F2 in the sidebar list, hard-coded: `KeyChord` has no function keys) | Sidebar |
| `thread.archive` / `thread.delete` | Archive / Delete Thread (disabled for a teammate's thread; pin, settle and rename too) | — | — | Sidebar |
| `team.new` | New Teammate… (the Team section's "+") | — | — | Team |
| `team.edit` / `team.delete` | Edit / Delete Teammate… (the selected teammate; delete confirms, naming it) | — | — | Team |
| `thread.copyReference` | Copy Thread Reference | not terminal | `cmd+shift+c` | Sidebar |
| `sidebar.search` | Search Threads | global | — | Sidebar |
| `sidebar.filterProjects` | Filter Threads by Project | global | — | Sidebar |
| `sidebar.toggleTeam` | Collapse or Expand Team (the Team header's click; not in the palette) | — | — | Sidebar |
| `chat.find` | Find in Thread | sidebar, timeline, composer | `cmd+f` | Timeline |
| `timeline.jumpToLatest` | Jump to Latest | timeline | `cmd+down` | Timeline |
| `timeline.expandAll` / `timeline.collapseAll` | Expand / Collapse All Work | — | — | Timeline |
| `timeline.toggleWorkLog` | Toggle Detailed Work Log (writes `chat.workLog`) | sidebar, timeline, composer, rightPanel | `cmd+shift+d` | Timeline |
| `composer.focus` | Focus Composer | global | `cmd+shift+l` | Composer |
| `modelPicker.toggle` | Model Picker | not terminal | `cmd+shift+m` | Composer |
| `composer.effort` | Reasoning Effort | not terminal | `cmd+shift+e` | Composer |
| `composer.mode` | Permissions | not terminal | `cmd+shift+a` | Composer |
| `composer.planMode` | Toggle Plan Mode (Build ↔ Plan, shown for providers with `supportsPlanMode`) | not terminal | `cmd+shift+t` | Composer |
| `composer.workspace` | Workspace | not terminal | `cmd+shift+x` | Composer |
| `composer.branch` | Branch | not terminal | `cmd+shift+g` | Composer |
| `composer.sendAlternate` | Steer or Queue (opposite) | composer | `cmd+enter` | Composer |
| `thread.stop` | Interrupt | global | — | Composer |
| `thread.compact` | Compact Conversation | — | — | Composer |
| `thread.sideQuestion` | Ask a Side Question (`/btw`) | not terminal | `cmd+shift+i` | Composer |
| `diff.toggle` | Toggle Diff | not terminal | `cmd+d` | Panels |
| `files.toggle` | Toggle Files | not terminal | `cmd+shift+f` | Panels |
| `files.search` | Search Files | — | — | Panels |
| `rightPanel.newTerminal` | New Terminal in Right Panel | global | `cmd+shift+j` | Panels |
| `rightPanel.closeTab` | Close Tab | rightPanel | `cmd+w` | Panels |
| `rightPanel.find` | Find in Panel (file tab: find bar, a Markdown preview switches to its source; Files: search; else Find in Thread) | rightPanel | `cmd+f` | Panels |
| `rightPanel.toggleMarkdownPreview` | Toggle Markdown Preview (reader ↔ source of a Markdown file tab) | rightPanel | `cmd+shift+v` | Panels |
| `terminal.new` | New Terminal (drawer, or a panel tab when one has focus) | terminal | `cmd+n` | Panels |
| `terminal.close` | Close Terminal (drawer, or the focused panel tab) | terminal | `cmd+w` | Panels |
| `editor.openFavorite` | Open in Editor | global | `cmd+o`, `prefix+v` | Panels |
| `git.openInSopranoGit` | Open in Soprano Git (the workspace's repository root, as in Soprano) | global | `prefix+g` | Panels |
| `git.commit` / `git.push` / `git.createPR` | Commit / Push / Create PR | — | — | Panels |
| `diff.toggleLayout` / `diff.toggleFileTree` | Toggle Split Diff View / Diff File Tree | — | — | Panels |
| `rightPanel.toggleMaximized` | Maximize Right Panel | — | — | Panels |
| `usage.open` | Show Usage | global | `cmd+u` | Accounts |
| `accounts.manage` | Manage Accounts… | global | — | Accounts |
| `usage.refresh` | Refresh Usage | global | — | Accounts |
| `statistics.toggle` | Statistics | global | `cmd+shift+u` | Statistics |

"not terminal" = scopes `[sidebar, timeline, composer, rightPanel]` (plus nil focus handled by the
router as global). A right-panel terminal tab is focus region `terminal`, like the drawer.

## Layout and visual design


```
┌ sidebar 256 (208…) ┬ chat column (≥ 640) ──────────────────────────────┬ right panel 540 (360…70%) ┐
│ [traffic lights]   │ header 52: project / Title ⌄ ▢ repo ⑂ br [▤][▭][◫] │ tabs [Diff][Files][x.swift]+│
│ Search  [⫶][📁][✎] │   lane ≤ 736 centered                ┌ details ┐   │                             │
│ Pinned / Working ⌄ │   user bubble right (≤ 80%, r16)    │ card 280 │   │                             │
│ Blocked / Failed / │   Worked for 3m 12s ›               └──────────┘   │                             │
│ Done / Idle ⌄ (78) │   assistant markdown 14/1.625                      │                             │
│ …                  │   N changed files card                             │                             │
│ Settled 43 ›       │   ┌ composer r16, glass ┐                          │                             │
│ [⚙][▥][◎]          │ terminal drawer 280 (180…75%)                      │                             │
└────────────────────┴────────────────────────────────────────────────────┴─────────────────────────────┘
```

- Colors only from `PaletteCenter.shared.palette`, which `Palette(soprano:)` derives from the
  Soprano theme in force (`theme: "soprano"` by default, following Soprano's own theme and
  appearance; `folio` follows macOS light/dark). Terminals (drawer and panel tabs) use the theme's terminal
  palette, project monograms its accent hues. Views subclass `PaletteView` and re-color in
  `applyPalette(_:)`.
- Fonts from `Typography`: system font (14 body, 13 detail rows, 12 meta/pills, 11 kbd), SF Mono
  13 for code, diffs and command output. The terminal is 12 pt in an installed "… Nerd Font Mono"
  family (JetBrains Mono first), else Powerlevel10k's "MesloLGS NF", so prompt icons and powerline
  separators render; without either, SF Mono with Symbols Nerd Font Mono as fallback when
  installed (regular cells only: SwiftTerm derives bold/italic without it). Icons are SF Symbols (`Icon` names
  them by role), 16 pt in 28 pt ghost buttons.
- Radii from `Radius`: composer, bubbles, dialogs, details card 16; buttons, menus,
  popovers, code blocks, changed-files card 8; sidebar cards 6.
- Sidebar sections (`InboxSection`, top to bottom): Pinned, Working, Blocked (approval or input
  pending), Failed, Done, Idle (no turn yet, or interrupted), each a collapsible "Title N ⌄"
  header shown only when non-empty and open by default; Settled sits at the bottom, closed by
  default, 10 slim rows then "Show 25 more". Groups follow the last turn's outcome, not the
  unread state, so opening a thread never moves it. A closed section still lists the open thread.
- Status pills (sidebar): Working (info, `circle.dashed`, live duration), Approval (warning),
  Input (indigo), Failed (error), Done (success), else relative time ("now", "5m", "3h", "2d").
- Subagents (sidebar): a card with subagents shows its meta line with a disclosure "⌄ ⚙ N"
  (running/total while one runs, info-tinted); a slim row shows it before its time. Open (by
  default while one runs, else after a click) it lists 30 pt rows under the thread, indented
  18 pt with a tree guide: status glyph (running `circle.dashed` info, done `checkmark.circle`,
  failed, stopped `stop.circle`), name, "agent · latest intent" (else description or
  assignment), live run time. A selected subagent stays listed under a closed disclosure; its
  row, not the thread's, is highlighted, and its thread stays unread until opened itself.
- Team (sidebar, above Pinned; hidden while searching, ignores the project filter): "Team N ⌄"
  header with a "+" (New Teammate…); clicking the header collapses the section like a shelf
  (open by default, not persisted; collapsed, only the open teammate stays listed), then one
  48 pt row per `engine.team` thread in creation order — a 24 pt avatar circle with the name's
  initial (hue from the handle among the palette's `projectIconColors`), name over role, the
  usual status pill or relative time, "⋯" on hover.
  Empty, it shows "Create a teammate to chat with and delegate to". Click opens the thread like
  any other, double-click / F2 edits, right-click is the teammate menu (Edit Teammate…, Mark
  unread, Copy ▸ Handle / Path / Thread ID, Delete Teammate…). Teammates come first in the
  thread order (↑/↓, ⇧⌘[ / ⇧⌘], ⌃1…⌃9) and never appear in the inbox sections
  (`InboxSection.of` is nil for them). The New / Edit Teammate dialog (`TeammateDialog`, an
  `OverlayWindow` card) has Name and Handle side by side (the handle follows
  `Teammate.suggestedHandle` until edited, `Teammate.handleProblem` shows under it and disables
  Save), Role, Instructions (88 pt, scrolls), Home folder (projects or "Own folder (no
  project)") and the "Also make available to terminal omp" switch; engine errors show above the
  buttons, a save `warning` in an alert after it closes. The model picker locks teammates to omp
  ("Teammates run on omp.").
- Messages from other threads (timeline): a user message or steer with `UserMessage.sender`
  shows "From CTO" (`.teammate`) or "From thread “Fix checkout totals”" (`.thread`) muted above
  its bubble; clicking it opens the sender when it still exists. A teammate's thread without
  turns shows `TeammateIntroRowView` (avatar, name, role, "Ask CTO anything. Your threads can
  message @cto too.") centered above the composer instead of "Send a message to start the
  conversation.".
- Work log (`chat.workLog`, ⇧⌘D toggles): `detailed` (default) opens every "Worked for" fold,
  work group and file diff; a running turn's steps show as an open group, the running one
  shimmering and expandable like the rest (its group header collapses to the live row; between
  steps "Thinking" shows). `minimal`
  closes them all and shows one shimmering live row. A file change is one `FileDiffRowView` per
  file: a work-log line ("Editing/Writing/Edited/Wrote/Created/Deleted path", "+N −M", or "N
  lines" for a write's whole content, drawn as plain numbered lines; an Open in Diff panel
  button opens the turn's checkpoint diff at that file once the turn finished, else the
  uncommitted changes; clicking the line folds the body) over a 1 pt bordered,
  `Radius.md` panel of Diff-panel line rows (`DiffStyle`, `DiffLineDrawing`: tint, change bar,
  line numbers, syntax colors once open, wrapped), at most 360 pt tall, scrolling inside;
  unpositioned preview hunks show their op ("PUT 12.=14:") and no line numbers. While the call
  runs, the panel keeps its newest line in view unless the user scrolled up.
- Motion: opacity/scale fades ≤ 200 ms, none under Reduce Motion; streaming text appears without
  animation.
- Floating surfaces that must appear in snapshots (palette, model picker, menus of the composer,
  branch picker, thread details popovers, context card, `/` command menu, side-question panel, usage card) are child windows of the main window
  (`window.addChildWindow(_:ordered:)`), not `NSPopover`. Context menus are native `NSMenu`.

## Verification harness

`SopranoAgents serve [--fixture <scenario>] [--port 47299] [--theme <id>] [--appearance
light|dark]` serves the phone web app and the real `RemoteAPI` over a `DemoFixtures` engine on
`http://127.0.0.1:<port>/` (fresh remote state in a temporary folder; prints the pairing link and
a ready device token) until killed, for working on `Remote/Web/` in a browser at a phone viewport.
The web files come from the build's resource bundle: `swift build` after editing them.

`SopranoAgents snapshot --out <png> [--fixture demo|running|stopping|editing|approval|input|failed|background|answered|rechecked|subagents|subagent|draft|empty|team|teammate]
[--size 1440x900] [--appearance light|dark] [--theme <id>] [--hide-sidebar] [--details]
[--terminal] [--right-panel] [--diff thread|turn:<n>|uncommitted] [--open-file <path>]… [--perform <command id>]…
[--settings general|providers|accounts|text-generation|worktrees|notifications|phone|keybindings|archive|about]
[--accounts none|demo|empty|pending] [--work-log detailed|minimal]
[--dialog confirm|choose|prompt|alert] [--type "<text>"] [--keys "<chord> …"] [--hover <label>]
[--click <label>]… [--wait <seconds>]` builds the real window offscreen on a `DemoFixtures` scenario and writes a PNG
of it and its child windows. `--perform` runs any registered command (open the palette, the model
picker, `files.toggle`, `files.search`, `rightPanel.newTerminal`, …); `--open-file` opens a
workspace-relative file tab; `--settings` opens the settings screen on a page; `--dialog` presents a sample
`Dialogs` dialog; `--type` inserts text into the first responder (of the topmost overlay, else
of a key-taking child window such as the palette or the side-question panel, when one shows);
`--keys` replays chords through the router (or into the topmost overlay or key-taking child window); `--hover` sets
the hover state of the `InteractiveView` with that accessibility label or tooltip; `--click` sends
a real mouse down/up at its center through the window, so whatever the window hit-tests there
(including a view drawn over the control) gets the click, as it would live. Clicks in the
titlebar strip start a window drag offscreen instead; use them below the header. Agents verify
UI with it and `read` the PNG; they do not launch the GUI. `--work-log` overrides `chat.workLog`
in memory (never `--perform timeline.toggleWorkLog`: that writes settings.json); the `editing`
fixture is a running turn with an applied edit and a write whose code is still streaming in.
The demo fixture also has OpenCode and Antigravity statuses and one OpenCode thread ("Release
checklist for 2.4", pinned): `--perform thread.previous` five times, then `--perform
modelPicker.toggle` shows the picker on it, with the omp tile locked because the thread has turns.

The demo fixture's thread reports 124k of 200k context tokens and the engine remembers an omp
command list for it and the `app` project: `--perform composer.focus --type "/re"` opens the
filtered `/` menu, `--click "Context: 124k / 200k tokens (62%)"` the context card, and
`--fixture failed --perform composer.focus --type "/"` the empty state. Every fixture's typing
aids are `FixtureTextAssistant` (omp's default preferences; words from a fixed vocabulary):
`--perform composer.focus --type "fix the login redi" --wait 1` shows the ghost "rect", adding
`--keys tab` accepts it; misspellings typed with `--wait 3` show their marks. The demo thread has two
side questions (one with a follow-up) and the running thread one still answering:
`--perform thread.sideQuestion` opens the list (`--keys "down enter"` the follow-up topic;
`--fixture running` shows the running one with Stop). `--fixture background`
adds and selects an omp thread whose turn yielded while a background job runs (finished turn,
an advisor's Concern, "Background work still running…" row, Send instead of Stop);
`--fixture answered` one whose final answer arrived while omp still wraps up the turn (Working,
Stop, no "Thinking" row); `--fixture rechecked` a finished turn that answered three times (an
advisor note, then omp's auto-double-check woke the agent, then omp's final recap): the first
answer, the closed "2 checks after this answer" row (`--perform timeline.expandAll` opens it),
then the recap with the changed files;
`--fixture stopping` the running thread after Stop was pressed ("Stopping…", dimmed Stop).
`--fixture subagents` adds and selects a thread whose yielded turn started two subagents
(running Reader, finished Scout: card disclosure "1/2" open, two subagent rows); `--fixture
subagent` selects Reader (its run with a steer, "Message Reader", Stop).
`--fixture team` adds two teammates — CTO (`cto`, two turns: one from the user, one sent by the
thread "Fix checkout totals", answered with a review) and Frontend engineer (`frontend`, no
turns) — plus that thread, whose turn holds the "Message to cto" tool call with the reply as its
output, and selects the CTO; `--fixture teammate` selects Frontend engineer (the empty teammate
state). `--perform team.new` opens the New Teammate dialog (`--type "Frontend Engineer"` fills
the name and the handle follows), `--perform team.edit` the Edit dialog of the selected teammate,
`--click "Fix checkout totals"` opens the messaging thread and `--click "From thread “Fix
checkout totals”"` follows a sender label.
`--accounts` installs an
`AccountFixtures` snapshot before the window is built (default `none`: no usage): `demo`
has two Claude logins and one Codex login in omp with 5h/7d windows at 9 %, 72 %/93 % and
75 %/38 %; `pending` adds a waiting omp Claude sign-in and a failed action on the Codex list.
`--perform usage.open` opens the usage card; `--click "Accounts"` clicks the account button.
Every fixture engine reads `FixtureUsageStatistics` (≈ 120 days of working hours on the demo
projects plus a `-Downloads-experiments` folder; Opus main and subagents, a Sonnet advisor,
GPT-6.1 Sol and an unpriced OpenRouter model): `--perform statistics.toggle` opens the board on
7d, then `--keys "t"` switches to Tokens, `--click "Period All"` (or `24h`, `30d`, …) picks a
period and `--click "claude-opus-5-5"` filters to that model.

Modal surfaces (settings screen, `Dialogs`) are `OverlayWindow`s: borderless
child windows covering the main window with a dimmed backdrop and one card. Their keys
go to the overlay's `keyHandler` before menus and fields; while the settings screen records a
shortcut it routes every key through `KeyboardRouter.capture`.

The command palette and Open Project… (`Views/Palette/`) are Soprano's `CommandPalettePanel`
(vendored), one per window (`MainWindowController.palette`): a child panel under the titlebar
over a scrim, rows of icon, title over `AppCommand.description`, keycaps; substring search on
title, then description, then search text. `PaletteItems` builds the rows (commands, threads by
last use, projects, settings rows; or projects, the subfolders of `projects.directories` that are
no project yet, Choose Folder…); a chosen row runs after the panel closed. While it is key, only
`palette.open` / `project.open` reach the menu (close, or switch to projects). The harness types
into it with `--type` and sends it `--keys`.

## Tests

swift-testing (`import Testing`, `@Test`, `#expect`), one `struct …Tests` per file, sentence-style
names. Test files `import AppKit` (never `Foundation`) plus `@testable import SopranoAgents` /
`SopranoAgentsCore`. Provider parsing is tested against the recorded traces in
`Tests/SopranoAgentsTests/Fixtures/`; engine logic against a fake `ProviderDriver` and
`FixtureGitService`-style fakes; git against real temp repositories with an isolated config
(`HOME=<tmp>`, `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=<tmp>/gitconfig`). Tests never start a
real agent CLI and never touch the user's repositories, settings or app data.
