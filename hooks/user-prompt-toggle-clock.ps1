# UserPromptSubmit hook: flip the 5h/7d rate-limit clock for this session.
# The statusline shows 5h when the sentinel is absent, 7d when present; on a
# wide terminal the other clock still fills in beside it. The flip rides the
# prompt redraw so the swap reads as natural.
#
# NOTE: this toggles on EVERY non-slash prompt, so the primary clock alternates
# as you work. If you'd rather pick a clock once and leave it, simply don't
# register this hook (the statusline defaults to 5h primary).
#
# Skip slash commands (/deets, /clear, ...) — they're UI state changes, not real
# turns; flipping the clock as a side effect of typing /deets would surprise.

try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $d = $raw | ConvertFrom-Json } catch { exit 0 }

$prompt = [string]$d.prompt
if ($prompt.StartsWith('/')) { exit 0 }
$sid = [string]$d.session_id
if (-not $sid) { exit 0 }

$cfg = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE ".claude" }
$stateDir = Join-Path $cfg "state"
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
$flag = Join-Path $stateDir "clock-toggle-$sid.flag"
if (Test-Path $flag) { Remove-Item $flag -Force } else { New-Item -ItemType File -Path $flag -Force | Out-Null }
exit 0
