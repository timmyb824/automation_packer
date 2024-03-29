# Ubuntu Server jammy
# ---
# Packer Template to create an Ubuntu Server (jammy) on Proxmox
# `packer build -var-file="credentials.pkr.hcl" ubuntu-server-jammy-X.pkr.hcl`

packer {
  required_plugins {
    name = {
      version = "~> 1"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

# Variable Definitions
variable "proxmox_api_url" {
    type = string
}

variable "proxmox_api_token_id" {
    type = string
}

variable "proxmox_api_token_secret" {
    type = string
    sensitive = true
}

# Resource Definiation for the VM Template
source "proxmox-iso" "ubuntu-server-jammy" {

    # Proxmox Connection Settings
    proxmox_url = "${var.proxmox_api_url}"
    username = "${var.proxmox_api_token_id}"
    token = "${var.proxmox_api_token_secret}"
    # (Optional) Skip TLS Verification
    # insecure_skip_tls_verify = true

    # VM General Settings
    node = "pve2"
    vm_id = "4201"
    vm_name = "ubuntu-2204-server-fully-provisioned"
    template_description = "Ubuntu Server jammy Image fully provisioned with cloud-init and personalization"

    # VM OS Settings
    # (Option 1) Local ISO File
    # iso_file = "local:iso/ubuntu-22.04-live-server-amd64.iso"
    # - or -
    # (Option 2) Download ISO
    iso_url = "https://releases.ubuntu.com/22.04/ubuntu-22.04.3-live-server-amd64.iso"
    iso_checksum = "a4acfda10b18da50e2ec50ccaf860d7f20b389df8765611142305c0e911d16fd"
    iso_storage_pool = "local"
    unmount_iso = true

    # VM System Settings
    qemu_agent = true

    # VM Hard Disk Settings
    scsi_controller = "virtio-scsi-pci"

    disks {
        disk_size = "20G"
        format = "raw"
        storage_pool = "local-zfs2"
        type = "virtio"
    }

    # VM CPU Settings
    cores = "2"

    # VM Memory Settings
    memory = "4096" # 4GB

    # VM Network Settings
    network_adapters {
        model = "virtio"
        bridge = "vmbr0"
        firewall = "false"
    }

    # VM Cloud-Init Settings
    cloud_init = true
    cloud_init_storage_pool = "local-zfs2"

    # PACKER Boot Commands
    boot_command = [
        "<esc><wait>",
        "e<wait>",
        "<down><down><down><end>",
        "<bs><bs><bs><bs><wait>",
        "autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ ---<wait>",
        "<f10><wait>"
    ]
    boot = "c"
    boot_wait = "5s"

    # PACKER Autoinstall Settings
    http_directory = "http"
    # (Optional) Bind IP Address and Port
    # http_bind_address = "0.0.0.0"
    # http_port_min = 8802
    # http_port_max = 8802

    ssh_username = "tbryant"

    # (Option 1) Add your Password here
    # ssh_password = ""
    # - or -
    # (Option 2) Add your Private SSH KEY file here
    ssh_private_key_file = "~/.ssh/id_master_key_nopass"

    # Raise the timeout, when installation takes longer
    ssh_timeout = "30m"
}

# Build Definition to create the VM Template
build {

    name = "ubuntu-server-jammy"
    sources = ["source.proxmox-iso.ubuntu-server-jammy"]

    # Provisioning the VM Template for Cloud-Init Integration in Proxmox
    provisioner "shell" {
        inline = [
            "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do echo 'Waiting for cloud-init...'; sleep 1; done",
            "sudo rm /etc/ssh/ssh_host_*",
            "sudo truncate -s 0 /etc/machine-id",
            "sudo apt -y autoremove --purge",
            "sudo apt -y clean",
            "sudo apt -y autoclean",
            "sudo cloud-init clean",
            "sudo rm -f /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg",
            "sudo rm -f /etc/netplan/00-installer-config.yaml",
            "sudo sync"
        ]
    }

    # Provisioning the VM Template for Cloud-Init Integration in Proxmox
    provisioner "file" {
        source = "files/99-pve.cfg"
        destination = "/tmp/99-pve.cfg"
    }

    # Provisioning the VM Template for Cloud-Init Integration in Proxmox
    provisioner "shell" {
        inline = [ "sudo cp /tmp/99-pve.cfg /etc/cloud/cloud.cfg.d/99-pve.cfg" ]
    }

    # Upload everything in the dotfiles directory to the VM Template
    provisioner "file" {
        source = "files/dotfiles"
        destination = "/home/tbryant"
    }

    # Provisioning the VM Template with Persoanlization Installation
    provisioner "shell" {
        inline = [
            "cd /home/tbryant/dotfiles",
            "chmod +x provision.sh",
            "./provision.sh"
        ]
    }
}
