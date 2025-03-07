#!/bin/bash

# Default values
TEMPLATE_ID=444
TARGET_NAME=""
TARGET_ID=""
MEMORY=2048
CORES=2
DISK_SIZE="32G"
PROXMOX_NODE="pve3"
PROXMOX_API_HOST="192.168.86.199"
PROXMOX_API_PORT="8006"
METHOD="qm" # or 'api'
TOKEN_ID=""
TOKEN_SECRET=""

# Function to make API calls
make_api_call() {
    local method=$1
    local endpoint=$2
    local data=$3

    if [ "$method" = "POST" ] && [ -n "$data" ]; then
        curl -k -s -X $method \
            -H "Authorization: PVEAPIToken=$TOKEN_ID=$TOKEN_SECRET" \
            -H "Content-Type: application/json" \
            -d "$data" \
            "https://$PROXMOX_API_HOST:$PROXMOX_API_PORT/api2/json$endpoint"
    else
        curl -k -s -X $method \
            -H "Authorization: PVEAPIToken=$TOKEN_ID=$TOKEN_SECRET" \
            "https://$PROXMOX_API_HOST:$PROXMOX_API_PORT/api2/json$endpoint"
    fi
}

# Function to clone VM using API
clone_vm_api() {
    local data="{\"newid\":\"$TARGET_ID\",\"name\":\"$TARGET_NAME\",\"full\":1}"
    make_api_call "POST" "/nodes/$PROXMOX_NODE/qemu/$TEMPLATE_ID/clone" "$data"
}

# Function to set VM resources using API
set_vm_resources_api() {
    local data="{\"memory\":\"$MEMORY\",\"cores\":\"$CORES\"}"
    make_api_call "PUT" "/nodes/$PROXMOX_NODE/qemu/$TARGET_ID/config" "$data"

    # Resize disk
    local disk_size_bytes=$(echo "$DISK_SIZE" | numfmt --from=iec)
    local data="{\"disk\":\"scsi0\",\"size\":\"$disk_size_bytes\"}"
    make_api_call "PUT" "/nodes/$PROXMOX_NODE/qemu/$TARGET_ID/resize" "$data"
}

# Function to start VM using API
start_vm_api() {
    make_api_call "POST" "/nodes/$PROXMOX_NODE/qemu/$TARGET_ID/status/start" "{}"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
    --name)
        TARGET_NAME="$2"
        shift 2
        ;;
    --id)
        TARGET_ID="$2"
        shift 2
        ;;
    --memory)
        MEMORY="$2"
        shift 2
        ;;
    --cores)
        CORES="$2"
        shift 2
        ;;
    --disk)
        DISK_SIZE="$2"
        shift 2
        ;;
    --node)
        PROXMOX_NODE="$2"
        shift 2
        ;;
    --method)
        METHOD="$2"
        shift 2
        ;;
    --api-host)
        PROXMOX_API_HOST="$2"
        shift 2
        ;;
    --api-port)
        PROXMOX_API_PORT="$2"
        shift 2
        ;;
    --token-id)
        TOKEN_ID="$2"
        shift 2
        ;;
    --token-secret)
        TOKEN_SECRET="$2"
        shift 2
        ;;
    *)
        echo "Unknown parameter: $1"
        exit 1
        ;;
    esac
done

# Validate required parameters
if [ -z "$TARGET_NAME" ] || [ -z "$TARGET_ID" ]; then
    echo "Usage: $0 --name <vm_name> --id <vm_id> [--memory <MB>] [--cores <num>] [--disk <size>] [--node <proxmox_node>] [--method qm|api] [--api-host <host>] [--api-port <port>] [--token-id <id>] [--token-secret <secret>]"
    echo "Example (qm): $0 --name ubuntu-test --id 445 --memory 4096 --cores 4 --disk 64G"
    echo "Example (api): $0 --name ubuntu-test --id 445 --memory 4096 --cores 4 --disk 64G --method api --token-id 'user@pam!token' --token-secret 'xxx'"
    exit 1
fi

# Validate API parameters if using API method
if [ "$METHOD" = "api" ]; then
    if [ -z "$TOKEN_ID" ] || [ -z "$TOKEN_SECRET" ]; then
        echo "Error: When using API method, --token-id and --token-secret are required"
        exit 1
    fi
fi

echo "Using method: $METHOD"

# Execute commands based on chosen method
if [ "$METHOD" = "api" ]; then
    echo "Cloning VM template..."
    clone_vm_api

    echo "Waiting for clone operation to complete..."
    sleep 10

    echo "Configuring VM resources..."
    set_vm_resources_api

    echo "Starting VM..."
    start_vm_api
else
    # Using qm commands
    echo "Cloning VM template..."
    qm clone $TEMPLATE_ID $TARGET_ID --name $TARGET_NAME --full

    echo "Configuring VM resources..."
    qm set $TARGET_ID --memory $MEMORY
    qm set $TARGET_ID --cores $CORES
    qm resize $TARGET_ID scsi0 $DISK_SIZE

    echo "Starting VM..."
    qm start $TARGET_ID
fi

echo "VM $TARGET_NAME (ID: $TARGET_ID) has been created and started!"
echo "Resource allocation:"
echo "- Memory: $MEMORY MB"
echo "- Cores: $CORES"
echo "- Disk: $DISK_SIZE"
