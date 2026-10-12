# RepoChecks.ps1 - the quality gates behind CI *and* the pre-commit hook.
#
# One implementation, two callers: .github/workflows/ci.yml runs each -Check in
# its own step (so CI reports which gate failed), and .githooks/pre-commit runs
# the fast ones locally before a commit is created. Keeping them here is what
# makes the local gate and the CI gate the same gate (AGENTS.md "Contribution
# workflow").
#
# Usage: pwsh -File tools/RepoChecks.ps1 -Check <name> [-Threshold <pct>]
#   PowerShell 5.1-compatible syntax only (the script also runs under pwsh 7).

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('parse', 'lint', 'format', 'tests', 'coverage', 'largefiles', 'secrets', 'all')]
    [string]$Check,

    # Minimum acceptable coverage percentage; only used by -Check coverage.
    [int]$Threshold = 85
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The app scripts plus the repo's own tooling scripts. Kept in one place so a
# new file cannot silently escape every gate.
$ScriptRoot  = Split-Path -Parent $PSScriptRoot
$CodeFiles   = @('opencode-bar.ps1', 'src/opencode-bar-lib.psm1', 'build.ps1')
$ToolFiles   = @('tools/RepoChecks.ps1')
$DocsFiles   = @('README.md', 'AGENTS.md')

function Get-AnalyzedFiles {
    # Everything Invoke-ScriptAnalyzer and the AST gate must cover. Resolved
    # against the repo root so the script works from any working directory.
    $all = @()
    foreach ($f in ($CodeFiles + $ToolFiles)) {
        $p = Join-Path $ScriptRoot $f
        if (Test-Path $p) { $all += $p }
    }
    return $all
}

function Invoke-ParseCheck {
    $failed = $false
    foreach ($p in (Get-AnalyzedFiles)) {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$errs) | Out-Null
        if ($errs.Count -gt 0) {
            $failed = $true
            Write-Host "$p : $($errs.Count) parse error(s)"
            foreach ($e in $errs) { Write-Host "  line $($e.Extent.StartLineNumber): $($e.Message)" }
        } else {
            Write-Host "$p : parse clean"
        }
    }
    if ($failed) { return 1 }
    return 0
}

function Invoke-LintCheck {
    # PSSA auto-discovers a settings file next to the analyzed file, so the
    # settings path is passed explicitly rather than relying on discovery.
    # The repo's own tools/ scripts are analyzed too - a gate that is not
    # itself linted is a gate that can rot.
    $settings = Join-Path $ScriptRoot 'PSScriptAnalyzerSettings.psd1'
    $findings = @()
    foreach ($p in (Get-AnalyzedFiles)) {
        # -Path takes a single string; pass one file per call (see AGENTS.md).
        $findings += Invoke-ScriptAnalyzer -Path $p -Settings $settings
    }
    $findings | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    $errors = @($findings | Where-Object { $_.Severity -eq 'Error' })
    if ($errors.Count -gt 0) {
        Write-Host "::error::$($errors.Count) Error-severity finding(s)"
        return 1
    }
    Write-Host "lint clean ($($findings.Count) non-error finding(s))"
    return 0
}

function Invoke-FormatCheck {
    # Invoke-Formatter is idempotent here: re-running it on already-formatted
    # source returns the source unchanged, so "does formatting change the file?"
    # is the check. Runs under pwsh 7 (PSSA's own engine), which is where the
    # formatter lives, so this gate is CI-only and is skipped by the pre-commit
    # hook when pwsh 7 is not installed.
    $settings = Join-Path $ScriptRoot 'PSScriptAnalyzerSettings.psd1'
    $failed = $false
    foreach ($p in (Get-AnalyzedFiles)) {
        $orig = (Get-Content -Raw $p) -replace "`r`n", "`n"
        $fmt = (Invoke-Formatter -ScriptDefinition (Get-Content -Raw $p) -Settings $settings) -replace "`r`n", "`n"
        if ($fmt.TrimEnd() -ne $orig.TrimEnd()) {
            Write-Host "::error::$p is not Invoke-Formatter clean"
            $failed = $true
        } else {
            Write-Host "$p : formatter clean"
        }
    }
    if ($failed) { return 1 }
    return 0
}

function Invoke-TestsCheck {
    # PassThru + an explicit exit rather than Pester's -CI switch: -CI makes
    # Pester exit the process itself, which would skip the remaining checks in
    # an -Check all run and leave $result null here.
    Import-Module Pester -RequiredVersion 5.7.1
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = Join-Path $ScriptRoot 'tests'
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'Detailed'
    $result = Invoke-Pester -Configuration $cfg
    Write-Host ("tests: {0} passed, {1} failed" -f $result.PassedCount, $result.FailedCount)
    if ($result.FailedCount -gt 0) { return 1 }
    return 0
}

function Invoke-CoverageCheck([int]$Min) {
    # Coverage is measured on the GUI-free lib module only: it is the surface
    # Pester can execute on any host, and the module header states it must never
    # load WinForms. Measuring opencode-bar.ps1 would report near-zero for code
    # that is only reachable on Windows.
    Import-Module Pester -RequiredVersion 5.7.1
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = Join-Path $ScriptRoot 'tests'
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'Detailed'
    $cfg.CodeCoverage.Enabled = $true
    $cfg.CodeCoverage.Path = Join-Path $ScriptRoot 'src/opencode-bar-lib.psm1'
    $result = Invoke-Pester -Configuration $cfg
    $pct = $result.CodeCoverage.CoveragePercent
    Write-Host ("lib module coverage: {0}% ({1}/{2} commands)" -f [math]::Round($pct, 2), $result.CodeCoverage.CommandsExecutedCount, $result.CodeCoverage.CommandsAnalyzedCount)
    if ($result.FailedCount -gt 0) { return 1 }
    if ($pct -lt $Min) {
        Write-Host "::error::coverage $pct% is below the $Min% floor"
        return 1
    }
    return 0
}

function Invoke-LargeFileCheck {
    # Repo-scale guard: 1 MiB for any tracked file, 1500 lines for code and
    # docs. Chosen to sit above the largest legitimate asset (docs/screenshot.png
    # at ~150 KB) so it only fires on accidental commits of build output,
    # archives or dumps.
    $maxBytes = 1MB
    $maxLines = 1500
    $failed = $false
    Push-Location $ScriptRoot
    try {
        $tracked = @(git ls-files)
        if ($LASTEXITCODE -ne 0) { Write-Host '::error::git ls-files failed'; return 1 }
        foreach ($f in $tracked) {
            if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
            # -Force: PowerShell on Unix reports dot-prefixed files (.editorconfig,
            # .gitignore) as hidden, and Get-Item skips hidden items without it.
            $size = (Get-Item -LiteralPath $f -Force).Length
            if ($size -gt $maxBytes) {
                Write-Host "::error::$f is $([math]::Round($size / 1KB)) KB, over the $([math]::Round($maxBytes / 1KB)) KB limit"
                $failed = $true
            }
            if ($CodeFiles -contains $f -or $ToolFiles -contains $f -or $DocsFiles -contains $f) {
                $lines = @(Get-Content -LiteralPath $f -Force).Count
                if ($lines -gt $maxLines) {
                    Write-Host "::error::$f is $lines lines, over the $maxLines line limit"
                    $failed = $true
                }
            }
        }
    } finally {
        Pop-Location
    }
    if ($failed) { return 1 }
    Write-Host "large-file check clean (max 1 MB / $maxLines lines)"
    return 0
}

function Invoke-SecretsCheck {
    # Key-shaped pattern, never the bare prefix: OpenCode keys are issued with
    # an `sk-` style prefix, so the pattern requires 16+ key characters after
    # it (docs say "sk-...", which the dots stop from matching). A key-shaped
    # match in the worktree *or* in history is a hard failure - that is a
    # leaked credential, not a style nit.
    $pattern = 'sk-[A-Za-z0-9_-]{16,}'
    $failed = $false
    Push-Location $ScriptRoot
    try {
        $hits = @(git grep -nE $pattern -- . 2>$null)
        if ($hits.Count -gt 0) {
            Write-Host '::error::key-shaped material found in tracked files:'
            $hits | ForEach-Object { Write-Host "  $_" }
            $failed = $true
        }
        # Exclude .git so an untracked scratch file cannot mask the history scan.
        $histHits = @(git log -p --all 2>$null | Select-String -Pattern $pattern)
        if ($histHits.Count -gt 0) {
            Write-Host "::error::key-shaped material found in git history ($($histHits.Count) line(s))"
            $failed = $true
        }
    } finally {
        Pop-Location
    }
    if ($failed) { return 1 }
    Write-Host 'secret scan clean (no key-shaped material in worktree or history)'
    return 0
}

$order = @('parse', 'lint', 'format', 'largefiles', 'secrets', 'tests', 'coverage')
$run = if ($Check -eq 'all') { $order } else { @($Check) }

# A single named check runs inline: that is the mode CI and the pre-commit hook
# use, and it keeps one gate == one process. `-Check all` orchestrates by
# spawning one child process per gate, because PSScriptAnalyzer and Pester 5.7.1
# both call Add-Type internally and loading both into a single process throws
# "Assembly with same name is already loaded". Process isolation also stops one
# gate leaving module state behind for the next, and makes each gate's exit code
# that gate's own exit code.
if ($Check -ne 'all') {
    $exit = 0
    switch ($Check) {
        'parse'      { $exit = Invoke-ParseCheck }
        'lint'       { $exit = Invoke-LintCheck }
        'format'     { $exit = Invoke-FormatCheck }
        'largefiles' { $exit = Invoke-LargeFileCheck }
        'secrets'    { $exit = Invoke-SecretsCheck }
        'tests'      { $exit = Invoke-TestsCheck }
        'coverage'   { $exit = Invoke-CoverageCheck -Min $Threshold }
    }
    if ($exit -ne 0) { Write-Host "::error::check '$Check' failed"; exit $exit }
    Write-Host 'all requested checks passed'
    exit 0
}

# Orchestrator mode: spawn this same script once per gate.
$child = (Get-Process -Id $PID).Path
if ([string]::IsNullOrWhiteSpace($child)) {
    # Fallback if the process path is unreadable: the host's own executable.
    $child = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
}

foreach ($c in $run) {
    Write-Host "--- repo-check: $c ---"
    $argv = @('-NoProfile', '-File', $PSCommandPath, '-Check', $c)
    if ($c -eq 'coverage') { $argv += @('-Threshold', [string]$Threshold) }
    $p = Start-Process -FilePath $child -ArgumentList $argv -NoNewWindow -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Write-Host "::error::check '$c' failed (exit $($p.ExitCode))"
        exit $p.ExitCode
    }
}
Write-Host 'all requested checks passed'
exit 0
