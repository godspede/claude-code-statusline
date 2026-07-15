# UserPromptSubmit hook: clear the awaiting-input sentinel the moment the
# operator types back. Pairs with stop-classify-awaiting.ps1.
#
# Skip slash commands (/deets, /clear, /loop, ...) — those are UI state changes,
# not answers to a surfaced question, so the badge should keep reflecting the
# real conversational state.

try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $d = $raw | ConvertFrom-Json } catch { exit 0 }

$prompt = [string]$d.prompt
if ($prompt.StartsWith('/')) { exit 0 }
$sid = [string]$d.session_id
if (-not $sid) { exit 0 }

$cfg = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE ".claude" }
Remove-Item (Join-Path $cfg "state\awaiting-$sid.flag") -Force -ErrorAction SilentlyContinue
exit 0
