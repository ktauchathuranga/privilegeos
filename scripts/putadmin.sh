#!/bin/sh
#
# putadmin.sh - Windows Admin Access Restoration Script for PrivilegeOS
# This script finds Windows partitions and restores the original sticky keys functionality
# WARNING: This is for educational/penetration testing purposes only!
# Updated: 2025-07-10 04:01:30 UTC

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
USE_FORCE=0
DELETE_HIBERFIL=0
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
    echo "  -d, --delete-hiberfil Delete hiberfil.sys if found (helps with hibernated Windows)"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                    # Normal restoration operation"
    echo "  $0 --force            # Use force mount option"
    echo "  $0 --delete-hiberfil  # Delete hibernation file if found"
    echo "  $0 -f -d              # Use both force mount and delete hiberfil"
    echo ""
    echo "Note: This script restores Windows system files that were modified by getadmin:"
    echo "  - Restores original sethc.exe from backup"
    echo "  - Verifies cmd.exe is in correct state"
    echo "  - Removes temporary files created during bypass"
    echo "  - Returns Windows to normal login functionality"
    echo ""
    echo "Note: Deleting hiberfil.sys will:"
    echo "  - Allow proper NTFS mounting of hibernated Windows systems"
    echo "  - Prevent Windows from resuming from hibernation (cold boot instead)"
    echo "  - Free up disk space (hiberfil.sys can be several GB)"
    echo ""
}

# Parse command line arguments
while [ $# -gt 0 ]; do
    case $1 in
        -f|--force)
            USE_FORCE=1
            shift
            ;;
        -d|--delete-hiberfil)
            DELETE_HIBERFIL=1
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
if [ "$DELETE_HIBERFIL" -eq 1 ]; then
    echo -e "${YELLOW}Delete hiberfil.sys: ENABLED${NC}"
else
    echo -e "${BLUE}Delete hiberfil.sys: DISABLED (use --delete-hiberfil to enable)${NC}"
fi
echo -e "${BLUE}Updated: 2025-07-10 04:01:30 UTC${NC}"
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

# Function to handle hibernation file
handle_hibernation_file() {
    local partition="$1"
    
    # Check if hibernation file exists
    if [ -f "$MOUNT_POINT/hiberfil.sys" ]; then
        HIBERFIL_SIZE=$(stat -c%s "$MOUNT_POINT/hiberfil.sys" 2>/dev/null)
        HIBERFIL_SIZE_MB=$((HIBERFIL_SIZE / 1024 / 1024))
        
        warning "Hibernation file detected:"
        warning "- File: $MOUNT_POINT/hiberfil.sys"
        warning "- Size: $HIBERFIL_SIZE_MB MB"
        warning "- This indicates Windows was hibernated, not shut down"
        
        if [ "$DELETE_HIBERFIL" -eq 1 ]; then
            echo ""
            echo -e "${YELLOW}Preparing to delete hiberfil.sys...${NC}"
            echo -e "${RED}WARNING: This will prevent Windows from resuming hibernation!${NC}"
            echo -e "${RED}Windows will perform a cold boot instead of resuming.${NC}"
            echo -e "${YELLOW}This is generally safe but any unsaved work will be lost.${NC}"
            echo ""
            echo -e "${YELLOW}Delete hiberfil.sys ($HIBERFIL_SIZE_MB MB)? (Type 'YES' to confirm): ${NC}"
            read -r CONFIRM_DELETE
            
            if [ "$CONFIRM_DELETE" = "YES" ]; then
                log "Deleting hiberfil.sys..."
                
                # Show before deletion
                log "Before deletion:"
                ls -la "$MOUNT_POINT/hiberfil.sys" 2>/dev/null
                
                # Try multiple deletion methods
                DELETED=0
                
                # Method 1: Simple rm
                if rm "$MOUNT_POINT/hiberfil.sys" 2>/dev/null; then
                    DELETED=1
                    success "hiberfil.sys deleted with rm command"
                elif rm -f "$MOUNT_POINT/hiberfil.sys" 2>/dev/null; then
                    DELETED=1
                    success "hiberfil.sys deleted with rm -f command"
                elif rm -rf "$MOUNT_POINT/hiberfil.sys" 2>/dev/null; then
                    DELETED=1
                    success "hiberfil.sys deleted with rm -rf command"
                else
                    error "Failed to delete hiberfil.sys with rm commands"
                    
                    # Method 2: Try with different attributes
                    log "Trying to remove file attributes..."
                    if command -v chattr >/dev/null 2>&1; then
                        chattr -i "$MOUNT_POINT/hiberfil.sys" 2>/dev/null || true
                        chattr -a "$MOUNT_POINT/hiberfil.sys" 2>/dev/null || true
                        if rm -f "$MOUNT_POINT/hiberfil.sys" 2>/dev/null; then
                            DELETED=1
                            success "hiberfil.sys deleted after removing attributes"
                        fi
                    fi
                fi
                
                if [ $DELETED -eq 1 ]; then
                    # Verify deletion
                    log "Verifying deletion..."
                    if [ ! -f "$MOUNT_POINT/hiberfil.sys" ]; then
                        success "Verification: hiberfil.sys is no longer present"
                        success "Freed up $HIBERFIL_SIZE_MB MB of disk space"
                    else
                        error "Verification failed: hiberfil.sys still exists!"
                        log "File still exists after deletion attempt:"
                        ls -la "$MOUNT_POINT/hiberfil.sys" 2>/dev/null
                        return 1
                    fi
                    
                    # Force sync after deletion
                    sync
                    sleep 3
                    sync
                    
                    success "Hibernation file successfully removed - continuing with restoration..."
                    return 0
                else
                    error "Failed to delete hiberfil.sys with all methods"
                    warning "You may need to:"
                    warning "1. Boot Windows normally and disable hibernation"
                    warning "2. Use a different tool to delete the file"
                    warning "3. Try mounting with different options"
                    return 1
                fi
            else
                warning "Skipping hiberfil.sys deletion"
                info "You can use --delete-hiberfil option to delete it automatically"
                return 1
            fi
        else
            echo ""
            echo -e "${YELLOW}Recommended actions:${NC}"
            echo -e "${YELLOW}1. Use --delete-hiberfil option to delete the hibernation file${NC}"
            echo -e "${YELLOW}2. Or use --force option to force mount the hibernated filesystem${NC}"
            echo -e "${YELLOW}3. Or boot Windows normally first, then shut down properly${NC}"
            echo -e "${YELLOW}4. Or manually delete: rm -rf $MOUNT_POINT/hiberfil.sys${NC}"
            echo ""
            return 1
        fi
    else
        info "No hibernation file found - Windows was shut down properly"
        return 0
    fi
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
        # Check for hibernation file first
        handle_hibernation_file "$partition"
        HIBERNATION_EXIT_CODE=$?
        
        # If hibernation file handling failed but we want to continue anyway
        if [ $HIBERNATION_EXIT_CODE -ne 0 ]; then
            if [ "$USE_FORCE" -eq 1 ]; then
                warning "Hibernation file handling failed, but continuing with --force option"
            else
                info "Hibernation file handling failed - this partition may not be accessible"
                safe_unmount "$partition"
                return 1
            fi
        fi
        
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
                    ls -la "$MOUNT_POINT/Windows/System32/cmd.exe.backup" 2>/dev/null
                    
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
                            info "System may already be in normal state, but will verify"
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
    
    # Check for hibernation file again in read-write mode
    if [ -f "$MOUNT_POINT/hiberfil.sys" ] && [ "$DELETE_HIBERFIL" -eq 0 ]; then
        warning "Hibernation file still present. This may cause issues."
        warning "Consider using --delete-hiberfil option"
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
    ls -la sethc.exe cmd.exe sethc.exe.backup cmd.exe.backup 2>/dev/null || {
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
    
    # Check for cmd.exe backup
    if [ -f "cmd.exe.backup" ]; then
        CMD_BACKUP_SIZE=$(stat -c%s "cmd.exe.backup" 2>/dev/null)
        log "cmd.exe.backup found with size: $CMD_BACKUP_SIZE bytes"
    else
        CMD_BACKUP_SIZE=0
        info "No cmd.exe.backup found (this is normal with the corrected getadmin)"
    fi
    
    log "Current file sizes:"
    log "- sethc.exe: $CURRENT_SETHC_SIZE bytes"
    log "- cmd.exe: $CURRENT_CMD_SIZE bytes"
    log "- sethc.exe.backup: $BACKUP_SIZE bytes"
    if [ "$CMD_BACKUP_SIZE" -gt 0 ]; then
        log "- cmd.exe.backup: $CMD_BACKUP_SIZE bytes"
    fi
    
    # Check if restoration is needed
    if [ "$CURRENT_SETHC_SIZE" -eq "$BACKUP_SIZE" ] && [ -f "sethc.exe" ]; then
        success "sethc.exe already matches backup size"
        success "System appears to already be restored!"
        
        # Verify cmd.exe is in expected state
        if [ "$CMD_BACKUP_SIZE" -gt 0 ]; then
            if [ "$CURRENT_CMD_SIZE" -eq "$CMD_BACKUP_SIZE" ]; then
                success "cmd.exe also matches its backup - complete restoration verified"
            else
                warning "cmd.exe size doesn't match backup, but may be normal"
            fi
        else
            success "cmd.exe appears to be in normal state (no backup needed)"
        fi
        
        log "Proceeding with verification and cleanup anyway..."
    elif [ "$CURRENT_SETHC_SIZE" -eq "$CURRENT_CMD_SIZE" ] && [ "$CURRENT_SETHC_SIZE" -ne "$BACKUP_SIZE" ]; then
        warning "sethc.exe appears to be replaced with cmd.exe (bypass active)"
        warning "Proceeding with restoration..."
    else
        info "File sizes indicate mixed state, proceeding with restoration..."
    fi
    
    # Force sync before operations
    sync
    sleep 2
    
    # Step 1: Remove current sethc.exe if it exists and differs from backup
    if [ -f "sethc.exe" ]; then
        log "Step 1: Removing current sethc.exe..."
        
        # Verify the file exists before removal
        if [ ! -f "sethc.exe" ]; then
            error "sethc.exe disappeared before removal!"
            safe_unmount "$partition"
            return 1
        fi
        
        if rm "sethc.exe"; then
            # Force sync to ensure deletion is committed
            sync
            sleep 1
            
            # Verify removal was successful
            if [ ! -f "sethc.exe" ]; then
                success "Current sethc.exe removed successfully"
                success "Verification: sethc.exe no longer exists"
            else
                error "Verification failed: sethc.exe still exists after removal!"
                log "File still present:"
                ls -la "sethc.exe" 2>/dev/null
                safe_unmount "$partition"
                return 1
            fi
        else
            error "Failed to remove current sethc.exe!"
            log "File permissions:"
            ls -la "sethc.exe" 2>/dev/null
            safe_unmount "$partition"
            return 1
        fi
    else
        warning "sethc.exe not found, will create it from backup"
    fi
    
    # Step 2: Restore sethc.exe from backup with comprehensive verification
    log "Step 2: Restoring sethc.exe from backup..."
    
    # Verify backup exists and is valid
    if [ ! -f "sethc.exe.backup" ]; then
        error "Backup file not found during restoration!"
        safe_unmount "$partition"
        return 1
    fi
    
    BACKUP_SIZE=$(stat -c%s "sethc.exe.backup" 2>/dev/null)
    if [ "$BACKUP_SIZE" -eq 0 ]; then
        error "Backup file is empty (0 bytes)!"
        safe_unmount "$partition"
        return 1
    fi
    
    log "Backup file size: $BACKUP_SIZE bytes"
    
    if cp "sethc.exe.backup" "sethc.exe"; then
        # Force sync to ensure copy is committed
        sync
        sleep 1
        
        # Comprehensive verification
        if [ -f "sethc.exe" ]; then
            success "sethc.exe restored from backup"
            
            # Verify size matches backup
            NEW_SETHC_SIZE=$(stat -c%s "sethc.exe" 2>/dev/null)
            
            if [ "$NEW_SETHC_SIZE" -eq "$BACKUP_SIZE" ]; then
                success "Size verification: sethc.exe matches backup ($NEW_SETHC_SIZE bytes)"
                
                # Verify content integrity
                if cmp "sethc.exe.backup" "sethc.exe" >/dev/null 2>&1; then
                    success "Content verification: sethc.exe is identical to backup"
                    success "RESTORATION SUCCESSFUL: Sticky Keys functionality restored"
                else
                    error "Content verification failed: Restored file differs from backup!"
                    safe_unmount "$partition"
                    return 1
                fi
                
                # Verify file permissions
                RESTORED_PERMS=$(stat -c%a "sethc.exe" 2>/dev/null)
                log "Restored sethc.exe permissions: $RESTORED_PERMS"
                
                # Set appropriate permissions if needed
                if [ "$RESTORED_PERMS" != "755" ]; then
                    log "Setting proper permissions..."
                    if chmod 755 "sethc.exe"; then
                        success "Permissions set to 755"
                    else
                        warning "Could not set permissions (may still work)"
                    fi
                fi
                
            else
                error "Size verification failed: Restored file size mismatch!"
                error "Expected: $BACKUP_SIZE bytes, Got: $NEW_SETHC_SIZE bytes"
                safe_unmount "$partition"
                return 1
            fi
        else
            error "Restoration verification failed: sethc.exe not found after restoration!"
            safe_unmount "$partition"
            return 1
        fi
    else
        error "Failed to restore sethc.exe from backup!"
        safe_unmount "$partition"
        return 1
    fi
    
    # Step 3: Check and restore cmd.exe if needed
    log "Step 3: Checking cmd.exe restoration..."
    if [ -f "cmd.exe.backup" ]; then
        log "Found cmd.exe.backup, checking if restoration is needed..."
        
        CURRENT_CMD_SIZE=$(stat -c%s "cmd.exe" 2>/dev/null)
        BACKUP_CMD_SIZE=$(stat -c%s "cmd.exe.backup" 2>/dev/null)
        
        log "Current cmd.exe size: $CURRENT_CMD_SIZE bytes"
        log "cmd.exe backup size: $BACKUP_CMD_SIZE bytes"
        
        if [ "$CURRENT_CMD_SIZE" -ne "$BACKUP_CMD_SIZE" ]; then
            log "cmd.exe appears to be modified, restoring from backup..."
            
            # Remove current cmd.exe
            if rm "cmd.exe"; then
                sync; sleep 1
                
                # Restore from backup
                if cp "cmd.exe.backup" "cmd.exe"; then
                    sync; sleep 1
                    
                    # Verify restoration
                    RESTORED_CMD_SIZE=$(stat -c%s "cmd.exe" 2>/dev/null)
                    if [ "$RESTORED_CMD_SIZE" -eq "$BACKUP_CMD_SIZE" ]; then
                        success "cmd.exe restored from backup ($RESTORED_CMD_SIZE bytes)"
                        
                        # Content verification
                        if cmp "cmd.exe.backup" "cmd.exe" >/dev/null 2>&1; then
                            success "cmd.exe content verification: Identical to backup"
                        else
                            warning "cmd.exe content verification failed (may still work)"
                        fi
                    else
                        warning "cmd.exe restoration size mismatch"
                        warning "Expected: $BACKUP_CMD_SIZE bytes, Got: $RESTORED_CMD_SIZE bytes"
                    fi
                else
                    warning "Failed to restore cmd.exe from backup"
                fi
            else
                warning "Failed to remove current cmd.exe for restoration"
            fi
        else
            success "cmd.exe appears to be unchanged (same size as backup)"
        fi
    else
        info "No cmd.exe.backup found - cmd.exe was likely not modified"
        success "cmd.exe appears to be the original file"
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
    ls -la sethc.exe cmd.exe sethc.exe.backup cmd.exe.backup 2>/dev/null
    
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
    if [ "$DELETE_HIBERFIL" -eq 1 ]; then
        echo -e "${YELLOW}5. Hibernation file was removed (cold boot required)${NC}"
    fi
    echo ""
    echo -e "${CYAN}What was restored:${NC}"
    echo -e "${CYAN}- sethc.exe: Restored from backup${NC}"
    echo -e "${CYAN}- File permissions: Reset to normal${NC}"
    echo -e "${CYAN}- Temporary files: Cleaned up${NC}"
    if [ "$DELETE_HIBERFIL" -eq 1 ]; then
        echo -e "${CYAN}- Hibernation file: Removed${NC}"
    fi
    echo ""
    echo -e "${GREEN}The backup files have been kept for reference.${NC}"
    echo -e "${GREEN}You can safely delete them if you no longer need them.${NC}"
    echo ""
    
    # Final unmount - go back to root directory first
    log "Unmounting Windows partition..."
    cd / || true
    safe_unmount "$partition"
    return 0
}

# Function to handle post-completion actions
handle_completion() {
    # Cleanup first
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    
    echo ""
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}              SCRIPT COMPLETED              ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}          POST-COMPLETION OPTIONS           ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    echo -e "${GREEN}The Windows system has been successfully restored!${NC}"
    echo ""
    echo -e "${YELLOW}What was accomplished:${NC}"
    echo -e "${YELLOW}1. Windows system files have been restored to normal${NC}"
    echo -e "${YELLOW}2. Sticky Keys functionality is back to normal${NC}"
    echo -e "${YELLOW}3. Admin bypass has been completely removed${NC}"
    echo -e "${YELLOW}4. System is ready for normal Windows boot${NC}"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo -e "${YELLOW}1. You can now power off PrivilegeOS${NC}"
    echo -e "${YELLOW}2. Boot into Windows normally${NC}"
    echo -e "${YELLOW}3. Verify that Shift x5 shows sticky keys dialog (not CMD)${NC}"
    echo -e "${YELLOW}4. Windows should function completely normally${NC}"
    echo ""
    echo -e "${CYAN}Would you like to power off the system now?${NC}"
    echo -e "${BLUE}Press ENTER to power off, or type 'n'/'no' to exit to shell: ${NC}"
    
    # Read user input
    read -r POWER_CHOICE
    
    case "$POWER_CHOICE" in
        ""|"y"|"Y"|"yes"|"YES"|"Yes")
            echo ""
            echo -e "${GREEN}Powering off the system...${NC}"
            echo -e "${YELLOW}After shutdown, remove the USB drive and boot Windows normally.${NC}"
            echo -e "${YELLOW}Windows should now function with normal login security.${NC}"
            echo ""
            
            # Give user a moment to read the message
            sleep 3
            
            # Sync and power off
            sync
            sync
            poweroff
            ;;
        "n"|"N"|"no"|"NO"|"No")
            echo ""
            echo -e "${GREEN}Returning to shell...${NC}"
            echo -e "${YELLOW}You can manually power off later with: poweroff${NC}"
            echo -e "${YELLOW}Or reboot with: reboot${NC}"
            echo ""
            ;;
        *)
            echo ""
            echo -e "${YELLOW}Invalid choice. Returning to shell...${NC}"
            echo -e "${YELLOW}You can manually power off later with: poweroff${NC}"
            echo -e "${YELLOW}Or reboot with: reboot${NC}"
            echo ""
            ;;
    esac
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
    echo -e "${YELLOW}6. Try: putadmin --force --delete-hiberfil${NC}"
    # Cleanup before exit
    rmdir "$MOUNT_POINT" 2>/dev/null || true
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
if [ "$DELETE_HIBERFIL" -eq 1 ]; then
    echo -e "${YELLOW}Hibernation file: Will be deleted if found${NC}"
else
    echo -e "${BLUE}Hibernation file: Will be preserved${NC}"
fi
echo ""
echo -e "${GREEN}What will be restored:${NC}"
echo -e "${GREEN}- sethc.exe will be restored from backup${NC}"
echo -e "${GREEN}- Normal sticky keys functionality will return${NC}"
echo -e "${GREEN}- Command prompt bypass will be removed${NC}"
echo -e "${GREEN}- Temporary files will be cleaned up${NC}"
if [ "$DELETE_HIBERFIL" -eq 1 ]; then
    echo -e "${GREEN}- Hibernation file will be removed if present${NC}"
fi
echo ""
echo -e "${YELLOW}Continue with restoration? (Type 'YES' to proceed): ${NC}"
read -r CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    warning "Restoration cancelled by user"
    safe_unmount
    # Cleanup before exit
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    exit 0
fi

# Perform the restoration
if perform_restoration "$WINDOWS_PARTITION"; then
    success "Windows restoration operation completed!"
    
    # Handle post-completion actions (power off or continue)
    handle_completion
    
else
    error "Failed to perform restoration!"
    # Cleanup on failure
    safe_unmount
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    exit 1
fi
