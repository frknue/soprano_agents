# Soprano Agents

Native macOS GUI for coding agents (Codex, Claude Code) in the Soprano family, with the feel and
look of [T3 Code](https://github.com/pingdotgg/t3code): thread inbox, centered chat lane with a
floating composer, collapsible work logs, approvals, per-turn diffs from hidden git checkpoints,
worktrees, terminal drawer, right-panel diff. Swift 6 + programmatic AppKit (no
storyboards/xibs/SwiftUI), SPM, macOS 14+, drives the `codex` and `claude` CLIs directly.
Shipped as a hand-packaged `.app` via `scripts/package-app.sh`.

## Commands

Homebrew Swift with the Command Line Tools SDK. Xcode's newer SDK breaks Homebrew Swift, so pin
`DEVELOPER_DIR` on every direct Swift command:

```bash
export DEVELOPER_DIR=/Library/Developer/CommandLineTools PATH="/opt/homebrew/opt/swift/bin:$PATH"
swift build
swift test
swift test --filter CodexEventMapperTests
.build/debug/SopranoAgents snapshot --out /tmp/shot.png --fixture demo [--appearance dark] [--perform palette.open]
./scripts/dev.sh --build-only        # package .build/debug/Soprano Agents Dev.app (com.soprano.agents.dev)
./scripts/install.sh                 # release build → /Applications/Soprano Agents.app
```

`ld: warning: building for macOS-14.0 …` link warnings are expected. There is no linter or
formatter; match surrounding style.

## Verification

- Source changes: `swift build` and `swift test`.
- UI: the offscreen `snapshot` subcommand on `DemoFixtures` scenarios; read the PNG, check light
  and dark (options in `docs/ARCHITECTURE.md` → Verification harness). Do not launch the GUI or run
  `./scripts/dev.sh` without `--build-only` unless the user asks.
- Tests never start a real agent CLI, never touch the user's repositories, settings or app data.
  Provider parsing is tested against the recorded traces in `Tests/SopranoAgentsTests/Fixtures/`.
- A live provider smoke test (real `codex app-server` / `claude` turn in a throwaway repo under
  `/tmp`) is fine for verifying provider changes; keep prompts tiny.

## Installing completed changes

After a verified change to the app or its packaging, run `./scripts/install.sh` as the last step.
It replaces `/Applications/Soprano Agents.app` without restarting a running instance. Never use
`sudo`; report permission problems instead. Docs-only work needs no install.

## Commits and changelog

- Push, open PRs, or create tags only when the user asks for that remote action.
- Short imperative subjects, `feat:` / `fix:` / `docs:` / `test:` / `chore:` prefixes.
- User-visible changes get a line under `## [Unreleased]` in `CHANGELOG.md` (Keep a Changelog
  groups), written for the user and naming the shortcut or setting. Never add a version heading
  during feature work.
- Releases: rename `[Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`, add a fresh `[Unreleased]`, set
  `CFBundleShortVersionString` and `CFBundleVersion` in `Support/Info.plist` (the only version
  source), `swift test`, install, commit `release: vX.Y.Z`.

## Architecture

`docs/ARCHITECTURE.md` is the contract: module ownership, seams (engine, providers, git, UI
state, commands, settings), provider wire protocols, keyboard model, default bindings, visual
spec, harness. Keep it current when a seam, binding, or harness option changes.
`docs/t3code-spec.md` is the T3 Code reference (layout, tokens, strings, protocols) the UI copies.
`docs/ROADMAP.md` lists what is deliberately not built.

- `Sources/SopranoAgentsCore/` — Foundation only: domain models, `AgentEngine` (state owner),
  provider drivers/sessions (Codex app-server, Claude stream-json), git (`GitRunner`,
  `LiveGitService`: checkpoints, diffs, worktrees, commit/push/PR), JSON-file store.
- `Sources/SopranoAgents/Theme/` — `Palette` (T3 Code tokens), typography, metrics, shared controls.
- `Sources/SopranoAgents/Shell/`, `App/`, `Views/Palette/`, `Views/Settings/`, `Notifications/` —
  window, workspace layout, `WorkspaceState`, settings,
  keymap/router, dialogs, palette, settings screen, notifications, snapshot harness.
- `Sources/SopranoAgents/Views/{Sidebar,Chat,Timeline,Composer,Panels}` — the regions.
- `Sources/SopranoAgents/Commands/` — `AppCommand` registry; every action is a command.

## Conventions

- Look is T3 Code's: colors only from `PaletteCenter.shared.palette` (`theme: "t3"` default,
  Soprano themes map onto the same tokens), `Typography` roles, `Radius`, `Metrics`, SF Symbols via
  `Icon`. Views subclass `PaletteView` and re-color in `applyPalette(_:)`. Strings copy T3 Code's
  wording (spec) unless this app's behavior differs.
- Views never spawn processes, run git or talk to providers: everything goes through
  `AgentEngine`. UI state goes through `WorkspaceState`.
- New actions: add an `AppCommand` to the owning module's `…Commands.all`, add its row to the
  binding table in `docs/ARCHITECTURE.md`, and keep the README shortcut list in sync. Avoid ⌥
  chords (Soprano's `KeyChord` rejects them; German layouts need ⌥).
- Floating surfaces that must show in snapshots are child windows of the main window, not
  `NSPopover`.
- Persisted UI state uses an injectable `UserDefaults`; settings live only in
  `~/.config/soprano-agents/settings.json`; app data in `~/Library/Application Support/<bundle name>`.
- Tests: swift-testing, one `struct …Tests` per file, sentence-style names. Test files
  `import AppKit`, never `Foundation` (the `_Testing_Foundation` overlay breaks the build).

## Gotchas

- `Sources/SopranoAgents/Vendored/` is copied from Soprano by `scripts/sync-soprano-chrome.sh`
  (committed Soprano state only; source commit in `Vendored/SOPRANO_COMMIT`). Never edit it here.
  `scripts/render-app-icon.swift` is this repo's own copy (adds the `agents` glyph); not synced.
- GUI apps start with a minimal PATH; provider and git runners extend it (`~/.local/bin`,
  `/opt/homebrew/bin`, `/usr/local/bin`, `~/.bun/bin`, `~/.cargo/bin`).
- `codex app-server` sends server requests with numeric or string ids; answer with the same id.
- Signing reuses Soprano's "Soprano Local Development" identity and keychain.
- Dev (`com.soprano.agents.dev`) and installed (`com.soprano.agents`) apps keep separate data.
