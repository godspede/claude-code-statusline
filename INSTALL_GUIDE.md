# Install guide (for Claude Code to execute)

**You are Claude Code, running on the user's Windows machine. Follow these steps
to install this statusline. Everything here is local and reversible — no network
services, no accounts, no external access is required.**

Work carefully: the only step that can disrupt the user is editing their
`~/.claude/settings.json`, so **back it up and merge — never overwrite it.**

---

## 0. Preconditions (check, don't assume)

Run these and confirm before proceeding:

```powershell
pwsh --version                 # PowerShell 7+ preferred; 5.1 works too
git --version                  # needed for the repo@branch cell
$env:USERPROFILE               # confirm the home dir; ~/.claude lives here
```

If `pwsh` is missing, either install PowerShell 7 (`winget install Microsoft.PowerShell`)
or, in the commands below, replace `pwsh` with `powershell` (Windows PowerShell 5.1).

This repo (the one containing this file) is the **source**. Note its path; the
steps below call it `$SRC`. Set it once:

```powershell
$SRC = (Get-Location).Path      # run this from the repo root
$DST = Join-Path $env:USERPROFILE ".claude"
```

## 1. Copy the files into ~/.claude

```powershell
New-Item -ItemType Directory -Force -Path (Join-Path $DST "hooks"), (Join-Path $DST "commands") | Out-Null
Copy-Item -Force (Join-Path $SRC "statusline.ps1")      (Join-Path $DST "statusline.ps1")
Copy-Item -Force (Join-Path $SRC "hooks\*.ps1")         (Join-Path $DST "hooks\")
Copy-Item -Force (Join-Path $SRC "commands\deets.md")   (Join-Path $DST "commands\deets.md")
```

## 2. Merge the settings — this is the delicate step

The user may already have a `~/.claude/settings.json` with their own keys and
hooks. **Do not clobber it.** Read the current file, merge in the `statusLine`
and `hooks` blocks from `settings.example.json`, and write it back.

First, **always back up**:

```powershell
$settingsPath = Join-Path $DST "settings.json"
if (Test-Path $settingsPath) { Copy-Item -Force $settingsPath "$settingsPath.bak" }
```

Then merge with the script below. It preserves every existing key, sets
`statusLine`, and **appends** our hook entries to any hook arrays already present
without disturbing the user's own hooks. It is **idempotent** — safe to re-run,
it won't add duplicates — and it picks the right PowerShell (`pwsh` if present,
else Windows PowerShell 5.1) and writes **absolute, quoted** script paths so it
works regardless of `~` expansion or spaces in the username.

```powershell
# Use PowerShell 7 if present, else Windows PowerShell 5.1.
$psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }

# Absolute, quoted launch command for a script under $DST.
function Launch([string]$rel) {
    $full = Join-Path $DST $rel
    return "$psExe -NoProfile -ExecutionPolicy Bypass -File `"$full`""
}

# The entries this installer adds, keyed by hook event.
$add = [ordered]@{
    Stop = @(
        [ordered]@{ hooks = @( [ordered]@{ type = 'command'; command = (Launch 'hooks\stop-classify-awaiting.ps1') } ) }
    )
    UserPromptSubmit = @(
        [ordered]@{ hooks = @(
            [ordered]@{ type = 'command'; command = (Launch 'hooks\user-prompt-clear-awaiting.ps1') },
            [ordered]@{ type = 'command'; command = (Launch 'hooks\user-prompt-toggle-clock.ps1') }
        ) }
    )
    UserPromptExpansion = @(
        [ordered]@{ matcher = 'deets'; hooks = @( [ordered]@{ type = 'command'; command = (Launch 'hooks\user-prompt-toggle-deets.ps1') } ) }
    )
}

# Load current settings as a mutable, ARRAY-PRESERVING hashtable tree. The `,`
# operators are load-bearing: without them PowerShell unwraps single-element
# arrays on return and the produced JSON would collapse `"hooks": [ {...} ]`
# into `"hooks": {...}`, which Claude Code cannot parse.
function To-Hash($o) {
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = To-Hash $p.Value }; return $h
    } elseif ($o -is [System.Collections.IEnumerable] -and $o -isnot [string]) {
        $a = @(); foreach ($i in $o) { $a += ,(To-Hash $i) }; return ,$a
    } else { return $o }
}
$curH = if (Test-Path $settingsPath) { To-Hash (Get-Content $settingsPath -Raw | ConvertFrom-Json) } else { [ordered]@{} }

# statusLine: set outright (the whole point of the install).
$curH['statusLine'] = [ordered]@{ type = 'command'; command = (Launch 'statusline.ps1') }

# hooks: append our entries idempotently — skip any whose command is already present.
if (-not $curH.Contains('hooks')) { $curH['hooks'] = [ordered]@{} }
$present = New-Object System.Collections.Generic.HashSet[string]
foreach ($evt in @($curH['hooks'].Keys)) {
    foreach ($entry in @($curH['hooks'][$evt])) {
        foreach ($hk in @($entry['hooks'])) { if ($hk -and $hk['command']) { [void]$present.Add([string]$hk['command']) } }
    }
}
foreach ($evt in $add.Keys) {
    if (-not $curH['hooks'].Contains($evt)) { $curH['hooks'][$evt] = @() }
    $new = @()
    foreach ($entry in $add[$evt]) {
        $cmds = @($entry['hooks'] | ForEach-Object { [string]$_['command'] })
        $allPresent = $true
        foreach ($c in $cmds) { if (-not $present.Contains($c)) { $allPresent = $false } }
        if (-not $allPresent) { $new += ,$entry }
    }
    $curH['hooks'][$evt] = @($curH['hooks'][$evt]) + $new
}

($curH | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $settingsPath -Encoding utf8
```

After writing, **re-read `settings.json` and confirm** each hook event is an
array of objects and each entry's inner `hooks` is itself an array (`[ { "type":
"command", ... } ]`) — not a bare object. If anything looks collapsed, restore
`settings.json.bak` and stop.

## 3. Verify (do not skip — show the user the evidence)

**a. The statusline renders.** Feed it a realistic sample and confirm you get a
coloured line back (not an error):

```powershell
'{"model":{"display_name":"Opus 4.8"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":40000,"cache_read_input_tokens":88000}},"rate_limits":{"five_hour":{"used_percentage":34,"resets_at":1893456000},"seven_day":{"used_percentage":12,"resets_at":1893456000}},"session_id":"test-123","cwd":"' + ($env:USERPROFILE -replace '\\','\\') + '","workspace":{}}' | pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $DST "statusline.ps1")
```

Expect one line beginning with a `●` bullet, the model name, an effort glyph, a
token count, and a `5h 34%` clock. (Colour codes will look like `←[38;...m`
escapes in a raw capture — that's correct; they render as colour in the real UI.)

**b. Each hook parses and exits cleanly.** A no-op input must exit 0 silently:

```powershell
foreach ($h in Get-ChildItem (Join-Path $DST "hooks\*.ps1")) {
    '{"session_id":"test-123","prompt":"hello"}' | pwsh -NoProfile -ExecutionPolicy Bypass -File $h.FullName
    Write-Host "$($h.Name): exit $LASTEXITCODE"
}
```

Expect `exit 0` for clear-awaiting and toggle-clock, `exit 0` for
stop-classify (no transcript) and toggle-deets (prompt isn't `/deets`).

**c. `/deets` toggles.** After restarting Claude Code, typing `/deets` should
print `deets mode ON`/`OFF` and switch the statusline between one and two lines.

## 4. Restart Claude Code

Settings and the statusline command are read at launch. Tell the user to start a
fresh `claude` session; the statusline appears at the bottom.

---

## What each piece does / how to uninstall

| File (in `~/.claude/`) | Role | Drop it if you don't want… |
|---|---|---|
| `statusline.ps1` | the statusline itself | (required) |
| `hooks/stop-classify-awaiting.ps1` | yellow **awaiting** badge when Claude asks a question | the awaiting state |
| `hooks/user-prompt-clear-awaiting.ps1` | clears awaiting when you reply | (pairs with the above) |
| `hooks/user-prompt-toggle-clock.ps1` | flips 5h↔7d each turn | alternating clocks (default stays 5h) |
| `hooks/user-prompt-toggle-deets.ps1` + `commands/deets.md` | the `/deets` two-line toggle | the `/deets` command |

To uninstall: restore `settings.json.bak`, and delete the files above. Nothing
else on the system is touched.

## Troubleshooting

- **Statusline shows just `Claude` or nothing.** The script got empty/invalid
  stdin, or `pwsh` isn't found. Confirm step 3a works and that the `command` path
  in settings resolves (`~` expands to the home dir; if in doubt use the full
  `C:\Users\<name>\.claude\statusline.ps1`).
- **Execution-policy error.** The `-ExecutionPolicy Bypass` flag in the commands
  already handles this; if you removed it, add it back.
- **`repo@branch` cell missing.** `git` isn't on `PATH`, or the session's `cwd`
  isn't a git repo. Everything else still renders.
- **Rate-limit clocks show `-`.** Claude Code didn't supply `rate_limits` on
  stdin and no cached usage exists yet; it fills in within a minute of use.
