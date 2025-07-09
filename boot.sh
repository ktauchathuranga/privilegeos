#!/bin/bash

# Script: boot.sh
# Description: Write PrivilegeOS disk image to USB drive for booting
# Version: 0.0.0 (Initial Release)
# Date: 2025-07-09

# Exit on errors
set -e

# --- Configuration ---
OS_NAME="PrivilegeOS"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BUILD_DIR="${SCRIPT_DIR}/build"
DISK_IMG="${BUILD_DIR}/${OS_NAME}.img"
LOG_DIR="${BUILD_DIR}/logs"

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
    if [ ! -f "${LOG_DIR}/boot.log" ]; then
        touch "${LOG_DIR}/boot.log"
    fi
    echo -e "\n${GREEN}${BOLD}[INFO ${timestamp}] ==> $1${NC}"
    echo "[INFO ${timestamp}] $1" >> "${LOG_DIR}/boot.log"
}

error() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "\n${RED}${BOLD}[ERROR ${timestamp}] ==> $1${NC}" >&2
    echo "[ERROR ${timestamp}] $1" >> "${LOG_DIR}/boot.log"
    exit 1
}

warning() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "\n${YELLOW}${BOLD}[WARNING ${timestamp}] ==> $1${NC}"
    echo "[WARNING ${timestamp}] $1" >> "${LOG_DIR}/boot.log"
}

info() {
    echo -e "${BLUE}$1${NC}"
}

show_help() {
    cat << EOF
Usage: $0 [options]

Options:
  -h, --help                Show this help message and exit
  -i, --image FILE          Specify disk image file (default: ${DISK_IMG})
  -n, --name NAME           Set OS name (default: ${OS_NAME})
  -y, --yes                 Skip confirmation prompts (use with caution)
  -d, --device DEVICE       Specify target device (e.g., sdb)
  -l, --list                List available block devices and exit

Examples:
  $0                        Interactive mode - will prompt for device
  $0 --list                 Show available devices
  $0 --device sdb           Write to /dev/sdb
  $0 --image custom.img --device sdb --yes
  $0 --name MyOS --device sdc

Note: This script writes a disk image to a USB drive for booting.
Make sure to select the correct device to avoid data loss!
EOF
    exit 0
}

list_devices() {
    echo -e "${BLUE}${BOLD}Available block devices:${NC}"
    echo ""
    lsblk -d -o NAME,SIZE,MODEL,VENDOR,TYPE | grep -v loop | grep -v "$(df / | grep -o '^\S*' | sed 's/[0-9]*$//')"
    echo ""
    echo -e "${YELLOW}Note: Do NOT select your system drive!${NC}"
    echo -e "${YELLOW}The system drive is typically: $(df / | grep -o '^\S*' | sed 's/[0-9]*$//')${NC}"
    exit 0
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                ;;
            -i|--image)
                DISK_IMG="$2"
                shift 2
                ;;
            -n|--name)
                OS_NAME="$2"
                shift 2
                ;;
            -y|--yes)
                SKIP_CONFIRM=1
                shift
                ;;
            -d|--device)
                USB_DEVICE="$2"
                shift 2
                ;;
            -l|--list)
                list_devices
                ;;
            *)
                error "Unknown option: $1"
                ;;
        esac
    done
}

check_dependencies() {
    log "Checking for required tools..."
    local deps=("lsblk" "dd" "blockdev" "stat" "numfmt" "sync")
    local missing_deps=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        error "Missing dependencies: ${missing_deps[*]}"
    fi
    
    log "All required tools are available."
}

check_image() {
    log "Checking disk image..."
    
    if [ ! -f "${DISK_IMG}" ]; then
        error "Disk image not found: ${DISK_IMG}"
    fi
    
    IMAGE_SIZE_BYTES=$(stat -c%s "${DISK_IMG}")
    IMAGE_SIZE_HR=$(numfmt --to=iec-i --suffix=B ${IMAGE_SIZE_BYTES})
    
    log "Found disk image: ${DISK_IMG} (${IMAGE_SIZE_HR})"
}

write_to_usb() {
    log "Preparing to write ${OS_NAME} to USB drive..."
    
    # If device not specified, show available devices and prompt
    if [ -z "${USB_DEVICE:-}" ]; then
        echo ""
        echo -e "${BLUE}${BOLD}Available drives:${NC}"
        lsblk -d -o NAME,SIZE,MODEL,VENDOR,TYPE | grep -v loop | grep -v "$(df / | grep -o '^\S*' | sed 's/[0-9]*$//')"
        echo ""
        
        read -p "Enter the device name to write to (e.g., sdb, NOT sdb1): " USB_DEVICE
    fi
    
    if [[ -z "$USB_DEVICE" ]]; then
        error "No device specified."
    fi
    
    # Remove /dev/ prefix if present
    USB_DEVICE=${USB_DEVICE#/dev/}
    
    # Validate device
    if [[ "$USB_DEVICE" == *"loop"* ]]; then
        error "Loop devices are not allowed."
    fi
    
    if [[ ! -b "/dev/${USB_DEVICE}" ]]; then
        error "Device /dev/${USB_DEVICE} does not exist or is not a block device."
    fi
    
    # Check if it's the system drive
    ROOT_DISK=$(df / | grep -o '^\S*' | sed 's/[0-9]*$//')
    if [[ "$ROOT_DISK" == "/dev/${USB_DEVICE}" ]]; then
        error "You're trying to write to the system's boot disk! Operation aborted."
    fi
    
    # Check if device has mounted partitions
    if grep -q "^/dev/${USB_DEVICE}" /proc/mounts; then
        warning "Device /dev/${USB_DEVICE} has mounted partitions. Attempting to unmount..."
        mounted_parts=$(grep "^/dev/${USB_DEVICE}" /proc/mounts | cut -d' ' -f1)
        for part in $mounted_parts; do
            sudo umount "$part" || error "Failed to unmount $part. Aborting."
        done
        log "Successfully unmounted all partitions on /dev/${USB_DEVICE}"
    fi
    
    # Check device size
    DEVICE_SIZE=$(sudo blockdev --getsize64 "/dev/${USB_DEVICE}")
    IMAGE_SIZE_BYTES=$(stat -c%s "${DISK_IMG}")
    
    DEVICE_SIZE_HR=$(numfmt --to=iec-i --suffix=B ${DEVICE_SIZE})
    IMAGE_SIZE_HR=$(numfmt --to=iec-i --suffix=B ${IMAGE_SIZE_BYTES})
    
    if [[ ${DEVICE_SIZE} -lt ${IMAGE_SIZE_BYTES} ]]; then
        error "USB drive is too small (${DEVICE_SIZE_HR}) for the image (${IMAGE_SIZE_HR})."
    fi
    
    # Confirmation (unless --yes flag is used)
    if [ "${SKIP_CONFIRM:-0}" -ne 1 ]; then
        echo ""
        echo -e "${RED}${BOLD}WARNING: YOU ARE ABOUT TO OVERWRITE /dev/${USB_DEVICE}${NC}"
        echo -e "${RED}${BOLD}ALL DATA ON THIS DEVICE (${DEVICE_SIZE_HR}) WILL BE LOST!${NC}"
        echo -e "${YELLOW}Device: /dev/${USB_DEVICE}${NC}"
        echo -e "${YELLOW}Image file: ${DISK_IMG} (${IMAGE_SIZE_HR})${NC}"
        echo -e "${YELLOW}OS: ${OS_NAME}${NC}"
        echo ""
        read -p "Type 'YES' to continue: " CONFIRM
        
        if [[ "$CONFIRM" != "YES" ]]; then
            error "Operation aborted."
        fi
    fi
    
    # Write image to USB
    log "Writing image to /dev/${USB_DEVICE}..."
    echo -e "${BLUE}This may take several minutes depending on image size and USB speed...${NC}"
    
    sudo dd if="${DISK_IMG}" of="/dev/${USB_DEVICE}" bs=8M status=progress conv=fsync
    sudo sync
    
    log "Image successfully written to USB drive."
    
    # Verify write (optional)
    log "Verifying write..."
    WRITTEN_SIZE=$(sudo blockdev --getsize64 "/dev/${USB_DEVICE}")
    if [[ ${WRITTEN_SIZE} -ge ${IMAGE_SIZE_BYTES} ]]; then
        log "Write verification successful."
    else
        warning "Write verification inconclusive. Please test the USB drive."
    fi
    
    echo ""
    echo -e "${GREEN}${BOLD}SUCCESS: ${OS_NAME} has been written to /dev/${USB_DEVICE}${NC}"
    echo -e "${GREEN}${BOLD}You can now boot your computer from this USB drive.${NC}"
    echo -e "${GREEN}Make sure to:${NC}"
    echo -e "${GREEN}1. Use UEFI boot mode in your BIOS/firmware settings${NC}"
    echo -e "${GREEN}2. Select the USB drive as the boot device${NC}"
    echo -e "${GREEN}3. The system will boot directly as root${NC}"
    echo ""
    echo -e "${BLUE}NTFS3 Support Available:${NC}"
    echo -e "${BLUE}- Mount NTFS drives: mount -t ntfs3 /dev/sdXN /mnt${NC}"
    echo -e "${BLUE}- Use 'getdrives' command to list available drives${NC}"
    echo ""
}

main() {
    parse_arguments "$@"
    
    echo ""
    echo -e "${BLUE}${BOLD}${OS_NAME} USB Writer${NC}"
    echo -e "${BLUE}Image: ${DISK_IMG}${NC}"
    echo ""
    
    check_dependencies
    check_image
    write_to_usb
    
    log "USB writing complete."
}

main "$@"
