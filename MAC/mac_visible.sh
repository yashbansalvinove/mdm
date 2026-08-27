#!/bin/bash

INVENTORY_FILE="inventory.ini"
KEY="$HOME/.ssh/id_ed25519"

DMG_URL="https://app.workstatus.io/downloads/mac/visible/7.0/Workstatus.dmg"
DMG_NAME="Workstatus.dmg"

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

if [[ ! -f "$KEY" ]]; then
    echo "SSH key not found. Generating..."
    ssh-keygen -t ed25519 -N "" -f "$KEY"
fi

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

echo "======================================================"
echo "Workstatus macOS DMG install"
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

    echo ""
    echo "======================================================"
    echo "HOST: $host"
    echo "  user: ${user:-<missing>}"
    echo "======================================================"
    echo ""

    if [[ -z "$user" || -z "$pass" ]]; then
        echo "Skipping $host: inventory needs user= and pass="
        continue
    fi

    echo "[1/2] Connecting..."

    SSHPASS="$pass" sshpass -e ssh-copy-id \
        -o StrictHostKeyChecking=no \
        "$user@$host" >/dev/null 2>&1 || true

    if ! ssh_mac "$user" "$host" "$pass" "echo SSH_OK" >/dev/null 2>&1; then
        echo "Could not SSH to $user@$host"
        echo "On the Mac enable: System Settings > General > Sharing > Remote Login"
        continue
    fi

    echo "SSH ready"
    echo ""
    echo "[2/2] Downloading and installing DMG..."

    if ssh_mac "$user" "$host" "$pass" \
        "DMG_URL='$DMG_URL' DMG_NAME='$DMG_NAME' SUDO_PASS='$pass' bash -s" <<'EOF'

set -e

echo "Cleaning existing Workstatus..."

pkill -f "[Ww]orkstatus" 2>/dev/null || true
killall Workstatus 2>/dev/null || true
killall "Workstatus Desktop" 2>/dev/null || true
sleep 2

SUPPORT_DIR="$HOME/Library/Application Support/Workstatus"
if [ -e "$SUPPORT_DIR" ]; then
    chmod -R u+w "$SUPPORT_DIR" 2>/dev/null || true
    chflags -R nouchg,noschg "$SUPPORT_DIR" 2>/dev/null || true
    if rm -rf "$SUPPORT_DIR" 2>/dev/null; then
        echo "REMOVED_APPSUPPORT=$SUPPORT_DIR"
    else
        printf '%s\n' "$SUDO_PASS" | sudo -S -p "" chflags -R nouchg,noschg "$SUPPORT_DIR" >/dev/null 2>&1 || true
        printf '%s\n' "$SUDO_PASS" | sudo -S -p "" rm -rf "$SUPPORT_DIR"
        echo "REMOVED_APPSUPPORT_WITH_SUDO=$SUPPORT_DIR"
    fi
else
    echo "APPSUPPORT_ALREADY_ABSENT"
fi

DOWNLOADS="$HOME/Downloads"
DMG_PATH="$DOWNLOADS/$DMG_NAME"
mkdir -p "$DOWNLOADS"

echo "Downloading Workstatus DMG..."
echo "DOWNLOAD_URL=$DMG_URL"

rm -f "$DMG_PATH"
curl --fail --location --retry 3 "$DMG_URL" -o "$DMG_PATH"

if [ ! -f "$DMG_PATH" ]; then
    echo "DMG_DOWNLOAD_FAILED"
    exit 1
fi

echo "DMG_DOWNLOAD_SUCCESS"
echo "DMG_PATH=$DMG_PATH"
echo "DMG_SIZE=$(du -h "$DMG_PATH" | awk '{print $1}')"

xattr -dr com.apple.quarantine "$DMG_PATH" 2>/dev/null || true

echo "Mounting DMG..."
ATTACH_OUT=$(hdiutil attach "$DMG_PATH" -nobrowse -noverify 2>&1) || {
    echo "DMG_MOUNT_FAILED"
    echo "$ATTACH_OUT"
    exit 1
}

echo "$ATTACH_OUT"
MOUNT_POINT=$(echo "$ATTACH_OUT" | sed -n 's/.*\(\/Volumes\/.*\)$/\1/p' | tail -1)

if [ -z "$MOUNT_POINT" ] || [ ! -d "$MOUNT_POINT" ]; then
    echo "DMG_MOUNT_POINT_NOT_FOUND"
    echo "$ATTACH_OUT"
    exit 1
fi

echo "MOUNT_POINT=$MOUNT_POINT"

cleanup_mount() {
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || \
        hdiutil detach "$MOUNT_POINT" -force 2>/dev/null || true
}
trap cleanup_mount EXIT

FOUND_APP=$(find "$MOUNT_POINT" -maxdepth 4 -name "*.app" -type d | head -1 || true)

if [ -z "$FOUND_APP" ]; then
    echo "APP_NOT_FOUND_IN_DMG"
    ls -la "$MOUNT_POINT"
    exit 1
fi

echo "FOUND_APP=$FOUND_APP"

APP_NAME=$(basename "$FOUND_APP")
DEST_APP="/Applications/$APP_NAME"

pkill -f "[Ww]orkstatus" 2>/dev/null || true
killall Workstatus 2>/dev/null || true
sleep 2

if [ -d "$DEST_APP" ]; then
    printf '%s\n' "$SUDO_PASS" | sudo -S -p "" rm -rf "$DEST_APP"
    echo "REMOVED_OLD_APP=$DEST_APP"
fi

echo "Installing to $DEST_APP"
printf '%s\n' "$SUDO_PASS" | sudo -S -p "" ditto "$FOUND_APP" "$DEST_APP"
printf '%s\n' "$SUDO_PASS" | sudo -S -p "" xattr -dr com.apple.quarantine "$DEST_APP" >/dev/null 2>&1 || true

if [ ! -d "$DEST_APP" ]; then
    echo "INSTALL_FAILED"
    exit 1
fi

echo "INSTALLED_APP=$DEST_APP"

cleanup_mount
trap - EXIT
rm -f "$DMG_PATH"

echo "Opening $DEST_APP"
open "$DEST_APP" >/dev/null 2>&1 || true

echo "DMG_INSTALL_SUCCESS"

EOF
    then
        echo ""
        echo "SUCCESS: $host"
    else
        echo ""
        echo "FAILED on $host"
        continue
    fi

done < "$INVENTORY_FILE"

echo ""
echo "All macOS DMG installations processed"
