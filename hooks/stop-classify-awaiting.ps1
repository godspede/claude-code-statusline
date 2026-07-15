# Stop hook: classify the just-completed assistant message and write/remove the
# "awaiting operator input" sentinel for this session. Read by statusline.ps1,
# which turns the badge yellow ("awaiting") when the flag is present.
#
# Pure text heuristics — no LLM, no network. Reads Claude Code's Stop-hook JSON
# on stdin (session_id + transcript_path) and only ever touches a flag file
# under ~/.claude/state. Native JSON parsing; no jq dependency.

$ErrorActionPreference = 'Stop'
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $d = $raw | ConvertFrom-Json } catch { exit 0 }

$sid = [string]$d.session_id
$transcript = [string]$d.transcript_path
if (-not $sid -or -not $transcript -or -not (Test-Path -LiteralPath $transcript)) { exit 0 }

$cfg = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE ".claude" }
$stateDir = Join-Path $cfg "state"
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
$sentinel = Join-Path $stateDir "awaiting-$sid.flag"

# Last non-empty assistant text message from the JSONL transcript.
$lastText = ""
foreach ($line in (Get-Content -LiteralPath $transcript)) {
    if (-not $line -or -not $line.Trim()) { continue }
    try { $o = $line | ConvertFrom-Json } catch { continue }
    if ($o.type -ne 'assistant') { continue }
    $content = $o.message.content
    if (-not $content) { continue }
    $texts = @($content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text })
    $joined = ($texts -join "`n")
    if ($joined.Trim().Length -gt 0) { $lastText = $joined }
}
if (-not $lastText) { Remove-Item -LiteralPath $sentinel -Force -ErrorAction SilentlyContinue; exit 0 }

# Strip fenced code blocks so a "# what is this?" inside code doesn't trip it.
$inFence = $false
$kept = foreach ($l in ($lastText -split "`r?`n")) {
    if ($l -match '^```') { $inFence = -not $inFence; continue }
    if (-not $inFence) { $l }
}
$stripped = ($kept -join "`n")

# Last non-empty paragraph only (blocks separated by one or more blank lines) —
# rhetorical questions earlier in the message don't count.
$blocks = $stripped -split "(?:\r?\n[ \t]*){2,}"
$lastPara = ($blocks | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -Last 1)
if (-not $lastPara) { $lastPara = "" }

$reIC = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
$reML = [System.Text.RegularExpressions.RegexOptions]::Multiline

# Enumerated option list: 2+ option lines with a NON-list closing line. The
# trailing non-list line separates an operator decision list (options then a
# recommendation/summary) from a plain done-work bullet list, which ends on its
# final item and must NOT light the badge.
$optRe = '^\s*([0-9]+[.)]|[-*]|[A-D][.)])\s'
$optCount = 0; $lastWasOpt = $false
foreach ($l in ($lastPara -split "`r?`n")) {
    if ([System.Text.RegularExpressions.Regex]::IsMatch($l, $optRe)) { $optCount++; $lastWasOpt = $true }
    else { $lastWasOpt = $false }
}
$optionList = ($optCount -ge 2 -and -not $lastWasOpt)

$awaiting = $false; $reason = ""
if ([System.Text.RegularExpressions.Regex]::IsMatch($lastPara, '\?[ \t]*$', $reML)) {
    $awaiting = $true; $reason = "trailing-question"
} elseif ([System.Text.RegularExpressions.Regex]::IsMatch($lastPara, '(want me to|should i|which (would|do) you|let me know|your call|shall i|y/n|\(yes/no\))', $reIC)) {
    $awaiting = $true; $reason = "surfacing-phrase"
} elseif ([System.Text.RegularExpressions.Regex]::IsMatch($lastPara, "(my take:|my rec:|recommendation:|i'?d recommend|pick one|up to you|option [A-D]\b|do you want me to|let me know which|which (one )?(would|do) you (prefer|want)|\(a\)/\(b\))", $reIC)) {
    $awaiting = $true; $reason = "recommendation"
} elseif ($optionList) {
    $awaiting = $true; $reason = "option-list"
}

if ($awaiting) {
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $obj = [ordered]@{ session_id = $sid; reason = $reason; ts = $ts }
    ($obj | ConvertTo-Json -Compress) | Set-Content -LiteralPath $sentinel -Force -Encoding utf8
} else {
    Remove-Item -LiteralPath $sentinel -Force -ErrorAction SilentlyContinue
}
exit 0
