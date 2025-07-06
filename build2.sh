#!/bin/bash

# Script: build.sh
# Description: Builds PrivilegeOS with separate initramfs for faster debugging
# Version: 3.4 (Separated initramfs from kernel)
# Date: 2025-07-06

# Exit on errors
set -e

# --- Configuration ---
OS_NAME="PrivilegeOS"
KERNEL_VER="6.15.3"
BUSYBOX_VER="1.36.1"
NTFS3G_VER="2022.10.3"
THREADS=$(nproc)
MEMORY="2G"
IMAGE_SIZE="512"  # In MB

# Source directories
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
KERNEL_SRC_DIR="${SCRIPT_DIR}/linux-${KERNEL_VER}"
BUSYBOX_SRC_DIR="${SCRIPT_DIR}/busybox-${BUSYBOX_VER}"
NTFS3G_SRC_DIR="${SCRIPT_DIR}/ntfs-3g-${NTFS3G_VER}"
CUSTOM_SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

# Build directory
BUILD_DIR="${SCRIPT_DIR}/build"
INITRAMFS_DIR="${BUILD_DIR}/initramfs"
INITRAMFS_FILE="${BUILD_DIR}/initramfs.cpio.gz"
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
    mkdir -p "${LOG_DIR}"
    if [ ! -f "${LOG_DIR}/build.log" ]; then
        touch "${LOG_DIR}/build.log"
    fi
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
  -h, --help                Show this help message and exit
  -n, --name NAME           Set OS name (default: PrivilegeOS)
  -k, --kernel VER          Set kernel version (default: ${KERNEL_VER})
  -b, --busybox VER         Set BusyBox version (default: ${BUSYBOX_VER})
  --ntfs3g VER             Set NTFS-3G version (default: ${NTFS3G_VER})
  -j, --threads N           Set number of threads for compilation (default: $(nproc))
  -m, --memory SIZE         Set QEMU memory size (default: ${MEMORY})
  -s, --size SIZE           Set disk image size in MB (default: ${IMAGE_SIZE})
  -c, --clean               Clean build directory before starting
  -q, --qemu-only           Only build and test in QEMU (no USB writing)
  --skip-qemu               Skip QEMU testing
  --skip-ntfs3g             Skip NTFS-3G build
  --skip-kernel             Skip kernel build (use existing kernel)
  --initramfs-only          Build only initramfs (for debugging)
  --update-initramfs        Update initramfs on existing disk image
  --kernel-config FILE      Use custom kernel config file
  --busybox-config FILE     Use custom BusyBox config file

Examples:
  $0 --clean --name MyOS --kernel 6.15.3 --size 1024
  $0 --qemu-only --threads 4
  $0 --initramfs-only       # Fast rebuild of just initramfs
  $0 --update-initramfs     # Update initramfs on existing image
  $0 --skip-kernel          # Skip kernel compilation
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
            --ntfs3g)
                NTFS3G_VER="$2"
                NTFS3G_SRC_DIR="${SCRIPT_DIR}/ntfs-3g-${NTFS3G_VER}"
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
            --skip-ntfs3g)
                SKIP_NTFS3G=1
                shift
                ;;
            --skip-kernel)
                SKIP_KERNEL=1
                shift
                ;;
            --initramfs-only)
                INITRAMFS_ONLY=1
                shift
                ;;
            --update-initramfs)
                UPDATE_INITRAMFS=1
                shift
                ;;
            --kernel-config)
                CUSTOM_KERNEL_CONFIG="$2"
                shift 2
                ;;
            --busybox-config)
                CUSTOM_BUSYBOX_CONFIG="$2"
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
    local deps=("gcc" "make" "bc" "qemu-system-x86_64" "parted" "mkfs.vfat" "losetup" "lsblk" "wget" "xz" "tar" "pkg-config" "autoconf" "automake" "libtool" "cpio" "gzip")
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

    # Check for FUSE development headers (needed for NTFS-3G)
    if [ "${SKIP_NTFS3G:-0}" -ne 1 ]; then
        if ! pkg-config --exists fuse || ! find /usr/include -name "fuse.h" 2>/dev/null | grep -q .; then
            missing_deps+=("libfuse-dev/fuse-devel")
        fi
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
    
    # Create build directory if it doesn't exist
    mkdir -p "${BUILD_DIR}"
    
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
    
    # Download NTFS-3G if needed and not skipped
    if [ "${SKIP_NTFS3G:-0}" -ne 1 ] && [ ! -d "$NTFS3G_SRC_DIR" ]; then
        log "Downloading NTFS-3G ${NTFS3G_VER}..."
        # Updated URL to match the GitHub archive format
        wget -c "https://github.com/tuxera/ntfs-3g/archive/${NTFS3G_VER}/ntfs-3g-${NTFS3G_VER}.tar.gz" -P "${BUILD_DIR}"
        tar -xf "${BUILD_DIR}/ntfs-3g-${NTFS3G_VER}.tar.gz" -C "${SCRIPT_DIR}"
        rm "${BUILD_DIR}/ntfs-3g-${NTFS3G_VER}.tar.gz"
    elif [ "${SKIP_NTFS3G:-0}" -ne 1 ]; then
        log "NTFS-3G source already present."
    fi
}

setup_workspace() {
    log "Setting up the build workspace..."
    
    # Create config and script directories if they don't exist
    mkdir -p "${CONFIG_DIR}"
    mkdir -p "${CUSTOM_SCRIPTS_DIR}"
    
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
    mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,etc,proc,sys,dev,usr/bin,usr/sbin,tmp,root,run,lib,lib64,mnt,opt,var/log}
    mkdir -p "${INITRAMFS_DIR}"/{etc/init.d,etc/network}
    mkdir -p "${INITRAMFS_DIR}/usr/local/bin"
    mkdir -p "${INITRAMFS_DIR}/dev/pts"
    chmod 1777 "${INITRAMFS_DIR}/tmp"
    chmod 700 "${INITRAMFS_DIR}/root"
    
    log "Workspace created at ${BUILD_DIR}"
}

build_busybox() {
    log "Building BusyBox ${BUSYBOX_VER}..."
    cd "$BUSYBOX_SRC_DIR"
    
    # Restore or apply custom BusyBox config if provided
    if [ -n "${CUSTOM_BUSYBOX_CONFIG:-}" ] && [ -f "$CUSTOM_BUSYBOX_CONFIG" ]; then
        log "Using user-provided BusyBox config from ${CUSTOM_BUSYBOX_CONFIG}"
        make distclean > /dev/null 2>&1 || true
        cp "${CUSTOM_BUSYBOX_CONFIG}" .config
    elif [ -f "${CONFIG_DIR}/busybox.config" ]; then
        log "Using existing BusyBox config from ${CONFIG_DIR}/busybox.config"
        make distclean > /dev/null 2>&1 || true
        cp "${CONFIG_DIR}/busybox.config" .config
    else
        log "Creating default BusyBox config..."
        make defconfig
        sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
        sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
        sed -i 's/# CONFIG_BLKID is not set/CONFIG_BLKID=y/' .config
        sed -i 's/# CONFIG_FINDFS is not set/CONFIG_FINDFS=y/' .config
        sed -i 's/# CONFIG_LSBLK is not set/CONFIG_LSBLK=y/' .config
        sed -i 's/# CONFIG_FDISK is not set/CONFIG_FDISK=y/' .config
        sed -i 's/# CONFIG_MKFS_VFAT is not set/CONFIG_MKFS_VFAT=y/' .config
        sed -i 's/# CONFIG_FEATURE_MOUNT_HELPERS is not set/CONFIG_FEATURE_MOUNT_HELPERS=y/' .config
        
        # Save it
        cp .config "${CONFIG_DIR}/busybox.config"
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

build_ntfs3g() {
    if [ "${SKIP_NTFS3G:-0}" -eq 1 ]; then
        log "Skipping NTFS-3G build as requested."
        return 0
    fi

    log "Building NTFS-3G ${NTFS3G_VER}..."
    cd "$NTFS3G_SRC_DIR"
    
    # Clean any previous build
    make distclean > /dev/null 2>&1 || true
    
    # Run autoreconf to generate configure script if needed
    if [ ! -f configure ]; then
        log "Generating configure script..."
        autoreconf -fiv > "${LOG_DIR}/ntfs3g_autoreconf.log" 2>&1 || error "NTFS-3G autoreconf failed. Check ${LOG_DIR}/ntfs3g_autoreconf.log for details."
    fi
    
    # Configure NTFS-3G
    log "Configuring NTFS-3G..."
    ./configure \
        --prefix="${INITRAMFS_DIR}/usr" \
        --exec-prefix="${INITRAMFS_DIR}/usr" \
        --enable-static \
        --disable-shared \
        --disable-ldconfig \
        --disable-crypto \
        --enable-extras \
        --with-fuse=internal \
        CFLAGS="-static -O2" \
        LDFLAGS="-static" > "${LOG_DIR}/ntfs3g_configure.log" 2>&1 || error "NTFS-3G configure failed. Check ${LOG_DIR}/ntfs3g_configure.log for details."
    
    # Build NTFS-3G
    log "Compiling NTFS-3G..."
    make -j"${THREADS}" > "${LOG_DIR}/ntfs3g_build.log" 2>&1 &
    build_pid=$!
    show_progress "$build_pid"
    wait "$build_pid" || error "NTFS-3G build failed. Check ${LOG_DIR}/ntfs3g_build.log for details."
    
    # Install NTFS-3G
    log "Installing NTFS-3G to initramfs..."
    make install >> "${LOG_DIR}/ntfs3g_build.log" 2>&1 || error "NTFS-3G install failed. Check ${LOG_DIR}/ntfs3g_build.log for details."
    
    # Create symlinks for common commands
    cd "${INITRAMFS_DIR}/usr/bin"
    ln -sf ntfs-3g mount.ntfs 2>/dev/null || true
    ln -sf ntfs-3g mount.ntfs-3g 2>/dev/null || true
    
    # Strip binaries to reduce size
    strip "${INITRAMFS_DIR}/usr/bin/ntfs-3g" 2>/dev/null || true
    strip "${INITRAMFS_DIR}/usr/bin/ntfsfix" 2>/dev/null || true
    strip "${INITRAMFS_DIR}/usr/bin/ntfsinfo" 2>/dev/null || true
    
    cd "$SCRIPT_DIR"
    log "NTFS-3G build complete."
}

create_initramfs_content() {
    log "Creating initramfs content..."
    
    # Create essential device nodes
    log "Creating essential device nodes..."
    sudo mknod -m 622 "${INITRAMFS_DIR}/dev/console" c 5 1
    sudo mknod -m 666 "${INITRAMFS_DIR}/dev/null" c 1 3
    sudo mknod -m 666 "${INITRAMFS_DIR}/dev/zero" c 1 5
    sudo mknod -m 666 "${INITRAMFS_DIR}/dev/ptmx" c 5 2
    sudo mknod -m 666 "${INITRAMFS_DIR}/dev/tty" c 5 0
    sudo mknod -m 444 "${INITRAMFS_DIR}/dev/random" c 1 8
    sudo mknod -m 444 "${INITRAMFS_DIR}/dev/urandom" c 1 9

    # Create init script
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

chmod -R a+r /proc 2>/dev/null || echo "Warning: Could not set permissions on /proc"
chmod -R a+r /sys 2>/dev/null || echo "Warning: Could not set permissions on /sys"

# Setup loopback interface
ip link set lo up

# Load common modules for hardware support
echo "Loading kernel modules for hardware support..."
modprobe fbcon 2>/dev/null || echo "Framebuffer console not available"
modprobe vt 2>/dev/null || echo "Virtual terminal not available"

# Load storage device modules
echo "Loading storage device modules..."
modprobe nvme 2>/dev/null || echo "NVMe module not available"
modprobe nvme_core 2>/dev/null || echo "NVMe core module not available"
modprobe ahci 2>/dev/null || echo "AHCI module not available"
modprobe sd_mod 2>/dev/null || echo "SCSI disk module not available"
modprobe usb_storage 2>/dev/null || echo "USB storage module not available"

# Load display drivers
echo "Loading display drivers..."
modprobe i915 2>/dev/null || echo "Intel graphics not available"
modprobe amdgpu 2>/dev/null || echo "AMD graphics not available"
modprobe nouveau 2>/dev/null || echo "NVIDIA graphics not available"
modprobe virtio_gpu 2>/dev/null || echo "Virtio GPU not available"

# Load FUSE module for NTFS-3G
echo "Loading FUSE module for NTFS support..."
modprobe fuse 2>/dev/null || echo "FUSE module not available"

# Initialize the framebuffer
for i in /sys/class/graphics/fb*; do
    [ -e "\$i" ] || continue
    echo "Found framebuffer: \$(basename \$i)"
done

# Set up root user environment
export HOME=/root
export USER=root
export LOGNAME=root
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin

hostname -F /etc/hostname

echo "Transferring control to BusyBox init..."
exec /sbin/init
EOF
    chmod +x "${INITRAMFS_DIR}/init"

    # Create inittab
    log "Creating inittab..."
    cat <<EOF > "${INITRAMFS_DIR}/etc/inittab"
# /etc/inittab for ${OS_NAME}

# System initialization
::sysinit:/etc/init.d/rcS

# Start ROOT shells on consoles
tty1::respawn:/bin/sh
tty2::respawn:/bin/sh
tty3::respawn:/bin/sh

# Start a ROOT shell on the first serial port (for debugging)
ttyS0::respawn:/bin/sh

# What to do when restarting the init process
::restart:/sbin/init

# What to do on ctrl-alt-del
::ctrlaltdel:/sbin/reboot

# What to do when shutting down
::shutdown:/bin/umount -a -r
::shutdown:/sbin/swapoff -a
EOF

    # Create rcS script
    log "Creating rcS script..."
    cat <<EOF > "${INITRAMFS_DIR}/etc/init.d/rcS"
#!/bin/sh
# System startup script for ${OS_NAME}

export HOME=/root
export USER=root
export LOGNAME=root
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin

touch /tmp/rcS_started
echo "rcS script started" > /dev/console

exec > /dev/tty0 2>&1

mount -t tmpfs none /var || echo "Failed to mount /var"

chmod 666 /dev/null
chmod 666 /dev/zero
chmod 666 /dev/tty*
chmod 666 /dev/random
chmod 666 /dev/urandom
chmod -R a+r /proc 2>/dev/null || echo "Warning: Could not set permissions on /proc"
chmod -R a+r /sys 2>/dev/null || echo "Warning: Could not set permissions on /sys"

mkdir -p /var/log
dmesg > /var/log/dmesg.log

echo "root::0:0:root:/root:/bin/sh" > /etc/passwd
echo "root:x:0:" > /etc/group
chmod 644 /etc/passwd /etc/group

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
echo -e "\e[1mYou are running as: \e[32mROOT\e[0m"
echo ""

echo "${OS_NAME}" > /etc/hostname
hostname -F /etc/hostname

ip addr add 127.0.0.1/8 dev lo
ip link set lo up

echo -e "\e[1mHardware Information:\e[0m"
echo "===================="
cat /proc/cpuinfo | grep "model name" | head -1
free -m | awk 'NR==2{printf "Memory: %s/%s MB\n", \$3, \$2}'

# Check for NTFS-3G
if command -v ntfs-3g >/dev/null 2>&1; then
    echo -e "\e[1;32mNTFS-3G support: AVAILABLE\e[0m"
else
    echo -e "\e[1;31mNTFS-3G support: NOT AVAILABLE\e[0m"
fi

CUSTOM_CMDS=\$(ls -1 /usr/local/bin/ 2>/dev/null)
if [ -n "\$CUSTOM_CMDS" ]; then
    echo -e "\n\e[1;32mCustom commands available:\e[0m"
    for cmd in \$CUSTOM_CMDS; do
        echo -e "  \e[1;33m- \$cmd\e[0m"
    done
fi

echo ""
echo -e "\e[1;32mType 'poweroff' or 'reboot' to exit.\e[0m"
echo -e "\e[1;32mTo mount NTFS drives: mount -t ntfs-3g /dev/sdXN /mnt\e[0m"
echo ""

touch /tmp/rcS_completed
EOF
    chmod 755 "${INITRAMFS_DIR}/etc/init.d/rcS"

    echo "${OS_NAME}" > "${INITRAMFS_DIR}/etc/hostname"

    # Create network configuration
    log "Creating network configuration..."
    cat <<EOF > "${INITRAMFS_DIR}/etc/network/interfaces"
# Network interfaces for ${OS_NAME}

auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

    # Create /etc/issue
    cat <<EOF > "${INITRAMFS_DIR}/etc/issue"
${OS_NAME} - Running as ROOT
\r (\l) \d \t

Welcome! No login required - you are already ROOT.

EOF

    # Create /etc/profile
    cat <<EOF > "${INITRAMFS_DIR}/etc/profile"
export HOME=/root
export USER=root
export LOGNAME=root
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin
export PS1='\w # '
alias ll='ls -la'
alias mount-ntfs='mount -t ntfs-3g'
EOF
    
    log "initramfs content created."
}

install_custom_scripts() {
    log "Installing custom scripts..."
    
    mkdir -p "${CUSTOM_SCRIPTS_DIR}"
    
    if [ -d "${CUSTOM_SCRIPTS_DIR}" ]; then
        SCRIPT_COUNT=0
        for script in "${CUSTOM_SCRIPTS_DIR}"/*; do
            if [ -f "$script" ]; then
                SCRIPT_NAME=$(basename "$script")
                log "Installing custom script: $SCRIPT_NAME"
                cp "$script" "${INITRAMFS_DIR}/usr/local/bin/$SCRIPT_NAME"
                chmod +x "${INITRAMFS_DIR}/usr/local/bin/$SCRIPT_NAME"
                SCRIPT_COUNT=$((SCRIPT_COUNT + 1))
            fi
        done
        
        if [ "$SCRIPT_COUNT" -gt 0 ]; then
            log "Installed $SCRIPT_COUNT custom scripts."
        else
            warning "No custom scripts found in ${CUSTOM_SCRIPTS_DIR}"
            warning "You can add scripts to ${CUSTOM_SCRIPTS_DIR} and rebuild to include them."
            
            # Create default getdrives script with NTFS support
            log "Creating default getdrives.sh script..."
            cat <<'EOF' > "${CUSTOM_SCRIPTS_DIR}/getdrives.sh"
#!/bin/sh
#
# getdrives.sh - List all drives and partitions in a BusyBox environment
# For use with PrivilegeOS - Enhanced with NTFS-3G support

echo "==============================================="
echo "            STORAGE DEVICES LIST"
echo "==============================================="

echo "\033[1;32mPartition Table:\033[0m"
echo "MAJOR MINOR  #BLOCKS  NAME"
echo "-----------------------------"
cat /proc/partitions 2>/dev/null

echo "\n\033[1;32mBlock Devices in /dev:\033[0m"
echo "-----------------------------"
ls -la /dev/[hsv]d[a-z]* /dev/nvme*n* /dev/mmcblk* /dev/sr* 2>/dev/null || echo "No standard block devices found"

echo "\n\033[1;32mMounted Filesystems:\033[0m"
echo "-----------------------------"
mount | grep "^/dev/" || echo "No mounted filesystems"

echo "\n\033[1;32mDisk Usage:\033[0m"
echo "-----------------------------"
df -h | grep -v "^none" || echo "No disk usage information available"

echo "\n\033[1;32mFilesystem Detection:\033[0m"
echo "-----------------------------"
for dev in /dev/[hsv]d[a-z]*[0-9] /dev/nvme*n*p* /dev/mmcblk*p*; do
    if [ -b "$dev" ]; then
        fstype=$(blkid -s TYPE -o value "$dev" 2>/dev/null)
        if [ -n "$fstype" ]; then
            echo "$dev: $fstype"
        fi
    fi
done

if command -v ntfs-3g >/dev/null 2>&1; then
    echo "\n\033[1;32mNTFS-3G Commands:\033[0m"
    echo "-----------------------------"
    echo "Mount NTFS partition: mount -t ntfs-3g /dev/sdXN /mnt"
    echo "Mount NTFS read-only: mount -t ntfs-3g -o ro /dev/sdXN /mnt"
    echo "Check NTFS: ntfsfix /dev/sdXN"
    echo "Get NTFS info: ntfsinfo /dev/sdXN"
else
    echo "\n\033[1;31mNTFS-3G: NOT AVAILABLE\033[0m"
fi

echo "\n\033[1;32mTo examine a partition:\033[0m"
echo "  mount /dev/XXX /mnt"
echo "  cd /mnt"
echo "  ls -la"
EOF
            chmod +x "${CUSTOM_SCRIPTS_DIR}/getdrives.sh"
            cp "${CUSTOM_SCRIPTS_DIR}/getdrives.sh" "${INITRAMFS_DIR}/usr/local/bin/getdrives"
            chmod +x "${INITRAMFS_DIR}/usr/local/bin/getdrives"
            log "Created and installed default getdrives script."
            SCRIPT_COUNT=1
        fi
    else
        log "Creating scripts directory at ${CUSTOM_SCRIPTS_DIR}"
        mkdir -p "${CUSTOM_SCRIPTS_DIR}"
        warning "No custom scripts directory found. Created one at ${CUSTOM_SCRIPTS_DIR}"

        # Create default getdrives script with NTFS support
        log "Creating default getdrives.sh script..."
        cat <<'EOF' > "${CUSTOM_SCRIPTS_DIR}/getdrives.sh"
#!/bin/sh
#
# getdrives.sh - List all drives and partitions in a BusyBox environment
# For use with PrivilegeOS - Enhanced with NTFS-3G support

echo "==============================================="
echo "            STORAGE DEVICES LIST"
echo "==============================================="

echo "\033[1;32mPartition Table:\033[0m"
echo "MAJOR MINOR  #BLOCKS  NAME"
echo "-----------------------------"
cat /proc/partitions 2>/dev/null

echo "\n\033[1;32mBlock Devices in /dev:\033[0m"
echo "-----------------------------"
ls -la /dev/[hsv]d[a-z]* /dev/nvme*n* /dev/mmcblk* /dev/sr* 2>/dev/null || echo "No standard block devices found"

echo "\n\033[1;32mMounted Filesystems:\033[0m"
echo "-----------------------------"
mount | grep "^/dev/" || echo "No mounted filesystems"

echo "\n\033[1;32mDisk Usage:\033[0m"
echo "-----------------------------"
df -h | grep -v "^none" || echo "No disk usage information available"

echo "\n\033[1;32mFilesystem Detection:\033[0m"
echo "-----------------------------"
for dev in /dev/[hsv]d[a-z]*[0-9] /dev/nvme*n*p* /dev/mmcblk*p*; do
    if [ -b "$dev" ]; then
        fstype=$(blkid -s TYPE -o value "$dev" 2>/dev/null)
        if [ -n "$fstype" ]; then
            echo "$dev: $fstype"
        fi
    fi
done

if command -v ntfs-3g >/dev/null 2>&1; then
    echo "\n\033[1;32mNTFS-3G Commands:\033[0m"
    echo "-----------------------------"
    echo "Mount NTFS partition: mount -t ntfs-3g /dev/sdXN /mnt"
    echo "Mount NTFS read-only: mount -t ntfs-3g -o ro /dev/sdXN /mnt"
    echo "Check NTFS: ntfsfix /dev/sdXN"
    echo "Get NTFS info: ntfsinfo /dev/sdXN"
else
    echo "\n\033[1;31mNTFS-3G: NOT AVAILABLE\033[0m"
fi

echo "\n\033[1;32mTo examine a partition:\033[0m"
echo "  mount /dev/XXX /mnt"
echo "  cd /mnt"
echo "  ls -la"
EOF
        chmod +x "${CUSTOM_SCRIPTS_DIR}/getdrives.sh"
        cp "${CUSTOM_SCRIPTS_DIR}/getdrives.sh" "${INITRAMFS_DIR}/usr/local/bin/getdrives"
        chmod +x "${INITRAMFS_DIR}/usr/local/bin/getdrives"
        log "Created and installed default getdrives script."
    fi
    
    # Create symlinks for convenience
    ln -sf "${INITRAMFS_DIR}/usr/local/bin/getdrives" "${INITRAMFS_DIR}/usr/local/bin/lsblk" 2>/dev/null || true
    ln -sf "${INITRAMFS_DIR}/usr/local/bin/getdrives" "${INITRAMFS_DIR}/usr/local/bin/disks" 2>/dev/null || true
}

create_initramfs_archive() {
    log "Creating initramfs archive..."
    
    cd "${INITRAMFS_DIR}"
    
    # Create the cpio archive
    find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > "${INITRAMFS_FILE}"
    
    if [ ! -f "${INITRAMFS_FILE}" ]; then
        error "Failed to create initramfs archive"
    fi
    
    local size=$(du -h "${INITRAMFS_FILE}" | cut -f1)
    log "Created initramfs archive: ${INITRAMFS_FILE} (${size})"
    
    cd "$SCRIPT_DIR"
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
        
        ./scripts/config --enable CONFIG_EFI_STUB
        ./scripts/config --enable CONFIG_EFI
        ./scripts/config --enable CONFIG_EFI_VARS
        ./scripts/config --enable CONFIG_FB_EFI
        
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
        
        ./scripts/config --enable CONFIG_DRM
        ./scripts/config --enable CONFIG_DRM_I915
        ./scripts/config --enable CONFIG_DRM_AMDGPU
        ./scripts/config --enable CONFIG_DRM_NOUVEAU
        ./scripts/config --enable CONFIG_DRM_VIRTIO_GPU
        ./scripts/config --enable CONFIG_DRM_PANEL
        ./scripts/config --enable CONFIG_DRM_FBDEV_EMULATION
        ./scripts/config --enable CONFIG_BACKLIGHT_CLASS_DEVICE
        
        # Enhanced filesystem support including NTFS
        ./scripts/config --enable CONFIG_VFAT_FS
        ./scripts/config --enable CONFIG_MSDOS_FS
        ./scripts/config --enable CONFIG_FAT_DEFAULT_UTF8
        ./scripts/config --enable CONFIG_EXFAT_FS
        ./scripts/config --enable CONFIG_EXT4_FS
        ./scripts/config --enable CONFIG_EXT2_FS
        ./scripts/config --enable CONFIG_EXT3_FS
        ./scripts/config --enable CONFIG_XFS_FS
        ./scripts/config --enable CONFIG_BTRFS_FS
        
        # Disable kernel NTFS drivers to avoid conflicts with NTFS-3G
        ./scripts/config --disable CONFIG_NTFS_FS
        ./scripts/config --disable CONFIG_NTFS3_FS
        ./scripts/config --disable CONFIG_NTFS3_64BIT_CLUSTER
        ./scripts/config --disable CONFIG_NTFS3_LZX_XPRESS
        ./scripts/config --disable CONFIG_NTFS3_FS_POSIX_ACL
        
        # FUSE support for NTFS-3G
        ./scripts/config --enable CONFIG_FUSE_FS
        ./scripts/config --enable CONFIG_CUSE
        
        ./scripts/config --enable CONFIG_SND
        ./scripts/config --enable CONFIG_SND_HDA_INTEL
        ./scripts/config --enable CONFIG_SND_HDA_CODEC_REALTEK
        ./scripts/config --enable CONFIG_SND_HDA_CODEC_HDMI
        ./scripts/config --enable CONFIG_SND_USB_AUDIO
        
        ./scripts/config --enable CONFIG_ATA
        ./scripts/config --enable CONFIG_SATA_AHCI
        ./scripts/config --enable CONFIG_SCSI
        ./scripts/config --enable CONFIG_BLK_DEV_SD
        
        ./scripts/config --enable CONFIG_NVME_CORE
        ./scripts/config --enable CONFIG_NVME_PCI
        ./scripts/config --enable CONFIG_NVME_MULTIPATH
        ./scripts/config --enable CONFIG_NVME_FABRICS
        ./scripts/config --enable CONFIG_NVME_RDMA
        ./scripts/config --enable CONFIG_NVME_FC
        ./scripts/config --enable CONFIG_NVME_TARGET
        ./scripts/config --module CONFIG_BLK_DEV_NVME
        
        ./scripts/config --enable CONFIG_USB
        ./scripts/config --enable CONFIG_USB_XHCI_HCD
        ./scripts/config --enable CONFIG_USB_EHCI_HCD
        ./scripts/config --enable CONFIG_USB_OHCI_HCD
        ./scripts/config --enable CONFIG_USB_UHCI_HCD
        ./scripts/config --enable CONFIG_USB_STORAGE
        ./scripts/config --enable CONFIG_USB_HID
        
        ./scripts/config --enable CONFIG_INPUT
        ./scripts/config --enable CONFIG_INPUT_EVDEV
        ./scripts/config --enable CONFIG_INPUT_KEYBOARD
        ./scripts/config --enable CONFIG_INPUT_MOUSE
        ./scripts/config --enable CONFIG_INPUT_TOUCHSCREEN
        ./scripts/config --enable CONFIG_HID
        ./scripts/config --enable CONFIG_HID_GENERIC
        
        ./scripts/config --enable CONFIG_NET
        ./scripts/config --enable CONFIG_ETHERNET
        ./scripts/config --enable CONFIG_E1000
        ./scripts/config --enable CONFIG_E1000E
        ./scripts/config --enable CONFIG_R8169
        ./scripts/config --enable CONFIG_IWLWIFI
        ./scripts/config --enable CONFIG_ATH9K
        ./scripts/config --enable CONFIG_RTL8192CE
    
        ./scripts/config --enable CONFIG_ACPI
        ./scripts/config --enable CONFIG_ACPI_BATTERY
        ./scripts/config --enable CONFIG_ACPI_AC
        ./scripts/config --enable CONFIG_X86_INTEL_LPSS
        ./scripts/config --enable CONFIG_THINKPAD_ACPI
        ./scripts/config --enable CONFIG_DELL_LAPTOP
        
        # IMPORTANT: DO NOT embed initramfs in kernel
        ./scripts/config --disable CONFIG_INITRAMFS_SOURCE
        ./scripts/config --set-str CONFIG_INITRAMFS_SOURCE ""
        
        ./scripts/config --enable CONFIG_CMDLINE_BOOL
        ./scripts/config --set-str CONFIG_CMDLINE "console=tty0 console=ttyS0"
        
        ./scripts/config --enable CONFIG_DRM_KMS_HELPER
        
        # Save
        cp .config "${CONFIG_DIR}/kernel.config"
    fi

    # Ensure initramfs is not embedded in kernel
    ./scripts/config --disable CONFIG_INITRAMFS_SOURCE
    ./scripts/config --set-str CONFIG_INITRAMFS_SOURCE ""

    log "Updating kernel config..."
    make olddefconfig > "${LOG_DIR}/kernel_olddefconfig.log" 2>&1
    
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
    
    log "Creating raw disk image of ${IMAGE_SIZE}MB..."
    dd if=/dev/zero of="${DISK_IMG}" bs=1M count="${IMAGE_SIZE}" status=progress
    
    log "Partitioning disk image..."
    parted -s "${DISK_IMG}" mklabel gpt
    parted -s "${DISK_IMG}" mkpart ESP fat32 1MiB 100%
    parted -s "${DISK_IMG}" set 1 esp on
    parted -s "${DISK_IMG}" set 1 boot on
    
    log "Setting up loopback device..."
    LOOP_DEV=$(sudo losetup -f --show -P "${DISK_IMG}")
    if [ -z "$LOOP_DEV" ]; then
        error "Failed to set up loopback device."
    fi
    
    log "Formatting EFI partition..."
    sudo mkfs.vfat -F 32 "${LOOP_DEV}p1"
    
    log "Mounting EFI partition..."
    mkdir -p "${BUILD_DIR}/mnt"
    sudo mount "${LOOP_DEV}p1" "${BUILD_DIR}/mnt"
    
    log "Copying kernel and initramfs to EFI partition..."
    sudo mkdir -p "${BUILD_DIR}/mnt/EFI/BOOT"
    sudo cp "${KERNEL_SRC_DIR}/arch/x86/boot/bzImage" "${BUILD_DIR}/mnt/EFI/BOOT/vmlinuz"
    sudo cp "${INITRAMFS_FILE}" "${BUILD_DIR}/mnt/EFI/BOOT/initramfs.cpio.gz"
    
    log "Creating EFI boot executable..."
    cat > "${BUILD_DIR}/efi_boot.sh" << 'EOF'
#!/bin/bash
# Create EFI boot executable
cat > /tmp/boot_script.txt << 'EFIEOF'
@echo -off
echo Loading PrivilegeOS...
vmlinuz initrd=initramfs.cpio.gz console=tty0 console=ttyS0
EFIEOF

# Convert to proper EFI executable format
# This is a simplified approach - in production you'd use proper EFI tools
cp /tmp/boot_script.txt BOOTX64.EFI
EFIEOF
    
    # Create a simple boot script for EFI
    cat > "${BUILD_DIR}/mnt/EFI/BOOT/boot.nsh" << EOF
@echo -off
echo Loading ${OS_NAME}...
vmlinuz initrd=initramfs.cpio.gz console=tty0 console=ttyS0
EOF
    
    # Create a proper EFI boot entry (this is a simplified approach)
    # In a real implementation, you'd use efibootmgr or similar tools
    sudo cp "${KERNEL_SRC_DIR}/arch/x86/boot/bzImage" "${BUILD_DIR}/mnt/EFI/BOOT/BOOTX64.EFI"
    
    log "Creating UEFI startup script..."
    cat <<EOF | sudo tee "${BUILD_DIR}/mnt/startup.nsh" > /dev/null
@echo -off
echo Loading ${OS_NAME}...
fs0:
cd \EFI\BOOT
vmlinuz initrd=initramfs.cpio.gz console=tty0 console=ttyS0
EOF
    
    cat <<EOF | sudo tee "${BUILD_DIR}/mnt/README.txt" > /dev/null
${OS_NAME} - A minimal Linux distribution with NTFS-3G support
Built on: $(date)
Kernel version: ${KERNEL_VER}
BusyBox version: ${BUSYBOX_VER}
NTFS-3G version: ${NTFS3G_VER}

This is a bootable UEFI image with separate initramfs. To boot:
1. Make sure UEFI boot is enabled
2. Boot from this device
3. The system should automatically start as root

Files:
- vmlinuz: Linux kernel
- initramfs.cpio.gz: Initial RAM filesystem
- BOOTX64.EFI: UEFI boot executable

NTFS Support:
- Mount NTFS drives: mount -t ntfs-3g /dev/sdXN /mnt
- Check NTFS drives: ntfsfix /dev/sdXN
- Get NTFS info: ntfsinfo /dev/sdXN

For technical support or issues:
- Check logs in /var/log/
- Use the serial console for debugging
EOF
    
    log "Unmounting EFI partition..."
    sudo umount "${BUILD_DIR}/mnt"
    sudo losetup -d "${LOOP_DEV}"
    LOOP_DEV=""
    
    log "UEFI disk image created at ${DISK_IMG}"
}

update_initramfs_on_image() {
    log "Updating initramfs on existing disk image..."
    
    if [ ! -f "${DISK_IMG}" ]; then
        error "Disk image ${DISK_IMG} does not exist. Build the full image first."
    fi
    
    if [ ! -f "${INITRAMFS_FILE}" ]; then
        error "Initramfs file ${INITRAMFS_FILE} does not exist. Build initramfs first."
    fi
    
    log "Setting up loopback device..."
    LOOP_DEV=$(sudo losetup -f --show -P "${DISK_IMG}")
    if [ -z "$LOOP_DEV" ]; then
        error "Failed to set up loopback device."
    fi
    
    log "Mounting EFI partition..."
    mkdir -p "${BUILD_DIR}/mnt"
    sudo mount "${LOOP_DEV}p1" "${BUILD_DIR}/mnt"
    
    log "Updating initramfs..."
    sudo cp "${INITRAMFS_FILE}" "${BUILD_DIR}/mnt/EFI/BOOT/initramfs.cpio.gz"
    
    log "Unmounting EFI partition..."
    sudo umount "${BUILD_DIR}/mnt"
    sudo losetup -d "${LOOP_DEV}"
    LOOP_DEV=""
    
    log "Initramfs updated on disk image."
}

write_to_usb() {
    log "Preparing to write to USB drive..."
    
    echo "Available drives:"
    lsblk -d -o NAME,SIZE,MODEL,VENDOR,TYPE | grep -v loop | grep -v "$(df / | grep -o '^\S*' | sed 's/[0-9]*$//')"
    echo ""
    
    read -p "Enter the device name to write to (e.g., sdb, NOT sdb1): " USB_DEVICE
    if [[ -z "$USB_DEVICE" ]]; then
        error "No device specified."
    fi
    
    if [[ "$USB_DEVICE" == *"loop"* ]]; then
        error "Loop devices are not allowed."
    fi
    
    if [[ ! -b "/dev/${USB_DEVICE}" ]]; then
        error "Device /dev/${USB_DEVICE} does not exist or is not a block device."
    fi
    
    ROOT_DISK=$(df / | grep -o '^\S*' | sed 's/[0-9]*$//')
    if [[ "$ROOT_DISK" == "/dev/${USB_DEVICE}" ]]; then
        error "You're trying to write to the system's boot disk! Operation aborted."
    fi
    
    if grep -q "^/dev/${USB_DEVICE}" /proc/mounts; then
        warning "Device /dev/${USB_DEVICE} has mounted partitions. Attempting to unmount..."
        mounted_parts=$(grep "^/dev/${USB_DEVICE}" /proc/mounts | cut -d' ' -f1)
        for part in $mounted_parts; do
            sudo umount "$part" || error "Failed to unmount $part. Aborting."
        done
        log "Successfully unmounted all partitions on /dev/${USB_DEVICE}"
    fi
    
    DEVICE_SIZE=$(sudo blockdev --getsize64 "/dev/${USB_DEVICE}")
    IMAGE_SIZE_BYTES=$(stat -c%s "${DISK_IMG}")
    
    DEVICE_SIZE_HR=$(numfmt --to=iec-i --suffix=B ${DEVICE_SIZE})
    IMAGE_SIZE_HR=$(numfmt --to=iec-i --suffix=B ${IMAGE_SIZE_BYTES})
    
    if [[ ${DEVICE_SIZE} -lt ${IMAGE_SIZE_BYTES} ]]; then
        error "USB drive is too small (${DEVICE_SIZE_HR}) for the image (${IMAGE_SIZE_HR})."
    fi
    
    echo ""
    echo -e "${RED}${BOLD}WARNING: YOU ARE ABOUT TO OVERWRITE /dev/${USB_DEVICE}${NC}"
    echo -e "${RED}${BOLD}ALL DATA ON THIS DEVICE (${DEVICE_SIZE_HR}) WILL BE LOST!${NC}"
    echo -e "${YELLOW}Device: /dev/${USB_DEVICE}${NC}"
    echo -e "${YELLOW}Image file: ${DISK_IMG} (${IMAGE_SIZE_HR})${NC}"
    echo ""
    read -p "Type 'YES' to continue: " CONFIRM
    
    if [[ "$CONFIRM" != "YES" ]]; then
        error "Operation aborted."
    fi
    
    log "Writing image to /dev/${USB_DEVICE}..."
    sudo dd if="${DISK_IMG}" of="/dev/${USB_DEVICE}" bs=8M status=progress conv=fsync
    sudo sync
    
    log "Image successfully written to USB drive."
    echo ""
    echo -e "${GREEN}${BOLD}You can now boot your laptop from this USB drive.${NC}"
    echo -e "${GREEN}Use UEFI boot mode in your BIOS/firmware settings.${NC}"
}

run_qemu() {
    log "Testing in QEMU..."
    
    OVMF_PATH="/usr/share/ovmf/x64/OVMF.4m.fd"
    if [ ! -f "$OVMF_PATH" ]; then
        OVMF_PATH="/usr/share/ovmf/x64/OVMF.fd"
        if [ ! -f "$OVMF_PATH" ]; then
            error "OVMF firmware not found. Please install 'ovmf'."
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
    
    echo ""
    read -p "Did the system boot correctly in QEMU? (y/n): " QEMU_RESULT
    if [[ "$QEMU_RESULT" == "y" || "$QEMU_RESULT" == "Y" ]]; then
        log "QEMU test passed."
    else
        warning "QEMU test may have had issues."
    fi
}

main() {
    parse_arguments "$@"
    
    trap cleanup EXIT INT TERM

    CLEAN_BUILD=${CLEAN_BUILD:-0}
    QEMU_ONLY=${QEMU_ONLY:-0}
    SKIP_QEMU=${SKIP_QEMU:-0}
    SKIP_NTFS3G=${SKIP_NTFS3G:-0}
    SKIP_KERNEL=${SKIP_KERNEL:-0}
    INITRAMFS_ONLY=${INITRAMFS_ONLY:-0}
    UPDATE_INITRAMFS=${UPDATE_INITRAMFS:-0}
    
    echo ""
    echo -e "${BLUE}${BOLD}Building ${OS_NAME} with separate initramfs${NC}"
    echo -e "${BLUE}Kernel version: ${KERNEL_VER}${NC}"
    echo -e "${BLUE}BusyBox version: ${BUSYBOX_VER}${NC}"
    if [ "${SKIP_NTFS3G:-0}" -ne 1 ]; then
        echo -e "${BLUE}NTFS-3G version: ${NTFS3G_VER}${NC}"
    else
        echo -e "${YELLOW}NTFS-3G: SKIPPED${NC}"
    fi
    echo -e "${BLUE}Using ${THREADS} threads for compilation${NC}"
    echo -e "${BLUE}Disk image size: ${IMAGE_SIZE}MB${NC}"
    echo -e "${BLUE}Custom scripts directory: ${CUSTOM_SCRIPTS_DIR}${NC}"
    echo ""

    # Special modes for faster debugging
    if [ "${INITRAMFS_ONLY:-0}" -eq 1 ]; then
        log "Building initramfs only (fast debugging mode)..."
        setup_workspace
        if [ "${SKIP_NTFS3G:-0}" -ne 1 ]; then
            if [ ! -d "$NTFS3G_SRC_DIR" ]; then
                download_sources
            fi
            build_ntfs3g
        fi
        if [ ! -d "$BUSYBOX_SRC_DIR" ]; then
            download_sources
        fi
        build_busybox
        create_initramfs_content
        install_custom_scripts
        create_initramfs_archive
        log "Initramfs-only build complete. File: ${INITRAMFS_FILE}"
        return 0
    fi
    
    if [ "${UPDATE_INITRAMFS:-0}" -eq 1 ]; then
        log "Updating initramfs on existing image..."
        setup_workspace
        if [ "${SKIP_NTFS3G:-0}" -ne 1 ]; then
            if [ ! -d "$NTFS3G_SRC_DIR" ]; then
                download_sources
            fi
            build_ntfs3g
        fi
        if [ ! -d "$BUSYBOX_SRC_DIR" ]; then
            download_sources
        fi
        build_busybox
        create_initramfs_content
        install_custom_scripts
        create_initramfs_archive
        update_initramfs_on_image
        log "Initramfs update complete."
        return 0
    fi

    #check_dependencies

    setup_workspace
    download_sources
    build_busybox
    build_ntfs3g
    create_initramfs_content
    install_custom_scripts
    create_initramfs_archive
    
    if [ "${SKIP_KERNEL:-0}" -ne 1 ]; then
        build_kernel
    else
        log "Skipping kernel build as requested."
        if [ ! -f "${KERNEL_SRC_DIR}/arch/x86/boot/bzImage" ]; then
            error "No kernel found. Build kernel first or remove --skip-kernel option."
        fi
    fi
    
    create_uefi_disk_image
    
    if [ "${SKIP_QEMU:-0}" -ne 1 ]; then
        if [ "${QEMU_ONLY:-0}" -eq 1 ] || { read -p "Test in QEMU first? (y/n): " TEST_QEMU && [[ "$TEST_QEMU" == "y" || "$TEST_QEMU" == "Y" ]]; }; then
            run_qemu
        fi
    fi
    
    if [ "${QEMU_ONLY:-0}" -ne 1 ]; then
        read -p "Write to USB drive now? (y/n): " WRITE_USB
        if [[ "$WRITE_USB" == "y" || "$WRITE_USB" == "Y" ]]; then
            write_to_usb
        else
            log "Skipping USB write. Your disk image is at: ${DISK_IMG}"
        fi
    fi
    
    log "Done. Build complete."
    echo ""
    echo -e "${GREEN}${BOLD}Summary:${NC}"
    echo -e "${GREEN}- OS Name: ${OS_NAME}${NC}"
    echo -e "${GREEN}- Kernel: ${KERNEL_VER}${NC}"
    echo -e "${GREEN}- BusyBox: ${BUSYBOX_VER}${NC}"
    if [ "${SKIP_NTFS3G:-0}" -ne 1 ]; then
        echo -e "${GREEN}- NTFS-3G: ${NTFS3G_VER}${NC}"
    else
        echo -e "${YELLOW}- NTFS-3G: SKIPPED${NC}"
    fi
    echo -e "${GREEN}- Image: ${DISK_IMG} ($(du -h "${DISK_IMG}" | cut -f1))${NC}"
    echo -e "${GREEN}- Initramfs: ${INITRAMFS_FILE} ($(du -h "${INITRAMFS_FILE}" | cut -f1))${NC}"
    echo -e "${GREEN}- Logs: ${LOG_DIR}${NC}"
    
    SCRIPT_COUNT=$(find "${INITRAMFS_DIR}/usr/local/bin" -type f 2>/dev/null | wc -l)
    if [ "$SCRIPT_COUNT" -gt 0 ]; then
        echo -e "${GREEN}- Installed custom scripts: ${SCRIPT_COUNT}${NC}"
        echo -e "${GREEN}  $(ls -1 "${INITRAMFS_DIR}/usr/local/bin" 2>/dev/null | tr '\n' ' ')${NC}"
    else
        echo -e "${YELLOW}- No custom scripts installed${NC}"
        echo -e "${YELLOW}  Add scripts to ${CUSTOM_SCRIPTS_DIR} before building to include them${NC}"
    fi
    
    if [ "${SKIP_NTFS3G:-0}" -ne 1 ]; then
        echo ""
        echo -e "${GREEN}${BOLD}NTFS-3G Support Added:${NC}"
        echo -e "${GREEN}- Mount NTFS drives: mount -t ntfs-3g /dev/sdXN /mnt${NC}"
        echo -e "${GREEN}- Mount NTFS read-only: mount -t ntfs-3g -o ro /dev/sdXN /mnt${NC}"
        echo -e "${GREEN}- Check NTFS drives: ntfsfix /dev/sdXN${NC}"
        echo -e "${GREEN}- Get NTFS info: ntfsinfo /dev/sdXN${NC}"
        echo -e "${GREEN}- Alias: mount-ntfs command available${NC}"
    fi
    
    echo ""
    echo -e "${GREEN}${BOLD}Fast Debugging Commands:${NC}"
    echo -e "${GREEN}- Rebuild initramfs only: ./build.sh --initramfs-only${NC}"
    echo -e "${GREEN}- Update initramfs on image: ./build.sh --update-initramfs${NC}"
    echo -e "${GREEN}- Skip kernel build: ./build.sh --skip-kernel${NC}"
    echo ""
}

main "$@"
