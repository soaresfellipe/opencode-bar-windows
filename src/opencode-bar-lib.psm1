#Requires -Version 5.1
<#
  OpenCode Bar - GUI-free helper library.

  opencode-bar.ps1 imports this module from $PSScriptRoot\src at startup; the Pester
  suite (tests/) imports it directly so the helpers can be unit-tested on any host,
  including pwsh on Linux. The module must therefore stay free of
  System.Windows.Forms / System.Drawing references and must not touch %APPDATA%
  (or any other Windows-only resource) at import time.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- module state
# The module owns the app's data-layer state; opencode-bar.ps1 reads and writes it
# through the exported accessors so the GUI layer never touches module internals.
$script:Data      = $null   # parsed GET /zen/go/v1/usage payload
$script:Cfg       = @{}     # app config slice (thresholds, notifyPools, trayPool)
$script:Alerts    = @{}     # per-window alert levels, persisted to state.json
$script:LastError = $null
$script:Updated   = $null
$script:LogPath   = $null
$script:StatePath = $null

# Static lookup tables shared by the GUI (labels, tooltip) and the helpers.
# The OpenCode Go plan exposes one pool ('go') with three sliding windows
# (rolling 5-hour, weekly, monthly).
$Pools   = [ordered]@{ go = 'Go' }
$Windows = [ordered]@{ rolling = 'Rolling 5-hour usage'; weekly = 'Weekly usage'; monthly = 'Monthly usage' }
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSScriptAnalyzer', 'PSUseDeclaredVarsMoreThanAssignments', Justification = '$Short is exported for the importing script (tray tooltip); nothing inside the module reads it.')]
$Short   = @{ rolling = '5h'; weekly = 'week'; monthly = 'month' }

function Write-Log([string]$msg) {
    try {
        if (-not $script:LogPath) { return }
        if ((Test-Path $script:LogPath) -and (Get-Item $script:LogPath).Length -gt 512KB) { Remove-Item $script:LogPath }
        Add-Content -Path $script:LogPath -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg) -Encoding UTF8
    } catch { }
}

function ConvertTo-Hashtable($obj) {
    $h = @{}
    if ($null -ne $obj) { foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    return $h
}

# Strict-mode-safe member access: returns $null when the property (or dictionary key)
# does not exist instead of throwing. Required because Set-StrictMode turns references
# to non-existent properties into terminating errors, and API/mock JSON is dynamic.
function Get-MemberValue($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Collections.IDictionary]) {
        if ($obj.Contains($name)) { return $obj[$name] } else { return $null }
    }
    $p = $obj.PSObject.Properties[$name]
    if ($null -ne $p) { return $p.Value }
    return $null
}

function Get-AlertState {
    if ($script:StatePath -and (Test-Path $script:StatePath)) {
        try { return ConvertTo-Hashtable (Get-Content $script:StatePath -Raw | ConvertFrom-Json) } catch { }
    }
    return @{}
}

# ---------------------------------------------------------------- data helpers

function ConvertTo-LocalTime($v) {
    if ($null -eq $v -or "$v" -eq '') { return $null }
    if ($v -is [datetime]) { return $v.ToLocalTime() }
    if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) {
        $n = [double]$v
        if ($n -gt 1e12) { return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$n).LocalDateTime }
        return [DateTimeOffset]::FromUnixTimeSeconds([long]$n).LocalDateTime
    }
    try { return [DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture).LocalDateTime } catch { return $null }
}

# One usage window of the Go plan. The API shape (mirroring opencode-quota's
# reading of GET /zen/go/v1/usage) is, per window:
#   { "status": "ok" | "rate-limited", "percent": 0-100, "resetsAt": "<offset-qualified ISO>" }
# 'rate-limited' means the window is exhausted: the meter reports 100 regardless
# of the raw percent value. An expired resetsAt rolls the window back to 0.
function Get-WinInfo([string]$pool, [string]$key) {
    $info = @{ Pct = $null; End = $null; Active = $false }
    # The single Go pool maps straight onto the payload's 'usage' object; the
    # pool argument stays for interface parity with the alert/tray helpers.
    if (-not $Pools.Contains($pool)) { return $info }
    $usage = Get-MemberValue $script:Data 'usage'
    if ($null -eq $usage) { return $info }
    $w = Get-MemberValue $usage $key
    if ($null -eq $w) { return $info }
    $pct = 0.0
    $used = Get-MemberValue $w 'percent'
    if ($null -ne $used) { $pct = [double]$used }
    $end = ConvertTo-LocalTime (Get-MemberValue $w 'resetsAt')
    $info.End = $end
    if ($end) {
        $info.Active = $end -ge (Get-Date)
        if (-not $info.Active) { $pct = 0 }   # window already rolled over: usage is back to zero
    }
    if ("$(Get-MemberValue $w 'status')" -eq 'rate-limited') { $pct = 100; $info.Active = $true }
    $info.Pct = [math]::Max(0, $pct)
    return $info
}

function Get-PoolMax([string]$pool) {
    $max = $null
    foreach ($k in $Windows.Keys) {
        $i = Get-WinInfo $pool $k
        if ($null -ne $i.Pct -and ($null -eq $max -or $i.Pct -gt $max)) { $max = $i.Pct }
    }
    return $max
}

function Format-Pct($pct) { if ($null -eq $pct) { return '—' }; return ('{0:0}%' -f [math]::Floor($pct)) }

function Format-Remaining($end) {
    if (-not $end) { return '—' }
    $ts = $end - (Get-Date)
    if ($ts.TotalSeconds -le 0) { return 'now' }
    if ($ts.TotalHours -ge 48) { return ('{0} days' -f [math]::Floor($ts.TotalDays)) }
    if ($ts.TotalHours -ge 24) { return ('1 day {0}h' -f $ts.Hours) }
    $h = [math]::Floor($ts.TotalHours)
    if ($h -gt 0) { return ('{0}h {1}min' -f $h, $ts.Minutes) }
    if ($ts.Minutes -lt 1) { return '<1min' }
    return ('{0}min' -f $ts.Minutes)
}

# ---------------------------------------------------------------- fetching

function Set-FetchResult($res) {
    if (Get-MemberValue $res 'ok') {
        try {
            $script:Data = $res.body | ConvertFrom-Json
            $script:LastError = $null
            $script:Updated = Get-Date
        } catch {
            $script:LastError = 'Unexpected API response'
            Write-Log "json: $_ :: $(Get-MemberValue $res 'body')"
        }
    } elseif ((Get-MemberValue $res 'status') -eq 401 -or (Get-MemberValue $res 'status') -eq 403) {
        $script:LastError = 'Invalid API key or missing permission'
    } elseif (Get-MemberValue $res 'status') {
        $script:LastError = "HTTP error $(Get-MemberValue $res 'status')"
    } else {
        $script:LastError = "Can't reach OpenCode"
    }
    if ($script:LastError) { Write-Log "$($script:LastError) $(Get-MemberValue $res 'error')" }
}

# ---------------------------------------------------------------- alerts

# Computes threshold crossings for every window of every notify pool and updates
# the persisted alert state. Returns the notification texts as data (Messages plus
# the highest crossed threshold); opencode-bar.ps1's Show-Alerts turns them into the
# tray balloon — the module itself never touches WinForms.
function Test-Alerts {
    # Config lookups go through Get-MemberValue so a config.json missing a key
    # degrades to "no thresholds / no pools" instead of a strict-mode error.
    $thresholds = @(Get-MemberValue $script:Cfg 'thresholds' | ForEach-Object { [double]$_ } | Sort-Object)
    $msgs = New-Object System.Collections.Generic.List[string]
    $worst = 0
    foreach ($pool in @(Get-MemberValue $script:Cfg 'notifyPools')) {
        if (-not $Pools.Contains($pool)) { continue }
        foreach ($k in $Windows.Keys) {
            $i = Get-WinInfo $pool $k
            if ($null -eq $i.Pct) { continue }
            $id = "$pool.$k"
            $level = 0.0
            if ($script:Alerts.ContainsKey($id)) { $level = [double]$script:Alerts[$id] }

            # Usage dropped well below the last alert: the window has reset.
            if ($level -gt 0 -and $i.Pct -lt ($level - 5)) {
                if ($level -ge 100) { $msgs.Add(("{0} · {1}: limit available again ({2})" -f $Pools[$pool], $Windows[$k], (Format-Pct $i.Pct))) }
                $level = 0
            }
            $crossed = $thresholds | Where-Object { $i.Pct -ge $_ } | Select-Object -Last 1
            if ($crossed -and $crossed -gt $level) {
                $what = if ($i.Pct -ge 100) { 'limit reached' } else { 'at ' + (Format-Pct $i.Pct) }
                $msgs.Add(("{0} · {1}: {2}, resets in {3}" -f $Pools[$pool], $Windows[$k], $what, (Format-Remaining $i.End)))
                $level = $crossed
                if ($crossed -gt $worst) { $worst = $crossed }
            }
            $script:Alerts[$id] = $level
        }
    }
    try { $script:Alerts | ConvertTo-Json | Set-Content -Path $script:StatePath -Encoding UTF8 } catch { }

    return @{ Messages = $msgs; Worst = $worst }
}

# ---------------------------------------------------------------- tray look

# Returns the tray icon look as plain data (palette names, no GDI types); the GUI
# script maps gray/dark/orange/red/white to its System.Drawing colors.
function Get-TrayLook {
    $pool = Get-MemberValue $script:Cfg 'trayPool'
    $max = Get-PoolMax $pool
    if (-not $script:Data -or $null -eq $max) {
        $t = if ($script:LastError) { '!' } else { '…' }
        return @{ text = $t; bg = 'gray'; fg = 'white' }
    }
    $bg = 'dark'
    if ($max -ge 90) { $bg = 'red' } elseif ($max -ge 75) { $bg = 'orange' }
    return @{ text = ('{0:0}' -f [math]::Min(100, [math]::Floor($max))); bg = $bg; fg = 'white' }
}

# ---------------------------------------------------------------- init / state accessors

# Called once by opencode-bar.ps1 at startup with the app's data-file paths. Also
# (re)loads the persisted alert state so Test-Alerts continues where the last run
# left off.
function Initialize-LibState {
    param([string]$LogPath, [string]$StatePath)
    $script:LogPath = $LogPath
    $script:StatePath = $StatePath
    $script:Alerts = Get-AlertState
}

function Set-LibConfig($Config) { $script:Cfg = $Config }
function Get-UsageData { return $script:Data }
function Get-FetchError { return $script:LastError }
function Set-FetchError([string]$msg) { $script:LastError = $msg }
function Get-LastUpdated { return $script:Updated }
function Set-LastUpdated($t) { $script:Updated = $t }

Export-ModuleMember -Function Write-Log, ConvertTo-Hashtable, Get-MemberValue, Get-AlertState, ConvertTo-LocalTime, Get-WinInfo, Get-PoolMax, Format-Pct, Format-Remaining, Set-FetchResult, Test-Alerts, Get-TrayLook, Initialize-LibState, Set-LibConfig, Get-UsageData, Get-FetchError, Set-FetchError, Get-LastUpdated, Set-LastUpdated -Variable Pools, Windows, Short
