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
    if losetup -a | grep -q "${LOOP_DEV}"; then
        sudo umount "${BUILD_DIR}/mnt" || true
        sudo losetup -d "${LOOP_DEV}" || true
    fi
}

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
    
    make distclean
    make defconfig
    
    sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
    sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
    
    make -j$(nproc)
    make CONFIG_PREFIX="${INITRAMFS_DIR}" install
    
    cd "$SCRIPT_DIR"
    log "BusyBox build complete."
}

create_initramfs_content() {
    log "Creating initramfs content..."
    
    # Create essential device nodes. While devtmpfs will create most,
    # these are good fallbacks for early boot.
    sudo mknod -m 622 "${INITRAMFS_DIR}/dev/console" c 5 1
    sudo mknod -m 666 "${INITRAMFS_DIR}/dev/null" c 1 3
    sudo mknod -m 666 "${INITRAMFS_DIR}/dev/zero" c 1 5

    # Create init script
    # The /init in the root of the initramfs is executed by the kernel first.
    cat <<EOF > "${INITRAMFS_DIR}/init"
#!/bin/sh

# Mount essential virtual filesystems
mount -t proc none /proc
mount -t sysfs none /sys
# devtmpfs will automatically populate /dev with device nodes
mount -t devtmpfs none /dev

# A small delay can sometimes help udev/mdev events to settle, though not strictly necessary here.
# sleep 1

# Execute the real init system from BusyBox
exec /sbin/init
EOF
    chmod +x "${INITRAMFS_DIR}/init"

    # Create inittab for BusyBox init
    cat <<EOF > "${INITRAMFS_DIR}/etc/inittab"
# This is run once at startup
::sysinit:/etc/init.d/rcS

# --- The Fix is Here ---
# Start a shell on the graphical console (the screen)
tty1::askfirst:-/bin/sh

# Start a shell on the first serial port (for debugging)
ttyS0::askfirst:-/bin/sh

# What to do when restarting the init process
::restart:/sbin/init

# What to do on ctrl-alt-del
::ctrlaltdel:/sbin/reboot

# What to do when shutting down
::shutdown:/bin/umount -a -r
::shutdown:/sbin/swapoff -a
EOF

    # Create rcS script (runs at boot)
    mkdir -p "${INITRAMFS_DIR}/etc/init.d"
    cat <<EOF > "${INITRAMFS_DIR}/etc/init.d/rcS"
#!/bin/sh

# You can add other boot-time commands here, like mounting filesystems.

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
    
    # No need to create /sbin/init symlink as BusyBox install does this.
    # No need to create /dev/tty* manually if using devtmpfs.
    
    log "initramfs content created."
}

build_kernel() {
    log "Building the Linux Kernel..."
    cd "$KERNEL_SRC_DIR"
    
    make mrproper
    make defconfig
    
    # Essential kernel configs
    ./scripts/config --enable CONFIG_EFI_STUB
    ./scripts/config --enable CONFIG_EFI
    ./scripts/config --enable CONFIG_FB_EFI
    ./scripts/config --enable CONFIG_VIRTIO_PCI
    ./scripts/config --enable CONFIG_VIRTIO_BLK
    ./scripts/config --enable CONFIG_DEVTMPFS
    ./scripts/config --enable CONFIG_DEVTMPFS_MOUNT
    ./scripts/config --enable CONFIG_SERIAL_8250
    ./scripts/config --enable CONFIG_SERIAL_8250_CONSOLE
    ./scripts/config --enable CONFIG_VIRTIO_CONSOLE
    ./scripts/config --enable CONFIG_FB
    ./scripts/config --enable CONFIG_FB_SIMPLE
    ./scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE
    ./scripts/config --enable CONFIG_LOGO
    ./scripts/config --enable CONFIG_LOGO_LINUX_CLUT224
    
    ./scripts/config --enable CONFIG_DRM_VIRTIO_GPU
    ./scripts/config --enable CONFIG_SND
    ./scripts/config --enable CONFIG_SND_HDA_INTEL
    ./scripts/config --enable CONFIG_E1000E
    ./scripts/config --enable CONFIG_USB
    ./scripts/config --enable CONFIG_USB_EHCI_HCD
    ./scripts/config --enable CONFIG_USB_OHCI_HCD
    ./scripts/config --enable CONFIG_USB_UHCI_HCD
    ./scripts/config --enable CONFIG_USB_HID
    ./scripts/config --enable CONFIG_INPUT
    ./scripts/config --enable CONFIG_INPUT_EVDEV
    ./scripts/config --enable CONFIG_HID
    ./scripts/config --enable CONFIG_HID_GENERIC
    ./scripts/config --enable CONFIG_ATA
    ./scripts/config --enable CONFIG_SATA_AHCI
    
    # Initramfs config
    ./scripts/config --enable CONFIG_INITRAMFS_SOURCE
    ./scripts/config --set-str CONFIG_INITRAMFS_SOURCE "${INITRAMFS_DIR}"
    
    # Command line
    ./scripts/config --enable CONFIG_CMDLINE_BOOL
    ./scripts/config --set-str CONFIG_CMDLINE "console=tty0 console=ttyS0 quiet"

    make olddefconfig
    make -j$(nproc) bzImage
    
    cd "$SCRIPT_DIR"
    log "Kernel build complete."
}

create_uefi_disk_image() {
    log "Creating UEFI disk image..."
    
    dd if=/dev/zero of="${DISK_IMG}" bs=1M count=256
    parted -s "${DISK_IMG}" mklabel gpt
    parted -s "${DISK_IMG}" mkpart ESP fat32 1MiB 100%
    parted -s "${DISK_IMG}" set 1 esp on
    
    LOOP_DEV=$(sudo losetup -f --show -P "${DISK_IMG}")
    if [ -z "$LOOP_DEV" ]; then
        error "Failed to set up loopback device."
    fi
    
    sudo mkfs.vfat -F 32 "${LOOP_DEV}p1"
    mkdir -p "${BUILD_DIR}/mnt"
    sudo mount "${LOOP_DEV}p1" "${BUILD_DIR}/mnt"
    sudo mkdir -p "${BUILD_DIR}/mnt/EFI/BOOT"
    sudo cp "${KERNEL_SRC_DIR}/arch/x86/boot/bzImage" "${BUILD_DIR}/mnt/EFI/BOOT/BOOTX64.EFI"
    
    sudo umount "${BUILD_DIR}/mnt"
    sudo losetup -d "${LOOP_DEV}"
    
    log "UEFI disk image created at ${DISK_IMG}"
}

run_qemu() {
    qemu-system-x86_64 \
        -machine q35,accel=kvm \
        -cpu host \
        -m 8G \
        -smp 4 \
        -bios /usr/share/ovmf/x64/OVMF.4m.fd \
        -drive file="${DISK_IMG}",format=raw,if=virtio \
        -device intel-hda \
        -device hda-output \
        -nic user,model=e1000e \
        -device usb-ehci \
        -device usb-tablet \
        -serial stdio \
        -no-reboot
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
