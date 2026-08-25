#!/bin/bash

INVENTORY_FILE="inventory.ini"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_PS1="$SCRIPT_DIR/start_workstatus.ps1"
REMOVE_PS1="$SCRIPT_DIR/remove_workstatus.ps1"

# ======================================================
# CONFIGURATION
# ======================================================

# Installer/package URL
# This can later be populated dynamically from API.
EXE_URL="https://app.workstatus.io/downloads/windows/py/7.0/Workstatus.zip"

# Token API
TOKEN_API_URL="https://api.workstatus.io/api/get_user_stealth_token"

# ZIP/package
ZIP_NAME="Workstatus.zip"

# EXE inside the ZIP
EXE_NAME="Workstatus.exe"

# Token file
TOKEN_FILE_NAME="user_token_file.txt"

# Extracted application directory
APP_DIR_NAME="workstatus_extract"

# ======================================================
# CHECK REQUIRED COMMANDS
# ======================================================

if ! command -v curl >/dev/null 2>&1; then
    echo "❌ curl is not installed"
    exit 1
fi

if ! command -v ansible >/dev/null 2>&1; then
    echo "❌ ansible is not installed"
    exit 1
fi

if command -v jq >/dev/null 2>&1; then
    JSON_PARSER="jq"
else
    if ! command -v python3 >/dev/null 2>&1; then
        echo "❌ Neither jq nor python3 is available"
        exit 1
    fi

    JSON_PARSER="python3"
fi

# ======================================================
# CHECK INVENTORY
# ======================================================

if [[ ! -f "$INVENTORY_FILE" ]]; then
    echo "❌ Inventory file not found: $INVENTORY_FILE"
    exit 1
fi

# ======================================================
# GET TOKEN FOR ONE INVENTORY USER
# ======================================================

get_workstatus_token() {

    local user_email="$1"

    TOKEN=""
    TOKEN_BASE64=""

    echo ""
    echo "======================================================"
    echo "🔐 Getting Workstatus user token"
    echo "   email: $user_email"
    echo "======================================================"
    echo ""

    TOKEN_RESPONSE=$(curl --silent --show-error \
        --location \
        --request GET "$TOKEN_API_URL" \
        --header "Content-Type: application/json" \
        --data-raw "{\"email\":\"$user_email\"}")

    local curl_exit=$?

    if [[ $curl_exit -ne 0 ]]; then
        echo "❌ Failed to call token API for $user_email"
        echo "$TOKEN_RESPONSE"
        return 1
    fi

    echo "API Response:"
    echo "$TOKEN_RESPONSE"
    echo ""

    if [[ "$JSON_PARSER" == "jq" ]]; then

        TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '
            .response.data.token //
            .response.data.access_token //
            .token //
            .data.token //
            .access_token //
            .data.access_token //
            empty
        ')

    else

        echo "⚠️ jq is not installed."
        echo "Trying Python JSON parser..."

        TOKEN=$(python3 -c '
import sys
import json

data = json.load(sys.stdin)

response = data.get("response", {})
response_data = response.get("data", {})

token = (
    response_data.get("token")
    or response_data.get("access_token")
    or data.get("token")
    or data.get("access_token")
    or data.get("data", {}).get("token")
    or data.get("data", {}).get("access_token")
)

if token:
    print(token)
' <<< "$TOKEN_RESPONSE")

    fi

    if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
        echo "❌ Could not extract token for $user_email"
        echo "API response:"
        echo "$TOKEN_RESPONSE"
        return 1
    fi

    TOKEN_BASE64=$(printf '%s' "$TOKEN" | base64 -w 0)

    if [[ -z "$TOKEN_BASE64" ]]; then
        echo "❌ Failed to encode token for $user_email"
        return 1
    fi

    echo "✅ Token received for $user_email"
    echo ""
    return 0
}

# ======================================================
# DEPLOYMENT START
# ======================================================

echo "======================================================"
echo "🚀 Workstatus Windows Deployment Started"
echo "======================================================"
echo ""

# ======================================================
# PROCESS INVENTORY
# ======================================================

while IFS= read -r line || [[ -n "$line" ]]; do

    # Remove leading/trailing whitespace
    line=$(echo "$line" | xargs)

    # Ignore empty lines/comments
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    # --------------------------------------------------
    # Detect inventory group
    # --------------------------------------------------

    if [[ "$line" =~ ^\[.*\]$ ]]; then

        in_group=false

        if [[ "$line" == "[workstatus_clients]" ]]; then
            in_group=true
        fi

        continue
    fi

    [[ "$in_group" != true ]] && continue

    # --------------------------------------------------
    # Extract host
    # --------------------------------------------------

    host=$(echo "$line" | awk '{print $1}')

    [[ -z "$host" ]] && continue

    # --------------------------------------------------
    # Extract OS
    # --------------------------------------------------

    os_type=$(echo "$line" | grep -oP 'os=\K\S+' || true)

    [[ "$os_type" != "windows" ]] && continue

    # --------------------------------------------------
    # Extract email for this host
    # --------------------------------------------------

    user_email=$(echo "$line" | grep -oP 'email=\K\S+' || true)
    user_email=${user_email//\"/}
    user_email=${user_email//\'/}

    echo ""
    echo "======================================================"
    echo "🖥️  HOST: $host"
    echo "   email: ${user_email:-<missing>}"
    echo "======================================================"
    echo ""

    if [[ -z "$user_email" ]]; then
        echo "❌ No email= value in inventory for $host"
        echo "   Example: $host ansible_user=\"yash\" os=windows email=user@example.com"
        continue
    fi

    if ! get_workstatus_token "$user_email"; then
        echo "❌ Skipping $host because token fetch failed"
        continue
    fi

    # ==================================================
    # STEP 1 - REMOVE EXISTING WORKSTATUS DESKTOP
    # ==================================================

    echo "▶ [1/6] Removing existing Workstatus Desktop and AppData..."

    if [[ ! -f "$REMOVE_PS1" ]]; then
        echo "❌ remove_workstatus.ps1 not found: $REMOVE_PS1"
        continue
    fi

    REMOVE_COPY_OUTPUT=$(ansible -i "$INVENTORY_FILE" "$host" \
        -m ansible.windows.win_copy \
        -a "src='$REMOVE_PS1' dest='C:\\Users\\Public\\ws_remove.ps1'" \
        2>&1)

    REMOVE_COPY_EXIT=$?
    echo "$REMOVE_COPY_OUTPUT"

    if [[ $REMOVE_COPY_EXIT -ne 0 ]]; then
        echo ""
        echo "❌ [FAILED] Could not copy remove script to $host"
        continue
    fi

    REMOVE_OUTPUT=$(ansible -i "$INVENTORY_FILE" "$host" \
        -m ansible.windows.win_shell \
        -a "& 'C:\\Users\\Public\\ws_remove.ps1'" \
        2>&1)

    REMOVE_EXIT=$?
    echo "$REMOVE_OUTPUT"

    if [[ $REMOVE_EXIT -eq 0 ]] && \
       echo "$REMOVE_OUTPUT" | grep -q "EXISTING_WORKSTATUS_CLEANUP_DONE"; then

        echo "✅ [SUCCESS] Existing Workstatus Desktop / AppData cleaned"

    else

        echo "⚠️ Could not fully remove previous Workstatus; continuing anyway"

    fi

    # ==================================================
    # STEP 2 - CREATE TOKEN FILE
    # ==================================================

    echo "▶ [2/6] Creating user_token_file.txt..."

    TOKEN_OUTPUT=$(ansible -i "$INVENTORY_FILE" "$host" \
        -m ansible.windows.win_shell \
        --extra-vars "token_base64=$TOKEN_BASE64" \
        --extra-vars "token_file_name=$TOKEN_FILE_NAME" \
        -a '
            $downloadDir = Join-Path $env:USERPROFILE "Downloads"
            $tokenPath = Join-Path $downloadDir "{{ token_file_name }}"

            $base64 = "{{ token_base64 }}"

            try {

                # Decode Base64 token
                $bytes = [System.Convert]::FromBase64String($base64)

                $token = [System.Text.Encoding]::UTF8.GetString($bytes)

                # Write token as UTF-8 without BOM
                [System.IO.File]::WriteAllText(
                    $tokenPath,
                    $token,
                    [System.Text.UTF8Encoding]::new($false)
                )

                if (Test-Path $tokenPath) {

                    $file = Get-Item $tokenPath

                    Write-Output "TOKEN_FILE_SUCCESS"
                    Write-Output ("TOKEN_FILE_PATH=" + $tokenPath)
                    Write-Output ("TOKEN_FILE_SIZE=" + $file.Length)

                }
                else {

                    Write-Output "TOKEN_FILE_FAILED"
                    exit 1

                }

            }
            catch {

                Write-Output "TOKEN_FILE_FAILED"
                Write-Output $_.Exception.Message
                exit 1

            }
        ' 2>&1)

    TOKEN_EXIT=$?

    echo "$TOKEN_OUTPUT"

    if [[ $TOKEN_EXIT -ne 0 ]] || \
       ! echo "$TOKEN_OUTPUT" | grep -q "TOKEN_FILE_SUCCESS"; then

        echo ""
        echo "❌ [FAILED] Could not create token file on $host"
        continue
    fi

    echo "✅ [SUCCESS] user_token_file.txt created"

    # ==================================================
    # STEP 3 - DOWNLOAD AND EXTRACT APPLICATION
    # ==================================================

    echo ""
    echo "▶ [3/6] Downloading Workstatus package..."

    DOWNLOAD_OUTPUT=$(ansible -i "$INVENTORY_FILE" "$host" \
        -m ansible.windows.win_shell \
        --extra-vars "exe_url=$EXE_URL" \
        --extra-vars "zip_name=$ZIP_NAME" \
        --extra-vars "exe_name=$EXE_NAME" \
        --extra-vars "app_dir_name=$APP_DIR_NAME" \
        -a '
            $downloadDir = Join-Path $env:USERPROFILE "Downloads"

            $zipPath = Join-Path $downloadDir "{{ zip_name }}"
            $appDir = Join-Path $downloadDir "{{ app_dir_name }}"
            $exePath = Join-Path $appDir "{{ exe_name }}"

            $url = "{{ exe_url }}"

            Write-Output ("DOWNLOAD_URL=" + $url)

            try {

                # ------------------------------------------
                # Remove old ZIP
                # ------------------------------------------

                if (Test-Path $zipPath) {

                    Remove-Item `
                        $zipPath `
                        -Force `
                        -ErrorAction SilentlyContinue

                }

                # ------------------------------------------
                # Download ZIP
                # ------------------------------------------

                Invoke-WebRequest `
                    -Uri $url `
                    -OutFile $zipPath `
                    -UseBasicParsing `
                    -ErrorAction Stop

                if (-not (Test-Path $zipPath)) {

                    Write-Output "ZIP_DOWNLOAD_FAILED"
                    exit 1

                }

                $zipFile = Get-Item $zipPath

                Write-Output "ZIP_DOWNLOAD_SUCCESS"
                Write-Output ("ZIP_PATH=" + $zipPath)
                Write-Output ("ZIP_SIZE=" + [math]::Round($zipFile.Length / 1MB, 2) + " MB")

                # ------------------------------------------
                # Remove previous extraction
                # ------------------------------------------

                if (Test-Path $appDir) {

                    Remove-Item `
                        $appDir `
                        -Recurse `
                        -Force `
                        -ErrorAction Stop

                }

                # ------------------------------------------
                # Create application directory
                # ------------------------------------------

                New-Item `
                    -ItemType Directory `
                    -Path $appDir `
                    -Force |
                    Out-Null

                # ------------------------------------------
                # Extract complete ZIP
                # ------------------------------------------

                Expand-Archive `
                    -Path $zipPath `
                    -DestinationPath $appDir `
                    -Force `
                    -ErrorAction Stop

                # ------------------------------------------
                # Find Workstatus.exe
                # ------------------------------------------

                $foundExe = Get-ChildItem `
                    -Path $appDir `
                    -Filter "{{ exe_name }}" `
                    -Recurse `
                    -File |
                    Select-Object -First 1

                if ($null -eq $foundExe) {

                    Write-Output "EXE_NOT_FOUND_IN_ZIP"
                    Write-Output "Extracted files:"

                    Get-ChildItem `
                        -Path $appDir `
                        -Recurse `
                        -File |
                        Select-Object -First 100 |
                        ForEach-Object {
                            Write-Output $_.FullName
                        }

                    exit 1

                }

                # ------------------------------------------
                # If EXE is inside a nested directory,
                # use that directory as the application dir.
                # ------------------------------------------

                $actualAppDir = $foundExe.Directory.FullName
                $actualExePath = $foundExe.FullName

                # ------------------------------------------
                # Check PyInstaller _internal directory
                # ------------------------------------------

                $internalDir = Join-Path $actualAppDir "_internal"

                if (-not (Test-Path $internalDir)) {

                    Write-Output "INTERNAL_DIRECTORY_NOT_FOUND"
                    Write-Output ("EXPECTED_INTERNAL=" + $internalDir)

                    exit 1

                }

                $exeFile = Get-Item $actualExePath

                Write-Output "DOWNLOAD_SUCCESS"
                Write-Output ("EXE_PATH=" + $actualExePath)
                Write-Output ("APP_PATH=" + $actualAppDir)
                Write-Output ("INTERNAL_PATH=" + $internalDir)
                Write-Output ("EXE_SIZE=" + [math]::Round($exeFile.Length / 1MB, 2) + " MB")

            }
            catch {

                Write-Output "DOWNLOAD_FAILED"
                Write-Output $_.Exception.Message
                exit 1

            }
        ' 2>&1)

    DOWNLOAD_EXIT=$?

    echo "$DOWNLOAD_OUTPUT"

    if [[ $DOWNLOAD_EXIT -ne 0 ]] || \
       ! echo "$DOWNLOAD_OUTPUT" | grep -q "DOWNLOAD_SUCCESS"; then

        echo ""
        echo "❌ [FAILED] Download/extraction failed on $host"
        continue
    fi

    echo "✅ [SUCCESS] Workstatus package downloaded and extracted"

    # ==================================================
    # STEP 4 - VERIFY FILES
    # ==================================================

    echo ""
    echo "▶ [4/6] Verifying Workstatus and token..."

    VERIFY_OUTPUT=$(ansible -i "$INVENTORY_FILE" "$host" \
        -m ansible.windows.win_shell \
        --extra-vars "exe_name=$EXE_NAME" \
        --extra-vars "token_file_name=$TOKEN_FILE_NAME" \
        --extra-vars "app_dir_name=$APP_DIR_NAME" \
        -a '
            $downloadDir = Join-Path $env:USERPROFILE "Downloads"

            $appRoot = Join-Path $downloadDir "{{ app_dir_name }}"
            $tokenPath = Join-Path $downloadDir "{{ token_file_name }}"

            $success = $true

            # ------------------------------------------
            # Find Workstatus.exe
            # ------------------------------------------

            $foundExe = Get-ChildItem `
                -Path $appRoot `
                -Filter "{{ exe_name }}" `
                -Recurse `
                -File |
                Select-Object -First 1

            if ($null -eq $foundExe) {

                Write-Output "EXE_NOT_FOUND"
                $success = $false

            }
            else {

                $exePath = $foundExe.FullName
                $appDir = $foundExe.Directory.FullName

                $exe = Get-Item $exePath

                Write-Output "EXE_EXISTS"
                Write-Output ("EXE_PATH=" + $exePath)
                Write-Output ("EXE_SIZE=" + [math]::Round($exe.Length / 1MB, 2) + " MB")

                # ------------------------------------------
                # Verify _internal
                # ------------------------------------------

                $internalDir = Join-Path $appDir "_internal"

                if (Test-Path $internalDir) {

                    Write-Output "INTERNAL_EXISTS"
                    Write-Output ("INTERNAL_PATH=" + $internalDir)

                }
                else {

                    Write-Output "INTERNAL_NOT_FOUND"
                    $success = $false

                }

            }

            # ------------------------------------------
            # Verify token in Downloads
            # ------------------------------------------

            if (Test-Path $tokenPath) {

                $token = Get-Content $tokenPath -Raw

                if ([string]::IsNullOrWhiteSpace($token)) {

                    Write-Output "TOKEN_FILE_EMPTY"
                    $success = $false

                }
                else {

                    $tokenFile = Get-Item $tokenPath

                    Write-Output "TOKEN_FILE_EXISTS"
                    Write-Output ("TOKEN_FILE_PATH=" + $tokenPath)
                    Write-Output ("TOKEN_FILE_SIZE=" + $tokenFile.Length)

                }

            }
            else {

                Write-Output "TOKEN_FILE_NOT_FOUND"
                $success = $false

            }

            # ------------------------------------------
            # Final verification
            # ------------------------------------------

            if ($success) {

                Write-Output "VERIFY_SUCCESS"

            }
            else {

                Write-Output "VERIFY_FAILED"
                exit 1

            }
        ' 2>&1)

    VERIFY_EXIT=$?

    echo "$VERIFY_OUTPUT"

    if [[ $VERIFY_EXIT -ne 0 ]] || \
       ! echo "$VERIFY_OUTPUT" | grep -q "VERIFY_SUCCESS"; then

        echo ""
        echo "❌ [FAILED] File verification failed on $host"
        continue
    fi

    echo "✅ [SUCCESS] Workstatus and token verified"

# ==================================================
# STEP 5 - START WORKSTATUS
# ==================================================

echo ""
echo "▶ [5/6] Starting Workstatus and enabling autostart..."

if [[ ! -f "$START_PS1" ]]; then
    echo "❌ start_workstatus.ps1 not found: $START_PS1"
    continue
fi

COPY_OUTPUT=$(ansible -i "$INVENTORY_FILE" "$host" \
    -m ansible.windows.win_copy \
    -a "src='$START_PS1' dest='C:\\Users\\Public\\ws_start.ps1'" \
    2>&1)

COPY_EXIT=$?
echo "$COPY_OUTPUT"

if [[ $COPY_EXIT -ne 0 ]]; then
    echo ""
    echo "❌ [FAILED] Could not copy start script to $host"
    continue
fi

START_OUTPUT=$(ansible -i "$INVENTORY_FILE" "$host" \
    -m ansible.windows.win_shell \
    -a "& 'C:\\Users\\Public\\ws_start.ps1' -AppDirName '$APP_DIR_NAME' -ExeName '$EXE_NAME' -TokenFileName '$TOKEN_FILE_NAME'" \
    2>&1)

START_EXIT=$?

echo "$START_OUTPUT"

if [[ $START_EXIT -eq 0 ]] && \
   echo "$START_OUTPUT" | grep -q "WORKSTATUS_START_SUCCESS"; then

    echo ""
    echo "✅ [SUCCESS] Workstatus started and autostart enabled on $host"
    echo "   It will launch at user logon / after reboot"

else

    echo ""
    echo "❌ [FAILED] Could not start Workstatus on $host"
    continue

fi

# ==================================================
# STEP 6 - CLEANUP ZIP
# ==================================================

echo ""
echo "▶ [6/6] Cleaning up downloaded ZIP..."

CLEANUP_OUTPUT=$(ansible -i "$INVENTORY_FILE" "$host" \
    -m ansible.windows.win_shell \
    --extra-vars "zip_name=$ZIP_NAME" \
    -a '
$downloadDir = Join-Path `
    $env:USERPROFILE `
    "Downloads"

$zipPath = Join-Path `
    $downloadDir `
    "{{ zip_name }}"

try {

    if (Test-Path $zipPath) {

        Remove-Item `
            $zipPath `
            -Force `
            -ErrorAction Stop

        Write-Output "ZIP_CLEANUP_SUCCESS"

    }
    else {

        Write-Output "ZIP_ALREADY_REMOVED"

    }

}
catch {

    Write-Output "ZIP_CLEANUP_FAILED"
    Write-Output $_.Exception.Message
    exit 1
}
' 2>&1)

CLEANUP_EXIT=$?

echo "$CLEANUP_OUTPUT"

if [[ $CLEANUP_EXIT -eq 0 ]] && \
   (
       echo "$CLEANUP_OUTPUT" | grep -q "ZIP_CLEANUP_SUCCESS" ||
       echo "$CLEANUP_OUTPUT" | grep -q "ZIP_ALREADY_REMOVED"
   ); then

    echo "✅ ZIP removed"

else

    echo "⚠️ Could not remove ZIP"

fi


# ==================================================
# FINAL STATUS
# ==================================================

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
















































