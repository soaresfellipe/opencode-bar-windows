# Installs the repo's git hooks into this clone.
#
#   pwsh -File tools/Install-Hooks.ps1
#
# Sets core.hooksPath to .githooks, which git then picks up automatically for
# every future commit in this clone. Safe to re-run (idempotent). Hooks cannot
# be committed into .git/hooks, so this is how the pre-commit gate reaches a
# contributor's machine.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    $hook = Join-Path $repoRoot '.githooks/pre-commit'
    if (-not (Test-Path $hook)) {
        throw '.githooks/pre-commit is missing; cannot install hooks'
    }

    # git refuses to run a hook whose file mode is not executable, and it only
    # *warns* - the commit then lands ungated, silently. Normalize the working-tree
    # permission and record 100755 in the index, so a fresh clone gets a hook git
    # will actually run (the index mode is what matters where core.fileMode is
    # false, e.g. on Windows).
    if (Get-Command chmod -ErrorAction SilentlyContinue) {
        & chmod +x $hook
    }
    git update-index --chmod=+x .githooks/pre-commit
    if ($LASTEXITCODE -ne 0) { throw 'could not mark .githooks/pre-commit executable' }

    git config core.hooksPath .githooks
    if ($LASTEXITCODE -ne 0) { throw 'git config core.hooksPath failed' }
    Write-Host 'installed: core.hooksPath = .githooks (and the hook is executable)'
    Write-Host 'the pre-commit gate now runs parse, lint, largefiles, secrets and docs before each commit'
} finally {
    Pop-Location
}
