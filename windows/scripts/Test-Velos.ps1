param([string]$DotNet = 'dotnet')

$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
& $DotNet run --project (Join-Path $PSScriptRoot '../tests/Velos.Tests/Velos.Tests.csproj')
exit $LASTEXITCODE
