# Generates the icon and compiles OpenCodeBar.exe with the C# compiler that ships with Windows (.NET Framework 4).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = $PSScriptRoot
$src  = Join-Path $root 'src'

# --- icon: the OpenCode logo mark from the official brand SVG's square variant
# (viewBox 24x30): light square frame, square hole (left transparent via PNG
# alpha) and a dark inner block. (PNGs inside an .ico.)
function New-IconPng([int]$sz) {
    $bmp = New-Object Drawing.Bitmap($sz, $sz)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $m = $sz * 0.06; $w = $sz - 2 * $m
    $u = $w / 24.0; $h = 30 * $u
    $frame = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(241, 236, 236))
    $block = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(75, 70, 70))
    # outer frame; the hole (6,6)-(18,24) stays unpainted (transparent)
    $g.FillRectangle($frame, [single]$m, [single]$m, [single]$w, [single]$h)
    # inner block (6,12)-(18,24)
    $g.FillRectangle($block, [single]($m + 6 * $u), [single]($m + 12 * $u), [single](12 * $u), [single](12 * $u))
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
