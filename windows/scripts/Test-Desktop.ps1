param(
    [ValidateSet('x64', 'x86')][string[]]$Architecture = @('x64', 'x86'),
    [string]$DotNet = 'dotnet',
    [switch]$SkipBuild,
    [switch]$MeasureIdle,
    [ValidateSet('stage1','screenshot-light','screenshot-dark','long','recording','translation','feature-audit')][string[]]$CasesToRun = @('stage1','screenshot-light','screenshot-dark','long','recording','translation','feature-audit')
)
$ErrorActionPreference = 'Stop'
Write-Output '接下来会顺序显示合成自测窗口；不采集真实屏幕或真实声音。'
if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Build-Velos.ps1') -DotNet $DotNet -Architecture $Architecture -Configuration Debug
    if ($LASTEXITCODE -ne 0) { throw 'Debug 构建失败。' }
}
$root = Join-Path $PSScriptRoot ('../bin/verification/' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $root | Out-Null
Write-Output ([IO.Path]::GetFullPath($root))
foreach ($target in $Architecture) {
    $app = Join-Path $PSScriptRoot "../src/Velos.App/bin/preview-Debug/win-$target/Velos.exe"
    $scenarios = @(
        @{Name='stage1'; Flag='--self-test'},
        @{Name='screenshot-light'; Flag='--screenshot-self-test'},
        @{Name='screenshot-dark'; Flag='--screenshot-self-test'; Dark=$true},
        @{Name='long'; Flag='--long-self-test'},
        @{Name='recording'; Flag='--recording-self-test'},
        @{Name='translation'; Flag='--translation-self-test'},
        @{Name='feature-audit'; Flag='--screenshot-self-test'; Extra='--feature-audit'}
    )
    foreach ($scenario in $scenarios) {
        if ($scenario.Name -notin $CasesToRun) { continue }
        $directory = Join-Path $root "$target/$($scenario.Name)"
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $arguments = @($scenario.Flag, $directory)
        if ($scenario.Extra) { $arguments += $scenario.Extra }
        $measure = $MeasureIdle -and $scenario.Name -in @('long', 'recording', 'translation')
        if ($measure) { $arguments += '--measure-idle' }
        if ($scenario.Dark) { $arguments += '--dark' }
        $process = Start-Process -FilePath $app -ArgumentList $arguments -PassThru -WindowStyle Normal
        $deadline = [DateTime]::UtcNow.AddSeconds(150)
        $measured = $false
        while (-not $process.WaitForExit(1000)) {
            if ([DateTime]::UtcNow -gt $deadline) { Stop-Process -Id $process.Id; throw "$target/$($scenario.Name) 超时。" }
            if ($measure -and -not $measured -and (Get-ChildItem -LiteralPath $directory -Filter '空闲就绪.txt' -Recurse)) {
                Start-Sleep -Seconds 3
                $process.Refresh(); $cpu = $process.TotalProcessorTime.TotalMilliseconds
                $watch = [Diagnostics.Stopwatch]::StartNew()
                $before = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -Filter "IDProcess=$($process.Id)"
                Start-Sleep -Seconds 20
                $process.Refresh()
                $after = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -Filter "IDProcess=$($process.Id)"
                [ordered]@{ PrivateWorkingSetMiBStart=[Math]::Round($before.WorkingSetPrivate/1MB,2); PrivateWorkingSetMiBEnd=[Math]::Round($after.WorkingSetPrivate/1MB,2);
                    CpuMilliseconds=[Math]::Round($process.TotalProcessorTime.TotalMilliseconds-$cpu,2); SampleSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,2) } |
                    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory '空闲资源.json') -Encoding utf8
                $measured = $true
            }
        }
        $process.Refresh()
        Get-ChildItem -LiteralPath $directory -Filter '结果.txt' -Recurse | ForEach-Object { Get-Content -LiteralPath $_.FullName }
        Write-Output "$target/$($scenario.Name) exit=$($process.ExitCode)"
        if ($process.ExitCode -ne 0) { throw "$target/$($scenario.Name) 自测失败。" }
    }
}
Write-Output '全部桌面自测通过。'
