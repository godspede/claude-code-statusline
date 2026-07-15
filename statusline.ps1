# Claude Code statusline (Windows / PowerShell). Based on
# https://github.com/daniel3303/ClaudeCodeStatusLine.
# One line by default; `/deets` flips a verbose two-line layout. Terminal-width
# elastic fit, 5h/7d rate-limit clock toggle, session-state badge. Native JSON
# parsing — no jq/bash dependency. Reads Claude Code's statusline JSON on stdin;
# companion hooks (see hooks/) drive the badge/toggle state via flag files under
# ~/.claude/state. No external services.
#
# Normal (one line):
#   ● <state> [@<recv>] <eff-glyph> <effort> | <repo>@<branch> [(+N -M)] | <toks>/<ctx> | <5h-or-7d> NN% @<reset>
# Deets (/deets on, two lines):
#   ● <state> [@<recv>] <eff-glyph> <effort> | <repo>@<branch> [(+N -M)]
#   <model> | <toks>/<ctx> | 5h NN% @<reset> | 7d NN% @<reset>

$VERSION = "1.4.3"

# Emit UTF-8 so the badge bullet (●) and ellipsis (…) render correctly when
# CC reads our stdout.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# Read input from stdin
$input = @($Input) -join "`n"

if (-not $input) {
    Write-Host -NoNewline "Claude"
    exit 0
}

# ANSI escape - use [char]0x1b for PowerShell 5 compatibility ("`e" is PS7+ only)
$esc = [char]0x1b

# ANSI colors matching oh-my-posh theme
$blue   = "${esc}[38;2;0;153;255m"
$orange = "${esc}[38;2;255;176;85m"
$green  = "${esc}[38;2;0;160;0m"
$cyan   = "${esc}[38;2;46;149;153m"
$red    = "${esc}[38;2;255;85;85m"
$yellow = "${esc}[38;2;230;200;0m"
$purple = "${esc}[38;2;167;139;250m"
$white  = "${esc}[38;2;220;220;220m"
$dim    = "${esc}[2m"
$reset  = "${esc}[0m"

# Format token counts (e.g., 50k / 200k)
function Format-Tokens([long]$num) {
    if ($num -ge 1000000) {
        $val = [math]::Round($num / 1000000, 1)
        if ([math]::Abs($val - [math]::Round($val)) -lt 0.05) { return "{0:F0}m" -f $val }
        return "{0:F1}m" -f $val
    }
    elseif ($num -ge 1000) { return "{0:F0}k" -f ($num / 1000) }
    else { return "$num" }
}

# Format number with commas (e.g., 134,938)
function Format-Commas([long]$num) {
    return $num.ToString("N0")
}

# Return color escape based on usage percentage
function Get-UsageColor([int]$pct) {
    if ($pct -ge 90) { return $red }
    elseif ($pct -ge 70) { return $orange }
    elseif ($pct -ge 50) { return $yellow }
    else { return $green }
}

# Null coalescing helper for PowerShell 5 compatibility (?? is PS7+ only)
function Coalesce($value, $default) {
    if ($null -ne $value) { return $value } else { return $default }
}

# Visible width of a string: strip the real ESC color sequences, then count
# UTF-16 chars. PowerShell counts '●' and '…' as 1 char each (true display
# width), so unlike statusline.sh there is no byte-count fudge to apply.
function Get-VisibleWidth([string]$s) {
    if (-not $s) { return 0 }
    return ($s -replace "$esc\[[0-9;]*m", "").Length
}

# Return $true if $a > $b using semantic versioning
function Test-VersionGreaterThan([string]$a, [string]$b) {
    try {
        $va = [version]($a -replace '^v', '')
        $vb = [version]($b -replace '^v', '')
        return $va -gt $vb
    } catch {
        return $false
    }
}

# ===== Extract data from JSON =====
$data = $input | ConvertFrom-Json

$modelName = if ($data.model.display_name) { $data.model.display_name } else { "Claude" }
$modelName = ($modelName -replace '\s*\((\d+\.?\d*[kKmM])\s+context\)', ' $1').Trim()  # "(1M context)" → "1M"

# Context window
$size = if ($data.context_window.context_window_size) { [long]$data.context_window.context_window_size } else { 200000 }
if ($size -eq 0) { $size = 200000 }

# Token usage
$inputTokens = if ($data.context_window.current_usage.input_tokens) { [long]$data.context_window.current_usage.input_tokens } else { 0 }
$cacheCreate = if ($data.context_window.current_usage.cache_creation_input_tokens) { [long]$data.context_window.current_usage.cache_creation_input_tokens } else { 0 }
$cacheRead   = if ($data.context_window.current_usage.cache_read_input_tokens) { [long]$data.context_window.current_usage.cache_read_input_tokens } else { 0 }
$current = $inputTokens + $cacheCreate + $cacheRead

$usedTokens  = Format-Tokens $current
$totalTokens = Format-Tokens $size

if ($size -gt 0) { $pctUsed = [math]::Floor($current * 100 / $size) } else { $pctUsed = 0 }
$pctRemain = 100 - $pctUsed

$usedComma   = Format-Commas $current
$remainComma = Format-Commas ($size - $current)

# Config directory (respects CLAUDE_CONFIG_DIR override)
$claudeConfigDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE ".claude" }
$stateDir = Join-Path $claudeConfigDir "state"

$effortLevel = $null
if ($data.effort.level) {
    $effortLevel = [string]$data.effort.level
} elseif ($env:CLAUDE_CODE_EFFORT_LEVEL) {
    $effortLevel = $env:CLAUDE_CODE_EFFORT_LEVEL
} else {
    $settingsPath = Join-Path $claudeConfigDir "settings.json"
    if (Test-Path $settingsPath) {
        try {
            $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
            if ($settings.effortLevel) { $effortLevel = $settings.effortLevel }
        } catch {}
    }
}
if (-not $effortLevel) { $effortLevel = "medium" }

# Effort fill-gauge glyph — mirrors Claude Code's own effort indicator,
# where a single glyph's fill encodes the level: low ○ / medium ◐ /
# high ● / xhigh ◉ / max ◈ (ultracode ✦). The CLI footer renders
# `<glyph> <level>`; we do the same. [char]0x.. literals keep the glyph
# correct regardless of this file's on-disk encoding. NOTE: .effort.level
# only ever reports the five base levels (ultracode resolves to xhigh
# upstream before it reaches the statusline JSON), so the ultracode arm
# is defensive for an explicit CLAUDE_CODE_EFFORT_LEVEL / settings value.
$effortGlyph = switch ($effortLevel) {
    "low"       { [char]0x25CB }  # ○
    "medium"    { [char]0x25D0 }  # ◐
    "high"      { [char]0x25CF }  # ●
    "xhigh"     { [char]0x25C9 }  # ◉
    "max"       { [char]0x25C8 }  # ◈
    "ultracode" { [char]0x2726 }  # ✦
    default     { [char]0x25D0 }  # ◐
}

# === /deets two-line mode ===
# Global sentinel — when present, render a verbose two-line layout. Toggled by
# hooks.d/user-prompt-toggle-deets.ps1 on `/deets`. Global (not per-session)
# so a flip survives new windows and applies across all open ones next render.
$deetsMode = Test-Path (Join-Path $stateDir "deets-mode.flag")
# === //deets two-line mode ===

# === terminal-width probe ===
# Mirror statusline.sh: derive the budget from real terminal width, reserving
# RC_RESERVED columns for CC's remote-control overlay. That overlay is now the
# short "/rc active" badge (CC's `/rc` is the alias for `/remote-control`);
# with the leading gap that's " /rc active" = 11 chars, down from the old
# " Remote Control active" = 22. On Windows $COLUMNS is reliably present only
# through the wt.exe→ssh→tmux stack; fall back to console width, then 80.
# Floor 20 / ceil 200 as in the sh probe.
#
# Below RC_GIVEUP_WIDTH the bypass-permissions footer ("⏵⏵ bypass permissions
# on (shift+tab to cycle) …") plus RC can't share one row, so RC wraps no
# matter how short the statusline is — the reservation only shrinks the line
# for nothing. Past that point, stop reserving and use the full width.
$RC_RESERVED = 11
$RC_GIVEUP_STR = ">> bypass permissions on (shift+tab to cycle) /rc active"
$RC_GIVEUP_WIDTH = $RC_GIVEUP_STR.Length  # 56
$termCols = 0
if ($env:COLUMNS -and [int]::TryParse($env:COLUMNS, [ref]$termCols)) { } else { $termCols = 0 }
if ($termCols -eq 0) {
    try { $termCols = [Console]::WindowWidth } catch { $termCols = 0 }
}
if ($termCols -le 0) { $termCols = 80 }
if ($termCols -lt $RC_GIVEUP_WIDTH) {
    # RC will wrap regardless — reclaim the full width for the statusline.
    $TARGET_WIDTH = $termCols
} else {
    $TARGET_WIDTH = $termCols - $RC_RESERVED
}
if ($TARGET_WIDTH -lt 20)  { $TARGET_WIDTH = 20 }
if ($TARGET_WIDTH -gt 200) { $TARGET_WIDTH = 200 }
# === /terminal-width probe ===

# ===== Build single-line output =====
$out = ""

# --- Session-state badge (leading slot; replaces the model name) ---
# States: working (busy) | awaiting (idle+sentinel) | stale (old sentinel) | ready (idle).
# The text portion is wrapped in strip-able sentinels so the elastic-fit pass
# can drop it as a budget-saving step; the bullet (●) always stays.
$badgeTextW = 0
$sidIn = $data.session_id
if ($sidIn) {
    $sessStatus = ""
    $sessionsDir = Join-Path $claudeConfigDir "sessions"
    if (Test-Path $sessionsDir) {
        $needle = '"sessionId":"' + $sidIn + '"'
        $sf = Get-ChildItem -Path $sessionsDir -Filter *.json -File -ErrorAction SilentlyContinue |
              Where-Object {
                  $c = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
                  $c -and ($c.Replace(" ", "") -like "*$needle*")
              } | Select-Object -First 1
        if ($sf) { try { $sessStatus = (Get-Content $sf.FullName -Raw | ConvertFrom-Json).status } catch {} }
    }

    if ($sessStatus -eq "busy") {
        $bColor = $blue; $bWord = "working"
    } else {
        $sentinel = Join-Path $stateDir "awaiting-$sidIn.flag"
        if (Test-Path $sentinel) {
            $sentTs = 0
            try { $sentTs = [long]((Get-Content $sentinel -Raw | ConvertFrom-Json).ts) } catch { $sentTs = 0 }
            $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $sentTs
            if ($age -gt 1800) { $bColor = $dim; $bWord = "stale" }
            else               { $bColor = $yellow; $bWord = "awaiting" }
        } else {
            $bColor = $green; $bWord = "ready"
        }
    }

    # The coarse since-last-prompt tag that used to sit here (Nm/Nh/Nd/Nw)
    # was removed: a relative duration is worthless once the line stops
    # refreshing (an idle session freezes it at a stale value). The absolute
    # "time the last message was received" now rides the line-1 badge as
    # `@HH:mm` (see the recv stamp below), where it stays meaningful without
    # a refresh.

    # recv stamp — absolute local time of the operator's most recent prompt
    # (last-prompt flag mtime), rendered in the badge as `@HH:mm` (or
    # `@<ddd> HH:mm` for an earlier day). Shown in both layouts (rides line 1).
    $recvDisp = ""
    $recvFlag = Join-Path $stateDir "last-prompt-$sidIn.flag"
    if (Test-Path $recvFlag) {
        $recvMtime = (Get-Item $recvFlag).LastWriteTime
        if ($recvMtime.Date -eq (Get-Date).Date) { $recvDisp = $recvMtime.ToString("HH:mm") }
        else { $recvDisp = $recvMtime.ToString("ddd HH:mm") }
    }

    # Badge label: the one-line (non-deets) layout shows the model name nowhere
    # else, so the badge text carries it instead of the state word — state stays
    # legible from the bullet's colour. In /deets mode the model name already
    # leads line 2, so line 1 keeps the state word.
    $bLabel = if ($deetsMode) { $bWord } else { $modelName }
    $out += "${bColor}●${reset}"
    $out += "___SL_BADGE_TXT_BEGIN___${bColor} ${bLabel}${reset}"
    $badgeTextW = 1 + $bLabel.Length
    # recv `@HH:mm` right after the label, inside the strip region.
    if ($recvDisp) {
        $out += " ${dim}@${recvDisp}${reset}"
        $badgeTextW += 2 + $recvDisp.Length
    }
    $out += "___SL_BADGE_TXT_END___"
}

# Effort fill-gauge chip — `<glyph> <level>`, grouped with the badge as the
# leading "session mode" cluster (state + effort). Always shown; sits outside
# the badge-text strip sentinels so it survives when the state word is dropped
# on narrow terminals (the bullet's colour still conveys state). Rendered in
# both normal and /deets mode — line 1 carries the badge in both. Purple is
# unused elsewhere, so it reads cleanly as "the effort colour". The glyph is a
# single BMP char, so the elastic-fit $plain.Length count needs no fudge.
$out += " ${purple}$effortGlyph ${effortLevel}${reset}"

# --- Repo cell (data only; rendering deferred to the elastic-fit pass) ---
$cwd = $data.cwd
$displayDir = ""
$gitBranch = $null
$gitStat = ""
if ($cwd) {
    $displayDir = Split-Path $cwd -Leaf
    try { $gitBranch = git -C $cwd rev-parse --abbrev-ref HEAD 2>$null } catch { $gitBranch = $null }

    $rbRepo = $data.workspace.repo.name
    if (-not $rbRepo) {
        $pd = $data.workspace.project_dir
        if ($pd) { $rbRepo = Split-Path $pd -Leaf }
    }
    if ($rbRepo) { $displayDir = $rbRepo }

    $rbWorktree = $data.workspace.git_worktree
    if ($rbWorktree) { $gitBranch = $rbWorktree }

    if ($gitBranch) {
        try {
            $numstat = git -C $cwd diff --numstat 2>$null
            if ($numstat) {
                $added = 0; $deleted = 0
                foreach ($line in $numstat) {
                    $parts = $line -split '\s+'
                    if ($parts[0] -match '^\d+$') { $added += [int]$parts[0] }
                    if ($parts[1] -match '^\d+$') { $deleted += [int]$parts[1] }
                }
                if (($added + $deleted) -gt 0) { $gitStat = "+$added -$deleted" }
            }
        } catch {}
    }
    # Whole cell wrapped so the fit pass can drop the ` | <repo>` cell entirely
    # on extreme-narrow terminals; REPO_FILL is substituted with the sized repo.
    $out += "___SL_REPO_CELL_BEGIN___ ${dim}|${reset} ___SL_REPO_FILL___"
    $out += "___SL_REPO_CELL_END___"
}

# Tokens — line 1 only in normal mode (deets moves them to line 2).
if (-not $deetsMode) {
    $out += " ${dim}|${reset} "
    $out += "${orange}${usedTokens}/${totalTokens}${reset}"
}

# ===== OAuth token resolution =====
function Get-OAuthToken {
    if ($env:CLAUDE_CODE_OAUTH_TOKEN) { return $env:CLAUDE_CODE_OAUTH_TOKEN }
    try {
        if (Get-Command "cmdkey.exe" -ErrorAction SilentlyContinue) {
            $credPath = Join-Path $env:LOCALAPPDATA "Claude Code\credentials.json"
            if (Test-Path $credPath) {
                $creds = Get-Content $credPath -Raw | ConvertFrom-Json
                $token = $creds.claudeAiOauth.accessToken
                if ($token -and $token -ne "null") { return $token }
            }
        }
    } catch {}
    $credsFile = Join-Path $claudeConfigDir ".credentials.json"
    if (Test-Path $credsFile) {
        try {
            $creds = Get-Content $credsFile -Raw | ConvertFrom-Json
            $token = $creds.claudeAiOauth.accessToken
            if ($token -and $token -ne "null") { return $token }
        } catch {}
    }
    return $null
}

# ===== Usage limits =====
# Prefer rate_limits from CC stdin (no OAuth/API needed); fall back to the API
# usage endpoint (only source of extra_usage) cached on disk.
$builtinFiveHourPct = $data.rate_limits.five_hour.used_percentage
$builtinFiveHourReset = $data.rate_limits.five_hour.resets_at
$builtinSevenDayPct = $data.rate_limits.seven_day.used_percentage
$builtinSevenDayReset = $data.rate_limits.seven_day.resets_at

$useBuiltin = ($null -ne $builtinFiveHourPct) -or ($null -ne $builtinSevenDayPct)

$effectiveBuiltin = $false
if ($useBuiltin) {
    if (($null -ne $builtinFiveHourPct -and [math]::Floor([double]$builtinFiveHourPct) -ne 0) -or
        ($null -ne $builtinSevenDayPct -and [math]::Floor([double]$builtinSevenDayPct) -ne 0)) {
        $effectiveBuiltin = $true
    }
    if (-not $effectiveBuiltin) {
        if (($null -ne $builtinFiveHourReset -and "$builtinFiveHourReset" -ne "null" -and "$builtinFiveHourReset" -ne "0") -or
            ($null -ne $builtinSevenDayReset -and "$builtinSevenDayReset" -ne "null" -and "$builtinSevenDayReset" -ne "0")) {
            $effectiveBuiltin = $true
        }
    }
}

# Cache — config-dir-hashed filename for parity with statusline.sh (shared across
# panes using the same CLAUDE_CONFIG_DIR, isolated from other configs).
$cfgHash = ""
try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($claudeConfigDir))
    $cfgHash = -join ($bytes | ForEach-Object { $_.ToString("x2") })
    $cfgHash = $cfgHash.Substring(0, 8)
} catch { $cfgHash = "default0" }
$cacheDir = Join-Path $env:TEMP "claude"
$cacheFile = Join-Path $cacheDir "statusline-usage-cache-$cfgHash.json"
$cacheMaxAge = 60

if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }

$needsRefresh = $true
$usageData = $null
if (Test-Path $cacheFile) {
    $cacheMtime = (Get-Item $cacheFile).LastWriteTime
    $cacheAge = ((Get-Date) - $cacheMtime).TotalSeconds
    if ($cacheAge -lt $cacheMaxAge) { $needsRefresh = $false }
    $usageData = Get-Content $cacheFile -Raw
}

if ($needsRefresh) {
    if (Test-Path $cacheFile) { (Get-Item $cacheFile).LastWriteTime = Get-Date }
    else { New-Item -ItemType File -Path $cacheFile -Force | Out-Null }
    $token = Get-OAuthToken
    if ($token) {
        try {
            $headers = @{
                "Accept"         = "application/json"
                "Content-Type"   = "application/json"
                "Authorization"  = "Bearer $token"
                "anthropic-beta" = "oauth-2025-04-20"
                "User-Agent"     = "claude-code/2.1.34"
            }
            $response = Invoke-RestMethod -Uri "https://api.anthropic.com/api/oauth/usage" `
                -Headers $headers -Method Get -TimeoutSec 10 -ErrorAction Stop
            $usageData = $response | ConvertTo-Json -Depth 10
            $usageData | Set-Content $cacheFile -Force
        } catch {}
    }
    if (-not $usageData -and (Test-Path $cacheFile)) { $usageData = Get-Content $cacheFile -Raw }
    if ((Test-Path $cacheFile) -and ((Get-Item $cacheFile).Length -eq 0)) {
        Remove-Item $cacheFile -Force -ErrorAction SilentlyContinue
    }
}

# Format ISO reset time to compact local time. 24-hour to match statusline.sh.
function Format-ResetTime($resetVal, [string]$style) {
    if ($null -eq $resetVal -or "$resetVal" -eq "null" -or "$resetVal" -eq "") { return $null }
    try {
        # resets_at may arrive as a raw ISO string OR — when it has already been
        # through ConvertFrom-Json (cache / API-fallback path) — as a [DateTime].
        # ConvertFrom-Json deserializes "…Z" to Kind=Utc; stringifying it drops the
        # Z, so we must convert from the DateTime directly, not re-Parse a string.
        if ($resetVal -is [datetime]) {
            switch ($resetVal.Kind) {
                ([System.DateTimeKind]::Utc)   { $dt = $resetVal.ToLocalTime() }
                ([System.DateTimeKind]::Local) { $dt = $resetVal }
                default { $dt = [datetime]::SpecifyKind($resetVal, [System.DateTimeKind]::Utc).ToLocalTime() }
            }
        } else {
            $dt = [DateTimeOffset]::Parse([string]$resetVal).LocalDateTime
        }
        switch ($style) {
            "time"     { return $dt.ToString("HH:mm") }
            "datetime" { return $dt.ToString("ddd HH:mm") }
            default    { return $dt.ToString("MMM d") }
        }
    } catch { return $null }
}

# Format Unix epoch reset time to compact local time. 24-hour to match the sh.
function Format-EpochResetTime([object]$epoch, [string]$style) {
    if ($null -eq $epoch -or "$epoch" -eq "null" -or "$epoch" -eq "") { return $null }
    try {
        $dt = [DateTimeOffset]::FromUnixTimeSeconds([long]$epoch).LocalDateTime
        switch ($style) {
            "time"     { return $dt.ToString("HH:mm") }
            "datetime" { return $dt.ToString("ddd HH:mm") }
            default    { return $dt.ToString("MMM d") }
        }
    } catch { return $null }
}

$sep = " ${dim}|${reset} "

# Render extra_usage segment from API usage data. Returns the segment (may be "").
function Format-ExtraUsage($usage) {
    if (-not $usage) { return "" }
    try {
        if ($usage.extra_usage.is_enabled -ne $true) { return "" }
        $pct = [math]::Floor([double](Coalesce $usage.extra_usage.utilization 0))
        $usedRaw = $usage.extra_usage.used_credits
        $limitRaw = $usage.extra_usage.monthly_limit
        if ($null -ne $usedRaw -and $null -ne $limitRaw) {
            $used = "{0:F2}" -f ([double]$usedRaw / 100)
            $limit = "{0:F2}" -f ([double]$limitRaw / 100)
            $color = Get-UsageColor $pct
            return "${sep}${white}extra${reset} ${color}`$${used}/`$${limit}${reset}"
        } else {
            return "${sep}${white}extra${reset} ${green}enabled${reset}"
        }
    } catch { return "" }
}

# Parse usage_data once (used for both clock data and extra_usage)
$parsedUsage = $null
if ($usageData) {
    try { $parsedUsage = if ($usageData -is [string]) { $usageData | ConvertFrom-Json } else { $usageData } } catch {}
}

# === clock toggle ===
# user-prompt-toggle-clock.ps1 flips a per-session sentinel: present = 7d, absent = 5h.
$clockChoice = "5h"
if ($sidIn -and (Test-Path (Join-Path $stateDir "clock-toggle-$sidIn.flag"))) { $clockChoice = "7d" }
# === /clock toggle ===

# Build both clock segments as DATA (full coloured strings, leading separator).
$segment5h = ""
$segment7d = ""
if ($effectiveBuiltin) {
    if ($null -ne $builtinFiveHourPct) {
        $p = [math]::Floor([double]$builtinFiveHourPct); $c = Get-UsageColor $p
        $segment5h = "${sep}${white}5h${reset} ${c}${p}%${reset}"
        $at = Format-EpochResetTime $builtinFiveHourReset "time"
        if ($at) { $segment5h += " ${dim}@${at}${reset}" }
    }
    if ($null -ne $builtinSevenDayPct) {
        $p = [math]::Floor([double]$builtinSevenDayPct); $c = Get-UsageColor $p
        $segment7d = "${sep}${white}7d${reset} ${c}${p}%${reset}"
        $at = Format-EpochResetTime $builtinSevenDayReset "datetime"
        if ($at) { $segment7d += " ${dim}@${at}${reset}" }
    }
} elseif ($parsedUsage -and $parsedUsage.five_hour) {
    $p = [math]::Floor([double](Coalesce $parsedUsage.five_hour.utilization 0)); $c = Get-UsageColor $p
    $segment5h = "${sep}${white}5h${reset} ${c}${p}%${reset}"
    $at = Format-ResetTime $parsedUsage.five_hour.resets_at "time"
    if ($at) { $segment5h += " ${dim}@${at}${reset}" }
    $p = [math]::Floor([double](Coalesce $parsedUsage.seven_day.utilization 0)); $c = Get-UsageColor $p
    $segment7d = "${sep}${white}7d${reset} ${c}${p}%${reset}"
    $at = Format-ResetTime $parsedUsage.seven_day.resets_at "datetime"
    if ($at) { $segment7d += " ${dim}@${at}${reset}" }
}
$ph5 = "${sep}${white}5h${reset} ${dim}-${reset}"
$ph7 = "${sep}${white}7d${reset} ${dim}-${reset}"

# Normal mode: fixed slot order (5h before 7d). Toggle picks the primary
# (always rendered, data-or-placeholder); the other becomes the second-clock
# marker, filled by the elastic-fit pass only if there's room (data-only).
$secondClock = ""
if (-not $deetsMode) {
    if ($clockChoice -eq "5h") {
        $out += if ($segment5h) { $segment5h } else { $ph5 }
        $out += "___SL_SECOND_CLOCK___"
        $secondClock = $segment7d
    } else {
        $out += "___SL_SECOND_CLOCK___"
        $out += if ($segment7d) { $segment7d } else { $ph7 }
        $secondClock = $segment5h
    }
    $out += Format-ExtraUsage $parsedUsage
}

# Cache builtin values for the API-fallback path (parity with statusline.sh).
if ($effectiveBuiltin) {
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $fhVal = if ($builtinFiveHourPct) { ([double]$builtinFiveHourPct).ToString($inv) } else { "0" }
    $sdVal = if ($builtinSevenDayPct) { ([double]$builtinSevenDayPct).ToString($inv) } else { "0" }
    $fhResetJson = "null"
    if ($null -ne $builtinFiveHourReset -and "$builtinFiveHourReset" -ne "null" -and "$builtinFiveHourReset" -ne "0") {
        try { $fhResetJson = '"' + [DateTimeOffset]::FromUnixTimeSeconds([long]$builtinFiveHourReset).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") + '"' } catch {}
    }
    $sdResetJson = "null"
    if ($null -ne $builtinSevenDayReset -and "$builtinSevenDayReset" -ne "null" -and "$builtinSevenDayReset" -ne "0") {
        try { $sdResetJson = '"' + [DateTimeOffset]::FromUnixTimeSeconds([long]$builtinSevenDayReset).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") + '"' } catch {}
    }
    $extraJson = "null"
    if ($parsedUsage -and $parsedUsage.extra_usage) {
        try { $extraJson = $parsedUsage.extra_usage | ConvertTo-Json -Depth 5 -Compress } catch {}
    }
    $fallbackJson = "{`"five_hour`":{`"utilization`":$fhVal,`"resets_at`":$fhResetJson},`"seven_day`":{`"utilization`":$sdVal,`"resets_at`":$sdResetJson},`"extra_usage`":$extraJson}"
    try { $fallbackJson | Set-Content $cacheFile -Force } catch {}
}

# ===== Update check disabled locally =====
$updateLine = ""

# === repo@branch elastic fit ===
# Substitute ___SL_REPO_FILL___ with a repo segment sized so the whole
# line lands within TARGET_WIDTH. Decision tree, highest preference first —
# the second clock outranks the (+N -M) change-stats indicator.
$stripBadge = $false
$stripCell = $false
if ($out -like "*___SL_REPO_FILL___*") {
    $plain = $out -replace "$esc\[[0-9;]*m", ""
    foreach ($m in @("___SL_REPO_FILL___", "___SL_SECOND_CLOCK___",
                     "___SL_BADGE_TXT_BEGIN___", "___SL_BADGE_TXT_END___",
                     "___SL_REPO_CELL_BEGIN___", "___SL_REPO_CELL_END___")) {
        $plain = $plain.Replace($m, "")
    }
    $othersW = $plain.Length
    $elasticAvail = $TARGET_WIDTH - $othersW

    $repoPlain = $displayDir
    if ($gitBranch) { $repoPlain = "$displayDir@$gitBranch" }
    $statsPlain = ""
    if ($gitStat) { $statsPlain = " ($gitStat)" }
    $repoW = $repoPlain.Length
    $statsW = $statsPlain.Length

    $secondW = 0
    if ($secondClock) { $secondW = Get-VisibleWidth $secondClock }

    # Helpers to assemble the coloured repo / stats fragments.
    $repoFill = {
        $f = "${cyan}${displayDir}${reset}"
        if ($gitBranch) { $f += "${dim}@${reset}${green}${gitBranch}${reset}" }
        return $f
    }
    $statsFill = {
        if (-not $gitStat) { return "" }
        $parts = $gitStat -split ' '
        return " ${dim}(${reset}${green}$($parts[0])${reset} ${red}$($parts[1])${reset}${dim})${reset}"
    }

    $fill = ""
    $scFill = ""
    if (($repoW + $statsW + $secondW) -le $elasticAvail) {
        $fill = (& $repoFill) + (& $statsFill)
        $scFill = $secondClock
    } elseif ((($repoW + $secondW) -le $elasticAvail) -and $secondClock) {
        $fill = (& $repoFill)
        $scFill = $secondClock
    } elseif (($repoW + $statsW) -le $elasticAvail) {
        $fill = (& $repoFill) + (& $statsFill)
    } elseif ($repoW -le $elasticAvail) {
        $fill = (& $repoFill)
    } elseif ($gitBranch -and (($displayDir.Length + 5) -le $elasticAvail)) {
        # Worktree-name shrink: require ≥3 branch chars (displayDir + @ + 3 + …
        # = displayDir + 5). Anything tighter renders an empty/1-char branch
        # stub (`myrepo@…`, `myrepo@f…`) — better to drop the cell entirely.
        $bAvail = $elasticAvail - $displayDir.Length - 2
        $b = $gitBranch.Substring(0, [math]::Min($bAvail, $gitBranch.Length))
        $fill = "${cyan}${displayDir}${reset}${dim}@${reset}${green}${b}${reset}${dim}…${reset}"
    } else {
        # Reclaim the badge-text budget and re-run the fit from there.
        $stripBadge = $true
        $avail2 = $elasticAvail + $badgeTextW
        if ($repoW -le $avail2) {
            $fill = (& $repoFill)
        } elseif ($gitBranch -and (($displayDir.Length + 5) -le $avail2)) {
            # Same min-3-branch-chars guard as above.
            $bAvail = $avail2 - $displayDir.Length - 2
            $b = $gitBranch.Substring(0, [math]::Min($bAvail, $gitBranch.Length))
            $fill = "${cyan}${displayDir}${reset}${dim}@${reset}${green}${b}${reset}${dim}…${reset}"
        } else {
            # Shrinking + field-removal can't fit a meaningful cell — drop
            # the whole ` | <repo>` cell. The freed width keeps the line
            # from wrapping under the RC overlay (and the bypass-permissions
            # banner CC paints alongside it).
            $stripCell = $true
            $fill = ""
        }
    }

    $out = $out.Replace("___SL_REPO_FILL___", $fill)
    $out = $out.Replace("___SL_SECOND_CLOCK___", $scFill)
}

# Resolve the repo-cell sentinels (drop the whole ` | <repo>` span if flagged).
if ($stripCell) {
    $out = $out -replace "___SL_REPO_CELL_BEGIN___.*?___SL_REPO_CELL_END___", ""
} else {
    $out = $out.Replace("___SL_REPO_CELL_BEGIN___", "").Replace("___SL_REPO_CELL_END___", "")
}

# Resolve the badge-text sentinels (excise the wrapped text if flagged, leaving ●).
if ($stripBadge) {
    $out = $out -replace "___SL_BADGE_TXT_BEGIN___.*?___SL_BADGE_TXT_END___", ""
} else {
    $out = $out.Replace("___SL_BADGE_TXT_BEGIN___", "").Replace("___SL_BADGE_TXT_END___", "")
}
# === /repo@branch elastic fit ===

# === /deets line 2 ===
# Verbose second line: model | tokens | 5h NN% [@reset] | 7d NN% [@reset].
# Each optional segment is projected against TARGET_WIDTH before being added so
# the line never overflows. Priority: model+tokens always; then 5h%, 5h@reset,
# 7d%, 7d@reset (trailing @reset stamps are the cheapest cuts).
if ($deetsMode) {
    $script:line2 = "${blue}${modelName}${reset}"
    $script:line2 += "${sep}${orange}${usedTokens}/${totalTokens}${reset}"

    function Test-AddLine2([string]$candidate) {
        $cand = $script:line2 + $candidate
        if ((Get-VisibleWidth $cand) -le $TARGET_WIDTH) { $script:line2 = $cand; return $true }
        return $false
    }

    # (recv moved to the line-1 badge as `@HH:mm` — see the badge render above.)

    # --- 5h ---
    $dFhPct = $null; $dFhAt = $null
    if ($effectiveBuiltin -and $null -ne $builtinFiveHourPct) {
        $dFhPct = [math]::Floor([double]$builtinFiveHourPct)
        if ($builtinFiveHourReset -and "$builtinFiveHourReset" -ne "null") { $dFhAt = Format-EpochResetTime $builtinFiveHourReset "time" }
    } elseif ($parsedUsage -and $parsedUsage.five_hour) {
        $dFhPct = [math]::Floor([double](Coalesce $parsedUsage.five_hour.utilization 0))
        $dFhAt = Format-ResetTime $parsedUsage.five_hour.resets_at "time"
    }
    if ($null -ne $dFhPct) {
        $c = Get-UsageColor $dFhPct
        if ((Test-AddLine2 "${sep}${white}5h${reset} ${c}${dFhPct}%${reset}") -and $dFhAt) {
            [void](Test-AddLine2 " ${dim}@${dFhAt}${reset}")
        }
    } else {
        [void](Test-AddLine2 "${sep}${white}5h${reset} ${dim}-${reset}")
    }

    # --- 7d ---
    $dSdPct = $null; $dSdAt = $null
    if ($effectiveBuiltin -and $null -ne $builtinSevenDayPct) {
        $dSdPct = [math]::Floor([double]$builtinSevenDayPct)
        if ($builtinSevenDayReset -and "$builtinSevenDayReset" -ne "null") { $dSdAt = Format-EpochResetTime $builtinSevenDayReset "datetime" }
    } elseif ($parsedUsage -and $parsedUsage.seven_day) {
        $dSdPct = [math]::Floor([double](Coalesce $parsedUsage.seven_day.utilization 0))
        $dSdAt = Format-ResetTime $parsedUsage.seven_day.resets_at "datetime"
    }
    if ($null -ne $dSdPct) {
        $c = Get-UsageColor $dSdPct
        if ((Test-AddLine2 "${sep}${white}7d${reset} ${c}${dSdPct}%${reset}") -and $dSdAt) {
            [void](Test-AddLine2 " ${dim}@${dSdAt}${reset}")
        }
    } else {
        [void](Test-AddLine2 "${sep}${white}7d${reset} ${dim}-${reset}")
    }

    $out += "`n$script:line2"
}
# === //deets line 2 ===

# Output
Write-Host -NoNewline "$out$updateLine"

exit 0
