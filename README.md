# terminal_ai (`tai`)

One terminal window with a project dashboard and several Claude Code panes.

| Folder | Stack | Entry point | Status |
|---|---|---|---|
| `windows/` | PowerShell 5.1 + Windows Terminal | `windows/tai.cmd` / `windows/tai.ps1` | Used daily; newer features not all tested live |
| `linux/` | Bash 4+ + tmux 3+ + jq | `linux/tai` | Feature parity with Windows; `bash -n` checked only, never run on a real machine |
| `macos/` | zsh + tmux + jq | `macos/tai` | Linux port with BSD tools and `osascript` toasts; never run (see `macos/README.md`) |

Both Windows and Linux give you:

- one terminal window with a project dashboard plus one pane per open project (Claude Code, Codex, agy, opencode,
  Cursor `agent`, Copilot, Qwen Code); opencode, Cursor, Copilot and Qwen launch and resume (`--continue`) with no setup;
- hook-driven working / waiting / done states, sub-agent and shell counts, model / effort / ctx / compact;
- git and GitHub row, Claude / Codex / agy usage bars, pinned keys block, session restore, pane move (`M` + arrow);
- per-project agent accounts (Claude and Codex), toasts when an agent needs you, diff / worktree / push / PR / preview / find.

Differences: Windows uses Windows Terminal panes and reads Claude transcripts for the preview; Linux uses tmux windows
and panes and shows the pane's screen. On Windows, `Protect-Tai` raises the dashboard and Windows Terminal priority and
keeps the dashboard's memory resident to reduce UI lag; on Linux agents run niced (`TAI_AGENT_NICE`, default 5; 0 turns it off).
Hook and status-line examples sit in both folders (`claude-settings`, `codex-hooks`, `agy-settings`, `qwen-settings`,
`copilot-hooks`, `cursor-hooks`); flags and hook schemas come from the docs and are untested here.

Each folder keeps its own runtime `state/`.
Windows hook/statusline settings reference `windows/*.ps1` by absolute path; Linux ones reference `linux/*.sh`.

## Quick start

- **Windows** (PowerShell 5.1, Windows Terminal): copy `windows/projects.example.json` to `windows/projects.json` and
  list your projects (or add them with `A` in the dashboard). Claude panes need no manual setup: tai passes Claude
  the hooks / `statusLine` in `windows/claude-settings.json`, which it creates on first start from
  `windows/claude-settings.example.json` with `C:/path/to/terminal_ai` replaced by your checkout (forward slashes,
  e.g. `C:/%username%/terminal_ai` if you cloned it to `C:\%username%\terminal_ai`; replace `%username%` with your real
  folder name).
  The example is the tracked template; `claude-settings.json` is the git-ignored copy actually in use. Delete it to
  regenerate. (On Linux and macOS there is no example: `linux/claude-settings.json` and `macos/claude-settings.json`
  are tracked and edited directly.) Press `H` in the dashboard to install them for you: for each installed CLI (Codex, Qwen, Cursor,
  Copilot) it asks y/N, copies your existing config to `*.tai-backup-<time>`, adds only tai's hook entries (nothing
  else is changed; running it twice adds nothing) and remembers the answer in `state/hooks-install.json`. Codex still
  needs `[features] hooks = true` in `~/.codex/config.toml`. Qwen/Cursor/Copilot formats are unconfirmed. By hand
  instead: for the other CLIs (Codex, Qwen, ...), the first dashboard start writes ready-to-use copies of the other
  `windows/*.example.json` files to `windows/generated/` (git-ignored, path already filled in; delete one to
  regenerate); copy them into those CLIs' own configs. Then run
  `windows/tai.cmd` (`windows/setup-profile.ps1` can add a `tai` command to your PowerShell profile).
  The repo row is hidden for folders that aren't git repos.
- **Linux**: install bash 4+, tmux 3+ and jq (`notify-send` optional, for toasts). Copy the hooks / status line from
  `linux/claude-settings.json`, `linux/codex-hooks.example.json` and `linux/agy-settings.example.json` into the CLIs'
  settings, replacing `/path/to/terminal_ai` with this checkout (the other examples go to `~/.qwen/settings.json`,
  `~/.copilot/hooks/` and `~/.cursor/hooks.json`; opencode has no command hooks). Press `H` in the dashboard to install
  them for you. List projects in `~/.config/tai/projects.json` (or press `A`), `chmod +x linux/tai`, then run `linux/tai`.
- **macOS**: `brew install tmux jq`, edit the `macos/*` settings the same way, `chmod +x macos/tai`, then run `macos/tai`.

Licensed under the MIT License (see `LICENSE`).

## Dashboard keys (Windows)

- `Enter` opens the selected project (or focuses its pane if already open); `Up` / `Down` move the highlight (a held key is folded into one move per redraw, so it stays smooth).
  The highlight also follows pane focus: click or move into a project's pane and the dashboard selects that project.
- A running `tai delegate` shows as `⇄ codex 1:15` at the end of the project's row (see Delegate).
- `X` closes the selected project and its pane (asks y/N; a reply in progress is cut off). `R` re-reads the pane layout
  (use it after moving panes by hand). `H` installs tai's hooks into the other CLIs' configs (see Quick start).
- `Shift+Up` / `Shift+Down` reorder the selected project within its agent group; the highlight follows it and the
  order is saved to `projects.json` (entries for the other OS keep their place).
- `A` add, `D` delete (open projects must be closed with `X` first), `G` change agent, `U` change account (closed projects only; see Accounts).
- `M` then an arrow key moves the selected project's pane in that direction.
- `F` opens `git diff HEAD` of the selected project in a new Windows Terminal tab (`windows/diffview.ps1`; `q` leaves git's pager, then any key closes the tab, so short or empty diffs stay visible).
- `W` creates a git worktree for the selected project.
- `S` opens an agents screen for the selected project in a new Windows Terminal tab (`windows/agentsview.ps1`); on Linux/macOS
  it opens a new tmux window (`agentsview.sh` / `agentsview.zsh`, `q` closes it).
  The bottom block ends with a one-line count: `agents: N open (…) - W working, X waiting, I idle`.
- `T` turns "needs you" toasts on or off. The choice is the file `windows/state/toast.off` and survives restarts;
  waiting states are still recorded while off, so turning toasts back on doesn't replay old prompts.
- `P` commits all changes (asks for a message), pushes the branch, and offers `gh pr create --fill` when `gh` is installed
  and you're not on main/master. Credential prompts are disabled, so a missing login fails instead of hanging.
- `/` finds a project: type to jump to the first name match, `Tab`/Down next, Up previous, `Enter` keep, `Esc` cancel.
- `V` toggles a live preview under the list. Windows shows the last reply of a Claude session (read from its transcript);
  Linux shows the last lines of the pane's screen for any CLI. Flag file `preview.on` in the state folder.

The Linux and macOS ports have the same keys (macOS is zsh, checked with `zsh -n` only once run on a Mac; until then unchecked): Shift+Up/Down reorder, `P`, `/`, `V`, `F` (diff in a new tmux window, `q` closes it), `S` (agents screen in a new tmux window; Claude sessions via `claude agents --json`, Codex/others show tai's own panes), `W` (worktree), `T` (toasts via `notify-send`/`osascript`, flag file `~/.config/tai/state/toast.off`), `U` (account, see Accounts), `H` (hook installer, same as Windows; files in `generated/`, answers in `state/hooks-install.json`), `R` (reload config and refresh usage). Agents run niced (`TAI_AGENT_NICE`, default 5; 0 turns it off). They are syntax-checked only (`bash -n`), not yet run on a real machine.

## Accounts (Windows, Linux, macOS; Claude and Codex only)

Copy `accounts.example.json` to `accounts.json` (git-ignored) and list named accounts per CLI as config folders, e.g.
`"claude": {"personal": "~/.claude", "work": "~/.claude-work"}`. The first is the default. A CLI keeps its login in its
config folder, so a pane on another account just gets `CLAUDE_CONFIG_DIR` / `CODEX_HOME` (the `configEnv` entry in
`agents.json`) pointed at that folder; the CLI's own default folder (`defaultDir`) is left unset.

- `U` cycles the selected closed project's account; it is saved per agent in `projects.json` (`"accounts": {"claude": "work"}`).
  Rows show `@work` for agents with 2+ accounts. Reopen the project to use it.
- The detail block shows the real login (`claude @work: me@x.com (pro)`), read via `claude auth status` (background, cached
  10 min) or from Codex's `auth.json` (email and plan only). It warns on `not logged in` and on two accounts that are the same login.
- A new account's folder is created on first launch and the CLI asks you to sign in once. A new Codex folder gets a copy of
  `~/.codex/hooks.json` and `config.toml` (Codex may ask to trust the hooks again); Claude gets its hooks via `--settings`.
- Usage bars follow the highlighted project's account (header `-- claude @work --`; otherwise the agent's first account).
  Claude panes on a non-default account write `windows/usage-<folder>.json` (from `CLAUDE_CONFIG_DIR`); Codex usage is
  read from that account's `<CODEX_HOME>\sessions`.
- **agy has no accounts**: it has no config-folder flag or variable, and per its community docs the Google login sits in the
  OS keyring (global on Windows), so a per-pane account can't be selected. Not wired (unverified here).
- On Linux and macOS the per-account usage file is `$TAI_CONF/usage-<folder>.json` and the login line comes from the same
  `claude auth status` / `auth.json` lookups (needs `jq`). Project rows don't show an `@account` tag there; the usage
  header and the login line do. Not run live yet.
- Not done: other CLIs have no `configEnv`.

## Shared config

- `agents.json` (repo root) is the one registry of per-CLI facts, read by both versions: `exe`, `args` (always passed),
  `resume` / `fresh` (extra args; `{name}` becomes the project name), `env` and, for Claude, `settingsFlag`
  (Windows only). Property order is the order of the CLI list. Add a CLI here to launch it on both OSes.
- `projects.json` can be one file for both OSes: set `TAI_CONF` to a folder holding it (Linux default `~/.config/tai`;
  on Windows it overrides `windows/projects.json`). A project's `path` is a plain string or
  `{"windows": "C:\\code\\app", "linux": "/home/me/code/app", "macos": "/Users/me/code/app"}`; plain strings only show on the OS they belong to,
  and entries for the other OS are kept untouched. Runtime state (`state/`, usage, open panes) stays per machine.
- Codex hooks need `[features] hooks = true` in `~/.codex/config.toml` and must be trusted on first run;
  `codex-hooks.example.json` has a `commandWindows` entry so one hooks file can serve both OSes.
- Qwen's `Stop` hook reports `context_usage`, so the dashboard shows a ctx value for Qwen.
- Copilot starts with `--no-alt-screen` and opencode with `OPENCODE_DISABLE_TERMINAL_TITLE=1` (both from `agents.json`).

## Delegate (Windows only)

`windows/delegate.cmd <target> "<task>"` lets one agent hand work to another CLI. The target runs headless (one shot) in
the same project folder and blocks until it finishes; its reply is printed and saved. Targets: `claude`, `codex`, `agy`
(`gemini` is accepted as an alias of `agy`).

- Options: `-Project <dir>`, `-Summary "<what has been done>"` (max 3000 chars), `-Files a,b`, `-Edit`, `-TimeoutSec 600`,
  `-Allow <rule>`, `-AllowWide`, and `-History` (lists past delegations of the project).
- Files live in `<project>\.tai\`: `task-<target>.md`, `reply-<target>.md`, a `running-<target>.lock` and
  `history\delegations.jsonl` (runs older than 30 days or beyond the last 50 are pruned). Exit code: 0 done, 1 failed /
  blocked / refused, 2 timed out. A delegate cannot delegate further.
- Read-only by default. `-Edit` lets the target change files (use a worktree if the caller is editing too). Headless runs
  can't ask for permission, so shell commands need `-Allow` in the target's own rule syntax (claude `Bash(npm test)`, agy
  `command(npm test)`). Rules that allow almost everything (a bare tool, `*`, a shell or interpreter) are refused unless
  `-AllowWide`. There are no skip-all-permissions flags. A blocked run reports what the target said, so you can see which
  rule it needs.
- Agents learn about it from a hint passed at launch through the `delegateHint` field in `agents.json` (claude, codex, agy);
  you can just say "delegate this to codex" in a pane. The project's account is used for the target.
- Linux and macOS have no delegate yet.

## Cross-CLI collaboration (research; only the headless hand-off is built, see Delegate)

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
