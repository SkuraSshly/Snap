param(
    [ValidateSet('x64', 'x86')][string[]]$Architecture = @('x64', 'x86'),
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release',
    [string]$DotNet = 'dotnet'
)

$ErrorActionPreference = 'Stop'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$project = Join-Path $PSScriptRoot '../src/Velos.App/Velos.App.csproj'
& (Join-Path $PSScriptRoot 'New-VelosIcon.ps1')
foreach ($target in $Architecture) {
    $runtime = "win-$target"
    $destination = Join-Path $PSScriptRoot "../src/Velos.App/bin/preview-$Configuration/$runtime"
    $debugType = if ($Configuration -eq 'Debug') { 'embedded' } else { 'none' }
    & $DotNet publish $project -c $Configuration -r $runtime --self-contained true `
        -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true "-p:DebugType=$debugType" `
        -o $destination --nologo
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
