param([Parameter(Mandatory)][string]$Helper)
$ErrorActionPreference = 'Stop'
. $Helper
function Assert-Recovery($Condition, [string]$Reason) { if (-not $Condition) { throw $Reason } }
function Wait-RunState([string]$Directory, [string]$Expected) {
    $watcher = [IO.FileSystemWatcher]::new($Directory, 'state.json'); $watcher.EnableRaisingEvents = $true
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    try {
        do {
            $value = Read-RunState $Directory
            if ($value.state -eq $Expected) { return $value }
            if ($value.state -in @('supervision_lost','supervision_error','failed')) { throw ($value | ConvertTo-Json -Depth 8 -Compress) }
            $null = $watcher.WaitForChanged([IO.WatcherChangeTypes]::All, 200)
        } while ([DateTime]::UtcNow -lt $deadline)
        throw ('Recovery did not reach ' + $Expected)
    } finally { $watcher.Dispose() }
}
$script:RunId = [guid]::NewGuid().ToString('D')
$directory = Get-RunDirectory $RunId; $null = [IO.Directory]::CreateDirectory($directory); $directory = Get-RunDirectory $RunId
$fixture = Join-Path $directory 'fixture.exe'
$owner = $null; $client = $null; $observer = $null; $lease = $null
try {
    # Real kernel job/client fixture. No application acceptance or task state is involved.
    $code = "using System.IO; using System.Diagnostics; using System.Reflection;`n" +
        [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $Helper) 'enterprise-job.cs')) + @'
public static class RecoveryFixture {
    private static void AwaitFile(string directory, string name) {
        using (var watcher = new FileSystemWatcher(directory, name)) {
            watcher.EnableRaisingEvents = true;
            while (!File.Exists(Path.Combine(directory, name))) watcher.WaitForChanged(WatcherChangeTypes.All, 1000);
        }
    }
    public static void Main(string[] args) {
        if (args[0] == "client") { AwaitFile(args[1], "client-release"); return; }
        using (var job = new VanessaRunner.ProcessJob(args[2])) {
            job.BindCurrentProcess();
            var child = Process.Start(Assembly.GetExecutingAssembly().Location, "client \"" + args[1] + "\"");
            File.WriteAllText(Path.Combine(args[1], "client.pid"), child.Id.ToString());
            AwaitFile(args[1], "observer-release");
        }
    }
}
'@
    Add-Type -OutputAssembly $fixture -OutputType ConsoleApplication -TypeDefinition $code
    $jobName = Get-RunJobName $RunId
    $owner = Start-IndependentProcess ('"' + $fixture + '" owner "' + $directory + '" ' + $jobName) $directory
    $ready = [IO.FileSystemWatcher]::new($directory, 'client.pid'); $ready.EnableRaisingEvents = $true
    try {
        if (-not [IO.File]::Exists((Join-Path $directory 'client.pid'))) { $null = $ready.WaitForChanged([IO.WatcherChangeTypes]::All, 10000) }
        $client = Get-Process -Id ([int][IO.File]::ReadAllText((Join-Path $directory 'client.pid')))
    } finally { $ready.Dispose() }
    $scenarioPath = Join-Path $directory 'scenario.status'; [IO.File]::WriteAllText($scenarioPath, '0')
    $state = [ordered]@{
        runId = $RunId; driverVersion = '0.3.2'; kind = 'vanessa'; ibpath = ''; statusPath = $scenarioPath
        processTracking = 'named_windows_job'; jobName = $jobName; activeProcessCount = 1
        sessionId = $owner.SessionId; bootTicks = Get-HostBootTicks
        state = 'running'; scenarioStatus = 'pending'; cleanupStatus = 'running'; result = 'pending'; failureReason = $null
        pid = $client.Id; startTicks = $client.StartTime.ToUniversalTime().Ticks.ToString()
        windowVisible = $false; windowSeen = $false; windowTitle = ''; exitCode = $null; lastPlatformError = $null
        observerPid = $owner.Id; observerStartTicks = $owner.StartTime.ToUniversalTime().Ticks.ToString(); observationError = $null
        recoveryStatus = 'not_requested'; recoveryProof = $null
        processes = @([pscustomobject]@{
            pid = $client.Id; role = 'manager'; startTicks = $client.StartTime.ToUniversalTime().Ticks.ToString()
            executable = $client.Path; state = 'running'; exitCode = $null; windowVisible = $false
        })
    }
    Write-RunJson (Join-Path $directory 'state.json') $state
    Start-JobLease $directory $state
    $leaseRecord = Read-RunJson (Join-Path $directory 'job-lease.json'); $lease = Get-Process -Id $leaseRecord.pid
    Assert-Recovery ($lease.StartTime.ToUniversalTime().Ticks.ToString() -eq $leaseRecord.startTicks) 'Lease process identity mismatch'
    [IO.File]::WriteAllText((Join-Path $directory 'observer-release'), '')
    Assert-Recovery ($owner.WaitForExit(10000)) 'Original observer did not finish'
    Assert-Recovery (-not $client.HasExited) 'Client must survive the original observer'
    Assert-Recovery ((Read-RunState $directory).state -eq 'supervision_lost') 'Loss must be visible before explicit recovery'
    $recovery = Invoke-RunRecovery $directory
    Assert-Recovery ($recovery.recoveryStatus -eq 'observer_restarted') 'Native recovery did not reopen the held group'
    $observer = Get-Process -Id $recovery.observerPid
    $observed = Wait-RunState $directory 'running'
    Assert-Recovery ($observed.activeProcessCount -gt 0 -and $observed.result -eq 'cleanup_pending') 'Passed status cannot finish a live client'
    Assert-Recovery ($observed.pid -eq $client.Id) 'Recovery launched or adopted another client'
    $repeat = Invoke-RunRecovery $directory
    Assert-Recovery ($repeat.observerPid -eq $observer.Id) 'Repeated recovery must keep the same observer'
    [IO.File]::WriteAllText((Join-Path $directory 'client-release'), '')
    $ended = Wait-RunState $directory 'exited'
    Assert-Recovery ($ended.activeProcessCount -eq 0 -and $ended.cleanupStatus -eq 'exited') 'Kernel cleanup is missing'
    Assert-Recovery ($ended.result -eq 'passed') 'Observed zero exit and passed fixture status should complete the lifecycle fixture'
    Assert-Recovery ($observer.WaitForExit(10000) -and $lease.WaitForExit(10000)) 'Recovery observer and lease must finish without being killed'
    $leaseEnded = Read-RunJson (Join-Path $directory 'job-lease.json')
    Assert-Recovery ($leaseEnded.state -eq 'exited' -and $leaseEnded.activeProcessCount -eq 0) 'Independent lease must record actual kernel cleanup'
} catch {
    Get-ChildItem -LiteralPath $directory -Filter '*.json' | ForEach-Object { [Console]::Error.WriteLine([IO.File]::ReadAllText($_.FullName)) }
    throw
} finally {
    [IO.File]::WriteAllText((Join-Path $directory 'observer-release'), '')
    [IO.File]::WriteAllText((Join-Path $directory 'client-release'), '')
    foreach ($process in @($owner,$client,$observer,$lease)) {
        if ($null -ne $process) {
            if (-not $process.WaitForExit(15000)) { throw 'Recovery fixture still alive; keep its owned directory' }
            $process.Dispose()
        }
    }
    $parent = Split-Path -Parent (Get-RunDirectory $RunId)
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($directory)) -ne $parent) { throw 'Unexpected fixture cleanup path' }
    Remove-Item -LiteralPath $directory -Recurse
}
'PASS: native observer loss/recovery, independent job lease, same live client, repeated recovery keeps owner, actual cleanup, no relaunch'

# An actual native launch refusal must also release its group and lease.
$script:RunId = [guid]::NewGuid().ToString('D'); $script:Action = 'launch'
$script:SpecPath = [IO.Path]::GetTempFileName()
$directory = Get-RunDirectory $RunId; $refusedObserver = $null
try {
    Write-RunJson $SpecPath @{ commandLine = 'not-a-1c-executable invalid'; kind = 'vanessa'; ibpath = ''; statusPath = '' }
    $launched = Invoke-EnterpriseRun
    $refusedObserver = Get-Process -Id $launched.observerPid
    $directory = Get-RunDirectory $RunId
    $refused = Wait-RunState $directory 'failed'
    Assert-Recovery ($refused.cleanupStatus -eq 'exited' -and $refused.activeProcessCount -eq 0) 'Pre-launch refusal must confirm actual cleanup'
    Assert-Recovery ($refused.result -eq 'failed' -and -not $refused.pid) 'Refused executable must not launch or pass a client'
    Assert-Recovery ($refusedObserver.WaitForExit(10000)) 'Refused launch observer must exit'
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $leaseState = Read-RunJson (Join-Path $directory 'job-lease.json')
        if ($leaseState.state -eq 'exited') { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert-Recovery ($leaseState.state -eq 'exited') 'Refused launch must release the independent lease'
} catch {
    [Console]::Error.WriteLine($_.Exception.ToString())
    throw
} finally {
    $directory = Get-RunDirectory $RunId
    if ($null -ne $refusedObserver) {
        if (-not $refusedObserver.WaitForExit(15000)) { throw 'Refused launch observer still alive; keep its owned directory' }
        $refusedObserver.Dispose()
    }
    Remove-Item -LiteralPath $SpecPath
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($directory)) -ne (Split-Path -Parent (Get-RunDirectory $RunId))) { throw 'Unexpected refused run cleanup path' }
    if ([IO.Directory]::Exists($directory)) { Remove-Item -LiteralPath $directory -Recurse }
}
'PASS: native launch refusal releases observer, kernel group and independent lease; no 1C process created'
