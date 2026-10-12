# Pester 5 suite for Set-FetchResult (parsing/error mapping) and Get-TrayLook
# (data-only tray look) in src/opencode-bar-lib.psm1.
# Run (pinned, see AGENTS.md):
#   Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester -Path tests -Output Detailed -CI
Set-StrictMode -Version Latest

BeforeAll {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path (Join-Path $RepoRoot 'src') 'opencode-bar-lib.psm1') -Force

    # Reset module state and seed it the way opencode-bar.ps1 does at startup.
    function Reset-LibTest {
        InModuleScope opencode-bar-lib {
            $script:Data = $null
            $script:LastError = $null
            $script:Updated = $null
        }
        Initialize-LibState -StatePath (Join-Path $TestDrive 'state.json')
        Set-LibConfig -Config @{ thresholds = @(75, 90, 100); notifyPools = @('go'); trayPool = 'go' }
    }

    function Set-TestData([string]$json) {
        Set-FetchResult @{ ok = $true; body = $json }
    }
}

Describe 'Set-FetchResult' {
    It 'parses a valid body into the data state' {
        Reset-LibTest
        Set-TestData '{"usage": {"rolling": {"percent": 42}}}'
        (Get-UsageData).usage.rolling.percent | Should -Be 42
        Get-FetchError | Should -BeNullOrEmpty
        Get-LastUpdated | Should -Not -BeNullOrEmpty
    }

    It 'maps invalid JSON to Unexpected API response' {
        Reset-LibTest
        Set-TestData 'not json {'
        Get-FetchError | Should -Be 'Unexpected API response'
    }

    It 'maps HTTP 401 to an invalid-key message' {
        Reset-LibTest
        Set-FetchResult @{ ok = $false; status = 401 }
        Get-FetchError | Should -Be 'Invalid API key or missing permission'
    }

    It 'maps HTTP 403 to an invalid-key message' {
        Reset-LibTest
        Set-FetchResult @{ ok = $false; status = 403 }
        Get-FetchError | Should -Be 'Invalid API key or missing permission'
    }

    It 'maps other HTTP statuses to a generic HTTP error' {
        Reset-LibTest
        Set-FetchResult @{ ok = $false; status = 429 }
        Get-FetchError | Should -Be 'HTTP error 429'
    }

    It 'maps a network failure to a reachability error' {
        Reset-LibTest
        Set-FetchResult @{ ok = $false; error = 'timeout' }
        Get-FetchError | Should -Be "Can't reach OpenCode"
    }

    It 'maps a result without the ok flag to a reachability error' {
        Reset-LibTest
        Set-FetchResult @{ }
        Get-FetchError | Should -Be "Can't reach OpenCode"
    }
}

Describe 'Get-TrayLook' {
    It 'shows the ellipsis on a dark gray icon when there is no data and no error' {
        Reset-LibTest
        $look = Get-TrayLook
        $look.text | Should -Be '…'
        $look.bg | Should -Be 'gray'
        $look.fg | Should -Be 'white'
    }

    It 'shows an exclamation when there is no data but an error' {
        Reset-LibTest
        Set-FetchError 'Can''t reach OpenCode'
        $look = Get-TrayLook
        $look.text | Should -Be '!'
        $look.bg | Should -Be 'gray'
    }

    It 'stays dark below 75%' {
        Reset-LibTest
        Set-TestData '{"usage": {"rolling": {"percent": 42, "resetsAt": "2099-01-01T00:00:00.000Z"}}}'
        $look = Get-TrayLook
        $look.text | Should -Be '42'
        $look.bg | Should -Be 'dark'
    }

    It 'turns orange at 75% and red at 90%' {
        Reset-LibTest
        Set-TestData '{"usage": {"rolling": {"percent": 75, "resetsAt": "2099-01-01T00:00:00.000Z"}}}'
        (Get-TrayLook).bg | Should -Be 'orange'

        Reset-LibTest
        Set-TestData '{"usage": {"rolling": {"percent": 74, "resetsAt": "2099-01-01T00:00:00.000Z"}}}'
        (Get-TrayLook).bg | Should -Be 'dark'

        Reset-LibTest
        Set-TestData '{"usage": {"rolling": {"percent": 90, "resetsAt": "2099-01-01T00:00:00.000Z"}}}'
        (Get-TrayLook).bg | Should -Be 'red'
    }

    It 'clamps the tray number at 100' {
        Reset-LibTest
        Set-TestData '{"usage": {"rolling": {"percent": 150, "resetsAt": "2099-01-01T00:00:00.000Z"}}}'
        $look = Get-TrayLook
        $look.text | Should -Be '100'
        $look.bg | Should -Be 'red'
    }

    It 'colors a rate-limited window red at 100' {
        Reset-LibTest
        Set-TestData '{"usage": {"rolling": {"status": "rate-limited", "percent": 99, "resetsAt": "2099-01-01T00:00:00.000Z"}}}'
        $look = Get-TrayLook
        $look.text | Should -Be '100'
        $look.bg | Should -Be 'red'
    }
}
