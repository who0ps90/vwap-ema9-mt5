param(
    [string]$MetaEditor = 'C:\Program Files\XM Global MT5\MetaEditor64.exe'
)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath $MetaEditor)) { throw "MetaEditor not found: $MetaEditor" }
$taskBuild = Join-Path $taskRoot 'build'
New-Item -ItemType Directory -Force -Path $taskBuild | Out-Null
$taskSources = @(
    'MQL5\Experts\XauVwapEma9\XauVwapEma9.mq5',
    'MQL5\Scripts\XauVwapEma9\CoreTests.mq5',
    'MQL5\Scripts\XauVwapEma9\ExportUsdNews.mq5'
)
foreach ($taskRelative in $taskSources) {
    $taskSource = Join-Path $taskRoot $taskRelative
    $taskName = [IO.Path]::GetFileNameWithoutExtension($taskSource)
    $taskLog = Join-Path $taskBuild ($taskName + '.log')
    $taskArgs = @('/compile:"' + $taskSource + '"', '/log:"' + $taskLog + '"')
    $taskProcess = Start-Process -FilePath $MetaEditor -ArgumentList $taskArgs -WindowStyle Hidden -PassThru
    if (-not $taskProcess.WaitForExit(30000)) { throw "Compiler timeout for $taskName; inspect process $($taskProcess.Id)." }
    if (-not (Test-Path -LiteralPath $taskLog)) { throw "Compiler produced no log for $taskName." }
    $taskText = Get-Content -LiteralPath $taskLog -Raw
    if ($taskText -notmatch 'Result: 0 errors, 0 warnings,') { throw "Compilation failed or warned for $taskName`n$taskText" }
    $taskBinary = [IO.Path]::ChangeExtension($taskSource, '.ex5')
    if (-not (Test-Path -LiteralPath $taskBinary)) { throw "Compiled binary missing for $taskName." }
    Write-Output "$taskName : 0 errors, 0 warnings"
}
