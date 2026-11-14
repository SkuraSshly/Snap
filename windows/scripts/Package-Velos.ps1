param(
    [ValidateSet('x64', 'x86')][string[]]$Architecture = @('x64', 'x86'),
    [string]$DotNet = 'dotnet',
    [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Build-Velos.ps1') -DotNet $DotNet -Architecture $Architecture -Configuration Release
    if ($LASTEXITCODE -ne 0) { throw 'Release 构建失败。' }
}
$windowsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$project = [xml](Get-Content -LiteralPath (Join-Path $windowsRoot 'src/Velos.App/Velos.App.csproj') -Raw)
$version = [string]$project.Project.PropertyGroup.Version
$output = Join-Path $windowsRoot ('bin/release/' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $output -ErrorAction Stop | Out-Null
$hashes = @()
foreach ($target in $Architecture) {
    $name = "Velos-$version-win-$target"
    $folder = Join-Path $output $name
    New-Item -ItemType Directory -Path $folder | Out-Null
    $exe = Join-Path $windowsRoot "src/Velos.App/bin/preview-Release/win-$target/Velos.exe"
    Copy-Item -LiteralPath $exe -Destination (Join-Path $folder 'Velos.exe')
    foreach ($document in @('README.md', 'Windows使用说明.md', '下载与发布说明.md', '卸载说明.md', '逐项功能检查.md', '改进记录.md', '移植行为对照.md', '2.3开发对照.md', '长图与翻译改进.md', 'Mac交互对齐.md', '完整流程测试.md')) {
        Copy-Item -LiteralPath (Join-Path $windowsRoot $document) -Destination $folder
    }
    $license = Join-Path $windowsRoot '../LICENSE'
    if (Test-Path -LiteralPath $license) { Copy-Item -LiteralPath $license -Destination (Join-Path $folder 'LICENSE') }
    $zip = Join-Path $output ($name + '.zip')
    Compress-Archive -LiteralPath (Get-ChildItem -LiteralPath $folder -File).FullName -DestinationPath $zip -CompressionLevel Optimal
    foreach ($artifact in @((Join-Path $folder 'Velos.exe'), $zip)) {
        $hash = Get-FileHash -LiteralPath $artifact -Algorithm SHA256
        $hashes += ($hash.Hash.ToLowerInvariant() + '  ' + $artifact.Substring($output.Length + 1))
    }
}
$hashes | Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS.txt') -Encoding utf8
Write-Output $output
