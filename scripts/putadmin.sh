#!/bin/sh
#
# putadmin.sh - Windows Admin Access Restoration Script for PrivilegeOS
# This script finds Windows partitions and restores the original sticky keys functionality
# WARNING: This is for educational/penetration testing purposes only!
# Updated: 2025-07-06 11:45:55 UTC

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
USE_FORCE=0
CURRENT_MOUNTED_DEVICE=""

# Logging function
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Help function
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -f, --force         Use force option when mounting NTFS partitions"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                    # Normal restoration operation"
    echo "  $0 --force            # Use force mount option"
    echo ""
    echo "Note: This script restores Windows system files that were modified by getadmin:"
    echo "  - Restores original sethc.exe from backup"
    echo "  - Restores original cmd.exe from backup"
    echo "  - Removes temporary files created during bypass"
    echo "  - Returns Windows to normal login functionality"
    echo ""
}

# Parse command line arguments
while [ $# -gt 0 ]; do
    case $1 in
        -f|--force)
            USE_FORCE=1
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Banner
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}       Windows Admin Access Restoration    ${NC}"
echo -e "${CYAN}=============================================${NC}"
echo -e "${YELLOW}WARNING: This tool is for educational/penetration testing only!${NC}"
echo -e "${YELLOW}Use only on systems you own or have explicit permission to test.${NC}"
echo -e "${CYAN}=============================================${NC}"
if [ "$USE_FORCE" -eq 1 ]; then
    echo -e "${YELLOW}Force mount option: ENABLED${NC}"
else
    echo -e "${BLUE}Force mount option: DISABLED (use --force to enable)${NC}"
fi
echo -e "${BLUE}Updated: 2025-07-06 11:45:55 UTC${NC}"
echo -e "${BLUE}User: ktauchathuranga${NC}"
echo ""

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root!"
    exit 1
fi

# Check if NTFS3 is available
if ! grep -q ntfs3 /proc/filesystems; then
    error "NTFS3 filesystem support is not available in the kernel!"
    error "Please ensure the kernel was compiled with NTFS3 support."
    exit 1
fi

# Create mount point
MOUNT_POINT="/mnt/windows_restore"
mkdir -p "$MOUNT_POINT"

# Function to safely unmount
safe_unmount() {
    local device_to_unmount="$1"
    
    # If no device specified, use the current mounted device
    if [ -z "$device_to_unmount" ]; then
        device_to_unmount="$CURRENT_MOUNTED_DEVICE"
    fi
    
    # Check if we have a device to unmount
    if [ -n "$device_to_unmount" ]; then
        log "Unmounting device: $device_to_unmount"
        
        # Force sync before unmounting
        sync
        sleep 2
        
        # Try multiple unmount methods
        if umount "$device_to_unmount" 2>/dev/null; then
            success "Successfully unmounted $device_to_unmount"
        elif umount "$MOUNT_POINT" 2>/dev/null; then
            success "Successfully unmounted via mount point"
        elif umount -l "$device_to_unmount" 2>/dev/null; then
            success "Lazy unmount successful for $device_to_unmount"
        elif umount -f "$device_to_unmount" 2>/dev/null; then
            success "Force unmount successful for $device_to_unmount"
        else
            error "Could not unmount $device_to_unmount"
            warning "Trying alternative methods..."
            
            # Show what's mounted
            log "Current mounts:"
            grep "$MOUNT_POINT\|$device_to_unmount" /proc/mounts 2>/dev/null || true
            
            # Kill any processes using the mount point
            if command -v fuser >/dev/null 2>&1; then
                log "Killing processes using the mount point..."
                fuser -km "$MOUNT_POINT" 2>/dev/null || true
                sleep 1
                
                # Try unmount again
                if umount "$device_to_unmount" 2>/dev/null; then
                    success "Successfully unmounted after killing processes"
                else
                    error "Still could not unmount $device_to_unmount"
                    return 1
                fi
            else
                return 1
            fi
        fi
        
        # Additional sync after unmount
        sync
        sleep 1
        
        # Clear the current mounted device
        CURRENT_MOUNTED_DEVICE=""
    else
        info "No device to unmount"
    fi
    
    return 0
}

# Function to try mounting with different options
try_mount() {
    local partition="$1"
    local mode="$2"  # "ro" or "rw"
    
    # First ensure mount point is clean
    safe_unmount
    
    # Build mount options
    local mount_opts="$mode"
    if [ "$USE_FORCE" -eq 1 ]; then
        mount_opts="$mount_opts,force"
    fi
    
    # Try to mount
    log "Attempting to mount $partition with NTFS3 ($mount_opts)..."
    if mount -t ntfs3 -o "$mount_opts" "$partition" "$MOUNT_POINT" 2>/dev/null; then
        success "Successfully mounted $partition with options: $mount_opts"
        # Store the currently mounted device
        CURRENT_MOUNTED_DEVICE="$partition"
        return 0
    else
        # If normal mount fails, try with additional options
        if [ "$USE_FORCE" -eq 0 ]; then
            warning "Normal mount failed, trying with force option..."
            if mount -t ntfs3 -o "$mode,force" "$partition" "$MOUNT_POINT" 2>/dev/null; then
                success "Successfully mounted $partition with force option"
                # Store the currently mounted device
                CURRENT_MOUNTED_DEVICE="$partition"
                return 0
            fi
        fi
        error "Failed to mount $partition"
        return 1
    fi
}

# Function to check if partition has modified Windows files
check_modified_windows_partition() {
    local partition="$1"
    
    log "Checking partition: $partition"
    
    # Try to mount the partition with NTFS3
    if try_mount "$partition" "rw"; then
        # Check for Windows directory structure
        if [ -d "$MOUNT_POINT/Windows" ]; then
            log "Found Windows directory"
            if [ -d "$MOUNT_POINT/Windows/System32" ]; then
                log "Found System32 directory"
                
                # Check for backup files that indicate modification
                if [ -f "$MOUNT_POINT/Windows/System32/sethc.exe.backup" ]; then
                    success "Found Windows partition with backup files at $partition!"
                    success "- sethc.exe.backup: FOUND"
                    
                    # Show current file status
                    log "Current file status:"
                    ls -la "$MOUNT_POINT/Windows/System32/sethc.exe" 2>/dev/null
                    ls -la "$MOUNT_POINT/Windows/System32/cmd.exe" 2>/dev/null
                    ls -la "$MOUNT_POINT/Windows/System32/sethc.exe.backup" 2>/dev/null
                    
                    # Check if files were actually modified (compare sizes)
                    if [ -f "$MOUNT_POINT/Windows/System32/sethc.exe" ] && [ -f "$MOUNT_POINT/Windows/System32/cmd.exe" ]; then
                        SETHC_SIZE=$(stat -c%s "$MOUNT_POINT/Windows/System32/sethc.exe" 2>/dev/null)
                        CMD_SIZE=$(stat -c%s "$MOUNT_POINT/Windows/System32/cmd.exe" 2>/dev/null)
                        BACKUP_SIZE=$(stat -c%s "$MOUNT_POINT/Windows/System32/sethc.exe.backup" 2>/dev/null)
                        
                        log "File sizes:"
                        log "- sethc.exe: $SETHC_SIZE bytes"
                        log "- cmd.exe: $CMD_SIZE bytes"
                        log "- sethc.exe.backup: $BACKUP_SIZE bytes"
                        
                        if [ "$SETHC_SIZE" -eq "$CMD_SIZE" ] && [ "$SETHC_SIZE" -ne "$BACKUP_SIZE" ]; then
                            warning "Files appear to be modified (sethc.exe has same size as cmd.exe)"
                            warning "This indicates the bypass is currently active"
                            return 0
                        elif [ "$SETHC_SIZE" -eq "$BACKUP_SIZE" ]; then
                            info "Files appear to already be restored (sethc.exe matches backup)"
                            info "System may already be in normal state"
                            return 0
                        else
                            warning "File sizes don't match expected pattern, but backup exists"
                            warning "Will proceed with restoration anyway"
                            return 0
                        fi
                    else
                        warning "sethc.exe or cmd.exe missing, but backup exists"
                        return 0
                    fi
                else
                    info "Windows partition found but no backup files detected"
                    info "This partition may not have been modified by getadmin"
                fi
            else
                info "Windows directory found but no System32 directory"
            fi
        else
            info "Partition mounted but no Windows directory found"
        fi
        
        safe_unmount "$partition"
        return 1
    else
        info "Failed to mount $partition with NTFS3"
        return 1
    fi
}

# Function to perform the restoration
perform_restoration() {
    local partition="$1"
    
    echo ""
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}      Performing Windows File Restoration  ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    # Check if partition is already mounted from the detection phase
    if [ "$CURRENT_MOUNTED_DEVICE" = "$partition" ] && grep -q "$MOUNT_POINT" /proc/mounts; then
        log "Partition is already mounted from detection phase"
        
        # Check if it's mounted read-only and remount as read-write if needed
        MOUNT_OPTIONS=$(grep "$MOUNT_POINT" /proc/mounts | awk '{print $4}')
        if echo "$MOUNT_OPTIONS" | grep -q "ro"; then
            log "Partition is mounted read-only, remounting as read-write..."
            safe_unmount "$partition"
            if ! try_mount "$partition" "rw"; then
                error "Failed to remount $partition as read-write!"
                return 1
            fi
        else
            log "Partition is already mounted read-write"
        fi
    else
        # Mount as read-write
        log "Mounting $partition as read-write..."
        if ! try_mount "$partition" "rw"; then
            error "Failed to mount $partition as read-write!"
            if [ "$USE_FORCE" -eq 0 ]; then
                error "Try running with --force option"
            fi
            return 1
        fi
    fi
    
    # Navigate to System32
    SYSTEM32_PATH="$MOUNT_POINT/Windows/System32"
    cd "$SYSTEM32_PATH" || {
        error "Could not navigate to System32 directory!"
        safe_unmount "$partition"
        return 1
    }
    
    log "Current directory: $(pwd)"
    
    # Show current file status
    log "Current file status before restoration:"
    ls -la sethc.exe cmd.exe sethc.exe.backup 2>/dev/null || {
        error "Could not list files!"
        safe_unmount "$partition"
        return 1
    }
    
    # Check for backup file
    if [ ! -f "sethc.exe.backup" ]; then
        error "sethc.exe.backup not found!"
        error "Cannot restore without backup file. System may not have been modified by getadmin."
        safe_unmount "$partition"
        return 1
    fi
    
    # Get file sizes for verification
    if [ -f "sethc.exe" ]; then
        CURRENT_SETHC_SIZE=$(stat -c%s "sethc.exe" 2>/dev/null)
    else
        CURRENT_SETHC_SIZE=0
    fi
    
    if [ -f "cmd.exe" ]; then
        CURRENT_CMD_SIZE=$(stat -c%s "cmd.exe" 2>/dev/null)
    else
        CURRENT_CMD_SIZE=0
    fi
    
    BACKUP_SIZE=$(stat -c%s "sethc.exe.backup" 2>/dev/null)
    
    log "Current file sizes:"
    log "- sethc.exe: $CURRENT_SETHC_SIZE bytes"
    log "- cmd.exe: $CURRENT_CMD_SIZE bytes"
    log "- sethc.exe.backup: $BACKUP_SIZE bytes"
    
    # Check if restoration is needed
    if [ "$CURRENT_SETHC_SIZE" -eq "$BACKUP_SIZE" ] && [ -f "sethc.exe" ]; then
        warning "sethc.exe already matches backup size"
        warning "System may already be restored, but will proceed anyway"
    fi
    
    # Force sync before operations
    sync
    sleep 2
    
    # Perform the restoration with extensive verification
    log "Performing file restoration with verification..."
    
    # Step 1: Remove current sethc.exe if it exists
    if [ -f "sethc.exe" ]; then
        log "Step 1: Removing current sethc.exe..."
        if rm "sethc.exe"; then
            success "Current sethc.exe removed"
            # Verify removal
            if [ ! -f "sethc.exe" ]; then
                success "Verification: sethc.exe no longer exists"
            else
                error "Verification failed: sethc.exe still exists!"
                safe_unmount "$partition"
                return 1
            fi
            sync
            sleep 1
        else
            error "Failed to remove current sethc.exe!"
            safe_unmount "$partition"
            return 1
        fi
    else
        warning "sethc.exe not found, will create it from backup"
    fi
    
    # Step 2: Restore sethc.exe from backup
    log "Step 2: Restoring sethc.exe from backup..."
    if cp "sethc.exe.backup" "sethc.exe"; then
        success "sethc.exe restored from backup"
        # Verify restoration
        if [ -f "sethc.exe" ]; then
            success "Verification: sethc.exe exists"
            NEW_SETHC_SIZE=$(stat -c%s "sethc.exe" 2>/dev/null)
            if [ "$NEW_SETHC_SIZE" -eq "$BACKUP_SIZE" ]; then
                success "Verification: sethc.exe size matches backup ($NEW_SETHC_SIZE bytes)"
            else
                error "Verification failed: sethc.exe size mismatch!"
                error "Expected: $BACKUP_SIZE bytes, Got: $NEW_SETHC_SIZE bytes"
                safe_unmount "$partition"
                return 1
            fi
        else
            error "Verification failed: sethc.exe missing after restoration!"
            safe_unmount "$partition"
            return 1
        fi
        sync
        sleep 1
    else
        error "Failed to restore sethc.exe from backup!"
        safe_unmount "$partition"
        return 1
    fi
    
    # Step 3: Check and fix cmd.exe if needed
    log "Step 3: Checking cmd.exe..."
    if [ -f "cmd.exe" ]; then
        CMD_SIZE_AFTER=$(stat -c%s "cmd.exe" 2>/dev/null)
        if [ "$CMD_SIZE_AFTER" -eq "$BACKUP_SIZE" ]; then
            warning "cmd.exe has same size as original sethc.exe"
            warning "This suggests cmd.exe was replaced during bypass"
            
            # Look for cmd.exe backup or try to restore from system
            if [ -f "cmd.exe.backup" ]; then
                log "Found cmd.exe.backup, restoring..."
                if cp "cmd.exe.backup" "cmd.exe"; then
                    success "cmd.exe restored from backup"
                    sync
                    sleep 1
                else
                    warning "Failed to restore cmd.exe from backup"
                fi
            else
                warning "No cmd.exe.backup found"
                warning "cmd.exe may still be the original sethc.exe"
                warning "Windows should still function normally"
            fi
        else
            success "cmd.exe appears to be normal (different size from sethc backup)"
        fi
    else
        error "cmd.exe is missing!"
        error "This is a serious problem - Windows will not function properly"
        safe_unmount "$partition"
        return 1
    fi
    
    # Step 4: Set proper permissions
    log "Step 4: Setting proper file permissions..."
    chmod 755 "sethc.exe" 2>/dev/null || warning "Could not change sethc.exe permissions"
    chmod 755 "cmd.exe" 2>/dev/null || warning "Could not change cmd.exe permissions"
    
    # Step 5: Clean up temporary files that may have been left behind
    log "Step 5: Cleaning up temporary files..."
    CLEANED_FILES=0
    
    for temp_file in "cmd_temp.exe" "sethc_temp.exe" "temp_cmd.exe" "temp_sethc.exe"; do
        if [ -f "$temp_file" ]; then
            if rm "$temp_file" 2>/dev/null; then
                success "Cleaned up: $temp_file"
                CLEANED_FILES=$((CLEANED_FILES + 1))
            else
                warning "Could not clean up: $temp_file"
            fi
        fi
    done
    
    if [ "$CLEANED_FILES" -eq 0 ]; then
        info "No temporary files found to clean up"
    else
        success "Cleaned up $CLEANED_FILES temporary files"
    fi
    
    # Force extensive sync
    log "Forcing filesystem sync..."
    sync
    sleep 2
    sync
    sleep 2
    
    # Final verification
    log "Performing final verification..."
    log "Final file listing:"
    ls -la sethc.exe cmd.exe sethc.exe.backup 2>/dev/null
    
    # Check final file sizes
    FINAL_SETHC_SIZE=$(stat -c%s "sethc.exe" 2>/dev/null)
    FINAL_CMD_SIZE=$(stat -c%s "cmd.exe" 2>/dev/null)
    
    log "Final file sizes:"
    log "- sethc.exe: $FINAL_SETHC_SIZE bytes"
    log "- cmd.exe: $FINAL_CMD_SIZE bytes"
    log "- sethc.exe.backup: $BACKUP_SIZE bytes"
    
    # Verify restoration was successful
    if [ "$FINAL_SETHC_SIZE" -eq "$BACKUP_SIZE" ]; then
        success "Restoration verification: sethc.exe matches backup - SUCCESS!"
    else
        error "Restoration verification: sethc.exe size mismatch - FAILED!"
        warning "Expected: $BACKUP_SIZE bytes, Got: $FINAL_SETHC_SIZE bytes"
        safe_unmount "$partition"
        return 1
    fi
    
    # Final sync before unmounting
    log "Final sync before unmounting..."
    sync
    sleep 3
    sync
    
    success "Windows file restoration completed!"
    echo ""
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}         RESTORATION COMPLETED!             ${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo ""
    echo -e "${YELLOW}Windows has been restored to normal functionality:${NC}"
    echo -e "${YELLOW}1. Sticky Keys will now work normally (5x Shift)${NC}"
    echo -e "${YELLOW}2. No more command prompt bypass at login${NC}"
    echo -e "${YELLOW}3. Original sethc.exe functionality restored${NC}"
    echo -e "${YELLOW}4. System should boot and function normally${NC}"
    echo ""
    echo -e "${CYAN}What was restored:${NC}"
    echo -e "${CYAN}- sethc.exe: Restored from backup${NC}"
    echo -e "${CYAN}- File permissions: Reset to normal${NC}"
    echo -e "${CYAN}- Temporary files: Cleaned up${NC}"
    echo ""
    echo -e "${GREEN}The backup file (sethc.exe.backup) has been kept for reference.${NC}"
    echo -e "${GREEN}You can safely delete it if you no longer need it.${NC}"
    echo ""
    
    # Final unmount - go back to root directory first
    log "Unmounting Windows partition..."
    cd / || true
    safe_unmount "$partition"
    return 0
}

# Main execution starts here...
log "Starting Windows restoration scan..."

# Get all partitions from /proc/partitions
PARTITIONS=""
log "Reading partition information from /proc/partitions..."

# Parse /proc/partitions to get device names
while IFS= read -r line; do
    # Skip header and empty lines
    echo "$line" | grep -q "major\|^$" && continue
    
    # Extract device name (4th column)
    device=$(echo "$line" | awk '{print $4}')
    
    # Skip if device name is empty
    [ -z "$device" ] && continue
    
    # Only include partitions (those with numbers at the end)
    if echo "$device" | grep -q '[0-9]$'; then
        PARTITIONS="$PARTITIONS /dev/$device"
    fi
done < /proc/partitions

if [ -z "$PARTITIONS" ]; then
    error "No partitions found!"
    echo ""
    echo "Raw /proc/partitions content:"
    cat /proc/partitions
    exit 1
fi

log "Found partitions to check:"
for partition in $PARTITIONS; do
    if [ -b "$partition" ]; then
        echo "  - $partition ✓"
    else
        echo "  - $partition ✗ (not found)"
    fi
done

echo ""
WINDOWS_PARTITION=""
PARTITION_COUNT=0

# Check each partition
for partition in $PARTITIONS; do
    PARTITION_COUNT=$((PARTITION_COUNT + 1))
    
    # Skip if device doesn't exist
    if [ ! -b "$partition" ]; then
        warning "Skipping $partition (device not found)"
        continue
    fi
    
    echo -e "${CYAN}=== Checking partition $PARTITION_COUNT: $partition ===${NC}"
    
    if check_modified_windows_partition "$partition"; then
        WINDOWS_PARTITION="$partition"
        success "Modified Windows partition found: $partition"
        break
    else
        info "Not a modified Windows partition: $partition"
    fi
    echo ""
done

# If no Windows partition found, clean up mount point
if [ -z "$WINDOWS_PARTITION" ]; then
    safe_unmount
fi

if [ -z "$WINDOWS_PARTITION" ]; then
    error "No modified Windows partition found!"
    echo ""
    echo "Checked partitions:"
    for partition in $PARTITIONS; do
        if [ -b "$partition" ]; then
            echo "  - $partition (checked, no modifications detected)"
        else
            echo "  - $partition (skipped, device not found)"
        fi
    done
    echo ""
    echo -e "${YELLOW}Possible reasons:${NC}"
    echo -e "${YELLOW}1. No Windows partitions were modified by getadmin${NC}"
    echo -e "${YELLOW}2. Backup files were manually removed${NC}"
    echo -e "${YELLOW}3. System was already restored${NC}"
    echo -e "${YELLOW}4. Windows partitions are encrypted (BitLocker)${NC}"
    echo -e "${YELLOW}5. Try running with --force option: putadmin --force${NC}"
    exit 1
fi

# Ask for confirmation
echo ""
echo -e "${YELLOW}=============================================${NC}"
echo -e "${YELLOW}          CONFIRMATION REQUIRED             ${NC}"
echo -e "${YELLOW}=============================================${NC}"
echo ""
echo -e "${BLUE}This will restore Windows system files to normal functionality!${NC}"
echo -e "${BLUE}Target Windows partition: $WINDOWS_PARTITION${NC}"
if [ "$USE_FORCE" -eq 1 ]; then
    echo -e "${YELLOW}Mount options: rw,force${NC}"
else
    echo -e "${BLUE}Mount options: rw${NC}"
fi
echo ""
echo -e "${GREEN}What will be restored:${NC}"
echo -e "${GREEN}- sethc.exe will be restored from backup${NC}"
echo -e "${GREEN}- Normal sticky keys functionality will return${NC}"
echo -e "${GREEN}- Command prompt bypass will be removed${NC}"
echo -e "${GREEN}- Temporary files will be cleaned up${NC}"
echo ""
echo -e "${YELLOW}Continue with restoration? (Type 'YES' to proceed): ${NC}"
read -r CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    warning "Restoration cancelled by user"
    safe_unmount
    exit 0
fi

# Perform the restoration
if perform_restoration "$WINDOWS_PARTITION"; then
    success "Windows restoration operation completed!"
    echo ""
    echo -e "${GREEN}Windows has been restored to normal functionality.${NC}"
    echo -e "${GREEN}You can now boot Windows normally.${NC}"
else
    error "Failed to perform restoration!"
    exit 1
fi

# Cleanup
rmdir "$MOUNT_POINT" 2>/dev/null || true

echo ""
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}              SCRIPT COMPLETED              ${NC}"
echo -e "${CYAN}=============================================${NC}"
