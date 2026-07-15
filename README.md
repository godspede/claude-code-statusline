# claude-code-statusline

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: Windows / PowerShell](https://img.shields.io/badge/platform-Windows%20%7C%20PowerShell-5391FE.svg)

A rich, self-contained statusline for [Claude Code](https://claude.com/claude-code)
on **Windows / PowerShell**. One line by default; `/deets` flips a verbose
two-line layout.

```
● Opus 4.8 @14:32 ◐ high | myrepo@main (+42 -7) | 128k/200k | 5h 34% @15:00
```

## What it shows

- **`●` state badge** — colour = session state: blue *working*, green *ready*,
  yellow *awaiting* (Claude asked you something and is waiting), dim *stale*.
- **Model name** and an **effort gauge** (`○ low` … `◈ max`).
- **`@HH:mm`** — when your last message was received.
- **`repo@branch`** with live **`(+N -M)`** diff stats.
- **token / context** usage.
- **5h / 7d rate-limit clocks** with reset times. `/deets` toggles a two-line
  layout showing both clocks plus the model.

The line **elastically fits** your terminal width — as the window narrows,
cells drop in priority order: second clock → effort → diff stats → branch →
repo → model name. The `●` bullet and the `@HH:mm` received-time never drop, and
one rate-limit clock is always shown — when both can't fit, the visible one
alternates between 5h and 7d on each redraw.

## No external dependencies

The statusline reads Claude Code's own status JSON on stdin. The **only**
network call it ever makes is to Anthropic's `oauth/usage` endpoint using *your*
Claude Code credentials — the same thing the CLI already does — and only to show
the extra-usage credit segment; the 5h/7d clocks come straight from the stdin
data with no auth. Everything else is local.

The companion **hooks** (in `hooks/`) power the interactive bits — the awaiting
badge and the `/deets` toggle. They are tiny PowerShell scripts
that only read the hook JSON Claude Code hands them and touch flag files under
`~/.claude/state`. No LLM calls, no services, no daemons, no jq. You can install
the statusline alone and skip the hooks; you just lose those interactive states
(the line still renders everything else).

## Install

See **[INSTALL_GUIDE.md](INSTALL_GUIDE.md)** — it's written so you can hand it to
Claude Code and say *"follow this."* Or do it by hand: copy `statusline.ps1`,
`hooks/`, and `commands/` into `~/.claude/`, then merge `settings.example.json`
into `~/.claude/settings.json`.

## Requirements

- Windows with **PowerShell 7+** (`pwsh`) — recommended — or Windows PowerShell 5.1.
- `git` on `PATH` (for the `repo@branch` cell).
- Claude Code.

## Credit

Based on [daniel3303/ClaudeCodeStatusLine](https://github.com/daniel3303/ClaudeCodeStatusLine)
by Daniel Oliveira.

## License

[MIT](LICENSE). Original work © 2025 Daniel Oliveira; this Windows/PowerShell
derivative © 2026 godspede.
