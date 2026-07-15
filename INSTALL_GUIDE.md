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

Then merge programmatically (this preserves every existing key, sets
`statusLine`, and **appends** these hooks to any hook arrays already present
rather than replacing them):

```powershell
$example = Get-Content (Join-Path $SRC "settings.example.json") -Raw | ConvertFrom-Json
if (Test-Path $settingsPath) {
    $cur = Get-Content $settingsPath -Raw | ConvertFrom-Json
} else {
    $cur = [pscustomobject]@{}
}

# Convert to a mutable hashtable tree so we can merge cleanly.
function To-Hash($o) {
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = To-Hash $p.Value }; return $h
    } elseif ($o -is [System.Collections.IEnumerable] -and $o -isnot [string]) {
        return @($o | ForEach-Object { To-Hash $_ })
    } else { return $o }
}
$curH = To-Hash $cur
$exH  = To-Hash $example

# statusLine: set/replace outright (this is the whole point of the install).
$curH['statusLine'] = $exH['statusLine']

# hooks: append our entries to existing event arrays, don't overwrite.
if (-not $curH.ContainsKey('hooks')) { $curH['hooks'] = @{} }
foreach ($evt in $exH['hooks'].Keys) {
    if (-not $curH['hooks'].ContainsKey($evt)) { $curH['hooks'][$evt] = @() }
    $curH['hooks'][$evt] = @($curH['hooks'][$evt]) + @($exH['hooks'][$evt])
}

($curH | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $settingsPath -Encoding utf8
```

If the user had **no** prior settings.json, you may instead just copy
`settings.example.json` to `~/.claude/settings.json`. Only do that when the file
did not already exist.

> If you re-run this guide later, the append step would add the hooks a second
> time. Before merging, check whether an entry whose command contains
> `statusline.ps1`/the hook filenames is already present, and skip it if so.

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
