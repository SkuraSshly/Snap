param([string]$OutputDirectory = (Join-Path $PSScriptRoot '../bin/setup'), [switch]$Tests)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$project = [xml](Get-Content -LiteralPath (Join-Path $root 'src/Velos.App/Velos.App.csproj') -Raw)
$version = [string]$project.Project.PropertyGroup.Version
$fileVersion = [string]$project.Project.PropertyGroup.FileVersion
if ($version -notmatch '^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$') { throw '版本格式错误' }
$buildInfo = @"
namespace Velos.Setup { internal static class BuildInfo {
 internal const string Version = "$version";
 internal const string FileVersion = "$fileVersion";
 internal const string Tag = "windows-v$version";
 internal const string ReleaseUrl = "https://github.com/SkuraSshly/Velos/releases/tag/" + Tag;
 internal const string DownloadRoot = "https://github.com/SkuraSshly/Velos/releases/download/" + Tag + "/";
} }
"@
$info = Join-Path $output 'BuildInfo.cs'
[IO.File]::WriteAllText($info, $buildInfo, [Text.UTF8Encoding]::new($false))
$framework = Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319'
$csc = Join-Path $framework 'csc.exe'
$references = @('System.dll','System.Core.dll','System.Net.Http.dll','System.Web.Extensions.dll','System.Drawing.dll','System.Windows.Forms.dll') | ForEach-Object { '/reference:' + (Join-Path $framework $_) }
$core = @('DownloadClient.cs','Installation.cs','WindowsIntegration.cs') | ForEach-Object { Join-Path $root "setup/$_" }
if ($Tests) {
    $exe = Join-Path $output 'Setup.Tests.exe'
    & $csc /nologo /target:exe /platform:x86 /langversion:5 /codepage:65001 /optimize+ "/out:$exe" @references $info @core (Join-Path $root 'setup/SetupTests.cs')
} else {
    $exe = Join-Path $output 'Velos-Setup.exe'
    $resources = @("/resource:$(Join-Path $root '../LICENSE'),Velos.License", "/resource:$(Join-Path $root 'src/Velos.App/Assets/Shared/wordmark-3x.png'),Velos.Wordmark")
    & $csc /nologo /target:winexe /platform:x86 /langversion:5 /codepage:65001 /optimize+ "/out:$exe" "/win32icon:$(Join-Path $root 'src/Velos.App/Assets/Velos.ico')" "/win32manifest:$(Join-Path $root 'src/Velos.App/app.manifest')" @references @resources $info @core (Join-Path $root 'setup/NativeControls.cs') (Join-Path $root 'setup/SetupForm.cs')
}
if ($LASTEXITCODE -ne 0) { throw '安装程序编译失败' }
Write-Output $exe
