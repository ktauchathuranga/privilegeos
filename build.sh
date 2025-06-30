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
DISK_IMG="${BUILD_DIR}/${OS_NAME}.img"

# --- Helper Functions ---
log() {
    echo -e "\n\e[1;32m[INFO] ==> $1\e[0m"
}

error() {
    echo -e "\n\e[1;31m[ERROR] ==> $1\e[0m"
    exit 1
}

cleanup() {
    log "Cleaning up..."
    # In case of script failure, unmount loop device if it exists
    if losetup -a | grep -q "${LOOP_DEV}"; then
        sudo umount "${BUILD_DIR}/mnt" || true
        sudo losetup -d "${LOOP_DEV}" || true
    fi
    # Don't remove the final build directory unless specified
    # rm -rf "${BUILD_DIR}"
}

# Trap errors and call cleanup
trap cleanup EXIT

# --- Main Build Steps ---

check_dependencies() {
    log "Checking for dependencies..."
    local deps=("gcc" "make" "bc" "ncursesw6-config" "qemu-system-x86_64" "parted" "mkfs.vfat" "losetup")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            error "Dependency '$dep' not found. Please install it."
        fi
    done
    if [ ! -f /usr/share/ovmf/x64/OVMF.fd ]; then
        error "OVMF firmware not found at /usr/share/ovmf/x64/OVMF.fd. Please install the 'ovmf' package."
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
    
    # Clean and configure for a static build
    make distclean
    make defconfig
    
    # Enable static linking so we don't need to worry about shared libraries
    sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
    sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
    
    make -j$(nproc)
    make CONFIG_PREFIX="${INITRAMFS_DIR}" install
    
    cd "$SCRIPT_DIR"
    log "BusyBox build complete."
}

create_initramfs_content() {
    log "Creating initramfs content..."
    
    # The mknod calls are removed. The kernel's devtmpfs will create these automatically.
    
    # Create the main init script
    cat <<EOF > "${INITRAMFS_DIR}/etc/inittab"
# This is the first process run by init
::sysinit:/etc/init.d/rcS

# Start a shell on the console
::askfirst:-/bin/sh

# What to do when restarting/halting
::restart:/sbin/init
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
::shutdown:/sbin/swapoff -a
EOF

    # Create the system startup script
    mkdir -p "${INITRAMFS_DIR}/etc/init.d"
    cat <<EOF > "${INITRAMFS_DIR}/etc/init.d/rcS"
#!/bin/sh

# Mount essential filesystems
mount -t proc none /proc
mount -t sysfs none /sys

# devtmpfs will automatically create /dev/null, /dev/console, etc.
# This is the key step that makes the manual mknod calls unnecessary.
mount -t devtmpfs none /dev

# Display a welcome message
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

# Set hostname
hostname -F /etc/hostname
EOF
    chmod +x "${INITRAMFS_DIR}/etc/init.d/rcS"

    # Set a hostname
    echo "${OS_NAME}" > "${INITRAMFS_DIR}/etc/hostname"
    
    log "initramfs content created."
}

build_kernel() {
    log "Building the Linux Kernel..."
    cd "$KERNEL_SRC_DIR"
    
    make mrproper
    make defconfig
    
    # Enable kernel options required for a minimal UEFI boot
    log "Configuring kernel for UEFI boot and QEMU hardware..."
    ./scripts/config --enable CONFIG_EFI_STUB
    ./scripts/config --enable CONFIG_EFI
    ./scripts/config --enable CONFIG_FB_EFI
    ./scripts/config --enable CONFIG_VIRTIO_PCI
    ./scripts/config --enable CONFIG_VIRTIO_BLK
    ./scripts/config --enable CONFIG_DEVTMPFS
    ./scripts/config --enable CONFIG_DEVTMPFS_MOUNT
    
    # --- FIX STARTS HERE ---
    # Enable the driver for the legacy PC serial port (8250/16550A) used by "qemu -serial stdio"
    ./scripts/config --enable CONFIG_SERIAL_8250
    # Allow the legacy serial port to be used as a system console
    ./scripts/config --enable CONFIG_SERIAL_8250_CONSOLE
    # --- FIX ENDS HERE ---

    # NOTE: You already enabled CONFIG_VIRTIO_CONSOLE, which is good, but the
    # QEMU command "-serial stdio" creates a legacy serial port, not a virtio one.
    # To use a virtio console, you'd change the QEMU flags. For now, enabling
    # the legacy driver is the correct fix for the current script.
    ./scripts/config --enable CONFIG_VIRTIO_CONSOLE # This is fine to leave enabled
    
    # Embed our initramfs directly into the kernel executable
    ./scripts/config --enable CONFIG_INITRAMFS_SOURCE
    ./scripts/config --set-str CONFIG_INITRAMFS_SOURCE "${INITRAMFS_DIR}"
    
    # Set a default command line
    ./scripts/config --enable CONFIG_CMDLINE_BOOL
    ./scripts/config --set-str CONFIG_CMDLINE "quiet console=ttyS0"

    make -j$(nproc) bzImage
    
    cd "$SCRIPT_DIR"
    log "Kernel build complete. The bootable EFI file is arch/x86/boot/bzImage"
}

create_uefi_disk_image() {
    log "Creating UEFI disk image..."
    
    # Create a 256MB disk image
    dd if=/dev/zero of="${DISK_IMG}" bs=1M count=256
    
    # Create a GPT partition table and an EFI System Partition (ESP)
    parted -s "${DISK_IMG}" mklabel gpt
    parted -s "${DISK_IMG}" mkpart ESP fat32 1MiB 100%
    parted -s "${DISK_IMG}" set 1 esp on
    
    # Format the partition with FAT32
    # We use a loopback device to mount the partition from the image file
    LOOP_DEV=$(sudo losetup -f --show -P "${DISK_IMG}")
    if [ -z "$LOOP_DEV" ]; then
        error "Failed to set up loopback device."
    fi
    
    # The partition is at ${LOOP_DEV}p1
    sudo mkfs.vfat -F 32 "${LOOP_DEV}p1"
    
    # Mount the partition
    mkdir -p "${BUILD_DIR}/mnt"
    sudo mount "${LOOP_DEV}p1" "${BUILD_DIR}/mnt"
    
    # Create the standard UEFI boot directory structure
    sudo mkdir -p "${BUILD_DIR}/mnt/EFI/BOOT"
    
    # Copy the kernel and rename it to the default UEFI bootloader name
    sudo cp "${KERNEL_SRC_DIR}/arch/x86/boot/bzImage" "${BUILD_DIR}/mnt/EFI/BOOT/BOOTX64.EFI"
    
    # Unmount and detach the loopback device
    sudo umount "${BUILD_DIR}/mnt"
    sudo losetup -d "${LOOP_DEV}"
    
    log "UEFI disk image created at ${DISK_IMG}"
}

run_qemu() {
    log "Booting ${OS_NAME} with QEMU..."
    echo "--- To exit QEMU, press Ctrl+A, then X ---"
    
    qemu-system-x86_64 \
        -machine q35,accel=kvm \
        -m 2G \
        -cpu host \
        -bios /usr/share/ovmf/x64/OVMF.4m.fd \
        -drive file="${DISK_IMG}",format=raw,if=virtio \
        -serial stdio \
        -display none
}

# --- Main Execution Flow ---
main() {
#    check_dependencies
    setup_workspace
    build_busybox
    create_initramfs_content
    build_kernel
    create_uefi_disk_image
    run_qemu
    log "Done."
}

main "$@"
