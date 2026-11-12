param([Parameter(Mandatory)][string]$Helper, [ValidateSet("pending","failed")][string]$ScenarioStatus = "pending")
$ErrorActionPreference = 'Stop'
. $Helper
function Assert-Cancellation($Condition, [string]$Reason) { if (-not $Condition) { throw $Reason } }
$script:RunId = [guid]::NewGuid().ToString('D')
$directory = Get-RunDirectory $RunId
$null = [IO.Directory]::CreateDirectory($directory)
$directory = Get-RunDirectory $RunId
$foreignRoot = Join-Path $directory 'foreign'
$null = [IO.Directory]::CreateDirectory($foreignRoot)
$job = $null; $owner = $null; $foreign = $null
try {
    $code = "using System.IO; using System.Diagnostics; using System.Reflection;`n" +
        [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $Helper) 'enterprise-job.cs')) + @"
public static class CancellationFixture {
    public static void Main(string[] args) {
        string directory = args[1];
        if (args[0] == "owner") {
            using (var job = new VanessaRunner.ProcessJob(args[2])) {
                job.BindCurrentProcess();
                var child = Process.Start(Assembly.GetExecutingAssembly().Location, "child \"" + directory + "\"");
                File.WriteAllText(Path.Combine(directory, "ready"), child.Id.ToString());
                Wait(directory);
            }
        } else { Wait(directory); }
    }
    private static void Wait(string directory) {
        using (var watcher = new FileSystemWatcher(directory, "release")) {
            watcher.EnableRaisingEvents = true;
            while (!File.Exists(Path.Combine(directory, "release"))) watcher.WaitForChanged(WatcherChangeTypes.All, 1000);
        }
    }
}
"@
    $fixture = Join-Path $directory 'cancel-fixture.exe'
    Add-Type -TypeDefinition $code -OutputAssembly $fixture -OutputType ConsoleApplication
    $name = Get-RunJobName $RunId
    $foreign = Start-IndependentProcess ('"' + $fixture + '" child "' + $foreignRoot + '"') $directory
    $owner = Start-IndependentProcess ('"' + $fixture + '" owner "' + $directory + '" "' + $name + '"') $directory
    $ready = Join-Path $directory 'ready'
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not [IO.File]::Exists($ready)) {
        if ($owner.HasExited -or [DateTime]::UtcNow -gt $deadline) { throw 'Cancellation fixture failed to launch' }
        Start-Sleep -Milliseconds 20
    }
    $childId = [int][IO.File]::ReadAllText($ready)
    $job = [VanessaRunner.ProcessJob]::OpenForCancellation($name)
    Assert-Cancellation ($job.Contains($owner.Handle)) 'Only the fixture owner enters its job'
    Assert-Cancellation (-not $job.Contains($foreign.Handle)) 'External fixture is outside the cancelled job'
    $state = @{
        runId = $RunId; jobName = $name; state = 'running'; result = 'pending'
        observerPid = $owner.Id; observerStartTicks = $owner.StartTime.ToUniversalTime().Ticks.ToString()
        scenarioStatus = $ScenarioStatus; cleanupStatus = 'running'; activeProcessCount = 2
        ibpath = $directory; failureReason = $null; observationError = $null
        windowVisible = $false; lastPlatformError = $null
        processes = @(@{ pid = $owner.Id; startTicks = $owner.StartTime.ToUniversalTime().Ticks.ToString(); state = 'running'; windowVisible = $false; exitCode = $null })
    }
    Write-RunJson (Join-Path $directory 'state.json') $state
    $answer = Invoke-RunCancellation $directory
    $expectedScenario = if ($ScenarioStatus -eq 'failed') { 'failed' } else { 'unknown' }
    Assert-Cancellation ($answer.result -eq 'failed' -and $answer.scenarioStatus -eq $expectedScenario) 'Cancellation never invents or erases a scenario verdict'
    Assert-Cancellation ($answer.cleanupStatus -eq 'exited' -and $answer.activeProcessCount -eq 0) 'Kernel confirms owned group empty'
    Assert-Cancellation ($answer.cancellationProof.runId -eq $RunId -and $answer.cancellationProof.jobName -eq $name) 'Proof refers to exact original run'
    Assert-Cancellation ($answer.cancellationProof.activeProcessCount -eq 0 -and $job.ProcessIds().Count -eq 0) 'Receipt follows kernel state'
    Assert-Cancellation ($owner.WaitForExit(10000) -and $answer.processes[0].exitCode -eq 1223) 'Retained owner handle supplies actual cancellation exit code'
    Assert-Cancellation ($null -eq (Get-Process -Id $childId -ErrorAction SilentlyContinue)) 'An inherited descendant is also cancelled'
    Assert-Cancellation (-not $foreign.HasExited) 'Unrelated live process survives'
    $again = Invoke-RunCancellation $directory
    Assert-Cancellation ($again.cancellationProof.observedAt -eq $answer.cancellationProof.observedAt) 'Repeated cancellation preserves terminal receipt'
    Write-RunJson (Join-Path $directory 'state.json') @{ runId=$RunId; jobName=(Get-RunJobName ([guid]::NewGuid().ToString('D'))); state='running' }
    $rejected = $false
    try { $null = Invoke-RunCancellation $directory } catch { $rejected = $_.Exception.Message -eq 'Cancellation requires this run owned named job' }
    Assert-Cancellation $rejected 'Foreign job identity is rejected'
    $job.Dispose(); $job = $null
    Write-RunJson (Join-Path $directory 'state.json') @{ runId=$RunId; jobName=$name; state='running' }
    $rejected = $false
    try { $null = Invoke-RunCancellation $directory } catch { $rejected = $_.Exception.Message -eq 'Cancellation cannot confirm an unavailable job' }
    Assert-Cancellation $rejected 'Missing named job never becomes an empty job claim'
} finally {
    [IO.File]::WriteAllText((Join-Path $directory 'release'), '')
    [IO.File]::WriteAllText((Join-Path $foreignRoot 'release'), '')
    if ($null -ne $job) { $job.Dispose() }
    foreach ($process in @($owner,$foreign)) {
        if ($null -ne $process) { if (-not $process.WaitForExit(10000)) { throw 'Owned test fixture did not finish' }; $process.Dispose() }
    }
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($directory)).TrimEnd('\') -ne (Split-Path -Parent (Get-RunDirectory $RunId)).TrimEnd('\')) { throw 'Unexpected cancellation fixture cleanup path' }
    Remove-Item -LiteralPath $directory -Recurse
}
Write-Host 'PASS: explicit cancellation kills only exact owned job; foreign process survives; no scenario success or unavailable-job cleanup invented'
