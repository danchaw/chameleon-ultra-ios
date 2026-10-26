# Regenerates classic multi-size app icon sets for the alternate icons
# (IconDark / IconLight) from the two 1024 masters.
Add-Type -AssemblyName System.Drawing
Set-Location (Join-Path $PSScriptRoot '..')

$contents = @'
{
  "images" : [
    { "filename" : "NAME-20.png", "idiom" : "iphone", "scale" : "2x", "size" : "20x20" },
    { "filename" : "NAME-60.png", "idiom" : "iphone", "scale" : "3x", "size" : "20x20" },
    { "filename" : "NAME-58.png", "idiom" : "iphone", "scale" : "2x", "size" : "29x29" },
    { "filename" : "NAME-87.png", "idiom" : "iphone", "scale" : "3x", "size" : "29x29" },
    { "filename" : "NAME-80.png", "idiom" : "iphone", "scale" : "2x", "size" : "40x40" },
    { "filename" : "NAME-120.png", "idiom" : "iphone", "scale" : "3x", "size" : "40x40" },
    { "filename" : "NAME-120.png", "idiom" : "iphone", "scale" : "2x", "size" : "60x60" },
    { "filename" : "NAME-180.png", "idiom" : "iphone", "scale" : "3x", "size" : "60x60" },
    { "filename" : "NAME-20.png", "idiom" : "ipad", "scale" : "1x", "size" : "20x20" },
    { "filename" : "NAME-40.png", "idiom" : "ipad", "scale" : "2x", "size" : "20x20" },
    { "filename" : "NAME-29.png", "idiom" : "ipad", "scale" : "1x", "size" : "29x29" },
    { "filename" : "NAME-58.png", "idiom" : "ipad", "scale" : "2x", "size" : "29x29" },
    { "filename" : "NAME-40.png", "idiom" : "ipad", "scale" : "1x", "size" : "40x40" },
    { "filename" : "NAME-80.png", "idiom" : "ipad", "scale" : "2x", "size" : "40x40" },
    { "filename" : "NAME-76.png", "idiom" : "ipad", "scale" : "1x", "size" : "76x76" },
    { "filename" : "NAME-152.png", "idiom" : "ipad", "scale" : "2x", "size" : "76x76" },
    { "filename" : "NAME-167.png", "idiom" : "ipad", "scale" : "2x", "size" : "83.5x83.5" },
    { "filename" : "NAME-1024.png", "idiom" : "ios-marketing", "scale" : "1x", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
'@

$pairs = @(
  @{ master = 'ChameleonUltra\Assets.xcassets\AppIcon.appiconset\AppIcon1024.png'; name = 'IconDark' },
  @{ master = 'ChameleonUltra\Assets.xcassets\AppIcon.appiconset\AppIconLight1024.png'; name = 'IconLight' }
)

foreach ($p in $pairs) {
  $dir = 'ChameleonUltra\Assets.xcassets\' + $p.name + '.appiconset'
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $img = [System.Drawing.Image]::FromFile((Resolve-Path $p.master))
  foreach ($px in @(20,29,40,58,60,76,80,87,120,152,167,180,1024)) {
    $bmp = New-Object System.Drawing.Bitmap($px, $px)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.DrawImage($img, (New-Object System.Drawing.Rectangle(0,0,$px,$px)))
    $g.Dispose()
    $bmp.Save((Join-Path (Get-Location) ($dir + '\' + $p.name + '-' + $px + '.png')), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
  }
  $img.Dispose()
  # ascii (not UTF8) — Set-Content -Encoding UTF8 emits a BOM that actool's JSON parser rejects
  ($contents -creplace 'NAME', $p.name) | Set-Content -Path ($dir + '\Contents.json') -Encoding ascii
  Write-Output ($p.name + ' set done')
}
