#!/usr/bin/env python3

import argparse
import contextlib
import os
import sys
import time
from datetime import datetime
from proxmoxer import ProxmoxAPI
from typing import Optional

def wait_for_task(proxmox: ProxmoxAPI, node: str, upid: str, timeout: int = 1200) -> bool:
    """Wait for a task to complete, showing progress for clone operations."""
    start_time = time.time()
    while time.time() - start_time < timeout:
        status = proxmox.nodes(node).tasks(upid).status.get()

        if status.get("status") == "stopped":
            if status.get("exitstatus") == "OK":
                return True
            print(f"Task failed with status: {status.get('exitstatus')}")
            return False

        # Show progress for clone operations
        if "type" in status and status["type"] == "qmclone":
            with contextlib.suppress(Exception):
                if (
                    log_entries := proxmox.nodes(node)
                    .tasks(upid)
                    .log.get(limit=1)
                ):
                    print(f"\r{log_entries[-1]['t']}", end="", flush=True)
        time.sleep(1)

    print("\nTimeout waiting for task completion")
    return False

def retry_api_call(func, *args, max_retries=3, **kwargs):
    """Retry an API call with exponential backoff."""
    for attempt in range(max_retries):
        try:
            return func(*args, **kwargs)
        except Exception as e:
            if attempt == max_retries - 1:
                raise
            wait_time = 2 ** attempt
            print(f"API call failed, retrying in {wait_time} seconds... (Error: {str(e)})")
            time.sleep(wait_time)

def get_vm_config(proxmox, node, vmid):
    """Get VM configuration including disk information."""
    try:
        config = proxmox.nodes(node).qemu(vmid).config.get()
        return config
    except Exception as e:
        print(f"Error getting VM config: {str(e)}")
        return None

def find_main_disk(config):
    """Find the main disk in VM config, excluding CD-ROM drives."""
    # First look for virtio disks
    for key, value in config.items():
        if key.startswith('virtio') and key.endswith('0') and not value.endswith(',media=cdrom'):
            return key

    # Then look for scsi disks
    for key, value in config.items():
        if key.startswith('scsi') and key.endswith('0') and not value.endswith(',media=cdrom'):
            return key

    # Then sata disks
    for key, value in config.items():
        if key.startswith('sata') and key.endswith('0') and not value.endswith(',media=cdrom'):
            return key

    return next(
        (
            key
            for key, value in config.items()
            if key.startswith('ide')
            and key.endswith('0')
            and not value.endswith(',media=cdrom')
        ),
        None,
    )

def set_vm_resources(proxmox, node, vmid, memory, cores, disk_size):
    """Set VM resources after cloning."""
    try:
        # Get current VM configuration
        config = get_vm_config(proxmox, node, vmid)
        if not config:
            print("Failed to get VM configuration")
            return False

        # Find the main disk
        disk_id = find_main_disk(config)
        if not disk_id:
            print("Could not find main disk in VM configuration")
            print("Available disks:", {k: v for k, v in config.items() if k.startswith(('ide', 'sata', 'scsi', 'virtio'))})
            return False

        print(f"Setting VM resources (disk: {disk_id})...")

        # Set memory and CPU
        proxmox.nodes(node).qemu(vmid).config.put(
            memory=memory,
            cores=cores
        )

        # Resize disk if specified
        if disk_size:
            proxmox.nodes(node).qemu(vmid).resize.put(
                disk=disk_id,
                size=disk_size
            )

        return True

    except Exception as e:
        print(f"Error setting VM resources: {str(e)}")
        return False

def clone_vm(
    proxmox: ProxmoxAPI,
    template_id: int,
    target_id: int,
    node: str,
    name: str,
    memory: int = 2048,
    cores: int = 2,
    disk_size: str = None,
    ip_address: str = None,
    gateway: str = None,
    nameserver: str = None
):
    """Clone a VM from a template."""
    print(f"Cloning VM {template_id} to {target_id} ({name})...")

    try:
        # Clone the VM
        clone_params = {
            'newid': target_id,
            'name': name,
            'full': 1,  # Full clone
            'description': f'Created by clone-vm.py on {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}'
        }

        task_id = retry_api_call(
            proxmox.nodes(node).qemu(template_id).clone.create,
            **clone_params
        )
    except Exception as e:
        print(f"Error cloning VM: {str(e)}")
        return False

    print("\nWaiting for clone to complete...")
    if not wait_for_task(proxmox, node, task_id):
        return False

    # Set cloud-init configuration if IP is provided
    if ip_address:
        print("\nConfiguring cloud-init network settings...")
        try:
            ipconfig = f"ip={ip_address}"
            if gateway:
                ipconfig += f",gw={gateway}"
            config = {'ipconfig0': ipconfig}
            # Add nameserver if provided
            if nameserver:
                config['nameserver'] = nameserver

            if config:
                proxmox.nodes(node).qemu(target_id).config.put(**config)
        except Exception as e:
            print(f"Warning: Failed to set cloud-init network configuration: {str(e)}")
            # Continue anyway as this is not critical

    print("\nSetting VM resources...")
    if not set_vm_resources(proxmox, node, target_id, memory, cores, disk_size):
        return False

    # Start the VM
    print("\nStarting VM...")
    try:
        retry_api_call(
            proxmox.nodes(node).qemu(target_id).status.start.post
        )
    except Exception as e:
        print(f"Error starting VM: {str(e)}")
        return False

    print(f"\nVM {name} (ID: {target_id}) has been created and started!")
    print("Resource allocation:")
    print(f"- Memory: {memory} MB")
    print(f"- Cores: {cores}")
    if disk_size:
        print(f"- Disk: {disk_size}")
    if ip_address:
        print(f"- IP Address: {ip_address}")
        if gateway:
            print(f"- Gateway: {gateway}")
        if nameserver:
            print(f"- Nameserver: {nameserver}")
    return True

def destroy_vm(proxmox, node, vmid):
    """Destroy a VM with safety checks and cleanup."""
    try:
        # Get VM status
        status = proxmox.nodes(node).qemu(vmid).status.current.get()
        if not status:
            print(f"VM {vmid} not found")
            return False

        # Confirm destruction
        vm_name = status.get('name', str(vmid))
        confirm = input(f"\nWARNING: You are about to destroy VM {vm_name} (ID: {vmid}).\nThis action cannot be undone!\nType 'yes' to confirm: ")
        if confirm.lower() != 'yes':
            print("Destruction cancelled")
            return False

        # Stop VM if running
        if status['status'] == 'running':
            print(f"Stopping VM {vm_name}...")
            proxmox.nodes(node).qemu(vmid).status.stop.post()

            # Wait for VM to stop
            for _ in range(30):  # 30 second timeout
                time.sleep(1)
                current_status = proxmox.nodes(node).qemu(vmid).status.current.get()
                if current_status['status'] == 'stopped':
                    break
            else:
                print("Warning: VM did not stop gracefully, forcing destruction")

        # Destroy VM with cleanup options
        print(f"Destroying VM {vm_name}...")
        params = {
            'purge': 1,                          # Remove from all job configurations
            'destroy-unreferenced-disks': 1      # Destroy unreferenced disks
        }
        proxmox.nodes(node).qemu(vmid).delete(**params)
        print(f"VM {vm_name} has been destroyed")
        return True

    except Exception as e:
        print(f"Error destroying VM: {str(e)}")
        return False

def get_api_url(host: str) -> str:
    """Format the API URL correctly, handling both hostnames and IPs."""
    # Remove any existing scheme
    host = host.replace("http://", "").replace("https://", "")

    # Remove any port number if present
    if ":" in host:
        host = host.split(":")[0]

    return host

def main():
    parser = argparse.ArgumentParser(description='Clone and manage Proxmox VMs')
    parser.add_argument('--host', help='Proxmox host (default: from env)')
    parser.add_argument('--port', type=int, help='Proxmox port (default: 8006 for IP, 443 for domain)')
    parser.add_argument('--token-user', help='API token user (default: from env)')
    parser.add_argument('--token-secret', help='API token secret (default: from env)')
    parser.add_argument('--node', help='Proxmox node name (default: from env)')
    parser.add_argument('--verify-ssl', action='store_true', help='Verify SSL certificate')

    subparsers = parser.add_subparsers(dest='command', help='Command to execute')

    # Clone command
    clone_parser = subparsers.add_parser('clone', help='Clone a VM')
    clone_parser.add_argument('--template', type=int, help='Template VM ID (default: from env)')
    clone_parser.add_argument('--id', type=int, required=True, help='New VM ID')
    clone_parser.add_argument('--name', required=True, help='New VM name')
    clone_parser.add_argument('--memory', type=int, default=2048, help='Memory in MB (default: 2048)')
    clone_parser.add_argument('--cores', type=int, default=2, help='Number of CPU cores (default: 2)')
    clone_parser.add_argument('--disk', help='Disk size (e.g., 32G)')
    clone_parser.add_argument('--ip', help='IP address with CIDR (e.g., 192.168.86.133/24)')
    clone_parser.add_argument('--gateway', help='Gateway IP address')
    clone_parser.add_argument('--nameserver', help='DNS nameserver')

    # Destroy command
    destroy_parser = subparsers.add_parser('destroy', help='Destroy a VM')
    destroy_parser.add_argument('--id', type=int, required=True, help='VM ID to destroy')

    args = parser.parse_args()

    # Get credentials from environment or arguments
    api_host = args.host or os.environ.get('PVE_URL')
    token_id = args.token_user or os.environ.get('PVE_TOKEN_USER')
    token_secret = args.token_secret or os.environ.get('PVE_TOKEN_SECRET')

    if not all([api_host, token_id, token_secret]):
        print("Error: Missing credentials. Please set environment variables or provide arguments:")
        print("  - PVE_URL or --api-host")
        print("  - PVE_TOKEN_USER or --token-user")
        print("  - PVE_TOKEN_SECRET or --token-secret")
        sys.exit(1)

    # Format the API URL - determine port based on whether it's an IP or domain
    api_url = get_api_url(api_host)
    port = args.port or (8006 if api_url.replace('.', '').isdigit() else 443)

    print(f"Connecting to Proxmox API at {api_url} on port {port}...")

    try:
        # Split token parts correctly
        user_part = token_id.split('!')[0]  # root@pam
        token_name = token_id.split('!')[1]  # homelab

        proxmox = ProxmoxAPI(
            api_url,
            user=user_part,           # root@pam
            token_name=token_name,    # homelab
            token_value=token_secret,
            verify_ssl=False,
            timeout=30,    # Increase connection timeout
            port=port     # Specify the port explicitly
        )
    except Exception as e:
        print(f"Error connecting to Proxmox API: {str(e)}")
        sys.exit(1)

    # Handle commands
    if args.command == 'clone':
        template_id = args.template or 555
        node = args.node or "pve2"
        success = clone_vm(
            proxmox=proxmox,
            template_id=template_id,
            target_id=args.id,
            node=node,
            name=args.name,
            memory=args.memory,
            cores=args.cores,
            disk_size=args.disk,
            ip_address=args.ip,
            gateway=args.gateway,
            nameserver=args.nameserver
        )
    elif args.command == 'destroy':
        node = args.node or "pve2"
        destroy_vm(proxmox, node, args.id)
    else:
        parser.print_help()

if __name__ == '__main__':
    main()
