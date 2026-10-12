#Requires -Version 5.1
<#
  OpenCode Bar - Windows tray icon showing your OpenCode Go usage limits.

  Usage:
    OpenCodeBar.exe                   (or: powershell -NoProfile -ExecutionPolicy Bypass -File opencode-bar.ps1)
    ... -Mock samples\mock.json       use a local JSON file instead of the API
    ... -Preview out.png              render the popup to a PNG and exit
    ... -Dump                         print the raw API response and exit
#>
param(
    [string]$Mock,
    [string]$Preview,
    [switch]$Dump
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DBNative {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
}
'@

# ---------------------------------------------------------------- paths/config

$AppName    = 'OpenCodeBar'
$ScriptPath = $MyInvocation.MyCommand.Path
$DataDir    = Join-Path $env:APPDATA 'opencode-bar'
$CfgPath    = Join-Path $DataDir 'config.json'
$StatePath  = Join-Path $DataDir 'state.json'
$LogPath    = Join-Path $DataDir 'opencode-bar.log'
$UsageUrl   = 'https://opencode.ai/console'
$KeysUrl    = 'https://opencode.ai/console'
$RunKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }

# GUI-free helpers (parsing, formatting, alert logic, tray look) live in a sibling
# module so they can be unit-tested off-Windows; it never loads WinForms/Drawing.
# $PSScriptRoot resolves to the exe folder under OpenCodeBar.exe too, so the release
# zip layout (script + src\opencode-bar-lib.psm1) works as-is.
Import-Module (Join-Path (Join-Path $PSScriptRoot 'src') 'opencode-bar-lib.psm1')
Initialize-LibState -LogPath $LogPath -StatePath $StatePath

function Get-Config {
    $cfg = @{
        apiKeyProtected = ''
        apiBase         = 'https://opencode.ai'
        pollMinutes     = 5
        thresholds      = @(75, 90, 100)
        notifyPools     = @('go')
        trayPool        = 'go'
    }
    if (Test-Path $CfgPath) {
        try {
            $saved = ConvertTo-Hashtable (Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json)
            foreach ($k in $saved.Keys) { $cfg[$k] = $saved[$k] }
        } catch { Write-Log "invalid config: $_" }
    }
    return $cfg
}

function Save-Config {
    $script:Cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $CfgPath -Encoding UTF8
}

# The key is protected with DPAPI (only your Windows user can decrypt it).
function Get-ApiKey {
    if ($env:OPENCODE_GO_API_KEY) { return $env:OPENCODE_GO_API_KEY }
    if (-not $script:Cfg.apiKeyProtected) { return $null }
    try {
        $sec = ConvertTo-SecureString $script:Cfg.apiKeyProtected
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    } catch { return $null }
}

function Set-ApiKey([string]$key) {
    $script:Cfg.apiKeyProtected = ConvertTo-SecureString $key -AsPlainText -Force | ConvertFrom-SecureString
    Save-Config
}

# ---------------------------------------------------------------- fetching

$script:Cfg = Get-Config
Set-LibConfig -Config $script:Cfg
$script:Fetch = $null

function Get-UsageUrl { return ($script:Cfg.apiBase.TrimEnd('/') + '/zen/go/v1/usage') }

# One background job fetches the Go usage endpoint with the Bearer key and
# returns @{ usage = <result> } (the hashtable shape Set-FetchResult expects).
$FetchScript = {
    param($usageUrl, $key)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $r = Invoke-WebRequest -Uri $usageUrl -UseBasicParsing -TimeoutSec 20 -Headers @{ Authorization = "Bearer $key"; Accept = 'application/json' }
        return @{ usage = @{ ok = $true; body = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) } }
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        return @{ usage = @{ ok = $false; status = $status; error = $_.Exception.Message } }
    }
}

function Start-Refresh {
    if ($script:Fetch) { return }
    if ($Mock) {
        $body = (Get-Content $Mock -Raw -Encoding UTF8)
        Set-FetchResult @{ ok = $true; body = $body }
        Show-Alerts
        Update-Ui
        return
    }
    $key = Get-ApiKey
    if (-not $key) {
        Set-FetchError 'Set your API key (right-click the icon)'
        Update-Ui
        return
    }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($FetchScript).AddArgument((Get-UsageUrl)).AddArgument($key)
    $script:Fetch = @{ ps = $ps; handle = $ps.BeginInvoke() }
    if ($script:Popup -and $script:Popup.Visible) { $script:Popup.Invalidate() }
}

function Complete-Refresh {
    if (-not $script:Fetch -or -not $script:Fetch.handle.IsCompleted) { return }
    $f = $script:Fetch
    $script:Fetch = $null
    try {
        $out = $f.ps.EndInvoke($f.handle)
        Set-FetchResult $out[0].usage
        if (-not (Get-FetchError)) { Show-Alerts }
    } catch {
        Set-FetchError 'Failed to query the API'
        Write-Log "fetch: $_"
    } finally { $f.ps.Dispose() }
    Update-Ui
}

# ---------------------------------------------------------------- alerts

# Test-Alerts (module) computes the threshold crossings and updates state.json;
# here we only turn its result into the tray balloon notification.
function Show-Alerts {
    $r = Test-Alerts
    if ($r.Messages.Count -gt 0 -and $script:Tray) {
        $title = 'OpenCode Go: usage'
        $icon = [Windows.Forms.ToolTipIcon]::Info
        if ($r.Worst -ge 100) { $title = 'OpenCode Go: limit reached'; $icon = [Windows.Forms.ToolTipIcon]::Error }
        elseif ($r.Worst -gt 0) { $title = 'OpenCode Go: approaching limit'; $icon = [Windows.Forms.ToolTipIcon]::Warning }
        $script:Tray.ShowBalloonTip(10000, $title, ($r.Messages -join "`n"), $icon)
    }
}

# ---------------------------------------------------------------- drawing

$C = @{
    Bg      = [Drawing.Color]::FromArgb(10, 10, 10)
    Border  = [Drawing.Color]::FromArgb(40, 40, 40)
    Text    = [Drawing.Color]::FromArgb(240, 240, 240)
    Muted   = [Drawing.Color]::FromArgb(130, 130, 130)
    Track   = [Drawing.Color]::FromArgb(38, 38, 38)
    Orange  = [Drawing.Color]::FromArgb(255, 92, 0)
    Red     = [Drawing.Color]::FromArgb(239, 68, 68)
    Cyan    = [Drawing.Color]::FromArgb(34, 211, 238)
    Link    = [Drawing.Color]::FromArgb(200, 200, 200)
}
$F = @{
    Title = New-Object Drawing.Font('Segoe UI Semibold', 10.5)
    Label = New-Object Drawing.Font('Segoe UI Semibold', 9.5)
    Body  = New-Object Drawing.Font('Segoe UI', 9)
    Small = New-Object Drawing.Font('Segoe UI', 8.5)
}
$TF = [Windows.Forms.TextFormatFlags]
# Get-TrayLook (module) returns palette names; map them to the popup's colors.
$TrayColors = @{
    gray   = [Drawing.Color]::FromArgb(60, 60, 60)
    dark   = [Drawing.Color]::FromArgb(38, 38, 38)
    orange = $C.Orange
    red    = $C.Red
    white  = [Drawing.Color]::White
}
$script:Hit   = @{}
$script:Hover = $null
$script:S     = 1.0

function New-RoundPath([Drawing.RectangleF]$r, [single]$rad) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $d = $rad * 2
    $p.AddArc($r.X, $r.Y, $d, $d, 180, 90)
    $p.AddArc($r.Right - $d, $r.Y, $d, $d, 270, 90)
    $p.AddArc($r.Right - $d, $r.Bottom - $d, $d, $d, 0, 90)
    $p.AddArc($r.X, $r.Bottom - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# Fixed popup height: one pool with three usage bars.
function Get-PopupSize {
    $s = $script:S
    return New-Object Drawing.Size([int](420 * $s), [int](292 * $s))
}

function Draw-Text($g, [string]$text, $font, [int]$x, [int]$y, $color) {
    [Windows.Forms.TextRenderer]::DrawText($g, $text, $font, (New-Object Drawing.Point($x, $y)), $color, $TF::NoPadding)
}
function Measure-Text([string]$text, $font) {
    return [Windows.Forms.TextRenderer]::MeasureText($text, $font, (New-Object Drawing.Size(1000, 100)), $TF::NoPadding)
}

function Draw-Popup($g, [int]$W, [int]$H) {
    $s = $script:S
    $pad = [int](22 * $s)
    $g.Clear($C.Bg)
    $g.SmoothingMode = 'AntiAlias'
    $script:Hit = @{}

    # frame
    $pen = New-Object Drawing.Pen($C.Border)
    $g.DrawRectangle($pen, 0, 0, $W - 1, $H - 1)

    # Cyan title: the popup's identity accent (Droid Bar's titles are white).
    Draw-Text $g 'Usage Limits' $F.Title $pad ([int]($pad + 3 * $s)) $C.Cyan

    # bars: the three Go windows (rolling 5-hour, weekly, monthly)
    $y = $pad + [int](50 * $s)
    $barW = $W - 2 * $pad
    $exhausted = $false
    foreach ($k in $Windows.Keys) {
        $i = Get-WinInfo 'go' $k
        $label = $Windows[$k]
        Draw-Text $g $label $F.Label $pad $y $C.Text
        $lw = (Measure-Text $label $F.Label).Width
        Draw-Text $g (Format-Pct $i.Pct) $F.Small ($pad + $lw + [int](8 * $s)) ($y + [int](1 * $s)) $C.Muted

        $reset = [char]0x21BB + ' ' + (Format-Remaining $i.End)
        $rw = (Measure-Text $reset $F.Small).Width
        Draw-Text $g $reset $F.Small ($W - $pad - $rw) ($y + [int](1 * $s)) $C.Muted

        $by = $y + [int](25 * $s); $bh = [int](8 * $s)
        $g.FillRectangle((New-Object Drawing.SolidBrush($C.Track)), $pad, $by, $barW, $bh)
        if ($i.Pct -gt 0) {
            $fill = if ($i.Pct -ge 90) { $C.Red } else { $C.Orange }
            $fw = [math]::Max([int](2 * $s), [int]($barW * [math]::Min(100, $i.Pct) / 100))
            $g.FillRectangle((New-Object Drawing.SolidBrush($fill)), $pad, $by, $fw, $bh)
        }
        if ($i.Pct -ge 100) { $exhausted = $true }
        $y += [int](52 * $s)
    }

    # status
    $data = Get-UsageData
    $status = if (-not $data) { '' }
              elseif ($exhausted) { 'OpenCode Go limit reached.' }
              else { 'You are using your OpenCode Go plan.' }
    Draw-Text $g $status $F.Small $pad ($y - [int](6 * $s)) $C.Muted

    # footer: updated / error + links
    Draw-Footer $g $W $H
    $pen.Dispose()
}

function Draw-Footer($g, [int]$W, [int]$H) {
    $s = $script:S
    $pad = [int](22 * $s)
    $pen = New-Object Drawing.Pen($C.Border)
    $fy = $H - $pad - [int](12 * $s)
    $g.DrawLine($pen, $pad, $fy - [int](10 * $s), $W - $pad, $fy - [int](10 * $s))
    $err = Get-FetchError
    $upd = Get-LastUpdated
    if ($script:Fetch) { $left = 'Refreshing…'; $lc = $C.Muted }
    elseif ($err) { $left = $err; $lc = $C.Red }
    elseif ($upd) { $left = 'Updated ' + $upd.ToString('HH:mm'); $lc = $C.Muted }
    else { $left = ''; $lc = $C.Muted }
    Draw-Text $g $left $F.Small $pad $fy $lc

    $lx = $W - $pad
    foreach ($l in @(@{ id = 'open'; t = 'Open console ' + [char]0x2197 }, @{ id = 'refresh'; t = 'Refresh' })) {
        $sz = Measure-Text $l.t $F.Small
        $lx -= $sz.Width
        $col = if ($script:Hover -eq $l.id) { [Drawing.Color]::White } else { $C.Link }
        Draw-Text $g $l.t $F.Small $lx $fy $col
        $script:Hit[$l.id] = New-Object Drawing.Rectangle($lx, $fy, $sz.Width, $sz.Height)
        $lx -= [int](18 * $s)
    }
    $pen.Dispose()
}

function New-TrayBitmap([string]$text, $bg, $fg, [int]$sz) {
    $bmp = New-Object Drawing.Bitmap($sz, $sz)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    # Circle body + cyan ring: the ring is the app's visual identity, so the icon
    # is distinguishable from Droid Bar's orange rounded square at a glance. The
    # fill keeps the usage semantics (dark/orange/red); the ring never changes.
    $rect = New-Object Drawing.RectangleF(1, 1, ($sz - 3), ($sz - 3))
    $g.FillEllipse((New-Object Drawing.SolidBrush($bg)), $rect)
    $ring = New-Object Drawing.Pen($C.Cyan, [math]::Max(1.0, $sz / 12.0))
    $g.DrawEllipse($ring, $rect)
    $ring.Dispose()
    $px = $sz * 0.72
    do {
        $font = New-Object Drawing.Font('Segoe UI', [single]$px, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
        $m = $g.MeasureString($text, $font, 1000, [Drawing.StringFormat]::GenericTypographic)
        if ($m.Width -le $sz - 1) { break }
        $font.Dispose(); $px -= 0.5
    } while ($px -gt 5)
    $sf = New-Object Drawing.StringFormat([Drawing.StringFormat]::GenericTypographic)
    $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $g.DrawString($text, $font, (New-Object Drawing.SolidBrush($fg)), (New-Object Drawing.RectangleF(0, ($sz * 0.04), $sz, $sz)), $sf)
    $g.Dispose(); $font.Dispose()
    return $bmp
}

# ---------------------------------------------------------------- preview / dump modes

if ($Dump) {
    $key = Get-ApiKey
    if (-not $key) { Write-Error 'No API key (set OPENCODE_GO_API_KEY or configure it in the app)'; exit 1 }
    $r = & $FetchScript (Get-UsageUrl) $key
    if ($r.usage.ok) { $r.usage.body } else { "Failed: HTTP $($r.usage.status) $($r.usage.error)" }
    exit 0
}

if ($Preview) {
    if ($Mock) {
        $body = (Get-Content $Mock -Raw -Encoding UTF8)
        Set-FetchResult @{ ok = $true; body = $body }
    }
    Set-LastUpdated (Get-Date)
    $script:S = 1.0
    $sz = Get-PopupSize
    $bmp = New-Object Drawing.Bitmap($sz.Width, $sz.Height)
    $g = [Drawing.Graphics]::FromImage($bmp)
    Draw-Popup $g $sz.Width $sz.Height
    $g.Dispose()
    $bmp.Save($Preview, [Drawing.Imaging.ImageFormat]::Png)
    $look = Get-TrayLook
    (New-TrayBitmap $look.text $TrayColors[$look.bg] $TrayColors[$look.fg] 64).Save(($Preview -replace '\.png$', '-icon.png'), [Drawing.Imaging.ImageFormat]::Png)
    "ok: $Preview"
    exit 0
}

# ---------------------------------------------------------------- app

$mutex = New-Object Threading.Mutex($false, 'Local\OpenCodeBar-Tray')
if (-not $mutex.WaitOne(0)) { exit 0 }

$console = [DBNative]::GetConsoleWindow()
if ($console -ne [IntPtr]::Zero) { [void][DBNative]::ShowWindow($console, 0) }
[void][DBNative]::SetProcessDPIAware()
[Windows.Forms.Application]::EnableVisualStyles()

# --- popup
$script:Popup = New-Object Windows.Forms.Form
$Popup.FormBorderStyle = 'None'
$Popup.ShowInTaskbar = $false
$Popup.TopMost = $true
$Popup.StartPosition = 'Manual'
$Popup.BackColor = $C.Bg
$Popup.KeyPreview = $true
$Popup.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($Popup, $true, $null)
$tmpG = $Popup.CreateGraphics(); $script:S = $tmpG.DpiX / 96.0; $tmpG.Dispose()
$Popup.ClientSize = Get-PopupSize
$corner = 2
[void][DBNative]::DwmSetWindowAttribute($Popup.Handle, 33, [ref]$corner, 4)   # rounded corners (Win11)
$script:HiddenAt = [datetime]::MinValue

$Popup.Add_Paint({ param($form, $e)
    try { Draw-Popup $e.Graphics $form.ClientSize.Width $form.ClientSize.Height } catch { Write-Log "paint: $_" }
})
$Popup.Add_Deactivate({ $script:Popup.Hide(); $script:HiddenAt = Get-Date })
$Popup.Add_KeyDown({ param($form, $e) if ($e.KeyCode -eq 'Escape') { $form.Hide() } })
$Popup.Add_MouseMove({ param($form, $e)
    $hover = $null
    foreach ($k in $script:Hit.Keys) { if ($script:Hit[$k].Contains($e.Location)) { $hover = $k } }
    if ($hover -ne $script:Hover) {
        $script:Hover = $hover
        $form.Cursor = if ($hover) { [Windows.Forms.Cursors]::Hand } else { [Windows.Forms.Cursors]::Default }
        $form.Invalidate()
    }
})
$Popup.Add_MouseClick({ param($form, $e)
    try {
        switch ($script:Hover) {
            'refresh'      { Start-Refresh }
            'open'         { Start-Process $UsageUrl; $form.Hide() }
        }
    } catch { Write-Log "click: $_" }
})

function Show-Popup {
    if ($script:Popup.Visible) { $script:Popup.Hide(); return }
    if (((Get-Date) - $script:HiddenAt).TotalMilliseconds -lt 300) { return }   # the icon click that just closed it
    $sz = $script:Popup.Size
    $cur = [Windows.Forms.Cursor]::Position
    $wa = [Windows.Forms.Screen]::FromPoint($cur).WorkingArea
    $m = [int](12 * $script:S)
    $x = [math]::Min([math]::Max($cur.X - $sz.Width / 2, $wa.Left + $m), $wa.Right - $sz.Width - $m)
    $y = if ($cur.Y -gt $wa.Top + $wa.Height / 2) { $wa.Bottom - $sz.Height - $m } else { $wa.Top + $m }
    $script:Popup.Location = New-Object Drawing.Point([int]$x, [int]$y)
    $script:Popup.Show()
    $script:Popup.Activate()
    $upd = Get-LastUpdated
    if (-not $upd -or ((Get-Date) - $upd).TotalSeconds -gt 60) { Start-Refresh }
}

# --- API key dialog
function Show-KeyDialog {
    $s = $script:S
    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = 'OpenCode Bar · API key'
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterScreen'; $dlg.TopMost = $true
    $dlg.ClientSize = New-Object Drawing.Size([int](440 * $s), [int](150 * $s))
    $dlg.Font = $F.Body

    $lbl = New-Object Windows.Forms.Label
    $lbl.Text = 'Paste an OpenCode Go API key (sk-...). It is stored encrypted (DPAPI) for your Windows user only.'
    $lbl.SetBounds([int](14 * $s), [int](12 * $s), [int](412 * $s), [int](36 * $s))
    $link = New-Object Windows.Forms.LinkLabel
    $link.Text = 'Manage keys at opencode.ai/console'
    $link.SetBounds([int](14 * $s), [int](50 * $s), [int](412 * $s), [int](20 * $s))
    $link.Add_LinkClicked({ Start-Process $KeysUrl })
    $box = New-Object Windows.Forms.TextBox
    $box.UseSystemPasswordChar = $true
    $box.SetBounds([int](14 * $s), [int](76 * $s), [int](412 * $s), [int](24 * $s))
    $ok = New-Object Windows.Forms.Button
    $ok.Text = 'Save'; $ok.DialogResult = 'OK'
    $ok.SetBounds([int](266 * $s), [int](112 * $s), [int](78 * $s), [int](28 * $s))
    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.DialogResult = 'Cancel'
    $cancel.SetBounds([int](348 * $s), [int](112 * $s), [int](78 * $s), [int](28 * $s))
    $dlg.Controls.AddRange(@($lbl, $link, $box, $ok, $cancel))
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel

    if ($dlg.ShowDialog() -eq 'OK' -and $box.Text.Trim()) {
        $key = $box.Text.Trim()
        $test = & $FetchScript (Get-UsageUrl) $key
        if (-not $test.usage.ok -and ($test.usage.status -eq 401 -or $test.usage.status -eq 403)) {
            [void][Windows.Forms.MessageBox]::Show('OpenCode rejected this key (HTTP ' + $test.usage.status + ').', 'OpenCode Bar', 'OK', 'Warning')
        } else {
            Set-ApiKey $key
            Set-FetchResult $test.usage
            Update-Ui
        }
    }
    $dlg.Dispose()
}

# --- start with Windows
$ExePath = Join-Path (Split-Path $ScriptPath) 'OpenCodeBar.exe'
function Get-RunCommand {
    if (Test-Path $ExePath) { return ('"{0}"' -f $ExePath) }
    return ('"{0}\System32\conhost.exe" --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}"' -f $env:SystemRoot, $ScriptPath)
}
function Test-Autostart {
    try { return [bool](Get-ItemProperty -Path $RunKey -Name $AppName -ErrorAction Stop).$AppName } catch { return $false }
}
function Set-Autostart([bool]$on) {
    if ($on) { Set-ItemProperty -Path $RunKey -Name $AppName -Value (Get-RunCommand) }
    else { Remove-ItemProperty -Path $RunKey -Name $AppName -ErrorAction SilentlyContinue }
}

# --- tray
$script:Tray = New-Object Windows.Forms.NotifyIcon
$script:PrevIcon = $null
$menu = New-Object Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('Show usage')
$miOpen.Font = New-Object Drawing.Font($miOpen.Font, [Drawing.FontStyle]::Bold)
$miOpen.Add_Click({ Show-Popup })
$menu.Items.Add('Refresh now').Add_Click({ Start-Refresh })
[void]$menu.Items.Add('-')
$menu.Items.Add('Open OpenCode console').Add_Click({ Start-Process $UsageUrl })
$menu.Items.Add('Set API key…').Add_Click({ Show-KeyDialog })
$miAuto = New-Object Windows.Forms.ToolStripMenuItem('Start with Windows')
if (Test-Autostart) { Set-Autostart $true }   # refresh old entries (powershell -> OpenCodeBar.exe)
$miAuto.Checked = Test-Autostart
$miAuto.Add_Click({ Set-Autostart (-not $miAuto.Checked); $miAuto.Checked = Test-Autostart })
[void]$menu.Items.Add($miAuto)
$menu.Items.Add('Open settings folder').Add_Click({ Start-Process $DataDir })
[void]$menu.Items.Add('-')
$menu.Items.Add('Quit').Add_Click({
    $script:Tray.Visible = $false
    [Windows.Forms.Application]::Exit()
})
$Tray.ContextMenuStrip = $menu
$Tray.Add_MouseClick({ param($form, $e) if ($e.Button -eq 'Left') { Show-Popup } })
$Tray.Add_BalloonTipClicked({ Show-Popup })

function Update-Ui {
    try {
        $look = Get-TrayLook
        $sz = [math]::Max(16, [Windows.Forms.SystemInformation]::SmallIconSize.Width)
        $bmp = New-TrayBitmap $look.text $TrayColors[$look.bg] $TrayColors[$look.fg] $sz
        $h = $bmp.GetHicon()
        $script:Tray.Icon = [Drawing.Icon]::FromHandle($h)
        $bmp.Dispose()
        if ($script:PrevIcon) { [void][DBNative]::DestroyIcon($script:PrevIcon) }
        $script:PrevIcon = $h

        $data = Get-UsageData
        $err = Get-FetchError
        if ($data) {
            $parts = foreach ($k in $Windows.Keys) { '{0} {1}' -f $Short[$k], (Format-Pct (Get-WinInfo 'go' $k).Pct) }
            $tip = 'OpenCode · ' + ($parts -join ' · ')
        } elseif ($err) { $tip = 'OpenCode · ' + $err }
        else { $tip = 'OpenCode · loading…' }
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
        $script:Tray.Text = $tip
        if ($script:Popup.Visible) {
            $script:Popup.Invalidate()
        }
    } catch { Write-Log "ui: $_" }
}

# --- timers
$pollTimer = New-Object Windows.Forms.Timer
$pollTimer.Interval = [int]([math]::Max(1, [double]$script:Cfg.pollMinutes) * 60000)
$pollTimer.Add_Tick({ Start-Refresh })
$pollTimer.Start()

$fetchTimer = New-Object Windows.Forms.Timer
$fetchTimer.Interval = 300
$fetchTimer.Add_Tick({ Complete-Refresh })
$fetchTimer.Start()

$clockTimer = New-Object Windows.Forms.Timer
$clockTimer.Interval = 30000
$clockTimer.Add_Tick({ if ($script:Popup.Visible) { $script:Popup.Invalidate() } })
$clockTimer.Start()

Update-Ui
$Tray.Visible = $true
if (-not (Get-ApiKey) -and -not $Mock) { Show-KeyDialog }
Start-Refresh

[Windows.Forms.Application]::Run()

$Tray.Dispose()
if ($script:PrevIcon) { [void][DBNative]::DestroyIcon($script:PrevIcon) }
$mutex.ReleaseMutex()
