# Status

Goal: Soprano Agents, a native macOS app in the Soprano family for the `omp` and OpenCode coding
agents (`~/git/private/soprano-agents`, public at https://github.com/frknue/soprano_agents).

## Done
- All modules built and merged: provider (omp `--mode rpc-ui`), engine (sessions, steering,
  queue, approvals, questions, checkpoints, revert, diffs,
  titles, branch names, git actions), JSON store, git (checkpoints in hidden refs, worktrees,
  status, commit/push/PR via gh), sidebar, chat header, timeline, composer, right panel (tabs per
  thread: Diff, Files explorer, read-only file tabs, Terminal tabs, "Open a surface" launcher),
  terminal drawer (SwiftTerm, sharing `ThreadTerminalStore` with the panel), thread details card,
  palette, settings screen, dialogs, notifications, icon.
- `swift test`: 452 tests. Offscreen snapshots of every fixture in light and dark.
- Live end-to-end smoke (real CLI, throwaway repo): omp thread (claude-haiku-5-5 via omp) in a
  new worktree with file-change and command approvals, checkpoint diff, omp-generated title and
  branch, a full-access relaunch on the same session file, Edit from here with file restore (omp
  `navigate_tree`), and reload + resume.
- OpenCode (2026-11-04): second provider over OpenCode 2.x's v2 HTTP API on its background service
  (pairing through `opencode api server.pair`). Live smoke on the real service (claude-agent/haiku,
  throwaway folder): write + shell with approvals and live output, question form, steer, subagent,
  side question, compaction, rollback, and the engine driving it (revert drops the turn from the
  conversation). `swift test`: 671 tests.

## Next
- Geplante Features nach Priorität: `docs/BACKLOG.md` (zuerst 1–3: in den Base-Branch mergen und
  aufräumen, Live-Checkliste, Link-Karte).
- First real GUI session (not launched by agents): check the terminal drawer's colors (the
  offscreen harness renders SwiftTerm's background white, drawer and panel tabs alike), the
  composer blur, window focus, and the right panel's "+" menu and file context menu (native
  menus don't show in snapshots).
- Known gaps: `docs/ROADMAP.md`; slice-level gaps (no diff search, no pull action in the engine,
  code blocks wrap instead of scrolling).

## Open decisions
- Add a release workflow like the siblings.
