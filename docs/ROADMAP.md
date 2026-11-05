# Roadmap

Deliberately not built yet, so nobody mistakes their absence for a bug. Geplante Arbeit steht in
`docs/BACKLOG.md`.

- Remote environments (SSH, Tailscale, relays, WSL), pairing, guest sharing.
- Agents other than omp and OpenCode (Codex, Claude Code, Cursor, upstream Pi, Grok, ACP registry
  agents).
- Plan mode: omp's RPC has no plan-mode switch (OpenCode's plan agent is not offered either).
- Statistics, Accounts and word completion for OpenCode: they read omp's own data and helpers.
- OpenCode side-question history across app runs: OpenCode keeps none, the app keeps this run's.
- Right-panel surfaces other than Diff, Files, file tabs and Terminal: in-app browser preview
  (im Backlog, nach der Link-Karte), pull request pages, device; editing files in the file tab.
- Subagent lineage tree.
- Team: OpenCode threads can't message teammates (the team tools are omp host tools; teammates
  run on omp); teammates act only when messaged (no schedules or standing check-ins); terminal
  omp gets a fresh copy of an exported teammate, not the one with its conversation and memory.
- Snooze, drag-and-drop inbox reordering, multi-select sidebar actions.
- Custom themes, theme editor, VS Code theme import (the `theme` setting picks a Soprano theme).
- Mobile and web clients.
