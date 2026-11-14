$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# 资源来自上游 c71628c 的 docs/界面参考/资源/App图标。
$source = Join-Path $PSScriptRoot '../src/Velos.App/Assets/AppIconSource'
$destination = Join-Path $PSScriptRoot '../src/Velos.App/Assets/Velos.ico'
$images = @{}
foreach ($size in 16, 32, 48, 64, 128, 256) {
    $images[$size] = [IO.File]::ReadAllBytes((Join-Path $source "icon-$size.png"))
}

$stream = [IO.MemoryStream]::new($images[32])
try {
    $bitmap = [Drawing.Bitmap]::new($stream)
    try {
        foreach ($size in 20, 24) {
            $small = [Drawing.Bitmap]::new($bitmap, $size, $size)
            $png = [IO.MemoryStream]::new()
            try {
                $small.Save($png, [Drawing.Imaging.ImageFormat]::Png)
                $images[$size] = $png.ToArray()
            }
            finally {
                $small.Dispose()
                $png.Dispose()
            }
        }
    }
    finally { $bitmap.Dispose() }
}
finally { $stream.Dispose() }

$null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
$file = [IO.BinaryWriter]::new([IO.File]::Create($destination))
try {
    $sizes = 32, 16, 20, 24, 48, 64, 128, 256
    $file.Write([uint16]0)
    $file.Write([uint16]1)
    $file.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    foreach ($size in $sizes) {
        $file.Write([byte]($size % 256))
        $file.Write([byte]($size % 256))
        $file.Write([uint16]0)
        $file.Write([uint16]1)
        $file.Write([uint16]32)
        $file.Write([uint32]$images[$size].Length)
        $file.Write([uint32]$offset)
        $offset += $images[$size].Length
    }
    foreach ($size in $sizes) { $file.Write([byte[]]$images[$size]) }
}
finally { $file.Dispose() }
