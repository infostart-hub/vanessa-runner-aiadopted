param([Parameter(Mandatory)][string]$Helper)
$ErrorActionPreference = 'Stop'
. $Helper
$taskFixtureRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('VanessaRunner-discovery-' + [guid]::NewGuid().ToString('D'))
$StoreRoot = Join-Path $taskFixtureRoot 'VanessaRunner/runs'
$null = [IO.Directory]::CreateDirectory($StoreRoot)
$scenarioLog = Join-Path $taskFixtureRoot 'one/scenario.log'
function Add-FixtureRun([string]$Log) {
    $id = [guid]::NewGuid().ToString('D')
    $directory = Join-Path $StoreRoot $id
    $null = [IO.Directory]::CreateDirectory($directory)
    $parameters = Join-Path $directory 'parameters.json'
    Write-RunJson $parameters @{ ИмяФайлаЛогВыполненияСценариев = $Log }
    Write-RunJson (Join-Path $directory 'scenario-plan.json') @{ commandLine = '/C"StartFeaturePlayer;VBParams=' + $parameters + ';"' }
    Write-RunJson (Join-Path $directory 'state.json') @{ runId = $id; kind = 'vanessa'; scenarioStatus = 'pending'; cleanupStatus = 'running' }
    return $id
}
try {
    $expected = Add-FixtureRun $scenarioLog
    $foreign = Add-FixtureRun (Join-Path $taskFixtureRoot 'two/scenario.log')
    $receipt = Find-OwnedRunForScenarioLog $scenarioLog $StoreRoot
    if ($receipt.runId -ne $expected -or $receipt.launchDiscovery.scenarioLog -ne $scenarioLog -or $receipt.scenarioStatus -ne 'pending') { throw 'Discovery changed launch identity or claimed scenario success' }
    $missingRejected = $false
    try { $null = Find-OwnedRunForScenarioLog (Join-Path $taskFixtureRoot 'missing/scenario.log') $StoreRoot }
    catch { $missingRejected = $_.Exception.Message -match 'found 0' }
    if (-not $missingRejected) { throw 'Missing launch must refuse' }
    $duplicate = Add-FixtureRun $scenarioLog
    $ambiguousRejected = $false
    try { $null = Find-OwnedRunForScenarioLog $scenarioLog $StoreRoot }
    catch { $ambiguousRejected = $_.Exception.Message -match 'found 2' }
    if (-not $ambiguousRejected) { throw 'Ambiguous launch must refuse' }
    $Action = 'launch'; $RunId = $expected
    $repeatRejected = $false
    try { $null = Invoke-EnterpriseRun }
    catch { $repeatRejected = $_.Exception.Message -match 'already exists' }
    if (-not $repeatRejected) { throw 'Preallocated identity must forbid duplicate launch before reading launch plan' }
    Write-Host 'PASS: exact native launch discovery, ambiguity refusal, repeat launch refusal'
}
finally {
    $target = [IO.Path]::GetFullPath($taskFixtureRoot)
    $allowed = [IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\') + '\'
    if (-not $target.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($target) -notlike 'VanessaRunner-discovery-*') { throw 'Unsafe fixture cleanup target' }
    Remove-Item -LiteralPath $target -Recurse -Force
}
