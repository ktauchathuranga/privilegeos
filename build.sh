#!/bin/bash

# Script: build_privilegeos.sh
# Description: Builds a minimal Linux distribution called PrivilegeOS
# Author: ktauchathuranga
# Version: 2.0

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting
set -u
# Prevent masking errors in a pipeline
set -o pipefail

# --- Configuration (can be overridden with command line options) ---
OS_NAME="PrivilegeOS"
KERNEL_VER="6.15.3"
BUSYBOX_VER="1.36.1"
THREADS=$(nproc)
MEMORY="2G"
IMAGE_SIZE="512"  # In MB

# Source directories (assumed to be in the same folder as the script)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
KERNEL_SRC_DIR="${SCRIPT_DIR}/linux-${KERNEL_VER}"
BUSYBOX_SRC_DIR="${SCRIPT_DIR}/busybox-${BUSYBOX_VER}"

# Build directory
BUILD_DIR="${SCRIPT_DIR}/build"
INITRAMFS_DIR="${BUILD_DIR}/initramfs"
DISK_IMG="${BUILD_DIR}/${OS_NAME}.img"
CONFIG_DIR="${SCRIPT_DIR}/configs"
LOG_DIR="${BUILD_DIR}/logs"

# --- Variables for tracking state ---
LOOP_DEV=""

# --- Output formatting ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Helper Functions ---
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    # Ensure LOG_DIR exists
    mkdir -p "${LOG_DIR}"

    # Ensure build.log exists
    if [ ! -f "${LOG_DIR}/build.log" ]; then
        touch "${LOG_DIR}/build.log"
    fi

    # Output to console and log file
    echo -e "\n${GREEN}${BOLD}[INFO ${timestamp}] ==> $1${NC}"
    echo "[INFO ${timestamp}] $1" >> "${LOG_DIR}/build.log"
}


error() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "\n${RED}${BOLD}[ERROR ${timestamp}] ==> $1${NC}" >&2
    echo "[ERROR ${timestamp}] $1" >> "${LOG_DIR}/build.log"
    exit 1
}

warning() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "\n${YELLOW}${BOLD}[WARNING ${timestamp}] ==> $1${NC}"
    echo "[WARNING ${timestamp}] $1" >> "${LOG_DIR}/build.log"
}

info() {
    echo -e "${BLUE}$1${NC}"
}

show_progress() {
    local pid=$1
    local delay=0.75
    local spinstr='|/-\'
    
    echo -n " "
    while ps a | awk '{print $1}' | grep -q "$pid"; do
        local temp=${spinstr#?}
        printf "\b%c" "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
    done
    printf "\b \n"
}

cleanup() {
    log "Cleaning up..."
    if [ -n "${LOOP_DEV}" ] && losetup -a | grep -q "${LOOP_DEV}"; then
        sudo umount "${BUILD_DIR}/mnt" 2>/dev/null || true
        sudo losetup -d "${LOOP_DEV}" || true
    fi
}

show_help() {
    cat << EOF
Usage: $0 [options]

Options:
  -h, --help           Show this help message and exit
  -n, --name NAME      Set OS name (default: PrivilegeOS)
  -k, --kernel VER     Set kernel version (default: ${KERNEL_VER})
  -b, --busybox VER    Set BusyBox version (default: ${BUSYBOX_VER})
  -j, --threads N      Set number of threads for compilation (default: $(nproc))
  -m, --memory SIZE    Set QEMU memory size (default: ${MEMORY})
  -s, --size SIZE      Set disk image size in MB (default: ${IMAGE_SIZE})
  -c, --clean          Clean build directory before starting
  -q, --qemu-only      Only build and test in QEMU (no USB writing)
  --skip-qemu          Skip QEMU testing
  --kernel-config FILE Use custom kernel config file

Examples:
  $0 --clean --name MyOS --kernel 6.15.3 --size 1024
  $0 --qemu-only --threads 4
EOF
    exit 0
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                ;;
            -n|--name)
                OS_NAME="$2"
                shift 2
                ;;
            -k|--kernel)
                KERNEL_VER="$2"
                KERNEL_SRC_DIR="${SCRIPT_DIR}/linux-${KERNEL_VER}"
                shift 2
                ;;
            -b|--busybox)
                BUSYBOX_VER="$2"
                BUSYBOX_SRC_DIR="${SCRIPT_DIR}/busybox-${BUSYBOX_VER}"
                shift 2
                ;;
            -j|--threads)
                THREADS="$2"
                shift 2
                ;;
            -m|--memory)
                MEMORY="$2"
                shift 2
                ;;
            -s|--size)
                IMAGE_SIZE="$2"
                shift 2
                ;;
            -c|--clean)
                CLEAN_BUILD=1
                shift
                ;;
            -q|--qemu-only)
                QEMU_ONLY=1
                shift
                ;;
            --skip-qemu)
                SKIP_QEMU=1
                shift
                ;;
            --kernel-config)
                CUSTOM_KERNEL_CONFIG="$2"
                shift 2
                ;;
            *)
                error "Unknown option: $1"
                ;;
        esac
    done
}

# --- Main Build Steps ---

check_dependencies() {
    log "Checking for dependencies..."
    local deps=("gcc" "make" "bc" "qemu-system-x86_64" "parted" "mkfs.vfat" "losetup" "lsblk" "wget" "xz" "tar")
    local missing_deps=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done

    # Check for specific packages with more detailed info
    if ! command -v "ncursesw6-config" &> /dev/null && ! command -v "ncurses5-config" &> /dev/null; then
        missing_deps+=("ncurses-dev/libncurses-dev")
    fi

    if [ ! -f /usr/share/ovmf/x64/OVMF.fd ] && [ ! -f /usr/share/ovmf/x64/OVMF.4m.fd ]; then
        missing_deps+=("ovmf")
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo "Missing dependencies: ${missing_deps[*]}"
        
        # Detect OS and suggest installation command
        if [ -f /etc/debian_version ]; then
            echo "Try: sudo apt-get install ${missing_deps[*]}"
        elif [ -f /etc/fedora-release ]; then
            echo "Try: sudo dnf install ${missing_deps[*]}"
        elif [ -f /etc/arch-release ]; then
            echo "Try: sudo pacman -S ${missing_deps[*]}"
        else
            echo "Please install the missing dependencies."
        fi
        
        error "Dependencies not satisfied."
    fi
    
    log "All dependencies are satisfied."
}

download_sources() {
    log "Checking source availability..."
    
    # Download kernel if needed
    if [ ! -d "$KERNEL_SRC_DIR" ]; then
        log "Downloading Linux kernel ${KERNEL_VER}..."
        wget -c "https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_VER:0:1}.x/linux-${KERNEL_VER}.tar.xz" -P "${BUILD_DIR}"
        tar -xf "${BUILD_DIR}/linux-${KERNEL_VER}.tar.xz" -C "${SCRIPT_DIR}"
        rm "${BUILD_DIR}/linux-${KERNEL_VER}.tar.xz"
    else
        log "Kernel source already present."
    fi
    
    # Download BusyBox if needed
    if [ ! -d "$BUSYBOX_SRC_DIR" ]; then
        log "Downloading BusyBox ${BUSYBOX_VER}..."
        wget -c "https://busybox.net/downloads/busybox-${BUSYBOX_VER}.tar.bz2" -P "${BUILD_DIR}"
        tar -xf "${BUILD_DIR}/busybox-${BUSYBOX_VER}.tar.bz2" -C "${SCRIPT_DIR}"
        rm "${BUILD_DIR}/busybox-${BUSYBOX_VER}.tar.bz2"
    else
        log "BusyBox source already present."
    fi
}

setup_workspace() {
    log "Setting up the build workspace..."
    
    # Create config directory if it doesn't exist
    mkdir -p "${CONFIG_DIR}"
    
    # If clean build requested, remove build directory
    if [ -n "${CLEAN_BUILD:-}" ]; then
        log "Cleaning build directory..."
        rm -rf "$BUILD_DIR"
    fi
    
    # Create build directories
    mkdir -p "$BUILD_DIR"
    mkdir -p "${LOG_DIR}"
    
    # Create fresh initramfs directory structure
    rm -rf "${INITRAMFS_DIR}"
    mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,etc,proc,sys,dev,usr/bin,usr/sbin,tmp,root,run,lib,mnt,opt,var/log}
    mkdir -p "${INITRAMFS_DIR}"/{etc/init.d,etc/network}
    # Create /dev/pts directory explicitly
    mkdir -p "${INITRAMFS_DIR}/dev/pts"
    chmod 1777 "${INITRAMFS_DIR}/tmp"
    
    log "Workspace created at ${BUILD_DIR}"
}

build_busybox() {
    log "Building BusyBox ${BUSYBOX_VER}..."
    cd "$BUSYBOX_SRC_DIR"
    
    # Save custom BusyBox config if it doesn't exist
    if [ ! -f "${CONFIG_DIR}/busybox.config" ]; then
        make defconfig
        sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
        sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
        cp .config "${CONFIG_DIR}/busybox.config"
        log "Saved default BusyBox config to ${CONFIG_DIR}/busybox.config"
    else
        log "Using existing BusyBox config"
        cp "${CONFIG_DIR}/busybox.config" .config
    fi
    
    # Build BusyBox with progress indicator
    log "Compiling BusyBox..."
    make -j"${THREADS}" > "${LOG_DIR}/busybox_build.log" 2>&1 &
    build_pid=$!
    show_progress "$build_pid"
    wait "$build_pid" || error "BusyBox build failed. Check ${LOG_DIR}/busybox_build.log for details."
    
    # Install BusyBox to initramfs
    log "Installing BusyBox to initramfs..."
    make CONFIG_PREFIX="${INITRAMFS_DIR}" install >> "${LOG_DIR}/busybox_build.log" 2>&1
    
    cd "$SCRIPT_DIR"
    log "BusyBox build complete."
}

create_initramfs_content() {
    log "Creating initramfs content..."
    
    # Create essential device nodes. While devtmpfs will create most,
    # these are good fallbacks for early boot.
    log "Creating essential device nodes..."
    sudo mknod -m 622 "${INITRAMFS_DIR}/dev/console" c 5 1
    sudo mknod -m 666 "${INITRAMFS_DIR}/dev/null" c 1 3
    sudo mknod -m 666 "${INITRAMFS_DIR}/dev/zero" c 1 5
    sudo mknod -m 666 "${INITRAMFS_DIR}/dev/ptmx" c 5 2
    sudo mknod -m 666 "${INITRAMFS_DIR}/dev/tty" c 5 0
    sudo mknod -m 444 "${INITRAMFS_DIR}/dev/random" c 1 8
    sudo mknod -m 444 "${INITRAMFS_DIR}/dev/urandom" c 1 9

    # Create init script with more diagnostics and features
    log "Creating init script..."
    cat <<EOF > "${INITRAMFS_DIR}/init"
#!/bin/sh

# Init script for ${OS_NAME}
# Set up kernel message logging level (1=critical, 7=debug)
dmesg -n 7

# Force output to the video console
exec > /dev/tty0 2>&1

echo "Starting ${OS_NAME} init process..."

# Mount essential virtual filesystems
mount -t proc none /proc || echo "Failed to mount /proc"
mount -t sysfs none /sys || echo "Failed to mount /sys"
mount -t devtmpfs none /dev || echo "Failed to mount /dev"
mount -t tmpfs none /tmp || echo "Failed to mount /tmp"
mount -t devpts devpts /dev/pts || echo "Failed to mount /dev/pts"

# Setup loopback interface
ip link set lo up

# Load common modules for hardware support
echo "Loading kernel modules for hardware support..."
modprobe fbcon 2>/dev/null || echo "Framebuffer console not available"
modprobe vt 2>/dev/null || echo "Virtual terminal not available"

# Try loading common graphics drivers
echo "Loading display drivers..."
modprobe i915 2>/dev/null || echo "Intel graphics not available"  # Intel
modprobe amdgpu 2>/dev/null || echo "AMD graphics not available"  # AMD
modprobe nouveau 2>/dev/null || echo "NVIDIA graphics not available"  # NVIDIA
modprobe virtio_gpu 2>/dev/null || echo "Virtio GPU not available"  # Virtual

# Initialize the framebuffer device
for i in /sys/class/graphics/fb*; do
    [ -e "\$i" ] || continue
    echo "Found framebuffer: \$(basename \$i)"
    # Optional: set specific framebuffer resolution
    # echo "1280x720" > "\$i/mode"
done

# Let's make sure the system knows its hostname
hostname -F /etc/hostname

# Execute the real init system from BusyBox
echo "Transferring control to BusyBox init..."
exec /sbin/init
EOF
    chmod +x "${INITRAMFS_DIR}/init"

    # Create improved inittab for BusyBox init
    log "Creating inittab..."
    cat <<EOF > "${INITRAMFS_DIR}/etc/inittab"
# /etc/inittab for ${OS_NAME}

# System initialization
::sysinit:/etc/init.d/rcS

# Start shells on consoles
tty1::respawn:/bin/sh
tty2::respawn:/bin/sh
tty3::respawn:/bin/sh

# Start a shell on the first serial port (for debugging)
ttyS0::respawn:/bin/sh

# Start a login prompt on the serial console
#ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100

# What to do when restarting the init process
::restart:/sbin/init

# What to do on ctrl-alt-del
::ctrlaltdel:/sbin/reboot

# What to do when shutting down
::shutdown:/bin/umount -a -r
::shutdown:/sbin/swapoff -a
EOF

    # Create rcS script (runs at boot) with more detailed diagnostics
    log "Creating rcS script..."
    cat <<EOF > "${INITRAMFS_DIR}/etc/init.d/rcS"
#!/bin/sh
# System startup script for ${OS_NAME}

# Debug info
touch /tmp/rcS_started
echo "rcS script started" > /dev/console

# Force output to video console
exec > /dev/tty0 2>&1

# Mount additional filesystems that might be needed
mount -t tmpfs none /var || echo "Failed to mount /var"

# Create log directory
mkdir -p /var/log

# Save kernel log to file
dmesg > /var/log/dmesg.log

# Setup system path
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# Display welcome message
echo ""
echo -e "\e[1;34m  ____       _ _ _         _   ___  ____  \e[0m"
echo -e "\e[1;34m |  _ \\ _ __(_) | |  _ __ (_) / _ \\/ ___| \e[0m"
echo -e "\e[1;34m | |_) | '__| | | | | '_ \\| |/ / | \\___ \\ \e[0m"
echo -e "\e[1;34m |  __/| |  | | | |_| |_) | / /| |___) |\e[0m"
echo -e "\e[1;34m |_|   |_|  |_|_|\\___/ .__/|_\\/  \\____/ \e[0m"
echo -e "\e[1;34m                     |_|                \e[0m"
echo ""
echo -e "\e[1mWelcome to ${OS_NAME}!\e[0m"
echo -e "\e[1mBuild date: $(date)\e[0m"
echo ""

# Set hostname
echo "${OS_NAME}" > /etc/hostname
hostname -F /etc/hostname

# Setup networking loopback interface
ip addr add 127.0.0.1/8 dev lo
ip link set lo up

# Print hardware info
echo -e "\e[1mHardware Information:\e[0m"
echo "===================="
cat /proc/cpuinfo | grep "model name" | head -1
free -m | awk 'NR==2{printf "Memory: %s/%s MB (%.2f%%)\n", \$3, \$2, \$3*100/\$2}'
cat /proc/meminfo | grep MemTotal

echo -e "\n\e[1mStorage devices:\e[0m"
lsblk

echo -e "\n\e[1mPCI Devices:\e[0m"
lspci

echo -e "\n\e[1mGraphics devices:\e[0m"
for i in /sys/class/graphics/fb*; do
    [ -e "\$i" ] || continue
    FB_NAME=\$(basename \$i)
    FB_MODE=\$(cat \$i/mode 2>/dev/null || echo "unknown")
    echo "- \$FB_NAME: \$FB_MODE"
done

echo -e "\n\e[1mNetwork interfaces:\e[0m"
ip addr

echo ""
echo -e "\e[1;32mType 'poweroff' or 'reboot' to exit.\e[0m"
echo ""

# Create another debug file to verify completion
touch /tmp/rcS_completed
EOF
    # Set proper execution permissions
    chmod 755 "${INITRAMFS_DIR}/etc/init.d/rcS"

    echo "${OS_NAME}" > "${INITRAMFS_DIR}/etc/hostname"
    
    # Create basic network configuration
    log "Creating network configuration..."
    cat <<EOF > "${INITRAMFS_DIR}/etc/network/interfaces"
# Network interfaces for ${OS_NAME}

# Loopback interface
auto lo
iface lo inet loopback

# Default configuration for eth0 (DHCP)
auto eth0
iface eth0 inet dhcp
EOF

    # Create /etc/issue for login screen
    cat <<EOF > "${INITRAMFS_DIR}/etc/issue"
${OS_NAME} \r (\l) \d \t

Welcome! Login with root (no password)

EOF
    
    log "initramfs content created."
}

build_kernel() {
    log "Building the Linux Kernel ${KERNEL_VER}..."
    cd "$KERNEL_SRC_DIR"
    
    # Clean kernel source
    make mrproper > "${LOG_DIR}/kernel_clean.log" 2>&1
    
    # Use custom kernel config if provided
    if [ -n "${CUSTOM_KERNEL_CONFIG:-}" ] && [ -f "$CUSTOM_KERNEL_CONFIG" ]; then
        log "Using custom kernel config from $CUSTOM_KERNEL_CONFIG"
        cp "$CUSTOM_KERNEL_CONFIG" .config
    elif [ -f "${CONFIG_DIR}/kernel.config" ]; then
        log "Using existing kernel config from ${CONFIG_DIR}/kernel.config"
        cp "${CONFIG_DIR}/kernel.config" .config
    else
        log "Creating new kernel config with essential features"
        make defconfig > "${LOG_DIR}/kernel_defconfig.log" 2>&1
        
        # Essential kernel configs for bootable media
        log "Configuring kernel features..."
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
        
        # Save the config for future builds
        cp .config "${CONFIG_DIR}/kernel.config"
    fi

    # Make sure config is up to date with current kernel
    log "Updating kernel config..."
    make olddefconfig > "${LOG_DIR}/kernel_olddefconfig.log" 2>&1
    
    # Build the kernel with progress indicator
    log "Compiling kernel (this might take a while)..."
    make -j"${THREADS}" bzImage > "${LOG_DIR}/kernel_build.log" 2>&1 &
    build_pid=$!
    show_progress "$build_pid"
    wait "$build_pid" || error "Kernel build failed. Check ${LOG_DIR}/kernel_build.log for details."
    
    cd "$SCRIPT_DIR"
    log "Kernel build complete."
}

create_uefi_disk_image() {
    log "Creating UEFI disk image..."
    
    # Create a larger image for more drivers and better hardware support
    log "Creating raw disk image of ${IMAGE_SIZE}MB..."
    dd if=/dev/zero of="${DISK_IMG}" bs=1M count="${IMAGE_SIZE}" status=progress
    
    # Partition the disk image for UEFI
    log "Partitioning disk image..."
    parted -s "${DISK_IMG}" mklabel gpt
    parted -s "${DISK_IMG}" mkpart ESP fat32 1MiB 100%
    parted -s "${DISK_IMG}" set 1 esp on
    parted -s "${DISK_IMG}" set 1 boot on
    
    # Set up loopback device
    log "Setting up loopback device..."
    LOOP_DEV=$(sudo losetup -f --show -P "${DISK_IMG}")
    if [ -z "$LOOP_DEV" ]; then
        error "Failed to set up loopback device."
    fi
    
    # Format the EFI partition
    log "Formatting EFI partition..."
    sudo mkfs.vfat -F 32 "${LOOP_DEV}p1"
    
    # Mount the EFI partition
    log "Mounting EFI partition..."
    mkdir -p "${BUILD_DIR}/mnt"
    sudo mount "${LOOP_DEV}p1" "${BUILD_DIR}/mnt"
    
    # Create proper EFI directory structure and copy kernel
    log "Copying kernel to EFI partition..."
    sudo mkdir -p "${BUILD_DIR}/mnt/EFI/BOOT"
    sudo cp "${KERNEL_SRC_DIR}/arch/x86/boot/bzImage" "${BUILD_DIR}/mnt/EFI/BOOT/BOOTX64.EFI"
    
    # Create UEFI startup script
    log "Creating UEFI startup script..."
    cat <<EOF | sudo tee "${BUILD_DIR}/mnt/startup.nsh" > /dev/null
@echo -off
echo Loading ${OS_NAME}...
\EFI\BOOT\BOOTX64.EFI
EOF
    
    # Create a readme file with info
    cat <<EOF | sudo tee "${BUILD_DIR}/mnt/README.txt" > /dev/null
${OS_NAME} - A minimal Linux distribution
Built on: $(date)
Kernel version: ${KERNEL_VER}
BusyBox version: ${BUSYBOX_VER}

This is a bootable UEFI image. To boot:
1. Make sure UEFI boot is enabled in your BIOS/firmware settings
2. Boot from this device
3. The system should automatically start

For technical support or issues:
- Check logs in /var/log/
- Use the serial console for debugging (115200 baud)
EOF
    
    # Unmount and clean up loop device
    log "Unmounting EFI partition..."
    sudo umount "${BUILD_DIR}/mnt"
    sudo losetup -d "${LOOP_DEV}"
    LOOP_DEV=""
    
    log "UEFI disk image created at ${DISK_IMG}"
}

write_to_usb() {
    log "Preparing to write to USB drive..."
    
    # Show available drives
    echo "Available drives:"
    lsblk -d -o NAME,SIZE,MODEL,VENDOR,TYPE | grep -v loop | grep -v "$(df / | grep -o '^\S*' | sed 's/[0-9]*$//')"
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
    
    # Check if this is the boot device
    ROOT_DISK=$(df / | grep -o '^\S*' | sed 's/[0-9]*$//')
    if [[ "$ROOT_DISK" == "/dev/${USB_DEVICE}" ]]; then
        error "You're trying to write to the system's boot disk! Operation aborted for safety."
    fi
    
    # Check if any partition on the device is mounted
    if grep -q "^/dev/${USB_DEVICE}" /proc/mounts; then
        warning "Device /dev/${USB_DEVICE} has mounted partitions. Attempting to unmount..."
        mounted_parts=$(grep "^/dev/${USB_DEVICE}" /proc/mounts | cut -d' ' -f1)
        for part in $mounted_parts; do
            sudo umount "$part" || error "Failed to unmount $part. Aborting for safety."
        done
        log "Successfully unmounted all partitions on /dev/${USB_DEVICE}"
    fi
    
    # Get device size for verification
    DEVICE_SIZE=$(sudo blockdev --getsize64 "/dev/${USB_DEVICE}")
    IMAGE_SIZE_BYTES=$(stat -c%s "${DISK_IMG}")
    
    # Convert to human-readable format for display
    DEVICE_SIZE_HR=$(numfmt --to=iec-i --suffix=B ${DEVICE_SIZE})
    IMAGE_SIZE_HR=$(numfmt --to=iec-i --suffix=B ${IMAGE_SIZE_BYTES})
    
    if [[ ${DEVICE_SIZE} -lt ${IMAGE_SIZE_BYTES} ]]; then
        error "USB drive is too small (${DEVICE_SIZE_HR}) for the image (${IMAGE_SIZE_HR})."
    fi
    
    # Final confirmation with detailed info
    echo ""
    echo -e "${RED}${BOLD}WARNING: YOU ARE ABOUT TO OVERWRITE /dev/${USB_DEVICE}${NC}"
    echo -e "${RED}${BOLD}ALL DATA ON THIS DEVICE (${DEVICE_SIZE_HR}) WILL BE PERMANENTLY LOST!${NC}"
    echo -e "${YELLOW}Device: /dev/${USB_DEVICE}${NC}"
    echo -e "${YELLOW}Image file: ${DISK_IMG} (${IMAGE_SIZE_HR})${NC}"
    echo ""
    read -p "Type 'YES' (all caps) to continue: " CONFIRM
    
    if [[ "$CONFIRM" != "YES" ]]; then
        error "Operation aborted."
    fi
    
    log "Writing image to /dev/${USB_DEVICE}..."
    sudo dd if="${DISK_IMG}" of="/dev/${USB_DEVICE}" bs=8M status=progress conv=fsync
    sudo sync
    
    log "Image successfully written to USB drive."
    echo ""
    echo -e "${GREEN}${BOLD}You can now boot your laptop from this USB drive.${NC}"
    echo -e "${GREEN}Make sure to select UEFI boot mode in your BIOS/firmware settings.${NC}"
}

run_qemu() {
    log "Testing in QEMU..."
    
    # Find OVMF firmware
    OVMF_PATH="/usr/share/ovmf/x64/OVMF.4m.fd"
    if [ ! -f "$OVMF_PATH" ]; then
        OVMF_PATH="/usr/share/ovmf/x64/OVMF.fd"
        if [ ! -f "$OVMF_PATH" ]; then
            error "OVMF firmware not found. Please install the 'ovmf' package."
        fi
    fi
    
    log "Starting QEMU with ${MEMORY} of RAM..."
    qemu-system-x86_64 \
        -machine q35,accel=kvm \
        -cpu host \
        -m "${MEMORY}" \
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
    
    # Ask for feedback after QEMU session ends
    echo ""
    read -p "Did the system boot correctly in QEMU? (y/n): " QEMU_RESULT
    if [[ "$QEMU_RESULT" == "y" || "$QEMU_RESULT" == "Y" ]]; then
        log "QEMU test passed."
    else
        warning "QEMU test may have had issues. Consider checking the logs in ${LOG_DIR} before writing to USB."
    fi
}

# --- Main Execution Flow ---
main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    # Register cleanup handler
    trap cleanup EXIT INT TERM

    # Initialize variables
    CLEAN_BUILD=${CLEAN_BUILD:-0}
    QEMU_ONLY=${QEMU_ONLY:-0}
    SKIP_QEMU=${SKIP_QEMU:-0}
    
    # Print build info
    echo ""
    echo -e "${BLUE}${BOLD}Building ${OS_NAME}${NC}"
    echo -e "${BLUE}Kernel version: ${KERNEL_VER}${NC}"
    echo -e "${BLUE}BusyBox version: ${BUSYBOX_VER}${NC}"
    echo -e "${BLUE}Using ${THREADS} threads for compilation${NC}"
    echo -e "${BLUE}Disk image size: ${IMAGE_SIZE}MB${NC}"
    echo ""

    # Run build steps
    check_dependencies
    setup_workspace
    download_sources
    build_busybox
    create_initramfs_content
    build_kernel
    create_uefi_disk_image
    
    # Test in QEMU if not skipped
    if [ "${SKIP_QEMU:-0}" -ne 1 ]; then
        # Ask if the user wants to test in QEMU first
        if [ "${QEMU_ONLY:-0}" -eq 1 ] || { read -p "Test in QEMU first? (y/n): " TEST_QEMU && [[ "$TEST_QEMU" == "y" || "$TEST_QEMU" == "Y" ]]; }; then
            run_qemu
        fi
    fi
    
    # Write to USB if not QEMU-only mode
    if [ "${QEMU_ONLY:-0}" -ne 1 ]; then
        # Ask if user wants to write to USB
        read -p "Write to USB drive now? (y/n): " WRITE_USB
        if [[ "$WRITE_USB" == "y" || "$WRITE_USB" == "Y" ]]; then
            write_to_usb
        else
            log "Skipping USB write. Your disk image is available at: ${DISK_IMG}"
        fi
    fi
    
    log "Done. Build complete."
    echo ""
    echo -e "${GREEN}${BOLD}Summary:${NC}"
    echo -e "${GREEN}- OS Name: ${OS_NAME}${NC}"
    echo -e "${GREEN}- Kernel: ${KERNEL_VER}${NC}"
    echo -e "${GREEN}- BusyBox: ${BUSYBOX_VER}${NC}"
    echo -e "${GREEN}- Image: ${DISK_IMG} ($(du -h "${DISK_IMG}" | cut -f1))${NC}"
    echo -e "${GREEN}- Logs: ${LOG_DIR}${NC}"
    echo ""
}

# Execute main function with all arguments
main "$@"
