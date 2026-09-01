#!/bin/bash

INVENTORY="inventory.ini"
KEY="$HOME/.ssh/id_ed25519"

API_URL="https://api.workstatus.io/api/get_user_stealth_token"


# ============================================================
# Detect operating system
# ============================================================

if [ ! -f /etc/os-release ]; then
    echo "✗ Cannot detect operating system"
    exit 1
fi

. /etc/os-release

OS_ID="$ID"
OS_VERSION="$VERSION_ID"

echo
echo "Operating System: $OS_ID"
echo "OS Version: $OS_VERSION"

if [ "$OS_ID" != "ubuntu" ]; then
    echo "✗ Unsupported operating system: $OS_ID"
    exit 1
fi

case "$OS_VERSION" in
    22.04)
        echo "✓ Ubuntu 22.04 detected"
        WORKSTATUS_URL="https://app.workstatus.io/downloads/linux/py/7.0/2204/Workstatus"
        ;;

    24.04)
        echo "✓ Ubuntu 24.04 detected"
        WORKSTATUS_URL="https://app.workstatus.io/downloads/linux/py/7.0/2404/Workstatus"
        ;;

    *)
        echo "✗ Unsupported Ubuntu version: $OS_VERSION"
        exit 1
        ;;
esac
# ============================================================
# Generate SSH key once
# ============================================================

if [ ! -f "$KEY" ]; then
    echo "SSH key not found. Generating..."
    ssh-keygen -t ed25519 -N "" -f "$KEY"

    if [ $? -ne 0 ]; then
        echo "✗ Failed to generate SSH key"
        exit 1
    fi
fi


# ============================================================
# Process every server in inventory
# ============================================================

while IFS= read -r line; do

    # Skip blank lines and section headers
    [[ -z "$line" || "$line" =~ ^\[ ]] && continue

    IP=$(echo "$line" | awk '{print $1}')
    USER=$(echo "$line" | sed -n 's/.*user=\([^ ]*\).*/\1/p')
    PASS=$(echo "$line" | sed -n 's/.*pass=\([^ ]*\).*/\1/p')
    USER_EMAIL=$(echo "$line" | sed -n 's/.*email=\([^ ]*\).*/\1/p')

    echo
    echo "========================================"
    echo "Connecting to $USER@$IP"
    echo "  email: ${USER_EMAIL:-<missing>}"
    echo "========================================"


    # ========================================================
    # Copy SSH key
    # ========================================================

    sshpass -p "$PASS" ssh-copy-id \
        -o StrictHostKeyChecking=no \
        "$USER@$IP" >/dev/null 2>&1

    if [ $? -ne 0 ]; then
        echo "✗ Could not configure SSH on $IP"
        continue
    fi

    echo "✓ SSH key configured"


    # ========================================================
    # Execute remote installation
    # ========================================================

    ssh -o StrictHostKeyChecking=no "$USER@$IP" \
        "API_URL='$API_URL' USER_EMAIL='$USER_EMAIL' PASS='$PASS' WORKSTATUS_URL='$WORKSTATUS_URL' bash -s" <<'EOF'

set -e

WORKSTATUS_DIR="$HOME/Workstatus"
TOKEN_FILE="$WORKSTATUS_DIR/user_token_file.txt"
WORKSTATUS_FILE="$WORKSTATUS_DIR/Workstatus"


# ============================================================
# Remove previous Workstatus / Workstatus-Desktop
# ============================================================

echo
echo "Removing previous Workstatus files..."

pkill -f "[Ww]orkstatus" 2>/dev/null || true
pkill -f "Workstatus-Desktop" 2>/dev/null || true
sleep 2

sudo_rm() {
    local path="$1"
    [ -e "$path" ] || return 0

    chmod -R u+w "$path" 2>/dev/null || true

    if rm -rf "$path" 2>/dev/null; then
        echo "REMOVED=$path"
        return 0
    fi

    if printf '%s\n' "$PASS" | sudo -S -p "" rm -rf "$path" >/dev/null 2>&1; then
        echo "REMOVED_WITH_SUDO=$path"
        return 0
    fi

    echo "REMOVE_FAILED=$path"
    return 0
}

sudo_rm "$HOME/Workstatus"
sudo_rm "$HOME/Home/Workstatus"

for app_path in \
    "$HOME/Applications/Workstatus" \
    "$HOME/Applications/Workstatus.desktop" \
    "$HOME/Applications/Workstatus-Desktop" \
    "$HOME/Applications/Workstatus-Desktop.desktop" \
    "$HOME/.local/share/applications/Workstatus.desktop" \
    "$HOME/.local/share/applications/Workstatus-Desktop.desktop" \
    "$HOME/.local/share/applications/workstatus.desktop" \
    "$HOME/.local/share/applications/workstatus-desktop.desktop" \
    "$HOME/.config/autostart/Workstatus.desktop" \
    "$HOME/.config/autostart/Workstatus-Desktop.desktop" \
    "$HOME/.config/autostart/workstatus.desktop" \
    "$HOME/.local/share/Workstatus" \
    "$HOME/.local/share/Workstatus-Desktop" \
    "$HOME/.config/Workstatus" \
    "$HOME/.config/Workstatus-Desktop"
do
    sudo_rm "$app_path"
done

printf '%s\n' "$PASS" | sudo -S -p "" bash -c '
    rm -f /usr/share/applications/Workstatus.desktop \
          /usr/share/applications/Workstatus-Desktop.desktop \
          /usr/share/applications/workstatus.desktop \
          /usr/share/applications/workstatus-desktop.desktop \
          /usr/local/share/applications/Workstatus.desktop \
          /usr/local/share/applications/Workstatus-Desktop.desktop \
          /usr/bin/Workstatus \
          /usr/bin/Workstatus-Desktop \
          /usr/local/bin/Workstatus \
          /usr/local/bin/Workstatus-Desktop
    rm -rf /opt/Workstatus \
           /opt/Workstatus-Desktop \
           /usr/share/Workstatus \
           /usr/share/Workstatus-Desktop
' >/dev/null 2>&1 || true

printf '%s\n' "$PASS" | sudo -S -p "" apt-get remove -y --purge workstatus-desktop Workstatus-Desktop 2>/dev/null || true
printf '%s\n' "$PASS" | sudo -S -p "" dpkg --purge workstatus-desktop Workstatus-Desktop 2>/dev/null || true

find "$HOME/.local/share/applications" "$HOME/.config/autostart" "$HOME/Applications" \
    -iname "*Workstatus*" 2>/dev/null | while read -r leftover; do
    sudo_rm "$leftover"
done || true

echo "✓ Previous Workstatus / Workstatus-Desktop files removed"

# ============================================================
# Prepare Workstatus directory
# ============================================================

echo
echo "Preparing Workstatus directory..."

mkdir -p "$WORKSTATUS_DIR"

echo "✓ Workstatus directory created:"
echo "  $WORKSTATUS_DIR"


# ============================================================
# Fetch Workstatus token
# ============================================================

echo
echo "Fetching Workstatus token..."

API_RESPONSE=$(curl --silent --show-error \
    --location \
    --request GET "$API_URL" \
    --header "Content-Type: application/json" \
    --data-raw "{\"email\":\"$USER_EMAIL\"}")

if [ $? -ne 0 ]; then
    echo "✗ API request failed"
    exit 1
fi

echo "✓ API request completed"

TOKEN=$(echo "$API_RESPONSE" | sed -n \
    's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

if [ -z "$TOKEN" ]; then
    echo "✗ Token was not returned by API"
    echo "API response:"
    echo "$API_RESPONSE"
    exit 1
fi

echo "$TOKEN" > "$TOKEN_FILE"

# Token should only be readable by the current user
chmod 600 "$TOKEN_FILE"

echo "✓ Token saved:"
echo "  $TOKEN_FILE"


# ============================================================
# Download Workstatus executable
# ============================================================

echo
echo "Downloading Workstatus..."

cd "$WORKSTATUS_DIR"

curl --fail --location \
    "$WORKSTATUS_URL" \
    -o "$WORKSTATUS_FILE"

if [ $? -ne 0 ]; then
    echo "✗ Workstatus download failed"
    exit 1
fi

chmod +x "$WORKSTATUS_FILE"

echo "✓ Workstatus downloaded:"
echo "  $WORKSTATUS_FILE"


# ============================================================
# Start Workstatus in background
#
# Workstatus creates setup.sh and then waits/exits during
# first-time setup. Running it in background allows this
# script to continue and wait for setup.sh.
# ============================================================

echo
echo "Executing Workstatus..."

cd "$WORKSTATUS_DIR"

./Workstatus > "$WORKSTATUS_DIR/Workstatus-bootstrap.log" 2>&1 &

WORKSTATUS_PID=$!

echo "✓ Workstatus started"
echo "  PID: $WORKSTATUS_PID"


# ============================================================
# Wait for setup.sh
# ============================================================

echo
echo "Waiting for setup.sh to be created..."

SETUP_FOUND=false

for i in {1..60}; do

    if [ -f "$WORKSTATUS_DIR/setup.sh" ]; then
        SETUP_FOUND=true
        echo "✓ setup.sh created"
        break
    fi

    # Check whether Workstatus process is still alive
    if ! kill -0 "$WORKSTATUS_PID" 2>/dev/null; then
        echo "Workstatus bootstrap process exited."

        # It may have exited normally after creating setup.sh,
        # so check for setup.sh before treating this as failure.
        if [ -f "$WORKSTATUS_DIR/setup.sh" ]; then
            SETUP_FOUND=true
            echo "✓ setup.sh found after Workstatus exited"
            break
        fi
    fi

    sleep 1
done


# ============================================================
# Verify setup.sh
# ============================================================

if [ "$SETUP_FOUND" != "true" ]; then

    echo
    echo "✗ setup.sh was not created after 60 seconds"

    echo
    echo "Workstatus directory contents:"
    ls -la "$WORKSTATUS_DIR"

    echo
    echo "Workstatus bootstrap log:"
    if [ -f "$WORKSTATUS_DIR/workstatus-bootstrap.log" ]; then
        cat "$WORKSTATUS_DIR/workstatus-bootstrap.log"
    fi

    exit 1
fi


# ============================================================
# Execute setup.sh
# ============================================================

chmod +x "$WORKSTATUS_DIR/setup.sh"

cd "$WORKSTATUS_DIR"

echo
echo "Running setup.sh..."

source ./setup.sh

SETUP_EXIT=$?

if [ $SETUP_EXIT -ne 0 ]; then
    echo "✗ setup.sh failed with exit code $SETUP_EXIT"
    exit 1
fi

echo "✓ setup.sh completed successfully"


# ============================================================
# Final status
# ============================================================

echo
echo "========================================"
echo "Workstatus setup completed"
echo "========================================"

echo "Workstatus directory:"
echo "  $WORKSTATUS_DIR"

echo "Token file:"
echo "  $TOKEN_FILE"

echo "Setup file:"
echo "  $WORKSTATUS_DIR/setup.sh"

EOF


    # ========================================================
    # Check remote result
    # ========================================================

    if [ $? -eq 0 ]; then
        echo "✓ $IP completed successfully"
    else
        echo "✗ Failed on $IP"
    fi

done < "$INVENTORY"