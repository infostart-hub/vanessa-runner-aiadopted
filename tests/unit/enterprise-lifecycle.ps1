param([Parameter(Mandatory)][string]$Helper)
$ErrorActionPreference = 'Stop'
. $Helper
function Assert-Equal($Actual, $Expected, [string]$Because) {
    if ($Actual -ne $Expected) { throw "$Because : expected $Expected, got $Actual" }
}
$notice = 'Предупреждение безопасности' + "`n`n" + 'Открывается "Vanessa Automation single" из файла "C:\known\vanessa.epf".' + "`n`n" + 'Разрешить открывать данный файл?'
Assert-Equal (Test-RequestedProcessingNotice $notice 'C:\known\vanessa.epf') $true 'Consent belongs to the exact requested processing'
Assert-Equal (Test-RequestedProcessingNotice ($notice.Replace('Разрешить открывать данный файл?','Рекомендуется обратить внимание на источник, из которого был получен этот файл. Если нет согласия с источником или по каким-то причинам есть сомнения в надежности источника, то открывать файл не рекомендуется.' + "`n`n" + 'Разрешить открыть этот файл?')) 'C:\known\vanessa.epf') $true 'Extended 8.3.25+ opening notice with source warning belongs to the exact requested processing'
Assert-Equal (Test-RequestedProcessingNotice ($notice.Replace('Открывается "Vanessa Automation single" из файла "C:\known\vanessa.epf".','Открывается внешняя обработка "C:\known\vanessa.epf".')) 'C:\known\vanessa.epf') $true 'Direct external processing wording belongs to the exact requested processing'
Assert-Equal (Test-RequestedProcessingNotice $notice 'C:\foreign\vanessa.epf') $false 'A different processing must not receive consent'
Assert-Equal (Test-RequestedProcessingNotice $notice '') $false 'No requested processing grants no consent'
Assert-Equal (Test-RequestedProcessingNotice ($notice.Replace('Предупреждение безопасности','Ошибка')) 'C:\known\vanessa.epf') $false 'A platform error cannot become processing consent'
Assert-Equal (Test-RequestedProcessingNotice ($notice.Replace('Разрешить открывать данный файл?','Запустить другой файл?')) 'C:\known\vanessa.epf') $false 'Other questions are never accepted'
Assert-Equal (Get-RequestedProcessing '/Execute"C:\unknown.epf"' 'enterprise') $null 'General application launches do not acquire processing consent'

# Capability-specific grant never accepts another EPF or a different privilege.
$adminNotice = 'Предупреждение безопасности' + "`n`n" + 'Модуль "Vanessa Automation single" загруженный из "C:\known\vanessa.epf" хочет выполнить административные действия с пользователями информационной базы.' + "`n`n" + 'Разрешить администрировать пользователей для данного модуля?'
Assert-Equal (Test-RequestedProcessingCapabilityNotice $adminNotice 'C:\known\vanessa.epf' 'administer_users') $true 'Exact requested EPF administration can be explicitly authorized'
Assert-Equal (Test-RequestedProcessingCapabilityNotice ($adminNotice.Replace('загруженный из','загруженный из:')) 'C:\known\vanessa.epf' 'administer_users') $true 'Colon variant in module source notice is recognized for exact requested EPF'
Assert-Equal (Test-RequestedProcessingCapabilityNotice $adminNotice 'C:\foreign\vanessa.epf' 'administer_users') $false 'Foreign processing never receives administration permission'
Assert-Equal (Test-RequestedProcessingCapabilityNotice $adminNotice 'C:\known\vanessa.epf' 'open_processing') $false 'Opening approval cannot authorize administration'
Assert-Equal (Test-RequestedProcessingCapabilityNotice $notice 'C:\known\vanessa.epf' 'administer_users') $false 'Administration approval cannot approve a different notice'
Assert-Equal (Test-RequestedProcessingCapabilityNotice $adminNotice 'C:\known\vanessa.epf' 'arbitrary') $false 'Unknown privileges are refused'

$acknowledgement = 'Текущее выполнение действия было прервано для выдачи предупреждения. Вы подтвердили выполнение действия для данного модуля. В дальнейшем это действие для данного модуля будет выполняться без выдачи предупреждений. Просьба сейчас вызвать действие еще раз.'
Assert-Equal (Test-ProcessingAuthorizationAcknowledgement $acknowledgement) $true 'Native acknowledgement retains interruption and retry semantics'
Assert-Equal (Test-ProcessingAuthorizationAcknowledgement 'Ошибка: операция прервана') $false 'An arbitrary failure must not be dismissed as a consent acknowledgement'
Assert-Equal (Test-ProcessingAuthorizationAcknowledgement ($acknowledgement.Replace('Вы подтвердили','Вы отменили'))) $false 'Denied permission cannot become an acknowledged grant'

# Message-only window verifies scoped delivery without foreground/RDP input.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path (Join-Path (Split-Path -Parent $Helper) 'enterprise-consent.cs')
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Windows.Forms;
public sealed class ConsentQueueFixture : NativeWindow, IDisposable {
    public int down, up;
    public ConsentQueueFixture() {
        var parameters = new CreateParams();
        parameters.Parent = new IntPtr(-3);
        CreateHandle(parameters);
    }
    protected override void WndProc(ref Message message) {
        if (message.WParam == new IntPtr(0x20)) {
            if (message.Msg == 0x100) down++;
            if (message.Msg == 0x101) up++;
        }
        base.WndProc(ref message);
    }
    public void Dispose() { DestroyHandle(); }
}
"@
$queueFixture = [ConsentQueueFixture]::new()
try {
    foreach ($target in @(
        @{ pid = ($PID + 1); hwnd = $queueFixture.Handle },
        @{ pid = $PID; hwnd = [IntPtr]::Zero },
        @{ pid = $PID; hwnd = [IntPtr]::new(0xffff) }
    )) {
        $rejected = $false
        try { [VanessaRunner.ProcessingConsentInput]::Activate($target.pid, $target.hwnd) }
        catch { $rejected = $_.Exception.GetBaseException().Message -eq 'Consent window is not owned by the manager' }
        Assert-Equal $rejected $true 'Foreign, null and broadcast windows cannot receive consent input'
    }
    [Windows.Forms.Application]::DoEvents()
    Assert-Equal $queueFixture.down 0 'Rejected targets leave the owned queue untouched'
    [VanessaRunner.ProcessingConsentInput]::Activate($PID, $queueFixture.Handle)
    [Windows.Forms.Application]::DoEvents()
    Assert-Equal $queueFixture.down 1 'One key down reaches the owned background queue'
    Assert-Equal $queueFixture.up 1 'One key up reaches the owned background queue'
} finally { $queueFixture.Dispose() }


# Visible fixture verifies enumeration is process-scoped and excludes message-only HWNDs.
$form = [Windows.Forms.Form]::new()
$form.Text = 'VanessaRunner owned window fixture'
try {
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    $windows = [VanessaRunner.ProcessingConsentInput]::WindowsForProcess($PID)
    Assert-Equal ($windows -contains $form.Handle) $true 'Exact visible process window is enumerated'
    Assert-Equal ([VanessaRunner.ProcessingConsentInput]::DialogsForProcess($PID) -contains $form.Handle) $false 'Normal application window is not probed for a consent dialog'
    $dialog = [Windows.Forms.Form]::new()
    try {
        $dialog.Show($form)
        $form.Enabled = $false
        [Windows.Forms.Application]::DoEvents()
        Assert-Equal ([VanessaRunner.ProcessingConsentInput]::DialogsForProcess($PID) -contains $dialog.Handle) $true 'Exact modal owned surface can be queried for the requested control'
        $nested = [Windows.Forms.Form]::new()
        try {
            $nested.Show($dialog); $dialog.Hide(); [Windows.Forms.Application]::DoEvents()
            Assert-Equal ([VanessaRunner.ProcessingConsentInput]::DialogsForProcess($PID) -contains $nested.Handle) $true 'Visible modal over an invisible owned container retains disabled ancestor ownership'
        } finally { $nested.Close(); $nested.Dispose() }
        $dialog.Show($form)
        $form.Enabled = $false
        [Windows.Forms.Application]::DoEvents()
        Assert-Equal ([VanessaRunner.ProcessingConsentInput]::RequestClose($PID, $dialog.Handle)) $true 'Owned modal receives the same close request as the session root'

    } finally { $form.Enabled = $true; $dialog.Close(); $dialog.Dispose() }
    Assert-Equal ([VanessaRunner.ProcessingConsentInput]::WindowsForProcess([int]::MaxValue).Length) 0 'Foreign process cannot supply the owned window'
    # Reproduce destruction after native enumeration, before UIA observation.
    $processFixture = [Diagnostics.Process]::GetCurrentProcess()
    try {
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
        $windowHandle = $form.Handle
        Assert-Equal ((Get-OwnedAutomationWindow $processFixture $windowHandle).Current.ProcessId) $PID 'Live owned HWND retains its UIA identity'
        Assert-Equal ([VanessaRunner.ProcessingConsentInput]::WindowBelongsToProcess([int]::MaxValue, $windowHandle)) $false 'Foreign PID cannot claim a native HWND'
        $form.Close(); [Windows.Forms.Application]::DoEvents()
        Assert-Equal ([VanessaRunner.ProcessingConsentInput]::WindowBelongsToProcess($PID, $windowHandle)) $false 'Destroyed enumerated HWND is no longer owned'
        Assert-Equal @(Get-OwnedAutomationWindow $processFixture $windowHandle).Count 0 'Closed HWND does not lose observation of the whole run'
    } finally { $processFixture.Dispose() }

} finally { $form.Close(); $form.Dispose() }

# Native endpoint is ready only for its real owner, not another process using that port.
Add-Type -Path (Join-Path (Split-Path -Parent $Helper) 'enterprise-endpoint.cs')
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
try {
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    Assert-Equal ([VanessaRunner.TestClientEndpoint]::OwnedListener($PID, $port)) $true 'Native listening endpoint is owned by this process'
    Assert-Equal ([VanessaRunner.TestClientEndpoint]::OwnedListener([int]::MaxValue, $port)) $false 'A foreign listener cannot make TestClient ready'
    Assert-Equal (Get-PreparedClientPort ('1cv8c.exe ENTERPRISE /TESTCLIENT -TPort ' + $port)) $port 'Native launch plan binds the exact requested endpoint'
    foreach ($command in @('1cv8c.exe ENTERPRISE', '1cv8c.exe /TESTCLIENT -TPort 0', '1cv8c.exe /TESTCLIENT -TPort 48000 -TPort 48001')) {
        $rejected = $false
        try { Get-PreparedClientPort $command | Out-Null } catch { $rejected = $true }
        Assert-Equal $rejected $true 'Missing, invalid or ambiguous transport refuses preparation'
    }
} finally { $listener.Stop() }
Assert-Equal ([VanessaRunner.TestClientEndpoint]::OwnedListener($PID, $port)) $false 'Closed endpoint no longer claims readiness'

$manager = [pscustomobject]@{ state = 'exited'; exitCode = 0 }
$client = [pscustomobject]@{ state = 'running'; exitCode = $null }
$unknownClient = Get-RunOutcome @($manager) 'vanessa' 'passed' $true 1
Assert-Equal $unknownClient.result 'cleanup_pending' 'An unobserved job descendant prevents false success'
Assert-Equal $unknownClient.cleanupStatus 'close_pending' 'Manager-only registry cannot prove cleanup'

$result = Get-RunOutcome @($manager, $client) 'vanessa' 'passed' $false
Assert-Equal $result.result 'cleanup_pending' 'Passed steps do not prove client exit'
Assert-Equal $result.state 'running' 'Manager exit must not hide a live client'
$namedManager = [pscustomobject]@{ role = 'manager'; state = 'exited'; exitCode = 0 }
$namedClient = [pscustomobject]@{ role = 'client'; state = 'running'; exitCode = $null }
$unsettledManagerExit = Get-RunOutcome @($namedManager, $namedClient) 'vanessa' 'pending' $false
Assert-Equal $unsettledManagerExit.result 'cleanup_pending' 'Manager exit without scenario.status still transitions to cleanup'
Assert-Equal $unsettledManagerExit.cleanupStatus 'close_pending' 'Live client enters close_pending when manager exits'
$result = Get-RunOutcome @($manager, $client) 'vanessa' 'passed' $true
Assert-Equal $result.state 'close_pending' 'A close request is not process exit'
$client.state = 'exited'; $client.exitCode = 0
Assert-Equal (Get-RunOutcome @($manager, $client) 'vanessa' 'passed' $true).result 'passed' 'Both processes and steps completed'
foreach ($scenario in @('missing','pending','invalid','unreadable','failed')) {
    Assert-Equal (Get-RunOutcome @($manager, $client) 'vanessa' $scenario $false).result 'failed' 'Exit zero alone cannot pass Vanessa'
}
$client.exitCode = 1
Assert-Equal (Get-RunOutcome @($manager, $client) 'vanessa' 'passed' $false).result 'failed' 'Client crash fails the run'
$client.exitCode = $null
Assert-Equal (Get-RunOutcome @($manager, $client) 'vanessa' 'passed' $false).result 'failed' 'Unknown exit code cannot pass'
$client.exitCode = 0
$silent = Get-RunOutcome @($manager, $client) 'enterprise' 'not_applicable' $false 0 $false
Assert-Equal $silent.result 'failed' 'An enterprise client that exits before showing a window is a failed launch'
Assert-Equal $silent.failureReason 'exited_before_window' 'The silent exit names its reason'
Assert-Equal (Get-RunOutcome @($manager, $client) 'enterprise' 'not_applicable' $false 0 $true).result 'passed' 'A window that was shown and then closed is a completed session'
Assert-Equal (Get-RunOutcome @($manager, $client) 'enterprise' 'not_applicable' $true 0 $false).result 'passed' 'A stop requested before the window appears is not a launch failure'
$client.exitCode = 1
Assert-Equal (Get-RunOutcome @($manager, $client) 'enterprise' 'not_applicable' $false 0 $true).failureReason 'bad_exit' 'A crash after the window is reported as a bad exit'
$client.exitCode = 0
Assert-Equal (Get-RunOutcome @($manager, $client) 'vanessa' 'failed' $false).failureReason 'scenario_failed' 'A failed scenario names the scenario status'
Assert-Equal (Get-LastEventLogError '') $null 'No infobase path yields no platform error'
try { Get-RunDirectory '..\foreign'; throw 'Invalid runId was accepted' } catch { if ($_.Exception.Message -ne 'Invalid runId') { throw } }
$directory = Join-Path ([IO.Path]::GetTempPath()) ('vr-lifecycle-check-' + [guid]::NewGuid())
$null = [IO.Directory]::CreateDirectory($directory)
try {
    $status = Join-Path $directory 'scenario.status'
    Assert-Equal (Get-ScenarioStatus $status $false) 'pending' 'Fresh status is pending'
    Assert-Equal (Get-ScenarioStatus $status $true) 'missing' 'Missing final result fails'
    foreach ($sample in @(@('0','passed'), @('1','failed'), @('2','failed'), @('3','failed'), @('nonsense','invalid'), @('','invalid'))) {
        [IO.File]::WriteAllText($status, $sample[0])
        Assert-Equal (Get-ScenarioStatus $status $true) $sample[1] 'Exact Vanessa status interpretation'
    }
    Assert-Equal (Get-LastEventLogError $directory) $null 'A base without an event log yields no platform error'
    $logDirectory = Join-Path $directory '1Cv8Log'
    $null = [IO.Directory]::CreateDirectory($logDirectory)
    $sampleLog = @'
{20260921133715,C,
{245665f9a4db0,1ad18},1,1,2,1,10,I,"",0,
{"U"},"",0,0,0,1,0,
{2,1,1,2,1},0},
{20260921133715,N,
{0,0},1,1,2,1,14,E,"Файл поставки не предназначен для баз ""по шаблону"".
{ОбщийМодуль.Пример.Модуль(91)}: ВызватьИсключение",0,
{"U"},"",0,0,0,1,0,
{2,1,1,2,1},0},
{20260921133715,N,
{0,0},1,1,2,1,3,I,"",0,
{"U"},"",0,0,0,1,0,
{2,1,1,2,1},0}
'@
    [IO.File]::WriteAllText((Join-Path $logDirectory '20260921000000.lgp'), $sampleLog, [Text.UTF8Encoding]::new($false))
    $platformError = Get-LastEventLogError $directory
    Assert-Equal ($platformError.StartsWith('Файл поставки не предназначен для баз "по шаблону".')) $true 'The last E record is returned with its quotes unescaped'
    Assert-Equal ($platformError.Contains('ВызватьИсключение')) $true 'The multi-line record body is kept'
    $state = Join-Path $directory 'state.json'
    Write-RunJson $state @{ runId = [guid]::NewGuid().ToString(); state = 'running'; result = 'pending' }
    Write-RunJson $state @{ state = 'exited'; result = 'passed' }
    Assert-Equal (Read-RunJson $state).result 'passed' 'Atomic state replacement remains readable'
    $lock = [IO.File]::Open($state, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    $reader = [Management.Automation.PowerShell]::Create().AddScript({ param($Helper, $Path) . $Helper; Start-Sleep -Milliseconds 300; (Read-RunJson $Path).result }).AddArgument($Helper).AddArgument($state)
    $pending = $reader.BeginInvoke()
    Start-Sleep -Milliseconds 400
    $lock.Dispose()
    Assert-Equal ($reader.EndInvoke($pending) | Select-Object -First 1) 'passed' 'A read that meets the atomic replace lock waits instead of failing'
    $reader.Dispose()
    # Exercise the unavailable pathname seen during Windows replacement, not only sharing locks.
    [IO.File]::Delete($state)
    $writer = [Management.Automation.PowerShell]::Create().AddScript({
        param($Helper, $Path)
        . $Helper
        Start-Sleep -Milliseconds 150
        Write-RunJson $Path @{ state = 'exited'; result = 'passed' }
    }).AddArgument($Helper).AddArgument($state)
    $pendingWrite = $writer.BeginInvoke()
    try {
        Assert-Equal (Read-RunJson $state).result 'passed' 'A transient missing pathname is retried until the actual record is readable'
        $null = $writer.EndInvoke($pendingWrite)
    } finally { $writer.Dispose() }
    [IO.File]::Delete($state)
    $missingRejected = $false
    try { Read-RunJson $state | Out-Null } catch [IO.IOException] { $missingRejected = $true }
    Assert-Equal $missingRejected $true 'A persistently absent record still fails instead of supplying an invented result'
    Write-RunJson $state @{ state = 'running'; result = 'pending'; observerPid = $PID; observerStartTicks = '0'; observationError = $null }
    Assert-Equal (Read-RunState $directory).state 'supervision_lost' 'PID reuse must not adopt another supervisor'
    $old = [pscustomobject]@{
        runId = [guid]::NewGuid().ToString('D'); state = 'supervision_lost'; result = 'unknown'
        observerPid = [int]::MaxValue; observerStartTicks = '200'; ibpath = $directory; activeProcessCount = 2; cleanupStatus = 'running'; scenarioStatus = 'passed'
        failureReason = $null; windowVisible = $true; observationError = 'lost'; processes = @(
            [pscustomobject]@{ pid = ([int]::MaxValue - 1); startTicks = '200'; executable = $Helper; state = 'running'; exitCode = $null; windowVisible = $true }
        )
    }
    $resource = Join-Path $directory '1Cv8.1CD'
    [IO.File]::WriteAllText($resource, 'owned-database-fixture')
    $held = [IO.File]::Open($resource, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    try {
        $sameBoot = Resolve-LostRunCleanup $old '100'
        Assert-Equal $sameBoot.recoveryStatus 'resource_busy' 'A held database cannot release the lost run'
        Assert-Equal $sameBoot.activeProcessCount 2 'Unobserved group count is not invented'
    } finally { $held.Dispose() }
    $released = Resolve-LostRunCleanup $old '100'
    Assert-Equal $released.cleanupStatus 'released' 'Exclusive access releases the owned database without OS restart'
    Assert-Equal $released.activeProcessCount $null 'Resource release does not claim an empty historical job'
    Assert-Equal $released.result 'failed' 'Resource release cannot pass an unobserved scenario'
    Assert-Equal $released.scenarioStatus 'unknown' 'Historical passed status is not acceptance'
    Assert-Equal $released.recoveryProof.kind 'infobase_exclusive' 'Native owner records the actual file claim'
    Assert-Equal ([IO.File]::ReadAllText($resource)) 'owned-database-fixture' 'Release does not alter the database'
    $old.processes[0].pid = $PID
    $old.processes[0].startTicks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks.ToString()
    $old.processes[0].executable = (Get-Process -Id $PID).Path
    Assert-Equal (Resolve-LostRunCleanup $old '100').recoveryStatus 'owned_processes_running' 'A live owned identity prevents release'
    $old.processes[0].startTicks = '200'
    Assert-Equal (Resolve-LostRunCleanup $old '100').recoveryStatus 'resources_released' 'A reused PID is not adopted or terminated'

    $afterBoot = Resolve-LostRunCleanup $old '300'
    Assert-Equal $afterBoot.cleanupStatus 'exited' 'A later OS boot proves previous processes exited'
    Assert-Equal $afterBoot.result 'failed' 'Cleanup proof never passes an unobserved scenario'
    Assert-Equal $afterBoot.scenarioStatus 'unknown' 'Old passed status is not accepted after observation loss'
    Assert-Equal $afterBoot.processes[0].exitCode $null 'Recovery never invents an exit code'
    Assert-Equal $afterBoot.recoveryProof.kind 'host_restarted' 'The native result records its OS proof'
    if (-not ('VanessaRunner.ProcessJob' -as [type])) { Add-Type -Path (Join-Path (Split-Path -Parent $Helper) 'enterprise-job.cs') }
    $missingName = Get-RunJobName ([guid]::NewGuid().ToString('D'))
    Assert-Equal ([VanessaRunner.ProcessJob]::Open($missingName)) $null 'Nonexistent kernel group is distinguishable from access failure'
    $empty = [VanessaRunner.ProcessJob]::new($missingName)
    $old | Add-Member -Force -NotePropertyName jobName -NotePropertyValue $missingName
    # Bind the record identity to this exact named group.
    $old.runId = $missingName.Substring('Local\VanessaRunner.Run.'.Length)
    try {
        $emptyResult = Resolve-LostRunCleanup $old '100'
        Assert-Equal $emptyResult.recoveryProof.kind 'named_job_empty' 'Kernel membership, not the old PID list, establishes cleanup'
        Assert-Equal $emptyResult.result 'failed' 'Empty group does not prove business success'
    } finally { $empty.Dispose() }
    $absentResult = Resolve-LostRunCleanup $old '100'
    Assert-Equal $absentResult.recoveryStatus 'resources_released' 'Missing job is not exit; the independent resource claim closes only the failed run'
    Assert-Equal $absentResult.activeProcessCount $null 'No empty job is invented when its handle is gone'

    $jobName = Get-RunJobName ([guid]::NewGuid().ToString('D'))
    $job = [VanessaRunner.ProcessJob]::new($jobName)
    $registry = @{}
    try {
        # A process outside this private job must never be adopted, even with a valid PID.
        Add-OwnedJobCandidate $PID $job $registry
        Assert-Equal $registry.Count 0 'Foreign processes cannot enter the owned registry'
        $fixture = Join-Path $directory 'job-fixture.exe'
        Add-Type -OutputAssembly $fixture -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
using System.Diagnostics;
using System.Reflection;
public static class Fixture {
    public static void Main(string[] args) {
        string directory = args[1];
        if (args[0] == "relay") {
            var child = Process.Start(Assembly.GetExecutingAssembly().Location, "child \"" + directory + "\"");
            File.WriteAllText(Path.Combine(directory, "client.pid"), child.Id.ToString());
            return;
        }
        using (var watcher = new FileSystemWatcher(directory, "release")) {
            watcher.EnableRaisingEvents = true;
            while (!File.Exists(Path.Combine(directory, "release"))) watcher.WaitForChanged(WatcherChangeTypes.All, 1000);
        }
    }
}
'@
        # Everything needed for the test is compiled before binding the supervisor to its job.
        $job.BindCurrentProcess()
        Assert-Equal ($job.Contains((Get-Process -Id $PID).Handle)) $true 'Supervisor owns this exact job'
        $selfCancellationRejected = $false
        try { $job.Cancel() } catch [InvalidOperationException] { $selfCancellationRejected = $true }
        Assert-Equal $selfCancellationRejected $true 'A cancellation caller cannot terminate itself or its own supervising job'
        $relay = Start-Process -FilePath $fixture -WindowStyle Hidden -PassThru -ArgumentList @('relay', ('"' + $directory + '"'))
        if (-not $relay.WaitForExit(10000)) { throw 'Fixture launcher did not exit' }
        $clientId = [int][IO.File]::ReadAllText((Join-Path $directory 'client.pid'))
        $relay.Dispose()
        Assert-Equal ($job.ProcessIds() -contains $clientId) $true 'Job retains child after intermediate launcher exits'
        Add-OwnedJobCandidate $clientId $job $registry
        Assert-Equal $registry.ContainsKey($clientId) $true 'Orphaned descendant is observed without a live parent'
        $retainedChild = $registry[$clientId].process
        $reopened = [VanessaRunner.ProcessJob]::Open($jobName)
        try {
            Assert-Equal ($reopened.ProcessIds() -contains $clientId) $true 'Native recovery reopens the same kernel group'
            Assert-Equal ($reopened.Contains($retainedChild.Handle)) $true 'Recovery validates the retained process handle'
            $job.Dispose()
            Assert-Equal ($reopened.ProcessIds() -contains $clientId) $true 'New owner observes descendants after the original handle is lost'
            $kernelLease = [VanessaRunner.ProcessJob]::Open($jobName)
        } finally { $reopened.Dispose() }
        # The observer launcher must not inherit this caller's process group or desktop mismatch.
        $detachedRoot = Join-Path $directory 'detached'
        $null = [IO.Directory]::CreateDirectory($detachedRoot)
        $detached = Start-IndependentProcess ('"' + $fixture + '" child "' + $detachedRoot + '"') $directory
        try {
            Assert-Equal ($jobName -eq '') $false 'The run has a reopenable identity'
            $ownedAgain = [VanessaRunner.ProcessJob]::Open($jobName)
            try { Assert-Equal ($ownedAgain.Contains($detached.Handle)) $false 'WMI observer escapes the caller job, including MCP kill-on-close' }
            finally { if ($null -ne $ownedAgain) { $ownedAgain.Dispose() } }
            Assert-Equal $detached.SessionId (Get-Process -Id $PID).SessionId 'Independent observer keeps the interactive desktop session'
        } finally {
            [IO.File]::WriteAllText((Join-Path $detachedRoot 'release'), '')
            if (-not $detached.WaitForExit(10000)) { throw 'Independent fixture did not finish gracefully' }
            $detached.Dispose()
        }
        $kernelLease.Dispose()
        Assert-Equal ([VanessaRunner.ProcessJob]::Open($jobName)) $null 'Losing all named handles does not imply that live descendants exited'
        # Closing the ownership handle is deliberately NOT a forced process shutdown.
        $job.Dispose()
        Assert-Equal $retainedChild.HasExited $false 'Disposing the job must not kill owned processes'
        [IO.File]::WriteAllText((Join-Path $directory 'release'), '')
        if (-not $retainedChild.WaitForExit(10000)) { throw 'Fixture child did not finish gracefully' }
        Assert-Equal $retainedChild.ExitCode 0 'Descendant exits naturally with its retained handle'
    } finally {
        [IO.File]::WriteAllText((Join-Path $directory 'release'), '')
        foreach ($entry in $registry.Values) { $null = $entry.process.WaitForExit(10000); $entry.process.Dispose() }
        $job.Dispose()
        Get-EventSubscriber | Unregister-Event
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.ToString())
    throw
} finally {
    # Delete only the exact directory created by this check, after checking its absolute parent.
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($directory)).TrimEnd('\') -ne [IO.Path]::GetTempPath().TrimEnd('\')) { throw 'Unexpected cleanup path' }
    Remove-Item -LiteralPath $directory -Recurse
}
'PASS: lifecycle/status, silent enterprise exit fails with its platform error, hidden live descendant blocks success, orphaned child retained by Windows job, foreign PID rejected, disposal never kills, graceful fixture exit'

# await: the caller holds a state and gets the next one; the change of the file
# is the event. A run that already ended answers at once.
$awaitRoot = Join-Path ([IO.Path]::GetTempPath()) ('vr-await-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($awaitRoot)
try {
    $ended = [ordered]@{
        runId = [guid]::NewGuid().ToString('D'); state = 'exited'; scenarioStatus = 'passed'
        cleanupStatus = 'exited'; result = 'passed'; observerPid = $null; observerStartTicks = ''
    }
    Write-RunJson (Join-Path $awaitRoot 'state.json') $ended
    $seen = Read-RunState $awaitRoot
    Assert-Equal $seen.state 'exited' 'A finished run answers from its own record'
    $currentObserver = Get-Process -Id $PID
    $running = [ordered]@{
        runId = $ended.runId; state = 'running'; scenarioStatus = 'pending'; cleanupStatus = 'running'
        result = 'pending'; observerPid = $PID; observerStartTicks = $currentObserver.StartTime.ToUniversalTime().Ticks.ToString()
        processes = @()
    }
    Write-RunJson (Join-Path $awaitRoot 'state.json') $running
    $previous = $running.observationId
    Add-Type -Path (Join-Path (Split-Path -Parent $Helper) 'enterprise-observation.cs')
    $notifications = [VanessaRunner.ObservationChanges]::new($awaitRoot)
    $running.processes = @(@{ role = 'client'; state = 'running'; windowVisible = $true })
    Write-RunJson (Join-Path $awaitRoot 'state.json') $running
    $notifications.Wait() # A queued replacement is retained before waiting.
    $notifications.Dispose()
    $changed = Wait-RunObservation $awaitRoot $previous
    Assert-Equal $changed.state 'running' 'A client-ready event needs no outcome transition'
    Assert-Equal $changed.scenarioStatus 'pending' 'No scenario success is invented by a window event'
    Assert-Equal $changed.processes[0].windowVisible $true 'The consumer receives the actual window observation'
    Assert-Equal ($changed.observationId -ne $previous) $true 'Atomic receipts have distinct delivery identities'
    $currentObserver.Dispose()
    $stale = [ordered]@{
        runId = $ended.runId; state = 'running'; scenarioStatus = 'pending'; cleanupStatus = 'running'
        result = 'pending'; observerPid = 999999; observerStartTicks = '1'; observationError = $null
    }
    Write-RunJson (Join-Path $awaitRoot 'state.json') $stale
    $lost = Read-RunState $awaitRoot
    Assert-Equal $lost.state 'supervision_lost' 'A record without its supervisor is not proof of a live run'
} finally { Remove-Item -LiteralPath $awaitRoot -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host 'PASS: await/state record, supervisor liveness'

$permissionRoot = Join-Path ([IO.Path]::GetTempPath()) ('vr-permissions-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($permissionRoot)
try {
    $permissionState = @{runId=[guid]::NewGuid().ToString('D'); state='running'; result='pending'; scenarioStatus='pending'; requestedProcessing='C:\known\vanessa.epf'; observerPid=$PID; observerStartTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks.ToString()}
    Write-RunJson (Join-Path $permissionRoot 'state.json') $permissionState
    $native = Read-RunState $permissionRoot
    $receipt = @{runId=$permissionState.runId;path=$permissionState.requestedProcessing;capability='administer_users';state='requested'}
    $receiptPath = Join-Path $permissionRoot 'processing-permission-administer_users.json'
    Write-RunJson $receiptPath $receipt
    $granted = Read-RunState $permissionRoot
    Assert-Equal ($granted.observationId -ne $native.observationId) $true 'Durable permission changes wake the owner without process changes'
    Assert-Equal (Read-RunState $permissionRoot).observationId $granted.observationId 'Unchanged composite observation remains stable across MCP reads'
    Assert-Equal $granted.scenarioStatus 'pending' 'Permission delivery never supplies a test verdict'
    $receipt.state='acknowledgement_requested'; Write-RunJson $receiptPath $receipt
    Assert-Equal ((Read-RunState $permissionRoot).observationId -ne $granted.observationId) $true 'Acknowledgement advances the delivered observation independently'
    $receipt.path='C:\foreign\vanessa.epf';Write-RunJson $receiptPath $receipt
    $rejected=$false
    try { Read-RunState $permissionRoot | Out-Null } catch { $rejected=$_.Exception.Message -eq 'Processing permission receipt identity changed' }
    Assert-Equal $rejected $true 'Foreign permission receipt is refused rather than delivered as owned state'
} finally { Remove-Item -LiteralPath $permissionRoot -Recurse }
Write-Host 'PASS: independent permission receipts wake await, preserve pending verdict and reject foreign processing'


# An unknown runId is an answer about the run, not a failure of the call.
$unknownRoot = Join-Path ([IO.Path]::GetTempPath()) ('vr-unknown-' + [guid]::NewGuid().ToString('N'))
try {
    $script:RunId = [guid]::NewGuid().ToString('D')
    foreach ($action in @('status','await','stop')) {
        $script:Action = $action
        $answer = & {
            $directory = $unknownRoot
            $statePath = Join-Path $directory 'state.json'
            if (-not [IO.File]::Exists($statePath)) {
                if ($Action -in @('status','await','stop')) {
                    return [pscustomobject][ordered]@{
                        runId = $RunId; state = 'supervision_lost'; scenarioStatus = 'unknown'
                        cleanupStatus = 'unknown'; result = 'unknown'; failureReason = $null
                        activeProcessCount = 0; processes = @()
                        observationError = 'No owned launch record for this runId'
                    }
                }
                throw 'Unknown runId: no owned launch record'
            }
        }
        Assert-Equal $answer.state 'supervision_lost' "$action of an unknown run answers with its state"
        Assert-Equal $answer.result 'unknown' "$action of an unknown run claims no verdict"
    }
} finally { Remove-Item -LiteralPath $unknownRoot -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host 'PASS: unknown runId answers instead of failing'

& (Join-Path $PSScriptRoot 'enterprise-recovery.ps1') -Helper $Helper

# Native fixture assemblies are process-local; unload before deleting their executable.
& powershell.exe -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'enterprise-cancellation.ps1') -Helper $Helper
if ($LASTEXITCODE -ne 0) { throw 'Native cancellation fixture failed' }
& powershell.exe -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot "enterprise-cancellation.ps1") -Helper $Helper -ScenarioStatus failed
if ($LASTEXITCODE -ne 0) { throw "Cancellation lost the completed scenario verdict" }

& powershell.exe -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot "enterprise-surface.ps1") -Helper (Join-Path (Split-Path -Parent $Helper) "enterprise-consent.cs")
if ($LASTEXITCODE -ne 0) { throw "Owned execution surface regression failed" }
