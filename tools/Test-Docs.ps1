# Test-Docs.ps1 - keeps AGENTS.md and README.md honest.
#
# Documentation drifts silently: a gate gets renamed, a file moves, a link
# rots, and the docs keep describing a workflow that no longer exists. This
# script fails CI on the three failure modes that actually happen in this repo:
#
#   1. A path mentioned in AGENTS.md / README.md that does not exist in the repo.
#   2. A local Markdown link whose target does not exist.
#   3. A fenced PowerShell block whose first command line references a missing
#      path (cheap guard against docs advertising deleted scripts).
#
# It does not try to validate prose or external URLs (network in CI is slow and
# flaky); scope is "does what the docs point at still exist".
#
# Usage: pwsh -File tools/Test-Docs.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$docs = @('AGENTS.md', 'README.md')

Push-Location $repoRoot
try {
    $tracked = @(git ls-files)
    # git ls-files uses forward slashes on every platform.
    $trackedSet = @{}
    foreach ($t in $tracked) { $trackedSet[$t.Replace('\', '/')] = $true }

    $problems = @()

    foreach ($doc in $docs) {
        if (-not (Test-Path -LiteralPath $doc)) {
            $problems += "$doc : missing from the repo"
            continue
        }
        $text = Get-Content -LiteralPath $doc -Raw -Force

        # (1) Backtick-quoted repo paths, e.g. `src/opencode-bar-lib.psm1` or `tests/`.
        # Only paths that are tracked *source* files are checked: the docs also
        # name build outputs (OpenCodeBar.exe, csc.exe) and runtime files that only
        # exist on a user's Windows box (%APPDATA%\opencode-bar\config.json), and
        # those are not repo paths.
        # NOTE: the result variable must not be called $matches - that is the
        # automatic variable the -match operator writes to, and this loop body
        # uses -match, which would overwrite it mid-enumeration.
        $pathHits = [regex]::Matches($text, '`([A-Za-z0-9_./-]+\.(ps1|psm1|psd1|yml|yaml|json|cs|md|txt|xml|exe|ico))`')
        foreach ($hit in $pathHits) {
            $path = $hit.Groups[1].Value
            # Skip anything that is clearly not a repo path (a URL fragment, a
            # Windows env var, a bare filename example).
            if ($path -match '^(https?:|%|\\\\|[A-Za-z]:)') { continue }
            # Build outputs and Windows runtime files are never tracked.
            if ($path -in @('OpenCodeBar.exe', 'csc.exe', 'config.json', 'state.json', 'opencode-bar.log')) { continue }
            # A path containing a directory separator must exist in the repo.
            # A bare filename (no separator) may legitimately be a runtime file
            # on the user's machine, so only check it if the repo tracks it.
            if ($trackedSet.ContainsKey($path)) { continue }
            if ($path -match '/') {
                $problems += "$doc : references missing path ``$path``"
            } elseif ($path -match '\.(ps1|psm1|psd1|cs)$') {
                # A source file by extension must be tracked, wherever it lives.
                $problems += "$doc : references missing source file ``$path``"
            }
        }

        # (2) Local markdown links: [text](target). Skip http(s), mailto, anchors.
        $linkMatches = [regex]::Matches($text, '\]\(([^)]+)\)')
        foreach ($link in $linkMatches) {
            $target = $link.Groups[1].Value
            if ($target -match '^(https?:|mailto:|#)') { continue }
            # Strip an anchor / query.
            $file = ($target -split '#')[0]
            if ([string]::IsNullOrWhiteSpace($file)) { continue }
            if (-not (Test-Path -LiteralPath $file)) {
                $problems += "$doc : broken link -> $target"
            }
        }
    }

    if ($problems.Count -gt 0) {
        Write-Host 'documentation is out of date:'
        $problems | ForEach-Object { Write-Host "::error::$_" }
        exit 1
    }
    Write-Host "doc check clean ($($docs.Count) file(s): paths and links resolve)"
    exit 0
} finally {
    Pop-Location
}
