## Summary

<!-- What does this PR change and why? -->

## Changes

-

## Validation

- [ ] Pester suite passes (`Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester -Path tests -Output Detailed -CI`)
- [ ] PSScriptAnalyzer clean (zero Error-severity findings with repo settings)
- [ ] AST parse clean on all `.ps1` / `.psm1` files
- [ ] PowerShell 5.1-compatible (no PS 7-only syntax)
- [ ] If rendering changed: `-Preview` PNG inspected
- [ ] No new network hosts; API key never logged or committed

CI runs all of the above on `windows-latest`; local checks are a fast pre-pass.
