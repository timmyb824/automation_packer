#!/bin/bash

# Default values
TEMPLATE_ID=445
TARGET_NAME=""
TARGET_ID=""
MEMORY=2048
CORES=2
DISK_SIZE="32G"
IP_ADDR=""
GATEWAY="192.168.86.1"
PROXMOX_NODE="pve3"
PROXMOX_API_HOST="192.168.86.199"
PROXMOX_API_PORT="8006"
METHOD="qm" # or 'api'
TOKEN_ID="root@pam!terraform"
TOKEN_SECRET="43ce3b66-b927-47bd-8ae9-6a1b26b15a07"

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

# Function to convert size to bytes
convert_to_bytes() {
    local size=$1
    local number=${size%[GgMmKk]*}
    local unit=${size##*[0-9]}

    case ${unit^^} in
    G) echo $((number * 1024 * 1024 * 1024)) ;;
    M) echo $((number * 1024 * 1024)) ;;
    K) echo $((number * 1024)) ;;
    *) echo $number ;;
    esac
}

# Function to check task status
check_task_status() {
    local upid=$1
    local status
    local i=0
    local max_attempts=60 # 5 minutes with 5-second intervals

    while [ $i -lt $max_attempts ]; do
        status=$(make_api_call "GET" "/nodes/$PROXMOX_NODE/tasks/$upid/status" | jq -r '.data.status')

        if [ "$status" = "stopped" ]; then
            return 0
        elif [ "$status" = "running" ]; then
            echo -n "."
            sleep 5
            i=$((i + 1))
        else
            echo "Task failed with status: $status"
            return 1
        fi
    done

    echo "Timeout waiting for task completion"
    return 1
}

# Function to remove lock file
remove_lock() {
    local vm_id=$1
    make_api_call "DELETE" "/nodes/$PROXMOX_NODE/qemu/$vm_id/config/lock" "{}"
}

# Function to set VM resources using API
set_vm_resources_api() {
    local data="{\"memory\":\"$MEMORY\",\"cores\":\"$CORES\"}"
    make_api_call "PUT" "/nodes/$PROXMOX_NODE/qemu/$TARGET_ID/config" "$data"

    # Resize disk
    local disk_size_bytes=$(convert_to_bytes "$DISK_SIZE")
    local data="{\"disk\":\"scsi0\",\"size\":\"$disk_size_bytes\"}"
    make_api_call "PUT" "/nodes/$PROXMOX_NODE/qemu/$TARGET_ID/resize" "$data"

    # Configure network
    local net_config="virtio,bridge=vmbr0"
    if [ -n "$IP_ADDR" ] && [ -n "$GATEWAY" ]; then
        net_config="$net_config,ip=$IP_ADDR/24,gw=$GATEWAY"
    fi
    local net_data="{\"net0\":\"$net_config\"}"
    make_api_call "PUT" "/nodes/$PROXMOX_NODE/qemu/$TARGET_ID/config" "$net_data"
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
    --ip)
        IP_ADDR="$2"
        shift 2
        ;;
    --gateway)
        GATEWAY="$2"
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
    echo "Example (with IP): $0 --name ubuntu-test --id 445 --ip 192.168.86.133 --gateway 192.168.86.1"
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
    local clone_result=$(clone_vm_api)
    local upid=$(echo "$clone_result" | jq -r '.data')

    if [ -z "$upid" ] || [ "$upid" = "null" ]; then
        echo "Error: Failed to get task ID from clone operation"
        exit 1
    fi

    echo -n "Waiting for clone operation to complete"
    if ! check_task_status "$upid"; then
        echo "\nClone operation failed"
        exit 1
    fi
    echo "\nClone completed successfully"

    # Remove any stale lock files
    remove_lock "$TARGET_ID"

    echo "Configuring VM resources..."
    set_vm_resources_api

    echo "Starting VM..."
    local start_result=$(start_vm_api)
    upid=$(echo "$start_result" | jq -r '.data')

    echo -n "Waiting for VM to start"
    if ! check_task_status "$upid"; then
        echo "\nVM start failed"
        exit 1
    fi
    echo "\nVM started successfully"
else
    # Using qm commands
    echo "Cloning VM template..."
    qm clone $TEMPLATE_ID $TARGET_ID --name $TARGET_NAME --full

    echo "Configuring VM resources..."
    qm set $TARGET_ID --memory $MEMORY
    qm set $TARGET_ID --cores $CORES
    qm resize $TARGET_ID scsi0 $DISK_SIZE

    # Configure network if IP is provided
    if [ -n "$IP_ADDR" ] && [ -n "$GATEWAY" ]; then
        qm set $TARGET_ID --ipconfig0 "ip=$IP_ADDR/24,gw=$GATEWAY"
    fi

    echo "Starting VM..."
    qm start $TARGET_ID
fi

echo "VM $TARGET_NAME (ID: $TARGET_ID) has been created and started!"
echo "Resource allocation:"
echo "- Memory: $MEMORY MB"
echo "- Cores: $CORES"
echo "- Disk: $DISK_SIZE"
if [ -n "$IP_ADDR" ] && [ -n "$GATEWAY" ]; then
    echo "Network configuration:"
    echo "- IP Address: $IP_ADDR/24"
    echo "- Gateway: $GATEWAY"
fi
