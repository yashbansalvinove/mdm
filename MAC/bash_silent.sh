#!/bin/bash

INVENTORY_FILE="inventory.ini"
KEY="$HOME/.ssh/id_ed25519"

TOKEN_API_URL="https://api.workstatus.io/api/get_user_stealth_token"
PKG_URL="https://app.workstatus.io/downloads/mac/py/7.0/Workstatus.pkg"
PKG_NAME="Workstatus.pkg"
TOKEN_FILE_NAME="user_token_file.txt"
LAUNCH_LABEL="io.workstatus.app"

# ======================================================
# CHECK REQUIRED COMMANDS
# ======================================================

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is not installed"
    exit 1
fi

if ! command -v ssh >/dev/null 2>&1; then
    echo "ssh is not installed"
    exit 1
fi

if ! command -v sshpass >/dev/null 2>&1; then
    echo "sshpass is not installed"
    echo "Install with: sudo apt install sshpass -y"
    exit 1
fi

if [[ ! -f "$INVENTORY_FILE" ]]; then
    echo "Inventory file not found: $INVENTORY_FILE"
    exit 1
fi

# ======================================================
# SSH KEY (optional, password still used as fallback)
# ======================================================

if [[ ! -f "$KEY" ]]; then
    echo "SSH key not found. Generating..."
    ssh-keygen -t ed25519 -N "" -f "$KEY"
fi

# ======================================================
# HELPERS
# ======================================================

inventory_value() {
    local line="$1"
    local key="$2"
    echo "$line" | grep -oP "${key}=\K\S+" | tr -d "\"'" || true
}

ssh_mac() {
    local user="$1"
    local ip="$2"
    local pass="$3"
    shift 3

    SSHPASS="$pass" sshpass -e ssh \
        -o StrictHostKeyChecking=no \
        -o PreferredAuthentications=password,publickey \
        -o PubkeyAuthentication=yes \
        "$user@$ip" "$@"
}

get_workstatus_token() {
    local user_email="$1"

    TOKEN=""

    echo ""
    echo "======================================================"
    echo "Getting Workstatus user token"
    echo "  email: $user_email"
    echo "======================================================"
    echo ""

    TOKEN_RESPONSE=$(curl --silent --show-error \
        --location \
        --request GET "$TOKEN_API_URL" \
        --header "Content-Type: application/json" \
        --data-raw "{\"email\":\"$user_email\"}")

    if [[ $? -ne 0 ]]; then
        echo "Failed to call token API for $user_email"
        echo "$TOKEN_RESPONSE"
        return 1
    fi

    echo "API Response:"
    echo "$TOKEN_RESPONSE"
    echo ""

    TOKEN=$(echo "$TOKEN_RESPONSE" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

    if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
        echo "Could not extract token for $user_email"
        return 1
    fi

    echo "Token received for $user_email"
    echo ""
    return 0
}

# ======================================================
# DEPLOYMENT
# ======================================================

echo "======================================================"
echo "Workstatus macOS Deployment Started"
echo "======================================================"
echo ""

while IFS= read -r line || [[ -n "$line" ]]; do

    line=$(echo "$line" | xargs)

    [[ -z "$line" || "$line" =~ ^# ]] && continue

    if [[ "$line" =~ ^\[.*\]$ ]]; then
        in_group=false
        if [[ "$line" == "[workstatus_clients]" || "$line" == "[clients]" ]]; then
            in_group=true
        fi
        continue
    fi

    [[ "$in_group" != true ]] && continue

    host=$(echo "$line" | awk '{print $1}')
    [[ -z "$host" ]] && continue

    os_type=$(inventory_value "$line" "os")
    if [[ -n "$os_type" && "$os_type" != "macos" && "$os_type" != "mac" && "$os_type" != "darwin" ]]; then
        continue
    fi

    user=$(inventory_value "$line" "user")
    pass=$(inventory_value "$line" "pass")
    user_email=$(inventory_value "$line" "email")

    echo ""
    echo "======================================================"
    echo "HOST: $host"
    echo "  user:  ${user:-<missing>}"
    echo "  email: ${user_email:-<missing>}"
    echo "======================================================"
    echo ""

    if [[ -z "$user" || -z "$pass" ]]; then
        echo "Skipping $host: inventory needs user= and pass="
        echo "  Example: $host user=pradeep pass=secret email=user@example.com"
        continue
    fi

    if [[ -z "$user_email" ]]; then
        echo "Skipping $host: inventory needs email="
        continue
    fi

    if ! get_workstatus_token "$user_email"; then
        echo "Skipping $host because token fetch failed"
        continue
    fi

    echo "[1/5] Configuring SSH..."

    SSHPASS="$pass" sshpass -e ssh-copy-id \
        -o StrictHostKeyChecking=no \
        "$user@$host" >/dev/null 2>&1 || true

    if ssh_mac "$user" "$host" "$pass" "echo SSH_OK" >/dev/null 2>&1; then
        echo "SSH ready"
    else
        echo "Could not SSH to $user@$host"
        echo "On the Mac enable: System Settings > General > Sharing > Remote Login"
        continue
    fi

    echo ""
    echo "[2/5] Removing existing Workstatus and installing the package..."

    if ssh_mac "$user" "$host" "$pass" \
        "TOKEN='$TOKEN' PKG_URL='$PKG_URL' PKG_NAME='$PKG_NAME' TOKEN_FILE_NAME='$TOKEN_FILE_NAME' LAUNCH_LABEL='$LAUNCH_LABEL' SUDO_PASS='$pass' bash -s" <<'EOF'

set -e

sudo_rm() {
    local path="$1"
    [ -e "$path" ] || return 0

    chmod -R u+w "$path" 2>/dev/null || true
    chflags -R nouchg,noschg "$path" 2>/dev/null || true

    if rm -rf "$path" 2>/dev/null; then
        echo "REMOVED=$path"
        return 0
    fi

    printf '%s\n' "$SUDO_PASS" | sudo -S -p "" chflags -R nouchg,noschg "$path" >/dev/null 2>&1 || true
    if printf '%s\n' "$SUDO_PASS" | sudo -S -p "" rm -rf "$path"; then
        echo "REMOVED_WITH_SUDO=$path"
        return 0
    fi

    echo "REMOVE_FAILED=$path"
    return 1
}

echo "Removing existing Workstatus..."

pkill -f "[Ww]orkstatus" 2>/dev/null || true
killall Workstatus 2>/dev/null || true
killall "Workstatus Desktop" 2>/dev/null || true
sleep 2

UID_NUM=$(id -u)
launchctl bootout "gui/${UID_NUM}/${LAUNCH_LABEL}" 2>/dev/null || true
launchctl unload "$HOME/Library/LaunchAgents/${LAUNCH_LABEL}.plist" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/${LAUNCH_LABEL}.plist"

for app_path in \
    "/Applications/Workstatus.app" \
    "/Applications/Workstatus Desktop.app" \
    "/Applications/Workstatus-Desktop.app" \
    "$HOME/Applications/Workstatus.app" \
    "$HOME/Applications/Workstatus Desktop.app"
do
    sudo_rm "$app_path" || true
done

SUPPORT_DIR="$HOME/Library/Application Support/Workstatus"
if [ -d "$SUPPORT_DIR" ]; then
    sudo_rm "$SUPPORT_DIR"
else
    echo "APPSUPPORT_ALREADY_ABSENT"
fi

osascript -e 'tell application "System Events" to delete (every login item whose name contains "Workstatus")' >/dev/null 2>&1 || true

echo "EXISTING_WORKSTATUS_CLEANUP_DONE"

DOWNLOADS="$HOME/Downloads"
mkdir -p "$DOWNLOADS"
PKG_PATH="$DOWNLOADS/$PKG_NAME"
EXPAND_DIR="$DOWNLOADS/workstatus_pkg_expand"
mkdir -p "$SUPPORT_DIR"

echo ""
echo "Downloading Workstatus package..."
echo "DOWNLOAD_URL=$PKG_URL"

rm -f "$PKG_PATH"
curl --fail --location --retry 3 \
    "$PKG_URL" \
    -o "$PKG_PATH"

if [ ! -f "$PKG_PATH" ]; then
    echo "PKG_DOWNLOAD_FAILED"
    exit 1
fi

echo "PKG_DOWNLOAD_SUCCESS"
echo "PKG_PATH=$PKG_PATH"
echo "PKG_SIZE=$(du -h "$PKG_PATH" | awk '{print $1}')"

xattr -dr com.apple.quarantine "$PKG_PATH" 2>/dev/null || true

echo ""
echo "Installing Workstatus.pkg..."

rm -rf "$EXPAND_DIR"
APP_EXEC=""
WORK_DIR=""
DEST_APP=""

extract_payload() {
    local payload="$1"
    local dest="$2"
    mkdir -p "$dest"
    if gzip -t "$payload" 2>/dev/null; then
        (cd "$dest" && gzip -dc "$payload" | cpio -idm 2>/dev/null)
    else
        (cd "$dest" && cpio -idm < "$payload" 2>/dev/null) || \
        (cd "$dest" && cat "$payload" | cpio -idm 2>/dev/null)
    fi
}

if pkgutil --expand-full "$PKG_PATH" "$EXPAND_DIR" >/tmp/ws_pkgutil.log 2>&1; then
    echo "PKG_EXPAND_FULL_SUCCESS"
elif pkgutil --expand "$PKG_PATH" "$EXPAND_DIR" >/tmp/ws_pkgutil.log 2>&1; then
    echo "PKG_EXPAND_SUCCESS"
    find "$EXPAND_DIR" -name Payload -type f | while read -r payload; do
        extract_payload "$payload" "$(dirname "$payload")/extracted"
    done
else
    echo "PKG_EXPAND_FAILED"
    cat /tmp/ws_pkgutil.log 2>/dev/null || true

    echo "Trying sudo installer..."
    if printf '%s\n' "$SUDO_PASS" | sudo -S -p "" installer -pkg "$PKG_PATH" -target / ; then
        echo "PKG_INSTALLER_SUCCESS"
    else
        echo "PKG_INSTALLER_FAILED"
        exit 1
    fi
fi

FOUND_APP=$(find "$EXPAND_DIR" /Applications "$HOME/Applications" "$SUPPORT_DIR" \
    -name "Workstatus.app" -type d 2>/dev/null | head -1 || true)

if [ -z "$FOUND_APP" ]; then
    FOUND_APP=$(find "$EXPAND_DIR" /Applications "$HOME/Applications" \
        -maxdepth 4 -name "*.app" -type d 2>/dev/null | grep -i Workstatus | head -1 || true)
fi

if [ -n "$FOUND_APP" ]; then
    echo "FOUND_APP=$FOUND_APP"
    DEST_APP="$SUPPORT_DIR/Workstatus.app"
    if [ "$FOUND_APP" != "$DEST_APP" ]; then
        rm -rf "$DEST_APP"
        ditto "$FOUND_APP" "$DEST_APP"
    fi
    xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
    chmod -R u+rwX "$DEST_APP" 2>/dev/null || true
    APP_EXEC="$DEST_APP/Contents/MacOS/Workstatus"
    if [ ! -e "$APP_EXEC" ]; then
        APP_EXEC=$(find "$DEST_APP/Contents/MacOS" -type f | head -1)
    fi
    chmod +x "$APP_EXEC" 2>/dev/null || true
    WORK_DIR="$(dirname "$APP_EXEC")"
    echo "INSTALLED_APP=$DEST_APP"
    echo "APP_EXEC=$APP_EXEC"
else
    FOUND_BIN=$(find "$EXPAND_DIR" "$SUPPORT_DIR" /usr/local/bin \
        -type f -name "Workstatus" 2>/dev/null | head -1)
    if [ -n "$FOUND_BIN" ]; then
        echo "FOUND_BIN=$FOUND_BIN"
        mkdir -p "$SUPPORT_DIR"
        cp "$FOUND_BIN" "$SUPPORT_DIR/Workstatus"
        chmod +x "$SUPPORT_DIR/Workstatus"
        APP_EXEC="$SUPPORT_DIR/Workstatus"
        WORK_DIR="$SUPPORT_DIR"
        echo "APP_EXEC=$APP_EXEC"
    fi
fi

if [ -z "$APP_EXEC" ] || [ ! -e "$APP_EXEC" ]; then
    echo "INSTALLED_BINARY_NOT_FOUND"
    echo "Expanded package contents:"
    ls -la "$EXPAND_DIR" 2>/dev/null || true
    find "$EXPAND_DIR" 2>/dev/null | head -80
    ls -la /Applications | grep -i work || true
    exit 1
fi

TOKEN_PATH="$SUPPORT_DIR/$TOKEN_FILE_NAME"
printf '%s' "$TOKEN" > "$TOKEN_PATH"
chmod 600 "$TOKEN_PATH"
echo "TOKEN_FILE_PATH=$TOKEN_PATH"

if [ -n "$WORK_DIR" ]; then
    cp "$TOKEN_PATH" "$WORK_DIR/$TOKEN_FILE_NAME"
    chmod 600 "$WORK_DIR/$TOKEN_FILE_NAME"
    echo "TOKEN_COPIED_BESIDE_BINARY=$WORK_DIR/$TOKEN_FILE_NAME"
fi

rm -f "$PKG_PATH"
rm -rf "$EXPAND_DIR"
echo "PKG_CLEANUP_SUCCESS"

echo ""
echo "Registering autostart LaunchAgent..."

LAUNCH_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$LAUNCH_DIR"
PLIST="$LAUNCH_DIR/${LAUNCH_LABEL}.plist"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCH_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${APP_EXEC}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${WORK_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${SUPPORT_DIR}/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${SUPPORT_DIR}/stderr.log</string>
</dict>
</plist>
PLIST

echo "AUTOSTART_PLIST=$PLIST"

launchctl bootout "gui/${UID_NUM}/${LAUNCH_LABEL}" 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true

if launchctl bootstrap "gui/${UID_NUM}" "$PLIST" 2>/dev/null; then
    launchctl enable "gui/${UID_NUM}/${LAUNCH_LABEL}" 2>/dev/null || true
    launchctl kickstart -k "gui/${UID_NUM}/${LAUNCH_LABEL}" 2>/dev/null || true
    echo "AUTOSTART_LAUNCHCTL_BOOTSTRAP_SUCCESS"
else
    launchctl load -w "$PLIST" 2>/dev/null || true
    echo "AUTOSTART_LAUNCHCTL_LOAD_ATTEMPTED"
fi

osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"${SUPPORT_DIR}/Workstatus.app\", hidden:false}" >/dev/null 2>&1 || true

echo "AUTOSTART_REGISTERED"

echo ""
echo "Starting Workstatus..."

open -a "$SUPPORT_DIR/Workstatus.app" >/dev/null 2>&1 || \
    open "$APP_EXEC" >/dev/null 2>&1 || \
    "$APP_EXEC" >/dev/null 2>&1 &

sleep 5

if pgrep -if "Workstatus" >/dev/null 2>&1; then
    echo "WORKSTATUS_PROCESS_RUNNING"
    echo "WORKSTATUS_PIDS=$(pgrep -if Workstatus | tr '\n' ' ')"
else
    echo "WORKSTATUS_NOT_RUNNING_NOW"
    echo "AUTOSTART_WILL_LAUNCH_ON_LOGON"
fi

echo "WORKSTATUS_START_SUCCESS"
echo "Workstatus macOS setup completed"

EOF
    then

        echo ""
        echo "SUCCESS: $host"

    else

        echo ""
        echo "FAILED on $host"
        continue

    fi

    echo "======================================================"
    echo "FINAL STATUS: $host -> SUCCESS"
    echo "======================================================"

done < "$INVENTORY_FILE"

echo ""
echo "======================================================"
echo "All macOS installations processed"
echo "======================================================"
