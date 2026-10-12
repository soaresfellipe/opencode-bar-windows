# Generates the icon and compiles OpenCodeBar.exe with the C# compiler that ships with Windows (.NET Framework 4).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = $PSScriptRoot
$src  = Join-Path $root 'src'

# --- icon: dark circle with a cyan ring and three cyan usage bars (PNGs inside an .ico).
# The circle + cyan is the app's identity, distinct from Droid Bar's orange rounded square.
function New-IconPng([int]$sz) {
    $bmp = New-Object Drawing.Bitmap($sz, $sz)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $ringW = [math]::Max(1.0, $sz / 12.0)
    $body = New-Object Drawing.RectangleF([single]$ringW, [single]$ringW, [single]($sz - 2 * $ringW - 1), [single]($sz - 2 * $ringW - 1))
    $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(18, 18, 18))), $body)
    $cyan = [Drawing.Color]::FromArgb(34, 211, 238)
    $g.DrawEllipse((New-Object Drawing.Pen($cyan, $ringW)), $body)
    $track = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(60, 60, 60))
    $accent = New-Object Drawing.SolidBrush($cyan)
    $m = $sz * 0.24; $w = $sz - 2 * $m; $h = [math]::Max(2, $sz * 0.11)
    $i = 0
    foreach ($f in 0.58, 0.40, 0.20) {
        $y = $sz * 0.30 + $i * $sz * 0.16
        $g.FillRectangle($track, [single]$m, [single]$y, [single]$w, [single]$h)
        $g.FillRectangle($accent, [single]$m, [single]$y, [single]($w * [math]::Max($f, 0.25)), [single]$h)
        $i++
    }
    $g.Dispose()
    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    return , $ms.ToArray()
}

$sizes = 16, 24, 32, 48, 64, 256
$pngs = foreach ($s in $sizes) { , (New-IconPng $s) }
$ico = New-Object IO.MemoryStream
$bw = New-Object IO.BinaryWriter($ico)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($k = 0; $k -lt $sizes.Count; $k++) {
    $s = $sizes[$k]; $len = $pngs[$k].Length
    $bw.Write([byte]($s % 256)); $bw.Write([byte]($s % 256)); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$len); $bw.Write([uint32]$offset)
    $offset += $len
}
foreach ($png in $pngs) { $bw.Write($png) }
$bw.Flush()
$icoPath = Join-Path $src 'opencode-bar.ico'
[IO.File]::WriteAllBytes($icoPath, $ico.ToArray())

# --- compile
$csc = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$sma = "$env:SystemRoot\Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation\v4.0_3.0.0.0__31bf3856ad364e35\System.Management.Automation.dll"
& $csc /nologo /target:winexe /platform:anycpu /optimize+ "/out:$root\OpenCodeBar.exe" "/win32icon:$icoPath" `
    "/reference:$sma" /reference:System.Windows.Forms.dll /reference:System.Core.dll "$src\OpenCodeBarHost.cs"
if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }
"ok: $root\OpenCodeBar.exe"
