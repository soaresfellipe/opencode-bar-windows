# PSScriptAnalyzer settings for OpenCode Bar.
#
# Every excluded rule carries a justification, per AGENTS.md ("every suppression
# carries a justification"). Rules NOT listed here are enforced as-is; CI fails the
# build on any Error-severity finding.

@{
    ExcludeRules = @(
        # Set-ApiKey takes the pasted key as plaintext solely to hand it to DPAPI:
        # `ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString`
        # immediately converts it to a DPAPI-protected blob (per-user encryption)
        # which is the only thing persisted to config.json. The key is never written
        # to disk in plaintext and never logged. There is no DPAPI path that avoids
        # the plaintext-to-SecureString step when the secret originates as user input.
        'PSAvoidUsingConvertToSecureStringWithPlainText'

        # The empty catches are deliberate best-effort swallows: Write-Log cannot
        # report its own failure, and a corrupt/locked state.json or log file must
        # not crash a headless tray app. Each site keeps the app running with safe
        # defaults (empty alert state, default config).
        'PSAvoidUsingEmptyCatchBlock'

        # Draw-Text / Draw-Popup are internal GDI+ rendering helpers; "Draw" is the
        # domain verb for rendering. Renaming them to approved verbs (e.g. Write-)
        # would actively mislead, so we keep the domain naming.
        'PSUseApprovedVerbs'

        # Test-Alerts intentionally evaluates every window of every notify pool, so
        # the plural noun is accurate.
        'PSUseSingularNouns'

        # Write-Log is this app's own log helper (writes to %APPDATA%\opencode-bar\).
        # It does not override any cmdlet that exists on the target runtime,
        # Windows PowerShell 5.1.
        'PSAvoidOverwritingBuiltInCmdlets'

        # These functions are internal tray-app state changers (Set-ApiKey,
        # Start-Refresh, Update-Ui, Set-Autostart, New-RoundPath, New-TrayBitmap,
        # Set-FetchResult). They are never exposed as cmdlets and are driven by GUI
        # events; adding SupportsShouldProcess would break their positional callers
        # and add -WhatIf plumbing that has no meaning inside a tray app.
        'PSUseShouldProcessForStateChangingFunctions'

        # WinForms event-handler scriptblocks must declare both delegate parameters
        # for positional argument binding even when one is unused (e.g. the popup
        # MouseClick uses only $e; the tray MouseClick uses only $e after binding).
        # Removing the unused parameter would shift the other argument onto it.
        'PSReviewUnusedParameter'

        # The internal drawing helpers (Draw-Text, Draw-Popup, New-TrayBitmap) are
        # called positionally on purpose to keep the single-file GUI script compact;
        # they are not public cmdlets and their signatures are stable.
        'PSAvoidUsingPositionalParameters'

        # The lib module's exported helpers are internal building blocks of a tray
        # app (documented inline where intent is non-obvious, per AGENTS.md);
        # full comment-based help blocks on each of them would be noise.
        'PSProvideCommentHelp'

        # The gate scripts in tools/ are CI jobs, not a library: their contract is
        # "print the diagnostic and exit non-zero", which is exactly Write-Host.
        # They run in a GitHub Actions step where the step log IS the report.
        'PSAvoidUsingWriteHost'
    )
}
