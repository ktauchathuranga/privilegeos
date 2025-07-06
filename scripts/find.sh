#!/bin/sh

# NTFS Windows Partition Scanner for BusyBox/PrivilegeOS
# Scans all NTFS partitions and lists contents of Windows partitions

echo "=== NTFS Windows Partition Scanner ==="
echo "Scanning for NTFS partitions..."

# Create temporary mount point
MOUNT_POINT="/tmp/ntfs_scan"
mkdir -p "$MOUNT_POINT"

# Function to check if a partition looks like Windows
is_windows_partition() {
    local mount_point="$1"
    
    # Check for common Windows directories/files
    if [ -d "$mount_point/Windows" ] || [ -d "$mount_point/WINDOWS" ]; then
        return 0
    elif [ -d "$mount_point/Program Files" ] || [ -d "$mount_point/PROGRA~1" ]; then
        return 0
    elif [ -f "$mount_point/bootmgr" ] || [ -f "$mount_point/BOOTMGR" ]; then
        return 0
    elif [ -f "$mount_point/ntldr" ] || [ -f "$mount_point/NTLDR" ]; then
        return 0
    fi
    
    return 1
}

# Function to safely unmount
safe_unmount() {
    local mount_point="$1"
    if mount | grep -q "$mount_point"; then
        umount "$mount_point" 2>/dev/null
    fi
}

# Find all block devices from /proc/partitions
echo "Scanning devices from /proc/partitions..."
cat /proc/partitions | tail -n +3 | while read major minor blocks name; do
    # Skip if name is empty or looks like a whole disk without partition number
    [ -z "$name" ] && continue
    
    # Skip loop devices and ram devices
    case "$name" in
        loop*|ram*) continue ;;
    esac
    
    # Only process devices that exist
    device="/dev/$name"
    [ -b "$device" ] || continue
    
    echo "Checking device: $device"
    
    # Try to identify filesystem type - simplified for BusyBox
    FS_TYPE=""
    
    # Method 1: Try blkid if available
    if command -v blkid >/dev/null 2>&1; then
        FS_TYPE=$(blkid -s TYPE -o value "$device" 2>/dev/null)
    fi
    
    # Skip if not NTFS and try mounting anyway
    if [ "$FS_TYPE" != "ntfs" ] && [ "$FS_TYPE" != "NTFS" ]; then
        # Try different mount methods for NTFS
        if ! mount -t ntfs "$device" "$MOUNT_POINT" 2>/dev/null; then
            continue
        fi
    else
        # Mount the NTFS partition
        if ! mount -t ntfs "$device" "$MOUNT_POINT" 2>/dev/null; then
            echo "  Failed to mount $device"
            continue
        fi
    fi
    
    echo "  Successfully mounted $device"
    
    # Check if this looks like a Windows partition
    if is_windows_partition "$MOUNT_POINT"; then
        echo "  *** WINDOWS PARTITION FOUND on $device ***"
        echo "  Listing contents:"
        echo "  ----------------------------------------"
        
        # List contents with ls
        if ls -la "$MOUNT_POINT" 2>/dev/null; then
            echo "  ----------------------------------------"
        else
            echo "  Error: Could not list directory contents"
        fi
        
        # Also show some Windows-specific directories if they exist
        for windir in "Windows" "WINDOWS" "Program Files" "PROGRA~1" "Users" "Documents and Settings"; do
            if [ -d "$MOUNT_POINT/$windir" ]; then
                echo "  Contents of $windir:"
                ls -la "$MOUNT_POINT/$windir" 2>/dev/null | head -20
                echo "  ----------------------------------------"
            fi
        done
        
    else
        echo "  NTFS partition found but doesn't appear to be Windows"
        echo "  Top-level contents:"
        ls -la "$MOUNT_POINT" 2>/dev/null | head -10
        echo "  ----------------------------------------"
    fi
    
    # Unmount the partition
    safe_unmount "$MOUNT_POINT"
    echo ""
done

# Cleanup
rmdir "$MOUNT_POINT" 2>/dev/null

echo "=== Scan Complete ==="
