#!/bin/bash
# DarwinKVM: Proxmox VE GPU passthrough helper for a secondary (dedicated) GPU.
#
# Run this as root on the Proxmox host. Usage:
#   ./proxmox-gpu-passthrough.sh check    Validate config, show GPU IDs and IOMMU groups
#   ./proxmox-gpu-passthrough.sh vfio     Bind the GPU to vfio-pci at boot (reboot needed)
#   ./proxmox-gpu-passthrough.sh create   Create the macOS VM and attach the GPU
#
# The host keeps its iGPU for the console; only the dedicated GPU is handed to the VM.

set -euo pipefail

#############################################################################
# USER CONFIGURATION - edit this section for your hardware
#############################################################################

# PCI address of the GPU you want to pass through (not the audio function).
# Find it with: lspci -nn | grep -i vga
# Example: "01:00" for a card shown as 01:00.0
GPU_BUS="01:00"

# Optional: PCI address of the GPU's HDMI audio function. Leave empty to
# auto-detect it (usually the same bus with function .1, e.g. 01:00.1).
GPU_AUDIO_BUS=""

# Optional: explicit "vendor:device" IDs. Leave empty to read them from lspci.
# Your RX 550 IDs appear in: lspci -nn -s <GPU_BUS>
GPU_VENDOR_DEVICE_IDS=""

# Proxmox VM settings
VMID="200"
VM_NAME="DarwinKVM-macOS"
VM_CORES="4"
VM_MEMORY_MB="8192"
VM_CPU_TYPE="host"            # Use the CPU model your OpenCore setup expects
VM_MACHINE="q35"
VM_DISK_STORAGE="local-lvm"   # Storage pool for the disk, see: pvesm status
VM_DISK_SIZE_GB="128"
VM_BRIDGE="vmbr0"

# Extra QEMU arguments for macOS (OpenCore, SMBIOS, CPU flags), added as "args:".
# Leave empty to set it later in the Proxmox web UI.
VM_EXTRA_ARGS=""

#############################################################################
# END OF USER CONFIGURATION
#############################################################################

VFIO_CONF="/etc/modprobe.d/darwinkvm-vfio.conf"

die() {
    echo "Error: $*" >&2
    exit 1
}

info() {
    echo "==> $*"
}

warn() {
    echo "Warning: $*" >&2
}

need_root() {
    [[ $EUID -eq 0 ]] || die "run this script as root on the Proxmox host."
}

need_cmds() {
    local cmd
    for cmd in lspci qm update-initramfs; do
        command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' not found. Is this a Proxmox VE host?"
    done
}

validate_config() {
    [[ $GPU_BUS =~ ^[0-9a-fA-F]{2}:[0-9a-fA-F]{2}$ ]] \
        || die "GPU_BUS must look like 01:00 (got '$GPU_BUS')."
    [[ $VMID =~ ^[0-9]+$ ]] || die "VMID must be a number."
    [[ $VM_MEMORY_MB =~ ^[0-9]+$ ]] || die "VM_MEMORY_MB must be a number."
    [[ $VM_CORES =~ ^[0-9]+$ ]] || die "VM_CORES must be a number."

    lspci -s "${GPU_BUS}.0" >/dev/null 2>&1 \
        || die "no PCI device at ${GPU_BUS}.0. Check GPU_BUS with: lspci -nn | grep -i vga"
}

# Resolve the audio function, and the vendor:device pair(s) to bind to vfio-pci.
resolve_ids() {
    if [[ -z $GPU_AUDIO_BUS ]]; then
        GPU_AUDIO_BUS="${GPU_BUS}.1"
    fi

    if [[ -z $GPU_VENDOR_DEVICE_IDS ]]; then
        local gpu_id audio_id
        gpu_id=$(lspci -n -s "${GPU_BUS}.0" | awk '{print $3}')
        GPU_VENDOR_DEVICE_IDS="$gpu_id"
        if audio_id=$(lspci -n -s "$GPU_AUDIO_BUS" 2>/dev/null | awk '{print $3}') && [[ -n $audio_id ]]; then
            GPU_VENDOR_DEVICE_IDS="$gpu_id,$audio_id"
        else
            warn "no audio function found at $GPU_AUDIO_BUS. Passing only the GPU."
        fi
    fi
}

check_iommu_enabled() {
    if [[ ! -d /sys/kernel/iommu_groups ]] || [[ -z $(ls -A /sys/kernel/iommu_groups 2>/dev/null) ]]; then
        die "IOMMU is not enabled. Add the kernel flags shown by: $0 vfio"
    fi
}

show_iommu_group() {
    local group_path dev
    group_path=$(readlink -f "/sys/bus/pci/devices/0000:${GPU_BUS}.0/iommu_group" 2>/dev/null) \
        || die "could not read the IOMMU group for $GPU_BUS."
    info "IOMMU group for $GPU_BUS:"
    for dev in "$group_path"/devices/*; do
        echo "    $(lspci -nns "${dev##*/}")"
    done
    warn "all devices in this group must be passed together or be bridges. Otherwise passthrough will fail."
}

detect_cpu_iommu_flag() {
    if grep -q "GenuineIntel" /proc/cpuinfo; then
        echo "intel_iommu=on iommu=pt"
    else
        echo "amd_iommu=on iommu=pt"
    fi
}

print_boot_instructions() {
    local flags
    flags=$(detect_cpu_iommu_flag)
    echo
    info "Add these kernel parameters to your Proxmox boot config:"
    echo "    $flags video=efifb:off"
    echo
    echo "  systemd-boot (ZFS or UEFI with proxmox-boot-tool):"
    echo "    Edit /etc/kernel/cmdline, then run: proxmox-boot-tool refresh"
    echo "  GRUB:"
    echo "    Edit GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub, then run: update-grub"
    echo
}

cmd_check() {
    validate_config
    resolve_ids
    info "GPU:          $(lspci -nn -s "${GPU_BUS}.0")"
    info "Audio:        ${GPU_AUDIO_BUS} ($(lspci -nn -s "$GPU_AUDIO_BUS" 2>/dev/null || echo 'not found'))"
    info "vfio IDs:     $GPU_VENDOR_DEVICE_IDS"
    if [[ -d /sys/kernel/iommu_groups ]] && [[ -n $(ls -A /sys/kernel/iommu_groups 2>/dev/null) ]]; then
        show_iommu_group
    else
        warn "IOMMU is not active on this boot."
        print_boot_instructions
    fi
}

cmd_vfio() {
    need_root
    validate_config
    resolve_ids

    info "Writing $VFIO_CONF"
    cat > "$VFIO_CONF" <<EOF
# Generated by DarwinKVM proxmox-gpu-passthrough.sh
options vfio-pci ids=$GPU_VENDOR_DEVICE_IDS disable_vga=1
softdep amdgpu pre: vfio-pci
softdep radeon pre: vfio-pci
EOF

    info "Updating initramfs"
    update-initramfs -u -k all

    if command -v proxmox-boot-tool >/dev/null 2>&1; then
        proxmox-boot-tool refresh
    fi

    print_boot_instructions
    warn "reboot the host, then run: $0 check"
}

cmd_create() {
    need_root
    validate_config
    resolve_ids
    check_iommu_enabled

    if qm status "$VMID" >/dev/null 2>&1; then
        die "VM $VMID already exists. Change VMID in the configuration."
    fi

    if ! lspci -k -s "$GPU_BUS.0" | grep -q "Kernel driver in use: vfio-pci"; then
        warn "GPU is not bound to vfio-pci yet. Run '$0 vfio' and reboot first."
    fi

    info "Creating VM $VMID ($VM_NAME)"
    qm create "$VMID" \
        --name "$VM_NAME" \
        --machine "$VM_MACHINE" \
        --bios ovmf \
        --ostype other \
        --cpu "$VM_CPU_TYPE" \
        --cores "$VM_CORES" \
        --memory "$VM_MEMORY_MB" \
        --scsihw virtio-scsi-pci \
        --net0 "vmxnet3,bridge=$VM_BRIDGE"

    qm set "$VMID" --efidisk0 "${VM_DISK_STORAGE}:1,efitype=4m,pre-enrolled-keys=0"
    qm set "$VMID" --scsi0 "${VM_DISK_STORAGE}:${VM_DISK_SIZE_GB}"

    # pcie=1 needs q35. x-vga=1 makes the GPU the primary display of the VM.
    qm set "$VMID" --hostpci0 "${GPU_BUS},pcie=1,x-vga=1"

    if [[ -n $VM_EXTRA_ARGS ]]; then
        qm set "$VMID" --args "$VM_EXTRA_ARGS"
    fi

    info "VM $VMID created. Next steps:"
    echo "    1. Add your OpenCore image as a disk, or set the boot order in the web UI."
    echo "    2. Add the VM's SMBIOS, OSK and device-id spoof for your macOS version (see the DarwinKVM docs)."
    echo "    3. Start the VM: qm start $VMID"
}

usage() {
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
    check)  need_cmds; cmd_check ;;
    vfio)   need_cmds; cmd_vfio ;;
    create) need_cmds; cmd_create ;;
    *)      usage; exit 1 ;;
esac
