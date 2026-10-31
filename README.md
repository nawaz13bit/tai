# terminal_ai (`tai`)

One terminal window with a project dashboard and several Claude Code panes.

- `windows/` — PowerShell + Windows Terminal version (entry point `windows/tai.ps1` / `windows/tai.cmd`).
- `linux/` — Bash + tmux port (entry point `linux/tai`; needs bash 4+, tmux 3+, jq). Same features as the Windows
  version: hook-driven working / waiting / done states, sub-agent and shell counts, model / effort / ctx / compact,
  git and GitHub row, Claude / Codex / agy usage bars, pinned keys block, session restore and pane move (M + arrow).
  Setup: copy the hooks / status line from `linux/claude-settings.json`, `linux/codex-hooks.example.json` and
  `linux/agy-settings.example.json` into the CLIs' settings, replacing `/path/to/terminal_ai` with this checkout.
  Also supported: opencode, Cursor (`agent`), Copilot and Qwen Code. They launch and resume (`--continue`) with no setup;
  `qwen-settings.example.json` (to `~/.qwen/settings.json`), `copilot-hooks.example.json` (to `~/.copilot/hooks/`) and
  `cursor-hooks.example.json` (to `~/.cursor/hooks.json`) add working / waiting / done status. opencode has no command hooks.
  The `windows/` folder has the same files. Flags and hook schemas come from the docs and are untested here.
  Not run yet on a real machine (written on Windows without tmux or jq).

Each folder keeps its own runtime `state/`.
Windows hook/statusline settings reference `windows/*.ps1` by absolute path.

## Quick start

- **Windows** (PowerShell 5.1, Windows Terminal): copy `windows/projects.example.json` to `windows/projects.json` and
  list your projects (or add them with `A` in the dashboard). Claude panes need no manual setup: tai passes Claude
  the hooks / `statusLine` in `windows/claude-settings.json`, which it creates on first start from
  `windows/claude-settings.example.json` with `C:/path/to/terminal_ai` replaced by your checkout (forward slashes,
  e.g. `C:/%username%/terminal_ai` if you cloned it to `C:\%username%\terminal_ai`; replace `%username%` with your real
  folder name).
  The example is the tracked template; `claude-settings.json` is the git-ignored copy actually in use. Delete it to
  regenerate. Press `H` in the dashboard to install them for you: for each installed CLI (Codex, Qwen, Cursor,
  Copilot) it asks y/N, copies your existing config to `*.tai-backup-<time>`, adds only tai's hook entries (nothing
  else is changed; running it twice adds nothing) and remembers the answer in `state/hooks-install.json`. Codex still
  needs `[features] hooks = true` in `~/.codex/config.toml`. Qwen/Cursor/Copilot formats are unconfirmed. By hand
  instead: for the other CLIs (Codex, Qwen, ...), the first dashboard start writes ready-to-use copies of the other
  `windows/*.example.json` files to `windows/generated/` (git-ignored, path already filled in; delete one to
  regenerate); copy them into those CLIs' own configs. Then run
  `windows/tai.cmd` (`windows/setup-profile.ps1` can add a `tai` command to your PowerShell profile).
- **Linux / macOS**: install bash 4+, tmux 3+ and jq, edit the `linux/*` settings the same way, then run `linux/tai`.

Licensed under the MIT License (see `LICENSE`).

## Dashboard keys (Windows)

- `Enter` opens the selected project; `Up` / `Down` move the highlight.
- `Shift+Up` / `Shift+Down` reorder the selected project within its agent group; the highlight follows it and the
  order is saved to `projects.json` (entries for the other OS keep their place).
- `A` add, `D` delete, `G` change agent, `M` + arrow move a pane.
- `F` opens `git diff HEAD` of the selected project in a new Windows Terminal tab (`windows/diffview.ps1`; `q` closes it).
- `W` creates a git worktree for the selected project.
- `T` turns "needs you" toasts on or off. The choice is the file `windows/state/toast.off` and survives restarts;
  waiting states are still recorded while off, so turning toasts back on doesn't replay old prompts.
- `P` commits all changes (asks for a message), pushes the branch, and offers `gh pr create --fill` when `gh` is installed
  and you're not on main/master. Credential prompts are disabled, so a missing login fails instead of hanging.
- `/` finds a project: type to jump to the first name match, `Tab`/Down next, Up previous, `Enter` keep, `Esc` cancel.
- `V` toggles a live preview under the list. Windows shows the last reply of a Claude session (read from its transcript);
  Linux shows the last lines of the pane's screen for any CLI. Flag file `preview.on` in the state folder.

The Linux port has the same keys: Shift+Up/Down reorder, `P`, `/`, `V`, `F` (diff in a new tmux window, `q` closes it), `W` (worktree), `T` (toasts via `notify-send`/`osascript`, flag file `~/.config/tai/state/toast.off`). They are syntax-checked only (`bash -n`), not yet run on a real machine.

## Shared config

- `agents.json` (repo root) is the one registry of per-CLI facts, read by both versions: `exe`, `args` (always passed),
  `resume` / `fresh` (extra args; `{name}` becomes the project name), `env` and, for Claude, `settingsFlag`
  (Windows only). Property order is the order of the CLI list. Add a CLI here to launch it on both OSes.
- `projects.json` can be one file for both OSes: set `TAI_CONF` to a folder holding it (Linux default `~/.config/tai`;
  on Windows it overrides `windows/projects.json`). A project's `path` is a plain string or
  `{"windows": "C:\\code\\app", "linux": "/home/me/code/app"}`; plain strings only show on the OS they belong to,
  and entries for the other OS are kept untouched. Runtime state (`state/`, usage, open panes) stays per machine.
- Codex hooks need `[features] hooks = true` in `~/.codex/config.toml` and must be trusted on first run;
  `codex-hooks.example.json` has a `commandWindows` entry so one hooks file can serve both OSes.
- Qwen's `Stop` hook reports `context_usage`, so the dashboard shows a ctx value for Qwen.
- Copilot starts with `--no-alt-screen` and opencode with `OPENCODE_DISABLE_TERMINAL_TITLE=1` (both from `agents.json`).

## Cross-CLI collaboration (research only, nothing built yet)

Researched 2026-10-27; "doc" = read in official docs, "snippet" = search snippet only, "unverified" = third-party or conflicting.
Check each flag with the CLI's `--help` before relying on it.

- **Headless calls** (a lead agent runs another CLI and reads the reply): `claude -p --output-format json` (doc),
  `codex exec --json` / `codex exec resume --last` (doc), `opencode run -m provider/model --format json` (doc),
  `agent -p --output-format json` (snippet; set the format explicitly, docs disagree on the default),
  `qwen -p` and `copilot -p` (snippet), `agy -p` (unverified; a reported issue says it hangs when piped).
- **MCP:** `claude mcp serve` and `codex mcp-server` (unverified); community wrappers such as `codex-as-mcp` let Claude
  call Codex but run it with sandboxing off. No official path found for Codex calling Claude. PAL MCP Server's `clink`
  covers several CLIs (maturity unknown).
- **ACP** (an editor drives an agent, not agent-to-agent): Copilot `--acp --stdio`, opencode `acp`. No A2A support found.
- **One tool, many providers:** opencode subagents with their own `provider/model` (doc); Claude Code through a
  LiteLLM / router proxy via `ANTHROPIC_BASE_URL` (bills the other provider's API).
- **Risks:** concurrent edits, agents looping through each other, cost, prompt injection from one agent's output into another.
- **Suggested order for `tai`:** (1) shared `AGENTS.md` plus a task-board file per project; (2) one git worktree and
  branch per CLI, merged by hand; (3) a headless "ask" command per pane with a turn limit and a logged transcript,
  writing replies to the board rather than into another pane. Defer MCP / ACP bridges.
