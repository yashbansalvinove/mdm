#!/bin/bash

INVENTORY="inventory.ini"
KEY="$HOME/.ssh/id_ed25519"

# Generate SSH key once
if [ ! -f "$KEY" ]; then
    ssh-keygen -t ed25519 -N "" -f "$KEY"
fi

while IFS= read -r line; do
    # Skip blank lines and section headers
    [[ -z "$line" || "$line" =~ ^\[ ]] && continue

    IP=$(echo "$line" | awk '{print $1}')
    USER=$(echo "$line" | sed -n 's/.*user=\([^ ]*\).*/\1/p')
    PASS=$(echo "$line" | sed -n 's/.*pass=\([^ ]*\).*/\1/p')

    echo "========================================"
    echo "Connecting to $USER@$IP"
    echo "========================================"

    # Copy SSH key (ignore if already present)
    sshpass -p "$PASS" ssh-copy-id \
        -o StrictHostKeyChecking=no \
        "$USER@$IP" >/dev/null 2>&1

    # Execute commands
    ssh -o StrictHostKeyChecking=no "$USER@$IP" <<EOF
wget -O ~/Downloads/Workstatus-Desktop-22.deb https://app.workstatus.io/downloads/linux/visible/22/7.0/Workstatus-Desktop.deb
echo "$PASS" | sudo -S apt install -y --allow-downgrades ~/Downloads/Workstatus-Desktop-22.deb
EOF

    if [ $? -eq 0 ]; then
        echo "✓ $IP completed successfully"
    else
        echo "✗ Failed on $IP"
    fi

done < "$INVENTORY"
