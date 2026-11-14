param(
    [Parameter(Mandatory=$true)][string]$VerificationRoot,
    [string]$AdditionalRoot,
    [string]$RecordingRoot,
    [string]$LongRoot,
    [string]$ReferenceRoot
)
$ErrorActionPreference = 'Stop'
if (-not $ReferenceRoot) { $ReferenceRoot = Join-Path $PSScriptRoot '../bin/dev/references/docs/界面参考' }
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase
$VerificationRoot = (Resolve-Path -LiteralPath $VerificationRoot).Path
$ReferenceRoot = (Resolve-Path -LiteralPath $ReferenceRoot).Path
$output = Join-Path $VerificationRoot '对照'
New-Item -ItemType Directory -Path $output -Force | Out-Null
function Read-Picture([string]$Path) {
    $image = [Windows.Media.Imaging.BitmapImage]::new()
    $image.BeginInit(); $image.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $image.UriSource = [Uri]::new([IO.Path]::GetFullPath($Path)); $image.EndInit(); $image.Freeze()
    return $image
}
function Paint-Text($Context, [string]$Text, [double]$X, [double]$Y, [double]$Size) {
    $font = [Windows.Media.Typeface]::new('Microsoft YaHei UI')
    $textObject = [Windows.Media.FormattedText]::new($Text, [Globalization.CultureInfo]::GetCultureInfo('zh-CN'), [Windows.FlowDirection]::LeftToRight,
        $font, $Size, [Windows.Media.BrushConverter]::new().ConvertFromString('#5C4533'), 1.0)
    $Context.DrawText($textObject, [Windows.Point]::new($X, $Y))
}
function Save-Picture($Visual, [int]$Width, [int]$Height, [string]$Path) {
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new($Width, $Height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($Visual)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new(); $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create($Path)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    return $bitmap
}
function Find-Picture([string]$Group, [string]$Name) {
    $search = Join-Path $VerificationRoot ('x64/' + $Group)
    if ($AdditionalRoot -and $Group -in @('recording','translation')) { $search = Join-Path $AdditionalRoot ('x64/' + $Group) }
    if ($RecordingRoot -and $Group -eq 'recording') { $search = Join-Path $RecordingRoot ('x64/' + $Group) }
    if ($LongRoot -and $Group -eq 'long') { $search = Join-Path $LongRoot ('x64/' + $Group) }
    return (Get-ChildItem -LiteralPath $search -Filter $Name -Recurse -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}
$gallery = @()
function Compare-Picture([string]$Name, [string]$Source, [string]$Result, [switch]$Featured) {
    if (-not $Result) { throw "没有自测图片：$Name" }
    $left = Read-Picture (Join-Path $ReferenceRoot $Source); $right = Read-Picture $Result
    $leftHeight = [Math]::Round($left.PixelHeight * 780 / $left.PixelWidth); $rightHeight = [Math]::Round($right.PixelHeight * 780 / $right.PixelWidth)
    $height = [int]([Math]::Max($leftHeight, $rightHeight) + 90)
    $visual = [Windows.Media.DrawingVisual]::new(); $dc = $visual.RenderOpen()
    try {
        $dc.DrawRectangle([Windows.Media.BrushConverter]::new().ConvertFromString('#F3EEE8'), $null, [Windows.Rect]::new(0, 0, 1620, $height))
        Paint-Text $dc $Name 20 6 22; Paint-Text $dc 'Mac 参考' 20 42 17; Paint-Text $dc 'Windows 合成自测' 820 42 17
        $dc.DrawImage($left, [Windows.Rect]::new(20, 76, 780, $leftHeight)); $dc.DrawImage($right, [Windows.Rect]::new(820, 76, 780, $rightHeight))
    } finally { $dc.Close() }
    $picture = Save-Picture $visual 1620 $height (Join-Path $output ($Name + '.png'))
    if ($Featured) { $script:gallery += $picture }
}
foreach ($dark in @($false, $true)) {
    $suffix = if ($dark) { '深色' } else { '浅色' }; $folder = if ($dark) { '设置-深色' } else { '设置' }; $tail = if ($dark) { '-dark' } else { '' }
    foreach ($entry in @(@('通用','general','long','通用'), @('快捷键','hotkeys','long','快捷键'), @('截图设置','screenshot','long','截图设置'), @('长截图设置','screenshot-bottom','long','长截图设置'),
        @('录屏设置','recording','recording','录屏设置'), @('录屏设置底部','recording-bottom','recording','录屏设置底部'), @('翻译设置','translate','translation','翻译设置'), @('翻译设置底部','translate-bottom','translation','翻译设置底部'))) {
        Compare-Picture ($entry[0] + '-' + $suffix) ($folder + '/settings-' + $entry[1] + $tail + '.png') (Find-Picture $entry[2] ($entry[3] + '-' + $suffix + '.png')) -Featured:($entry[0] -in @('录屏设置','翻译设置'))
    }
    foreach ($entry in @(@('录屏选区','录屏/01-框选录制区域.png'), @('录屏中','录屏/02-录制控制条与红框.png'), @('录屏倒计时','录屏/03-倒计时.png'))) {
        Compare-Picture ($entry[0] + '-' + $suffix) $entry[1] (Find-Picture 'recording' ($entry[0] + '-' + $suffix + '.png')) -Featured:($entry[0] -eq '录屏中')
    }
    Compare-Picture ('录屏缩略图-' + $suffix) '截图/22-演示-缩略图.png' (Find-Picture 'recording' ('录屏缩略图-' + $suffix + '.png'))
    Compare-Picture ('混合缩略图-' + $suffix) '截图/22-演示-缩略图.png' (Find-Picture 'recording' ('混合缩略图-' + $suffix + '.png'))
    foreach ($entry in @(@('翻译选区','01-框选.png'), @('翻译识别中','02-识别中.png'), @('翻译结果','03-结果窗口.png'), @('翻译钉住','04-钉住.png'))) {
        Compare-Picture ($entry[0] + '-' + $suffix) ('截屏翻译/' + $entry[1]) (Find-Picture 'translation' ($entry[0] + '-' + $suffix + '.png')) -Featured:($entry[0] -eq '翻译结果')
    }
    foreach ($axis in @('竖向','回滚')) { Compare-Picture ('长截图-' + $axis + '-' + $suffix) '长截图/01-长截图界面.png' (Find-Picture 'long' ('长截图-' + $axis + '-' + $suffix + '.png')) }
    $group = if ($dark) { 'screenshot-dark' } else { 'screenshot-light' }
    foreach ($entry in @(@('放大镜','02-放大镜.png'), @('框选和标注','21-演示-标注.png'), @('缩略图','22-演示-缩略图.png'), @('编辑窗口','06-标注与工具栏.png'))) {
        Compare-Picture ($entry[0] + '-' + $suffix) ('截图/' + $entry[1]) (Find-Picture $group ($entry[0] + '.png'))
    }
}
$visual = [Windows.Media.DrawingVisual]::new(); $dc = $visual.RenderOpen(); $rows = [int][Math]::Ceiling($gallery.Count / 2)
try {
    $dc.DrawRectangle([Windows.Media.BrushConverter]::new().ConvertFromString('#E6DED5'), $null, [Windows.Rect]::new(0, 0, 1640, $rows * 570))
    for ($i = 0; $i -lt $gallery.Count; $i++) { $picture = $gallery[$i]; $ratio = [Math]::Min(800 / $picture.PixelWidth, 550 / $picture.PixelHeight)
        $dc.DrawImage($picture, [Windows.Rect]::new(10 + ($i % 2) * 820, 10 + [Math]::Floor($i / 2) * 570, $picture.PixelWidth * $ratio, $picture.PixelHeight * $ratio)) }
} finally { $dc.Close() }
$null = Save-Picture $visual 1640 ($rows * 570) (Join-Path $output '界面对照总览.png')
Write-Output $output
