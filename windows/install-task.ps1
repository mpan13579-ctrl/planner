# install-task.ps1 -- run the lp0 bridge invisibly in the background,
# starting at every logon and restarting if it dies. The Windows
# equivalent of the repo's launchd/systemd services.
#
#   powershell -ExecutionPolicy Bypass -File windows\install-task.ps1
#
# To stop and remove later:
#   Stop-ScheduledTask -TaskName lp0-bridge
#   Unregister-ScheduledTask -TaskName lp0-bridge -Confirm:$false

$ErrorActionPreference = 'Stop'

$script = Join-Path $PSScriptRoot 'lp0-bridge.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $script + '"')

$trigger = New-ScheduledTaskTrigger -AtLogOn -User ($env:USERDOMAIN + '\' + $env:USERNAME)

$settings = New-ScheduledTaskSettingsSet `
    -RestartCount 99 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName 'lp0-bridge' -Action $action -Trigger $trigger `
    -Settings $settings -Description 'SSH bridge to lp0 (see the planner repo)' -Force | Out-Null

Start-ScheduledTask -TaskName 'lp0-bridge'
Write-Host 'lp0-bridge task installed and started.'
Write-Host 'Verify with:  curl.exe http://localhost:8000/v1/models'
