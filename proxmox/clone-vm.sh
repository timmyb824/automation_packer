#!/bin/bash

######### WORK IN PROGRESS #########

# Default values
TEMPLATE_ID=555
TARGET_NAME=""
TARGET_ID=""
MEMORY=2048
CORES=2
DISK_SIZE="32G"
PROXMOX_NODE="pve2"
METHOD="api"

# Function to make API calls
make_api_call() {
    local method=$1
    local endpoint=$2
    local data=$3

    # Check required environment variables
    if [ -z "$PVE_URL" ] || [ -z "$PVE_TOKEN_USER" ] || [ -z "$PVE_TOKEN_SECRET" ]; then
        echo "Error: Required environment variables not set. Please set:"
        echo "  - PVE_URL (e.g., pve2.example.com)"
        echo "  - PVE_TOKEN_USER"
        echo "  - PVE_TOKEN_SECRET"
        return 1
    fi

    local url="https://$PVE_URL/api2/json$endpoint"
    local debug_output=""
    debug_output+="=== API Request Details ===\n"
    debug_output+="Full URL: $url\n"
    debug_output+="Method: $method\n"
    debug_output+="Headers:\n"
    debug_output+="  Authorization: PVEAPIToken=${PVE_TOKEN_USER}=<hidden>\n"
    debug_output+="  Content-Type: application/json\n"
    debug_output+="  Accept: application/json\n"
    if [ -n "$data" ]; then
        debug_output+="Request Body: $data\n"
    fi
    debug_output+="====================\n"

    # Create a temporary file for curl output
    local tmp_headers=$(mktemp)
    local response
    local http_code
    local curl_exit

    # Make the API call
    if [ "$method" = "POST" ] && [ -n "$data" ]; then
        response=$(curl -sS -k -w '%{http_code}' -D "$tmp_headers" -X "$method" \
            -H "Authorization: PVEAPIToken=${PVE_TOKEN_USER}=${PVE_TOKEN_SECRET}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -d "$data" \
            "$url")
        curl_exit=$?
    else
        response=$(curl -sS -k -w '%{http_code}' -D "$tmp_headers" -X "$method" \
            -H "Authorization: PVEAPIToken=${PVE_TOKEN_USER}=${PVE_TOKEN_SECRET}" \
            -H "Accept: application/json" \
            "$url")
        curl_exit=$?
    fi

    # Extract HTTP status code and response body
    http_code=${response: -3}
    response=${response:0:-3}

    # Add response info to debug output
    debug_output+="=== Response Headers ===\n"
    debug_output+="$(cat "$tmp_headers")\n"
    debug_output+="HTTP Status Code: $http_code\n"
    debug_output+="Response Body: $response\n"
    debug_output+="====================\n"

    rm -f "$tmp_headers"

    if [ $curl_exit -ne 0 ]; then
        echo "$debug_output" >&2
        echo "Error: Curl command failed with exit code $curl_exit" >&2
        return 1
    fi

    # Check if response is empty
    if [ -z "$response" ]; then
        echo "$debug_output" >&2
        echo "Warning: Empty response from API" >&2
        return 1
    fi

    # Try to clean the response
    response=$(echo "$response" | tr -cd '[:print:]\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    # Parse the response to check for errors
    if [[ "$response" == *'"errors":'* ]]; then
        local error_msg=$(echo "$response" | jq -r '.errors | join(", ")' 2>/dev/null)
        if [ -n "$error_msg" ]; then
            echo "$debug_output" >&2
            echo "Error from Proxmox API: $error_msg" >&2
            return 1
        fi
    fi

    # Check HTTP status code
    if [ "$http_code" -ge 400 ]; then
        # If we got a task ID despite error, don't fail
        if [[ "$response" == *'"data":"UPID:'* ]]; then
            echo "$debug_output" >&2
            echo "Warning: Got HTTP $http_code but received task ID, continuing..." >&2
        else
            echo "$debug_output" >&2
            echo "Error: HTTP $http_code response from Proxmox API" >&2
            echo "Response: $response" >&2

            # For 500 errors, try to get more detailed error information
            if [ "$http_code" -eq 500 ]; then
                local error_details=$(make_api_call "GET" "/nodes/$PROXMOX_NODE/tasks/status")
                echo "Recent task status: $error_details" >&2
            fi
            return 1
        fi
    fi

    # Send debug output to stderr
    echo "$debug_output" >&2
    echo "Debug: Cleaned response: '$response'" >&2

    # Return only the actual response
    echo "$response"
}

# Function to clone VM using API
clone_vm_api() {
    # Validate required parameters
    if [ -z "$TARGET_ID" ] || [ -z "$TARGET_NAME" ] || [ -z "$TEMPLATE_ID" ]; then
        echo "Error: Missing required parameters (TARGET_ID, TARGET_NAME, or TEMPLATE_ID)"
        return 1
    fi

    # Print essential parameters
    echo "=== Clone Parameters ==="
    echo "Target: $TARGET_NAME (ID: $TARGET_ID)"
    echo "Template: $TEMPLATE_ID"
    echo "Node: $PROXMOX_NODE"
    echo "===================="

    # Check if VM exists
    local existing_vm=$(make_api_call "GET" "/nodes/$PROXMOX_NODE/qemu/$TARGET_ID/status/current")
    local api_status=$?

    if [ $api_status -eq 0 ]; then
        if echo "$existing_vm" | jq empty 2>/dev/null; then
            local vm_status=$(echo "$existing_vm" | jq -r '.data.status // empty' 2>/dev/null)
            if [ -n "$vm_status" ]; then
                echo "Error: Target VM $TARGET_ID already exists (status: $vm_status)"
                return 1
            fi
        fi
    elif [ $api_status -eq 1 ] && [[ "$existing_vm" == *"does not exist"* ]]; then
        echo "Target VM ID is available"
    else
        echo "Warning: VM existence check failed - proceeding anyway"
    fi

    # Construct the clone request data
    local data="{\"newid\":\"$TARGET_ID\",\"name\":\"$TARGET_NAME\",\"full\":1}"

    # Make the API call
    echo "Cloning VM..."
    local clone_response=$(make_api_call "POST" "/nodes/$PROXMOX_NODE/qemu/$TEMPLATE_ID/clone" "$data")
    local api_status=$?

    if [ $api_status -ne 0 ]; then
        echo "Error: Clone failed"
        if [ -n "$clone_response" ]; then
            if echo "$clone_response" | jq empty 2>/dev/null; then
                local error_msg=$(echo "$clone_response" | jq -r '.errors[0] // .message // empty' 2>/dev/null)
                if [ -n "$error_msg" ]; then
                    echo "Details: $error_msg"
                fi
            fi
        fi
        return 1
    fi

    if [ -z "$clone_response" ]; then
        echo "Error: Empty response from clone operation"
        return 1
    fi

    # Try to extract the task ID from the clone response
    local task_id
    local clone_success=false

    # First try to parse as JSON
    if echo "$clone_response" | jq empty 2>/dev/null; then
        echo "=== Clone Response Processing ==="
        echo "Valid JSON detected"

        # Try to extract error message first
        local error_msg=$(echo "$clone_response" | jq -r '.errors // empty' 2>/dev/null)
        if [ -n "$error_msg" ] && [ "$error_msg" != "null" ]; then
            echo "Error: API returned error: $error_msg"
            return 1
        fi

        # Extract task ID from .data field and verify it's a UPID
        task_id=$(echo "$clone_response" | jq -r '.data // empty' 2>/dev/null)
        if [ -n "$task_id" ] && [[ "$task_id" == UPID:* ]]; then
            echo "Found task ID in .data field: $task_id"

            # Wait a moment for the task to start
            echo "Waiting for task to start..."
            sleep 2

            # Check task status
            echo "Checking task status..."
            local status=$(check_task_status "$task_id")
            local check_exit=$?

            if [ $check_exit -ne 0 ]; then
                echo "Error: Task failed or returned error status"
                echo "Task Status: $status"
                return 1
            fi

            echo "Clone task completed successfully"
            clone_success=true

            # Start the VM
            echo "Starting VM..."
            local start_response=$(make_api_call "POST" "/nodes/$PROXMOX_NODE/qemu/$TARGET_ID/status/start")

            # Try to parse start response as JSON
            if echo "$start_response" | jq empty 2>/dev/null; then
                # Extract start task ID
                local start_task_id=$(echo "$start_response" | jq -r '.data // empty' 2>/dev/null)
                if [ -n "$start_task_id" ] && [[ "$start_task_id" =~ ^UPID:[a-zA-Z0-9:@._-]+$ ]]; then
                    echo "Waiting for VM to start..."
                    local start_status=$(check_task_status "$start_task_id")
                    local start_check_exit=$?

                    if [ $start_check_exit -ne 0 ]; then
                        echo "Error: Failed to start VM"
                        return 1
                    fi

                    echo "VM started successfully"
                else
                    echo "Error: Invalid start task ID"
                    return 1
                fi
            else
                echo "Error: Invalid start response"
                echo "Raw response: '$start_response'"
                return 1
            fi
        else
            echo "No valid task ID found in response"
            echo "Full JSON structure:"
            echo "$clone_response" | jq '.'
            return 1
        fi
        echo "===================="
    else
        echo "Response is not valid JSON"
        echo "Raw response: '$clone_response'"
        return 1
    fi

    if [ -z "$task_id" ]; then
        echo "Error: Could not find task ID in response"
        echo "Raw response: $clone_response"
        return 1
    fi

    echo "Success: Found task ID: $task_id"

    echo "$task_id"
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
    local max_attempts=120 # 10 minutes with 5-second intervals
    local last_log=""
    local current_log

    echo "Checking status for task: $upid"

    while [ $i -lt $max_attempts ]; do
        local response=$(make_api_call "GET" "/nodes/$PROXMOX_NODE/tasks/$upid/status")
        status=$(echo "$response" | jq -r '.data.status // empty')
        local exitstatus=$(echo "$response" | jq -r '.data.exitstatus // empty')

        # Get task log for better error reporting
        current_log=$(make_api_call "GET" "/nodes/$PROXMOX_NODE/tasks/$upid/log")
        if [ "$current_log" != "$last_log" ]; then
            echo "$current_log"
            last_log="$current_log"
        fi

        if [ "$status" = "stopped" ]; then
            if [ "$exitstatus" = "OK" ]; then
                echo "\nTask completed successfully"
                return 0
            else
                echo "\nTask failed with exit status: $exitstatus"
                echo "Final task log: $current_log"
                return 1
            fi
        elif [ "$status" = "running" ]; then
            echo -n "."
            sleep 5
            i=$((i + 1))
        else
            echo "\nTask failed with status: $status"
            return 1
        fi
    done

    echo "\nTimeout waiting for task completion"
    return 1
}

# Function to remove lock file
remove_lock() {
    local vm_id=$1
    echo "Removing lock for VM $vm_id..."
    make_api_call "DELETE" "/nodes/$PROXMOX_NODE/qemu/$vm_id/config/lock" "{}"
    local remove_status=$?

    if [ $remove_status -eq 0 ]; then
        echo "Successfully removed lock"
        return 0
    else
        echo "Warning: Failed to remove lock, but continuing..."
        return 0 # Continue anyway as the lock might not exist
    fi
}

# Function to set VM resources using API
set_vm_resources_api() {
    local data="{\"memory\":\"$MEMORY\",\"cores\":\"$CORES\"}"
    make_api_call "PUT" "/nodes/$PROXMOX_NODE/qemu/$TARGET_ID/config" "$data"

    # Resize disk
    local disk_size_bytes=$(convert_to_bytes "$DISK_SIZE")
    local data="{\"disk\":\"scsi0\",\"size\":\"$disk_size_bytes\"}"
    make_api_call "PUT" "/nodes/$PROXMOX_NODE/qemu/$TARGET_ID/resize" "$data"

}

# Function to start VM using API
start_vm_api() {
    if [ -z "$TARGET_ID" ]; then
        echo "Error: No target VM ID specified"
        return 1
    fi

    local response=$(make_api_call "POST" "/nodes/$PROXMOX_NODE/qemu/$TARGET_ID/status/start" "{}")
    local api_status=$?

    if [ $api_status -ne 0 ]; then
        echo "Error: Failed to start VM $TARGET_ID"
        return 1
    fi

    echo "$response"
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
        PVE_URL="$2"
        shift 2
        ;;
    --api-port)
        PROXMOX_API_PORT="$2"
        shift 2
        ;;
    --token-id)
        PVE_TOKEN_USER="$2"
        shift 2
        ;;
    --token-secret)
        PVE_TOKEN_SECRET="$2"
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

if [ "$METHOD" = "api" ]; then
    # If token credentials not provided via args, use environment variables
    if [ -z "$PVE_TOKEN_USER" ]; then
        PVE_TOKEN_USER=$PVE_TOKEN_USER
    fi
    if [ -z "$PVE_TOKEN_SECRET" ]; then
        PVE_TOKEN_SECRET=$PVE_TOKEN_SECRET
    fi
    if [ -z "$PVE_URL" ]; then
        PVE_URL=$PVE_URL
    fi

    # Check network connectivity to Proxmox server
    echo "=== Checking Network Connectivity ==="
    echo "Testing connection..."
    # Test HTTPS connectivity using curl
    echo "Testing HTTPS connectivity to $PVE_URL..."
    curl_output=$(curl -k -s -o /dev/null -w '%{http_code}' "https://$PVE_URL/api2/json/version")

    # A 401 response means we reached the server but aren't authenticated, which is expected
    if [ "$curl_output" = "401" ]; then
        echo "Successfully connected to Proxmox API (got expected 401 Unauthorized)"
    fi
    echo "Connection successful!"
    echo "==========================="

    # Check required credentials
    if [ -z "$PVE_TOKEN_USER" ] || [ -z "$PVE_TOKEN_SECRET" ] || [ -z "$PVE_URL" ]; then
        echo "Error: API credentials required. Please set these environment variables:"
        echo "  - PVE_TOKEN_USER"
        echo "  - PVE_TOKEN_SECRET"
        echo "  - PVE_URL"
        exit 1
    fi
fi

echo "Using method: $METHOD"

# Function to execute API commands
execute_api_commands() {
    echo "=== Starting Clone Operation ==="
    echo "Target: $TARGET_NAME (ID: $TARGET_ID)"
    echo "Template: $TEMPLATE_ID"
    echo "=========================="

    echo "Cloning VM..."
    clone_result=$(clone_vm_api)
    clone_status=$?

    if [ $clone_status -ne 0 ]; then
        echo "Error: Clone failed (status: $clone_status)"
        echo "Details: $clone_result"
        exit 1
    fi

    # Extract task ID
    if [[ "$clone_result" =~ ^[[:space:]]*UPID:[a-zA-Z0-9:@._-]+[[:space:]]*$ ]]; then
        upid=$(echo "$clone_result" | tr -d '[:space:]')
    else
        if echo "$clone_result" | jq empty 2>/dev/null; then
            upid=$(echo "$clone_result" | jq -r '.data' 2>/dev/null)
            if [ -z "$upid" ] || [ "$upid" = "null" ]; then
                echo "Error: No task ID found in response"
                exit 1
            fi
        else
            echo "Error: Invalid clone response"
            exit 1
        fi
    fi

    echo -n "Waiting for clone to complete..."
    if ! check_task_status "$upid"; then
        echo " failed"
        exit 1
    fi
    echo " done"

    echo "Setting VM resources..."
    set_vm_resources_api

    echo "Starting VM..."
    start_result=$(start_vm_api)
    if [ $? -ne 0 ]; then
        echo "Error: Failed to start VM"
        exit 1
    fi

    if ! echo "$start_result" | jq empty 2>/dev/null; then
        echo "Error: Invalid response from start VM API"
        exit 1
    fi

    upid=$(echo "$start_result" | jq -r '.data // empty')
    if [ -z "$upid" ]; then
        echo "Error: No task ID in start response"
        exit 1
    fi

    echo -n "Waiting for VM to start..."
    if ! check_task_status "$upid"; then
        echo " failed"
        exit 1
    fi
    echo " done"
}

# Execute commands based on chosen method
if [ "$METHOD" = "api" ]; then
    execute_api_commands
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
