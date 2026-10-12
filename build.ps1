# Generates the icon and compiles OpenCodeBar.exe with the C# compiler that ships with Windows (.NET Framework 4).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = $PSScriptRoot
$src  = Join-Path $root 'src'

# --- icon: dark rounded square with three orange usage bars (PNGs inside an .ico)
function New-IconPng([int]$sz) {
    $bmp = New-Object Drawing.Bitmap($sz, $sz)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $r = $sz * 0.2; $d = $r * 2; $e = $sz - 1
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $p.AddArc(0, 0, $d, $d, 180, 90); $p.AddArc($e - $d, 0, $d, $d, 270, 90)
    $p.AddArc($e - $d, $e - $d, $d, $d, 0, 90); $p.AddArc(0, $e - $d, $d, $d, 90, 90); $p.CloseFigure()
    $g.FillPath((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(18, 18, 18))), $p)
    $track = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(60, 60, 60))
    $orange = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 92, 0))
    $m = $sz * 0.18; $w = $sz - 2 * $m; $h = [math]::Max(2, $sz * 0.13)
    $i = 0
    foreach ($f in 0.58, 0.40, 0.20) {
        $y = $sz * 0.24 + $i * $sz * 0.2
        $g.FillRectangle($track, [single]$m, [single]$y, [single]$w, [single]$h)
        $g.FillRectangle($orange, [single]$m, [single]$y, [single]($w * [math]::Max($f, 0.25)), [single]$h)
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
