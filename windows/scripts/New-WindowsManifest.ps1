param([Parameter(Mandatory)][string]$ReleaseDirectory)
$ErrorActionPreference = 'Stop'
$project = [xml](Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/Velos.App/Velos.App.csproj') -Raw)
$version = [string]$project.Project.PropertyGroup.Version
$tag = 'windows-v' + $version
$assets = [ordered]@{}
foreach ($arch in @('x64','x86')) {
    $name = "Velos-$version-win-$arch.zip"
    $file = Get-Item -LiteralPath (Join-Path $ReleaseDirectory $name)
    $assets[$arch] = [ordered]@{name=$name;url="https://github.com/SkuraSshly/Velos/releases/download/$tag/$name";size=$file.Length;sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
}
$json = [ordered]@{schema=1;version=$version;tag=$tag;minimumWindowsBuild=19041;releaseUrl="https://github.com/SkuraSshly/Velos/releases/tag/$tag";assets=$assets} | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText((Join-Path $ReleaseDirectory 'Velos-Windows.json'), $json, [Text.UTF8Encoding]::new($false))
Write-Output (Join-Path $ReleaseDirectory 'Velos-Windows.json')
