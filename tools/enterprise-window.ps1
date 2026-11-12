param(
    [ValidateSet('launch','watch','status','stop','await','recover','recover_watch','job_lease','cancel','execute','find','authorize')][string]$Action = 'status',
    [string]$RunId,
    [string]$SpecPath,
    [string]$StoreRoot,
    [ValidateRange(0,30)][int]$TimeoutSeconds = 5
)
$ErrorActionPreference = 'Stop'
# This native helper uses only its own built-in modules, independent of the calling host's PS version.
$env:PSModulePath = Join-Path $PSHOME 'Modules'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Get-RunDirectory([string]$Id) {
    $parsed = [guid]::Empty
    if (-not [guid]::TryParseExact($Id, 'D', [ref]$parsed)) { throw 'Invalid runId' }
    $root = if ($StoreRoot) { $StoreRoot } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'VanessaRunner\runs' }
    $root = [IO.Path]::GetFullPath($root).TrimEnd('\')
    $localData = [Environment]::GetFolderPath('LocalApplicationData').TrimEnd('\') + '\'
    if (-not $root.StartsWith($localData, [StringComparison]::OrdinalIgnoreCase) -or -not $root.EndsWith('\VanessaRunner\runs', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Run store is outside this user LocalAppData'
    }
    if ([IO.Directory]::Exists($root)) {
        if (-not ('VanessaRunner.RunStore' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'enterprise-job.cs') }
        $root = [VanessaRunner.RunStore]::Resolve($root)
    }
    $directory = Join-Path $root $parsed.ToString('D')
    if ([IO.Directory]::Exists($directory)) { $directory = [VanessaRunner.RunStore]::Resolve($directory) }
    return $directory
}

function Write-RunJson([string]$Path, $Value) {
    if ([IO.Path]::GetFileName($Path) -eq 'state.json') {
        # Every atomic native observation has one opaque delivery identity.
        # Process/window changes must wake consumers even when outcomes match.
        $identity = [guid]::NewGuid().ToString('D')
        if ($Value -is [Collections.IDictionary]) { $Value['observationId'] = $identity }
        else { $Value | Add-Member -Force -NotePropertyName observationId -NotePropertyValue $identity }
    }
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
    else { [IO.File]::Move($temporary, $Path) }
}

function Read-RunJson([string]$Path) {
    # Windows replacement can briefly make the pathname unavailable as well as locked.
    # Retry the read within one bounded window; never return stale or invented state.
    $attempt = 0
    while ($true) {
        try { return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json) }
        catch [IO.IOException] {
            $attempt++
            if ($attempt -ge 40) { throw }
            Start-Sleep -Milliseconds 25
        }
    }
}

function Get-RunOutcome($Processes, [string]$Kind, [string]$Scenario, [bool]$StopRequested, [int]$ActiveProcessCount = 0, [bool]$WindowSeen = $true) {
    $live = @($Processes | Where-Object { $_.state -ne 'exited' })
    $hasLive = $live.Count -gt 0 -or $ActiveProcessCount -gt 0
    $managerDone = $Kind -eq 'vanessa' -and
        @($Processes | Where-Object { $_.role -eq 'manager' }).Count -gt 0 -and
        @($Processes | Where-Object { $_.role -eq 'manager' -and $_.state -ne 'exited' }).Count -eq 0
    $closing = $StopRequested -or $managerDone -or ($Kind -eq 'vanessa' -and $Scenario -in @('passed','failed','invalid'))
    $cleanup = if ($hasLive) { if ($closing) { 'close_pending' } else { 'running' } } else { 'exited' }
    $state = if ($hasLive) { if ($StopRequested) { 'close_pending' } else { 'running' } } else { 'exited' }
    $result = 'pending'
    $reason = $null
    if (-not $hasLive) {
        $badExit = @($Processes | Where-Object { $_.role -ne 'helper' -and ($null -eq $_.exitCode -or $_.exitCode -ne 0) }).Count -gt 0
        # An interactive session that ends without ever showing a window is a failed launch
        # (the platform reported its error and quit), not a completed one - exit code 0 or not.
        $silentExit = $Kind -eq 'enterprise' -and -not $StopRequested -and -not $WindowSeen
        $scenarioFailed = $Kind -eq 'vanessa' -and $Scenario -ne 'passed'
        if ($badExit) { $reason = 'bad_exit' }
        elseif ($silentExit) { $reason = 'exited_before_window' }
        elseif ($scenarioFailed) { $reason = 'scenario_' + $Scenario }
        $result = if ($null -eq $reason) { 'passed' } else { 'failed' }
    }
    elseif ($Kind -eq 'vanessa' -and ($Scenario -in @('passed','failed','invalid') -or $managerDone)) { $result = 'cleanup_pending' }
    [pscustomobject]@{ state = $state; cleanupStatus = $cleanup; result = $result; failureReason = $reason }
}

function Get-LastEventLogError([string]$IbPath) {
    # Best-effort: the last error record ("E" severity) of the infobase event log, so a client
    # that quit before its window appeared reports WHY instead of a bare exit code.
    if (-not $IbPath) { return $null }
    try {
        $logDirectory = Join-Path $IbPath '1Cv8Log'
        if (-not [IO.Directory]::Exists($logDirectory)) { return $null }
        $newest = Get-ChildItem -LiteralPath $logDirectory -Filter '*.lgp' -File | Sort-Object LastWriteTimeUtc | Select-Object -Last 1
        if ($null -eq $newest) { return $null }
        $text = [IO.File]::ReadAllText($newest.FullName, [Text.Encoding]::UTF8).Replace([string][char]0, '')
        $records = [regex]::Matches($text, ',E,"((?:[^"]|"")*)"', [Text.RegularExpressions.RegexOptions]::Singleline)
        if ($records.Count -eq 0) { return $null }
        $message = $records[$records.Count - 1].Groups[1].Value.Replace('""', '"').Trim()
        if ($message.Length -gt 4000) { $message = $message.Substring(0, 4000) }
        return $message
    } catch { return $null }
}

function Get-RequestedProcessing([string]$Arguments, [string]$Kind) {
    if ($Kind -ne 'vanessa') { return $null }
    $matches = [regex]::Matches($Arguments, '(?i)(?:^|\s)/Execute\s*"([^"\r\n]+)"')
    if ($matches.Count -ne 1) { throw 'Vanessa must request exactly one external processing file' }
    $path = $matches[0].Groups[1].Value
    if (-not [IO.Path]::IsPathRooted($path) -or [IO.Path]::GetExtension($path) -ne '.epf' -or -not [IO.File]::Exists($path)) {
        throw 'Requested Vanessa processing must be an existing absolute EPF path'
    }
    return [IO.Path]::GetFullPath($path)
}

function Test-RequestedProcessingNotice([string]$Text, [string]$ExpectedPath) {
    # This is consent to the exact /Execute file in this launch, never a change
    # to the platform's protection policy or approval of another processing.
    if (-not $ExpectedPath -or -not $Text.StartsWith('Предупреждение безопасности')) { return $false }
    $match = [regex]::Match($Text, 'Открывается (?:(?:"[^"\r\n]+" )?из файла|внешняя обработка|внешний отчет|файл) "([^"\r\n]+)"\.')
    $questionMatch = $Text.TrimEnd() -match 'Разрешить (?:открывать|открыть) (?:данный|этот) файл\?$'
    if (-not $match.Success -or -not $questionMatch) { return $false }
    return [string]::Equals($match.Groups[1].Value, $ExpectedPath, [StringComparison]::OrdinalIgnoreCase)
}

function Test-RequestedProcessingCapabilityNotice([string]$Text, [string]$ExpectedPath, [string]$Capability) {
    if ($Capability -eq 'open_processing') { return Test-RequestedProcessingNotice $Text $ExpectedPath }
    if ($Capability -ne 'administer_users' -or -not $ExpectedPath -or -not $Text.StartsWith('Предупреждение безопасности')) { return $false }
    $match = [regex]::Match($Text, 'Модуль "[^"\r\n]+",?\s*загруженный из:?\s+"([^"\r\n]+)"')
    return $match.Success -and ($Text.TrimEnd() -match 'Разрешить администрировать пользователей для (?:данного|этого) модуля\?$') -and
        [string]::Equals($match.Groups[1].Value, $ExpectedPath, [StringComparison]::OrdinalIgnoreCase)
}

function Get-ExecutionDesktop {
    if (-not ('VanessaRunner.ExecutionDesktop' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'enterprise-desktop.cs') }
    return [VanessaRunner.ExecutionDesktop]::Read()
}

function Set-ExecutionDesktopObservation($State) {
    $context = Get-ExecutionDesktop
    $State | Add-Member -Force -NotePropertyName executionDesktop -NotePropertyValue $context
    return $context.available
}

function Get-ExecutionDesktopRefusal($State) {
    $context = $State.executionDesktop
    return ('execution_desktop_unavailable: session=' + $context.sessionId + ', connection=' + $context.connection +
        ', desktop=' + $context.desktop + ', inputDesktop=' + $context.inputDesktop + ', Win32=' + $context.win32Error)
}

function Invoke-OwnedWindowControl($Entry, $Window, $Control, $Job) {
    $process = $Entry.process
    if ($process.HasExited -or -not $Job.Contains($process.Handle) -or
        $process.StartTime.ToUniversalTime().Ticks.ToString() -ne $Entry.startTicks -or
        $Window.Current.ProcessId -ne $process.Id -or $Control.Current.ProcessId -ne $process.Id) {
        throw 'Requested window control ownership changed'
    }
    if (-not $Control.Current.IsEnabled -or $Control.Current.IsOffscreen) { throw 'Requested window control is unavailable' }
    # Invoke the exact owned control through its native automation contract.
    # Focus/foreground and synthetic keys are not prerequisites of this action.
    $pattern = $null
    if (-not $Control.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        throw 'Requested window control does not support native invocation'
    }
    ([Windows.Automation.InvokePattern]$pattern).Invoke()
}

function Get-OwnedAutomationWindows($Process, [switch]$DialogsOnly) {
    if (-not ('VanessaRunner.ProcessingConsentInput' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'enterprise-consent.cs') }
    $handles = if ($DialogsOnly) { [VanessaRunner.ProcessingConsentInput]::DialogsForProcess($Process.Id) }
        else { [VanessaRunner.ProcessingConsentInput]::WindowsForProcess($Process.Id) }
    foreach ($handle in $handles) { Get-OwnedAutomationWindow $Process $handle }
}

function Get-OwnedAutomationWindow($Process, [IntPtr]$Handle) {
    # A close can destroy/reuse an enumerated HWND before its UIA provider is read.
    # Ignore that vanished candidate; never observe or act on its foreign replacement.
    if ($Process.HasExited -or -not [VanessaRunner.ProcessingConsentInput]::WindowBelongsToProcess($Process.Id, $Handle)) { return }
    try {
        $element = [Windows.Automation.AutomationElement]::FromHandle($Handle)
        $owner = $element.Current.ProcessId
    } catch [Windows.Automation.ElementNotAvailableException] {
        if (-not [VanessaRunner.ProcessingConsentInput]::WindowBelongsToProcess($Process.Id, $Handle)) { return }
        throw
    }
    if (-not [VanessaRunner.ProcessingConsentInput]::WindowBelongsToProcess($Process.Id, $Handle)) { return }
    if ($owner -ne $Process.Id) { throw 'Owned window identity changed before UI observation' }
    $element
}

function Get-OwnedExecutionSurface($Process) {
    if (-not ('VanessaRunner.ProcessingConsentInput' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'enterprise-consent.cs') }
    if ($Process.HasExited) { return [IntPtr]::Zero }
    [VanessaRunner.ProcessingConsentInput]::PrimaryWindowForProcess($Process.Id)
}

function Request-OwnedClosure($Entry, $Job) {
    $process = $Entry.process
    if ($process.HasExited) { return }
    if (-not $Job.Contains($process.Handle) -or $process.StartTime.ToUniversalTime().Ticks.ToString() -ne $Entry.startTicks) {
        throw 'Requested close process ownership changed'
    }
    if (-not ('VanessaRunner.ProcessingConsentInput' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'enterprise-consent.cs') }
    if (@([VanessaRunner.ProcessingConsentInput]::DialogsForProcess($process.Id)).Count -gt 0) { return }
    $surface = Get-OwnedExecutionSurface $process
    if ($surface -eq [IntPtr]::Zero) { return }
    # Apply the same explicit stop intent to a recreated owned surface. A queued
    # WM_CLOSE is not a receipt of exit and cannot settle scenario success.
    if ($Entry.PSObject.Properties['closeRequestedHwnd'] -and $Entry.closeRequestedHwnd -eq $surface.ToInt64()) { return }
    $Entry.closeAccepted = [VanessaRunner.ProcessingConsentInput]::RequestClose($process.Id, $surface)
    if ($Entry.closeAccepted) { $Entry | Add-Member -Force -NotePropertyName closeRequestedHwnd -NotePropertyValue ($surface.ToInt64()) }
}

function Confirm-OwnedDeveloperLicense($Entry, $Job, $State) {
    $process = $Entry.process
    if ($process.HasExited) { return }
    if (-not $Job.Contains($process.Handle) -or $process.StartTime.ToUniversalTime().Ticks.ToString() -ne $Entry.startTicks) {
        throw 'Developer license notice process ownership changed'
    }
    if (-not ('VanessaRunner.ProcessingConsentInput' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'enterprise-consent.cs') }
    $handles = @([VanessaRunner.ProcessingConsentInput]::WindowsForProcess($process.Id))
    $receipts = @($State.developerLicenseNotices | Where-Object { $_.pid -eq $process.Id -and $_.startTicks -eq $Entry.startTicks })
    if ($receipts.Count -gt 0) {
        foreach ($receipt in $receipts) {
            if ($receipt.state -eq 'acknowledgement_requested' -and @($handles | Where-Object { $_.ToInt64() -eq $receipt.windowHandle }).Count -eq 0) {
                $receipt.state = 'acknowledged'
                $receipt | Add-Member -Force -NotePropertyName acknowledgedAt -NotePropertyValue ([DateTime]::UtcNow.ToString('o'))
            }
        }
        return
    }
    $process.Refresh()
    if ($process.MainWindowTitle -notin @('1С:Предприятие','1C:Предприятие','1C:Enterprise')) { return }
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    foreach ($window in @(Get-OwnedAutomationWindows $process)) {
        $texts = $window.FindAll([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Text))
        $notices = @($texts | Where-Object {
            $text = [regex]::Replace($_.Current.Name.Trim(), '\s+', ' ')
            $text -match '^Используемая лицензия предназначена для проектирования, разработки, тестирования и демонстрации программ\. Лицензия не предназначена для коммерческого использования\. Разработчик: .+\. Последнее обновление статуса: .+\.$'
        })
        if ($notices.Count -ne 1) { continue }
        $buttons = $window.FindAll([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button))
        $acknowledge = @($buttons | Where-Object { $_.Current.Name.Trim() -eq 'OK' -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen })
        if ($acknowledge.Count -ne 1) { throw 'Developer license notice has no unique enabled OK control' }
        $receipt = [pscustomobject]@{
            state = 'acknowledgement_requested'; capability = 'acknowledge_developer_license'
            runId = $State.runId; pid = $process.Id; startTicks = $Entry.startTicks
            windowHandle = [long]$window.Current.NativeWindowHandle; text = $notices[0].Current.Name
            inputMethod = 'owned_window_close'; at = [DateTime]::UtcNow.ToString('o')
        }
        # A platform startup notice is outside the TestClient application loop.
        # Close this informational dialog through the native window lifecycle;
        # a queued request is acknowledged only when this exact notice disappears.
        if (-not [VanessaRunner.ProcessingConsentInput]::RequestClose($process.Id, [IntPtr]$receipt.windowHandle)) {
            throw 'Developer license notice close request was not queued'
        }
        $State.developerLicenseNotices = @($State.developerLicenseNotices) + @($receipt)
        return
    }
}

function Clear-BlockingModals($Entry, $Job) {
    # A modal disables its owner. That Win32 fact blocks exit of any owned
    # session, independent of the product caption. Close the dialog surface
    # with the same request used for the root, then allow the root close again.
    $process = $Entry.process
    if ($process.HasExited) { return }
    if (-not $Job.Contains($process.Handle) -or $process.StartTime.ToUniversalTime().Ticks.ToString() -ne $Entry.startTicks) {
        throw 'Blocking modal process ownership changed'
    }
    if (-not ('VanessaRunner.ProcessingConsentInput' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'enterprise-consent.cs') }
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $closed = [VanessaRunner.ProcessingConsentInput]::DismissPopups($process.Id)
    foreach ($window in @(Get-OwnedAutomationWindows $process -DialogsOnly)) {
        $handle = $window.Current.NativeWindowHandle
        $buttons = $window.FindAll([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button))
        $dismiss = @($buttons | Where-Object {
            $_.Current.Name.Trim() -in @('Нет','No','Отмена','Cancel','Закрыть','Close','Закрыть форму','Close the form','OK','ОК') -and
                $_.Current.IsEnabled -and -not $_.Current.IsOffscreen
        })
        if ($dismiss.Count -ge 1) {
            try {
                Invoke-OwnedWindowControl $Entry $window $dismiss[0] $Job
                if ($handle -ne 0) { [VanessaRunner.ProcessingConsentInput]::Activate($process.Id, [IntPtr]$handle) }
                $closed++
                continue
            } catch {}
        }
    }
    foreach ($dialog in @([VanessaRunner.ProcessingConsentInput]::DialogsForProcess($process.Id))) {
        if ([VanessaRunner.ProcessingConsentInput]::RequestClose($process.Id, $dialog)) { $closed++ }
    }
    if ($closed -eq 0) { return }
    $Entry.closeAccepted = $null
    $Entry | Add-Member -Force -NotePropertyName closeRequestedHwnd -NotePropertyValue $null
    $Entry | Add-Member -Force -NotePropertyName blockingModalsClosed -NotePropertyValue $closed
}

function Confirm-RequestedClosure($Entry, $Job) {
    # Confirm quit prompts on owned sessions during closure (whether initiated by
    # Vanessa Automation's own CloseTestClient/Exit or by this run's WM_CLOSE).
    $process = $Entry.process
    if ($process.HasExited) { return }
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $windows = @(Get-OwnedAutomationWindows $process -DialogsOnly)
    foreach ($window in $windows) {
        $handle = [long]$window.Current.NativeWindowHandle
        if ($Entry.PSObject.Properties['closeConfirmedHwnd'] -and $Entry.closeConfirmedHwnd -eq $handle) { continue }
        $texts = $window.FindAll([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Text))
        $prompts = @(
            'Завершить работу с приложением?',
            'Завершить работу с программой?',
            'Вы действительно хотите завершить работу?',
            'Данные были изменены. Все изменения будут потеряны.',
            'Вы уверены?',
            'Есть несохраненные изменения. Вы уверены?'
        )
        if (@($texts | Where-Object { $prompts -contains $_.Current.Name.Trim() }).Count -lt 1) { continue }
        $buttons = $window.FindAll([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button))
        $finish = @($buttons | Where-Object {
            $_.Current.Name.Trim() -in @('Завершить работу','Да','Yes','Закрыть форму') -and
                $_.Current.IsEnabled -and -not $_.Current.IsOffscreen
        })
        if ($finish.Count -lt 1) { throw 'Requested close notice has no enabled finish control' }
        Invoke-OwnedWindowControl $Entry $window $finish[0] $Job
        if ($handle -ne 0) {
            [VanessaRunner.ProcessingConsentInput]::Activate($process.Id, [IntPtr]$handle)
        }
        $Entry | Add-Member -Force -NotePropertyName closeConfirmedHwnd -NotePropertyValue $handle
        $Entry | Add-Member -Force -NotePropertyName closeConfirmationRequested -NotePropertyValue $true
        return
    }
}

function Confirm-RunClosure($State) {
    if ($State.jobName -ne (Get-RunJobName $State.runId)) { throw 'Close confirmation requires this run owned named job' }
    if (-not ('VanessaRunner.ProcessJob' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'enterprise-job.cs') }
    $job = [VanessaRunner.ProcessJob]::Open($State.jobName)
    if ($null -eq $job) { throw 'Close confirmation cannot confirm an unavailable job' }
    $owned = @{}
    try {
        foreach ($identity in @($State.processes | Where-Object { $_.role -in @('manager','client') -and $_.state -eq 'running' })) {
            Add-OwnedJobCandidate $identity.pid $job $owned
            $entry = $owned[[int]$identity.pid]
            if ($null -eq $entry -or $entry.startTicks -ne $identity.startTicks -or $entry.executable -ne $identity.executable) { throw 'Close confirmation process identity changed' }
            $entry.closeAccepted = $identity.closeAccepted
            Request-OwnedClosure $entry $job
            Confirm-RequestedClosure $entry $job
        }
    } finally {
        foreach ($entry in $owned.Values) { $entry.process.Dispose() }
        $job.Dispose()
    }
}

function Confirm-RequestedProcessing($Entry, [string]$ExpectedPath, $Job, $State, [string]$Capability = 'open_processing') {
    $process = $Entry.process
    if ($process.HasExited -or $process.MainWindowHandle -eq [IntPtr]::Zero) { return $null }
    $requestedProperty = 'consentRequested_' + $Capability
    if ($Entry.PSObject.Properties[$requestedProperty] -and $Entry.$requestedProperty) { return $null }
    if (-not $Job.Contains($process.Handle) -or $process.StartTime.ToUniversalTime().Ticks.ToString() -ne $Entry.startTicks) {
        throw 'Processing consent process ownership changed'
    }
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $windows = @(Get-OwnedAutomationWindows $process -DialogsOnly)
    foreach ($window in $windows) {
        $texts = $window.FindAll([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Text))
        $notices = @($texts | Where-Object { Test-RequestedProcessingCapabilityNotice $_.Current.Name $ExpectedPath $Capability })
        if ($notices.Count -ne 1) { continue }
        $buttons = $window.FindAll([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button))
        $allow = @($buttons | Where-Object { $_.Current.Name.Trim() -eq 'Да' -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen })
        if ($allow.Count -ne 1) { throw 'Requested processing notice has no unique enabled consent control' }
        if ($process.HasExited -or -not $Job.Contains($process.Handle) -or $window.Current.ProcessId -ne $process.Id) {
            throw 'Processing consent window ownership changed'
        }
        # Desktop connectivity is an observation, not a prerequisite of this
        # window-addressed action or the native TestClient transport.
        $null = Set-ExecutionDesktopObservation $State
        $windowHandle = $window.Current.NativeWindowHandle
        Invoke-OwnedWindowControl $Entry $window $allow[0] $Job
        if ($windowHandle -ne 0) {
            [VanessaRunner.ProcessingConsentInput]::Activate($process.Id, [IntPtr]$windowHandle)
        }
        $Entry | Add-Member -Force -NotePropertyName $requestedProperty -NotePropertyValue $true
        return [pscustomobject]@{ state = 'requested'; capability = $Capability; inputMethod = 'window_message'; path = $ExpectedPath; pid = $process.Id; startTicks = $Entry.startTicks; windowHandle = $windowHandle; at = [DateTime]::UtcNow.ToString('o') }
    }
    return $null
}

function Test-ProcessingAuthorizationAcknowledgement([string]$Text) {
    $normalized = [regex]::Replace($Text.Trim(), '\s+', ' ')
    return $normalized -eq 'Текущее выполнение действия было прервано для выдачи предупреждения. Вы подтвердили выполнение действия для данного модуля. В дальнейшем это действие для данного модуля будет выполняться без выдачи предупреждений. Просьба сейчас вызвать действие еще раз.'
}

function Acknowledge-ProcessingAuthorization($Entry, $Receipt, $Job) {
    if ($Receipt.state -ne 'requested') { return $Receipt }
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $matches = @()
    foreach ($window in @(Get-OwnedAutomationWindows $Entry.process -DialogsOnly)) {
        $texts = $window.FindAll([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Text))
        $notice = @($texts | Where-Object { Test-ProcessingAuthorizationAcknowledgement $_.Current.Name })
        if ($notice.Count -eq 1) { $matches += @{ window = $window; text = $notice[0].Current.Name } }
    }
    if ($matches.Count -eq 0) { return $Receipt }
    if ($matches.Count -ne 1) { throw 'Processing authorization acknowledgement is ambiguous' }
    $window = $matches[0].window
    $buttons = $window.FindAll([Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button))
    $acknowledge = @($buttons | Where-Object { $_.Current.Name.Trim() -eq 'OK' -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen })
    if ($acknowledge.Count -ne 1) { throw 'Processing acknowledgement has no unique enabled OK control' }
    $windowHandle = $window.Current.NativeWindowHandle
    Invoke-OwnedWindowControl $Entry $window $acknowledge[0] $Job
    if ($windowHandle -ne 0) {
        [VanessaRunner.ProcessingConsentInput]::Activate($Entry.process.Id, [IntPtr]$windowHandle)
    }
    $Receipt.state = 'acknowledgement_requested'
    $Receipt | Add-Member -Force -NotePropertyName acknowledgement -NotePropertyValue @{
        text = $matches[0].text; windowHandle = $windowHandle; at = [DateTime]::UtcNow.ToString('o')
        interruptedAction = $true; requiresActionRetry = $true; inputMethod = 'window_message'
    }
    return $Receipt
}

function Authorize-RunProcessing([string]$Directory, [string]$Capability) {
    if ($Capability -notin @('open_processing','administer_users')) { throw 'Unknown processing capability' }
    $mutex = [Threading.Mutex]::new($false, ('Local\VanessaRunner.Permission.' + $RunId))
    $entered = Enter-RunMutex $mutex -1
    $job = $null; $owned = @{}
    try {
        $state = Read-RunState $Directory
        if ($state.kind -ne 'vanessa' -or $state.state -ne 'running' -or -not $state.requestedProcessing -or
            $state.jobName -ne (Get-RunJobName $RunId) -or [IO.File]::Exists((Join-Path $Directory 'stop.json'))) {
            throw 'Processing authorization requires the live owned Vanessa run'
        }
        $receiptPath = Join-Path $Directory ('processing-permission-' + $Capability + '.json')
        $previous = if ([IO.File]::Exists($receiptPath)) { Read-RunJson $receiptPath } else { $null }
        if (-not ('VanessaRunner.ProcessJob' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'enterprise-job.cs') }
        $job = [VanessaRunner.ProcessJob]::Open($state.jobName)
        if ($null -eq $job) { throw 'Processing authorization requires the native run job' }
        $managers = @($state.processes | Where-Object { $_.role -eq 'manager' -and $_.state -eq 'running' })
        if ($managers.Count -ne 1) { throw 'Processing authorization requires one owned manager' }
        $identity = $managers[0]
        Add-OwnedJobCandidate $identity.pid $job $owned
        $entry = $owned[[int]$identity.pid]
        if ($null -eq $entry -or $entry.startTicks -ne $identity.startTicks -or $entry.executable -ne $identity.executable) {
            throw 'Processing authorization manager identity changed'
        }
        if ($null -ne $previous) {
            if ($previous.runId -ne $RunId -or $previous.path -ne $state.requestedProcessing -or $previous.capability -ne $Capability -or
                $previous.pid -ne $identity.pid -or $previous.startTicks -ne $identity.startTicks) { throw 'Previous permission receipt ownership changed' }
            $receipt = Acknowledge-ProcessingAuthorization $entry $previous $job
            Write-RunJson $receiptPath $receipt
            return $receipt
        }
        $receipt = Confirm-RequestedProcessing $entry $state.requestedProcessing $job $state $Capability
        if ($null -eq $receipt) { throw 'No matching owned security notice for the requested capability' }
        $receipt | Add-Member -NotePropertyName runId -NotePropertyValue $RunId
        Write-RunJson $receiptPath $receipt
        return $receipt
    } finally {
        foreach ($entry in $owned.Values) { $entry.process.Dispose() }
        if ($null -ne $job) { $job.Dispose() }
        if ($entered) { $mutex.ReleaseMutex() }; $mutex.Dispose()
    }
}

function Get-PreparedClientPort([string]$CommandLine) {
    $ports = [regex]::Matches($CommandLine, '(?i)(?:^|\s)-TPort\s*(\d+)(?=\s|$)')
    if ($ports.Count -ne 1 -or $CommandLine -notmatch '(?i)(?:^|\s)/TESTCLIENT(?=\s|$)') { throw 'Prepared TestClient requires one explicit native transport port' }
    $port = [int]$ports[0].Groups[1].Value
    if ($port -lt 1 -or $port -gt 65535) { throw 'Prepared TestClient port is outside 1..65535' }
    return $port
}

function Test-PreparedClientReady($Entry, [int]$Port) {
    $process = $Entry.process
    if ($process.HasExited -or (Get-OwnedExecutionSurface $process) -eq [IntPtr]::Zero -or -not $process.Responding) { return $false }
    if (-not ('VanessaRunner.TestClientEndpoint' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'enterprise-endpoint.cs') }
    return [VanessaRunner.TestClientEndpoint]::OwnedListener($process.Id, $Port)
}

function Get-ScenarioStatus([string]$Path, [bool]$Finished) {
    if (-not $Path) { return 'not_applicable' }
    if (-not [IO.File]::Exists($Path)) { if ($Finished) { return 'missing' }; return 'pending' }
    try { $value = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8).Trim() }
    catch { return 'unreadable' }
    if ($value -eq '0') { return 'passed' }
    # Vanessa: 1 = failed steps, 2 = connection/context error, 3 = not executed.
    if ($value -in @('1','2','3')) { return 'failed' }
    if (-not $value -and -not $Finished) { return 'pending' }
    return 'invalid'
}

function Get-OwnedProcessState($Entry) {
    $process = $Entry.process
    $process.Refresh()
    $exited = $process.HasExited
    if (-not $exited -and -not ('VanessaRunner.ProcessingConsentInput' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'enterprise-consent.cs')
    }
    $surface = if ($exited) { [IntPtr]::Zero } else { Get-OwnedExecutionSurface $process }
    # The retained handle, creation time and executable belong to the launched process.
    # Never reopen a PID to close it: a later process may reuse that number.
    [pscustomobject][ordered]@{
        pid = $process.Id; role = $Entry.role; startTicks = $Entry.startTicks; executable = $Entry.executable
        state = $(if ($exited) { 'exited' } else { 'running' })
        windowVisible = ($surface -ne [IntPtr]::Zero)
        windowHandle = $(if ($exited) { $null } else { $surface.ToInt64() })
        windowTitle = $(if ($exited) { '' } else { $process.MainWindowTitle })
        responding = $(if ($exited) { $null } else { $process.Responding })
        closeAccepted = $Entry.closeAccepted
        modalDialogs = $(if ($exited) { 0 } else { @([VanessaRunner.ProcessingConsentInput]::DialogsForProcess($process.Id)).Count })
        exitCode = $(if ($exited) { $process.ExitCode } else { $null })
    }
}

function Add-OwnedProcess($Process, [string]$Role, $Registry, [string]$Executable) {
    if (-not $Executable -or -not [IO.Path]::IsPathRooted($Executable)) { throw "Owned process executable is not confirmed" }
    $null = $Process.Handle
    $entry = [pscustomobject]@{
        process = $Process; role = $Role; startTicks = $Process.StartTime.ToUniversalTime().Ticks.ToString()
        executable = [IO.Path]::GetFullPath($Executable); closeAccepted = $null
    }
    $Registry[$Process.Id] = $entry
    $Process.EnableRaisingEvents = $true
    Register-ObjectEvent $Process Exited -SourceIdentifier ('vr-process-' + [guid]::NewGuid().ToString('N')) | Out-Null
}

function Add-OwnedJobCandidate([int]$ChildId, $Job, $Registry) {
    $previous = $Registry[$ChildId]
    if ($null -ne $previous -and -not $previous.process.HasExited) { return }
    $child = Get-Process -Id $ChildId -ErrorAction SilentlyContinue
    if ($null -eq $child) { return } # Exited between the job snapshot and opening the handle.
    try {
        $null = $child.Handle
        # Job membership is checked on the retained handle, never on a bare, reusable PID.
        if (-not $Job.Contains($child.Handle)) { $child.Dispose(); return }
        if ($child.HasExited) { $child.Dispose(); return }
        $role = if ($child.ProcessName -in @('1cv8','1cv8c')) { 'client' } else { 'helper' }
        if ($null -ne $previous) { $Registry[('exited-' + $ChildId + '-' + $previous.startTicks)] = $previous }
        Add-OwnedProcess $child $role $Registry $child.Path
    } catch {
        # Short-lived launchers can exit while their handle/name is being read.
        if ($child.HasExited) { $child.Dispose(); return }
        $child.Dispose(); throw
    }
}

function Find-OwnedJobProcesses($Job, $Registry) {
    foreach ($childId in $Job.ProcessIds()) {
        if ($childId -ne $PID) { Add-OwnedJobCandidate $childId $Job $Registry }
    }
}

function Get-RunJobName([string]$Id) {
    $null = Get-RunDirectory $Id # Validate the identity before forming a kernel object name.
    'Local\VanessaRunner.Run.' + $Id
}

function Get-HostBootTicks {
    (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().Ticks.ToString()
}

function Get-RunMutex([string]$Id) {
    $null = Get-RunDirectory $Id
    [Threading.Mutex]::new($false, ('Local\VanessaRunner.Observer.' + $Id))
}

function Enter-RunMutex($Mutex, [int]$Milliseconds) {
    try { return $Mutex.WaitOne($Milliseconds) }
    catch [Threading.AbandonedMutexException] { return $true } # Kernel granted ownership.
}

function Start-IndependentProcess([string]$CommandLine, [string]$WorkingDirectory) {
    # WMI creates this process outside the caller's job (including MCP's kill-on-close job).
    # Explicit breakaway also excludes WMI provider quota jobs. No alternative launcher.
    $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{
        ShowWindow = [uint16]0; CreateFlags = [uint32]0x01000000; WinstationDesktop = 'winsta0\default'
    }
    $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = $CommandLine; CurrentDirectory = $WorkingDirectory; ProcessStartupInformation = $startup
    }
    if ($created.ReturnValue -ne 0) { throw ('Independent observer creation failed: WMI ' + $created.ReturnValue) }
    $process = Get-Process -Id $created.ProcessId
    $null = $process.Handle # Retain identity and exit status across a short-lived startup.
    return $process
}

function Start-RunHelper([string]$Directory, [string]$HelperAction, [string]$Specification, [string]$Id) {
    $helper = Join-Path $PSScriptRoot 'enterprise-window.ps1'
    $powershell = Join-Path ([Environment]::GetEnvironmentVariable('SystemRoot')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $log = Join-Path $Directory ('owner-' + $HelperAction + '.log')
    foreach ($path in @($helper, $powershell, $Directory, $Specification)) {
        if ($path -match '["\r\n]') { throw 'Invalid observer path' }
    }
    $null = Get-RunDirectory $Id
    # Capture startup errors as well as native receipts. Paths are literal PowerShell strings;
    # the command never contains the 1C launch specification or credentials.
    $invoke = "& '" + $helper.Replace("'", "''") + "' -Action " + $HelperAction + ' -RunId ' + $Id
    $physicalStore = Split-Path -Parent $Directory
    $invoke += " -StoreRoot '" + $physicalStore.Replace("'", "''") + "'"
    if ($Specification) { $invoke += " -SpecPath '" + $Specification.Replace("'", "''") + "'" }
    $invoke += " *> '" + $log.Replace("'", "''") + "'"
    $literalLog = "'" + $log.Replace("'", "''") + "'"
    $bootstrap = '[IO.File]::WriteAllText(' + $literalLog + ', "Starting native owner"); try { ' + $invoke + ' } catch { [IO.File]::AppendAllText(' + $literalLog + ', $_.Exception.ToString()); exit 1 }'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
    $commandLine = '"' + $powershell + '" -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ' + $encoded
    Start-IndependentProcess $commandLine $PSScriptRoot
}

function Start-RunObserver([string]$Directory, [string]$WatchAction, [string]$Specification, $State) {
    $observer = Start-RunHelper $Directory $WatchAction $Specification $State.runId
    try {
        # Caller owns the run mutex until this handoff is persisted. The observer waits for it.
        $State.observerPid = $observer.Id
        $State.observerStartTicks = $observer.StartTime.ToUniversalTime().Ticks.ToString()
        Write-RunJson (Join-Path $Directory 'state.json') $State
    } finally { $observer.Dispose() }
}

function Invoke-JobLease([string]$Directory) {
    $state = Read-RunJson (Join-Path $Directory 'state.json')
    $leasePath = Join-Path $Directory 'job-lease.json'
    $self = Get-Process -Id $PID
    $receipt = [ordered]@{
        runId = $state.runId; jobName = $state.jobName; bootTicks = Get-HostBootTicks
        pid = $PID; startTicks = $self.StartTime.ToUniversalTime().Ticks.ToString()
        state = 'starting'; activeProcessCount = $null; error = $null
    }
    $job = $null
    try {
        if ($self.SessionId -ne $state.sessionId -or $state.jobName -ne (Get-RunJobName $state.runId)) { throw 'Job lease identity mismatch' }
        if (-not ('VanessaRunner.ProcessJob' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'enterprise-job.cs') }
        $job = [VanessaRunner.ProcessJob]::Open($state.jobName)
        if ($null -eq $job) { throw 'Run job disappeared before lease acquisition' }
        # This independent lease retains the named kernel handle if the observer dies.
        # It stays OUTSIDE the job, so zero really means every run process exited.
        $lastJson = ''
        do {
            $receipt.activeProcessCount = @($job.ProcessIds()).Count
            $receipt.state = if ($receipt.activeProcessCount -eq 0) { 'exited' } else { 'running' }
            $json = $receipt | ConvertTo-Json -Depth 12 -Compress
            if ($json -ne $lastJson) { Write-RunJson $leasePath $receipt; $lastJson = $json }
            if ($receipt.activeProcessCount -eq 0) { break }
            $job.WaitForChange(1000)
        } while ($true)
    } catch {
        $receipt.state = 'unknown'; $receipt.error = $_.Exception.Message
        Write-RunJson $leasePath $receipt
    } finally {
        if ($null -ne $job) { $job.Dispose() }
        $self.Dispose()
    }
}

function Start-JobLease([string]$Directory, $State) {
    $lease = Start-RunHelper $Directory 'job_lease' '' $State.runId
    $receiptPath = Join-Path $Directory 'job-lease.json'
    $watcher = [IO.FileSystemWatcher]::new($Directory, 'job-lease.json')
    $watcher.EnableRaisingEvents = $true
    try {
        while (-not [IO.File]::Exists($receiptPath)) {
            if ($lease.HasExited) { throw ('Job lease exited before acquiring the kernel handle; exit=' + $lease.ExitCode) }
            $null = $watcher.WaitForChanged([IO.WatcherChangeTypes]::All, 1000)
        }
        $receipt = Read-RunJson $receiptPath
        if ($receipt.state -ne 'running' -or $receipt.runId -ne $State.runId -or $receipt.jobName -ne $State.jobName -or
            $receipt.pid -ne $lease.Id -or $receipt.startTicks -ne $lease.StartTime.ToUniversalTime().Ticks.ToString()) {
            throw ('Job lease did not acquire this run: ' + $receipt.error)
        }
    } finally { $watcher.Dispose(); $lease.Dispose() }
}

function Confirm-LostRunCleanup($State, [string]$Proof, [string]$BootTicks) {
    $State.state = 'exited'; $State.cleanupStatus = 'exited'; $State.activeProcessCount = 0
    $State.result = 'failed'; $State.scenarioStatus = 'unknown'; $State.failureReason = 'supervision_lost'
    $State.windowVisible = $false; $State.observationError = $null
    foreach ($entry in $State.processes) {
        # OS proof establishes exit, not an unobserved exit code or a passed scenario.
        if ($entry.state -ne 'exited') { $entry.exitCode = $null }
        $entry.state = 'exited'; $entry.windowVisible = $false
    }
    $State | Add-Member -Force -NotePropertyName recoveryStatus -NotePropertyValue 'cleanup_confirmed'
    $State | Add-Member -Force -NotePropertyName recoveryProof -NotePropertyValue @{
        kind = $Proof; observedBootTicks = $BootTicks; observedAt = [DateTime]::UtcNow.ToString('o')
    }
    $State
}

function Test-RunIdentitiesExited($State) {
    $identities = @($State.processes) + @([pscustomobject]@{
        pid = $State.observerPid; startTicks = $State.observerStartTicks; executable = $null
    })
    foreach ($entry in $identities) {
        $created = [long]0
        if (-not $entry.pid -or -not [long]::TryParse([string]$entry.startTicks, [ref]$created) -or $created -le 0) {
            throw 'Run process identity is incomplete'
        }
        $process = Get-Process -Id $entry.pid -ErrorAction SilentlyContinue
        if ($null -eq $process) { continue }
        try {
            $null = $process.Handle
            if ($process.StartTime.ToUniversalTime().Ticks -ne $created) { continue }
            if ($entry.executable -and $process.Path -ne $entry.executable) { throw 'Run executable identity mismatch' }
            if (-not $process.HasExited) { return $false }
        } finally { $process.Dispose() }
    }
    return $true
}

function Release-LostRunResources($State, [string]$Directory) {
    # Unknown historical descendants remain unknown. Release the owned resource, not an invented empty job.
    if (-not (Test-RunIdentitiesExited $State)) {
        $State | Add-Member -Force -NotePropertyName recoveryStatus -NotePropertyValue 'owned_processes_running'
        return $State
    }
    if (-not $State.ibpath -or -not [IO.Path]::IsPathRooted($State.ibpath) -or $State.ibpath.StartsWith('\\')) {
        throw 'A lost file-infobase run has no local resource identity'
    }
    $database = [IO.Path]::GetFullPath((Join-Path $State.ibpath '1Cv8.1CD'))
    $claim = $null
    try {
        # OPEN_EXISTING + no sharing proves this file is not held by another client. Contents never change.
        $claim = [IO.File]::Open($database, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        if (-not (Test-RunIdentitiesExited $State)) { throw 'An owned process remained live during release' }
        $State.state = 'failed'; $State.result = 'failed'; $State.scenarioStatus = 'unknown'
        $State.cleanupStatus = 'released'; $State.activeProcessCount = $null
        $State.failureReason = 'supervision_lost'; $State.observationError = $null; $State.windowVisible = $false
        foreach ($entry in $State.processes) {
            if ($entry.state -ne 'exited') { $entry.exitCode = $null }
            $entry.state = 'exited'; $entry.windowVisible = $false
        }
        $State | Add-Member -Force -NotePropertyName recoveryStatus -NotePropertyValue 'resources_released'
        $State | Add-Member -Force -NotePropertyName recoveryProof -NotePropertyValue @{
            kind = 'infobase_exclusive'; runId = $State.runId; resource = $database
            ownedIdentitiesExited = $true; exclusiveAccess = $true; observedAt = [DateTime]::UtcNow.ToString('o')
        }
        if ($Directory) { Write-RunJson (Join-Path $Directory 'state.json') $State }
        return $State
    } catch [IO.IOException] {
        if (($_.Exception.GetBaseException().HResult -band 0xffff) -notin @(32,33)) { throw }
        $State | Add-Member -Force -NotePropertyName recoveryStatus -NotePropertyValue 'resource_busy'
        return $State
    } finally { if ($null -ne $claim) { $claim.Dispose() } }
}

function Resolve-LostRunCleanup($State, [string]$BootTicks, [string]$Directory = '') {
    $started = [long]0
    if ([long]::TryParse([string]$State.observerStartTicks, [ref]$started) -and $started -gt 0 -and [long]$BootTicks -gt $started) {
        return Confirm-LostRunCleanup $State 'host_restarted' $BootTicks
    }
    # An unnamed historical group cannot be reconstructed from reusable PIDs.
    if (-not $State.jobName) {
        return Release-LostRunResources $State $Directory
    }
    if ($State.jobName -ne (Get-RunJobName $State.runId)) { throw 'Run job identity mismatch' }
    if (-not ('VanessaRunner.ProcessJob' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'enterprise-job.cs') }
    $job = [VanessaRunner.ProcessJob]::Open($State.jobName)
    if ($null -eq $job) {
        # Windows removes a name after the last handle closes even while processes remain.
        # Absence alone is NOT cleanup. Accept only the independent lease's kernel receipt.
        $leasePath = if ($Directory) { Join-Path $Directory 'job-lease.json' } else { '' }
        if ($leasePath -and [IO.File]::Exists($leasePath)) {
            $lease = Read-RunJson $leasePath
            if ($lease.runId -eq $State.runId -and $lease.jobName -eq $State.jobName -and $lease.bootTicks -eq $BootTicks -and
                $lease.state -eq 'exited' -and $lease.activeProcessCount -eq 0) {
                return Confirm-LostRunCleanup $State 'job_lease_exited' $BootTicks
            }
        }
        return Release-LostRunResources $State $Directory
    }
    try {
        if ($job.ProcessIds().Count -eq 0) { return Confirm-LostRunCleanup $State 'named_job_empty' $BootTicks }
    } finally { $job.Dispose() }
    return $State
}

function Invoke-RunCancellation([string]$Directory) {
    $statePath = Join-Path $Directory 'state.json'
    $state = Read-RunState $Directory
    if ($state.state -in @('exited','failed')) { return $state }
    if ($state.runId -ne $RunId -or $state.jobName -ne (Get-RunJobName $RunId)) { throw 'Cancellation requires this run owned named job' }
    if (-not ('VanessaRunner.ProcessJob' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'enterprise-job.cs') }
    $job = [VanessaRunner.ProcessJob]::OpenForCancellation($state.jobName)
    if ($null -eq $job) { throw 'Cancellation cannot confirm an unavailable job' }
    $members = @{}
    $mutex = Get-RunMutex $RunId
    $entered = $false
    try {
        foreach ($memberId in $job.ProcessIds()) {
            $process = Get-Process -Id $memberId -ErrorAction SilentlyContinue
            if ($null -eq $process) { continue }
            if ($job.Contains($process.Handle)) { $members[$memberId] = $process }
            else { $process.Dispose() }
        }
        Write-RunJson (Join-Path $Directory 'cancel.json') @{ runId = $RunId; requestId = [guid]::NewGuid().ToString('D'); issuedAt = [DateTime]::UtcNow.ToString('o') }
        $job.Cancel()
        $entered = Enter-RunMutex $mutex -1
        $state = Read-RunJson $statePath
        if ($state.runId -ne $RunId -or $state.jobName -ne (Get-RunJobName $RunId)) { throw 'Cancellation receipt identity changed' }
        foreach ($entry in $state.processes) {
            $process = $members[[int]$entry.pid]
            if ($null -ne $process -and $process.StartTime.ToUniversalTime().Ticks.ToString() -eq $entry.startTicks) { $entry.exitCode = $process.ExitCode }
            elseif ($entry.state -ne 'exited') { $entry.exitCode = $null }
            $entry.state = 'exited'; $entry.windowVisible = $false
        }
        $state.state = 'failed'; $state.result = 'failed'
        # Resource cancellation never erases an already observed scenario verdict.
        if ($state.scenarioStatus -notin @('passed','failed')) { $state.scenarioStatus = 'unknown' }
        $state.cleanupStatus = 'exited'; $state.activeProcessCount = 0
        $state.failureReason = 'cancelled_by_owner'; $state.observationError = $null
        # Cancellation is not a platform error; unrelated historical IB records are not this run evidence.
        $state.windowVisible = $false
        $state | Add-Member -Force -NotePropertyName cancellationProof -NotePropertyValue @{
            kind = 'named_job_terminated'; runId = $RunId; jobName = $state.jobName
            activeProcessCount = $job.ProcessIds().Count; observedAt = [DateTime]::UtcNow.ToString('o')
        }
        Write-RunJson $statePath $state
        return $state
    } finally {
        foreach ($process in $members.Values) { $process.Dispose() }
        if ($entered) { $mutex.ReleaseMutex() }; $mutex.Dispose(); $job.Dispose()
    }
}

function Invoke-RunRecovery([string]$Directory) {
    $mutex = Get-RunMutex $RunId
    $entered = Enter-RunMutex $mutex 0
    try {
        if (-not $entered) { return Read-RunState $Directory } # An observer already owns this run.
        $state = Read-RunState $Directory
        if ($state.state -in @('exited','failed')) { return $state }
        if ($state.state -notin @('supervision_lost','supervision_error')) { return $state }
        $state = Resolve-LostRunCleanup $state (Get-HostBootTicks) $Directory
        if ($state.recoveryStatus -in @('cleanup_confirmed','resources_released','owned_processes_running','resource_busy')) {
            Write-RunJson (Join-Path $Directory 'state.json') $state
            return $state
        }
        $state.state = 'recovering'; $state.result = 'unknown'; $state.observationError = $null
        $state | Add-Member -Force -NotePropertyName recoveryStatus -NotePropertyValue 'observer_restarted'
        Start-RunObserver $Directory 'recover_watch' '' $state
        return $state
    } finally {
        if ($entered) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-RunWatch([string]$Directory, [string]$Specification) {
    $statePath = Join-Path $Directory 'state.json'
    $mutex = Get-RunMutex $RunId
    $entered = Enter-RunMutex $mutex -1
    $state = Read-RunJson $statePath
    $owned = @{}
    $historical = @()
    $subscriptions = @()
    $fileWatchers = @()
    $job = $null
    try {
        if ($state.observerPid -ne $PID) { return } # This handoff belongs to another observer.
        $observer = Get-Process -Id $PID
        if ($observer.SessionId -ne $state.sessionId) { throw 'Observer did not enter the launch desktop session' }
        $observer.Dispose()
        # Observation and process cleanup do not require interactive input.
        if ($state.kind -eq 'vanessa') { $null = Set-ExecutionDesktopObservation $state }
        if (-not ('VanessaRunner.ProcessJob' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'enterprise-job.cs') }
        if ($Specification) {
            $spec = Read-RunJson $Specification
            $acknowledgeLicense = $false
            if ($spec.PSObject.Properties['acknowledgeDeveloperLicense']) {
                if ($spec.acknowledgeDeveloperLicense -isnot [bool]) { throw 'Developer license acknowledgement must be Boolean' }
                $acknowledgeLicense = $spec.acknowledgeDeveloperLicense
            }
            $state | Add-Member -Force -NotePropertyName acknowledgeDeveloperLicense -NotePropertyValue $acknowledgeLicense
            $state | Add-Member -Force -NotePropertyName developerLicenseNotices -NotePropertyValue @()
            Remove-Item -LiteralPath $Specification
            $job = [VanessaRunner.ProcessJob]::new((Get-RunJobName $RunId))
            $state.jobName = Get-RunJobName $RunId
            # Persist ownership BEFORE any 1C process is created.
            Write-RunJson $statePath $state
        } else {
            if ($state.jobName -ne (Get-RunJobName $RunId)) { throw 'Run job identity mismatch' }
            $job = [VanessaRunner.ProcessJob]::Open($state.jobName)
            if ($null -eq $job) {
                $state = Resolve-LostRunCleanup $state (Get-HostBootTicks) $Directory
                Write-RunJson $statePath $state
                return
            }
            $historical = @($state.processes)
        }
        if ($Specification) {
            $job.BindCurrentProcess()
            Start-JobLease $Directory $state
        }
        # Recovery observes the existing group from outside: it launches no 1C processes
        # and must not join the original observer's nested Windows/WMI parent jobs.
        foreach ($folder in @($Directory, $(if ($state.statusPath) { Split-Path -Parent $state.statusPath })) | Where-Object { $_ } | Select-Object -Unique) {
            $watcher = [IO.FileSystemWatcher]::new($folder)
            $watcher.EnableRaisingEvents = $true
            foreach ($eventName in @('Created','Changed','Renamed')) {
                $subscriptions += Register-ObjectEvent $watcher $eventName -SourceIdentifier ('vr-file-' + [guid]::NewGuid().ToString('N'))
            }
            $fileWatchers += $watcher
        }
        if ($Specification) {
            $state | Add-Member -Force -NotePropertyName executionPhase -NotePropertyValue 'executing'
            if ($spec.preparationCommandLine) {
                if ($state.kind -ne 'vanessa') { throw 'Only a Vanessa run has a prepared scenario plan' }
                # The same restricted run directory holds the deferred native plan.
                # No shell, no second run and no credentials in the state/receipts.
                Write-RunJson (Join-Path $Directory 'scenario-plan.json') @{ commandLine = $spec.commandLine }
                $state | Add-Member -Force -NotePropertyName preparedClientPort -NotePropertyValue (Get-PreparedClientPort $spec.preparationCommandLine)
                $state | Add-Member -Force -NotePropertyName executionContract -NotePropertyValue 'prepared-window/v2'
                Start-OwnedPlatform $spec.preparationCommandLine 'client' $owned $state
                $state.executionPhase = 'preparing'
            } else {
                Start-OwnedPlatform $spec.commandLine 'manager' $owned $state
                $state | Add-Member -Force -NotePropertyName scenarioStartedAt -NotePropertyValue ([DateTime]::UtcNow.ToString('o'))
            }
            Write-RunJson $statePath $state
        }
        Find-OwnedJobProcesses $job $owned
        foreach ($entry in $owned.Values) {
            if ($state.pid -and $entry.process.Id -eq $state.pid -and $entry.startTicks -eq $state.startTicks) { $entry.role = 'manager' }
        }
        $stopPath = Join-Path $Directory 'stop.json'
        $lastStop = ''
        $lastJson = ''
        while ($true) {
            Find-OwnedJobProcesses $job $owned
            $platform = @($owned.Values | Where-Object { $_.role -ne 'helper' })
            if ([IO.File]::Exists($stopPath)) {
                $request = Read-RunJson $stopPath
                if ($request.requestId -ne $lastStop) {
                    Find-OwnedJobProcesses $job $owned
                    $platform = @($owned.Values | Where-Object { $_.role -ne 'helper' })
                    $lastStop = $request.requestId
                    # Client first, manager last. CloseMainWindow is a request, never a forced kill.
                    foreach ($entry in $platform) { $entry.closeAccepted = $null }
                }
            }
            $scenarioDone = $state.executionPhase -eq 'executing' -and
                @($platform | Where-Object { $_.role -eq 'manager' -and -not $_.process.HasExited }).Count -eq 0
            if (-not $lastStop -and -not $scenarioDone -and $state.executionPhase -eq 'executing') {
                $liveManager = @($platform | Where-Object { $_.role -eq 'manager' -and -not $_.process.HasExited })
                if ($liveManager.Count -eq 1) {
                    $mgr = $liveManager[0]
                    $consentPending = $state.requestedProcessing -and (-not $state.processingConsent -or $state.processingConsent.state -eq 'requested')
                    if ($consentPending) {
                        $consent = Confirm-RequestedProcessing $mgr $state.requestedProcessing $job $state
                        if ($null -ne $consent) { $state.processingConsent = $consent }
                    }
                    $mgrDialogs = @([VanessaRunner.ProcessingConsentInput]::DialogsForProcess($mgr.process.Id))
                    $consentHwnd = if ($state.processingConsent -and $state.processingConsent.windowHandle) { [long]$state.processingConsent.windowHandle } else { 0 }
                    $nonConsentDialogs = @($mgrDialogs | Where-Object { $_.ToInt64() -ne $consentHwnd })
                    $statusSettled = (Get-ScenarioStatus $state.statusPath $false) -in @('passed','failed','invalid')
                    if ($nonConsentDialogs.Count -gt 0 -or $statusSettled) {
                        Confirm-RequestedClosure $mgr $job
                        $activeConfirmed = $false
                        if ($mgr.PSObject.Properties['closeConfirmedHwnd'] -and $mgr.closeConfirmedHwnd) {
                            $activeDialogs = @([VanessaRunner.ProcessingConsentInput]::DialogsForProcess($mgr.process.Id) | ForEach-Object { $_.ToInt64() })
                            $activeConfirmed = $activeDialogs -contains [long]$mgr.closeConfirmedHwnd
                        }
                        if (-not $activeConfirmed) {
                            Clear-BlockingModals $mgr $job
                            Request-OwnedClosure $mgr $job
                            Confirm-RequestedClosure $mgr $job
                        }
                    }
                }
            }
            if ($lastStop -or $scenarioDone) {
                foreach ($entry in @($platform | Sort-Object { $_.role -eq 'manager' })) {
                    # A quit confirmation belongs to our close request. Confirm
                    # it before dismissing other blockers; WM_CLOSE on this dialog
                    # would cancel the exit and re-open it on the next iteration.
                    Confirm-RequestedClosure $entry $job
                    $activeConfirmed = $false
                    if ($entry.PSObject.Properties['closeConfirmedHwnd'] -and $entry.closeConfirmedHwnd) {
                        $activeDialogs = @([VanessaRunner.ProcessingConsentInput]::DialogsForProcess($entry.process.Id) | ForEach-Object { $_.ToInt64() })
                        $activeConfirmed = $activeDialogs -contains [long]$entry.closeConfirmedHwnd
                    }
                    if (-not $activeConfirmed) {
                        Clear-BlockingModals $entry $job
                        Request-OwnedClosure $entry $job
                        Confirm-RequestedClosure $entry $job
                    }
                }
            }
            if (($lastStop -or $state.executionPhase -notin @('preparing','ready')) -and
                $platform.Count -gt 0 -and @($platform | Where-Object { -not $_.process.HasExited }).Count -eq 0) {
                foreach ($helper in @($owned.Values | Where-Object { $_.role -eq 'helper' -and -not $_.process.HasExited })) {
                    try { $helper.process.Kill() } catch {}
                }
            }
            if (-not $lastStop -and $state.PSObject.Properties['acknowledgeDeveloperLicense'] -and $state.acknowledgeDeveloperLicense) {
                foreach ($entry in $platform) { Confirm-OwnedDeveloperLicense $entry $job $state }
            }
            if (-not $lastStop -and $state.executionPhase -in @('preparing','ready')) {
                $clients = @($platform | Where-Object { $_.role -eq 'client' -and -not $_.process.HasExited })
                $ready = $clients.Count -eq 1 -and (Test-PreparedClientReady $clients[0] $state.preparedClientPort)
                $state.executionPhase = if ($ready) { 'ready' } else { 'preparing' }
                if ([IO.File]::Exists((Join-Path $Directory 'execute.json'))) {
                    if (-not $ready) { throw 'Prepared TestClient window or owned transport is no longer ready' }
                    $request = Read-RunJson (Join-Path $Directory 'execute.json')
                    if ($request.runId -ne $state.runId) { throw 'Scenario command belongs to another run' }
                    $planPath = Join-Path $Directory 'scenario-plan.json'
                    $plan = Read-RunJson $planPath
                    Start-OwnedPlatform $plan.commandLine 'manager' $owned $state
                    $state.executionPhase = 'executing'
                    $state | Add-Member -Force -NotePropertyName scenarioStartedAt -NotePropertyValue ([DateTime]::UtcNow.ToString('o'))
                    Write-RunJson $statePath $state
                    Remove-Item -LiteralPath $planPath
                    Find-OwnedJobProcesses $job $owned
                }
            }
            $states = @($owned.Values | ForEach-Object { Get-OwnedProcessState $_ })
            foreach ($past in $historical) {
                if (@($states | Where-Object { $_.pid -eq $past.pid -and $_.startTicks -eq $past.startTicks }).Count -eq 0) {
                    if ($past.state -ne 'exited') { $past.exitCode = $null }
                    $past.state = 'exited'; $past.windowVisible = $false
                    $states += $past
                }
            }
            # Count ALL job descendants, including unobserved and intermediate processes.
            # Zero is authoritative: with only the supervisor left, no client can appear later.
            $state.activeProcessCount = @($job.ProcessIds() | Where-Object { $_ -ne $PID }).Count
            $finished = $state.activeProcessCount -eq 0 -and @($states | Where-Object { $_.state -ne 'exited' }).Count -eq 0
            $scenario = Get-ScenarioStatus $state.statusPath $finished
            # A prepared TestClient already exists before the manager/EPF.
            # Only Vanessa's scenario receipt proves processing execution;
            # queuing input or owning that earlier client is not acceptance.
            if ($state.processingConsent -and $scenario -in @('passed','failed')) {
                $state.processingConsent.state = 'accepted'
            }
            $state.windowVisible = @($states | Where-Object { $_.windowVisible }).Count -gt 0
            if ($state.windowVisible) { $state.windowSeen = $true }
            $outcome = Get-RunOutcome $states $state.kind $scenario ([bool]$lastStop) $state.activeProcessCount ([bool]$state.windowSeen)
            $manager = $states | Where-Object { $_.role -eq 'manager' } | Select-Object -First 1
            $state.state = $outcome.state; $state.result = $outcome.result; $state.failureReason = $outcome.failureReason
            if ($finished -and $outcome.failureReason -eq 'exited_before_window') { $state.lastPlatformError = Get-LastEventLogError $state.ibpath }
            $state.cleanupStatus = $outcome.cleanupStatus; $state.scenarioStatus = $scenario
            $state.processes = $states
            $state.exitCode = $manager.exitCode
            $state.windowTitle = $manager.windowTitle; $state.startTicks = $manager.startTicks
            $json = $state | ConvertTo-Json -Depth 12 -Compress
            if ($json -ne $lastJson) { Write-RunJson $statePath $state; $lastJson = $state | ConvertTo-Json -Depth 12 -Compress }
            if ($finished) { break }
            # Event-driven wake-up; this is an observation interval, not a run deadline.
            Get-Event | Remove-Event
            $job.WaitForChange(1000)
        }
    }
    catch {
        $failure = $_.Exception.Message
        $clean = $false
        if ($null -ne $job) {
            $state.activeProcessCount = @($job.ProcessIds() | Where-Object { $_ -ne $PID }).Count
            $clean = $state.activeProcessCount -eq 0
        } elseif ($Specification -and -not $state.pid) { $clean = $true }
        $state.state = if ($clean) { 'failed' } else { 'supervision_error' }
        $state.result = if ($clean) { 'failed' } else { 'unknown' }
        if ($clean) { $state.cleanupStatus = 'exited'; $state.activeProcessCount = 0 }
        $state.observationError = $failure
        $state | Add-Member -Force -NotePropertyName observationErrorDetail -NotePropertyValue @{
            type = $_.Exception.GetType().FullName; stack = $_.ScriptStackTrace
        }
        $state.processes = @($owned.Values | ForEach-Object { Get-OwnedProcessState $_ })
        Write-RunJson $statePath $state
    }
    finally {
        if ($Specification -and [IO.File]::Exists($Specification)) { Remove-Item -LiteralPath $Specification }
        Get-EventSubscriber | Unregister-Event
        foreach ($watcher in $fileWatchers) { $watcher.Dispose() }
        foreach ($entry in $owned.Values) { $entry.process.Dispose() }
        if ($null -ne $job) { $job.Dispose() }
        if ($entered) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Read-RunState([string]$Directory) {
    $state = Read-RunJson (Join-Path $Directory 'state.json')
    $authorizations = @()
    foreach ($capability in @('open_processing','administer_users')) {
        $receiptPath = Join-Path $Directory ('processing-permission-' + $capability + '.json')
        if ([IO.File]::Exists($receiptPath)) {
            $receipt = Read-RunJson $receiptPath
            if ($receipt.runId -ne $state.runId -or $receipt.path -ne $state.requestedProcessing -or $receipt.capability -ne $capability) {
                throw 'Processing permission receipt identity changed'
            }
            $authorizations += $receipt
        }
    }
    if ($authorizations.Count) {
        $state | Add-Member -Force -NotePropertyName processingAuthorizations -NotePropertyValue $authorizations
        # The delivered observation includes independent durable permission receipts.
        # A permission transition must wake enterprise_await even if the process did not change.
        $nativeIdentity = $state.observationId
        $material = $nativeIdentity + ($authorizations | ConvertTo-Json -Depth 12 -Compress)
        $digest = [Security.Cryptography.SHA256]::Create()
        try { $bytes = $digest.ComputeHash([Text.Encoding]::UTF8.GetBytes($material)) } finally { $digest.Dispose() }
        $state | Add-Member -Force -NotePropertyName nativeObservationId -NotePropertyValue $nativeIdentity
        $state.observationId = [guid]::new([byte[]]$bytes[0..15]).ToString('D')
    }

    if ($state.state -in @('starting','running','close_pending','recovering') -and $state.observerPid) {
        $observer = Get-Process -Id $state.observerPid -ErrorAction SilentlyContinue
        if ($null -eq $observer -or $observer.StartTime.ToUniversalTime().Ticks.ToString() -ne $state.observerStartTicks) {
            $state.state = 'supervision_lost'; $state.result = 'unknown'
            $state.observationError = 'Run supervisor exited; saved state is not proof of current process state'
        }
    }
    return $state
}

function Wait-RunObservation([string]$Directory, [string]$Previous) {
    $parsed = [guid]::Empty
    if (-not [guid]::TryParseExact($Previous, 'D', [ref]$parsed)) { throw 'Expected native observationId' }
    # Install the watcher before reading: an intervening receipt is observed
    # immediately; otherwise the next atomic file replacement wakes this call.
    if (-not ('VanessaRunner.ObservationChanges' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'enterprise-observation.cs') }
    $watcher = [VanessaRunner.ObservationChanges]::new($Directory)
    try {
        while ($true) {
            $state = Read-RunState $Directory
            if ($state.state -in @('exited','failed','supervision_lost','supervision_error')) { return $state }
            if (-not $state.observationId) { throw 'Native run has no observationId' }
            if ($state.observationId -ne $Previous) { return $state }
            $watcher.Wait()
        }
    } finally { $watcher.Dispose() }
}

function Start-OwnedPlatform([string]$CommandLine, [string]$Role, $Owned, $State) {
    # Native engine supplies quoting. Never pass the plan to a shell.
    if ($CommandLine -match '^"([^"]+)"\s*(.*)$') { $exe = $Matches[1]; $arguments = $Matches[2] }
    elseif ($CommandLine -match '^(\S+)\s+(.*)$') { $exe = $Matches[1]; $arguments = $Matches[2] }
    else { throw 'Invalid 1C launch plan' }
    if ([IO.Path]::GetFileName($exe) -notin @('1cv8.exe','1cv8c.exe') -or -not [IO.File]::Exists($exe)) {
        throw 'Expected installed 1C executable'
    }
    if ($Role -eq 'manager') {
        $State | Add-Member -Force -NotePropertyName requestedProcessing -NotePropertyValue (Get-RequestedProcessing $arguments $State.kind)
        $State | Add-Member -Force -NotePropertyName processingConsent -NotePropertyValue $null
    }
    $info = [Diagnostics.ProcessStartInfo]::new($exe, $arguments)
    $info.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($info)
    Add-OwnedProcess $process $Role $Owned $exe
    if ($Role -eq 'manager') { $State.pid = $process.Id; $State.startTicks = $Owned[$process.Id].startTicks }
    if (-not $State.ibpath -and $arguments -match '(?i)(?:^|\s)/F\s*(?:"([^"]+)"|(\S+))') {
        $State.ibpath = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
    }
}

function Find-OwnedRunForScenarioLog([string]$ScenarioLog, [string]$Root) {
    if (-not [IO.Path]::IsPathRooted($ScenarioLog)) { throw 'Scenario log must be absolute' }
    $target = [IO.Path]::GetFullPath($ScenarioLog)
    $foundRuns = @()
    foreach ($folder in [IO.Directory]::GetDirectories($Root)) {
        $id = [IO.Path]::GetFileName($folder)
        $parsed = [guid]::Empty
        if (-not [guid]::TryParseExact($id, 'D', [ref]$parsed)) { continue }
        $directory = Get-RunDirectory $id
        $statePath = Join-Path $directory 'state.json'
        $planPath = Join-Path $directory 'scenario-plan.json'
        if (-not [IO.File]::Exists($statePath) -or -not [IO.File]::Exists($planPath)) { continue }
        $state = Read-RunJson $statePath
        if ($state.runId -ne $id -or $state.kind -ne 'vanessa') { continue }
        $plan = Read-RunJson $planPath
        if ($plan.commandLine -notmatch 'VBParams=([^;"\r\n]+)') { continue }
        $parameters = Read-RunJson $Matches[1]
        $log = $parameters.ИмяФайлаЛогВыполненияСценариев
        if ($log -and [IO.Path]::GetFullPath($log) -eq $target) { $foundRuns += $state }
    }
    if ($foundRuns.Count -ne 1) { throw ('Expected exactly one owned prepared launch for scenario log; found ' + $foundRuns.Count) }
    $state = $foundRuns[0]
    $state | Add-Member -Force -NotePropertyName launchDiscovery -NotePropertyValue @{
        contract = 'scenario-log/v1'; scenarioLog = $target
    }
    return $state
}

function Invoke-EnterpriseRun {
    if ($Action -eq 'find') {
        $root = Split-Path -Parent (Get-RunDirectory $RunId)
        return Find-OwnedRunForScenarioLog $SpecPath $root
    }
    $directory = Get-RunDirectory $RunId
    $statePath = Join-Path $directory 'state.json'
    if ($Action -eq 'launch') {
        if ([IO.Directory]::Exists($directory)) { throw 'runId already exists; inspect its state instead of relaunching' }
        $spec = Read-RunJson $SpecPath
        $null = [IO.Directory]::CreateDirectory($directory)
        $directory = Get-RunDirectory $RunId
        $statePath = Join-Path $directory 'state.json'
        # The short-lived launch specification can contain credentials. Restrict it to this user.
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.SetOwner($identity)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $directory -AclObject $acl
        $launchPath = Join-Path $directory 'launch.json'
        Write-RunJson $launchPath $spec
        $state = [ordered]@{
            runId = $RunId; driverVersion = '0.3.2'; kind = $spec.kind; ibpath = $spec.ibpath; statusPath = $spec.statusPath
            processTracking = 'named_windows_job'; activeProcessCount = 0; jobName = $null
            sessionId = (Get-Process -Id $PID).SessionId; bootTicks = Get-HostBootTicks
            recoveryStatus = 'not_requested'; recoveryProof = $null
            state = 'starting'; scenarioStatus = 'pending'; cleanupStatus = 'starting'; result = 'pending'; failureReason = $null
            pid = $null; startTicks = ''; windowTitle = ''; windowVisible = $false; windowSeen = $false; lastPlatformError = $null; exitCode = $null
            observerPid = $null; observerStartTicks = ''; observationError = $null; processes = @()
        }
        Write-RunJson $statePath $state
        try {
            $mutex = Get-RunMutex $RunId
            $entered = Enter-RunMutex $mutex -1
            try { Start-RunObserver $directory 'watch' $launchPath $state }
            finally { if ($entered) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
            return $state
        }
        catch {
            $state.state = 'failed'; $state.result = 'failed'; $state.observationError = $_.Exception.Message
            Write-RunJson $statePath $state
            Remove-Item -LiteralPath $launchPath -ErrorAction SilentlyContinue
            throw
        }
    }
    if (-not [IO.File]::Exists($statePath)) {
        # A run nobody has a record of is a run nobody can judge. For an
        # observer that is an answer about the run, not a failure of the call:
        # the caller stops waiting for a verdict that will never come.
        if ($Action -in @('status','await','stop','recover','execute')) {
            return [pscustomobject][ordered]@{
                runId = $RunId; state = 'supervision_lost'; scenarioStatus = 'unknown'
                cleanupStatus = 'unknown'; result = 'unknown'; failureReason = $null
                activeProcessCount = 0; processes = @()
                observationError = 'No owned launch record for this runId'
            }
        }
        throw 'Unknown runId: no owned launch record'
    }
    if ($Action -eq 'job_lease') { Invoke-JobLease $directory; return }
    if ($Action -in @('watch','recover_watch')) { Invoke-RunWatch $directory $SpecPath; return }
    if ($Action -eq 'recover') { return Invoke-RunRecovery $directory }
    if ($Action -eq 'cancel') { return Invoke-RunCancellation $directory }
    if ($Action -eq 'authorize') { return Authorize-RunProcessing $directory $SpecPath }
    if ($Action -eq 'await') { return Wait-RunObservation $directory $SpecPath }
    $state = Read-RunState $directory
    if ($Action -eq 'execute') {
        if ($state.executionPhase -eq 'executing') { return $state }
        if ($state.kind -ne 'vanessa' -or $state.executionPhase -ne 'ready' -or $state.state -ne 'running') {
            throw 'Scenario execution requires the prepared, live TestClient window'
        }
        if ([IO.File]::Exists((Join-Path $directory 'stop.json'))) { throw 'A stopped run cannot execute scenarios' }
        $requestPath = Join-Path $directory 'execute.json'
        if (-not [IO.File]::Exists($requestPath)) {
            Write-RunJson $requestPath @{ runId = $RunId; requestId = [guid]::NewGuid().ToString(); at = [DateTime]::UtcNow.ToString('o') }
        }
        return $state
    }
    if ($Action -eq 'stop' -and $state.state -in @('starting','running','close_pending')) {
        Write-RunJson (Join-Path $directory 'stop.json') @{ requestId = [guid]::NewGuid().ToString('D') }
        Confirm-RunClosure $state
        $watcher = [IO.FileSystemWatcher]::new($directory, 'state.json')
        $watcher.EnableRaisingEvents = $true
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        try {
            do {
                $state = Read-RunState $directory
                if ($state.state -in @('exited','failed','supervision_lost','supervision_error')) { break }
                $remaining = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
                if ($remaining -le 0) { break }
                $null = $watcher.WaitForChanged([IO.WatcherChangeTypes]::All, $remaining)
            } while ([DateTime]::UtcNow -lt $deadline)
        } finally { $watcher.Dispose() }
        if ($state.state -in @('starting','running','close_pending')) { $state.state = 'close_pending'; $state.cleanupStatus = 'close_pending' }
    }
    # Polling remains passive during execution AND shutdown. Repeated UIA/PrintWindow
    # calls must not compete with the test client's pending command or WM_CLOSE.
    if ($Action -eq 'status' -and $state.state -eq 'close_pending') {
        Add-Type -Path (Join-Path $PSScriptRoot 'enterprise-waits.cs')
        foreach ($entry in $state.processes) {
            if ($entry.role -eq 'manager' -and $entry.state -eq 'running' -and -not $entry.responding) {
                $ownedProcess = Get-Process -Id $entry.pid -ErrorAction SilentlyContinue
                if ($null -ne $ownedProcess -and $ownedProcess.StartTime.ToUniversalTime().Ticks.ToString() -eq $entry.startTicks -and $ownedProcess.Path -eq $entry.executable) {
                    try { $entry | Add-Member -NotePropertyName waitChains -NotePropertyValue @([VanessaRunner.WaitDiagnostics]::Read($ownedProcess)) }
                    finally { $ownedProcess.Dispose() }
                }
            }
        }
    }
    return $state
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-EnterpriseRun | ConvertTo-Json -Depth 12 -Compress }
    catch {
        $failure = $_.Exception.Message
        $directory = Get-RunDirectory $RunId
        if ([IO.Directory]::Exists($directory)) {
            Write-RunJson (Join-Path $directory ('owner-error-' + $Action + '.json')) @{
                action = $Action; error = $failure; at = [DateTime]::UtcNow.ToString('o')
            }
        }
        [Console]::Error.WriteLine($failure); exit 1
    }
}
