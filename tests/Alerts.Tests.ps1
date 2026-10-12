# Pester 5 suite for Test-Alerts (pure threshold computation) in src/opencode-bar-lib.psm1.
# Test-Alerts returns the notification messages as data; the GUI layer (opencode-bar.ps1
# Show-Alerts) turns them into the tray balloon.
# Run (pinned, see AGENTS.md):
#   Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester -Path tests -Output Detailed -CI
Set-StrictMode -Version Latest

BeforeAll {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path (Join-Path $RepoRoot 'src') 'opencode-bar-lib.psm1') -Force

    # Reset module state and seed it the way opencode-bar.ps1 does at startup.
    function Set-AlertTestState {
        param([string]$DataJson, $NotifyPools = @('go'))
        Initialize-LibState -StatePath (Join-Path $TestDrive 'state.json')
        # Start from an empty alert state so tests never depend on execution order.
        InModuleScope opencode-bar-lib { $script:Alerts = @{} }
        Set-LibConfig -Config @{ thresholds = @(75, 90, 100); notifyPools = $NotifyPools; trayPool = 'go' }
        if ($DataJson) { Set-FetchResult @{ ok = $true; body = $DataJson } }
    }

    function Get-SavedState {
        $raw = Get-Content (Join-Path $TestDrive 'state.json') -Raw
        ConvertTo-Hashtable ($raw | ConvertFrom-Json)
    }
}

Describe 'Test-Alerts' {
    It 'fires a first crossing message and records the level in state.json' {
        Set-AlertTestState -DataJson '{"usage": {"rolling": {"percent": 80, "resetsAt": "2099-01-01T00:00:00.000Z"}}}'
        $r = Test-Alerts
        $r.Messages.Count | Should -Be 1
        $r.Messages[0] | Should -BeLike '*Go*Rolling 5-hour usage*80%*'
        $r.Worst | Should -Be 75
        (Get-SavedState)['go.rolling'] | Should -Be 75
    }

    It 'fires exactly at the threshold (>= boundary)' {
        Set-AlertTestState -DataJson '{"usage": {"rolling": {"percent": 75, "resetsAt": "2099-01-01T00:00:00.000Z"}}}'
        $r = Test-Alerts
        $r.Messages.Count | Should -Be 1
        $r.Worst | Should -Be 75
    }

    It 'does not repeat a notification while the level is unchanged' {
        Set-AlertTestState -DataJson '{"usage": {"rolling": {"percent": 80, "resetsAt": "2099-01-01T00:00:00.000Z"}}}'
        $first = Test-Alerts
        $first.Messages.Count | Should -Be 1
        $second = Test-Alerts
        $second.Messages.Count | Should -Be 0
    }

    It 'escalates to the next threshold with a new message' {
        Set-AlertTestState -DataJson '{"usage": {"rolling": {"percent": 80, "resetsAt": "2099-01-01T00:00:00.000Z"}}}'
        [void](Test-Alerts)
        Set-FetchResult @{ ok = $true; body = '{"usage": {"rolling": {"percent": 95, "resetsAt": "2099-01-01T00:00:00.000Z"}}}' }
        $r = Test-Alerts
        $r.Messages.Count | Should -Be 1
        $r.Worst | Should -Be 90
        (Get-SavedState)['go.rolling'] | Should -Be 90
    }

    It 'announces availability again after a 100% window resets' {
        Set-AlertTestState -DataJson '{"usage": {"rolling": {"percent": 100, "resetsAt": "2099-01-01T00:00:00.000Z"}}}'
        $maxed = Test-Alerts
        $maxed.Worst | Should -Be 100
        $maxed.Messages[0] | Should -BeLike '*limit reached*'

        Set-FetchResult @{ ok = $true; body = '{"usage": {"rolling": {"percent": 50, "resetsAt": "2099-01-01T00:00:00.000Z"}}}' }
        $r = Test-Alerts
        $r.Messages.Count | Should -Be 1
        $r.Messages[0] | Should -BeLike '*limit available again*'
        $r.Worst | Should -Be 0
        (Get-SavedState)['go.rolling'] | Should -Be 0
    }

    It 'treats a rate-limited window as 100% and fires the limit-reached message' {
        Set-AlertTestState -DataJson '{"usage": {"rolling": {"status": "rate-limited", "percent": 97, "resetsAt": "2099-01-01T00:00:00.000Z"}}}'
        $r = Test-Alerts
        $r.Messages.Count | Should -Be 1
        $r.Worst | Should -Be 100
        $r.Messages[0] | Should -BeLike '*limit reached*'
    }

    It 'resets silently when usage drops more than 5 points below the level' {
        Set-AlertTestState -DataJson '{"usage": {"rolling": {"percent": 75, "resetsAt": "2099-01-01T00:00:00.000Z"}}}'
        [void](Test-Alerts)

        Set-FetchResult @{ ok = $true; body = '{"usage": {"rolling": {"percent": 60, "resetsAt": "2099-01-01T00:00:00.000Z"}}}' }
        $r = Test-Alerts
        $r.Messages.Count | Should -Be 0
        $r.Worst | Should -Be 0
        (Get-SavedState)['go.rolling'] | Should -Be 0
    }

    It 'stays silent below all thresholds' {
        Set-AlertTestState -DataJson '{"usage": {"rolling": {"percent": 10, "resetsAt": "2099-01-01T00:00:00.000Z"}}}'
        $r = Test-Alerts
        $r.Messages.Count | Should -Be 0
        $r.Worst | Should -Be 0
    }

    It 'checks every window of the notify pool' {
        Set-AlertTestState -DataJson '{"usage": {"rolling": {"percent": 80, "resetsAt": "2099-01-01T00:00:00.000Z"}, "weekly": {"percent": 95, "resetsAt": "2099-01-08T00:00:00.000Z"}}}'
        $r = Test-Alerts
        $r.Messages.Count | Should -Be 2
        $r.Messages[0] | Should -BeLike '*Go*Rolling 5-hour usage*'
        $r.Messages[1] | Should -BeLike '*Go*Weekly usage*'
        $r.Worst | Should -Be 90
        $state = Get-SavedState
        $state['go.rolling'] | Should -Be 75
        $state['go.weekly'] | Should -Be 90
    }

    It 'never alerts for pools outside the registry' {
        Set-AlertTestState -NotifyPools @('go', 'other') -DataJson '{"usage": {"rolling": {"percent": 100, "resetsAt": "2099-01-01T00:00:00.000Z"}}}'
        $r = Test-Alerts
        $r.Messages.Count | Should -Be 1
        $state = Get-SavedState
        $state.Keys | Should -Not -Contain 'other.rolling'
        # @() so the assertion holds under Set-StrictMode: Where-Object returns
        # $null (not an empty collection) when nothing matches, and .Count on
        # $null is a terminating error there.
        @($state.Keys | Where-Object { $_ -like 'other*' }).Count | Should -Be 0
    }
}
