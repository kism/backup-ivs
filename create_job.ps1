# Creates a job that runs every day, downloads the folders/videos to the parent directory
# Cygwin apps are a bit particular about paths, In prod I use a network drive which works well V:\

$Script_Path = "C:\path\to\backup-ivs\backupivs.ps1 -pw `"<apipassword>`" -out ..\ -conf .\settings.json -production"
$Working_Directory = "C:\path\to\backup-ivs\"
$User_id = ""
$Task_name = "Backup-IVS"
$Task_time = "18:00"
$Task_path = "MYFOLDER"

# $Powershell_7 = "C:\Program Files\PowerShell\7\pwsh.exe"
$Powershell_5 = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

# Actual code

$Task = Get-ScheduledTask | Where-Object { $_.TaskName -eq $Task_name } | Select-Object -First 1
if ($null -ne $Task) {
    $task | Unregister-ScheduledTask -Confirm:$false
    Write-Host “Task $Task_name was removed” -ForegroundColor Yellow
}

$Job_Sched = New-ScheduledTaskTrigger -Daily -At $Task_time

$Action = New-ScheduledTaskAction -Execute $Powershell_5 -Argument $Script_Path -WorkingDirectory $Working_Directory

$Owner = New-ScheduledTaskPrincipal -UserId $User_id -RunLevel Limited

$Task = New-ScheduledTask -Action $Action -Trigger $Job_Sched -Principal $Owner

Register-ScheduledTask -TaskPath $Task_path -TaskName $Task_name -InputObject $Task
