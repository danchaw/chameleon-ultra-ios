# Renders the app icon (light variant on a soft gray gradient) to a
# 1024px PNG for the AppIcon asset catalog (single-size slot).
Add-Type -AssemblyName System.Drawing
Set-Location (Join-Path $PSScriptRoot '..')

$S = 1.16; $TX = -45.1; $TY = -76.9; $K = 2.0
function MX([double]$x) { return ($S * $x + $TX) * $K }
function MY([double]$y) { return ($S * $y + $TY) * $K }
function MW([double]$w) { return $S * $w * $K }

function New-RoundedRectPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $r * 2
  $p.AddArc($x, $y, $d, $d, 180, 90)
  $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
  $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $p.CloseFigure()
  return $p
}

function Draw-SvgArc($g, $pen, $x1, $y1, $x2, $y2, $r) {
  $dx = $x2 - $x1; $dy = $y2 - $y1
  $L = [Math]::Sqrt($dx * $dx + $dy * $dy)
  $mx = ($x1 + $x2) / 2; $my = ($y1 + $y2) / 2
  $hh = $r * $r - ($L / 2) * ($L / 2)
  if ($hh -lt 0) { $hh = 0 }
  $h = [Math]::Sqrt($hh)
  $cx = $mx + $h * (-$dy) / $L
  $cy = $my + $h * ($dx) / $L
  $start = [Math]::Atan2($y1 - $cy, $x1 - $cx) * 180 / [Math]::PI
  $end   = [Math]::Atan2($y2 - $cy, $x2 - $cx) * 180 / [Math]::PI
  $delta = $end - $start
  while ($delta -lt 0) { $delta += 360 }
  while ($delta -ge 360) { $delta -= 360 }
  $g.DrawArc($pen, [single]($cx - $r), [single]($cy - $r), [single]($r * 2), [single]($r * 2), [single]$start, [single]$delta)
}

$bmp = New-Object System.Drawing.Bitmap(1024, 1024)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'

# light background: soft gray diagonal gradient
$bgBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
  (New-Object System.Drawing.RectangleF(0, 0, 1024, 1024)),
  [System.Drawing.Color]::FromArgb(255, 249, 250, 251),
  [System.Drawing.Color]::FromArgb(255, 229, 231, 235), 45.0)
$g.FillRectangle($bgBrush, 0, 0, 1024, 1024)

$gradRect = New-Object System.Drawing.RectangleF(140, 180, 740, 660)

function New-StrokePen([double]$width, [int]$alpha) {
  $c1 = [System.Drawing.Color]::FromArgb($alpha, 5, 150, 105)    # emerald 600
  $c2 = [System.Drawing.Color]::FromArgb($alpha, 8, 145, 178)    # cyan 600
  $b = New-Object System.Drawing.Drawing2D.LinearGradientBrush($gradRect, $c1, $c2, 0.0)
  $pen = New-Object System.Drawing.Pen($b, [single]$width)
  $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
  $pen.LineJoin = 'Round'
  return $pen
}

# concentric signal arcs (chameleon crest / NFC waves)
Draw-SvgArc $g (New-StrokePen (MW 24) 255) (MX 140) (MY 300) (MX 400) (MY 240) ($S * 180 * $K)
Draw-SvgArc $g (New-StrokePen (MW 20) 210) (MX 180) (MY 310) (MX 360) (MY 260) ($S * 130 * $K)
Draw-SvgArc $g (New-StrokePen (MW 16) 165) (MX 220) (MY 320) (MX 320) (MY 280) ($S * 80 * $K)

# body + coiled tail
$gp = New-Object System.Drawing.Drawing2D.GraphicsPath
$gp.StartFigure()
$gp.AddBezier(
  [single](MX 140), [single](MY 300),
  [single](MX 100), [single](MY 350),
  [single](MX 130), [single](MY 420),
  [single](MX 200), [single](MY 410))
$gp.AddBezier(
  [single](MX 200), [single](MY 410),
  [single](MX 240), [single](MY 400),
  [single](MX 230), [single](MY 360),
  [single](MX 200), [single](MY 360))
$g.DrawPath((New-StrokePen (MW 24) 255), $gp)

# RFID chip eye
$chip = New-RoundedRectPath (MX 310) (MY 160) (MW 62) (MW 62) (MW 16)
$cb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 5, 150, 105))
$g.FillPath($cb, $chip)
$pb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 31, 41, 55))
$pr = MW 15
$g.FillEllipse($pb, [single]((MX 341) - $pr), [single]((MY 191) - $pr), [single]($pr * 2), [single]($pr * 2))

$g.Dispose()
$outDir = (Resolve-Path (Join-Path $PSScriptRoot '..\ChameleonUltra\Assets.xcassets\AppIcon.appiconset')).Path
$bmp.Save((Join-Path $outDir 'AppIcon1024.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "rendered: $outDir\AppIcon1024.png"
