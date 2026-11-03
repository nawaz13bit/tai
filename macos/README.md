# tai for macOS (zsh + tmux)

A zsh rewrite of the Linux port. It uses the zsh that ships with macOS, so no newer bash is needed.

**Status: written without access to a Mac and never run.** Run the syntax check below first and expect small fixes.

## Install

```sh
brew install tmux jq        # gh is optional (issue / PR counts, P key)
chmod +x macos/tai macos/*.zsh
for f in macos/*.zsh macos/tai; do zsh -n "$f" && echo "ok $f"; done
macos/tai
```

## Hook setup

Press `H` in the dashboard to install the Codex, Qwen, Cursor and Copilot hooks automatically (backups made, idempotent;
ready-made copies are in `macos/generated/`). By hand instead: copy the entries from `claude-settings.json`, `codex-hooks.example.json`, `agy-settings.example.json`,
`qwen-settings.example.json`, `copilot-hooks.example.json` and `cursor-hooks.example.json` into each CLI's settings.
Replace `/path/to/terminal_ai` with this checkout. Commands start with `zsh `, so the execute bit is not needed.

## Terminal

- Any terminal works, including Terminal.app. The dashboard uses 16-colour ANSI only, so the terminal's colour scheme sets the look.
- iTerm2, WezTerm or Ghostty are recommended.
- The `Alt+D` binding (jump back to the dashboard) needs Option to act as Meta: Terminal.app → Settings → Profiles → Keyboard →
  "Use Option as Meta key"; iTerm2 → Profiles → Keys → Left Option key = Esc+.

## Differences from Linux

- BSD `ps`, `date`, `stat`, `md5 -q`; a `mkdir` lock instead of `flock`; no `readlink -f`.
- Toasts through `osascript` (T key toggles; flag file `~/.config/tai/state/toast.off`).
- Data (`projects.json`, `agents.json`, state) is shared with the other ports. A project path can be
  `{"windows": "...", "linux": "...", "macos": "/Users/me/code/app"}`.
- Same keys as Linux: arrows / j k, Enter, X, D, A, G, Shift+Up/Down, F, W, T, M, P, V, `/`, Q, plus `U` (switch the
  closed project's Claude / Codex account), `H` (hook installer) and `R` (reload config, refresh usage).
- Accounts: copy `accounts.example.json` to `accounts.json` (see the main README). The usage file per account is
  `$TAI_CONF/usage-<folder>.json`; the login line needs `jq` and `claude auth status`.
- Agents run niced (`TAI_AGENT_NICE`, default 5; 0 turns it off).
- Config lives in `~/.config/tai` (override with `TAI_CONF`); `agents.json` at the repo root is shared with the other ports.
