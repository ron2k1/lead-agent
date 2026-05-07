---
name: Bug report
about: Report unexpected behavior in lead-agent
title: "bug: "
labels: ["bug", "triage"]
assignees: []
---

## Description

<!-- One-paragraph summary of the bug. -->

## Steps to reproduce

1.
2.
3.

## Expected behavior

<!-- What should have happened. -->

## Actual behavior

<!-- What actually happened. Include error messages and hook deny messages.
     Redact usernames or paths that include personal info. -->

## Verify output

Paste the output of:

    & "$env:USERPROFILE\.claude\skills\lead-agent\install.ps1" -Verify

```

(paste here)

```

## Hook log (if relevant)

Paste the relevant tail of:

    Get-Content "$env:USERPROFILE\.claude\hooks\lead-pretool-hook.log" -Tail 40

Redact paths.

```

(paste here)

```

## Environment

- OS: Windows 10 / 11 (specify build number)
- PowerShell version: (output of `$PSVersionTable.PSVersion`)
- Python version: (output of `python --version`)
- Windows Terminal version: (output of `wt.exe --version`)
- Claude Code version: (output of `claude --version`)

## Additional context

<!-- Forks, custom hooks, custom skills under ~/.claude/, anything relevant. -->
