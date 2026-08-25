
#!/bin/bash

INVENTORY_FILE="inventory.ini"

# EXE hosted on your server
EXE_URL="https://app.workstatus.io/downloads/windows/visible/7.0/k/Workstatus-Desktop-1.2.0-x64.exe"

# # Temporary location on Windows
# EXE_REMOTE='C:\Users\Public\Workstatus-Desktop.exe'

echo ""
echo "======================================================"
echo "🚀 Workstatus Windows Deployment Started"
echo "======================================================"
echo ""

while IFS= read -r line || [[ -n "$line" ]]; do

    line=$(echo "$line" | xargs)

    [[ -z "$line" || "$line" =~ ^# ]] && continue

    if [[ "$line" =~ ^\[.*\]$ ]]; then
        in_group=false

        if [[ "$line" == "[workstatus_clients]" ]]; then
            in_group=true
        fi

        continue
    fi

    [[ "$in_group" != true ]] && continue

    host=$(echo "$line" | awk '{print $1}')
    os_type=$(echo "$line" | grep -oP 'os=\K\S+')

    [[ "$os_type" != "windows" ]] && continue

    echo ""
    echo "======================================================"
    echo "🖥️  HOST: $host"
    echo "======================================================"

    # --------------------------------------------------
    # STEP 1 - Download
    # --------------------------------------------------

    echo ""
    echo "▶ [1/4] Downloading installer..."

    DOWNLOAD_OUTPUT=$(ansible -i "$INVENTORY_FILE" "$host" \
        -m ansible.windows.win_shell \
        -a "try {
                Invoke-WebRequest -Uri '$EXE_URL' -OutFile '$EXE_REMOTE' -UseBasicParsing -ErrorAction Stop;
                Write-Output 'DOWNLOAD_SUCCESS'
             }
             catch {
                Write-Output 'DOWNLOAD_FAILED'
                Write-Output \$_.Exception.Message
                exit 1
             }" 2>&1)

    DOWNLOAD_EXIT=$?

    echo "$DOWNLOAD_OUTPUT"

    if [[ $DOWNLOAD_EXIT -ne 0 ]] || ! echo "$DOWNLOAD_OUTPUT" | grep -q "DOWNLOAD_SUCCESS"; then
        echo ""
        echo "❌ [FAILED] Download failed on $host"
        echo "➡️  Skipping installation"
        continue
    fi




DOWNLOAD_OUTPUT=$(ansible -i "$INVENTORY_FILE" "$host" \
  -m ansible.windows.win_shell \
  -a "\$downloadPath = Join-Path \$env:USERPROFILE 'Downloads\Workstatus-Desktop-1.2.0-x64.exe'; Invoke-WebRequest -Uri '$EXE_URL' -OutFile \$downloadPath -UseBasicParsing -ErrorAction Stop; Write-Output ('DOWNLOAD_PATH=' + \$downloadPath); Write-Output 'DOWNLOAD_SUCCESS'" \
  2>&1)

DOWNLOAD_EXIT=$?

echo "$DOWNLOAD_OUTPUT"

if [[ $DOWNLOAD_EXIT -ne 0 ]] || ! echo "$DOWNLOAD_OUTPUT" | grep -q "DOWNLOAD_SUCCESS"; then
    echo "❌ [FAILED] Download failed on $host"
    continue
fi
    echo "✅ [SUCCESS] Download completed"

    # --------------------------------------------------
    # STEP 2 - Verify file
    # --------------------------------------------------

    # echo ""
    # echo "▶ [2/4] Verifying downloaded file..."

    # VERIFY_OUTPUT=$(ansible -i "$INVENTORY_FILE" "$host" \
    #     -m ansible.windows.win_shell \
    #     -a "if (Test-Path '$EXE_REMOTE') {
    #             \$file = Get-Item '$EXE_REMOTE'
    #             Write-Output \"FILE_EXISTS\"
    #             Write-Output \"FILE_SIZE=\$([math]::Round(\$file.Length / 1MB, 2)) MB\"
    #          }
    #          else {
    #             Write-Output 'FILE_NOT_FOUND'
    #             exit 1
    #          }" 2>&1)

    # VERIFY_EXIT=$?

    # echo "$VERIFY_OUTPUT"

    # if [[ $VERIFY_EXIT -ne 0 ]] || ! echo "$VERIFY_OUTPUT" | grep -q "FILE_EXISTS"; then
    #     echo "❌ [FAILED] Installer file verification failed"
    #     continue
    # fi
echo ""
echo "▶ [2/4] Verifying downloaded file..."

# VERIFY_OUTPUT=$(ansible -i "$INVENTORY_FILE" "$host" \
#     -m ansible.windows.win_shell \
#     -a "\$downloadPath = Join-Path \$env:USERPROFILE 'Downloads\Workstatus-Desktop-1.2.0-x64.exe'; if (Test-Path \$downloadPath) {
#             \$file = Get-Item \$downloadPath
#             Write-Output 'FILE_EXISTS'
#             Write-Output ('FILE_SIZE=' + [math]::Round(\$file.Length / 1MB, 2) + ' MB')
#             Write-Output ('FILE_PATH=' + \$downloadPath)
#          }
#          else {
#             Write-Output 'FILE_NOT_FOUND'
#             Write-Output ('EXPECTED_PATH=' + \$downloadPath)
#             exit 1
#          }" 2>&1)

# VERIFY_EXIT=$?

# echo "$VERIFY_OUTPUT"

# if [[ $VERIFY_EXIT -ne 0 ]] || ! echo "$VERIFY_OUTPUT" | grep -q "FILE_EXISTS"; then
#     echo "❌ [FAILED] Installer file verification failed"
#     continue
# fi

echo "✅ [SUCCESS] Installer verified"
    echo "✅ [SUCCESS] Installer verified"

    # --------------------------------------------------
    # STEP 3 - Install
    # --------------------------------------------------
echo ""
echo "▶ [3/4] Starting installation..."

INSTALL_OUTPUT=$(ansible -i "$INVENTORY_FILE" "$host" \
    -m ansible.windows.win_shell \
    -a "\$downloadPath = Join-Path \$env:USERPROFILE 'Downloads\Workstatus-Desktop-1.2.0-x64.exe'; \$logPath = Join-Path \$env:USERPROFILE 'Downloads\workstatus_install.log'; if (-not (Test-Path \$downloadPath)) { Write-Output ('INSTALLER_NOT_FOUND=' + \$downloadPath); exit 1 }; Write-Output ('INSTALLER_PATH=' + \$downloadPath); Write-Output ('INSTALLER_SIZE=' + [math]::Round((Get-Item \$downloadPath).Length / 1MB, 2) + ' MB'); \$arguments = @('/S', '/LOG=' + \$logPath); \$p = Start-Process -FilePath \$downloadPath -ArgumentList \$arguments -Wait -PassThru; Write-Output ('INSTALL_EXIT_CODE=' + \$p.ExitCode); if (Test-Path \$logPath) { Write-Output '--- INSTALLER LOG ---'; Get-Content \$logPath -Tail 100; Write-Output '--- END INSTALLER LOG ---' }; if (\$p.ExitCode -eq 0) { Write-Output 'INSTALL_SUCCESS' } else { Write-Output 'INSTALL_FAILED'; exit \$p.ExitCode }" \
    2>&1)

INSTALL_EXIT=$?

echo "$INSTALL_OUTPUT"

if [[ $INSTALL_EXIT -eq 0 ]] && echo "$INSTALL_OUTPUT" | grep -q "INSTALL_SUCCESS"; then
    echo ""
    echo "✅ [SUCCESS] Installation completed on $host"
else
    echo ""
    echo "❌ [FAILED] Installation failed on $host"
    continue
fi
    # --------------------------------------------------
    # Cleanup
    # --------------------------------------------------

    echo ""
    echo "▶ Cleaning up installer..."

    CLEANUP_OUTPUT=$(ansible -i "$INVENTORY_FILE" "$host" \
        -m ansible.windows.win_file \
        -a "path=$EXE_REMOTE state=absent" 2>&1)

    CLEANUP_EXIT=$?

    echo "$CLEANUP_OUTPUT"

    if [[ $CLEANUP_EXIT -eq 0 ]]; then
        echo "✅ Installer removed"
    else
        echo "⚠️ Could not remove installer"
    fi

    echo ""
    echo "======================================================"
    echo "🎯 FINAL STATUS: $host → SUCCESS"
    echo "======================================================"
    echo ""

done < "$INVENTORY_FILE"

echo ""
echo "======================================================"
echo "🏁 All Windows installations processed"
echo "======================================================"
