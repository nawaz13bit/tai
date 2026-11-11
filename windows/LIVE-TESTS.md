# tai live test checklist

Before starting: close all tai panes, then launch `tai` fresh (new scripts load only on restart).
Tick each box; note anything odd next to it.

## 1. Core features
- [x] Launch tai with 1 project: focus lands on the dashboard.
- [x] Open 2, 3, 4 projects with Enter: layout adapts, each pane gets the right project.
- [x] Hook states: send a prompt in a pane, dashboard shows `working`, then `! waiting` on a permission prompt, then `done <age>`.
- [x] `▶ N sh` appears while Claude runs a shell command.
- [x] `M` + arrow swaps a project with its neighbour; sessions keep running.
- [x] `R` re-reads the layout (no "Could not read the layout").
- [x] `X` on a project with several panes: Claude stops, the pane closes (check WT closes it after `[Environment]::Exit(0)`).
- [x] `X` on the last pane: pane is emptied, not removed.
- [x] Close a pane by hand (Ctrl+Shift+W): dashboard shows "Pane N closed" within ~1 s.
- [x] Reopen a project after a hand-closed pane: a new pane opens (no stale `slotN.assign`).
- [x] Kill a pane's Claude from outside: the pane shows the CLI-exit menu (confirmed live 2026-10-30). Note: the slot file's pid is the `slot.ps1` wrapper, not Claude; killing the wrapper leaves Claude orphaned in the pane while the dashboard shows the project closed (not fixed).
- [x] Run `tai` again while panes are alive: relaunch guard refuses.
- [x] `D` on a closed project: asks y/N, folder stays on disk, `A` re-adds it.

## 2. Multi-agent
- [x] Enter on a project with no saved agent shows the chooser (Up/Down+Enter, digits, Esc cancels).
- [x] `G` cycles the agent of a closed project.
- [x] `A` with a non-existent path offers to create the folder (y/N), then lists it.
- [x] Exit the CLI inside a pane (`/exit`): menu shows Restart / Switch / Close project.
- [x] Switch to another CLI: it relaunches in the same pane and the choice is saved.
- [x] Esc or idle on the menu leaves the pane empty (idle timeout is 5 s; see section 3c).
- [x] (Only if codex/agy installed; Codex data and agy quotas confirmed live 2026-10-30) apply `agy-settings.example.json` / `codex-hooks.example.json`, check model/ctx/quota rows.

## 3. Fixes to confirm
- [x] Window title stays `pane N` (CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1).
- [x] Hook state files belong to the right project (TAI_PROJECT_DIR); `hook_*` files vanish when the session ends.
- [x] Resize/scroll bug: resize slot 1, then try mouse wheel and Shift+PgUp/PgDn.
  - If still broken, set `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1` in `slot.ps1` and retest.
  - Workaround meanwhile: Ctrl+O then `[`.
- [x] Idle sessions keep model/effort/ctx fresh in the dashboard. (`refreshInterval` was never needed or applied.)

## 3b. Added 2026-10-21 (all confirmed live; restart tai first)
- [x] Pane limit by monitor size: `state\cells.json` holds the monitor's [columns, rows] (208x72 on this 1080p at font 8) and tai stops at 4 panes (min pane 55x24 cells), even after you resize panes by hand. Dashboard says "Window fits only N panes" when full.
- [x] (`G` cycles only installed CLIs, confirmed live 2026-10-30; the startup message itself was too brief to read) Dashboard starts with "CLIs found: claude" (only installed CLIs); chooser is skipped with one CLI, `G` only cycles installed ones.
- [x] `/exit` in a pane when 2+ panes are open: press Esc, or wait 5 s, or pick "Close project (and pane)": the pane closes.
- [x] After that, the dashboard shows "Pane N closed, layout re-read" and the remaining panes still match their projects (try M and Enter).
- [x] `/exit` in the last remaining pane: it stays open and empty (not closed).
- [x] Restart and Switch in that menu still work.

## 3c. Added 2026-10-21 (all confirmed live; restart tai first)
- [x] Session restore: open 2-3 projects, close the whole window, run `tai`: the same projects reopen one by one (about 2.5 s apart), each resuming its last conversation; the dashboard says "Reopening N project(s)".
- [x] After the restore, focus lands on the dashboard and the restored panes stay open beside it.
- [x] A project closed with X before closing the window is not reopened. Closing every project with X, then restarting, reopens nothing.
- [x] (confirmed live 2026-10-30) A saved project that was removed from the list (D) is skipped with a message and the rest still open.
- [x] (confirmed live 2026-10-30) Close a pane by hand with 2+ panes open: after "Pane N closed, layout re-read", focus returns to the dashboard (`Focus-Dashboard`).
- [x] CLI-exit menu: with no key pressed, the pane closes after 5 s (2+ panes) and the hint reads "Esc or 5 s idle: close pane"; a key press stops the timer.

## 4. Unconfirmed
- [x] Usage bars show real hourly/weekly numbers (after the first reply).
- [x] Claude sends effort to the status line.
- [x] Per-pane status line looks right: `[folder] ctx N% | compact in ~N%`.
- [ ] 5+ panes in a very large window; unequal pane sizes. (This monitor stops at 4 panes, so 5+ can't be tested here. Defer to a bigger display.)
- [ ] Closing the 4th pane (4 to 3 panes): wt cannot re-split running panes, so `Optimize-Layout` only fixes 2 stacked panes and 3/4 keep wt's own shape. Re-test after a tai restart; reopening tai lays out 3/4 correctly via `Get-NextSplit`.
- [ ] Wrapper pid killed from outside: Claude is left orphaned in the pane while the dashboard shows the project closed (unfixed, see section 1).

## 5. Built 2026-10-31, not yet seen live (restart tai first)
- [ ] `P` on a scratch repo with changes: asks for a message, commits, pushes the branch, offers `gh pr create --fill` when `gh` is installed. Commit message has no BOM (`git log -1 --format=%B | xxd | head`).
- [ ] `P` on a repo with nothing to commit, and on a folder that is not a repo: clear message, nothing breaks.
- [ ] `V` toggles the preview under the list; with a Claude session selected it shows the last reply (wrapped, up to 4 rows). Other CLIs show "claude only"; a closed project shows "not open".
- [ ] `V` state survives a dashboard restart (flag `preview.on`).
- [ ] `/` find: type part of a project name, the cursor jumps to the match, nothing is hidden, and M/reorder/save still use the full list.
- [x] `F` on a project with no changes or a short diff: the tab stays open until a key is pressed (confirmed 2026-10-31).
- [x] `T` toast toggle and `F` diff / `W` worktree were confirmed live 2026-10-30; no re-test needed.

## 6. Built 2026-11-06, not yet seen live (restart tai first)
- [ ] `S` opens the agents screen tab for a Claude, a Codex and another-CLI project; `q` closes it.
- [ ] Bottom block ends with `agents: N open (...) - W working, X waiting, I idle`; counts change as agents work, wait and finish.
- [ ] Codex project in `waiting` flips back to working once Codex resumes (rollout write), including a project on a second Codex account.
- [ ] Codex effort row shows the `model_reasoning_effort` from `config.toml` (not a value from a `[profiles.*]` table).
- [ ] agy shows `done`, and a stale `working` report goes idle after 3 minutes.
- [ ] Repo row is hidden for a non-git folder.
- [ ] Linux/macOS (on a real machine): `S` opens a tmux window; arrows work (macOS: fractional `read -t`); empty session list shows no blank row.
- [ ] Linux/macOS dashboards now match Windows: the `agents: N open ...` line, Codex effort + ctx rows (rollout log), Codex waiting-clear, agy `done` / stale-working-to-idle. macOS `codex_scan` (zsh glob `(.NOm[1,20])`, `=~` with `$match`) is unverified: check Codex ctx shows up.

## 7. `tai delegate`, built 2026-11-07/08, Windows only (windows\delegate.ps1, delegate.cmd)
Tested headless by hand (claude, codex, agy); not yet seen from a real pane.
- [ ] By hand in a project folder: `windows\delegate.cmd codex "say ok"` prints the reply and `[tai delegate: codex done ...]`; `.tai\task-codex.md` and `.tai\reply-codex.md` exist; `.tai\history\` gets one file and a `delegations.jsonl` line. Same for `agy` and `claude`.
- [ ] Read-only: ask a target to create a file; it must be refused or reported as blocked, no file appears. With `-Edit` the file is created and listed as changed.
- [ ] A shell command the target needs (for example `npm test`) reports `blocked`; re-running with `-Allow` for that command works (rule syntax differs: claude `Bash(npm test)`, agy `command(npm test)`).
- [ ] Too-wide `-Allow` (for example `Bash(*)`, `Bash`, `Bash(bash:*)`, `command(regex:.*)`) is refused with "-Allow rule too wide" and nothing runs; `-AllowWide` overrides it. Every run logs `allow` (the rules) and `wide` in `.tai\history\delegations.jsonl`.
- [ ] `-Summary "..."` and `-Files a.txt,b.txt` show up as "Context..." and "Files to look at" lines in `task-<target>.md`.
- [ ] Two delegations to the same target at once: the second is refused (lock). Exit codes: 0 done, 1 failed/blocked, 2 timed out (`-TimeoutSec 5` with a slow task).
- [ ] Non-git project: `.tai\` is created, nothing breaks; git project: `.tai/` is added to `.git/info/exclude`.
- [ ] Hint reaches the agents (restart tai first): in a Claude, a Codex and an agy pane type "delegate to <another CLI>: say ok". The agent runs delegate.ps1 and relays the reply. `windows\generated\delegate-hint-<agent>.md` exists per agent.
- [ ] agy pane: the first thing in the chat is the hint message answered with just `ok` (no tool call, no approval prompt). Restarting the pane (resume) sends it again.
- [ ] Claude pane after `--continue`: the hint still applies (`--system-prompt-snapshot off`).
- [ ] "summarise this chat and send file X to codex": the agent fills `-Summary` and `-Files`.
- [ ] Known limits: read-only is best effort (agy blocks writes by rule; claude plan mode; codex sandbox); claude permissions on a clean install are untested (without a global Bash allow, git commands may be blocked); a delegate cannot delegate further.

## 8. Worktree key `W`, changed 2026-11-08 (restart tai first)
- [ ] `W` with a new branch name: worktree `<project>-<branch>` is created and listed directly below the project, same CLI group.
- [ ] `W` with a branch that already has a worktree (listed or not): that folder is reused, listed below the project; if it is already listed the cursor jumps to it ("already listed").
- [ ] `W` with an existing branch that has no worktree: a worktree is created on that branch (no `-b`).
