param([string]$DotNet = 'dotnet', [switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Build-Velos.ps1') -DotNet $DotNet -Configuration Release
    if ($LASTEXITCODE -ne 0) { throw 'Release 构建失败' }
}
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$project = [xml](Get-Content -LiteralPath (Join-Path $root 'src/Velos.App/Velos.App.csproj') -Raw)
$version = [string]$project.Project.PropertyGroup.Version
$tag = 'windows-v' + $version
$output = Join-Path $root ('bin/setup-release/' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $output -ErrorAction Stop | Out-Null
$assets = [ordered]@{}
foreach ($arch in @('x64','x86')) {
    $name = "Velos-$version-win-$arch.exe"
    $built = Join-Path $root "src/Velos.App/bin/preview-Release/win-$arch/Velos.exe"
    if ((Get-Item -LiteralPath $built).VersionInfo.FileVersion -ne [string]$project.Project.PropertyGroup.FileVersion) { throw '程序版本与发布版本不一致' }
    $path = Join-Path $output $name
    Copy-Item -LiteralPath $built -Destination $path
    $assets[$arch] = [ordered]@{name=$name;url="https://github.com/SkuraSshly/Velos/releases/download/$tag/$name";size=(Get-Item -LiteralPath $path).Length;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
}
$setup = & (Join-Path $PSScriptRoot 'Build-Setup.ps1')
Copy-Item -LiteralPath $setup -Destination $output
$manifest = [ordered]@{schema=2;version=$version;tag=$tag;minimumWindowsBuild=19041;releaseUrl="https://github.com/SkuraSshly/Velos/releases/tag/$tag";assets=$assets} | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText((Join-Path $output 'Velos-Install.json'), $manifest, [Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath (Join-Path $root '../LICENSE') -Destination (Join-Path $output 'LICENSE.txt')
$hashes = Get-ChildItem -LiteralPath $output -File | Sort-Object Name | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $_.Name }
[IO.File]::WriteAllLines((Join-Path $output 'SHA256SUMS.txt'), [string[]]$hashes, [Text.UTF8Encoding]::new($false))
Write-Output $output
