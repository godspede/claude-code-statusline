# UserPromptExpansion hook: intercept the `/deets` slash command and toggle the
# global deets-mode sentinel so the statusline switches between the one-line
# default and the verbose two-line layout.
#
# WHY UserPromptExpansion (not UserPromptSubmit): recent Claude Code routes a
# REGISTERED custom slash command (commands/deets.md) through the command
# expansion path, so the literal "/deets" no longer reaches UserPromptSubmit
# hooks — it arrives as a UserPromptExpansion event carrying command_name. We
# match on command_name first and keep the literal-prompt regex as a fallback.
#
# Exit 0 (NOT 2): this is a pure side-effect. deets.md carries an empty body +
# `disable-model-invocation: true`, so exit 0 lets the expansion proceed to an
# empty prompt that fires no model turn. We deliberately do NOT exit 2 — a
# non-zero UserPromptExpansion exit makes Claude Code show "UserPromptExpansion
# operation blocked by hook: <stderr>", which reads as an error to the user. On
# an exit-0 hook the stderr line below lands in the debug log, not the
# transcript, so the toggle is silent — the statusline flipping to/from the
# two-line layout is the real confirmation.
#
# Sentinel is GLOBAL (not per-session) so a flip from any window affects all of
# them on next render, and the state survives across new windows.

try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $d = $raw | ConvertFrom-Json } catch { exit 0 }

$prompt = [string]$d.prompt
$cmd = [string]$d.command_name
if ($cmd -eq 'deets' -or $prompt -match '^/deets\s*$') {
    $cfg = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE ".claude" }
    $stateDir = Join-Path $cfg "state"
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    $flag = Join-Path $stateDir "deets-mode.flag"
    if (Test-Path $flag) {
        Remove-Item $flag -Force
        [Console]::Error.WriteLine("deets mode OFF")
    } else {
        New-Item -ItemType File -Path $flag -Force | Out-Null
        [Console]::Error.WriteLine("deets mode ON")
    }
    exit 0
}
exit 0
