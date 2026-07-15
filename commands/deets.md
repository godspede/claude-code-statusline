---
description: Toggle the verbose two-line statusline (model + tokens + recv time + both rate-limit clocks). UI state only — no model turn fires.
disable-model-invocation: true
---

<!--
Pure side-effect command — intentionally EMPTY body so expansion yields no
prompt and no model turn. The actual work is done by the
`user-prompt-toggle-deets` hook bound to the **UserPromptExpansion** event
(matcher = `deets`): it flips the global sentinel at
`~/.claude/state/deets-mode.flag` and exits 0 (a non-zero exit would make Claude
Code show an "operation blocked by hook" error). `disable-model-invocation: true`
— together with the empty body — is what keeps the empty expansion from firing a
model turn; this file existing as a registered
command is what makes Claude Code fire UserPromptExpansion for `/deets` (and
keeps autocomplete from substituting a different command). Do not add body text
— any prose here would become the expanded prompt. Source + rationale:
`hooks/user-prompt-toggle-deets.ps1`.
-->
