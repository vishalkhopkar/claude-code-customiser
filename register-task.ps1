# Registers (or re-registers) the Windows scheduled task that runs
# update-spinner-verbs.ps1 every INTERVAL_HOURS. Re-run after changing
# INTERVAL_HOURS or TASK_NAME in config.json.
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [datetime]$StartAt = (Get-Date).AddMinutes(1),
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'

$config = Get-Content -Raw -Encoding UTF8 $ConfigPath | ConvertFrom-Json
$taskName = $config.TASK_NAME

if ($Unregister) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Removed scheduled task '$taskName'"
    return
}

$script = Join-Path $PSScriptRoot 'update-spinner-verbs.ps1'
$resolvedConfig = (Resolve-Path $ConfigPath).Path
$retryBudgetSec = ([int]$config.MAX_RETRIES + 1) * ([int]$config.CLAUDE_TIMEOUT_SECONDS + [int]$config.RETRY_DELAY_SECONDS)

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -WorkingDirectory $PSScriptRoot `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -ConfigPath `"$resolvedConfig`""
$trigger = New-ScheduledTaskTrigger -Once -At $StartAt `
    -RepetitionInterval (New-TimeSpan -Hours ([int]$config.INTERVAL_HOURS))
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Seconds ($retryBudgetSec + 300))

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
    -Description 'Refreshes Claude Code spinner verbs from a headless Claude run' -Force | Out-Null

Write-Host "Registered '$taskName': every $($config.INTERVAL_HOURS) h, first run at $StartAt"
