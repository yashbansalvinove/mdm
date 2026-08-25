param(
    [string]$AppDirName = "workstatus_extract",
    [string]$ExeName = "Workstatus.exe",
    [string]$TokenFileName = "user_token_file.txt"
)

$ErrorActionPreference = "Stop"

$downloadDir = Join-Path $env:USERPROFILE "Downloads"
$appRoot = Join-Path $downloadDir $AppDirName
$downloadTokenPath = Join-Path $downloadDir $TokenFileName

$foundExe = Get-ChildItem -Path $appRoot -Filter $ExeName -Recurse -File |
    Select-Object -First 1

if ($null -eq $foundExe) {
    Write-Output "EXTRACTED_WORKSTATUS_NOT_FOUND"
    Write-Output "SEARCH_PATH=$appRoot"
    exit 1
}

$sourceExe = $foundExe.FullName
$sourceDir = $foundExe.Directory.FullName

Write-Output "EXTRACTED_WORKSTATUS_FOUND"
Write-Output "SOURCE_EXE=$sourceExe"
Write-Output "SOURCE_DIRECTORY=$sourceDir"

$internalDir = Join-Path $sourceDir "_internal"
if (-not (Test-Path $internalDir)) {
    Write-Output "INTERNAL_DIRECTORY_NOT_FOUND"
    Write-Output "INTERNAL_PATH=$internalDir"
    exit 1
}

Write-Output "INTERNAL_DIRECTORY_FOUND"

if (-not (Test-Path $downloadTokenPath)) {
    Write-Output "TOKEN_FILE_NOT_FOUND"
    Write-Output "TOKEN_PATH=$downloadTokenPath"
    exit 1
}

Write-Output "TOKEN_FILE_FOUND"

$sourceTokenPath = Join-Path $sourceDir $TokenFileName
try {
    Copy-Item -Path $downloadTokenPath -Destination $sourceTokenPath -Force
    Write-Output "SOURCE_TOKEN_COPY_SUCCESS"
    Write-Output "SOURCE_TOKEN_PATH=$sourceTokenPath"
}
catch {
    Write-Output "SOURCE_TOKEN_COPY_FAILED"
    Write-Output $_.Exception.Message
    exit 1
}

$installedDir = Join-Path $env:APPDATA "Workstatus"
$installedExe = Join-Path $installedDir $ExeName
$installedInternal = Join-Path $installedDir "_internal"

Write-Output ""
Write-Output "Installing complete Workstatus copy to AppData..."
Write-Output ("INSTALL_DEST=" + $installedDir)

Get-Process -Name "Workstatus" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

if (Test-Path $installedDir) {
    Remove-Item -Path $installedDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output "CLEARED_EXISTING_APPDATA"
}

New-Item -ItemType Directory -Path $installedDir -Force | Out-Null

$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& robocopy.exe $sourceDir $installedDir /E /COPY:DAT /R:3 /W:2 /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
$roboExit = $LASTEXITCODE
$ErrorActionPreference = $previousErrorAction

if ($roboExit -ge 8) {
    Write-Output "INSTALL_COPY_FAILED"
    Write-Output ("ROBOCOPY_EXIT=" + $roboExit)
    exit 1
}

Write-Output "INSTALL_COPY_SUCCESS"
Write-Output ("ROBOCOPY_EXIT=" + $roboExit)

if (-not (Test-Path $installedExe)) {
    Write-Output "INSTALLED_WORKSTATUS_NOT_FOUND"
    Write-Output "EXPECTED_PATH=$installedExe"
    exit 1
}

if (-not (Test-Path $installedInternal)) {
    Write-Output "INSTALLED_INTERNAL_NOT_FOUND"
    Write-Output "EXPECTED_INTERNAL=$installedInternal"
    exit 1
}

$sourceInternalFiles = @(Get-ChildItem -Path $internalDir -Recurse -File).Count
$installedInternalFiles = @(Get-ChildItem -Path $installedInternal -Recurse -File).Count

Write-Output ("INTERNAL_SOURCE_FILES=" + $sourceInternalFiles)
Write-Output ("INTERNAL_DEST_FILES=" + $installedInternalFiles)

if ($installedInternalFiles -lt $sourceInternalFiles) {
    Write-Output "INSTALLED_INTERNAL_INCOMPLETE"
    exit 1
}

Write-Output "INSTALLED_WORKSTATUS_FOUND"
Write-Output "INSTALLED_EXE=$installedExe"
Write-Output "INSTALLED_INTERNAL=$installedInternal"

$installedTokenPath = Join-Path $installedDir $TokenFileName
try {
    Copy-Item -Path $downloadTokenPath -Destination $installedTokenPath -Force
    Write-Output "INSTALLED_TOKEN_COPY_SUCCESS"
    Write-Output "INSTALLED_TOKEN=$installedTokenPath"
}
catch {
    Write-Output "INSTALLED_TOKEN_COPY_FAILED"
    Write-Output $_.Exception.Message
    exit 1
}

if (-not (Test-Path $installedTokenPath)) {
    Write-Output "INSTALLED_TOKEN_VERIFICATION_FAILED"
    exit 1
}

$installedToken = Get-Content $installedTokenPath -Raw
if ([string]::IsNullOrWhiteSpace($installedToken)) {
    Write-Output "INSTALLED_TOKEN_EMPTY"
    exit 1
}

Write-Output "INSTALLED_TOKEN_VERIFIED"

Write-Output ""
Write-Output "Registering Workstatus autostart..."

$autostartOk = $false
$taskName = "Workstatus"
$userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

Write-Output ("AUTOSTART_USER=" + $userId)
Write-Output ("AUTOSTART_USERNAME=" + $env:USERNAME)
Write-Output ("AUTOSTART_USERDOMAIN=" + $env:USERDOMAIN)

$cmdPath = Join-Path $installedDir "start-workstatus.cmd"
$vbsPath = Join-Path $installedDir "start-workstatus.vbs"
$logPath = Join-Path $installedDir "autostart.log"
$q = [char]34

$cmdLines = @(
    "@echo off"
    "setlocal"
    ("cd /d " + $q + $installedDir + $q)
    ("set PATH=" + $installedDir + ";" + $installedInternal + ";%PATH%")
    ("echo %DATE% %TIME% launcher started >> " + $q + $logPath + $q)
    ("start " + $q + $q + " /D " + $q + $installedDir + $q + " " + $q + $installedExe + $q)
)
Set-Content -Path $cmdPath -Value $cmdLines -Encoding ASCII -Force

$vbsLines = @(
    ("Set o = CreateObject(" + $q + "WScript.Shell" + $q + ")")
    ("o.CurrentDirectory = " + $q + $installedDir + $q)
    ("o.Run " + $q + $q + $q + $installedExe + $q + $q + $q + ", 1, False")
)
Set-Content -Path $vbsPath -Value $vbsLines -Encoding ASCII -Force

if (-not ((Test-Path $cmdPath) -and (Test-Path $vbsPath))) {
    Write-Output "AUTOSTART_LAUNCHER_FAILED"
    exit 1
}

Write-Output "AUTOSTART_LAUNCHER_SUCCESS"
Write-Output ("AUTOSTART_CMD=" + $cmdPath)
Write-Output ("AUTOSTART_VBS=" + $vbsPath)

Get-Process -Name "Workstatus" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

try {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    $taskAction = New-ScheduledTaskAction -Execute $installedExe -WorkingDirectory $installedDir
    $taskTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
    $taskSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew `
        -DontStopOnIdleEnd
    $taskSettings.ExecutionTimeLimit = "PT0S"

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $taskAction `
        -Trigger $taskTrigger `
        -Principal $taskPrincipal `
        -Settings $taskSettings `
        -Description "Start Workstatus at user logon" `
        -Force |
        Out-Null

    $registeredTask = Get-ScheduledTask -TaskName $taskName
    Write-Output "AUTOSTART_TASK_SUCCESS"
    Write-Output ("AUTOSTART_TASK=" + $taskName)
    Write-Output ("AUTOSTART_TASK_USER=" + $userId)
    Write-Output ("AUTOSTART_TASK_STATE=" + $registeredTask.State)
    $autostartOk = $true
}
catch {
    Write-Output "AUTOSTART_TASK_FAILED"
    Write-Output $_.Exception.Message

    schtasks.exe /Delete /TN $taskName /F 2>$null | Out-Null
    schtasks.exe /Create /TN $taskName /TR $cmdPath /SC ONLOGON /RU $userId /IT /RL LIMITED /F
    if ($LASTEXITCODE -eq 0) {
        Write-Output "AUTOSTART_TASK_SCHTASKS_SUCCESS"
        $autostartOk = $true
    }
    else {
        Write-Output "AUTOSTART_TASK_SCHTASKS_FAILED"
        schtasks.exe /Create /TN $taskName /TR $cmdPath /SC ONLOGON /IT /RL LIMITED /F
        if ($LASTEXITCODE -eq 0) {
            Write-Output "AUTOSTART_TASK_SCHTASKS_NO_RU_SUCCESS"
            $autostartOk = $true
        }
    }
}

try {
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    if (-not (Test-Path $runKey)) {
        New-Item -Path $runKey -Force | Out-Null
    }

    $runCommand = "wscript.exe //nologo " + $q + $vbsPath + $q
    Set-ItemProperty -Path $runKey -Name "Workstatus" -Value $runCommand -Type String -Force
    $runValue = (Get-ItemProperty -Path $runKey -Name "Workstatus").Workstatus
    Write-Output "AUTOSTART_REGISTRY_SUCCESS"
    Write-Output ("AUTOSTART_REGISTRY=" + $runValue)
    $autostartOk = $true
}
catch {
    Write-Output "AUTOSTART_REGISTRY_FAILED"
    Write-Output $_.Exception.Message
}

try {
    $startupFolder = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
    if (-not (Test-Path $startupFolder)) {
        New-Item -ItemType Directory -Path $startupFolder -Force | Out-Null
    }

    $shortcutPath = Join-Path $startupFolder "Workstatus.lnk"
    $wshell = New-Object -ComObject WScript.Shell
    $shortcut = $wshell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $installedExe
    $shortcut.WorkingDirectory = $installedDir
    $shortcut.WindowStyle = 7
    $shortcut.Save()

    if (Test-Path $shortcutPath) {
        Write-Output "AUTOSTART_SHORTCUT_SUCCESS"
        Write-Output ("AUTOSTART_SHORTCUT=" + $shortcutPath)
        $autostartOk = $true
    }
    else {
        Write-Output "AUTOSTART_SHORTCUT_FAILED"
    }
}
catch {
    Write-Output "AUTOSTART_SHORTCUT_FAILED"
    Write-Output $_.Exception.Message
}

try {
    $enabledBytes = [byte[]](0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
    $approvedRun = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
    $approvedFolder = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"

    foreach ($approvedPath in @($approvedRun, $approvedFolder)) {
        if (-not (Test-Path $approvedPath)) {
            New-Item -Path $approvedPath -Force | Out-Null
        }
    }

    New-ItemProperty -Path $approvedRun -Name "Workstatus" -PropertyType Binary -Value $enabledBytes -Force | Out-Null
    New-ItemProperty -Path $approvedFolder -Name "Workstatus.lnk" -PropertyType Binary -Value $enabledBytes -Force | Out-Null
    Write-Output "AUTOSTART_APPROVED_SUCCESS"
}
catch {
    Write-Output "AUTOSTART_APPROVED_FAILED"
    Write-Output $_.Exception.Message
}

if (-not $autostartOk) {
    Write-Output "AUTOSTART_REGISTER_FAILED"
    exit 1
}

Write-Output "AUTOSTART_REGISTERED"

Write-Output ""
Write-Output "Starting installed Workstatus..."

$startedNow = $false
$explorer = Get-Process -Name "explorer" -ErrorAction SilentlyContinue

if ($null -eq $explorer) {
    Write-Output "NO_INTERACTIVE_SESSION"
    Write-Output "Workstatus will start at next user logon"
}
else {
    Write-Output "INTERACTIVE_SESSION_FOUND"

    try {
        Start-ScheduledTask -TaskName $taskName
        Write-Output "SCHEDULED_TASK_STARTED"
        $startedNow = $true
    }
    catch {
        Write-Output "SCHEDULED_TASK_START_FAILED"
        Write-Output $_.Exception.Message
    }

    try {
        Start-Process -FilePath $installedExe -WorkingDirectory $installedDir
        Write-Output "EXPLORER_LAUNCHED"
        $startedNow = $true
    }
    catch {
        Write-Output "EXPLORER_LAUNCH_FAILED"
        Write-Output $_.Exception.Message
    }

    if (-not $startedNow) {
        try {
            $cmdLine = "start " + $q + $q + " /D " + $q + $installedDir + $q + " " + $q + $installedExe + $q
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $cmdLine -WindowStyle Hidden
            Write-Output "CMD_START_LAUNCHED"
            $startedNow = $true
        }
        catch {
            Write-Output "CMD_START_FAILED"
            Write-Output $_.Exception.Message
        }
    }
}

Start-Sleep -Seconds 8

$runningWorkstatus = Get-Process -Name "Workstatus" -ErrorAction SilentlyContinue
if ($null -ne $runningWorkstatus) {
    Write-Output "WORKSTATUS_PROCESS_RUNNING"
    Write-Output ("WORKSTATUS_PIDS=" + ($runningWorkstatus.Id -join ","))
    Write-Output "WORKSTATUS_START_SUCCESS"
    exit 0
}

if ($autostartOk) {
    Write-Output "WORKSTATUS_NOT_RUNNING_NOW"
    Write-Output "AUTOSTART_WILL_LAUNCH_ON_LOGON"
    Write-Output "WORKSTATUS_START_SUCCESS"
    exit 0
}

Write-Output "INSTALLED_WORKSTATUS_NOT_RUNNING"
exit 1
