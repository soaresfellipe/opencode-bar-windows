# Pester 5 suite for the GUI-free helpers in src/opencode-bar-lib.psm1.
# Run (pinned, see AGENTS.md):
#   Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester -Path tests -Output Detailed -CI
Set-StrictMode -Version Latest

BeforeAll {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path (Join-Path $RepoRoot 'src') 'opencode-bar-lib.psm1') -Force

    # Seed the module with a parsed API payload (same shape as /zen/go/v1/usage).
    function Set-TestData([string]$json) {
        Set-FetchResult @{ ok = $true; body = $json }
    }
}

Describe 'ConvertTo-Hashtable' {
    It 'returns an empty hashtable for null input' {
        $h = ConvertTo-Hashtable $null
        $h | Should -BeOfType [hashtable]
        $h.Count | Should -Be 0
    }

    It 'maps PSCustomObject properties to keys and values' {
        $o = '{"a": 1, "b": "x"}' | ConvertFrom-Json
        $h = ConvertTo-Hashtable $o
        $h.Count | Should -Be 2
        $h['a'] | Should -Be 1
        $h['b'] | Should -Be 'x'
    }
}

Describe 'Get-MemberValue' {
    It 'returns null for a null object' {
        Get-MemberValue $null 'anything' | Should -BeNullOrEmpty
    }

    It 'returns the value of an existing PSCustomObject property' {
        $o = '{"percent": 42}' | ConvertFrom-Json
        Get-MemberValue $o 'percent' | Should -Be 42
    }

    It 'returns null (not a strict-mode error) for a missing PSCustomObject property' {
        $o = '{}' | ConvertFrom-Json
        Get-MemberValue $o 'missing' | Should -BeNullOrEmpty
    }

    It 'returns the value of an existing dictionary key' {
        $d = @{ key = 'value' }
        Get-MemberValue $d 'key' | Should -Be 'value'
    }

    It 'returns null for a missing dictionary key' {
        $d = @{ key = 'value' }
        Get-MemberValue $d 'missing' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-LocalTime' {
    It 'returns null for null or empty input' {
        ConvertTo-LocalTime $null | Should -BeNullOrEmpty
        ConvertTo-LocalTime '' | Should -BeNullOrEmpty
    }

    It 'returns null for an unparseable string' {
        ConvertTo-LocalTime 'not-a-date' | Should -BeNullOrEmpty
    }

    It 'interprets epoch seconds' {
        $r = ConvertTo-LocalTime 1600000000
        $r | Should -BeOfType [datetime]
        $r | Should -Be ([DateTimeOffset]::FromUnixTimeSeconds(1600000000).LocalDateTime)
    }

    It 'interprets epoch milliseconds' {
        $r = ConvertTo-LocalTime 1600000000000
        $r | Should -Be ([DateTimeOffset]::FromUnixTimeMilliseconds(1600000000000).LocalDateTime)
    }

    It 'parses an ISO-8601 timestamp' {
        $r = ConvertTo-LocalTime '2026-10-04T03:13:37.287Z'
        $expected = [DateTimeOffset]::Parse('2026-10-04T03:13:37.287Z', [Globalization.CultureInfo]::InvariantCulture).LocalDateTime
        $r | Should -Be $expected
    }

    It 'passes datetimes through ToLocalTime' {
        $r = ConvertTo-LocalTime ([datetime]'2099-01-01T00:00:00Z')
        $r | Should -BeOfType [datetime]
    }
}

Describe 'Get-WinInfo' {
    It 'returns an inactive null-pct info when the usage payload is missing' {
        Set-TestData '{}'
        $i = Get-WinInfo 'go' 'rolling'
        $i.Pct | Should -BeNullOrEmpty
        $i.Active | Should -BeFalse
        $i.End | Should -BeNullOrEmpty
    }

    It 'returns an inactive null-pct info when the window is missing' {
        Set-TestData '{"usage": {"rolling": {"percent": 10}}}'
        $i = Get-WinInfo 'go' 'weekly'
        $i.Pct | Should -BeNullOrEmpty
    }

    It 'returns an inactive null-pct info for a pool outside the registry' {
        Set-TestData '{"usage": {"rolling": {"percent": 10}}}'
        $i = Get-WinInfo 'other' 'rolling'
        $i.Pct | Should -BeNullOrEmpty
    }

    It 'reports pct and active end for a running window' {
        Set-TestData '{"usage": {"rolling": {"percent": 42, "resetsAt": "2099-01-01T00:00:00.000Z"}}}'
        $i = Get-WinInfo 'go' 'rolling'
        $i.Pct | Should -Be 42
        $i.Active | Should -BeTrue
        $i.End | Should -BeOfType [datetime]
    }

    It 'treats a missing resetsAt as no active window but keeps the reported pct' {
        Set-TestData '{"usage": {"rolling": {"percent": 33}}}'
        $i = Get-WinInfo 'go' 'rolling'
        $i.Pct | Should -Be 33
        $i.Active | Should -BeFalse
        $i.End | Should -BeNullOrEmpty
    }

    It 'reports an expired window as inactive with usage back to 0' {
        Set-TestData '{"usage": {"rolling": {"percent": 80, "resetsAt": "2020-01-01T00:00:00.000Z"}}}'
        $i = Get-WinInfo 'go' 'rolling'
        $i.Pct | Should -Be 0
        $i.Active | Should -BeFalse
    }

    It 'reports a rate-limited window as 100% and active' {
        Set-TestData '{"usage": {"rolling": {"status": "rate-limited", "percent": 99, "resetsAt": "2099-01-01T00:00:00.000Z"}}}'
        $i = Get-WinInfo 'go' 'rolling'
        $i.Pct | Should -Be 100
        $i.Active | Should -BeTrue
    }

    It 'defaults a missing percent to 0' {
        Set-TestData '{"usage": {"rolling": {"resetsAt": "2099-01-01T00:00:00.000Z"}}}'
        (Get-WinInfo 'go' 'rolling').Pct | Should -Be 0
    }

    It 'clamps a negative percent to 0' {
        Set-TestData '{"usage": {"rolling": {"percent": -5, "resetsAt": "2099-01-01T00:00:00.000Z"}}}'
        (Get-WinInfo 'go' 'rolling').Pct | Should -Be 0
    }
}

Describe 'Get-PoolMax' {
    It 'returns the max pct across the pool windows' {
        Set-TestData '{"usage": {"rolling": {"percent": 42, "resetsAt": "2099-01-01T00:00:00.000Z"}, "weekly": {"percent": 10, "resetsAt": "2099-01-08T00:00:00.000Z"}, "monthly": {"percent": 5, "resetsAt": "2099-02-01T00:00:00.000Z"}}}'
        Get-PoolMax 'go' | Should -Be 42
    }

    It 'returns null when there is no data' {
        Set-TestData '{}'
        Get-PoolMax 'go' | Should -BeNullOrEmpty
    }

    It 'returns null when every window is missing' {
        Set-TestData '{"usage": {"rolling": {"percent": 10}}}'
        Get-PoolMax 'go' | Should -Not -BeNullOrEmpty
        Set-TestData '{"usage": {}}'
        Get-PoolMax 'go' | Should -BeNullOrEmpty
    }
}

Describe 'Format-Pct' {
    It 'renders null as an em dash' {
        Format-Pct $null | Should -Be '—'
    }

    It 'floors fractional percentages' {
        Format-Pct 0 | Should -Be '0%'
        Format-Pct 6.4 | Should -Be '6%'
        Format-Pct 99.9 | Should -Be '99%'
        Format-Pct 100 | Should -Be '100%'
    }
}

Describe 'Format-Remaining' {
    It 'renders null end as an em dash' {
        Format-Remaining $null | Should -Be '—'
    }

    It 'renders an elapsed window as now' {
        Format-Remaining (Get-Date).AddMinutes(-5) | Should -Be 'now'
    }

    It 'renders less than a minute as <1min' {
        Format-Remaining (Get-Date).AddSeconds(30) | Should -Be '<1min'
    }

    It 'renders a single minute without padding' {
        Format-Remaining (Get-Date).AddSeconds(105) | Should -Be '1min'
    }

    It 'renders hours and minutes' {
        Format-Remaining (Get-Date).AddMinutes(125) | Should -Be '2h 4min'
    }

    It 'renders more than a day as 1 day Xh' {
        Format-Remaining (Get-Date).AddHours(30) | Should -Be '1 day 5h'
    }

    It 'renders multi-day windows as N days' {
        Format-Remaining ((Get-Date).AddDays(3).AddMinutes(5)) | Should -Be '3 days'
    }
}

Describe 'Get-AlertState' {
    It 'returns an empty hashtable when the state file does not exist' {
        Initialize-LibState -StatePath (Join-Path $TestDrive 'missing.json')
        (Get-AlertState).Count | Should -Be 0
    }

    It 'parses a saved alert state file' {
        $p = Join-Path $TestDrive 'state.json'
        '{"go.rolling": 75}' | Set-Content -Path $p -Encoding UTF8
        Initialize-LibState -StatePath $p
        $a = Get-AlertState
        $a.Count | Should -Be 1
        $a['go.rolling'] | Should -Be 75
    }

    It 'returns an empty hashtable for a corrupt state file' {
        $p = Join-Path $TestDrive 'state.json'
        'not json {' | Set-Content -Path $p -Encoding UTF8
        Initialize-LibState -StatePath $p
        (Get-AlertState).Count | Should -Be 0
    }
}

Describe 'module hygiene' {
    It 'exports the shared lookup tables' {
        $Pools['go'] | Should -Be 'Go'
        $Windows['rolling'] | Should -Be 'Rolling 5-hour usage'
        $Windows['weekly'] | Should -Be 'Weekly usage'
        $Windows['monthly'] | Should -Be 'Monthly usage'
        $Short['rolling'] | Should -Be '5h'
        $Short['weekly'] | Should -Be 'week'
        $Short['monthly'] | Should -Be 'month'
    }

    It 'returns palette names (no GDI types) from Get-TrayLook' {
        InModuleScope opencode-bar-lib {
            $script:Data = $null
            $script:LastError = $null
        }
        Set-LibConfig -Config @{ thresholds = @(75, 90, 100); notifyPools = @('go'); trayPool = 'go' }
        $look = Get-TrayLook
        $look.bg | Should -BeOfType [string]
        $look.fg | Should -BeOfType [string]
        $look.text | Should -Be '…'
    }
}
