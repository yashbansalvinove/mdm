$ErrorActionPreference = "Continue"

Write-Output "REMOVING_EXISTING_WORKSTATUS"

# --------------------------------------------------
# Stop running Workstatus processes
# --------------------------------------------------

$processNames = @(
    "Workstatus",
    "Workstatus-Desktop",
    "Workstatus Desktop",
    "WorkstatusDesktop"
)

foreach ($name in $processNames) {
    Get-Process -Name $name -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

Get-Process | Where-Object {
    $_.ProcessName -like "*Workstatus*"
} | Stop-Process -Force -ErrorAction SilentlyContinue

Start-Sleep -Seconds 2
Write-Output "WORKSTATUS_PROCESSES_STOPPED"

# --------------------------------------------------
# Uninstall Workstatus Desktop from Programs and Features
# --------------------------------------------------

$uninstalled = $false

$uninstallRoots = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
)

$apps = foreach ($root in $uninstallRoots) {
    if (Test-Path $root) {
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        }
    }
}

$workstatusApps = $apps | Where-Object {
    $_.DisplayName -and (
        $_.DisplayName -like "*Workstatus*Desktop*" -or
        $_.DisplayName -like "*Workstatus Desktop*" -or
        $_.DisplayName -like "Workstatus*"
    )
}

if ($null -eq $workstatusApps) {
    Write-Output "WORKSTATUS_DESKTOP_NOT_INSTALLED"
}
else {
    foreach ($app in @($workstatusApps)) {
        Write-Output ("FOUND_INSTALLED_APP=" + $app.DisplayName)

        $uninstallCmd = $app.QuietUninstallString
        if ([string]::IsNullOrWhiteSpace($uninstallCmd)) {
            $uninstallCmd = $app.UninstallString
        }

        if ([string]::IsNullOrWhiteSpace($uninstallCmd)) {
            Write-Output "UNINSTALL_STRING_MISSING"
            continue
        }

        Write-Output ("UNINSTALL_STRING=" + $uninstallCmd)

        try {
            if ($uninstallCmd -match 'msiexec') {
                if ($uninstallCmd -notmatch '/quiet|/qn|/silent') {
                    $uninstallCmd = ($uninstallCmd -replace '/I', '/X') + " /qn /norestart"
                }

                $p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $uninstallCmd -Wait -PassThru -WindowStyle Hidden
                Write-Output ("UNINSTALL_EXIT=" + $p.ExitCode)
            }
            else {
                if ($uninstallCmd.StartsWith('"')) {
                    $exe = $uninstallCmd.Substring(1, $uninstallCmd.IndexOf('"', 1) - 1)
                    $args = $uninstallCmd.Substring($uninstallCmd.IndexOf('"', 1) + 1).Trim()
                }
                else {
                    $parts = $uninstallCmd -split '\s+', 2
                    $exe = $parts[0]
                    $args = if ($parts.Count -gt 1) { $parts[1] } else { "" }
                }

                if ($args -notmatch '/S|/silent|/SILENT|/quiet') {
                    $args = ($args + " /S").Trim()
                }

                if (Test-Path $exe) {
                    $p = Start-Process -FilePath $exe -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
                    Write-Output ("UNINSTALL_EXIT=" + $p.ExitCode)
                }
                else {
                    $p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", ($uninstallCmd + " /S") -Wait -PassThru -WindowStyle Hidden
                    Write-Output ("UNINSTALL_EXIT=" + $p.ExitCode)
                }
            }

            $uninstalled = $true
            Write-Output ("UNINSTALL_RAN=" + $app.DisplayName)
        }
        catch {
            Write-Output "UNINSTALL_FAILED"
            Write-Output $_.Exception.Message
        }
    }
}

if ($uninstalled) {
    Write-Output "WORKSTATUS_DESKTOP_UNINSTALLED"
}

Start-Sleep -Seconds 2

Get-Process | Where-Object {
    $_.ProcessName -like "*Workstatus*"
} | Stop-Process -Force -ErrorAction SilentlyContinue

Start-Sleep -Seconds 1

# --------------------------------------------------
# Remove leftover install folders
# --------------------------------------------------

$programFolders = @(
    (Join-Path $env:ProgramFiles "Workstatus"),
    (Join-Path $env:ProgramFiles "Workstatus Desktop"),
    (Join-Path $env:ProgramFiles "Workstatus-Desktop")
)

if (${env:ProgramFiles(x86)}) {
    $programFolders += @(
        (Join-Path ${env:ProgramFiles(x86)} "Workstatus"),
        (Join-Path ${env:ProgramFiles(x86)} "Workstatus Desktop"),
        (Join-Path ${env:ProgramFiles(x86)} "Workstatus-Desktop")
    )
}

$localPrograms = Join-Path $env:LOCALAPPDATA "Programs"
if (Test-Path $localPrograms) {
    Get-ChildItem $localPrograms -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*Workstatus*" } |
        ForEach-Object { $programFolders += $_.FullName }
}

foreach ($folder in $programFolders) {
    if (Test-Path $folder) {
        try {
            Remove-Item -Path $folder -Recurse -Force -ErrorAction Stop
            Write-Output ("REMOVED_PROGRAM_FOLDER=" + $folder)
        }
        catch {
            Write-Output ("REMOVE_PROGRAM_FOLDER_FAILED=" + $folder)
            Write-Output $_.Exception.Message
        }
    }
}

# --------------------------------------------------
# Clear AppData\Roaming\Workstatus
# --------------------------------------------------

$roamingWorkstatus = Join-Path $env:APPDATA "Workstatus"

if (Test-Path $roamingWorkstatus) {
    try {
        Remove-Item -Path $roamingWorkstatus -Recurse -Force -ErrorAction Stop
        Write-Output ("REMOVED_APPDATA=" + $roamingWorkstatus)
    }
    catch {
        Write-Output "REMOVE_APPDATA_FAILED"
        Write-Output ("APPDATA_PATH=" + $roamingWorkstatus)
        Write-Output $_.Exception.Message

        Get-ChildItem -Path $roamingWorkstatus -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

        if (Test-Path $roamingWorkstatus) {
            Write-Output "APPDATA_STILL_PRESENT"
        }
        else {
            Write-Output ("REMOVED_APPDATA=" + $roamingWorkstatus)
        }
    }
}
else {
    Write-Output "APPDATA_ALREADY_ABSENT"
}

$localWorkstatus = Join-Path $env:LOCALAPPDATA "Workstatus"
if (Test-Path $localWorkstatus) {
    Remove-Item -Path $localWorkstatus -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output ("REMOVED_LOCALAPPDATA=" + $localWorkstatus)
}

# --------------------------------------------------
# Remove previous autostart leftovers
# --------------------------------------------------

Unregister-ScheduledTask -TaskName "Workstatus" -Confirm:$false -ErrorAction SilentlyContinue
schtasks.exe /Delete /TN "Workstatus" /F 2>$null | Out-Null
Write-Output "AUTOSTART_TASK_REMOVED"

$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
if (Test-Path $runKey) {
    Remove-ItemProperty -Path $runKey -Name "Workstatus" -ErrorAction SilentlyContinue
    Write-Output "AUTOSTART_REGISTRY_REMOVED"
}

$startupShortcut = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\Workstatus.lnk"
if (Test-Path $startupShortcut) {
    Remove-Item -Path $startupShortcut -Force -ErrorAction SilentlyContinue
    Write-Output "AUTOSTART_SHORTCUT_REMOVED"
}

Write-Output "EXISTING_WORKSTATUS_CLEANUP_DONE"
exit 0
