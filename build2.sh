#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
OS_NAME="PrivilegeOS"
KERNEL_VER="6.15.3"
BUSYBOX_VER="1.36.1"

# Source directories (assumed to be in the same folder as the script)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
KERNEL_SRC_DIR="${SCRIPT_DIR}/linux-${KERNEL_VER}"
BUSYBOX_SRC_DIR="${SCRIPT_DIR}/busybox-${BUSYBOX_VER}"

# Build directory
BUILD_DIR="${SCRIPT_DIR}/build"
INITRAMFS_DIR="${BUILD_DIR}/initramfs"
USB_MNT_DIR="${BUILD_DIR}/usbmnt" # Mount point for USB flashing
DISK_IMG="${BUILD_DIR}/${OS_NAME}.img"

# This variable will be set later if we use a loop device
LOOP_DEV=""

# --- Helper Functions ---
log() {
    echo -e "\n\e[1;32m[INFO] ==> $1\e[0m"
}

error() {
    echo -e "\n\e[1;31m[ERROR] ==> $1\e[0m"
    exit 1
}

warn() {
    echo -e "\n\e[1;33m[WARNING] ==> $1\e[0m"
}

cleanup() {
    log "Cleaning up..."
    # Unmount USB mount point if it exists
    if mountpoint -q "${USB_MNT_DIR}"; then
        sudo umount "${USB_MNT_DIR}"
    fi
    # Detach loop device if it was used
    if [ -n "$LOOP_DEV" ] && losetup -a | grep -q "${LOOP_DEV}"; then
        sudo umount "${BUILD_DIR}/mnt" || true
        sudo losetup -d "${LOOP_DEV}" || true
    fi
}

trap cleanup EXIT

usage() {
    echo "Usage: $0 [action] [device]"
    echo "Actions:"
    echo "  run           Builds the disk image and runs it in QEMU. (Default)"
    echo "  build         Builds the disk image and exits."
    echo "  usb <device>  Builds and flashes the OS to a USB device (e.g., /dev/sdc)."
    echo "                !!! THIS IS DESTRUCTIVE AND WILL ERASE THE DEVICE !!!"
    exit 1
}


# --- Main Build Steps ---

check_dependencies() {
    log "Checking for dependencies..."
    # Added wipefs for cleaner partitioning
    local deps=("gcc" "make" "bc" "ncursesw6-config" "qemu-system-x86_64" "parted" "mkfs.vfat" "losetup" "wipefs")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            error "Dependency '$dep' not found. Please install it."
        fi
    done
    if [ ! -f /usr/share/ovmf/x64/OVMF.4m.fd ]; then
        error "OVMF firmware not found at /usr/share/ovmf/x64/OVMF.fd. Please install the 'ovmf' package. The path might also be 'OVMF_CODE.fd' on some systems."
    fi
    log "All dependencies are satisfied."
}

setup_workspace() {
    log "Setting up the build workspace..."
    if [ ! -d "$KERNEL_SRC_DIR" ]; then
        error "Kernel source directory not found: $KERNEL_SRC_DIR"
    fi
    if [ ! -d "$BUSYBOX_SRC_DIR" ]; then
        error "BusyBox source directory not found: $BUSYBOX_SRC_DIR"
    fi

    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,etc,proc,sys,dev,usr/bin,usr/sbin}
    log "Workspace created at ${BUILD_DIR}"
}

build_busybox() {
    log "Building BusyBox..."
    cd "$BUSYBOX_SRC_DIR"
    
    make distclean
    make defconfig
    
    # Statically link BusyBox to avoid library dependencies
    sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
    # This can sometimes cause build issues, disabling if not needed.
    sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
    
    make -j$(nproc)
    make CONFIG_PREFIX="${INITRAMFS_DIR}" install
    
    cd "$SCRIPT_DIR"
    log "BusyBox build complete."
}

create_initramfs_content() {
    log "Creating initramfs content..."
    
    sudo mknod -m 622 "${INITRAMFS_DIR}/dev/console" c 5 1
    sudo mknod -m 666 "${INITRAMFS_DIR}/dev/null" c 1 3
    sudo mknod -m 666 "${INITRAMFS_DIR}/dev/zero" c 1 5

    cat <<EOF > "${INITRAMFS_DIR}/init"
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
exec /sbin/init
EOF
    chmod +x "${INITRAMFS_DIR}/init"

    cat <<EOF > "${INITRAMFS_DIR}/etc/inittab"
::sysinit:/etc/init.d/rcS
tty1::askfirst:-/bin/sh
ttyS0::askfirst:-/bin/sh
::restart:/sbin/init
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
::shutdown:/sbin/swapoff -a
EOF

    mkdir -p "${INITRAMFS_DIR}/etc/init.d"
    cat <<EOF > "${INITRAMFS_DIR}/etc/init.d/rcS"
#!/bin/sh
echo ""
echo "  ____       _ _ _         _   ___  ____  "
echo " |  _ \ _ __(_) | |  _ __ (_) / _ \/ ___| "
echo " | |_) | '__| | | | | '_ \| |/ / | \___ \ "
echo " |  __/| |  | | | |_| |_) | / /| |___) |"
echo " |_|   |_|  |_|_|\___/ .__/|_\/  \____/ "
echo "                     |_|                "
echo ""
echo "Welcome to ${OS_NAME}! Type 'poweroff' or 'reboot' to exit."
echo ""
hostname -F /etc/hostname
EOF
    chmod +x "${INITRAMFS_DIR}/etc/init.d/rcS"

    echo "${OS_NAME}" > "${INITRAMFS_DIR}/etc/hostname"
    
    log "initramfs content created."
}

build_kernel() {
    log "Building the Linux Kernel..."
    cd "$KERNEL_SRC_DIR"
    
    make mrproper
    make defconfig
    
    # --- QEMU Specific Drivers (Keep them for testing) ---
    ./scripts/config --enable CONFIG_VIRTIO_PCI
    ./scripts/config --enable CONFIG_VIRTIO_BLK
    ./scripts/config --enable CONFIG_VIRTIO_CONSOLE
    ./scripts/config --enable CONFIG_DRM_VIRTIO_GPU
    
    # --- ENHANCED GOP AND EFI FRAMEBUFFER SUPPORT ---
    log "Enabling enhanced GOP and EFI framebuffer support..."
    
    # Basic EFI support (required for GOP)
    ./scripts/config --enable CONFIG_EFI
    ./scripts/config --enable CONFIG_EFI_STUB
    ./scripts/config --enable CONFIG_EFI_MIXED
    ./scripts/config --enable CONFIG_FB_EFI
    
    # Enhanced framebuffer support
    ./scripts/config --enable CONFIG_FB
    ./scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE
    ./scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE_DETECT_PRIMARY
    ./scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE_ROTATION
    
    # EFI Graphics Output Protocol specific options
    ./scripts/config --enable CONFIG_EFI_EARLYCON
    ./scripts/config --enable CONFIG_EARLY_PRINTK_EFI
    
    # Simple framebuffer for GOP fallback
    ./scripts/config --enable CONFIG_DRM_SIMPLEDRM
    ./scripts/config --enable CONFIG_DRM_FBDEV_EMULATION
    
    # VGA/Graphics Support
    ./scripts/config --enable CONFIG_VGA_CONSOLE
    ./scripts/config --enable CONFIG_VGACON_SOFT_SCROLLBACK
    ./scripts/config --enable CONFIG_LOGO
    ./scripts/config --enable CONFIG_LOGO_LINUX_CLUT224
    
    # Core system requirements
    ./scripts/config --enable CONFIG_DEVTMPFS
    ./scripts/config --enable CONFIG_DEVTMPFS_MOUNT
    
    # --- Core Console/Serial (Correct) ---
    ./scripts/config --enable CONFIG_SERIAL_8250
    ./scripts/config --enable CONFIG_SERIAL_8250_CONSOLE

    # --- Generic Drivers for Real Hardware (Good start) ---
    ./scripts/config --enable CONFIG_SATA_AHCI # SATA disks
    ./scripts/config --enable CONFIG_USB_XHCI_HCD # USB 3.0
    ./scripts/config --enable CONFIG_USB_EHCI_HCD # USB 2.0
    ./scripts/config --enable CONFIG_USB_OHCI_HCD # USB 1.1
    ./scripts/config --enable CONFIG_USB_HID # Keyboards, Mice
    ./scripts/config --enable CONFIG_HID_GENERIC
    ./scripts/config --enable CONFIG_E1000E # Common Intel NIC
    ./scripts/config --enable CONFIG_SND_HDA_INTEL # Common Intel HD Audio

    # ====================================================================
    # --- Drivers for Real Physical GPUs (ENHANCED) ---
    # ====================================================================
    log "Enabling enhanced drivers for physical GPUs..."

    # Enable the main DRM (Direct Rendering Manager) subsystem
    ./scripts/config --enable CONFIG_DRM
    ./scripts/config --enable CONFIG_DRM_KMS_HELPER
    ./scripts/config --enable CONFIG_DRM_KMS_FB_HELPER

    # Enable Intel i915 Driver (Most common for Dell laptops)
    ./scripts/config --enable CONFIG_DRM_I915
    ./scripts/config --enable CONFIG_DRM_I915_USERPTR
    ./scripts/config --enable CONFIG_DRM_I915_GVT
    ./scripts/config --enable CONFIG_DRM_I915_CAPTURE_ERROR
    ./scripts/config --enable CONFIG_DRM_I915_COMPRESS_ERROR

    # --- FIX: Force probe i915 devices even if firmware is missing ---
    ./scripts/config --enable CONFIG_DRM_I915_FORCE_PROBE
    ./scripts/config --set-str CONFIG_DRM_I915_FORCE_PROBE "\"*\""

    # Ensure firmware loader is built-in (might help if we have firmware)
    ./scripts/config --enable CONFIG_FW_LOADER
    ./scripts/config --enable CONFIG_FW_LOADER_BUILTIN
    ./scripts/config --enable CONFIG_EXTRA_FIRMWARE
    
    # AMD GPU Driver for wider compatibility
    ./scripts/config --enable CONFIG_DRM_AMD
    ./scripts/config --enable CONFIG_DRM_AMDGPU
    ./scripts/config --enable CONFIG_DRM_AMDGPU_SI
    ./scripts/config --enable CONFIG_DRM_AMDGPU_CIK
    
    # NVIDIA GPU basic support (Nouveau driver)
    ./scripts/config --enable CONFIG_DRM_NOUVEAU
    
    # --- Initramfs config (Correct) ---
    ./scripts/config --enable CONFIG_INITRAMFS_SOURCE
    ./scripts/config --set-str CONFIG_INITRAMFS_SOURCE "${INITRAMFS_DIR}"
    
    # --- Command line with GOP-specific parameters ---
    ./scripts/config --enable CONFIG_CMDLINE_BOOL
    # Using a more verbose command line for debugging on real hardware with explicit framebuffer settings
    ./scripts/config --set-str CONFIG_CMDLINE "console=tty1 console=ttyS0,115200 video=efifb:nobgrt fbcon=scrollback:1024k fbcon=font:VGA8x16 loglevel=7"

    make olddefconfig
    make -j$(nproc) bzImage
    
    cd "$SCRIPT_DIR"
    log "Kernel build complete. Ready at ${KERNEL_SRC_DIR}/arch/x86/boot/bzImage"
}

install_to_uefi_target() {
    local TARGET_DEV="$1"
    local TARGET_IS_BLOCKDEV=false
    
    if [ -b "${TARGET_DEV}" ]; then
        TARGET_IS_BLOCKDEV=true
    fi
    
    if [ "$TARGET_IS_BLOCKDEV" = true ]; then
        log "Preparing to flash to block device ${TARGET_DEV}"
        warn "THIS WILL COMPLETELY ERASE ALL DATA ON ${TARGET_DEV}."
        
        echo -e "\n\e[1;33mDevice information:\e[0m"
        lsblk -o NAME,SIZE,MODEL "${TARGET_DEV}"
        
        read -p $'\n\e[1;31mARE YOU ABSOLUTELY SURE? Type YES to continue: \e[0m' CONFIRMATION
        if [ "${CONFIRMATION}" != "YES" ]; then
            error "Aborted by user."
        fi
        
        log "User confirmed. Wiping and partitioning ${TARGET_DEV}..."
        sudo umount "${TARGET_DEV}"* || true
        sudo wipefs -a "${TARGET_DEV}"
        
    else
        log "Creating UEFI disk image file..."
        dd if=/dev/zero of="${TARGET_DEV}" bs=1M count=256
    fi
    
    sudo parted -s "${TARGET_DEV}" mklabel gpt
    sudo parted -s "${TARGET_DEV}" mkpart ESP fat32 1MiB 100%
    sudo parted -s "${TARGET_DEV}" set 1 esp on
    
    if [ "$TARGET_IS_BLOCKDEV" = true ]; then
        log "Waiting for kernel to recognize new partition..."
        sleep 3
        sudo partprobe "${TARGET_DEV}"
        sleep 1
    fi
    
    local PARTITION
    if [ "$TARGET_IS_BLOCKDEV" = true ]; then
        # This logic handles both standard devices (sda -> sda1)
        # and NVMe devices (nvme0n1 -> nvme0n1p1).
        if [[ "${TARGET_DEV}" == *nvme* ]]; then
            PARTITION="${TARGET_DEV}p1"
        else
            PARTITION="${TARGET_DEV}1"
        fi
    else
        # This is the logic for file-based images
        LOOP_DEV=$(sudo losetup -f --show -P "${TARGET_DEV}")
        if [ -z "$LOOP_DEV" ]; then
            error "Failed to set up loopback device."
        fi
        PARTITION="${LOOP_DEV}p1"
    fi
    
    if [ ! -b "$PARTITION" ]; then
        error "Could not find partition device at '${PARTITION}'. The kernel may not have detected it."
    fi

    log "Formatting partition ${PARTITION} as FAT32..."
    sudo mkfs.vfat -F 32 "${PARTITION}"
    
    log "Mounting and copying EFI bootloader..."
    local MNT_POINT
    if [ "$TARGET_IS_BLOCKDEV" = true ]; then
        MNT_POINT="${USB_MNT_DIR}"
    else
        MNT_POINT="${BUILD_DIR}/mnt"
    fi
    
    mkdir -p "${MNT_POINT}"
    sudo mount "${PARTITION}" "${MNT_POINT}"
    sudo mkdir -p "${MNT_POINT}/EFI/BOOT"
    
    sudo cp "${KERNEL_SRC_DIR}/arch/x86/boot/bzImage" "${MNT_POINT}/EFI/BOOT/BOOTX64.EFI"
    
    log "Unmounting target..."
    sudo umount "${MNT_POINT}"
    
    if [ "$TARGET_IS_BLOCKDEV" = false ]; then
        sudo losetup -d "${LOOP_DEV}"
    else
        sync
    fi
    
    log "UEFI target ${TARGET_DEV} is ready."
}

run_qemu() {
    log "Starting QEMU..."
    qemu-system-x86_64 \
        -machine q35,accel=kvm \
        -cpu host \
        -m 2G \
        -smp 2 \
        -bios /usr/share/ovmf/x64/OVMF.4m.fd \
        -drive file="${DISK_IMG}",format=raw,if=virtio \
        -device intel-hda -device hda-output \
        -nic user,model=e1000e \
        -device usb-ehci -device usb-tablet \
        -serial stdio \
        -no-reboot
}

# --- Main Execution Flow ---
main() {
    ACTION="${1:-run}" # Default to 'run' if no action is specified

    case "$ACTION" in
        run)
            check_dependencies
            setup_workspace
            build_busybox
            create_initramfs_content
            build_kernel
            install_to_uefi_target "${DISK_IMG}"
            run_qemu
            ;;
        build)
            setup_workspace
            build_busybox
            create_initramfs_content
            build_kernel
            install_to_uefi_target "${DISK_IMG}"
            log "Build complete. Image is at ${DISK_IMG}"
            ;;
        usb)
            TARGET_USB_DEV="$2"
            if [ -z "$TARGET_USB_DEV" ]; then
                error "No target device specified for 'usb' action."
                usage
            fi
            if [ ! -b "$TARGET_USB_DEV" ]; then
                error "Target '${TARGET_USB_DEV}' is not a block device."
            fi

          #  check_dependencies
            setup_workspace
            build_busybox
            create_initramfs_content
            build_kernel
            install_to_uefi_target "${TARGET_USB_DEV}"
            log "Flashing complete. You can now safely eject ${TARGET_USB_DEV} and boot from it."
            ;;
        *)
            usage
            ;;
    esac

    log "Done."
}

main "$@"
