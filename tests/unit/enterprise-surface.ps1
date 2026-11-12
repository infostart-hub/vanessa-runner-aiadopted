param([string]$Helper = (Join-Path $PSScriptRoot '../../tools/enterprise-consent.cs'))
$ErrorActionPreference = 'Stop'
Add-Type -Path $Helper
Add-Type -AssemblyName System.Windows.Forms
$container = [Windows.Forms.Form]::new()
$main = [Windows.Forms.Form]::new()
$dialog = [Windows.Forms.Form]::new()
$foreignRoot = [Windows.Forms.Form]::new()
try {
    $null = $container.Handle
    $main.Owner = $container
    $main.Show()
    [Windows.Forms.Application]::DoEvents()
    if ([VanessaRunner.ProcessingConsentInput]::PrimaryWindowForProcess($PID) -ne $main.Handle) { throw 'Hidden platform container replaced the visible application surface' }
    $main.WindowState = [Windows.Forms.FormWindowState]::Minimized
    [Windows.Forms.Application]::DoEvents()
    if ([VanessaRunner.ProcessingConsentInput]::PrimaryWindowForProcess($PID) -ne $main.Handle) { throw 'Minimized application surface was not restored to its primary handle' }
    [Windows.Forms.Application]::DoEvents()
    if ($main.WindowState -eq [Windows.Forms.FormWindowState]::Minimized) { throw 'Minimized application surface stayed minimized instead of restoring for visual execution' }
    $dialog.Owner = $main
    $dialog.Show()
    [Windows.Forms.Application]::DoEvents()
    if ([VanessaRunner.ProcessingConsentInput]::PrimaryWindowForProcess($PID) -ne $main.Handle) { throw 'Owned dialog replaced the application root surface' }
    $foreignRoot.Show()
    [Windows.Forms.Application]::DoEvents()
    if ([VanessaRunner.ProcessingConsentInput]::PrimaryWindowForProcess($PID) -ne [IntPtr]::Zero) { throw 'Ambiguous application surfaces were guessed' }
    $foreignRoot.Close()
    $dialog.Close()
    [Windows.Forms.Application]::DoEvents()
    if (-not [VanessaRunner.ProcessingConsentInput]::RequestClose($PID, $main.Handle)) { throw 'Close intent was not queued to the actual application surface' }
    [Windows.Forms.Application]::DoEvents()
    if ($main.Visible) { throw 'Actual application window did not close' }
    'PASS: visible native surface, hidden owner, owned dialog, ambiguity and explicit closure'
} finally {
    $foreignRoot.Dispose(); $dialog.Dispose(); $main.Dispose(); $container.Dispose()
}
