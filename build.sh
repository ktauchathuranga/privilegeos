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

warning() {
    echo -e "\n\e[1;33m[WARNING] ==> $1\e[0m"
}

cleanup() {
    log "Cleaning up..."
    if [ -n "${LOOP_DEV}" ] && losetup -a | grep -q "${LOOP_DEV}"; then
        sudo umount "${BUILD_DIR}/mnt" 2>/dev/null || true
        sudo losetup -d "${LOOP_DEV}" || true
    fi
}

trap cleanup EXIT

# --- Main Build Steps ---

check_dependencies() {
    log "Checking for dependencies..."
    local deps=("gcc" "make" "bc" "ncursesw6-config" "qemu-system-x86_64" "parted" "mkfs.vfat" "losetup" "lsblk")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            error "Dependency '$dep' not found. Please install it."
        fi
    done
    if [ ! -f /usr/share/ovmf/x64/OVMF.fd ] && [ ! -f /usr/share/ovmf/x64/OVMF.4m.fd ]; then
        error "OVMF firmware not found. Please install the 'ovmf' package."
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
    mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,etc,proc,sys,dev,usr/bin,usr/sbin,tmp,root}
    # Create /dev/pts directory explicitly
    mkdir -p "${INITRAMFS_DIR}/dev/pts"
    chmod 1777 "${INITRAMFS_DIR}/tmp"
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
    cat <<EOF > "${INITRAMFS_DIR}/init"
#!/bin/sh

# Force output to the video console
exec > /dev/tty0 2>&1

# Mount essential virtual filesystems
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

# Create /dev/pts directory if it doesn't exist
mkdir -p /dev/pts

# Load common modules for hardware support
modprobe fbcon 2>/dev/null || echo "Framebuffer console not available"
modprobe vt 2>/dev/null || echo "Virtual terminal not available"

# Try loading common graphics drivers
modprobe i915 2>/dev/null || echo "Intel graphics not available"  # Intel
modprobe amdgpu 2>/dev/null || echo "AMD graphics not available"  # AMD
modprobe nouveau 2>/dev/null || echo "NVIDIA graphics not available"  # NVIDIA

# Initialize the framebuffer device
for i in /sys/class/graphics/fb*; do
    [ -e "\$i" ] || continue
    echo "Found framebuffer: \$(basename \$i)"
    # Optional: set specific framebuffer resolution
    # echo "1280x720" > "\$i/mode"
done

# Execute the real init system from BusyBox
exec /sbin/init
EOF
    chmod +x "${INITRAMFS_DIR}/init"

    # Create inittab for BusyBox init
    cat <<EOF > "${INITRAMFS_DIR}/etc/inittab"
# This is run once at startup
::sysinit:/etc/init.d/rcS

# Start a shell on the graphical console (the screen)
tty1::respawn:/bin/sh
tty2::respawn:/bin/sh
tty3::respawn:/bin/sh

# Start a shell on the first serial port (for debugging)
ttyS0::respawn:/bin/sh

# What to do when restarting the init process
::restart:/sbin/init

# What to do on ctrl-alt-del
::ctrlaltdel:/sbin/reboot

# What to do when shutting down
::shutdown:/bin/umount -a -r
::shutdown:/sbin/swapoff -a
EOF

    # Create rcS script (runs at boot) with debugging info
    mkdir -p "${INITRAMFS_DIR}/etc/init.d"
    cat <<EOF > "${INITRAMFS_DIR}/etc/init.d/rcS"
#!/bin/sh

# Debug info
touch /tmp/rcS_started
echo "rcS script started" > /dev/console

# Force output to video console
exec > /dev/tty0 2>&1

# Mount additional filesystems that might be needed
mount -t tmpfs none /tmp
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts

# Display hardware information
echo ""
echo "  ____       _ _ _         _   ___  ____  "
echo " |  _ \ _ __(_) | |  _ __ (_) / _ \/ ___| "
echo " | |_) | '__| | | | | '_ \| |/ / | \___ \ "
echo " |  __/| |  | | | |_| |_) | / /| |___) |"
echo " |_|   |_|  |_|_|\___/ .__/|_\/  \____/ "
echo "                     |_|                "
echo ""
echo "Welcome to ${OS_NAME}!"
echo ""

# Set hostname
echo "${OS_NAME}" > /etc/hostname
hostname -F /etc/hostname

# Print hardware info
echo "Hardware Information:"
echo "===================="
cat /proc/cpuinfo | grep "model name" | head -1
free -m | awk 'NR==2{printf "Memory: %s/%s MB (%.2f%%)\n", \$3, \$2, \$3*100/\$2}'
lspci -k | grep -A 2 -E "(VGA|3D|Display)"

echo ""
echo "Graphics devices:"
for i in /sys/class/graphics/fb*; do
    [ -e "\$i" ] || continue
    FB_NAME=\$(basename \$i)
    FB_MODE=\$(cat \$i/mode 2>/dev/null || echo "unknown")
    echo "- \$FB_NAME: \$FB_MODE"
done

echo ""
echo "Type 'poweroff' or 'reboot' to exit."
echo ""

# Create another debug file to verify completion
touch /tmp/rcS_completed
EOF
    # Set proper execution permissions
    chmod 755 "${INITRAMFS_DIR}/etc/init.d/rcS"

    echo "${OS_NAME}" > "${INITRAMFS_DIR}/etc/hostname"
    
    log "initramfs content created."
}

build_kernel() {
    log "Building the Linux Kernel..."
    cd "$KERNEL_SRC_DIR"
    
    make mrproper
    make defconfig
    
    # Essential kernel configs for bootable media
    ./scripts/config --enable CONFIG_EFI_STUB
    ./scripts/config --enable CONFIG_EFI
    ./scripts/config --enable CONFIG_EFI_VARS
    ./scripts/config --enable CONFIG_FB_EFI
    
    # Devfs and hardware support
    ./scripts/config --enable CONFIG_DEVTMPFS
    ./scripts/config --enable CONFIG_DEVTMPFS_MOUNT
    
    # Serial and console
    ./scripts/config --enable CONFIG_SERIAL_8250
    ./scripts/config --enable CONFIG_SERIAL_8250_CONSOLE
    ./scripts/config --enable CONFIG_VIRTIO_CONSOLE
    
    # Display/Framebuffer
    ./scripts/config --enable CONFIG_FB
    ./scripts/config --enable CONFIG_FB_SIMPLE
    ./scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE
    ./scripts/config --enable CONFIG_LOGO
    ./scripts/config --enable CONFIG_LOGO_LINUX_CLUT224
    
    # Graphics cards (for real hardware)
    ./scripts/config --enable CONFIG_DRM
    ./scripts/config --enable CONFIG_DRM_I915       # Intel
    ./scripts/config --enable CONFIG_DRM_AMDGPU     # AMD
    ./scripts/config --enable CONFIG_DRM_NOUVEAU    # NVIDIA
    ./scripts/config --enable CONFIG_DRM_VIRTIO_GPU # Virtual
    ./scripts/config --enable CONFIG_DRM_PANEL
    ./scripts/config --enable CONFIG_DRM_FBDEV_EMULATION
    ./scripts/config --enable CONFIG_BACKLIGHT_CLASS_DEVICE
    ./scripts/config --enable CONFIG_BACKLIGHT_PWM
    ./scripts/config --enable CONFIG_BACKLIGHT_GPIO
    
    # Sound support
    ./scripts/config --enable CONFIG_SND
    ./scripts/config --enable CONFIG_SND_HDA_INTEL
    ./scripts/config --enable CONFIG_SND_HDA_CODEC_REALTEK
    ./scripts/config --enable CONFIG_SND_HDA_CODEC_HDMI
    ./scripts/config --enable CONFIG_SND_USB_AUDIO
    
    # Storage controllers (for real hardware)
    ./scripts/config --enable CONFIG_ATA
    ./scripts/config --enable CONFIG_SATA_AHCI
    ./scripts/config --enable CONFIG_SCSI
    ./scripts/config --enable CONFIG_BLK_DEV_SD
    ./scripts/config --enable CONFIG_NVME_CORE
    ./scripts/config --enable CONFIG_NVME_PCI
    
    # USB support
    ./scripts/config --enable CONFIG_USB
    ./scripts/config --enable CONFIG_USB_XHCI_HCD
    ./scripts/config --enable CONFIG_USB_EHCI_HCD
    ./scripts/config --enable CONFIG_USB_OHCI_HCD
    ./scripts/config --enable CONFIG_USB_UHCI_HCD
    ./scripts/config --enable CONFIG_USB_STORAGE
    ./scripts/config --enable CONFIG_USB_HID
    
    # Input devices
    ./scripts/config --enable CONFIG_INPUT
    ./scripts/config --enable CONFIG_INPUT_EVDEV
    ./scripts/config --enable CONFIG_INPUT_KEYBOARD
    ./scripts/config --enable CONFIG_INPUT_MOUSE
    ./scripts/config --enable CONFIG_INPUT_TOUCHSCREEN
    ./scripts/config --enable CONFIG_HID
    ./scripts/config --enable CONFIG_HID_GENERIC
    
    # Network support
    ./scripts/config --enable CONFIG_NET
    ./scripts/config --enable CONFIG_ETHERNET
    ./scripts/config --enable CONFIG_E1000
    ./scripts/config --enable CONFIG_E1000E
    ./scripts/config --enable CONFIG_R8169
    ./scripts/config --enable CONFIG_IWLWIFI      # Intel WiFi
    ./scripts/config --enable CONFIG_ATH9K        # Atheros WiFi
    ./scripts/config --enable CONFIG_RTL8192CE    # Realtek WiFi

    # Laptop-specific features
    ./scripts/config --enable CONFIG_ACPI
    ./scripts/config --enable CONFIG_ACPI_BATTERY
    ./scripts/config --enable CONFIG_ACPI_AC
    ./scripts/config --enable CONFIG_X86_INTEL_LPSS
    ./scripts/config --enable CONFIG_THINKPAD_ACPI
    ./scripts/config --enable CONFIG_DELL_LAPTOP
    
    # Initramfs config
    ./scripts/config --enable CONFIG_INITRAMFS_SOURCE
    ./scripts/config --set-str CONFIG_INITRAMFS_SOURCE "${INITRAMFS_DIR}"
    
    # Command line
    ./scripts/config --enable CONFIG_CMDLINE_BOOL
    ./scripts/config --set-str CONFIG_CMDLINE "console=tty0 console=ttyS0"
    
    # Add KMS support
    ./scripts/config --enable CONFIG_DRM_KMS_HELPER

    make olddefconfig
    make -j$(nproc) bzImage
    
    cd "$SCRIPT_DIR"
    log "Kernel build complete."
}

create_uefi_disk_image() {
    log "Creating UEFI disk image..."
    
    # Create a larger image for more drivers and better hardware support
    dd if=/dev/zero of="${DISK_IMG}" bs=1M count=512
    parted -s "${DISK_IMG}" mklabel gpt
    parted -s "${DISK_IMG}" mkpart ESP fat32 1MiB 100%
    parted -s "${DISK_IMG}" set 1 esp on
    parted -s "${DISK_IMG}" set 1 boot on
    
    LOOP_DEV=$(sudo losetup -f --show -P "${DISK_IMG}")
    if [ -z "$LOOP_DEV" ]; then
        error "Failed to set up loopback device."
    fi
    
    sudo mkfs.vfat -F 32 "${LOOP_DEV}p1"
    mkdir -p "${BUILD_DIR}/mnt"
    sudo mount "${LOOP_DEV}p1" "${BUILD_DIR}/mnt"
    
    # Create proper EFI directory structure
    sudo mkdir -p "${BUILD_DIR}/mnt/EFI/BOOT"
    sudo cp "${KERNEL_SRC_DIR}/arch/x86/boot/bzImage" "${BUILD_DIR}/mnt/EFI/BOOT/BOOTX64.EFI"
    
    # Create a startup.nsh script for better UEFI compatibility
    cat <<EOF | sudo tee "${BUILD_DIR}/mnt/startup.nsh" > /dev/null
@echo -off
echo Loading ${OS_NAME}...
\EFI\BOOT\BOOTX64.EFI
EOF
    
    sudo umount "${BUILD_DIR}/mnt"
    sudo losetup -d "${LOOP_DEV}"
    LOOP_DEV=""
    
    log "UEFI disk image created at ${DISK_IMG}"
}

write_to_usb() {
    log "Preparing to write to USB drive..."
    
    # Show available drives
    echo "Available drives:"
    lsblk -d -o NAME,SIZE,MODEL,VENDOR,TYPE | grep -v loop
    echo ""
    
    # Ask for confirmation
    read -p "Enter the device name to write to (e.g., sdb, NOT sdb1): " USB_DEVICE
    
    # Safety checks
    if [[ -z "$USB_DEVICE" ]]; then
        error "No device specified."
    fi
    
    if [[ "$USB_DEVICE" == *"loop"* ]]; then
        error "Loop devices are not allowed."
    fi
    
    if [[ ! -b "/dev/${USB_DEVICE}" ]]; then
        error "Device /dev/${USB_DEVICE} does not exist or is not a block device."
    fi
    
    if grep -q "^/dev/${USB_DEVICE}" /proc/mounts; then
        warning "Device /dev/${USB_DEVICE} is mounted. Unmounting..."
        sudo umount "/dev/${USB_DEVICE}"* || error "Failed to unmount device."
    fi
    
    # Final confirmation
    echo ""
    echo "YOU ARE ABOUT TO OVERWRITE /dev/${USB_DEVICE}"
    echo "ALL DATA ON THIS DEVICE WILL BE PERMANENTLY LOST!"
    echo ""
    read -p "Type 'YES' to continue: " CONFIRM
    
    if [[ "$CONFIRM" != "YES" ]]; then
        error "Operation aborted."
    fi
    
    log "Writing image to /dev/${USB_DEVICE}..."
    sudo dd if="${DISK_IMG}" of="/dev/${USB_DEVICE}" bs=4M status=progress conv=fsync
    sudo sync
    
    log "Image successfully written to USB drive."
    echo ""
    echo "You can now boot your laptop from this USB drive."
    echo "Make sure to select UEFI boot mode in your BIOS/firmware settings."
}

run_qemu() {
    log "Testing in QEMU before writing to USB..."
    
    OVMF_PATH="/usr/share/ovmf/x64/OVMF.4m.fd"
    if [ ! -f "$OVMF_PATH" ]; then
        OVMF_PATH="/usr/share/ovmf/x64/OVMF.fd"
    fi
    
    qemu-system-x86_64 \
        -machine q35,accel=kvm \
        -cpu host \
        -m 2G \
        -smp 2 \
        -bios "$OVMF_PATH" \
        -drive file="${DISK_IMG}",format=raw,if=virtio \
        -device intel-hda \
        -device hda-output \
        -nic user,model=e1000e \
        -device usb-ehci \
        -device usb-tablet \
        -serial stdio \
        -display gtk,gl=on \
        -no-reboot
}

# --- Main Execution Flow ---
main() {
 #   check_dependencies
    setup_workspace
    build_busybox
    create_initramfs_content
    build_kernel
    create_uefi_disk_image
    
    # Ask if the user wants to test in QEMU first
    read -p "Test in QEMU first? (y/n): " TEST_QEMU
    if [[ "$TEST_QEMU" == "y" || "$TEST_QEMU" == "Y" ]]; then
        run_qemu
    fi
    
    # Write to USB drive
    write_to_usb
    
    log "Done. Your bootable USB drive is ready."
}

main "$@"
